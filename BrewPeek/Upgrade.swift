import Darwin
import Foundation

struct UpgradePackage {
  let name: String
  let fullName: String
  let type: String
  let current: [String]
  let next: String
  let receipt: String
  let apps: [String]
  var reason: String
  var id: String { type + ":" + fullName }
  var argument: String {
    fullName.contains("/")
      ? fullName : "homebrew/" + (type == "cask" ? "cask/" : "core/") + fullName
  }
  var record: Record {
    [
      "id": id, "name": name, "type": type, "version": current.joined(separator: ", "),
      "availableVersion": next, "action": current.isEmpty ? "install" : "update", "reason": reason,
    ]
  }
}
struct UpgradePlan {
  let token = UUID().uuidString
  let selected: [UpgradePackage]
  let packages: [UpgradePackage]
  let output: String
  let excluded: [String]
  var fingerprint: [String] {
    packages.map { $0.id + "|" + $0.current.joined(separator: ",") + "|" + $0.next }.sorted()
  }
  var record: Record {
    [
      "token": token, "selectedCount": selected.count, "packages": packages.map(\.record),
      "details": output, "excluded": excluded,
    ]
  }
}

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

/// All commands run off the main thread. Arguments come from Homebrew metadata, never shell text.
final class Upgrade {
  let inventory: Inventory
  init(brew: String) { inventory = Inventory(brew: brew) }
  static func validName(_ name: String) -> Bool {
    name.range(
      of: #"^[a-zA-Z0-9][a-zA-Z0-9@+_.-]*(/[a-zA-Z0-9][a-zA-Z0-9@+_.-]*){0,2}$"#,
      options: .regularExpression) != nil
  }
  private func commandEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for name in [
      "HOMEBREW_NO_AUTO_UPDATE", "HOMEBREW_NO_API_AUTO_UPDATE", "HOMEBREW_NO_ANALYTICS",
      "HOMEBREW_NO_INSTALL_CLEANUP", "HOMEBREW_NO_ASK", "HOMEBREW_NO_UPGRADE_QUIT_CASKS",
    ] { env[name] = "1" }
    env["HOMEBREW_DOWNLOAD_CONCURRENCY"] = "auto"
    env["SUDO_ASKPASS"] = "/usr/bin/false"
    env["TERM"] = "dumb"
    env["NO_COLOR"] = "1"
    env["PATH"] =
      URL(fileURLWithPath: inventory.brew).deletingLastPathComponent().path
      + ":/usr/bin:/bin:/usr/sbin:/sbin"
    return env
  }
  /// File-backed output lets cancellation interrupt silent commands without waiting for pipe EOF.
  /// Only info and upgrade --dry-run are accepted; mutating execution uses command() instead.
  func readOnly(_ arguments: [String], control: UpgradePreparation, combinedOutput: Bool = false)
    throws -> String
  {
    guard
      arguments.first == "info" || (arguments.first == "upgrade" && arguments.contains("--dry-run"))
    else {
      throw InventoryError(message: "Invalid preparation command.")
    }
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
    task.executableURL = URL(fileURLWithPath: inventory.brew)
    task.arguments = arguments
    task.environment = commandEnvironment()
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = out
    task.standardError = combinedOutput ? out : err
    try task.run()
    do {
      while task.isRunning {
        try control.check()
        Thread.sleep(forTimeInterval: 0.05)
      }
      task.waitUntilExit()
      try control.check()
    } catch {
      if task.isRunning {
        task.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.5
        while task.isRunning && ProcessInfo.processInfo.systemUptime < grace {
          Thread.sleep(forTimeInterval: 0.02)
        }
        if task.isRunning { kill(task.processIdentifier, SIGKILL) }
      }
      task.waitUntilExit()
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
  func command(_ arguments: [String], streaming: ((String) -> Void)? = nil) throws -> (
    Int32, String
  ) {
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: inventory.brew)
    task.arguments = arguments
    task.environment = commandEnvironment()
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = pipe
    task.standardError = pipe
    try task.run()
    // Read continuously, draining both streams together. Never timeout/kill an installation.
    var pending = Data()
    var output = ""
    while true {
      let chunk = pipe.fileHandleForReading.availableData
      if chunk.isEmpty { break }
      pending.append(chunk)
      if pending.count > 262_144 {
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        output += line
        streaming?(line)
      }
      while let end = pending.firstIndex(of: 10) {
        let line = String(decoding: pending[..<end], as: UTF8.self).replacingOccurrences(
          of: "\r", with: "")
        pending.removeSubrange(...end)
        output += line + "\n"
        if output.utf8.count > 1_000_000 { output = String(output.suffix(500_000)) }
        streaming?(line)
      }
    }
    if !pending.isEmpty {
      let line = String(decoding: pending, as: UTF8.self)
      output += line
      streaming?(line)
    }
    task.waitUntilExit()
    try? pipe.fileHandleForReading.close()
    return (task.terminationStatus, output)
  }
  func json(_ arguments: [String], control: UpgradePreparation? = nil) throws -> Record {
    let text =
      try control.map { try readOnly(arguments, control: $0) }
      ?? inventory.run(inventory.brew, arguments)
    guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? Record else {
      throw InventoryError(message: "Homebrew returned invalid package information.")
    }
    return object
  }
  static func packages(_ info: Record) -> [UpgradePackage] {
    var result: [UpgradePackage] = []
    for f in info["formulae"] as? [Record] ?? [] {
      guard let name = f["name"] as? String else { continue }
      let full = f["full_name"] as? String ?? name
      let installed = f["installed"] as? [Record] ?? []
      let revision = f["revision"] as? Int ?? 0
      let stable = (f["versions"] as? Record)?["stable"] as? String ?? ""
      result.append(
        UpgradePackage(
          name: name, fullName: full, type: "formula",
          current: installed.compactMap { $0["version"] as? String },
          next: stable + (revision > 0 ? "_\(revision)" : ""),
          receipt: installed.map { String(describing: $0["time"] ?? "") }.joined(separator: ","),
          apps: [], reason: "Dependency"))
    }
    for c in info["casks"] as? [Record] ?? [] {
      guard let name = c["token"] as? String else { continue }
      let full = c["full_token"] as? String ?? name
      let versions = c["installed"] as? [String] ?? (c["installed"] as? String).map { [$0] } ?? []
      let apps = (c["artifacts"] as? [Record] ?? []).compactMap {
        ($0["app"] as? [Any])?.first as? String
      }
      result.append(
        UpgradePackage(
          name: name, fullName: full, type: "cask", current: versions,
          next: c["version"] as? String ?? "",
          receipt: String(describing: c["installed_time"] ?? ""), apps: apps, reason: "Dependency"))
    }
    return result
  }
  func installed(control: UpgradePreparation? = nil) throws -> [UpgradePackage] {
    Self.packages(try json(["info", "--json=v2", "--installed"], control: control))
  }
  /// Read only recognized plan blocks, then resolve every name through Homebrew JSON.
  static func plannedNames(_ text: String) throws -> [String] {
    var names = Set<String>()
    var block = false
    var expected = 0
    var count = 0
    func validateBlock() throws {
      if block && count < expected {
        throw InventoryError(
          message: "Homebrew returned an incomplete update plan. Refresh and try again.\n" + text)
      }
    }
    for raw in text.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("==>") {
        try validateBlock()
        block =
          line.range(
            of:
              #"Would (upgrade|install|reinstall) \d+ (requested |outdated |dependent )*(package|formula|formulae|cask|dependen)"#,
            options: .regularExpression) != nil
        expected = block ? Int(line.split(separator: " ").dropFirst(3).first ?? "0") ?? 0 : 0
        count = 0
        if !block
          && line.range(
            of: #"^==> Would (upgrade|install|reinstall) "#, options: .regularExpression) != nil
        {
          throw InventoryError(
            message: "This Homebrew update plan format is not supported.\n" + text)
        }
        continue
      }
      if line.isEmpty {
        try validateBlock()
        block = false
        continue
      }
      guard block else { continue }
      if line.hasPrefix("Disable ") || line.hasPrefix("Hide ") { continue }
      if line.hasPrefix("Warning:") { continue }
      if line.hasPrefix("Error:") {
        throw InventoryError(message: "Homebrew reported an error in the update plan.\n" + text)
      }
      let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
      let candidates =
        parts.contains("->") || (parts.count > 1 && parts[1].first?.isNumber == true)
        ? Array(parts.prefix(1)) : parts
      for name in candidates {
        guard validName(name) else {
          throw InventoryError(message: "Could not read Homebrew's update plan.\n" + text)
        }
        names.insert(name)
        count += 1
      }
    }
    try validateBlock()
    return names.sorted()
  }
  func prepare(keys: [String], control: UpgradePreparation = UpgradePreparation()) throws
    -> UpgradePlan
  {
    let installed = try installed(control: control)
    let selected = try keys.map { id -> UpgradePackage in
      guard var package = installed.first(where: { $0.id == id }), Self.validName(package.fullName)
      else {
        throw InventoryError(
          message: "The selected package is no longer installed. Refresh and try again.")
      }
      package.reason = "Selected"
      return package
    }
    guard !selected.isEmpty, Set(keys).count == keys.count else {
      throw InventoryError(message: "Select at least one package.")
    }
    let output = try readOnly(
      ["upgrade", "--dry-run", "--no-ask"] + selected.map(\.argument), control: control,
      combinedOutput: true)
    let names = try Self.plannedNames(output)
    guard !names.isEmpty else {
      throw InventoryError(
        message:
          "Homebrew found no changes to apply. The package may already be current or pinned. Refresh to check its status.\n"
          + output)
    }
    let arguments = names.flatMap { name -> [String] in
      let matches = selected.filter { $0.fullName == name || $0.name == name }
      return matches.isEmpty ? [name] : matches.map(\.argument)
    }
    let metadata = try json(["info", "--json=v2"] + arguments, control: control)
    var packages = Self.packages(metadata)
    guard !packages.isEmpty,
      packages.allSatisfy({ Self.validName($0.fullName) && !$0.next.isEmpty })
    else {
      throw InventoryError(message: "Could not resolve the versions in Homebrew's update plan.")
    }
    var seen = Set<String>()
    packages = packages.filter { seen.insert($0.id).inserted }.map { p in
      var p = p
      p.reason =
        selected.contains(where: { $0.id == p.id })
        ? "Selected" : p.current.isEmpty ? "New dependency" : "Related package"
      return p
    }
    let actionable = selected.filter { p in packages.contains(where: { $0.id == p.id }) }
    guard !actionable.isEmpty else {
      throw InventoryError(
        message:
          "Homebrew excluded the selected packages from the update plan. They may already be current or pinned.\n"
          + output)
    }
    return UpgradePlan(
      selected: actionable, packages: packages, output: output,
      excluded: selected.filter { p in !actionable.contains(where: { $0.id == p.id }) }.map(\.name))
  }

  func execute(_ plan: UpgradePlan, event: @escaping (Record) -> Void) throws -> Record {
    let before = try installed()
    var items = plan.packages
    var states = Dictionary(uniqueKeysWithValues: items.map { ($0.id, "Waiting for Homebrew") })
    var touched = Set<String>()
    var bufferedLines: [String] = []
    var lastEvent = Date.distantPast
    event(["kind": "progress", "packages": items.map(\.record), "states": states, "processed": 0])
    let result = try command(["upgrade", "--no-ask"] + plan.selected.map(\.argument)) { line in
      if let range = line.range(
        of: #"Installing (?:.* dependency: |dependencies for [^:]+: )"#, options: .regularExpression
      ) {
        for candidate in line[range.upperBound...].components(separatedBy: ", ") {
          let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
          if Self.validName(name),
            !items.contains(where: { $0.name == name || $0.fullName == name })
          {
            let old = before.first(where: {
              $0.type == "formula" && ($0.name == name || $0.fullName == name)
            })
            let item = UpgradePackage(
              name: name, fullName: old?.fullName ?? name, type: "formula",
              current: old?.current ?? [], next: "", receipt: old?.receipt ?? "", apps: [],
              reason: "Detected during execution")
            items.append(item)
            states[item.id] = "Waiting for Homebrew"
          }
        }
      }
      // Output is activity, not proof of success. Percentages are intentionally not inferred.
      for p in items
      where line.range(
        of: "(?<![A-Za-z0-9@+_.-])" + NSRegularExpression.escapedPattern(for: p.name)
          + "(?![A-Za-z0-9@+_.-])", options: .regularExpression) != nil
      {
        if line.contains("Installing") || line.contains("Upgrading") || line.contains("Pouring") {
          states[p.id] = "Installing…"
          touched.insert(p.id)
        } else if line.contains("Downloading") || line.contains("Fetching") {
          states[p.id] = "Downloading…"
        } else if line.contains("successfully") || line.contains("🍺") {
          states[p.id] = "Awaiting verification"
          touched.insert(p.id)
        }
      }
      bufferedLines.append(line)
      if Date().timeIntervalSince(lastEvent) >= 0.1 {
        event([
          "kind": "activity", "line": bufferedLines.joined(separator: "\n"),
          "packages": items.map(\.record), "states": states,
          "processed": states.values.filter { $0 == "Awaiting verification" }.count,
        ])
        bufferedLines.removeAll()
        lastEvent = Date()
      }
    }
    if !bufferedLines.isEmpty {
      event([
        "kind": "activity", "line": bufferedLines.joined(separator: "\n"),
        "packages": items.map(\.record), "states": states,
        "processed": states.values.filter { $0 == "Awaiting verification" }.count,
      ])
    }
    event(["kind": "verifying"])
    let after: [UpgradePackage]
    do { after = try installed() } catch {
      return [
        "kind": "result",
        "packages": items.map { p -> Record in
          var r = p.record
          r["outcome"] = "attention"
          r["message"] = "Could not verify installed version"
          return r
        }, "details": result.1 + "\n" + error.localizedDescription, "verified": false,
      ]
    }
    items = items.map { p in
      guard p.next.isEmpty else { return p }
      let matches = after.filter { $0.type == p.type && ($0.id == p.id || $0.name == p.name) }
      guard matches.count == 1, let actual = matches.first else { return p }
      return UpgradePackage(
        name: actual.name, fullName: actual.fullName, type: actual.type, current: p.current,
        next: actual.current.last ?? "", receipt: p.receipt, apps: actual.apps, reason: p.reason)
    }
    var identities = Set<String>()
    items = items.filter { identities.insert($0.id).inserted }
    for p in after where !items.contains(where: { $0.id == p.id }) {
      let old = before.first(where: { $0.id == p.id })
      if old == nil || old!.current != p.current || old!.receipt != p.receipt {
        items.append(
          UpgradePackage(
            name: p.name, fullName: p.fullName, type: p.type, current: old?.current ?? [],
            next: p.current.last ?? p.next, receipt: old?.receipt ?? "", apps: p.apps,
            reason: "Detected during execution"))
      }
    }
    let records: [Record] = items.map { p in
      var r = p.record
      let actual = after.first { $0.id == p.id }
      let expected = p.next.isEmpty ? actual?.current.last ?? "" : p.next
      r["availableVersion"] = expected
      let verified =
        actual?.current.contains(expected) == true
        && (p.current != actual!.current || p.receipt != actual!.receipt)
      let outcome: String
      let message: String
      if verified {
        outcome = p.current.isEmpty ? "installed" : "updated"
        message = p.current.isEmpty ? "Installed" : "Updated"
      } else if result.0 == 0 {
        outcome = "attention"
        message = "Expected installed version could not be verified"
      } else if result.1.localizedCaseInsensitiveContains("sudo")
        || result.1.localizedCaseInsensitiveContains("permission")
        || result.1.localizedCaseInsensitiveContains("password")
      {
        outcome = "attention"
        message = "May require administrator permission. Review activity and use Terminal."
      } else {
        outcome = touched.contains(p.id) ? "failed" : "skipped"
        message =
          touched.contains(p.id)
          ? "Update failed. Review activity."
          : "Not updated. Homebrew did not complete this package."
      }
      r["outcome"] = outcome
      r["message"] = message
      r["actualVersion"] = actual?.current.joined(separator: ", ") ?? "Not installed"
      return r
    }
    return [
      "kind": "result", "packages": records, "details": result.1, "verified": true,
      "exitCode": result.0,
    ]
  }
  static func withLock<T>(at output: URL, _ action: () throws -> T) throws -> T {
    let dir = output.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fd = open(dir.appendingPathComponent(".homebrew-report.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw InventoryError(message: "Could not open the operation lock.") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      throw InventoryError(
        message: "Another BrewPeek operation is running. Try again when it finishes.")
    }
    defer { flock(fd, LOCK_UN) }
    return try action()
  }
}
