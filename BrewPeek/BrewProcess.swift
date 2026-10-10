import Darwin
import Foundation

/// Execute Homebrew commands with separate preparation and mutation policies.
final class BrewProcess {
  let brew: String
  init(brew: String) { self.brew = brew }
  private func commandEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for name in [
      "HOMEBREW_NO_AUTO_UPDATE", "HOMEBREW_NO_API_AUTO_UPDATE", "HOMEBREW_NO_ANALYTICS",
      "HOMEBREW_NO_ASK", "HOMEBREW_NO_UPGRADE_QUIT_CASKS",
    ] { env[name] = "1" }
    env["HOMEBREW_DOWNLOAD_CONCURRENCY"] = "auto"
    env["SUDO_ASKPASS"] = "/usr/bin/false"
    env["TERM"] = "dumb"
    env["NO_COLOR"] = "1"
    env["PATH"] =
      URL(fileURLWithPath: brew).deletingLastPathComponent().path
      + ":/usr/bin:/bin:/usr/sbin:/sbin"
    return env
  }
  /// File-backed output lets cancellation interrupt silent commands without waiting for pipe EOF.
  /// Only metadata queries and upgrade --dry-run are accepted; mutations use command() instead.
  func readOnly(
    _ arguments: [String], control: UpgradePreparation, combinedOutput: Bool = false,
    environmentOverrides: [String: String] = [:]
  )
    throws -> String
  {
    guard
      arguments.first == "info" || arguments == ["--caskroom"]
        || (arguments.first == "upgrade" && arguments.contains("--dry-run"))
    else {
      throw InventoryError(message: "Invalid preparation command.")
    }
    return try runPreparation(
      arguments, control: control, combinedOutput: combinedOutput,
      environmentOverrides: environmentOverrides)
  }
  /// Called only with the bundled read-only dependency projection, never with web-provided code.
  func dependencyProjection(_ script: String, control: UpgradePreparation) throws -> String {
    try runPreparation(
      ["ruby", "-e", script], control: control,
      environmentOverrides: ["HOMEBREW_DEV_CMD_RUN": "1"])
  }
  private func runPreparation(
    _ arguments: [String], control: UpgradePreparation,
    combinedOutput: Bool = false, environmentOverrides: [String: String] = [:]
  ) throws -> String {
    try control.check()
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("brewpeek-prepare-" + UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let outURL = dir.appendingPathComponent("stdout")
    let errURL = dir.appendingPathComponent("stderr")
    fm.createFile(atPath: outURL.path, contents: nil)
    fm.createFile(atPath: errURL.path, contents: nil)
    let out = try FileHandle(forWritingTo: outURL)
    let err = try FileHandle(forWritingTo: errURL)
    defer {
      try? out.close()
      try? err.close()
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: brew)
    task.arguments = arguments
    task.environment = commandEnvironment().merging(environmentOverrides) { _, override in override
    }
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = out
    task.standardError = combinedOutput ? out : err
    try control.start(task, temporaryDirectory: dir)
    defer { control.finish(task) }
    do {
      while task.isRunning {
        try control.check()
        Thread.sleep(forTimeInterval: 0.05)
      }
      task.waitUntilExit()
      try control.check()
    } catch {
      control.stop(task)
      throw error
    }
    let output = try String(contentsOf: outURL, encoding: .utf8)
    guard task.terminationStatus == 0 else {
      let detail = combinedOutput ? output : try String(contentsOf: errURL, encoding: .utf8)
      throw InventoryError(
        message: detail.isEmpty ? "Homebrew could not check the update plan." : detail)
    }
    return output
  }
  func command(
    _ arguments: [String], environmentOverrides: [String: String] = [:],
    streaming: ((String) -> Void)? = nil
  ) throws -> (
    Int32, String
  ) {
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: brew)
    task.arguments = arguments
    var environment = commandEnvironment().merging(environmentOverrides) { _, override in override
    }
    var authenticationDirectory: URL?
    defer {
      if let directory = authenticationDirectory { try? FileManager.default.removeItem(at: directory) }
    }
    // Homebrew sanitizes arbitrary environment variables; the private askpass link identifies
    // this one confirmed operation. The request file contains no credentials.
    if ["upgrade", "uninstall"].contains(arguments.first ?? ""),
      !arguments.contains("--dry-run"), let executable = Bundle.main.executableURL
    {
      let helper = executable.deletingLastPathComponent().appendingPathComponent("BrewPeekAskpass")
      if FileManager.default.isExecutableFile(atPath: helper.path) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
          "brewpeek-auth-" + UUID().uuidString)
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        authenticationDirectory = directory
        var info = proc_bsdinfo()
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info,
          Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size)
        else { throw InventoryError(message: "Could not prepare administrator authentication.") }
        let request: Record = ["pid": getpid(), "started": info.pbi_start_tvsec,
          "microseconds": info.pbi_start_tvusec, "operation": arguments.joined(separator: " ")]
        let file = directory.appendingPathComponent("request.json")
        try JSONSerialization.data(withJSONObject: request).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let link = directory.appendingPathComponent("askpass")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
        environment["SUDO_ASKPASS"] = link.path
      }
    }
    task.environment = environment
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = pipe
    task.standardError = pipe
    try task.run()
    // Read continuously, draining both streams together. Never timeout/kill an installation.
    var pending = Data()
    var output = UpdateLogBuffer()
    while true {
      let chunk = pipe.fileHandleForReading.availableData
      if chunk.isEmpty { break }
      pending.append(chunk)
      if pending.count > 262_144 {
        var end = pending.index(pending.startIndex, offsetBy: 262_144)
        while end > pending.startIndex && pending[end] & 0xc0 == 0x80 {
          end = pending.index(before: end)
        }
        if end == pending.startIndex { end = pending.index(pending.startIndex, offsetBy: 262_144) }
        let line = String(decoding: pending[..<end], as: UTF8.self)
        pending.removeSubrange(..<end)
        output.append(line)
        streaming?(line)
      }
      while let end = pending.firstIndex(of: 10) {
        let line = String(decoding: pending[..<end], as: UTF8.self).replacingOccurrences(
          of: "\r", with: "")
        pending.removeSubrange(...end)
        output.append(line + "\n")
        streaming?(line)
      }
    }
    if !pending.isEmpty {
      let line = String(decoding: pending, as: UTF8.self)
      output.append(line)
      streaming?(line)
    }
    task.waitUntilExit()
    if let directory = authenticationDirectory,
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled").path)
    {
      output.append("\nAdministrator authentication cancelled. Retry when ready.\n")
    }
    try? pipe.fileHandleForReading.close()
    return (task.terminationStatus, output.text)
  }
}
