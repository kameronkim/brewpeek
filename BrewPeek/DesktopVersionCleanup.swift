import Cocoa

extension DesktopApp {
  func prepareVersionCleanup(key: String, requestID: String) {
    reportLoadID = nil
    operationPhase = .preparing
    updateRequestID = requestID
    operationPlan = nil
    let control = UpgradePreparation()
    preparationControl = control
    let destination = output
    sendUpdate(["kind": "checking", "operation": "version-cleanup", "requestID": requestID])
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let plan = try Upgrade.withLock(at: destination) {
          try VersionCleanup(brew: Inventory.locateBrew()).prepare(key: key, control: control)
        }
        DispatchQueue.main.async {
          guard self.finishPreparation(requestID) else { return }
          self.operationPlan = .versions(plan)
          self.sendUpdate(["kind": "plan", "plan": plan.record, "requestID": requestID])
        }
      } catch {
        DispatchQueue.main.async {
          guard self.finishPreparation(requestID) else { return }
          self.sendUpdate([
            "kind": "error", "message": error.localizedDescription, "requestID": requestID,
          ])
        }
      }
    }
  }
  func startVersionCleanup(_ plan: VersionCleanupPlan, selected: [String], requestID: String) {
    guard !selected.isEmpty, Set(selected).count == selected.count,
      selected.allSatisfy({ v in plan.versions.contains { $0.version == v && $0.removable } })
    else { return }
    operationPhase = .rechecking
    updateRequestID = requestID
    operationPlan = nil
    let control = UpgradePreparation()
    preparationControl = control
    let destination = output
    sendUpdate([
      "kind": "checking", "operation": "version-cleanup", "requestID": requestID,
      "message": "Rechecking installed versions…",
    ])
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let cleanup = VersionCleanup(brew: try Inventory.locateBrew())
        try Upgrade.withLock(at: destination) {
          let fresh = try cleanup.prepare(key: plan.key, control: control)
          let shouldStart = DispatchQueue.main.sync { () -> Bool in
            guard self.isCurrentPreparation(requestID) else {
              _ = self.finishPreparation(requestID)
              return false
            }
            guard fresh.fingerprint == plan.fingerprint else {
              guard self.finishPreparation(requestID) else { return false }
              self.operationPlan = .versions(fresh)
              self.sendUpdate([
                "kind": "plan", "plan": fresh.record, "changed": true, "requestID": requestID,
              ])
              return false
            }
            self.operationPhase = .running
            self.preparationControl = nil
            var record = fresh.record
            record["packages"] = (record["packages"] as? [Record])?.filter {
              selected.contains($0["version"] as? String ?? "")
            }
            self.sendUpdate(["kind": "started", "plan": record, "requestID": requestID])
            return true
          }
          guard shouldStart else { return }
          var result = try cleanup.execute(fresh, selected: selected) { event in
            var event = event
            event["requestID"] = requestID
            DispatchQueue.main.async { self.sendUpdate(event) }
          }
          OperationInventory.append(
            to: &result, inventory: cleanup.engine.inventory, destination: destination,
            invalidatingSizes: [fresh.key], installedInfo: cleanup.engine.latestInstalledInfo)
          result["requestID"] = requestID
          let completed = result
          DispatchQueue.main.async {
            self.finishPackageOperation(completed, requestID: requestID)
          }
        }
      } catch {
        DispatchQueue.main.async {
          guard self.finishPackageOperation([
            "kind": "error", "message": error.localizedDescription,
          ], requestID: requestID) else { return }
        }
      }
    }
  }
}
