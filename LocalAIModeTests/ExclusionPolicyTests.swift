import XCTest
@testable import Local_AI_Mode

final class ExclusionPolicyTests: XCTestCase {
    private func policy(excluded: Set<String> = [], menuBar: Bool = false, hosts: Set<Int32> = []) -> ExclusionPolicy {
        ExclusionPolicy(ownBundleIdentifier: "com.localaimode.LocalAIMode", ownPID: 100,
                        userExcludedBundleIDs: excluded, includeMenuBarApps: menuBar, ollamaHostPIDs: hosts)
    }

    private func app(_ name: String, _ id: String?, path: String? = nil, pid: Int32 = 500,
                     policy: AppDescriptor.Policy = .regular) -> AppDescriptor {
        AppDescriptor(name: name, bundleIdentifier: id, bundlePath: path ?? "/Applications/\(name).app", pid: pid, activationPolicy: policy)
    }

    func testRegularUserAppWillClose() {
        XCTAssertEqual(policy().decision(for: app("Pages", "com.apple.iWork.Pages")), .willClose)
    }

    func testSelfIsProtectedByPIDAndBundleID() {
        XCTAssertTrue(policy().decision(for: app("Local AI Mode", "x", pid: 100)).isProtected)
        XCTAssertTrue(policy().decision(for: app("Local AI Mode", "com.localaimode.LocalAIMode")).isProtected)
    }

    func testOllamaIsProtected() {
        XCTAssertEqual(policy().decision(for: app("Ollama", "com.electron.ollama")), .protected(reason: "Ollama"))
        XCTAssertEqual(policy().decision(for: app("Ollama Helper", "com.example.unknown", path: "/Applications/Ollama.app/Contents/Helper.app")),
                       .protected(reason: "Ollama"))
    }

    func testFinderAndSystemProcessesAreProtected() {
        XCTAssertEqual(policy().decision(for: app("Finder", "com.apple.finder", path: "/System/Library/CoreServices/Finder.app")),
                       .protected(reason: "Finder"))
        XCTAssertTrue(policy().decision(for: app("Dock", "com.apple.dock", path: "/System/Library/CoreServices/Dock.app")).isProtected)
        XCTAssertTrue(policy().decision(for: app("Agent", "com.apple.someagent", path: "/System/Library/PrivateFrameworks/X.app")).isProtected)
    }

    func testSystemApplicationsFolderAppsAreClosable() {
        // Notes lives in /System/Applications but is a normal user app.
        XCTAssertEqual(policy().decision(for: app("Notes", "com.apple.Notes", path: "/System/Applications/Notes.app")), .willClose)
    }

    func testUserExclusion() {
        XCTAssertEqual(policy(excluded: ["com.apple.Music"]).decision(for: app("Music", "com.apple.Music")), .userExcluded)
    }

    func testProtectionWinsOverUserExclusion() {
        XCTAssertTrue(policy(excluded: ["com.apple.finder"]).decision(for: app("Finder", "com.apple.finder")).isProtected)
    }

    func testMenuBarAppsOnlyWhenEnabled() {
        let a = app("Rectangle", "com.knollsoft.Rectangle", policy: .accessory)
        if case .notIncluded = policy().decision(for: a) {} else { XCTFail("Menu-bar app should not be included by default") }
        XCTAssertEqual(policy(menuBar: true).decision(for: a), .willClose)
    }

    func testBackgroundOnlyAndBundlelessAreProtected() {
        XCTAssertTrue(policy().decision(for: app("bg", "com.x.bg", policy: .prohibited)).isProtected)
        XCTAssertTrue(policy().decision(for: AppDescriptor(name: "cli", bundleIdentifier: nil, bundlePath: nil, pid: 9, activationPolicy: .regular)).isProtected)
    }

    func testAppHostingOllamaServerIsProtected() {
        let terminal = app("Terminal", "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app", pid: 777)
        XCTAssertEqual(policy(hosts: [777]).decision(for: terminal), .protected(reason: "Hosts the Ollama server"))
        XCTAssertEqual(policy().decision(for: terminal), .willClose)
    }
}

final class DefaultExclusionTests: XCTestCase {
    func testFreshSettingsExcludeClaudeAndTerminal() {
        var s = AppSettings()
        XCTAssertTrue(s.seedDefaultExclusions())
        XCTAssertEqual(Set(s.userExcludedBundleIDs), ["com.anthropic.claudefordesktop", "com.apple.Terminal"])
    }

    func testExistingSettingsGetDefaultsMergedOnce() throws {
        // Settings saved before the defaults existed (no seed version key).
        var s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"userExcludedBundleIDs":["com.apple.Music"]}"#.utf8))
        XCTAssertTrue(s.seedDefaultExclusions())
        XCTAssertEqual(Set(s.userExcludedBundleIDs), ["com.apple.Music", "com.anthropic.claudefordesktop", "com.apple.Terminal"])
    }

    func testRemovedDefaultIsNotReAdded() throws {
        var s = AppSettings()
        s.seedDefaultExclusions()
        s.userExcludedBundleIDs.removeAll { $0 == "com.apple.Terminal" }
        let reloaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        var r = reloaded
        XCTAssertFalse(r.seedDefaultExclusions())
        XCTAssertFalse(r.userExcludedBundleIDs.contains("com.apple.Terminal"))
    }

    func testDefaultsResolveToUserExcludedDecision() {
        var s = AppSettings(); s.seedDefaultExclusions()
        let policy = ExclusionPolicy(ownBundleIdentifier: nil, ownPID: 1, userExcludedBundleIDs: Set(s.userExcludedBundleIDs), includeMenuBarApps: false)
        let claude = AppDescriptor(name: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop", bundlePath: "/Applications/Claude.app", pid: 50, activationPolicy: .regular)
        XCTAssertEqual(policy.decision(for: claude), .userExcluded)
    }
}
