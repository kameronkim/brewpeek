import Foundation

/// Only an explicitly confirmed removal is persisted. Recovery never resumes commands automatically.
struct SavedRemovalPackage: Codable {
  let name: String
  let fullName: String
  let type: String
  let current: [String]
  let next: String
  let receipt: String
  let apps: [String]
  init(_ package: UpgradePackage) {
    name = package.name
    fullName = package.fullName
    type = package.type
    current = package.current
    next = package.next
    receipt = package.receipt
    apps = package.apps
  }
  var package: UpgradePackage {
    UpgradePackage(
      name: name, fullName: fullName, type: type, current: current, next: next,
      receipt: receipt, apps: apps, reason: "Previously confirmed")
  }
}
struct RemovalTask: Codable {
  let schemaVersion: Int
  let id: String
  let root: SavedRemovalPackage
  var dependencies: [SavedRemovalPackage]
  init(_ plan: PackageRemovalPlan) {
    schemaVersion = 1
    id = UUID().uuidString
    root = SavedRemovalPackage(plan.package)
    dependencies = plan.dependencies.map(SavedRemovalPackage.init)
  }
}
enum RemovalTaskStore {
  static func url(for inventory: URL) -> URL {
    inventory.deletingLastPathComponent().appendingPathComponent("pending-removal.json")
  }
  static func load(at inventory: URL) throws -> RemovalTask? {
    let file = url(for: inventory)
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let task = try JSONDecoder().decode(RemovalTask.self, from: Data(contentsOf: file))
    let packages = [task.root] + task.dependencies
    guard task.schemaVersion == 1, UUID(uuidString: task.id) != nil,
      ["formula", "cask"].contains(task.root.type),
      task.dependencies.allSatisfy({ $0.type == "formula" }),
      packages.allSatisfy({ Upgrade.validName($0.fullName) && !$0.current.isEmpty }),
      Set(packages.map { $0.package.id }).count == packages.count
    else { throw InventoryError(message: "The saved cleanup task has an invalid format.") }
    return task
  }
  static func save(_ task: RemovalTask, at inventory: URL) throws {
    let file = url(for: inventory)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(task).write(to: file, options: .atomic)
  }
  static func clear(at inventory: URL, id: String) throws {
    guard let task = try load(at: inventory), task.id == id else {
      throw InventoryError(message: "The saved cleanup task changed. Refresh before continuing.")
    }
    try FileManager.default.removeItem(at: url(for: inventory))
  }
  static func finish(_ task: RemovalTask, result: Record, at inventory: URL) throws -> Bool {
    guard result["verified"] as? Bool == true, let rows = result["packages"] as? [Record] else {
      return true
    }
    let rootGone =
      rows.first(where: { $0["id"] as? String == task.root.package.id })?["actualVersion"]
      as? String == "Not installed"
    var pending = task
    pending.dependencies = task.dependencies.filter { saved in
      guard let row = rows.first(where: { $0["id"] as? String == saved.package.id }) else {
        return true
      }
      return row["actualVersion"] as? String != "Not installed"
        && row["outcome"] as? String != "kept"
    }
    if rootGone && pending.dependencies.isEmpty {
      try clear(at: inventory, id: task.id)
      return false
    }
    try save(pending, at: inventory)
    return true
  }
}
struct CleanupPlan {
  let token = UUID().uuidString
  let task: RemovalTask
  let packages: [UpgradePackage]
  let kept: [Record]
  var fingerprint: [String] {
    packages.map { $0.id + "|" + $0.current.joined(separator: ",") + "|" + $0.receipt }.sorted()
      + kept.map {
        ($0["id"] as? String ?? "") + "|" + ($0["message"] as? String ?? "") + "|"
          + ($0["version"] as? String ?? "")
      }.sorted()
  }
  var record: Record {
    [
      "operation": "cleanup", "token": token, "selectedCount": packages.count,
      "packages": packages.map { p -> Record in
        var row = p.record
        row["action"] = "uninstall"
        row["status"] = "Ready to remove"
        return row
      }, "kept": kept, "rootName": task.root.name,
    ]
  }
}
extension PackageRemoval {
  func checkHomebrewIdle(control: UpgradePreparation) throws {
    let response = try engine.dependencyProjection(
      #"""
      require "json"
      busy = Dir.glob((HOMEBREW_LOCKS/"*.lock").to_s).filter_map do |path|
        begin
          File.open(path, "r") do |file|
            if file.flock(File::LOCK_EX | File::LOCK_NB)
              file.flock(File::LOCK_UN)
              nil
            else
              File.basename(path)
            end
          end
        rescue Errno::ENOENT
          nil
        end
      end
      puts JSON.generate({"busy" => busy})
      """#, control: control)
    guard let object = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? Record,
      let busy = object["busy"] as? [String]
    else {
      throw InventoryError(message: "Could not check whether Homebrew is busy. Try again.")
    }
    guard busy.isEmpty else {
      throw InventoryError(
        message: "Another Homebrew task is running. Wait for it to finish, then retry cleanup.")
    }
  }
  func recoveryResult(_ task: RemovalTask, control: UpgradePreparation = UpgradePreparation())
    throws -> Record
  {
    let installed = try engine.installed(control: control)
    let rootGone = !installed.contains { $0.id == task.root.package.id }
    let rows = ([task.root] + task.dependencies).map { saved -> Record in
      var row = saved.package.record
      let actual = installed.first { $0.id == saved.package.id }
      row["actualVersion"] = actual?.current.joined(separator: ", ") ?? "Not installed"
      row["outcome"] = actual == nil ? "uninstalled" : "attention"
      row["message"] = actual == nil ? "Uninstalled" : "Still installed. Review before retrying."
      return row
    }
    return [
      "kind": "result", "operation": "uninstall", "packages": rows, "verified": true,
      "details": "Recovered a saved removal task. Current Homebrew registrations checked.",
      "recovered": true, "recoveryID": task.id,
      "pendingCleanup": rootGone
        && rows.dropFirst().contains { $0["actualVersion"] as? String != "Not installed" },
    ]
  }
  func prepareCleanup(_ task: RemovalTask, control: UpgradePreparation = UpgradePreparation())
    throws -> CleanupPlan
  {
    try checkHomebrewIdle(control: control)
    let installed = try engine.installed(control: control)
    guard !installed.contains(where: { $0.id == task.root.package.id }) else {
      throw InventoryError(
        message:
          "The selected package is still installed. Retry its uninstall before dependency cleanup.")
    }
    let unchangedNames = task.dependencies.filter { saved in
      installed.contains {
        $0.id == saved.package.id && $0.current == saved.current && $0.receipt == saved.receipt
      }
    }.map(\.fullName)
    let eligible = Set(
      try eligibleDependencies(
        package: task.root.package,
        scope: unchangedNames, control: control))
    var targets: [UpgradePackage] = []
    var kept: [Record] = []
    for saved in task.dependencies {
      guard let actual = installed.first(where: { $0.id == saved.package.id }) else { continue }
      let unchanged = actual.current == saved.current && actual.receipt == saved.receipt
      if unchanged && eligible.contains(actual.fullName) {
        var package = actual
        package.reason = "Unused dependency"
        package.relationship = "No longer needed after removing " + task.root.name
        targets.append(package)
      } else {
        var row = actual.record
        row["status"] = "Kept"
        row["outcome"] = "kept"
        row["message"] =
          unchanged
          ? "Still required, directly installed, pinned, or excluded by Homebrew."
          : "Installation changed since the original confirmation."
        row["actualVersion"] = actual.current.joined(separator: ", ")
        kept.append(row)
      }
    }
    return CleanupPlan(task: task, packages: targets, kept: kept)
  }
  func executeCleanup(_ plan: CleanupPlan, event: @escaping (Record) -> Void) throws -> Record {
    var log = UpdateLogBuffer()
    var activity = UpdateLogBuffer()
    var lastEvent = Date.distantPast
    let exit: Int32
    if plan.packages.isEmpty {
      exit = 0
    } else {
      event([
        "kind": "progress", "packages": plan.record["packages"]!,
        "states": Dictionary(
          uniqueKeysWithValues: plan.packages.map { ($0.id, "Removing unused dependency…") }),
        "processed": 0,
      ])
      let command = try engine.command(
        ["uninstall", "--formula"]
          + (plan.packages.contains { $0.current.count > 1 } ? ["--force"] : [])
          + plan.packages.map(\.argument),
        environmentOverrides: ["HOMEBREW_NO_AUTOREMOVE": "1"]
      ) { line in
        log.append(line + "\n")
        activity.append(line + "\n")
        if Date().timeIntervalSince(lastEvent) >= 0.1 {
          event(["kind": "activity", "line": activity.text])
          activity.removeAll()
          lastEvent = Date()
        }
      }
      if !activity.text.isEmpty { event(["kind": "activity", "line": activity.text]) }
      exit = command.0
    }
    event(["kind": "verifying"])
    let installed = try engine.installed()
    var root = plan.task.root.package.record
    let actualRoot = installed.first { $0.id == plan.task.root.package.id }
    root["actualVersion"] = actualRoot?.current.joined(separator: ", ") ?? "Not installed"
    root["outcome"] = actualRoot == nil ? "uninstalled" : "attention"
    root["message"] =
      actualRoot == nil
      ? "Uninstalled" : "The package is installed again. Review its current installation."
    let rows: [Record] = plan.task.dependencies.map { saved in
      if let kept = plan.kept.first(where: { $0["id"] as? String == saved.package.id }) {
        return kept
      }
      var row = saved.package.record
      let actual = installed.first { $0.id == saved.package.id }
      row["actualVersion"] = actual?.current.joined(separator: ", ") ?? "Not installed"
      row["outcome"] = actual == nil ? "uninstalled" : "failed"
      row["message"] =
        actual == nil ? "Uninstalled" : "Still installed. Retry cleanup to review it again."
      return row
    }
    return [
      "kind": "result", "operation": "uninstall", "packages": [root] + rows,
      "verified": true, "details": log.text, "exitCode": exit,
    ]
  }
}
