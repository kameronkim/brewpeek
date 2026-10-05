import Foundation

/// Shared only between the UI cancellation action and the read-only preparation worker.
final class UpgradePreparation {
  private let lock = NSLock()
  private var cancelled = false
  private let deadline: TimeInterval
  init(timeout: TimeInterval = 180) {
    deadline = ProcessInfo.processInfo.systemUptime + timeout
  }
  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
  func check() throws {
    lock.lock()
    let stopped = cancelled
    lock.unlock()
    if stopped { throw InventoryError(message: "Update check cancelled.") }
    if ProcessInfo.processInfo.systemUptime >= deadline {
      throw InventoryError(message: "The update check timed out. Check your connection and retry.")
    }
  }
}

/// Keep recent activity in a byte-bounded buffer without splitting a UTF-8 scalar.
struct UpdateLogBuffer {
  private static let byteLimit = 1_000_000
  private var bytes = Data()
  var isEmpty: Bool { bytes.isEmpty }
  var text: String { String(decoding: bytes, as: UTF8.self) }

  mutating func append(_ text: String) {
    bytes.append(contentsOf: text.utf8)
    if bytes.count > Self.byteLimit {
      // Trim in batches to avoid copying the entire buffer for every new line.
      bytes = Data(bytes.suffix(Self.byteLimit / 2).drop(while: { $0 & 0xc0 == 0x80 }))
    }
  }
  mutating func removeAll() { bytes.removeAll(keepingCapacity: true) }
}

/// Compile each package-name boundary pattern once per operation, including newly discovered names.
struct PackageActivityMatcher {
  private var patterns: [String: NSRegularExpression] = [:]

  mutating func matches(_ name: String, in line: String) -> Bool {
    let pattern: NSRegularExpression
    if let cached = patterns[name] {
      pattern = cached
    } else {
      let expression = "(?<![A-Za-z0-9@+_.-])" + NSRegularExpression.escapedPattern(for: name)
        + "(?![A-Za-z0-9@+_.-])"
      guard let compiled = try? NSRegularExpression(pattern: expression) else { return false }
      patterns[name] = compiled
      pattern = compiled
    }
    return pattern.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil
  }
}
