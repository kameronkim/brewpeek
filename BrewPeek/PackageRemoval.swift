import Foundation

struct PackageRemovalPlan {
  let token = UUID().uuidString
  let package: UpgradePackage
  var dependencies: [UpgradePackage] = []
  var packages: [UpgradePackage] { [package] + dependencies }
  var fingerprint: [String] {
    packages.map { [$0.id, $0.current.joined(separator: ","), $0.receipt] + $0.apps.sorted() }
      .map { $0.joined(separator: "|") }.sorted()
  }
  var record: Record {
    [
      "operation": "uninstall", "token": token, "selectedCount": 1,
      "packages": packages.map { p -> Record in
        var item = p.record
        item["action"] = "uninstall"
        item["availableVersion"] = "Not installed"
        item["installedVersions"] = p.current
        return item
      },
    ]
  }
}

/// Homebrew decides eligibility; only Formula dependencies of the selected package are in scope.
struct PackageRemoval {
  let engine: Upgrade
  init(brew: String) { engine = Upgrade(brew: brew) }

  // Keep this read-only. Homebrew's internal API may change; preparation must fail closed.
  static let dependencyScript = #"""
    require "json"
    require "cleanup"
    require "cask/caskroom"
    require "utils/autoremove"
    require "installed_dependents"
    request = JSON.parse(PAYLOAD.unpack1("m0"))
    formulae = Formula.installed
    casks = Cask::Caskroom.casks
    type = request.fetch("type")
    name = request.fetch("name")
    selected_cask = type == "cask" ? casks.find { |c| c.full_token == name } : nil
    selected_formula = type == "formula" ? formulae.find { |f| f.full_name == name } : nil
    blocked = []
    if selected_formula
      blocked << "Pinned Formula" if selected_formula.pinned?
      parents = InstalledDependents.find_some_installed_dependents(selected_formula.installed_kegs)
      blocked.concat(parents[1]) if parents
    end
    scope = request["scope"]
    if scope.nil?
      raise "Selected package is no longer installed" unless selected_cask || selected_formula
      scope = if selected_formula
        selected_formula.installed_runtime_formula_dependencies.map(&:full_name)
      else
        selected_cask.depends_on.formula.flat_map do |dependency|
          f = Formulary.factory(dependency)
          [f.full_name, *f.installed_runtime_formula_dependencies.map(&:full_name)]
        end
      end.uniq
    end
    formulae -= [selected_formula]
    protected = formulae.select(&:pinned?).flat_map do |f|
      [f.full_name, *f.installed_runtime_formula_dependencies.map(&:full_name)]
    end
    unless Homebrew::EnvConfig.no_cleanup_formulae.to_s.empty?
      excluded = formulae.select { |f| Homebrew::Cleanup.skip_clean_formula?(f) }
      formulae -= excluded.flat_map { |f| [f, *f.installed_runtime_formula_dependencies] }
    end
    removable = Utils::Autoremove.removable_formulae(formulae, casks - [selected_cask])
      .select { |f| scope.include?(f.full_name) && !protected.include?(f.full_name) }
    # Only this operation's candidates may be excluded from dependent checks.
    # A candidate kept in one pass may require another candidate in the next pass.
    loop do
      kegs = removable.map(&:any_installed_keg).compact
      required = InstalledDependents.find_some_installed_dependents(
        kegs + (selected_formula ? selected_formula.installed_kegs : []),
        casks: selected_cask ? [selected_cask] : [])
      required_names = required ? required[0].map(&:name) : []
      remaining = removable.reject { |f| required_names.include?(f.name) }
      break if remaining.size == removable.size
      removable = remaining
    end
    names = removable.map(&:full_name).sort
    puts JSON.generate({"dependencies" => names, "blocked" => blocked.uniq.sort})
    """#

  func eligibleDependencies(
    package: UpgradePackage, scope: [String]? = nil,
    control: UpgradePreparation? = nil
  ) throws -> [String] {
    var payload: Record = ["type": package.type, "name": package.fullName]
    if let scope { payload["scope"] = scope }
    let encoded = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
    let script = Self.dependencyScript.replacingOccurrences(
      of: "PAYLOAD", with: "\"" + encoded + "\"")
    let text = try engine.dependencyProjection(script, control: control ?? UpgradePreparation())
    guard let data = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? Record else {
      throw InventoryError(message: "Homebrew could not verify removable dependencies.")
    }
    guard let blocked = data["blocked"] as? [String] else {
      throw InventoryError(message: "Homebrew could not verify package dependents.")
    }
    if !blocked.isEmpty {
      throw InventoryError(
        message: "This Formula cannot be uninstalled while it is pinned or required by: "
          + blocked.joined(separator: ", "))
    }
    guard let names = data["dependencies"] as? [String], names.allSatisfy(Upgrade.validName),
      Set(names).count == names.count
    else {
      throw InventoryError(message: "Homebrew could not verify removable dependencies.")
    }
    return names
  }

  func prepare(key: String, control: UpgradePreparation = UpgradePreparation()) throws
    -> PackageRemovalPlan
  {
    let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, ["formula", "cask"].contains(parts[0]), Upgrade.validName(parts[1])
    else {
      throw InventoryError(message: "Select an installed package to uninstall.")
    }
    let info = try engine.installedMetadata(control: control)
    let installed = try engine.resolvedPackages(info, control: control)
    guard
      var package = installed.first(where: {
        $0.id == key && !$0.current.isEmpty
      })
    else {
      throw InventoryError(message: "This package is no longer installed. Refresh and try again.")
    }
    if package.type == "formula" {
      let receipts = info.formulae.first { $0.fullName == package.fullName }?.receipts ?? []
      guard receipts.contains(where: { $0["installed_on_request"] as? Bool == true }) else {
        throw InventoryError(
          message:
            "This Formula was installed as a dependency. Remove it together with the package that requires it."
        )
      }
    }
    package.reason = "Selected"
    let names =
      package.type == "cask" && package.dependencies.isEmpty
      ? [] : try eligibleDependencies(package: package, control: control)
    let dependencies = try names.map { name -> UpgradePackage in
      guard
        var p = installed.first(where: {
          $0.type == "formula" && $0.fullName == name && !$0.current.isEmpty
        })
      else {
        throw InventoryError(message: "Dependency information changed. Refresh and try again.")
      }
      p.reason = "Unused dependency"
      p.relationship = "No longer needed after removing " + package.name
      return p
    }
    return PackageRemovalPlan(package: package, dependencies: dependencies)
  }

  func execute(_ plan: PackageRemovalPlan, event: @escaping (Record) -> Void) throws -> Record {
    var details = UpdateLogBuffer()
    var states = Dictionary(
      uniqueKeysWithValues: plan.packages.map { ($0.id, "Waiting for Homebrew") })
    var activity = UpdateLogBuffer()
    var lastEvent = Date.distantPast
    func progress(_ processed: Int) {
      event([
        "kind": "progress", "packages": plan.record["packages"]!, "states": states,
        "processed": processed,
      ])
    }
    func command(_ args: [String]) throws -> Int32 {
      let result = try engine.command(args, environmentOverrides: ["HOMEBREW_NO_AUTOREMOVE": "1"]) {
        line in
        activity.append(line + "\n")
        if Date().timeIntervalSince(lastEvent) >= 0.1 {
          event(["kind": "activity", "line": activity.text])
          activity.removeAll()
          lastEvent = Date()
        }
      }
      if !activity.isEmpty {
        event(["kind": "activity", "line": activity.text])
        activity.removeAll()
      }
      details.append(result.1)
      return result.0
    }
    let package = plan.package
    states[package.id] = "Uninstalling…"
    progress(0)
    let packageExit = try command(
      [
        "uninstall", package.type == "cask" ? "--cask" : "--formula",
      ] + (package.type == "formula" && package.current.count > 1 ? ["--force"] : []) + [
        package.argument
      ])
    var dependencyExit: Int32 = 0
    var kept = Set<String>()
    var attempted = Set<String>()
    // Never remove dependencies unless the selected package is confirmed absent and its command succeeded.
    do {
      let remaining = try engine.installed()
      if packageExit == 0 && !remaining.contains(where: { $0.id == package.id })
        && !plan.dependencies.isEmpty
      {
        states[package.id] = "Uninstalled"
        let eligible = Set(
          try eligibleDependencies(package: package, scope: plan.dependencies.map(\.fullName))
        )
        let targets = plan.dependencies.filter { p in
          guard eligible.contains(p.fullName),
            let actual = remaining.first(where: { $0.id == p.id })
          else { return false }
          return actual.current == p.current && actual.receipt == p.receipt
        }
        kept = Set(
          plan.dependencies.filter { p in !targets.contains(where: { $0.id == p.id }) }.map(\.id))
        for p in targets {
          states[p.id] = "Removing unused dependency…"
          attempted.insert(p.id)
        }
        for id in kept { states[id] = "Kept — no longer eligible for removal" }
        progress(1)
        if !targets.isEmpty {
          dependencyExit = try command(
            ["uninstall", "--formula"]
              + (targets.contains { $0.current.count > 1 } ? ["--force"] : [])
              + targets.map(\.argument))
        }
      }
    } catch {
      dependencyExit = 1
      details.append("\nDependency removal stopped: " + error.localizedDescription)
    }
    event(["kind": "verifying"])
    var verified = false
    var records: [Record] = []
    do {
      let remaining = try engine.installed()
      verified = true
      records = plan.packages.map { p in
        var item = p.record
        item["action"] = "uninstall"
        let actual = remaining.first { $0.id == p.id }
        item["actualVersion"] = actual?.current.joined(separator: ", ") ?? "Not installed"
        let exit = p.id == package.id ? packageExit : dependencyExit
        if actual == nil {
          item["outcome"] = exit == 0 ? "uninstalled" : "attention"
          item["message"] =
            exit == 0 ? "Uninstalled" : "Removed, but Homebrew reported an error. Review activity."
        } else if kept.contains(p.id) {
          item["outcome"] = "kept"
          item["message"] = "Kept because it is no longer eligible for removal."
        } else {
          item["outcome"] = "attention"
          item["message"] =
            p.id != package.id && !attempted.contains(p.id)
            ? "Dependency removal did not start. Review activity."
            : "Still registered as installed. Review activity and retry."
          if exit != 0 { item["outcome"] = "failed" }
        }
        return item
      }
    } catch {
      details.append("\n" + error.localizedDescription)
      records = plan.packages.map { p in
        var item = p.record
        item["action"] = "uninstall"
        item["outcome"] = "attention"
        item["message"] = "Could not verify removal. Refresh before retrying."
        item["actualVersion"] = "Unknown"
        return item
      }
    }
    return [
      "kind": "result", "operation": "uninstall", "packages": records,
      "details": details.text, "verified": verified,
      "exitCode": packageExit != 0 ? packageExit : dependencyExit,
    ]
  }
}
