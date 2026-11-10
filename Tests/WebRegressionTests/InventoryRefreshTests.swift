import XCTest

final class InventoryRefreshTests: XCTestCase {
  func testRefreshSearchSortAndSecurityPatchPreserveInventoryState() throws {
    let page = try WebTestPage()
    try page.fixture("InventoryRefresh")
    XCTAssertTrue(page.messages.values.isEmpty)
  }
}
