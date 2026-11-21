import Cocoa
import XCTest
@testable import BrewPeek

final class UpdateQuitTests: XCTestCase {
  private let id = "running-update"
  private let photo = QuitCaskApp(packageID: "cask:studio", path: "/Applications/Photo.app", bundleID: "test.photo")
  private let video = QuitCaskApp(packageID: "cask:studio", path: "/Applications/Video.app", bundleID: "test.video")
  private var success: Record {
    ["kind": "result", "verified": true, "exitCode": Int32(0), "commandWarning": "",
     "snapshot": Record(), "packages": [["outcome": "updated"], ["outcome": "installed"]]]
  }

  private func desktop() throws -> DesktopApp {
    _ = NSApplication.shared
    let suite = "BrewPeek.Tests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return DesktopApp(output: FileManager.default.temporaryDirectory.appendingPathComponent(suite), preferences: defaults)
  }

  private func runUpdate(_ app: DesktopApp, apps: Set<QuitCaskApp> = []) {
    app.operation.phase = .running
    app.operation.requestID = id
    app.operation.updateQuit = UpdateQuit(closedApps: apps)
  }
  private func schedule(_ app: DesktopApp, reopen: Bool, request: String? = nil) {
    app.handleUpdate(["action": "scheduleQuit", "requestID": request ?? id, "reopen": reopen])
  }

  func testOnlyRunningUpdateCanScheduleAndOnlyConfirmedAppChoiceIsRemembered() throws {
    let app = try desktop()
    app.operation.phase = .running
    app.operation.requestID = id // Other package operations use the same execution phase.
    schedule(app, reopen: false)
    XCTAssertNil(app.operation.updateQuit)
    runUpdate(app, apps: [photo])
    func preferred() -> Bool? {
      app.operation.updateQuit?.prompt(requestID: id, preferences: app.preferences)["reopen"] as? Bool
    }
    XCTAssertEqual(preferred(), true)
    schedule(app, reopen: false, request: "old")
    XCTAssertNil(app.operation.updateQuit?.reopenBeforeQuit)
    app.handleUpdate(["action": "cancelScheduledQuit", "requestID": id])
    XCTAssertNil(app.preferences.object(forKey: UpdateQuit.preferenceKey))
    schedule(app, reopen: false)
    XCTAssertEqual(preferred(), false)
    app.handleUpdate(["action": "cancelScheduledQuit", "requestID": "old"])
    XCTAssertEqual(app.operation.updateQuit?.reopenBeforeQuit, false)
    app.handleUpdate(["action": "cancelScheduledQuit", "requestID": id])
    XCTAssertNil(app.operation.updateQuit?.reopenBeforeQuit)
    XCTAssertEqual(app.operation.phase, .running)
    var quits = 0
    app.finishUpdate(success, requestID: id, quit: { quits += 1 })
    XCTAssertEqual(quits, 0)
    runUpdate(app)
    schedule(app, reopen: true)
    XCTAssertEqual(preferred(), false, "An update with no closed apps keeps the stored preference")
    app.finishUpdate(success, requestID: "old", quit: { quits += 1 })
    XCTAssertTrue(app.busy)
    app.finishUpdate(success, requestID: id, quit: { quits += 1 })
    XCTAssertEqual(quits, 1)
    XCTAssertNil(app.operation.updateQuit)
    runUpdate(app, apps: [photo])
    schedule(app, reopen: false)
    app.finishUpdate(success, requestID: id, open: { _, _ in XCTFail("Reopen was unchecked") }, quit: { quits += 1 })
    XCTAssertEqual(quits, 2)
  }

  func testIncompleteResultsKeepBrewPeekOpenAndClearTheReservation() throws {
    let app = try desktop()
    let changes: [Record] = [
      ["verified": false], ["exitCode": Int32(1)], ["commandWarning": "warning"],
      ["snapshot": NSNull()], ["refreshError": "save failed"], ["kind": "error"], ["packages": []],
    ] + ["attention", "failed", "skipped"].map { ["packages": [["outcome": "updated"], ["outcome": $0]]] }
    for change in changes {
      runUpdate(app, apps: [photo])
      schedule(app, reopen: true)
      app.finishUpdate(success.merging(change) { _, new in new }, requestID: id,
        open: { _, _ in XCTFail("Incomplete update launched an app") }, quit: { XCTFail("Unexpected quit: \(change)") })
      XCTAssertFalse(app.busy)
      XCTAssertNil(app.operation.updateQuit)
    }
  }

  func testWaitsForEveryLaunchAndKeepsOnlyFailedAppsRetryable() throws {
    let app = try desktop()
    for mode in ["success", "launch failure", "cancel", "missing target"] {
      runUpdate(app, apps: [photo, video])
      schedule(app, reopen: true)
      var result = success
      var targets: [String: Record] = ["photo": ["name": "Photo"]]
      if mode != "missing target" { targets["video"] = ["name": "Video"] }
      result["reopenApps"] = targets
      var callbacks: [String: (String?) -> Void] = [:]
      var quits = 0
      app.finishUpdate(result, requestID: id, open: { target, callback in
        callbacks[target["name"] as! String] = callback
      }, quit: { quits += 1 })
      XCTAssertTrue(app.busy)
      XCTAssertEqual(app.applicationShouldTerminate(.shared), .terminateCancel)
      if mode == "cancel" { app.handleUpdate(["action": "cancelScheduledQuit", "requestID": id]) }
      try XCTUnwrap(callbacks["Photo"])(nil)
      if mode != "missing target" {
        XCTAssertEqual(quits, 0)
        XCTAssertTrue(app.busy)
        try XCTUnwrap(callbacks["Video"])(mode == "launch failure" ? "Launch failed" : nil)
      }
      XCTAssertFalse(app.busy)
      XCTAssertEqual(quits, mode == "success" ? 1 : 0)
      let saved = try XCTUnwrap(app.webRecovery.lastResult)
      let retry = try XCTUnwrap(saved["reopenApps"] as? [String: Record])
      XCTAssertEqual(Set(retry.keys), mode == "launch failure" ? ["video"] : [])
      XCTAssertEqual(saved["reopenWarning"] != nil, ["launch failure", "missing target"].contains(mode))
    }
  }
}
