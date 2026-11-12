import Cocoa
import WebKit

struct SecuritySnapshotContext {
  let id: String
}

extension DesktopApp {
  func cancelSecurityRefresh() {
    let old = securityInventory
    securityInventory = nil
    securityContext = nil
    securityGeneration = nil
    interruptedSecurityContext = nil
    latestSecurityReport = nil
    old?.cancel()
  }

  /// Called under the package-operation lock immediately before approved trust writes.
  func invalidateSecurityForTrustChange() -> SecuritySnapshotContext? {
    let context = securityContext
    cancelSecurityRefresh()
    guard let context else { return nil }
    securityContext = context
    let owner = UUID()
    securityGeneration = owner
    publishSecurityReport(["scope": "formulae", "status": "checking"], context: context, owner: owner)
    return context
  }

  /// Trust can be partially saved even when the command fails. Recheck independently of Update.
  func refreshSecurityAfterTrustChange(_ context: SecuritySnapshotContext?, brew: String) {
    guard let context, securityContext?.id == context.id, !terminating else { return }
    cancelSecurityRefresh()
    securityContext = context
    startSecurityRefresh([
      "snapshotID": context.id, "securityCheck": ["scope": "formulae", "status": "checking"],
    ], using: Inventory(brew: brew))
  }

  /// Record the inventory before handing it to WebKit; execution can start before its callback.
  func observeSecuritySnapshot(_ snapshot: Record) {
    guard let id = snapshot["snapshotID"] as? String, securityContext?.id != id else { return }
    cancelSecurityRefresh()
    securityContext = SecuritySnapshotContext(id: id)
  }

  func suspendSecurityForOperation() {
    let context = securityContext
    cancelSecurityRefresh()
    interruptedSecurityContext = context
  }

  /// An operation can finish without a replacement snapshot (execution or refresh failure).
  func finishInterruptedSecurity(hasFreshSnapshot: Bool) {
    let context = interruptedSecurityContext
    interruptedSecurityContext = nil
    guard !hasFreshSnapshot, let context, !terminating else { return }
    cancelSecurityRefresh()
    securityContext = context
    let owner = UUID()
    securityGeneration = owner
    publishSecurityReport([
      "scope": "formulae", "status": "failed",
      "error": "The inventory could not be refreshed after the package operation. Refresh before checking security again.",
    ], context: context, owner: owner)
  }

  /// Reports live only in this app session; scans never write to the inventory file.
  func startSecurityRefresh(_ snapshot: Record, using suppliedInventory: Inventory? = nil) {
    guard !terminating, operation.phase != .running, inventoryRefreshState != "refreshing",
      let snapshotID = snapshot["snapshotID"] as? String,
      securityContext?.id == snapshotID else { return }
    if let latest = latestSecurityReport, latest.snapshotID == snapshotID {
      deliverSecurityReport(latest.report, snapshotID: snapshotID)
      return
    }
    guard
      (snapshot["securityCheck"] as? Record)?["status"] as? String == "checking",
      !(securityContext?.id == snapshotID && securityGeneration != nil) else { return }
    cancelSecurityRefresh()
    let context = SecuritySnapshotContext(id: snapshotID)
    securityContext = context
    let owner = UUID()
    securityGeneration = owner
    let inventory: Inventory
    do { inventory = try suppliedInventory ?? Inventory(brew: Inventory.locateBrew()) }
    catch {
      publishSecurityReport([
        "status": "failed", "scope": "formulae", "error": error.localizedDescription,
      ], context: context, owner: owner)
      return
    }
    securityInventory = inventory
    let version = (snapshot["environment"] as? Record)?["brewVersion"] as? String
    let cache = securitySupportCache
    DispatchQueue.global(qos: .utility).async {
      let report = FormulaSecurity.check(inventory: inventory, supportCache: cache, brewVersion: version)
      DispatchQueue.main.async {
        guard self.securityGeneration == owner, !self.terminating else { return }
        self.securityInventory = nil
        self.publishSecurityReport(report, context: context, owner: owner)
      }
    }
  }

  private func publishSecurityReport(_ report: Record, context: SecuritySnapshotContext, owner: UUID) {
    guard securityGeneration == owner, !terminating else { return }
    latestSecurityReport = (context.id, report)
    securityGeneration = nil
    deliverSecurityReport(report, snapshotID: context.id)
  }

  func restoreSecurityReport() {
    if let latest = latestSecurityReport {
      deliverSecurityReport(latest.report, snapshotID: latest.snapshotID)
    }
  }

  private func deliverSecurityReport(_ report: Record, snapshotID: String) {
    guard pageReady, !webRecovery.isRecovering else { return }
    // Keep a page-independent high-water mark: queued WebKit calls cannot revoke
    // a newer delivery, even when trust refresh keeps the same snapshot ID.
    securityDeliverySequence += 1
    web.callAsyncJavaScript(
      "window.setSecurityCheck(report, snapshotID, deliverySequence)",
      arguments: ["report": report, "snapshotID": snapshotID, "deliverySequence": securityDeliverySequence], in: nil, in: .page
    ) { result in
      if case .failure(let error) = result { NSLog("Security UI delivery failed: %@", error.localizedDescription) }
    }
  }
}
