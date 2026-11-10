import XCTest

final class SecurityDisplayTests: XCTestCase {
  func testFindingsPatchResolutionEscapingAndUpdateAvailability() throws {
    let page = try WebTestPage()
    try page.fixture("SecurityDisplay")
    XCTAssertTrue(page.messages.values.isEmpty)
  }

  func testSingleAndMultipleVersionScopeAcrossFindingAndReportStates() throws {
    let page = try WebTestPage()
    try page.fixture("SecurityVersionCoverage")
    XCTAssertTrue(page.messages.values.isEmpty)
  }
}
