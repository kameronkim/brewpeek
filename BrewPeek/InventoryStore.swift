import Foundation

/// The single persisted snapshot; UI assets always live in the app bundle.
enum InventoryStore {
  static func decode(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? Record else {
      throw InventoryError(
        message: NSLocalizedString("The saved inventory has an invalid format.", comment: ""))
    }
    return try normalize(value)
  }

  private static func normalize(_ snapshot: Record) throws -> Record {
    var value = snapshot
    func invalid() -> InventoryError {
      InventoryError(
        message: NSLocalizedString("The saved inventory has an invalid format.", comment: ""))
    }
    guard let formulae = value["formulae"] as? [Record], let casks = value["casks"] as? [Record],
      value["taps"] is [String], var environment = value["environment"] as? Record,
      let updated = environment["updated"] as? String, !updated.isEmpty
    else { throw invalid() }
    if let schema = value["schemaVersion"], !(schema is NSNull) {
      guard let number = schema as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number == 1 else { throw invalid() }
    }
    var identities = Set<String>()
    func optional(_ object: Record, _ name: String) -> Any? {
      guard let field = object[name], !(field is NSNull) else { return nil }
      return field
    }
    func strings(_ object: Record, _ name: String) throws -> [String] {
      guard let field = optional(object, name) else { return [] }
      guard let values = field as? [String] else { throw invalid() }
      return values
    }
    func text(_ object: Record, _ name: String, fallback: String = "—") throws -> String {
      guard let field = optional(object, name) else { return fallback }
      guard let value = field as? String else { throw invalid() }
      return value
    }
    func number(_ object: Record, _ name: String) throws -> Any {
      guard let field = optional(object, name) else { return NSNull() }
      guard let value = field as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
        value.doubleValue.isFinite, value.doubleValue >= 0 else { throw invalid() }
      return value
    }
    func packages(_ records: [Record], type: String) throws -> [Record] {
      try records.map { original in
        var package = original
        guard let name = package["name"] as? String, HomebrewPackageName.isValid(name),
          package["type"] as? String == type,
          let version = package["version"] as? String, !version.isEmpty else { throw invalid() }
        let id = try text(package, "id", fallback: type + ":" + name)
        guard id.hasPrefix(type + ":"),
          HomebrewPackageName.isValid(String(id.dropFirst(type.count + 1))),
          identities.insert(id).inserted else { throw invalid() }
        package["id"] = id
        package["category"] = try text(package, "category", fallback: "Other")
        for field in ["displayName", "description", "homepage", "tap", "availableVersion"] {
          if let raw = optional(package, field), !(raw is String) { throw invalid() }
        }
        for field in ["dependencies", "usedBy", "paths", "installedVersions"] {
          package[field] = try strings(package, field)
        }
        for field in ["leaf", "direct", "deprecated", "appExpected"] {
          if let raw = optional(package, field) {
            guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID()
            else { throw invalid() }
          }
          package[field] = optional(package, field) ?? false
        }
        package["size"] = try number(package, "size")
        let apps = optional(package, "apps") ?? [Record]()
        guard let apps = apps as? [Record] else { throw invalid() }
        package["apps"] = try apps.map { original -> Record in
          var app = original
          guard let path = app["path"] as? String, !path.isEmpty else { throw invalid() }
          app["version"] = try text(app, "version")
          app["kib"] = try number(app, "kib")
          return app
        }
        return package
      }
    }
    value["formulae"] = try packages(formulae, type: "formula")
    value["casks"] = try packages(casks, type: "cask")
    for field in ["prefix", "brewVersion", "architecture", "macOS", "build"] {
      environment[field] = try text(environment, field)
    }
    for field in ["cellarSize", "caskSize"] { environment[field] = try number(environment, field) }
    value["environment"] = environment
    return value
  }
  static func save(_ value: [String: Any], to url: URL) throws {
    var snapshot = value
    snapshot["schemaVersion"] = 1
    let normalized = try normalize(snapshot)
    let data = try JSONSerialization.data(
      withJSONObject: normalized, options: [.sortedKeys, .prettyPrinted])
    try data.write(to: url, options: .atomic)
  }
  static func load(_ url: URL) throws -> [String: Any] {
    try decode(Data(contentsOf: url))
  }
  /// Internal cache metadata stays native; the web view only receives display data.
  static func displaySnapshot(_ value: Record) -> Record {
    var snapshot = value
    snapshot.removeValue(forKey: "sizeCache")
    return snapshot
  }
  static func migrateLegacy(to url: URL) throws {
    let legacy = url.deletingLastPathComponent().appendingPathComponent("homebrew-inventory.html")
    guard FileManager.default.fileExists(atPath: legacy.path) else { return }
    if !FileManager.default.fileExists(atPath: url.path) {
      let html = try String(contentsOf: legacy, encoding: .utf8)
      guard let start = html.range(of: "const brewData = "),
        let end = html.range(of: ";\n", range: start.upperBound..<html.endIndex)
      else {
        throw InventoryError(
          message: NSLocalizedString(
            "Could not read the data from the previous report.", comment: ""))
      }
      let value = try decode(Data(html[start.upperBound..<end.lowerBound].utf8))
      try save(value, to: url)
    }
    _ = try load(url)
    try FileManager.default.removeItem(at: legacy)
  }
}
