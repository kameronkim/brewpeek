import Darwin
import Foundation

struct DesktopRemoval {
  typealias Trash = (URL) throws -> URL
  typealias Restore = (URL, URL) throws -> Void
  static func remove(
    app: URL, reports: URL,
    trash: Trash = { url in
      var destination: NSURL?
      try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
      guard let destination = destination else {
        throw InventoryError(
          message: NSLocalizedString("Could not determine the location in the Trash: ", comment: "")
            + url.path)
      }
      return destination as URL
    },
    restore: Restore = { from, to in try FileManager.default.moveItem(at: from, to: to) }
  ) throws {
    let fm = FileManager.default
    guard app.pathExtension == "app", reports.lastPathComponent == "BrewPeek" else {
      throw InventoryError(
        message: NSLocalizedString("Could not verify the paths to remove.", comment: ""))
    }
    let hasReports = fm.fileExists(atPath: reports.path)
    var lock: Int32 = -1
    if hasReports {
      let values = try reports.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
      guard values.isSymbolicLink != true, values.isDirectory == true else {
        throw InventoryError(
          message: NSLocalizedString(
            "Removal stopped because the data folder is not a regular directory.", comment: ""))
      }
      lock = open(
        reports.appendingPathComponent(".homebrew-report.lock").path, O_CREAT | O_RDWR, 0o600)
      guard lock >= 0 else {
        throw InventoryError(
          message: NSLocalizedString(
            "Removal stopped because the data folder could not be locked.", comment: ""))
      }
      guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        close(lock)
        throw InventoryError(
          message: NSLocalizedString(
            "The inventory is being collected. Please try again when it finishes.", comment: ""))
      }
    }
    defer {
      if lock >= 0 {
        flock(lock, LOCK_UN)
        close(lock)
      }
    }
    // Move the app first. If this fails, the existing report remains untouched.
    let trashedApp = try trash(app)
    guard hasReports else { return }
    do { _ = try trash(reports) } catch {
      let original = error.localizedDescription
      do { try restore(trashedApp, app) } catch {
        throw InventoryError(
          message:
            String(
              format: NSLocalizedString(
                "Could not remove the data folder or restore the app.\nYour data remains in its original location.\nApp location: %1$@\nData error: %2$@\nRestore error: %3$@",
                comment: "App path, data removal error, restoration error"), trashedApp.path,
              original, error.localizedDescription)
        )
      }
      throw InventoryError(
        message: NSLocalizedString(
          "Could not remove the data folder. The app was restored to its original location.\n",
          comment: "") + original)
    }
  }
}
