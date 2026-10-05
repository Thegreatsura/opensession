import XCTest
@testable import OS1

/// The Standard / Fast / Ultrafast contract the server and web share
/// (`SessionSpeed` in the protocol package, `ModelEffortSelect` on the web):
/// tolerant decoding, which speeds a model and account can run at, and what
/// survives a model or pin change.
final class SessionSpeedTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func model(fast: Bool?, ultra: Bool?) -> ModelOption {
        var option = ModelOption(id: "gpt-6-astra")
        option.provider = "openai"
        option.accountProvider = "codex"
        option.fastModeSupported = fast
        option.ultrafastSupported = ultra
        return option
    }

    private func account(
        _ id: String, kind: String = "home", plan: String? = nil, usable: Bool? = true
    ) -> ProviderAccount {
        var account = ProviderAccount()
        account.id = id
        account.name = "Account \(id)"
        account.kind = kind
        account.plan = plan
        account.usable = usable
        return account
    }

    // MARK: Decoding

    func testSessionSpeedFallsBackToFastModeAndIgnoresUnknownValues() throws {
        XCTAssertEqual(try decode(Session.self, #"{"id":"a"}"#).speedSetting.speed, .standard)
        XCTAssertEqual(
            try decode(Session.self, #"{"id":"a","fastMode":true}"#).speedSetting.speed, .fast,
            "an older server carries only fastMode"
        )
        let ultra = try decode(Session.self, #"{"id":"a","fastMode":true,"speed":"ultrafast"}"#)
        XCTAssertEqual(ultra.speedSetting.speed, .ultrafast)
        XCTAssertEqual(ultra.speedSetting.wireSpeed, "ultrafast")
        XCTAssertTrue(ultra.speedSetting.wireFastMode)

        let future = try decode(Session.self, #"{"id":"a","fastMode":true,"speed":"warp"}"#)
        XCTAssertEqual(future.speedSetting.speed, .fast, "an unknown speed reads as its fastMode")
        XCTAssertNil(future.speedSetting.wireSpeed, "an unknown speed must never be echoed as Fast")
        XCTAssertTrue(future.speedSetting.wireFastMode)

        let unknownAlone = try decode(Session.self, #"{"id":"a","speed":"standard-plus"}"#)
        XCTAssertEqual(unknownAlone.speedSetting.speed, .standard)
        XCTAssertNil(unknownAlone.speedSetting.wireSpeed)
    }

    func testCatalogAndAccountsDecodeOptionalCapabilities() throws {
        let catalog = try decode(
            ModelCatalog.self,
            #"{"models":[{"id":"gpt-6-astra","fastModeSupported":true,"ultrafastSupported":true,"futureFlag":1},{"id":"old","fastModeSupported":true}],"default":"old"}"#
        )
        XCTAssertEqual(catalog.option(for: "gpt-6-astra")?.ultrafastSupported, true)
        XCTAssertNil(catalog.option(for: "old")?.ultrafastSupported)

        let accounts = try decode(
            [ProviderAccount].self,
            #"[{"id":"a","kind":"home","plan":"promax"},{"id":"b","kind":"home"}]"#
        )
        XCTAssertEqual(accounts.map(\.plan), ["promax", nil])
    }

    // MARK: Eligibility

    func testUltrafastNeedsTheModelAndAProMaxLogin() {
        let pool = [account("plus", plan: "plus"), account("max", plan: "promax")]
        let astra = SpeedChoices(model: model(fast: true, ultra: true), accounts: pool, accountId: "")
        XCTAssertEqual(astra.options, [.standard, .fast, .ultrafast])
        XCTAssertEqual(astra.ultrafastAccount?.id, "max")
        XCTAssertEqual(astra.subscriptionAccount?.id, "plus")

        let otherModel = SpeedChoices(model: model(fast: true, ultra: nil), accounts: pool, accountId: "")
        XCTAssertEqual(otherModel.options, [.standard, .fast])

        let noProMax = SpeedChoices(
            model: model(fast: true, ultra: true), accounts: [account("plus", plan: "plus")], accountId: ""
        )
        XCTAssertEqual(noProMax.options, [.standard, .fast])

        let exhausted = SpeedChoices(
            model: model(fast: true, ultra: true),
            accounts: [account("plus"), account("max", plan: "promax", usable: false)],
            accountId: ""
        )
        XCTAssertEqual(exhausted.options, [.standard, .fast], "an unusable Pro $500 login serves nothing")

        XCTAssertTrue(SpeedChoices(model: model(fast: nil, ultra: true), accounts: pool, accountId: "").isEmpty)
        XCTAssertTrue(SpeedChoices(model: nil, accounts: pool, accountId: "").isEmpty)
    }

    func testPinsDecideWhatIsOffered() {
        let pool = [
            account("plus", plan: "plus"),
            account("max", plan: "promax"),
            account("key", kind: "api_key"),
        ]
        let astra = model(fast: true, ultra: true)
        XCTAssertEqual(SpeedChoices(model: astra, accounts: pool, accountId: "max").options, [.standard, .fast, .ultrafast])
        XCTAssertEqual(SpeedChoices(model: astra, accounts: pool, accountId: "plus").options, [.standard, .fast])
        XCTAssertTrue(SpeedChoices(model: astra, accounts: pool, accountId: "key").isEmpty)
        XCTAssertEqual(
            SpeedChoices(model: astra, accounts: pool, accountId: "someone-elses").options, [.standard, .fast],
            "a pin this list cannot see is not provably an API key, nor a Pro $500 login"
        )
        XCTAssertEqual(
            SpeedChoices(model: astra, accounts: [], accountId: "").options, [.standard, .fast],
            "with no pool known yet Fast follows the catalog, as it always has"
        )
        XCTAssertTrue(
            SpeedChoices(model: astra, accounts: [account("key", kind: "api_key")], accountId: "").isEmpty,
            "a pool of API keys has no subscription tier"
        )
    }

    func testEffectiveSpeedStepsDownWithoutTouchingTheStoredValue() {
        let fastOnly = SpeedChoices(model: model(fast: true, ultra: nil), accounts: [], accountId: "")
        XCTAssertEqual(fastOnly.effective(.ultrafast), .fast)
        XCTAssertEqual(fastOnly.effective(.fast), .fast)
        XCTAssertEqual(SpeedChoices().effective(.ultrafast), .standard)
        XCTAssertEqual(SpeedChoices().effective(.standard), .standard)
    }

    func testPickingAFasterTierOnAutoPinsTheServingLogin() {
        let pool = [account("plus", plan: "plus"), account("max", plan: "promax")]
        let choices = SpeedChoices(model: model(fast: true, ultra: true), accounts: pool, accountId: "")
        XCTAssertEqual(choices.pin(for: .ultrafast, accountId: "")?.id, "max")
        XCTAssertEqual(choices.pin(for: .fast, accountId: "")?.id, "plus")
        XCTAssertNil(choices.pin(for: .standard, accountId: ""))
        XCTAssertNil(choices.pin(for: .ultrafast, accountId: "max"), "an existing pin is honored")
    }

    func testModelAndPinChangesDowngrade() {
        XCTAssertEqual(SpeedChoices.afterModelChange(.ultrafast, next: model(fast: true, ultra: nil)), .fast)
        XCTAssertEqual(SpeedChoices.afterModelChange(.ultrafast, next: model(fast: true, ultra: true)), .ultrafast)
        XCTAssertEqual(SpeedChoices.afterModelChange(.fast, next: model(fast: nil, ultra: nil)), .standard)
        XCTAssertEqual(SpeedChoices.afterModelChange(.fast, next: nil), .standard)

        XCTAssertEqual(SpeedChoices.afterPin(.ultrafast, account: account("plus", plan: "plus")), .fast)
        XCTAssertEqual(SpeedChoices.afterPin(.ultrafast, account: account("max", plan: "promax")), .ultrafast)
        XCTAssertEqual(SpeedChoices.afterPin(.ultrafast, account: account("key", kind: "api_key")), .standard)
        XCTAssertEqual(SpeedChoices.afterPin(.ultrafast, account: nil), .ultrafast, "Auto keeps the choice")
    }

    func testPoolKeepsOnlyTheModelsProviderAndTheViewersAccounts() {
        var mine = account("mine", plan: "promax")
        mine.owner = "Alex Example"
        var theirs = account("theirs", plan: "promax")
        theirs.owner = "Sam Example"
        let pools = [
            PooledAccount(account: mine, kind: .codex),
            PooledAccount(account: theirs, kind: .codex),
            PooledAccount(account: account("shared"), kind: .codex),
            PooledAccount(account: account("claude"), kind: .claude),
        ]
        let catalog = ModelCatalog(models: [model(fast: true, ultra: true)], defaultModel: nil)
        let pool = SpeedChoices.pool(
            for: "gpt-6-astra", catalog: catalog, accounts: pools, viewer: "Alex Example"
        )
        XCTAssertEqual(pool.map(\.id), ["mine", "shared"])
    }

    // MARK: Payloads

    @MainActor
    func testCreateBodyCarriesSpeedWithTheLegacyMirror() {
        let standard = OS1API.createSessionBody(prompt: "hi", repo: "acme", mode: "code", user: "Alex")
        XCTAssertNil(standard["speed"])
        XCTAssertNil(standard["fastMode"])

        let ultra = OS1API.createSessionBody(
            prompt: "hi", repo: "acme", mode: "code", speed: .ultrafast, user: "Alex"
        )
        XCTAssertEqual(ultra["speed"] as? String, "ultrafast")
        XCTAssertEqual(ultra["fastMode"] as? Bool, true)
    }

    @MainActor
    func testPromptBodyReplaysLegacyItemsWithFastModeOnly() {
        let legacy = OS1API.deliverPromptBody(
            content: "hi", images: [], user: "Alex", busyMode: "queue",
            effort: nil, fastMode: true, speed: nil, clientId: "c1"
        )
        XCTAssertEqual(legacy["fastMode"] as? Bool, true)
        XCTAssertNil(legacy["speed"], "a pre-speed item must not name a tier")

        let current = OS1API.deliverPromptBody(
            content: "hi", images: [], user: "Alex", busyMode: "queue",
            effort: nil, fastMode: true, speed: "ultrafast", clientId: "c2"
        )
        XCTAssertEqual(current["speed"] as? String, "ultrafast")
    }

    func testOptimisticSessionCarriesTheChosenSpeed() {
        let session = Session.optimistic(
            id: "pending-1", title: "New", repo: "acme", mode: "code",
            model: "gpt-6-astra", effort: nil, speed: .ultrafast, startedBy: "Alex"
        )
        XCTAssertEqual(session.speedSetting.speed, .ultrafast)
        XCTAssertEqual(session.fastMode, true)
    }
}
