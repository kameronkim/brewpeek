import Foundation

struct UpgradeTrustTarget {
  let id: String
  let state: String
  let argument: String
  let reference: String
  var type: String { String(id.split(separator: ":", maxSplits: 1)[0]) }
  var name: String { String(id.split(separator: ":", maxSplits: 1)[1]) }
  var fingerprint: [String] { [id, argument, reference] }
  var record: Record { ["id": id, "name": name, "type": type, "source": reference, "trust": state] }
}
struct UpgradeTrustPlan {
  let token = UUID().uuidString
  let keys: [String]
  let brew: String
  let targets: [UpgradeTrustTarget]
  var record: Record {
    ["operation": "trust", "token": token, "keys": keys, "packages": targets.map(\.record)]
  }
}
struct UpgradeTrustRequired: LocalizedError {
  let plan: UpgradeTrustPlan
  var errorDescription: String? { "Homebrew requires explicit trust before loading these packages." }
}

/// Inspect Tap metadata without loading third-party Formula/Cask Ruby or writing trust settings.
enum UpgradeTrust {
  static let script = #"""
    require "json"
    require "trust"
    request = JSON.parse(PAYLOAD.unpack1("m0"))
    result = request.map do |item|
      type = item.fetch("type").to_sym
      raise "Invalid package type" unless [:formula, :cask].include?(type)
      tap_name = item.fetch("name").split("/").first(2).join("/")
      token = item.fetch("name").split("/").last
      tap = Tap.fetch(tap_name)
      if tap.official? && ["homebrew/core", "homebrew/cask"].include?(tap.name)
        {"id" => item.fetch("id"), "state" => "official", "argument" => item.fetch("name"), "reference" => tap.name}
      else
        raise "Tap is not installed" unless tap.installed?
        files = type == :formula ? tap.formula_files_by_name : tap.cask_files_by_name
        path = files[token]
        raise "Canonical package file not found; aliases require explicit canonical selection" unless path && path.file?
        state = if tap.official?
          "official"
        elsif Homebrew::Trust.trusted_tap?(tap)
          "tap"
        elsif Homebrew::Trust.trusted?(type, item.fetch("name"))
          "package"
        else
          "untrusted"
        end
        {"id" => item.fetch("id"), "state" => state, "argument" => path.expand_path.to_s, "reference" => tap.reference}
      end
    end
    puts JSON.generate(result)
    """#

  static func isSafeArgument(_ value: String) -> Bool {
    if value.hasPrefix("/") {
      // Homebrew's full_name? is exactly two slashes. Absolute Tap paths must not match it.
      return value.hasSuffix(".rb") && value.filter { $0 == "/" }.count > 2 && !value.contains("\n")
    }
    return (value.hasPrefix("homebrew/core/") || value.hasPrefix("homebrew/cask/"))
      && value.split(separator: "/").count == 3 && HomebrewPackageName.isValid(value)
  }

  static func commands(_ packages: [UpgradePackage], preview: Bool) throws -> [[String]] {
    guard !packages.isEmpty, packages.allSatisfy({ isSafeArgument($0.upgradeArgument) }) else {
      throw InventoryError(message: "Unsafe upgrade arguments. Review package trust again.")
    }
    let groups = packages.contains { $0.type == "cask" && $0.upgradeArgument.hasPrefix("/") }
      ? [packages.filter { $0.type == "formula" }, packages.filter { $0.type == "cask" }].filter { !$0.isEmpty }
      : [packages]
    return groups.map { group in
      var args = ["upgrade"] + (preview ? ["--dry-run"] : []) + ["--no-ask"]
      if groups.count > 1 || group.contains(where: { $0.type == "cask" && $0.upgradeArgument.hasPrefix("/") }) {
        args.append(group[0].type == "cask" ? "--cask" : "--formula")
      }
      return args + group.map(\.upgradeArgument)
    }
  }

  static func inspect(_ keys: [String], process: BrewProcess, control: UpgradePreparation) throws -> [UpgradeTrustTarget] {
    var official: [String: UpgradeTrustTarget] = [:]
    var external: [Record] = []
    for key in keys {
      let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2, ["formula", "cask"].contains(parts[0]), HomebrewPackageName.isValid(parts[1]) else {
        throw InventoryError(message: "Invalid package trust target.")
      }
      let prefix = parts[0] == "cask" ? "homebrew/cask/" : "homebrew/core/"
      if !parts[1].contains("/") || parts[1].hasPrefix(prefix) {
        let argument = parts[1].hasPrefix(prefix) ? parts[1] : prefix + parts[1]
        official[key] = UpgradeTrustTarget(id: key, state: "official", argument: argument, reference: String(prefix.dropLast()))
      } else {
        guard parts[1].split(separator: "/").count == 3 else { throw InventoryError(message: "Invalid Tap package name.") }
        external.append(["id": key, "type": parts[0], "name": parts[1]])
      }
    }
    var resolved = official
    if !external.isEmpty {
      let payload = try JSONSerialization.data(withJSONObject: external).base64EncodedString()
      let text = try process.trustInspection(script.replacingOccurrences(of: "PAYLOAD", with: "\"" + payload + "\""), control: control)
      guard let records = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Record] else {
        throw InventoryError(message: "Homebrew returned invalid trust information.")
      }
      for row in records {
        guard let id = row["id"] as? String, external.contains(where: { $0["id"] as? String == id }), resolved[id] == nil,
          let state = row["state"] as? String, ["official", "tap", "package", "untrusted"].contains(state),
          let path = row["argument"] as? String, path.hasPrefix("/"), path.hasSuffix(".rb"), !path.contains("\n"),
          let reference = row["reference"] as? String, !reference.isEmpty else {
          throw InventoryError(message: "Homebrew returned invalid trust information.")
        }
        resolved[id] = UpgradeTrustTarget(id: id, state: state, argument: path, reference: reference)
      }
    }
    guard keys.count == Set(keys).count, resolved.count == keys.count else { throw InventoryError(message: "Homebrew trust inspection was incomplete.") }
    return keys.compactMap { resolved[$0] }
  }

  static func requireTrusted(_ targets: [UpgradeTrustTarget], keys: [String], brew: String) throws {
    let blocked = targets.filter { $0.state == "untrusted" }
    if !blocked.isEmpty { throw UpgradeTrustRequired(plan: UpgradeTrustPlan(keys: keys, brew: brew, targets: blocked)) }
  }
}
