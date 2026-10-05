import Cocoa

extension DesktopApp {
  func prepareVersionCleanup(key: String, requestID: String) {
    reportLoadID = nil
    busy = true
    updatePreparing = true
    updateRequestID = requestID
    updatePlan = nil
    removalPlan = nil
    cleanupPlan = nil
    versionCleanupPlan = nil
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
          self.versionCleanupPlan = plan
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
    busy = true
    updateInProgress = true
    updatePreparing = true
    updateRequestID = requestID
    versionCleanupPlan = nil
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
            guard self.updateRequestID == requestID else {
              _ = self.finishPreparation(requestID)
              return false
            }
            guard fresh.fingerprint == plan.fingerprint else {
              guard self.finishPreparation(requestID) else { return false }
              self.versionCleanupPlan = fresh
              self.sendUpdate([
                "kind": "plan", "plan": fresh.record, "changed": true, "requestID": requestID,
              ])
              return false
            }
            self.updatePreparing = false
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
            invalidatingSizes: [fresh.key])
          result["requestID"] = requestID
          let completed = result
          DispatchQueue.main.async {
            self.busy = false
            self.updateInProgress = false
            self.updateRequestID = nil
            self.sendUpdate(completed)
          }
        }
      } catch {
        DispatchQueue.main.async {
          if self.updatePreparing { guard self.finishPreparation(requestID) else { return } }
          self.busy = false
          self.updateInProgress = false
          self.updateRequestID = nil
          self.sendUpdate([
            "kind": "error", "message": error.localizedDescription, "requestID": requestID,
          ])
        }
      }
    }
  }
}
