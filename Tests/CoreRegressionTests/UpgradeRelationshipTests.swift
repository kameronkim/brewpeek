import Foundation
import XCTest
@testable import BrewPeek

final class UpgradeRelationshipTests: XCTestCase {
  func testDirectGraphExplanationsPreserveIdentityAndReceiptFallback() throws {
    func formula(_ name: String, _ dependencies: [String] = []) -> Record {
      [
        "name": name.split(separator: "/").last.map(String.init) ?? name,
        "full_name": name, "versions": ["stable": "2"], "dependencies": dependencies,
        "installed": [["version": "1"]],
      ]
    }
    func explanations(_ info: Record, selected: Set<String>) throws -> [String: String] {
      var metadata = info
      metadata["formulae"] = metadata["formulae"] ?? [Record]()
      metadata["casks"] = metadata["casks"] ?? [Record]()
      let packages = Upgrade.packages(try Inventory.validateInstalledInfo(metadata)).map { package -> UpgradePackage in
        var package = package
        package.reason = selected.contains(package.id) ? "Selected" : "Related package"
        return package
      }
      let explained = Upgrade.explainRelationships(packages)
      XCTAssertTrue(explained.map(\.id) == packages.map(\.id), "explanations never change plan contents")
      return Dictionary(uniqueKeysWithValues: explained.map { ($0.id, $0.relationship) })
    }
    let graph: Record = [
      "formulae": [
        formula("node", ["homebrew/core/libuv", "simdutf"]), formula("libuv"), formula("simdutf"),
      ]
    ]
    XCTAssertTrue(
      try explanations(graph, selected: ["formula:node"])["formula:simdutf"]
        == "Required by node", "forward dependency")
    XCTAssertTrue(
      try explanations(graph, selected: ["formula:libuv"])["formula:node"]
        == "Uses libuv", "reverse dependency")
    XCTAssertTrue(
      try explanations(graph, selected: ["formula:libuv", "formula:simdutf"])["formula:node"]
        == "Uses libuv, simdutf", "multiple selected dependencies")
    let tapped: Record = [
      "formulae": [
        formula("node", ["vendor/tap/ssl"]), formula("ssl"), formula("vendor/tap/ssl"),
      ]
    ]
    let tappedLabels = try explanations(tapped, selected: ["formula:node"])
    XCTAssertTrue(tappedLabels["formula:ssl"] == "", "same token from another tap must not match")
    XCTAssertTrue(tappedLabels["formula:vendor/tap/ssl"] == "Required by node", "qualified tap matches")
    let chain: Record = [
      "formulae": [
        formula("app", ["middle"]),
        formula("middle", ["base"]), formula("base"), formula("unrelated"),
      ]
    ]
    let chainLabels = try explanations(chain, selected: ["formula:app"])
    XCTAssertTrue(chainLabels["formula:base"] == "Required by middle", "chain names its direct parent")
    XCTAssertTrue(chainLabels["formula:unrelated"] == "", "unproven relationships use the fallback")
    let casks: Record = [
      "formulae": [formula("codec"), formula("viewer")],
      "casks": [
        [
          "token": "viewer", "version": "2", "installed": "1",
          "depends_on": ["formula": ["codec"], "cask": ["helper"]],
        ],
        ["token": "helper", "version": "2", "installed": "1"],
      ],
    ]
    let caskLabels = try explanations(casks, selected: ["cask:viewer"])
    XCTAssertTrue(caskLabels["formula:codec"] == "Required by viewer (cask)", "cask formula dependency")
    XCTAssertTrue(caskLabels["cask:helper"] == "Required by viewer (cask)", "cask dependency")
    XCTAssertTrue(caskLabels["formula:viewer"] == "", "formula and cask identities stay separate")
    let shared: Record = [
      "formulae": [
        formula("app", ["ssl"]), formula("node", ["ssl"]),
        formula("ssl"),
      ]
    ]
    XCTAssertTrue(
      try explanations(shared, selected: ["formula:app", "formula:node"])["formula:ssl"]
        == "Required by app, node", "multiple parent names are stable")
    var receiptOnly = formula("old-app")
    receiptOnly.removeValue(forKey: "dependencies")
    receiptOnly["installed"] = [
      [
        "version": "1",
        "runtime_dependencies": [
          ["full_name": "ssl", "declared_directly": true],
          ["full_name": "indirect", "declared_directly": false],
        ],
      ]
    ]
    let receipts: Record = ["formulae": [receiptOnly, formula("ssl"), formula("indirect")]]
    let receiptLabels = try explanations(receipts, selected: ["formula:old-app"])
    XCTAssertTrue(receiptLabels["formula:ssl"] == "Required by old-app", "direct receipt fallback")
    XCTAssertTrue(receiptLabels["formula:indirect"] == "", "transitive receipt is not a direct edge")
    receiptOnly["dependencies"] = [String]()
    XCTAssertTrue(
      try explanations(
        ["formulae": [receiptOnly, formula("ssl")]],
        selected: ["formula:old-app"])["formula:ssl"] == "",
      "current recipe takes precedence over an old receipt")
  }
}
