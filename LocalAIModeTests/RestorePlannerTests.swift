import XCTest
@testable import Local_AI_Mode

struct FakeEnvironment: AppEnvironment {
    var existing: Set<String> = []
    var lookup: [String: URL] = [:]
    var running: Set<String> = []

    func fileExists(atPath path: String) -> Bool { existing.contains(path) }
    func applicationURL(forBundleIdentifier id: String) -> URL? { lookup[id] }
    func isRunning(bundleIdentifier: String?, bundlePath: String) -> Bool {
        running.contains(bundleIdentifier ?? bundlePath)
    }
}

final class RestorePlannerTests: XCTestCase {
    private func entry(_ name: String, _ id: String, order: Int, docs: [String] = []) -> AppSnapshotEntry {
        AppSnapshotEntry(name: name, bundleIdentifier: id, bundlePath: "/Applications/\(name).app",
                         processIdentifier: 1, launchOrder: order, documentURLs: docs)
    }

    func testLaunchesInOriginalOrderAndSkipsRunningApps() {
        let snap = WorkspaceSnapshot(applications: [entry("B", "b", order: 1), entry("A", "a", order: 0), entry("C", "c", order: 2)],
                                     accessibilityWasAvailable: false, browserCaptureWasEnabled: false)
        let env = FakeEnvironment(existing: ["/Applications/A.app", "/Applications/B.app", "/Applications/C.app"], running: ["c"])
        let plan = RestorePlanner.plan(for: snap, environment: env)
        XCTAssertEqual(plan.map(\.entry.name), ["A", "B", "C"])
        guard case .launch(_, let url, let relocated) = plan[0] else { return XCTFail() }
        XCTAssertEqual(url.path, "/Applications/A.app")
        XCTAssertFalse(relocated)
        guard case .alreadyRunning = plan[2] else { return XCTFail("C is running") }
    }

    func testMovedAppIsFoundByBundleID() {
        let snap = WorkspaceSnapshot(applications: [entry("Moved", "com.x.moved", order: 0)],
                                     accessibilityWasAvailable: false, browserCaptureWasEnabled: false)
        let newURL = URL(fileURLWithPath: "/Users/me/Applications/Moved.app")
        let env = FakeEnvironment(existing: [newURL.path], lookup: ["com.x.moved": newURL])
        guard case .launch(_, let url, let relocated) = RestorePlanner.plan(for: snap, environment: env)[0] else { return XCTFail() }
        XCTAssertEqual(url, newURL)
        XCTAssertTrue(relocated)
    }

    func testUninstalledAppIsReportedMissing() {
        let snap = WorkspaceSnapshot(applications: [entry("Gone", "com.x.gone", order: 0)],
                                     accessibilityWasAvailable: false, browserCaptureWasEnabled: false)
        guard case .missing(_, let reason) = RestorePlanner.plan(for: snap, environment: FakeEnvironment())[0] else { return XCTFail() }
        XCTAssertTrue(reason.contains("moved or uninstalled"))
    }

    func testStaleLaunchServicesEntryIsMissing() {
        let snap = WorkspaceSnapshot(applications: [entry("Gone", "com.x.gone", order: 0)],
                                     accessibilityWasAvailable: false, browserCaptureWasEnabled: false)
        let env = FakeEnvironment(lookup: ["com.x.gone": URL(fileURLWithPath: "/Trash/Gone.app")])
        guard case .missing = RestorePlanner.plan(for: snap, environment: env)[0] else { return XCTFail() }
    }

    func testOnlyExistingDocumentsAreReopened() {
        let e = entry("TextEdit", "t", order: 0, docs: ["file:///tmp/a.txt", "file:///tmp/deleted.txt", "https://not-a-file"])
        let docs = RestorePlanner.existingDocuments(for: e, environment: FakeEnvironment(existing: ["/tmp/a.txt"]))
        XCTAssertEqual(docs.map(\.path), ["/tmp/a.txt"])
    }
}
