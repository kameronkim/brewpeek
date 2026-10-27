import Cocoa
import WebKit

extension DesktopApp {
  func cancelSecurityRefresh() {
    let old = securityInventory
    securityInventory = nil
    securitySnapshotID = nil
    latestSecurityReport = nil
    old?.cancel()
  }

  /// Security work owns no mutation/refresh UI state. Its only write is a guarded snapshot patch.
  func startSecurityRefresh(_ snapshot: Record, using suppliedInventory: Inventory? = nil, at suppliedDestination: URL? = nil) {
    guard !terminating, operationPhase != .running,
      let snapshotID = snapshot["snapshotID"] as? String else { return }
    if let latest = latestSecurityReport, latest.snapshotID == snapshotID {
      deliverSecurityReport(latest.report, snapshotID: snapshotID)
      return
    }
    guard
      (snapshot["securityCheck"] as? Record)?["status"] as? String == "checking",
      securitySnapshotID != snapshotID else { return }
    cancelSecurityRefresh()
    let inventory: Inventory
    do { inventory = try suppliedInventory ?? Inventory(brew: Inventory.locateBrew()) }
    catch {
      let failure: Record = ["status": "failed", "scope": "formulae", "error": error.localizedDescription]
      latestSecurityReport = (snapshotID, failure)
      deliverSecurityReport(failure, snapshotID: snapshotID)
      return
    }
    securityInventory = inventory
    securitySnapshotID = snapshotID
    let destination = suppliedDestination ?? output
    let version = (snapshot["environment"] as? Record)?["brewVersion"] as? String
    let cache = securitySupportCache
    DispatchQueue.global(qos: .utility).async {
      let report = FormulaSecurity.check(inventory: inventory, supportCache: cache, brewVersion: version)
      DispatchQueue.main.async {
        guard self.securityInventory === inventory, !self.terminating else { return }
        // Save under the shared lock, off the main thread. A new task can invalidate ownership meanwhile.
        DispatchQueue.global(qos: .utility).async {
          let result = Result { try SecurityReportStore.update(report, snapshotID: snapshotID, at: destination) }
          DispatchQueue.main.async {
            guard self.securityInventory === inventory, !self.terminating else { return }
            self.securityInventory = nil
            switch result {
            case .success(true):
              self.latestSecurityReport = (snapshotID, report)
              self.deliverSecurityReport(report, snapshotID: snapshotID)
            case .success(false): break // Another snapshot owns the file now.
            case .failure:
              var failure = report
              failure["status"] = "failed"
              failure["error"] = "Could not save the security report. Refresh to check again."
              self.latestSecurityReport = (snapshotID, failure)
              self.deliverSecurityReport(failure, snapshotID: snapshotID)
            }
          }
        }
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
