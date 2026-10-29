import Cocoa
import WebKit

struct SecuritySnapshotContext {
  let id: String
  let destination: URL
}

extension DesktopApp {
  func cancelSecurityRefresh() {
    let old = securityInventory
    securityInventory = nil
    securityContext = nil
    securityGeneration?.invalidate()
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
    let owner = SecurityReportGeneration()
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
    ], using: Inventory(brew: brew), at: context.destination)
  }

  /// Record the inventory before handing it to WebKit; execution can start before its callback.
  func observeSecuritySnapshot(_ snapshot: Record, at destination: URL? = nil) {
    guard let id = snapshot["snapshotID"] as? String, securityContext?.id != id else { return }
    cancelSecurityRefresh()
    securityContext = SecuritySnapshotContext(id: id, destination: destination ?? output)
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
    let owner = SecurityReportGeneration()
    securityGeneration = owner
    publishSecurityReport([
      "scope": "formulae", "status": "failed",
      "error": "The inventory could not be refreshed after the package operation. Refresh before checking security again.",
    ], context: context, owner: owner)
  }

  /// Security work owns no mutation/refresh UI state. Its only write is a guarded snapshot patch.
  func startSecurityRefresh(_ snapshot: Record, using suppliedInventory: Inventory? = nil, at suppliedDestination: URL? = nil) {
    guard !terminating, operationPhase != .running, inventoryRefreshState != "refreshing",
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
    let context = SecuritySnapshotContext(id: snapshotID, destination: suppliedDestination ?? output)
    securityContext = context
    let owner = SecurityReportGeneration()
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

  private func publishSecurityReport(_ report: Record, context: SecuritySnapshotContext, owner: SecurityReportGeneration) {
    latestSecurityReport = (context.id, report)
    deliverSecurityReport(report, snapshotID: context.id)
    persistSecurityReport(report, context: context, owner: owner)
  }

  /// Contention is temporary, not a scan failure. Retry only persistence, until ownership changes.
  private func persistSecurityReport(
    _ report: Record, context: SecuritySnapshotContext, owner: SecurityReportGeneration, retryDelay: TimeInterval = 0.1
  ) {
    guard securityGeneration == owner, !terminating else { return }
    DispatchQueue.global(qos: .utility).async {
      let result = Result { try SecurityReportStore.update(report, snapshotID: context.id, at: context.destination, generation: owner) }
      DispatchQueue.main.async {
        guard self.securityGeneration == owner, !self.terminating else { return }
        switch result {
        case .failure(let error):
          if case HomebrewOperationLock.Failure.busy = error {
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
              self.persistSecurityReport(report, context: context, owner: owner, retryDelay: min(2, retryDelay * 2))
            }
            return
          }
          var failure = report
          failure["status"] = "failed"
          failure["error"] = "Could not save the security report. Refresh to check again."
          self.latestSecurityReport = (context.id, failure)
          self.deliverSecurityReport(failure, snapshotID: context.id)
        case .success:
          break // A mismatched/missing snapshot must not be recreated or overwritten.
        }
        self.securityGeneration = nil
      }
    }
  }

  func restoreSecurityReport() {
    if let latest = latestSecurityReport {
      deliverSecurityReport(latest.report, snapshotID: latest.snapshotID)
    }
  }

  private func deliverSecurityReport(_ report: Record, snapshotID: String) {
    guard pageReady, !recoveringWebContent else { return }
    web.callAsyncJavaScript(
      "window.setSecurityCheck(report, snapshotID)",
      arguments: ["report": report, "snapshotID": snapshotID], in: nil, in: .page
    ) { result in
      if case .failure(let error) = result { NSLog("Security UI delivery failed: %@", error.localizedDescription) }
    }
  }
}
