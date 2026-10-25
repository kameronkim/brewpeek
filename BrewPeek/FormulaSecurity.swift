import CoreFoundation
import Foundation

/// Homebrew 7.0.10's vulns JSON is authoritative. No CVE matching or version inference lives here.
enum FormulaSecurity {
  static func check(inventory: Inventory, timeout: Double = 45) -> Record {
    do {
      // Probe the JSON coverage contract, not a guessed Homebrew version or localized error alone.
      let help = try inventory.runResult(inventory.brew, ["help", "vulns"], timeout: 10)
      if help.exited, help.status == 0 {
        guard help.output.contains("--json"), help.output.contains("scan coverage") else {
          return ["status": "unsupported", "scope": "formulae"]
        }
      } else {
        let unknown = help.error + help.output
        if help.exited, help.status == 1, unknown.contains("Unknown command"), unknown.contains("vulns") {
          return ["status": "unsupported", "scope": "formulae"]
        }
        return failure("Could not check Homebrew vulnerability command support.", result: help)
      }
      let result = try inventory.runResult(inventory.brew, ["vulns", "--json"], timeout: timeout)
      return interpret(result)
    } catch {
      return failure(error.localizedDescription)
    }
  }

  private static func failure(_ message: String, result: Inventory.CommandResult? = nil) -> Record {
    var value: Record = ["status": "failed", "scope": "formulae", "error": message]
    if let result {
      value["exitStatus"] = Int(result.status)
      value["diagnostic"] = String(result.error.prefix(8192))
    }
    return value
  }

  /// Strict enough to distinguish a report from arbitrary JSON printed before a command failure.
  static func validReport(_ report: Record) -> Bool {
    func integer(_ value: Any?) -> Bool {
      guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return false }
      return value.doubleValue.isFinite && value.doubleValue >= 0 && value.doubleValue.rounded() == value.doubleValue
    }
    func flag(_ value: Any?) -> Bool {
      guard let value = value as? NSNumber else { return false }
      return CFGetTypeID(value) == CFBooleanGetTypeID()
    }
    func names(_ value: Any?) -> Bool {
      guard let values = value as? [String] else { return false }
      return values.allSatisfy(HomebrewPackageName.isValid)
    }
    func vulnerabilities(_ value: Any?) -> Bool {
      guard let records = value as? [Record] else { return false }
      return records.allSatisfy {
        ($0["id"] as? String)?.isEmpty == false && $0["severity"] is String
          && ($0["summary"] is String || $0["summary"] is NSNull)
          && $0["aliases"] is [String] && $0["fixed_versions"] is [String]
      }
    }
    guard let findings = report["findings"] as? [Record], integer(report["checked"]),
      flag(report["complete"]), names(report["skipped_formulae"]), names(report["outdated_without_sbom"]),
      let unscanned = report["unscanned_formulae"] as? [String: String],
      unscanned.keys.allSatisfy(HomebrewPackageName.isValid),
      unscanned.values.allSatisfy({ !$0.isEmpty }) else { return false }
    guard (report["checked"] as! NSNumber).intValue >= findings.count else { return false }
    var identities = Set<String>()
    return findings.allSatisfy {
      guard let name = $0["formula"] as? String, HomebrewPackageName.isValid(name),
        identities.insert(HomebrewPackageName.formulaIdentity(name)).inserted,
        ($0["version"] as? String)?.isEmpty == false else { return false }
      return vulnerabilities($0["vulnerabilities"]) && vulnerabilities($0["patched"])
        && (!(($0["vulnerabilities"] as? [Record]) ?? []).isEmpty || !(($0["patched"] as? [Record]) ?? []).isEmpty)
    }
  }

  static func interpret(_ result: Inventory.CommandResult) -> Record {
    guard let report = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? Record,
      validReport(report) else { return failure("Homebrew did not return a valid vulnerability report.", result: result) }
    let findings = report["findings"] as! [Record]
    let open = findings.contains { !($0["vulnerabilities"] as! [Record]).isEmpty }
    let stale = report["outdated_without_sbom"] as! [String]
    let skipped = report["skipped_formulae"] as! [String]
    let unscanned = report["unscanned_formulae"] as! [String: String]
    let complete = report["complete"] as! Bool && stale.isEmpty && skipped.isEmpty && unscanned.isEmpty
    // cmd/vulns.rb sets Homebrew.failed for these cases. Other exit codes are execution failures.
    let expectedFailure = open || !stale.isEmpty
      || unscanned.values.contains("untrusted_tap") || unscanned.values.contains("resolution_error")
    let expectedStatus: Int32 = expectedFailure ? 1 : 0
    var value: Record = [
      "scope": "formulae", "report": report, "complete": complete,
      "exitStatus": Int(result.status), "diagnostic": String(result.error.prefix(8192)),
      "checkedAt": ISO8601DateFormatter().string(from: Date()),
    ]
    if result.exited && result.status == expectedStatus {
      value["status"] = complete ? "succeeded" : "incomplete"
    } else {
      value["status"] = "failed"
      value["error"] = "Homebrew exited unexpectedly. Reported findings are retained; the scan is not confirmed."
    }
    return value
  }

  /// Corrupt optional security metadata must never prevent ordinary inventory from loading.
  static func normalize(_ value: Any?) -> Record? {
    guard let value else { return nil }
    guard let value = value as? Record,
      let state = value["status"] as? String,
      ["succeeded", "incomplete", "unsupported", "failed"].contains(state),
      value["scope"] as? String == "formulae" else { return failure("Saved security information is invalid. Refresh to check again.") }
    if let report = value["report"] {
      guard let report = report as? Record, validReport(report) else {
        return failure("Saved security information is invalid. Refresh to check again.")
      }
    } else if ["succeeded", "incomplete"].contains(state) {
      return failure("Saved security information is incomplete. Refresh to check again.")
    }
    // Recheck coverage invariants even for a saved snapshot.
    var normalized = value
    if let report = value["report"] as? Record {
      let complete = report["complete"] as? Bool == true
        && (report["skipped_formulae"] as? [String])?.isEmpty == true
        && (report["outdated_without_sbom"] as? [String])?.isEmpty == true
        && (report["unscanned_formulae"] as? [String: String])?.isEmpty == true
      normalized["complete"] = complete
      if state == "succeeded" && !complete { normalized["status"] = "incomplete" }
    }
    return normalized
  }
}
