import Cocoa

extension DesktopApp {
  /// This is the sole trust-writing path, reached only through the dedicated confirmation token.
  func startUpdateTrust(_ plan: UpgradeTrustPlan, requestID: String) {
    let control = beginPackagePreparation(requestID: requestID, operation: "trust")
    let destination = output
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let process = BrewProcess(brew: plan.brew)
        var trusted = false
        try Upgrade.withLock(at: destination) {
          let fresh = try UpgradeTrust.inspect(plan.keys, process: process, control: control)
          let blocked = fresh.filter { $0.state == "untrusted" }
          let approved = Set(plan.targets.map(\.fingerprint))
          guard blocked.allSatisfy({ approved.contains($0.fingerprint) }) else {
            DispatchQueue.main.async {
              self.publishPackagePlan(.trust(UpgradeTrustPlan(keys: plan.keys, brew: plan.brew, targets: blocked)), requestID: requestID, changed: true)
            }
            return
          }
          let allowed = DispatchQueue.main.sync { () -> Bool in
            guard self.isCurrentPreparation(requestID) else { _ = self.finishPreparation(requestID); return false }
            self.operationPhase = .running
            self.preparationControl = nil
            self.sendUpdate(["kind": "trusting", "requestID": requestID])
            return true
          }
          guard allowed else { return }
          for target in blocked {
            let result = try process.command(["trust", "--" + target.type, target.name])
            guard result.0 == 0 else {
              throw InventoryError(message: "Homebrew could not finish the approved trust changes. Some entries may already be saved.\n" + result.1)
            }
          }
          trusted = true
        }
        guard trusted else { return }
        DispatchQueue.main.async {
          guard self.updateRequestID == requestID else { return }
          self.operationPhase = .idle
          self.prepareUpdate(keys: plan.keys, requestID: requestID, brew: plan.brew)
        }
      } catch {
        DispatchQueue.main.async {
          self.finishPackageOperation(["kind":"error", "message":error.localizedDescription], requestID: requestID)
        }
      }
    }
  }
}
