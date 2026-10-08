import XCTest
@testable import OS1

/// Add project builds the same `POST /api/setup/repos` bodies as the web
/// picker (SetupRepos.tsx, lib/new-repo.ts) and holds one registration at a
/// time.
@MainActor
final class RepoRegistrationTests: XCTestCase {
    private func json(_ registration: RepoRegistration?) throws -> String {
        let registration = try XCTUnwrap(registration)
        return String(decoding: try OS1API.registrationBody(registration), as: UTF8.self)
    }

    // MARK: Bodies

    func testGithubCloneSendsTheBareFullName() throws {
        XCTAssertEqual(try json(.github(fullName: " acme/widget ")), #"{"fullName":"acme\/widget"}"#)
        XCTAssertEqual(RepoRegistration.github(fullName: "acme/widget")?.action, .clone)
    }

    func testCodeStorageNamesItsSource() throws {
        XCTAssertEqual(
            try json(.codeStorage(fullName: "acme/widget")),
            #"{"fullName":"acme\/widget","source":"codestorage"}"#
        )
    }

    func testLocalFolderIsAServerPath() throws {
        XCTAssertEqual(
            try json(.local(path: " /srv/repos/widget ")),
            #"{"path":"\/srv\/repos\/widget","source":"local"}"#
        )
        XCTAssertEqual(RepoRegistration.local(path: "/srv/x")?.action, .register)
        XCTAssertNil(RepoRegistration.local(path: "srv/repos/widget"))
        XCTAssertNil(RepoRegistration.local(path: "/"))
        XCTAssertNil(RepoRegistration.local(path: "  "))
    }

    func testNewOnTheServerOnly() throws {
        XCTAssertEqual(
            try json(.new(name: "my-project", owner: nil)),
            #"{"name":"my-project","source":"new"}"#
        )
        XCTAssertEqual(RepoRegistration.new(name: "my-project", owner: nil)?.action, .create)
    }

    /// The server refuses to create on GitHub, so a GitHub owner connects the
    /// repository the person created there, as a clone.
    func testNewOnGithubConnectsAsAClone() throws {
        let registration = RepoRegistration.new(name: "my-project", owner: "acme")
        XCTAssertEqual(try json(registration), #"{"fullName":"acme\/my-project"}"#)
        XCTAssertEqual(registration?.action, .clone)
        XCTAssertNil(RepoRegistration.new(name: "my-project", owner: "https://github.com/acme"))
    }

    // MARK: Rules

    func testNewRepoNameMatchesTheServerRule() {
        for valid in ["a", "my-project", "My.Project_2", String(repeating: "a", count: 100)] {
            XCTAssertTrue(RepoRegistration.validNewRepoName(valid), valid)
        }
        for invalid in [
            "", "-lead", ".hidden", "a..b", "x.git", "X.GIT", "has space",
            "__proto__", "Constructor", String(repeating: "a", count: 101),
        ] {
            XCTAssertFalse(RepoRegistration.validNewRepoName(invalid), invalid)
        }
    }

    func testGithubOwnerAndFullName() {
        XCTAssertTrue(RepoRegistration.validGithubOwner("acme-labs"))
        XCTAssertFalse(RepoRegistration.validGithubOwner("acme--labs"))
        XCTAssertFalse(RepoRegistration.validGithubOwner("-acme"))
        XCTAssertFalse(RepoRegistration.validGithubOwner("acme-"))
        XCTAssertTrue(RepoRegistration.validGithubFullName("acme/widget.js"))
        XCTAssertFalse(RepoRegistration.validGithubFullName("acme"))
        XCTAssertFalse(RepoRegistration.validGithubFullName("acme/widget/x"))
    }

    func testGithubNewRepoURLIsPrefilledPrivate() throws {
        let url = try XCTUnwrap(RepoRegistration.githubNewRepoURL(owner: "acme", name: "widget"))
        XCTAssertEqual(
            url.absoluteString,
            "https://github.com/new?owner=acme&name=widget&visibility=private&readme=1"
        )
    }

    func testCopyPerAction() {
        let clone = RepoRegistration.github(fullName: "acme/widget")
        XCTAssertEqual(clone?.pendingText, "Cloning acme/widget…")
        XCTAssertEqual(clone?.confirmTitle, "Add acme/widget?")
        XCTAssertEqual(RepoRegistration.local(path: "/srv/w")?.pendingText, "Registering /srv/w…")
        XCTAssertEqual(RepoRegistration.new(name: "w", owner: nil)?.pendingText, "Creating w…")
        XCTAssertEqual(
            AddRepositorySource.allCases.map(\.menuLabel),
            ["Clone repository…", "Local folder…", "New repository…"]
        )
    }

    // MARK: Decoding

    func testDecodesOwnersAndANullAnswer() throws {
        let owners = try JSONDecoder().decode(
            OS1API.GithubOwners.self,
            from: Data(#"{"appConfigured":true,"appInstallUrl":"x","owners":[{"login":"acme","type":"Organization","selected":true}]}"#.utf8)
        )
        XCTAssertEqual(owners.owners?.map(\.login), ["acme"])
        XCTAssertEqual(owners.owners?.first?.selected, true)
        let unavailable = try JSONDecoder().decode(
            OS1API.GithubOwners.self,
            from: Data(#"{"appConfigured":true,"owners":null}"#.utf8)
        )
        XCTAssertNil(unavailable.owners)
    }

    func testDecodesBrowseWithInstallationContext() throws {
        let browse = try JSONDecoder().decode(
            OS1API.RepoBrowse.self,
            from: Data(#"{"source":null,"repos":[],"appConfigured":true,"unavailableInstallations":["acme"],"installations":[]}"#.utf8)
        )
        XCTAssertNil(browse.source)
        XCTAssertEqual(browse.appConfigured, true)
        XCTAssertEqual(browse.unavailableInstallations, ["acme"])
        let older = try JSONDecoder().decode(
            OS1API.RepoBrowse.self,
            from: Data(#"{"source":"org","repos":[{"fullName":"acme/widget","private":true,"defaultBranch":"main","registered":false}]}"#.utf8)
        )
        XCTAssertEqual(older.repos?.count, 1)
        XCTAssertNil(older.appConfigured)
    }

    // MARK: Model

    func testSuccessRecordsTheRepoAndRefreshes() async throws {
        var posted: [RepoRegistration] = []
        var refreshed = 0
        let model = RepoRegistrationModel { posted.append($0) }
        let registration = try XCTUnwrap(RepoRegistration.github(fullName: "acme/widget"))
        let ok = await model.register(registration) { refreshed += 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(posted, [registration])
        XCTAssertEqual(refreshed, 1)
        XCTAssertTrue(model.wasAdded(registration))
        XCTAssertNil(model.pending)
        XCTAssertNil(model.error)
    }

    func testAnAddedRepoIsNotSentAgain() async throws {
        var posts = 0
        let model = RepoRegistrationModel { _ in posts += 1 }
        let registration = try XCTUnwrap(RepoRegistration.local(path: "/srv/w"))
        await model.register(registration)
        let again = await model.register(registration)
        XCTAssertFalse(again)
        XCTAssertEqual(posts, 1)
    }

    func testServerRefusalSurfacesItsTextAndDoesNotRefresh() async throws {
        var refreshed = false
        let model = RepoRegistrationModel { _ in
            throw OS1API.APIError.server("Repository is already registered: acme/widget")
        }
        let registration = try XCTUnwrap(RepoRegistration.github(fullName: "acme/widget"))
        let ok = await model.register(registration) { refreshed = true }
        XCTAssertFalse(ok)
        XCTAssertFalse(refreshed)
        XCTAssertEqual(model.error, "Repository is already registered: acme/widget")
        XCTAssertFalse(model.wasAdded(registration))
        XCTAssertNil(model.pending)
    }

    func testOneRegistrationAtATime() async throws {
        var gate: CheckedContinuation<Void, Never>?
        var posts: [String] = []
        let model = RepoRegistrationModel { registration in
            posts.append(registration.label)
            await withCheckedContinuation { gate = $0 }
        }
        let first = try XCTUnwrap(RepoRegistration.github(fullName: "acme/one"))
        let second = try XCTUnwrap(RepoRegistration.github(fullName: "acme/two"))
        let running = Task { await model.register(first) }
        while gate == nil { await Task.yield() }
        XCTAssertEqual(model.pending, first)
        XCTAssertTrue(model.isBusy)
        let refused = await model.register(second)
        XCTAssertFalse(refused)
        gate?.resume()
        let ok = await running.value
        XCTAssertTrue(ok)
        XCTAssertEqual(posts, ["acme/one"])
    }
}
