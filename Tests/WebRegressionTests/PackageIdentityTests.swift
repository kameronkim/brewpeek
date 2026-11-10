import XCTest
@testable import BrewPeek

final class PackageIdentityTests: XCTestCase {
  func testNativeRecordsRetainIdentityInConfirmationAndProgressAtBothWidths() throws {
    func package(_ type: String, _ fullName: String, _ name: String = "demo", relationship: String = "") -> Record {
      UpgradePackage(name: name, fullName: fullName, type: type, current: ["1.0"], next: "2.0",
                     receipt: "fixture", apps: [], reason: "Selected", relationship: relationship).record
    }
    let fixtures = [
      "triple": [package("formula", "alpha/tools/demo"), package("formula", "beta/tools/demo"), package("cask", "demo")],
      "kinds": [package("formula", "demo"), package("cask", "demo")],
      "taps": [package("formula", "alpha/tools/demo"), package("formula", "beta/tools/demo")],
      "single": [package("formula", "solo", "solo")],
      "relationship": [package("formula", "solo", "solo", relationship: "Uses sdk")]
    ]
    let triple = try XCTUnwrap(fixtures["triple"])
    XCTAssertEqual(Set(triple.compactMap { $0["id"] as? String }).count, 3)
    XCTAssertTrue(triple.allSatisfy { $0["name"] as? String == "demo" && $0["version"] as? String == "1.0" && $0["availableVersion"] as? String == "2.0" })
    let page = try WebTestPage(width: 900, height: 760)
    try page.run("window.fixtures=fixtures; return true;", arguments: ["fixtures": fixtures])
    try page.fixture("PackageIdentity")
    page.resize(width: 480, height: 760)
    try page.run("checkNarrowIdentity(); return true;")
    XCTAssertTrue(page.messages.values.isEmpty)
  }
}
