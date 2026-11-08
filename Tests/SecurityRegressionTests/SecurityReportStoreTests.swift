import Foundation
import XCTest
@testable import BrewPeek

private final class UpdateOutcome: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Bool, Error>?
  func store(_ value: Result<Bool, Error>) { lock.lock(); defer { lock.unlock() }; result = value }
  func load() -> Result<Bool, Error>? { lock.lock(); defer { lock.unlock() }; return result }
}

final class SecurityReportStoreTests: XCTestCase {
  func testValidCurrentGenerationUpdatesOnlySecurityFields() throws {
    let workspace = try SecurityWorkspace()
    try SecurityFixture.saveSnapshot(SecurityFixture.snapshot(), to: workspace.inventory)
    let before = try InventoryStore.load(workspace.inventory)
    let report = try SecurityFixture.check("complete-open", status: 1)
    XCTAssertTrue(try SecurityReportStore.update(report, snapshotID: "snapshot-A", at: workspace.inventory, generation: SecurityReportGeneration()))
    var after = try InventoryStore.load(workspace.inventory)
    let saved = try XCTUnwrap(after.removeValue(forKey: "securityCheck") as? Record)
    XCTAssertEqual(try SecurityFixture.canonical(saved), try SecurityFixture.canonical(report))
    XCTAssertEqual(try SecurityFixture.canonical(after), try SecurityFixture.canonical(before))
  }

  func testDifferentSnapshotIsRejectedWithoutChangingFile() throws {
    let workspace = try SecurityWorkspace()
    try SecurityFixture.saveSnapshot(SecurityFixture.snapshot(id: "snapshot-B"), to: workspace.inventory)
    let before = try Data(contentsOf: workspace.inventory)
    XCTAssertFalse(try SecurityReportStore.update(SecurityFixture.check("complete-open", status: 1), snapshotID: "snapshot-A", at: workspace.inventory, generation: SecurityReportGeneration()))
    XCTAssertEqual(try Data(contentsOf: workspace.inventory), before)
  }

  func testInvalidatedGenerationCannotWriteEvenForSameSnapshot() throws {
    let workspace = try SecurityWorkspace()
    try SecurityFixture.saveSnapshot(SecurityFixture.snapshot(), to: workspace.inventory)
    let before = try Data(contentsOf: workspace.inventory)
    let owner = SecurityReportGeneration()
    owner.invalidate()
    XCTAssertFalse(try SecurityReportStore.update(SecurityFixture.check("complete-open", status: 1), snapshotID: "snapshot-A", at: workspace.inventory, generation: owner))
    XCTAssertEqual(try Data(contentsOf: workspace.inventory), before)
  }

  func testDelayedPreTrustWriterCannotOverwriteFreshResultOnSameSnapshot() throws {
    let workspace = try SecurityWorkspace()
    try SecurityFixture.saveSnapshot(SecurityFixture.snapshot(), to: workspace.inventory)
    let previous = SecurityReportGeneration()
    let oldReport = try SecurityFixture.check("incomplete-untrusted", status: 1)
    let freshReport = try SecurityFixture.check("complete-open", status: 1)
    let ready = expectation(description: "Old response is queued")
    let done = expectation(description: "Old response attempts persistence")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let outcome = UpdateOutcome()
    DispatchQueue(label: "security-test-old-response").async {
      ready.fulfill()
      guard release.wait(timeout: .now() + 5) == .success else {
        outcome.store(.failure(InventoryError(message: "Fixture release timed out")))
        done.fulfill(); return
      }
      outcome.store(Result { try SecurityReportStore.update(oldReport, snapshotID: "snapshot-A", at: workspace.inventory, generation: previous) })
      done.fulfill()
    }
    wait(for: [ready], timeout: 5)
    // Trust changes invalidate old ownership before a new report for the same snapshot is saved.
    previous.invalidate()
    XCTAssertTrue(try SecurityReportStore.update(freshReport, snapshotID: "snapshot-A", at: workspace.inventory, generation: SecurityReportGeneration()))
    let freshBytes = try Data(contentsOf: workspace.inventory)
    release.signal()
    wait(for: [done], timeout: 5)
    XCTAssertFalse(try XCTUnwrap(outcome.load()).get())
    XCTAssertEqual(try Data(contentsOf: workspace.inventory), freshBytes)
    let saved = try XCTUnwrap(InventoryStore.load(workspace.inventory)["securityCheck"] as? Record)
    XCTAssertEqual(saved["status"] as? String, "succeeded")
  }

  func testContendedOldWriterCannotSucceedOnRetryAfterInvalidation() throws {
    let workspace = try SecurityWorkspace()
    try SecurityFixture.saveSnapshot(SecurityFixture.snapshot(), to: workspace.inventory)
    let owner = SecurityReportGeneration()
    let oldReport = try SecurityFixture.check("incomplete-untrusted", status: 1)
    let done = expectation(description: "Contended write returns")
    let outcome = UpdateOutcome()
    try HomebrewOperationLock.withLock(at: workspace.inventory) {
      DispatchQueue(label: "security-test-contention").async {
        outcome.store(Result { try SecurityReportStore.update(oldReport, snapshotID: "snapshot-A", at: workspace.inventory, generation: owner) })
        done.fulfill()
      }
      wait(for: [done], timeout: 5)
      switch try XCTUnwrap(outcome.load()) {
      case .failure(HomebrewOperationLock.Failure.busy): break
      default: XCTFail("Lock contention must remain retryable, not count as a saved result")
      }
      owner.invalidate()
    }
    let fresh = try SecurityFixture.check("complete-open", status: 1)
    XCTAssertTrue(try SecurityReportStore.update(fresh, snapshotID: "snapshot-A", at: workspace.inventory, generation: SecurityReportGeneration()))
    let before = try Data(contentsOf: workspace.inventory)
    XCTAssertFalse(try SecurityReportStore.update(oldReport, snapshotID: "snapshot-A", at: workspace.inventory, generation: owner))
    XCTAssertEqual(try Data(contentsOf: workspace.inventory), before)
  }

  func testMissingInventoryIsNotRecreated() throws {
    let workspace = try SecurityWorkspace()
    let destination = workspace.root.appendingPathComponent("removed/inventory.json")
    XCTAssertFalse(try SecurityReportStore.update(SecurityFixture.check("complete-empty"), snapshotID: "snapshot-A", at: destination, generation: SecurityReportGeneration()))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
  }
}

final class SecurityReportGenerationTests: XCTestCase {
  func testGenerationUsesIdentityAndInvalidationPreventsFurtherActions() {
    let first = SecurityReportGeneration()
    let second = SecurityReportGeneration()
    XCTAssertEqual(first, first)
    XCTAssertNotEqual(first, second)
    XCTAssertTrue(first.withCurrent { true })
    first.invalidate()
    var called = false
    XCTAssertFalse(first.withCurrent { called = true; return true })
    XCTAssertFalse(called)
    XCTAssertTrue(second.withCurrent { true })
  }

  func testThrowingActionReleasesGenerationLock() {
    let owner = SecurityReportGeneration()
    XCTAssertThrowsError(try owner.withCurrent { throw InventoryError(message: "Fixture save failure") })
    owner.invalidate()
    XCTAssertFalse(owner.withCurrent { true })
  }
}
