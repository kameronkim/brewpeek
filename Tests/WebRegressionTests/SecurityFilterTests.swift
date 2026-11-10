import XCTest

final class SecurityFilterTests: XCTestCase {
  func testFilterIntersectionsAsyncMembershipAndReadingPositionAtBothWidths() throws {
    for width in [1100, 480] {
      let page = try WebTestPage(width: CGFloat(width))
      try page.fixture("SecurityFilter")
      XCTAssertTrue(page.messages.values.isEmpty)
    }
  }
}
