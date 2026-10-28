import Foundation

/// Patch only the report belonging to this exact inventory; never overwrite a newer collection.
enum SecurityReportStore {
  static func update(_ report: Record, snapshotID: String, at url: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    return try HomebrewOperationLock.withLock(at: url, createDirectory: false) {
      var snapshot = try InventoryStore.load(url)
      guard snapshot["snapshotID"] as? String == snapshotID else { return false }
      snapshot["securityCheck"] = report
      try InventoryStore.save(snapshot, to: url)
      return true
    }
  }
}
