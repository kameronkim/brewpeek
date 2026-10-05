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
  var dependencies: [String] = []
  var relationship: String = ""
  var id: String { type + ":" + fullName }
  var argument: String {
    fullName.contains("/")
      ? fullName : "homebrew/" + (type == "cask" ? "cask/" : "core/") + fullName
  }
  var record: Record {
    [
      "id": id, "name": name, "type": type, "version": current.joined(separator: ", "),
      "availableVersion": next, "action": current.isEmpty ? "install" : "update", "reason": reason,
      "relationship": relationship,
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

/// All commands run off the main thread. Arguments come from Homebrew metadata, never shell text.
final class Upgrade {
  let inventory: Inventory
  private var caskroom: String?
  private let process: BrewProcess
  private(set) var latestInstalledInfo: Record?
  init(brew: String) {
    inventory = Inventory(brew: brew)
    process = BrewProcess(brew: brew)
  }
  static func validName(_ name: String) -> Bool {
    name.range(
      of: #"^[a-zA-Z0-9][a-zA-Z0-9@+_.-]*(/[a-zA-Z0-9][a-zA-Z0-9@+_.-]*){0,2}$"#,
      options: .regularExpression) != nil
  }
  func readOnly(
    _ arguments: [String], control: UpgradePreparation, combinedOutput: Bool = false,
    environmentOverrides: [String: String] = [:]
  ) throws -> String {
    try process.readOnly(arguments, control: control, combinedOutput: combinedOutput,
      environmentOverrides: environmentOverrides)
  }
  func dependencyProjection(_ script: String, control: UpgradePreparation) throws -> String {
    try process.dependencyProjection(script, control: control)
  }
  func command(
    _ arguments: [String], environmentOverrides: [String: String] = [:],
    streaming: ((String) -> Void)? = nil
  ) throws -> (Int32, String) {
    latestInstalledInfo = nil
    return try process.command(
      arguments, environmentOverrides: environmentOverrides, streaming: streaming)
  }
  func json(_ arguments: [String], control: UpgradePreparation? = nil) throws -> Record {
    if arguments == ["info", "--json=v2", "--installed"] {
      return try installedMetadata(control: control).raw
    }
    return try readJSON(arguments, control: control)
  }
  private func readJSON(_ arguments: [String], control: UpgradePreparation?) throws -> Record {
    let text =
      try control.map { try readOnly(arguments, control: $0) }
      ?? inventory.run(inventory.brew, arguments)
    guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? Record else {
      throw InventoryError(message: "Homebrew returned invalid package information.")
    }
    return object
  }
  /// Validate once, retaining the raw snapshot for inventory and typed fields for operations.
  func installedMetadata(control: UpgradePreparation? = nil) throws
    -> (raw: Record, installed: InstalledPackageInfo)
  {
    latestInstalledInfo = nil
    let raw = try readJSON(["info", "--json=v2", "--installed"], control: control)
    let installed = try Inventory.validateInstalledInfo(raw)
    latestInstalledInfo = raw
    return (raw, installed)
  }
  /// Plan metadata may describe new dependencies with no installed receipts.
  static func packages(_ info: Record, caskroom: String? = nil) -> [UpgradePackage] {
    let formulae = (info["formulae"] as? [Record] ?? []).compactMap { raw -> InstalledFormulaInfo? in
      guard let name = raw["name"] as? String else { return nil }
      let receipts = raw["installed"] as? [Record] ?? []
      return InstalledFormulaInfo(
        raw: raw, name: name, fullName: raw["full_name"] as? String ?? name,
        receipts: receipts, versions: receipts.compactMap { $0["version"] as? String })
    }
    let casks = (info["casks"] as? [Record] ?? []).compactMap { raw -> InstalledCaskInfo? in
      guard let name = raw["token"] as? String else { return nil }
      let versions = raw["installed"] as? [String]
        ?? (raw["installed"] as? String).map { [$0] } ?? []
      return InstalledCaskInfo(
        raw: raw, name: name, fullName: raw["full_token"] as? String ?? name, versions: versions)
    }
    return packages(InstalledPackageInfo(formulae: formulae, casks: casks), caskroom: caskroom)
  }
  static func packages(_ info: InstalledPackageInfo, caskroom: String? = nil) -> [UpgradePackage] {
    var result: [UpgradePackage] = []
    for item in info.formulae {
      let f = item.raw
      let installed = item.receipts
      let revision = f["revision"] as? Int ?? 0
      let stable = (f["versions"] as? Record)?["stable"] as? String ?? ""
      let dependencies =
        f["dependencies"] as? [String]
        ?? installed.flatMap {
          ($0["runtime_dependencies"] as? [Record] ?? []).filter {
            $0["declared_directly"] as? Bool == true
          }.compactMap { $0["full_name"] as? String }
        }
      result.append(
        UpgradePackage(
          name: item.name, fullName: item.fullName, type: "formula",
          current: item.versions,
          next: stable + (revision > 0 ? "_\(revision)" : ""),
          receipt: installed.map { String(describing: $0["time"] ?? "") }.joined(separator: ","),
          apps: [], reason: "Dependency",
          dependencies: dependencies.map { relationshipID($0, type: "formula") }))
    }
    for item in info.casks {
      let c = item.raw
      let apps = CaskApps.paths(c, caskroom: caskroom)
      let dependencies = c["depends_on"] as? Record ?? [:]
      let dependencyIDs = ["formula", "cask"].flatMap { type in
        (dependencies[type] as? [String] ?? []).map { relationshipID($0, type: type) }
      }
      result.append(
        UpgradePackage(
          name: item.name, fullName: item.fullName, type: "cask", current: item.versions,
          next: c["version"] as? String ?? "",
          receipt: String(describing: c["installed_time"] ?? ""), apps: apps, reason: "Dependency",
          dependencies: dependencyIDs))
    }
    return result
  }
  private static func relationshipID(_ name: String, type: String) -> String {
    let prefix = type == "cask" ? "homebrew/cask/" : "homebrew/core/"
    return type + ":" + (name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name)
  }
  /// Explain only known, direct edges between packages Homebrew already put in the plan.
  /// Keep origin (Selected / Detected during execution) separate from the display explanation.
  static func explainRelationships(_ packages: [UpgradePackage]) -> [UpgradePackage] {
    func id(_ package: UpgradePackage) -> String {
      relationshipID(package.fullName, type: package.type)
    }
    func names(_ related: [UpgradePackage]) -> String {
      related.map { package in
        packages.contains { $0.fullName == package.fullName && $0.type != package.type }
          ? package.fullName + " (" + package.type + ")" : package.fullName
      }.sorted().joined(separator: ", ")
    }
    return packages.map { package in
      var package = package
      guard package.reason != "Selected" else { return package }
      let parents = packages.filter { $0.id != package.id && $0.dependencies.contains(id(package)) }
      let dependencies = packages.filter {
        $0.id != package.id && package.dependencies.contains(id($0))
      }
      let selectedParents = parents.filter { $0.reason == "Selected" }
      let selectedDependencies = dependencies.filter { $0.reason == "Selected" }
      if !selectedParents.isEmpty {
        package.relationship = "Required by " + names(selectedParents)
      } else if !selectedDependencies.isEmpty {
        package.relationship = "Uses " + names(selectedDependencies)
      } else if !parents.isEmpty {
        package.relationship = "Required by " + names(parents)
      } else if !dependencies.isEmpty {
        package.relationship = "Uses " + names(dependencies)
      }
      return package
    }
  }
  /// Share app path resolution without reparsing validated installed fields.
  private func resolveCaskroom(_ casks: [Record], control: UpgradePreparation?) throws {
    if caskroom == nil, casks.contains(where: CaskApps.needsAppDirectory) {
      let path = try control.map { try readOnly(["--caskroom"], control: $0) }
        ?? inventory.run(inventory.brew, ["--caskroom"])
      let directory = path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard directory.hasPrefix("/") else {
        throw InventoryError(message: "Could not resolve Homebrew's Caskroom path.")
      }
      caskroom = directory
    }
  }
  func resolvedPackages(_ info: Record, control: UpgradePreparation? = nil) throws
    -> [UpgradePackage]
  {
    guard let casks = info["casks"] as? [Record] else {
      throw InventoryError(message: "Homebrew returned incomplete update plan metadata.")
    }
    var metadata = info
    // Homebrew represents an uninstalled Cask with null rather than an installed version.
    metadata["casks"] = casks.map { raw -> Record in
      var cask = raw
      if cask["installed"] == nil || cask["installed"] is NSNull { cask["installed"] = [String]() }
      return cask
    }
    let validated = try Inventory.validateInstalledInfo(metadata)
    return try resolvedPackages(validated, control: control)
  }
  func resolvedPackages(_ info: InstalledPackageInfo, control: UpgradePreparation? = nil) throws
    -> [UpgradePackage]
  {
    try resolveCaskroom(info.casks.map(\.raw), control: control)
    return Self.packages(info, caskroom: caskroom)
  }
  func installed(control: UpgradePreparation? = nil) throws -> [UpgradePackage] {
    try resolvedPackages(installedMetadata(control: control).installed, control: control)
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
    var packages = try resolvedPackages(metadata, control: control)
    func matches(_ package: UpgradePackage, _ name: String) -> Bool {
      package.fullName == name || package.name == name || package.argument == name
    }
    guard !packages.isEmpty,
      packages.allSatisfy({ Self.validName($0.fullName) && !$0.next.isEmpty }),
      names.allSatisfy({ name in packages.contains { matches($0, name) } }),
      packages.allSatisfy({ package in names.contains { matches(package, $0) } })
    else {
      throw InventoryError(message: "Could not resolve the versions in Homebrew's update plan.")
    }
    packages = packages.map { p in
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
      selected: actionable, packages: Self.explainRelationships(packages), output: output,
      excluded: selected.filter { p in !actionable.contains(where: { $0.id == p.id }) }.map(\.name))
  }

  func execute(_ plan: UpgradePlan, event: @escaping (Record) -> Void) throws -> Record {
    let before = try installed()
    var items = plan.packages
    var states = Dictionary(uniqueKeysWithValues: items.map { ($0.id, "Waiting for Homebrew") })
    var sentStates = states
    var packagesChanged = false
    var touched = Set<String>()
    var activityMatcher = PackageActivityMatcher()
    var bufferedLines = UpdateLogBuffer()
    var lastEvent = Date.distantPast
    event(["kind": "progress", "packages": items.map(\.record), "states": states, "processed": 0])
    func flushActivity() {
      var update: Record = ["kind": "activity", "line": bufferedLines.text]
      if packagesChanged {
        update["packages"] = items.map(\.record)
        packagesChanged = false
      }
      if states != sentStates {
        update["states"] = states
        update["processed"] = states.values.filter { $0 == "Awaiting verification" }.count
        sentStates = states
      }
      event(update)
      bufferedLines.removeAll()
      lastEvent = Date()
    }
    let result = try command(["upgrade", "--no-ask"] + plan.selected.map(\.argument)) { line in
      let installing = line.contains("Installing")
      let phase: String?
      if installing || line.contains("Upgrading") || line.contains("Pouring") {
        phase = "Installing…"
      } else if line.contains("Downloading") || line.contains("Fetching") {
        phase = "Downloading…"
      } else if line.contains("successfully") || line.contains("🍺") {
        phase = "Awaiting verification"
      } else {
        phase = nil
      }
      if installing,
        let range = line.range(
          of: #"Installing (?:.* dependency: |dependencies for [^:]+: )"#,
          options: .regularExpression
        )
      {
        let names = line[range.upperBound...].components(separatedBy: ", ").map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter(Self.validName)
        for name in names {
          if !items.contains(where: { $0.name == name || $0.fullName == name }) {
            let old = before.first(where: {
              $0.type == "formula" && ($0.name == name || $0.fullName == name)
            })
            let item = UpgradePackage(
              name: name, fullName: old?.fullName ?? name, type: "formula",
              current: old?.current ?? [], next: "", receipt: old?.receipt ?? "", apps: [],
              reason: "Detected during execution", dependencies: old?.dependencies ?? [])
            items.append(item)
            packagesChanged = true
            states[item.id] = "Waiting for Homebrew"
          }
        }
        // Homebrew can reveal a new dependency before JSON metadata includes it.
        let heading = String(line[range])
        let parentName =
          heading.hasPrefix("Installing dependencies for ")
          ? String(heading.dropFirst("Installing dependencies for ".count).dropLast(2))
          : String(heading.dropFirst("Installing ".count).dropLast(" dependency: ".count))
        let parents = items.indices.filter {
          items[$0].fullName == parentName || items[$0].name == parentName
        }
        if parents.count == 1, let parent = parents.first {
          for name in names {
            let dependency = Self.relationshipID(name, type: "formula")
            if !items[parent].dependencies.contains(dependency) {
              items[parent].dependencies.append(dependency)
              packagesChanged = true
            }
          }
        }
        items = Self.explainRelationships(items)
      }
      // Output is activity, not proof of success. Percentages are intentionally not inferred.
      if let phase {
        for p in items where activityMatcher.matches(p.name, in: line) {
          states[p.id] = phase
          if phase != "Downloading…" { touched.insert(p.id) }
        }
      }
      if !bufferedLines.isEmpty { bufferedLines.append("\n") }
      bufferedLines.append(line)
      if Date().timeIntervalSince(lastEvent) >= 0.1 { flushActivity() }
    }
    if !bufferedLines.isEmpty { flushActivity() }
    event(["kind": "verifying"])
    let after: [UpgradePackage]
    do { after = try installed() } catch {
      var details = UpdateLogBuffer()
      details.append(result.1)
      details.append("\n" + error.localizedDescription)
      return [
        "kind": "result",
        "packages": items.map { p -> Record in
          var r = p.record
          r["outcome"] = "attention"
          r["message"] = "Could not verify installed version"
          r["actualVersion"] = "Unknown"
          return r
        }, "details": details.text, "verified": false, "exitCode": result.0,
      ]
    }
    items = items.map { p in
      guard p.next.isEmpty else { return p }
      let matches = after.filter { $0.type == p.type && ($0.id == p.id || $0.name == p.name) }
      guard matches.count == 1, let actual = matches.first else { return p }
      return UpgradePackage(
        name: actual.name, fullName: actual.fullName, type: actual.type, current: p.current,
        next: actual.current.last ?? "", receipt: p.receipt, apps: actual.apps, reason: p.reason,
        dependencies: actual.dependencies, relationship: p.relationship)
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
            reason: "Detected during execution", dependencies: p.dependencies))
      }
    }
    items = Self.explainRelationships(items)
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
      } else if result.1.contains("Administrator authentication cancelled.") {
        outcome = "attention"
        message = "Authentication cancelled. Retry when ready."
      } else if result.1.localizedCaseInsensitiveContains("sudo")
        || result.1.localizedCaseInsensitiveContains("permission")
        || result.1.localizedCaseInsensitiveContains("password")
      {
        outcome = "attention"
        message = "Administrator authentication did not complete. Review activity and retry."
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
