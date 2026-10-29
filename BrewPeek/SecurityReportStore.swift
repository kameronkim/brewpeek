import Foundation

/// A cancelled scan must not write after trust changes, even for the same inventory snapshot.
final class SecurityReportGeneration: Equatable {
  private let lock = NSLock()
  private var current = true
  static func == (lhs: SecurityReportGeneration, rhs: SecurityReportGeneration) -> Bool { lhs === rhs }
  func invalidate() {
    lock.lock(); defer { lock.unlock() }
    current = false
  }
  func withCurrent(_ action: () throws -> Bool) rethrows -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard current else { return false }
    return try action()
  }
}

/// Patch only the report belonging to this exact inventory; never overwrite a newer collection.
enum SecurityReportStore {
  static func update(_ report: Record, snapshotID: String, at url: URL, generation: SecurityReportGeneration? = nil) throws -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    return try HomebrewOperationLock.withLock(at: url, createDirectory: false) {
      let save = { () throws -> Bool in
        var snapshot = try InventoryStore.load(url)
        guard snapshot["snapshotID"] as? String == snapshotID else { return false }
        snapshot["securityCheck"] = report
        try InventoryStore.save(snapshot, to: url)
        return true
      }
      if let generation { return try generation.withCurrent(save) }
      return try save()
    }
  }
}
