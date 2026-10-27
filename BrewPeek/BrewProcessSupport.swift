import Darwin
import Foundation

/// Shared only between the UI cancellation action and the read-only preparation worker.
final class UpgradePreparation {
  private let lock = NSLock()
  private var cancelled = false
  private let stopLock = NSLock()
  private var currentProcess: Process?
  private var temporaryDirectory: URL?
  private let deadline: TimeInterval
  init(timeout: TimeInterval = 180) {
    deadline = ProcessInfo.processInfo.systemUptime + timeout
  }
  func cancel() {
    lock.lock()
    cancelled = true
    if let task = currentProcess, task.isRunning { task.terminate() }
    lock.unlock()
  }

  /// Launch and register atomically so cancellation cannot miss a just-started query.
  func start(_ task: Process, temporaryDirectory: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    try checkLocked()
    try task.run()
    currentProcess = task
    self.temporaryDirectory = temporaryDirectory
  }

  func finish(_ task: Process) {
    lock.lock()
    defer { lock.unlock() }
    guard currentProcess === task else { return }
    if let directory = temporaryDirectory { try? FileManager.default.removeItem(at: directory) }
    currentProcess = nil
    temporaryDirectory = nil
  }

  /// Used only for read-only preparation. Package mutations must never be interrupted here.
  func stop(_ task: Process) {
    stopLock.lock()
    defer { stopLock.unlock() }
    if task.isRunning {
      task.terminate()
      let deadline = ProcessInfo.processInfo.systemUptime + 0.5
      while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.02)
      }
      if task.isRunning { kill(task.processIdentifier, SIGKILL) }
    }
    task.waitUntilExit()
  }

  /// App termination waits for the owned query and removes its temporary output.
  func cancelAndWait() {
    lock.lock()
    cancelled = true
    let task = currentProcess
    lock.unlock()
    if let task {
      stop(task)
      finish(task)
    }
  }

  private func checkLocked() throws {
    if cancelled { throw InventoryError(message: "Package check cancelled.") }
    if ProcessInfo.processInfo.systemUptime >= deadline {
      throw InventoryError(message: "The package check timed out. Please try again.")
    }
  }

  func check() throws {
    lock.lock()
    defer { lock.unlock() }
    try checkLocked()
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

/// Progress hints only: dependency identities come from headings, never their version annotations.
struct HomebrewDependencyHeading {
  let parent: String
  let names: [String]

  private static let heading = try! NSRegularExpression(
    pattern: #"^(?:==>\s*)?(?:Installing|Upgrading) (?:dependencies for ([^:]+)|([^:]+) dependency):\s*(.+)$"#)
  private static let entry = try! NSRegularExpression(
    pattern: #"^([A-Za-z0-9][A-Za-z0-9@+_./-]*)(?:\s+(?:\([^()\r\n]*\)|[↑✔✓]))*$"#)

  static func parse(_ line: String) -> HomebrewDependencyHeading? {
    let text = line.replacingOccurrences(
      of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let whole = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = heading.firstMatch(in: text, range: whole) else { return nil }
    func capture(_ index: Int) -> String? {
      Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
    guard let parent = capture(1) ?? capture(2), HomebrewPackageName.isValid(parent),
      let body = capture(3) else { return nil }
    let summary = capture(1) != nil
    let entries = summary
      ? body.replacingOccurrences(of: #",\s*(?:and\s+)?|\s+and\s+"#, with: "\n", options: .regularExpression)
        .components(separatedBy: "\n")
      : [body]
    var seen = Set<String>()
    let names = entries.compactMap { value -> String? in
      let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let found = entry.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
        let range = Range(found.range(at: 1), in: value) else { return nil }
      let name = String(value[range])
      guard HomebrewPackageName.isValid(name),
        seen.insert(HomebrewPackageName.formulaIdentity(name)).inserted else { return nil }
      return name
    }
    return names.isEmpty ? nil : HomebrewDependencyHeading(parent: parent, names: names)
  }
}
