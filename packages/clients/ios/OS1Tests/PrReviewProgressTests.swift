import XCTest
@testable import OS1

final class PrReviewProgressTests: XCTestCase {
    // MARK: Decoding

    func testViewedFilesDecodeChangedAndDefaultItForOlderServers() throws {
        let current = try JSONDecoder().decode(
            PrViewedFiles.self,
            from: Data(#"{"prId":"PR_1","viewed":["a.swift"],"changed":["b.swift"]}"#.utf8)
        )
        XCTAssertEqual(current, PrViewedFiles(prId: "PR_1", viewed: ["a.swift"], changed: ["b.swift"]))

        let older = try JSONDecoder().decode(
            PrViewedFiles.self,
            from: Data(#"{"prId":"PR_1","viewed":["a.swift"]}"#.utf8)
        )
        XCTAssertEqual(older.changed, [])
        XCTAssertEqual(older.viewed, ["a.swift"])
    }

    func testGuideDecodesStaleAndDefaultsItToFresh() throws {
        let stale = try JSONDecoder().decode(
            PrReviewGuide.self,
            from: Data(#"{"number":7,"headRefOid":"abc","stale":true,"sections":[{"title":"Core","explanation":"Why","files":["a.swift"]}]}"#.utf8)
        )
        XCTAssertTrue(stale.stale)
        XCTAssertEqual(stale.sections.first?.files, ["a.swift"])

        let older = try JSONDecoder().decode(
            PrReviewGuide.self,
            from: Data(#"{"number":7,"headRefOid":"abc","sections":[{"title":"Core","files":["a.swift"]}]}"#.utf8)
        )
        XCTAssertFalse(older.stale)
        XCTAssertEqual(older.sections.first?.explanation, "")
    }

    func testGithubMarksKeepChangedFilesOutOfReviewed() {
        let marks = PrReviewMarks.github(PrViewedFiles(prId: "PR", viewed: ["a"], changed: ["b"]))
        XCTAssertEqual(marks.state(of: "a"), .reviewed)
        XCTAssertEqual(marks.state(of: "b"), .changed)
        XCTAssertEqual(marks.state(of: "c"), .unreviewed)
    }

    func testOptimisticApplySettlesChangedState() {
        var marks = PrReviewMarks.github(PrViewedFiles(prId: "PR", viewed: ["a"], changed: ["b", "c"]))
        marks.apply(["b"], reviewed: true)
        marks.apply(["c"], reviewed: false)
        XCTAssertEqual(marks.reviewed, ["a", "b"])
        XCTAssertEqual(marks.changed, [])
    }

    // MARK: Local marks

    private func store() -> PrLocalReviewStore {
        let suite = "os1.tests.review.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return PrLocalReviewStore(defaults: defaults)
    }

    private let before = """
    diff --git a/a.swift b/a.swift
    index 111..222 100644
    --- a/a.swift
    +++ b/a.swift
    @@ -1,1 +1,1 @@
    -let a = 1
    +let a = 2
    diff --git a/b.swift b/b.swift
    index 333..444 100644
    --- a/b.swift
    +++ b/b.swift
    @@ -1,1 +1,1 @@
    -let b = 1
    +let b = 2
    """

    func testEditAfterLocalReviewInvalidatesOnlyThatFile() {
        let store = store()
        let key = PrLocalReviewStore.worktreeKey(sessionId: "s", repo: "acme")
        let hashes = PrReviewHash.hashes(of: PatchSplitter.split(before))
        store.setReviewed(key, paths: ["a.swift", "b.swift"], reviewed: true, hashes: hashes)

        let edited = before.replacingOccurrences(of: "+let b = 2", with: "+let b = 3")
        let next = PrReviewHash.hashes(of: PatchSplitter.split(edited))
        let marks = PrReviewMarks.local(key: key, stored: store.read(key), hashes: next)
        XCTAssertEqual(marks.reviewed, ["a.swift"])
        XCTAssertEqual(marks.changed, ["b.swift"])
    }

    func testRebaseThatOnlyMovesBlobIdsKeepsReview() {
        let rebased = before.replacingOccurrences(of: "index 111..222", with: "index 999..aaa")
        XCTAssertEqual(
            PrReviewHash.hashes(of: PatchSplitter.split(before)),
            PrReviewHash.hashes(of: PatchSplitter.split(rebased))
        )
    }

    func testPrPatchHashesAreKeyedAndDistinctPerFile() {
        let parsed = PrReviewHash.hashes(of: PrPatchParser.files(in: before))
        XCTAssertEqual(Set(parsed.keys), ["a.swift", "b.swift"])
        XCTAssertNotEqual(parsed["a.swift"], parsed["b.swift"])
    }

    func testUnmarkingForgetsTheFileAndStoreEvictsOldestReviews() {
        let store = store()
        let hashes = ["a": "1"]
        store.setReviewed("k", paths: ["a"], reviewed: true, hashes: hashes)
        store.setReviewed("k", paths: ["a"], reviewed: false, hashes: hashes)
        XCTAssertEqual(store.read("k"), [:])

        for index in 0...PrLocalReviewStore.maxReviews {
            store.write("review-\(index)", ["a": "1"])
        }
        XCTAssertEqual(store.read("review-0"), [:])
        XCTAssertEqual(store.read("review-\(PrLocalReviewStore.maxReviews)"), ["a": "1"])
    }

    // MARK: Batch actions

    func testBulkActionsFlipOnlyWhatTheyMust() {
        let paths = ["a", "b", "c"]
        let reviewed: Set<String> = ["a"]
        let mark = PrReviewGroups.bulkChanges(paths, reviewed: reviewed, action: .mark)
        XCTAssertEqual(mark.mark, ["b", "c"])
        XCTAssertEqual(mark.unmark, [])
        let reset = PrReviewGroups.bulkChanges(paths, reviewed: reviewed, action: .reset)
        XCTAssertEqual(reset.mark, [])
        XCTAssertEqual(reset.unmark, ["a"])
        let invert = PrReviewGroups.bulkChanges(paths, reviewed: reviewed, action: .invert)
        XCTAssertEqual(invert.mark, ["b", "c"])
        XCTAssertEqual(invert.unmark, ["a"])
    }

    func testBatchBodySendsPathsAndSinglePathForOlderServers() {
        let batch = OS1API.viewedFilesBody(prId: "PR", paths: ["a", "b"], viewed: true, repo: "acme", user: "")
        XCTAssertEqual(batch["paths"] as? [String], ["a", "b"])
        XCTAssertNil(batch["path"])
        XCTAssertEqual(batch["repo"] as? String, "acme")
        XCTAssertNil(batch["user"])

        let single = OS1API.viewedFilesBody(prId: "PR", paths: ["a"], viewed: false, repo: nil, user: "kent")
        XCTAssertEqual(single["path"] as? String, "a")
        XCTAssertEqual(single["paths"] as? [String], ["a"])
        XCTAssertEqual(single["viewed"] as? Bool, false)
        XCTAssertEqual(single["user"] as? String, "kent")
    }

    func testOlderServerRejectionIsRecognised() {
        XCTAssertTrue(OS1API.isSinglePathOnlyServer(OS1API.APIError.server("prId, path and viewed required")))
        XCTAssertTrue(OS1API.isSinglePathOnlyServer(OS1API.APIError.http(400)))
        XCTAssertFalse(OS1API.isSinglePathOnlyServer(OS1API.APIError.server("GitHub GraphQL is rate-limited")))
    }

    func testFolderTargetsOnlyItsOwnFiles() {
        let paths = ["src/a.swift", "src/b.swift", "src-old/c.swift", "src/inner/d.swift"]
        XCTAssertEqual(
            PrReviewGroups.filesInFolder(paths, folder: "src"),
            ["src/a.swift", "src/b.swift", "src/inner/d.swift"]
        )
        XCTAssertEqual(PrReviewGroups.folder(of: "src/inner/d.swift"), "src/inner")
        XCTAssertNil(PrReviewGroups.folder(of: "README.md"))
    }

    // MARK: Groups

    func testTypeGroupsWhileTheGuideIsUnavailable() {
        let paths = ["Sources/App.swift", "src/app.test.ts", "README.md", "project.yml", "Package.resolved", "dist/app.js"]
        let result = PrReviewGroups.reviewGroups(guide: nil, paths: paths)
        XCTAssertFalse(result.fromGuide)
        XCTAssertEqual(result.groups.map(\.title), ["Code", "Tests", "Docs", "Config", "Dependencies", "Generated"])
    }

    func testStaleGuideNamesFilesItDoesNotCoverAsNew() {
        let guide = PrReviewGuide(
            number: 1,
            headRefOid: "old",
            sections: [.init(title: "Core", explanation: "", files: ["App.swift", "Gone.swift"])],
            stale: true
        )
        let result = PrReviewGroups.reviewGroups(guide: guide, paths: ["Sources/App.swift", "Sources/New.swift"])
        XCTAssertTrue(result.fromGuide)
        XCTAssertEqual(result.groups.map(\.title), ["Core", PrReviewGroups.staleLeftoverTitle])
        XCTAssertEqual(result.groups.first?.files, ["Sources/App.swift"])
        XCTAssertEqual(result.groups.last?.files, ["Sources/New.swift"])
    }

    func testGroupProgressCountsReviewedAndChanged() {
        let groups = [PrReviewGroup(title: "One", files: ["b", "a"])]
        let progress = PrReviewGroups.progress(groups, paths: ["a", "b", "c"], reviewed: ["a", "b"], changed: ["c"])
        XCTAssertEqual(progress.map(\.title), ["One", PrReviewGroups.leftoverTitle])
        XCTAssertEqual(progress[0].files, ["a", "b"])
        XCTAssertTrue(progress[0].isDone)
        XCTAssertEqual(progress[1].changed, 1)
        XCTAssertEqual(PrReviewGroups.nextUnreviewed(["a", "b", "c"], after: "a", reviewed: ["a", "b"]), "c")
        XCTAssertNil(PrReviewGroups.nextUnreviewed(["a"], after: nil, reviewed: ["a"]))
    }

    // MARK: History

    func testRemovedFilesAccumulateUntilTheyReturn() {
        var history = PrRemovedFiles.next(nil, target: "pr#1", current: ["a", "b", "c"])
        history = PrRemovedFiles.next(history, target: "pr#1", current: ["a", "b"])
        XCTAssertEqual(history.removed, ["c"])
        history = PrRemovedFiles.next(history, target: "pr#1", current: ["a"])
        XCTAssertEqual(history.removed, ["c", "b"])
        history = PrRemovedFiles.next(history, target: "pr#1", current: ["a", "c"])
        XCTAssertEqual(history.removed, ["b"])
        XCTAssertEqual(PrRemovedFiles.next(history, target: "pr#2", current: ["x"]).removed, [])
    }

    func testResolvedCountsPerFile() {
        let threads = [
            PrReviewThread(id: "1", isResolved: true, isOutdated: false, path: "a", line: 1, rootAuthor: nil, comments: nil),
            PrReviewThread(id: "2", isResolved: true, isOutdated: true, path: "a", line: 2, rootAuthor: nil, comments: nil),
            PrReviewThread(id: "3", isResolved: false, isOutdated: false, path: "b", line: 1, rootAuthor: nil, comments: nil),
        ]
        XCTAssertEqual(PrResolvedThreads.countByPath(threads), ["a": 2])
    }
}
