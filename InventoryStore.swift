import Foundation

/// The single persisted snapshot; UI assets always live in the app bundle.
enum InventoryStore {
  static func decode(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      value["formulae"] is [[String: Any]], value["casks"] is [[String: Any]],
      value["taps"] is [String], value["environment"] is [String: Any]
    else {
      throw InventoryError(message: "저장된 설치 정보의 형식이 올바르지 않습니다.")
    }
    return value
  }
  static func save(_ value: [String: Any], to url: URL) throws {
    var snapshot = value
    snapshot["schemaVersion"] = 1
    let data = try JSONSerialization.data(
      withJSONObject: snapshot, options: [.sortedKeys, .prettyPrinted])
    _ = try decode(data)
    try data.write(to: url, options: .atomic)
  }
  static func load(_ url: URL) throws -> [String: Any] {
    try decode(Data(contentsOf: url))
  }
  static func migrateLegacy(to url: URL) throws {
    let legacy = url.deletingLastPathComponent().appendingPathComponent("homebrew-inventory.html")
    guard FileManager.default.fileExists(atPath: legacy.path) else { return }
    if !FileManager.default.fileExists(atPath: url.path) {
      let html = try String(contentsOf: legacy, encoding: .utf8)
      guard let start = html.range(of: "const brewData = "),
        let end = html.range(of: ";\n", range: start.upperBound..<html.endIndex)
      else {
        throw InventoryError(message: "이전 보고서의 데이터를 읽지 못했습니다.")
      }
      let value = try decode(Data(html[start.upperBound..<end.lowerBound].utf8))
      try save(value, to: url)
    }
    _ = try load(url)
    try FileManager.default.removeItem(at: legacy)
  }
}
