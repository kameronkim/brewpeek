import Foundation
import WebKit

struct PackageNotes {
  let file: URL

  func read() throws -> [String: String] {
    do {
      return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return [:]
    }
  }

  func save(id: String, text: String) throws -> String {
    let parts = id.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, ["formula", "cask"].contains(parts[0]),
      HomebrewPackageName.isValid(String(parts[1])), text.utf16.count <= 300
    else { throw InventoryError(message: "Invalid package note.") }
    return try HomebrewOperationLock.withLock(
      at: file, lockName: ".package-notes.lock", busyError: "Another note is being saved. Try again."
    ) {
      var notes = try read()
      let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
      notes[id] = value.isEmpty ? nil : value
      try JSONEncoder().encode(notes).write(to: file, options: .atomic)
      return value
    }
  }
}

/// Notes use a separate file and queue so a Homebrew refresh cannot replace or block a note.
final class PackageNotesBridge: NSObject, WKScriptMessageHandlerWithReply {
  private let page: URL
  private let store: PackageNotes
  private let queue = DispatchQueue(label: "BrewPeek.PackageNotes")

  init(page: URL, directory: URL) {
    self.page = page.standardizedFileURL
    store = PackageNotes(file: directory.appendingPathComponent("notes.json"))
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping (Any?, String?) -> Void
  ) {
    guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.standardizedFileURL == page,
      let request = message.body as? Record
    else { replyHandler(nil, "Invalid note request."); return }
    queue.async { [store] in
      do {
        let response: Any
        switch request["action"] as? String {
        case "load": response = try store.read()
        case "save":
          guard let id = request["id"] as? String, let text = request["text"] as? String
          else { throw InventoryError(message: "Invalid note request.") }
          response = try store.save(id: id, text: text)
        default: throw InventoryError(message: "Unknown note request.")
        }
        DispatchQueue.main.async { replyHandler(response, nil) }
      } catch {
        DispatchQueue.main.async { replyHandler(nil, error.localizedDescription) }
      }
    }
  }
}
