import XCTest
@testable import Local_AI_Mode

final class SnapshotSerializationTests: XCTestCase {
    static func sampleSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(applications: [
            AppSnapshotEntry(name: "Safari", bundleIdentifier: "com.apple.Safari", bundlePath: "/Applications/Safari.app",
                             processIdentifier: 321, wasHidden: false, wasActive: true, launchOrder: 0,
                             documentURLs: [], windowCount: 2,
                             browserTabs: [BrowserTab(url: "https://example.com", title: "Example")]),
            AppSnapshotEntry(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", bundlePath: "/System/Applications/TextEdit.app",
                             processIdentifier: 654, wasHidden: true, launchOrder: 1,
                             documentURLs: ["file:///Users/me/notes.txt"], wasClosedByAIMode: true),
        ], accessibilityWasAvailable: true, browserCaptureWasEnabled: true)
    }

    func testRoundTrip() throws {
        let snap = Self.sampleSnapshot()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(WorkspaceSnapshot.self, from: enc.encode(snap))
        XCTAssertEqual(decoded.id, snap.id)
        XCTAssertEqual(decoded.applications, snap.applications)
        XCTAssertEqual(decoded.schemaVersion, WorkspaceSnapshot.currentSchemaVersion)
        XCTAssertEqual(decoded.closedApplications.map(\.name), ["TextEdit"])
        XCTAssertEqual(decoded.applications[0].browserTabs.first?.url, "https://example.com")
    }

    func testJournalRoundTripPreservesChangedSettings() throws {
        var journal = SessionJournal(phase: .active, snapshot: Self.sampleSnapshot())
        journal.changedSettings = ChangedSettingsRecord(
            originalPowerModes: [PowerModeSetting(key: "powermode", source: .battery, value: 1)], powerModesChanged: true)
        journal.requestedModel = "llama3.2:3b"
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(SessionJournal.self, from: enc.encode(journal))
        XCTAssertEqual(decoded.changedSettings, journal.changedSettings)
        XCTAssertEqual(decoded.requestedModel, "llama3.2:3b")
        XCTAssertEqual(decoded.phase, .active)
    }

    func testSettingsDecodeToleratesMissingKeys() throws {
        let data = Data(#"{"selectedModel":"qwen3:8b","keepAliveMinutes":30}"#.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(s.selectedModel, "qwen3:8b")
        XCTAssertEqual(s.keepAliveMinutes, 30)
        XCTAssertTrue(s.confirmBeforeClosing) // default preserved
        XCTAssertEqual(s.keepAliveAPIValue, .duration(seconds: 1800))
    }
}
