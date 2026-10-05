#if os(iOS)
import ActivityKit
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class LiveActivityCoordinator {
    static let shared = LiveActivityCoordinator()
    static let preferenceKey = "os1.liveActivities.enabled"

    private static let deviceIdKey = "os1.liveActivities.deviceId"
    private static let staleInterval: TimeInterval = 10 * 60

    private var pushToStartTask: Task<Void, Never>?
    private var activityUpdatesTask: Task<Void, Never>?
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var deviceRegistrationTask: Task<Void, Never>?
    private var activityRegistrationTasks: [String: Task<Void, Never>] = [:]
    private var reconcileTask: Task<Void, Never>?
    private var reconcileDirty = false
    private var latestSessions: [Session] = []
    private var latestSnapshot: ActiveSessionsSnapshot?
    private var connection: OS1API.LiveActivityConnection?
    private var reconfigureTask: Task<Void, Never>?
    private var generation = 0
    private var started = false

    var areActivitiesAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private var enabled: Bool {
        UserDefaults.standard.bool(forKey: Self.preferenceKey)
    }

    private func deviceIdKey(for connection: OS1API.LiveActivityConnection) -> String {
        let source = "\(connection.baseURL.absoluteString)\u{0}\(connection.token)"
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(Self.deviceIdKey).\(digest)"
    }

    private func deviceId(for connection: OS1API.LiveActivityConnection) -> String {
        let defaults = UserDefaults.standard
        let key = deviceIdKey(for: connection)
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: key)
        return id
    }

    private func storedDeviceId(for connection: OS1API.LiveActivityConnection) -> String? {
        UserDefaults.standard.string(forKey: deviceIdKey(for: connection))
    }

    func start() {
        guard enabled else { return }
        let next = OS1API.LiveActivityConnection.current()
        if connection != next {
            let previous = connection
            connection = next
            latestSnapshot = nil
            generation += 1
            let currentGeneration = generation
            stopObservers()
            started = true
            let priorTask = reconfigureTask
            reconfigureTask = Task { [weak self] in
                _ = await priorTask?.value
                guard let self else { return }
                if let previous { await cleanup(previous) }
                guard generation == currentGeneration else { return }
                guard let next else {
                    started = false
                    return
                }
                beginObservers(connection: next)
                scheduleReconcile()
            }
            return
        }
        guard let next, !started else { return }
        started = true
        beginObservers(connection: next)
        scheduleReconcile()
    }

    private func beginObservers(connection: OS1API.LiveActivityConnection) {
        pushToStartTask = Task { [weak self] in
            guard let self else { return }
            if let token = Activity<ActiveSessionsAttributes>.pushToStartToken {
                scheduleDeviceRegistration(token.hexString, connection: connection)
            }
            for await token in Activity<ActiveSessionsAttributes>.pushToStartTokenUpdates {
                guard !Task.isCancelled else { return }
                scheduleDeviceRegistration(token.hexString, connection: connection)
            }
        }

        activityUpdatesTask = Task { [weak self] in
            guard let self else { return }
            for activity in Activity<ActiveSessionsAttributes>.activities {
                observe(activity, connection: connection)
            }
            for await activity in Activity<ActiveSessionsAttributes>.activityUpdates {
                guard !Task.isCancelled else { return }
                observe(activity, connection: connection)
            }
        }
    }

    func sync(_ sessions: [Session]) {
        latestSessions = sessions
        syncCurrentSnapshot()
    }

    /// Read marks can change without the sessions poll changing. Rebuild from
    /// the last authoritative list so the Island and app icon clear as soon as
    /// someone opens or marks a session read.
    func refreshUnreadStatus() {
        syncCurrentSnapshot()
    }

    private func syncCurrentSnapshot() {
        let reads = ReadsStore.shared
        let snapshot = ActiveSessionsSnapshot.make(
            from: latestSessions,
            userName: ServerConfig.shared.userName,
            githubLogin: ServerConfig.shared.githubLogin,
            isUnread: { reads.isUnread($0) }
        )
        guard enabled else {
            latestSnapshot = snapshot
            return
        }
        let reconfiguring = connection != OS1API.LiveActivityConnection.current()
        start()
        latestSnapshot = snapshot
        if !reconfiguring {
            scheduleReconcile()
        }
    }

    func disable() async {
        generation += 1
        reconfigureTask?.cancel()
        reconfigureTask = nil
        stopObservers()
        let previous = connection
        connection = nil
        if let previous { await cleanup(previous) }
        else { await endLocalActivities() }
    }

    private func stopObservers() {
        started = false
        pushToStartTask?.cancel()
        activityUpdatesTask?.cancel()
        pushToStartTask = nil
        activityUpdatesTask = nil
        for task in tokenTasks.values { task.cancel() }
        tokenTasks.removeAll()
        deviceRegistrationTask?.cancel()
        deviceRegistrationTask = nil
        for task in activityRegistrationTasks.values { task.cancel() }
        activityRegistrationTasks.removeAll()
        reconcileTask?.cancel()
        reconcileTask = nil
        reconcileDirty = false
    }

    private func cleanup(_ connection: OS1API.LiveActivityConnection) async {
        await endLocalActivities()
        if let storedDeviceId = storedDeviceId(for: connection) {
            try? await OS1API.unregisterLiveActivityDevice(
                deviceId: storedDeviceId,
                connection: connection
            )
        }
    }

    private func endLocalActivities() async {
        let final = ActivityContent(state: ActiveSessionsSnapshot.empty, staleDate: nil)
        for activity in Activity<ActiveSessionsAttributes>.activities {
            await activity.end(final, dismissalPolicy: .immediate)
        }
    }

    private func scheduleReconcile() {
        reconcileDirty = true
        guard reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            while reconcileDirty, !Task.isCancelled {
                reconcileDirty = false
                await reconcileLocalActivity(expectedGeneration: generation)
            }
            reconcileTask = nil
            if reconcileDirty { scheduleReconcile() }
        }
    }

    private func reconcileLocalActivity(expectedGeneration: Int) async {
        guard areActivitiesAvailable,
              let latestSnapshot,
              let connection
        else { return }
        let currentDeviceId = deviceId(for: connection)
        let allActivities = Activity<ActiveSessionsAttributes>.activities
        let mismatched = allActivities.filter { $0.attributes.deviceId != currentDeviceId }
        if !mismatched.isEmpty {
            let final = ActivityContent(state: ActiveSessionsSnapshot.empty, staleDate: nil)
            for activity in mismatched {
                await activity.end(final, dismissalPolicy: .immediate)
            }
        }
        guard generation == expectedGeneration, self.connection == connection else { return }
        var activities = allActivities.filter { $0.attributes.deviceId == currentDeviceId }

        if latestSnapshot.totalCount == 0, latestSnapshot.unreadCount == 0 {
            let final = ActivityContent(state: latestSnapshot, staleDate: nil)
            for activity in activities {
                await activity.end(final, dismissalPolicy: .after(Date().addingTimeInterval(30)))
            }
            return
        }

        let content = ActivityContent(
            state: latestSnapshot,
            staleDate: Date().addingTimeInterval(Self.staleInterval)
        )
        if activities.isEmpty {
            if let activity = try? Activity.request(
                attributes: ActiveSessionsAttributes(deviceId: currentDeviceId),
                content: content,
                pushType: .token
            ) {
                activities = [activity]
                observe(activity, connection: connection)
            }
        } else {
            await activities[0].update(content)
        }

        for duplicate in activities.dropFirst() {
            await duplicate.end(content, dismissalPolicy: .immediate)
        }
    }

    private func observe(
        _ activity: Activity<ActiveSessionsAttributes>,
        connection: OS1API.LiveActivityConnection
    ) {
        guard activity.attributes.deviceId == deviceId(for: connection) else {
            Task {
                let final = ActivityContent(state: ActiveSessionsSnapshot.empty, staleDate: nil)
                await activity.end(final, dismissalPolicy: .immediate)
            }
            return
        }
        guard tokenTasks[activity.id] == nil else { return }
        tokenTasks[activity.id] = Task { [weak self] in
            guard let self else { return }
            if let token = activity.pushToken {
                scheduleActivityRegistration(
                    activity: activity,
                    token: token.hexString,
                    connection: connection
                )
            }
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                scheduleActivityRegistration(
                    activity: activity,
                    token: token.hexString,
                    connection: connection
                )
            }
        }
    }

    private func scheduleDeviceRegistration(
        _ token: String,
        connection: OS1API.LiveActivityConnection
    ) {
        deviceRegistrationTask?.cancel()
        deviceRegistrationTask = Task { [weak self] in
            await self?.maintainDeviceRegistration(token: token, connection: connection)
        }
    }

    private func scheduleActivityRegistration(
        activity: Activity<ActiveSessionsAttributes>,
        token: String,
        connection: OS1API.LiveActivityConnection
    ) {
        activityRegistrationTasks[activity.id]?.cancel()
        activityRegistrationTasks[activity.id] = Task { [weak self] in
            await self?.register(activity: activity, token: token, connection: connection)
        }
    }

    private func maintainDeviceRegistration(
        token: String,
        connection: OS1API.LiveActivityConnection
    ) async {
        var retryDelay: TimeInterval = 1
        while !Task.isCancelled, self.connection == connection, enabled {
            do {
                try await OS1API.registerLiveActivityDevice(
                    deviceId: deviceId(for: connection),
                    pushToStartToken: token,
                    connection: connection
                )
                retryDelay = 1
                try await Task.sleep(for: .seconds(12 * 60 * 60))
            } catch {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(retryDelay))
                retryDelay = min(retryDelay * 2, 60)
            }
        }
    }

    private func register(
        activity: Activity<ActiveSessionsAttributes>,
        token: String,
        connection: OS1API.LiveActivityConnection
    ) async {
        var retryDelay: TimeInterval = 1
        while !Task.isCancelled, self.connection == connection, enabled {
            do {
                try await OS1API.registerLiveActivity(
                    deviceId: deviceId(for: connection),
                    activityId: activity.id,
                    pushToken: token,
                    connection: connection
                )
                return
            } catch {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(retryDelay))
                retryDelay = min(retryDelay * 2, 60)
            }
        }
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
#endif
