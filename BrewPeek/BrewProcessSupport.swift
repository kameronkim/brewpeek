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
