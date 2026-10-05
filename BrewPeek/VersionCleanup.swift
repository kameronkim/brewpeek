import Foundation

struct InstalledVersion {
  let version: String
  let fingerprint: String
  let removable: Bool
}
struct VersionCleanupPlan {
  let token = UUID().uuidString
  let key: String
  let name: String
  let fullName: String
  let versions: [InstalledVersion]
  var fingerprint: [String] {
    versions.map { $0.version + "|" + $0.fingerprint + "|" + String($0.removable) }.sorted()
  }
  var record: Record {
    [
      "operation": "version-cleanup", "token": token, "selectedCount": 1, "key": key,
      "packages": versions.map { v -> Record in
        [
          "id": key + "@" + v.version, "name": name, "version": v.version,
          "removable": v.removable,
          "reason": v.removable ? "Old installed version" : "Kept by Homebrew",
          "availableVersion": v.removable ? "Remove" : "Keep",
        ]
      },
    ]
  }
}

/// Use Homebrew's keg eligibility and cleanup routines, without touching caches or other packages.
struct VersionCleanup {
  let engine: Upgrade
  init(brew: String) { engine = Upgrade(brew: brew) }
  static let script = #"""
    require "json"
    require "digest"
    require "cleanup"
    request = JSON.parse(PAYLOAD.unpack1("m0"))
    formula = Formulary.factory(request.fetch("name"))
    def version_records(formula)
      eligible = if formula.pinned? || Homebrew::Cleanup.skip_clean_formula?(formula)
        []
      else
        formula.eligible_kegs_for_cleanup(quiet: true).reject(&:optlinked?)
      end
      formula.installed_kegs.map do |keg|
        path = Pathname.new(keg)
        receipt = path/"INSTALL_RECEIPT.json"
        identity = [path.to_s, path.stat.ino, Digest::SHA256.file(receipt).hexdigest,
                    keg.linked?, keg.optlinked?].join("|")
        {"version" => keg.version.to_s, "fingerprint" => identity,
         "removable" => eligible.include?(keg)}
      end.sort_by { |r| r.fetch("version") }
    end
    if request["selected"]
      formula.lock
      begin
        records = version_records(formula)
        selected = request.fetch("selected")
        raise "No versions selected" if selected.empty?
        raise "Installed versions changed. Review them again." unless records == request.fetch("expected")
        targets = selected.map do |version|
          record = records.find { |r| r.fetch("version") == version }
          raise "This version is no longer eligible for cleanup" unless record && record.fetch("removable")
          formula.installed_kegs.find { |k| k.version.to_s == version } || raise("Version no longer installed")
        end
        cleaner = Homebrew::Cleanup.new
        targets.each { |keg| cleaner.cleanup_keg(keg) }
        raise "Some versions could not be removed" unless cleaner.unremovable_kegs.empty?
      ensure
        formula.unlock
      end
    else
      puts JSON.generate({"name" => formula.name, "fullName" => formula.full_name,
                          "versions" => version_records(formula)})
    end
    """#
  static func script(_ payload: Record) throws -> String {
    let encoded = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
    return script.replacingOccurrences(of: "PAYLOAD", with: "\"" + encoded + "\"")
  }
  func prepare(key: String, control: UpgradePreparation = UpgradePreparation()) throws
    -> VersionCleanupPlan
  {
    guard key.hasPrefix("formula:"), HomebrewPackageName.isValid(String(key.dropFirst(8))) else {
      throw InventoryError(message: "Select an installed Formula to review versions.")
    }
    let text = try engine.dependencyProjection(
      Self.script(["name": String(key.dropFirst(8))]), control: control)
    guard let data = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? Record,
      let name = data["name"] as? String, let fullName = data["fullName"] as? String,
      "formula:" + fullName == key, let records = data["versions"] as? [Record], !records.isEmpty
    else { throw InventoryError(message: "Could not verify installed versions.") }
    let versions = try records.map { r -> InstalledVersion in
      guard let version = r["version"] as? String, !version.isEmpty,
        let fingerprint = r["fingerprint"] as? String, !fingerprint.isEmpty,
        let removable = r["removable"] as? Bool
      else { throw InventoryError(message: "Homebrew returned incomplete version information.") }
      return InstalledVersion(version: version, fingerprint: fingerprint, removable: removable)
    }
    guard Set(versions.map(\.version)).count == versions.count else {
      throw InventoryError(message: "Homebrew returned duplicate installed versions.")
    }
    return VersionCleanupPlan(key: key, name: name, fullName: fullName, versions: versions)
  }
  func execute(_ plan: VersionCleanupPlan, selected: [String], event: @escaping (Record) -> Void)
    throws -> Record
  {
    guard !selected.isEmpty, Set(selected).count == selected.count,
      selected.allSatisfy({ v in plan.versions.contains { $0.version == v && $0.removable } })
    else {
      throw InventoryError(message: "Select only old versions that Homebrew allows removing.")
    }
    let expected = plan.versions.map { v -> Record in
      ["version": v.version, "fingerprint": v.fingerprint, "removable": v.removable]
    }
    let result = try engine.command(
      [
        "ruby", "-e",
        Self.script([
          "name": plan.fullName, "expected": expected, "selected": selected,
        ]),
      ], environmentOverrides: ["HOMEBREW_DEV_CMD_RUN": "1", "HOMEBREW_NO_AUTOREMOVE": "1"]
    ) { line in
      event(["kind": "activity", "line": line])
    }
    event(["kind": "verifying"])
    var verified = false
    var details = result.1
    var records: [Record] = []
    do {
      let remaining = try prepare(key: plan.key)
      verified = true
      records = selected.map { version in
        let removed = !remaining.versions.contains { $0.version == version }
        return [
          "id": plan.key + "@" + version, "name": plan.name + " " + version,
          "outcome": removed && result.0 == 0 ? "removed" : "attention",
          "actualVersion": removed ? "Removed" : "Still installed",
          "message": removed
            ? (result.0 == 0
              ? "Version removed" : "Removed, but Homebrew reported an error. Review activity.")
            : "Version remains installed. Review activity and retry.",
        ]
      }
    } catch {
      details += "\n" + error.localizedDescription
      records = selected.map { version in
        [
          "id": plan.key + "@" + version, "name": plan.name + " " + version,
          "outcome": "attention", "actualVersion": "Unknown",
          "message": "Could not verify version removal. Refresh before retrying.",
        ]
      }
    }
    return [
      "kind": "result", "operation": "version-cleanup", "packages": records,
      "details": details, "verified": verified, "exitCode": result.0, "retryKeys": [plan.key],
    ]
  }
}
