import Darwin
import Foundation

/// One identifier policy for installed metadata and confirmed package operations.
enum HomebrewPackageName {
  static func isValid(_ name: String) -> Bool {
    name.range(
      of: #"^[a-zA-Z0-9][a-zA-Z0-9@+_.-]*(/[a-zA-Z0-9][a-zA-Z0-9@+_.-]*){0,2}$"#,
      options: .regularExpression) != nil
  }
}

/// Inventory collection and package operations share one nonblocking file lock.
enum HomebrewOperationLock {
  static func withLock<T>(
    at inventory: URL,
    openError: String = "Could not open the operation lock.",
    busyError: String = "Another BrewPeek operation is running. Try again when it finishes.",
    _ action: () throws -> T
  ) throws -> T {
    let directory = inventory.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fd = open(
      directory.appendingPathComponent(".homebrew-report.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw InventoryError(message: openError) }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      throw InventoryError(message: busyError)
    }
    defer { flock(fd, LOCK_UN) }
    return try action()
  }
}
