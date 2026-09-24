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
        throw InventoryError(message: "휴지통 이동 경로를 확인하지 못했습니다: " + url.path)
      }
      return destination as URL
    },
    restore: Restore = { from, to in try FileManager.default.moveItem(at: from, to: to) }
  ) throws {
    let fm = FileManager.default
    guard app.pathExtension == "app", reports.lastPathComponent == "BrewPeek" else {
      throw InventoryError(message: "제거 대상 경로를 확인하지 못했습니다.")
    }
    let hasReports = fm.fileExists(atPath: reports.path)
    var lock: Int32 = -1
    if hasReports {
      let values = try reports.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
      guard values.isSymbolicLink != true, values.isDirectory == true else {
        throw InventoryError(message: "보고서 폴더가 일반 폴더가 아니므로 제거를 중단했습니다.")
      }
      lock = open(
        reports.appendingPathComponent(".homebrew-report.lock").path, O_CREAT | O_RDWR, 0o600)
      guard lock >= 0 else { throw InventoryError(message: "보고서 폴더를 잠글 수 없어 제거를 중단했습니다.") }
      guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        close(lock)
        throw InventoryError(message: "보고서 생성이 진행 중입니다. 완료 후 다시 시도해 주세요.")
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
            "보고서 폴더 제거에 실패했고 앱 복원도 완료하지 못했습니다.\n보고서는 원래 위치에 남아 있습니다.\n앱 위치: \(trashedApp.path)\n보고서 오류: \(original)\n복원 오류: \(error.localizedDescription)"
        )
      }
      throw InventoryError(message: "보고서 폴더 제거에 실패하여 앱을 원래 위치로 복원했습니다.\n" + original)
    }
  }
}
