import Cocoa

extension DesktopApp {
  func preparePackageRemoval(key: String, requestID: String) {
    reportLoadID = nil
    busy = true
    updatePreparing = true
    updateRequestID = requestID
    updatePlan = nil
    removalPlan = nil
    let control = UpgradePreparation()
    preparationControl = control
    let destination = output
    sendUpdate(["kind": "checking", "operation": "uninstall", "requestID": requestID])
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let removal = PackageRemoval(brew: try Inventory.locateBrew())
        let plan = try Upgrade.withLock(at: destination) {
          try removal.prepare(key: key, control: control)
        }
        DispatchQueue.main.async {
          guard self.finishPreparation(requestID) else { return }
          self.removalPlan = plan
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

  func startPackageRemoval(_ plan: PackageRemovalPlan, requestID: String) {
    busy = true
    updateInProgress = true
    updatePreparing = true
    updateRequestID = requestID
    removalPlan = nil
    let control = UpgradePreparation()
    preparationControl = control
    let destination = output
    sendUpdate([
      "kind": "checking", "message": "Rechecking the selected package…", "requestID": requestID,
    ])
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let removal = PackageRemoval(brew: try Inventory.locateBrew())
        try Upgrade.withLock(at: destination) {
          let fresh = try removal.prepare(key: plan.package.id, control: control)
          let shouldStart = DispatchQueue.main.sync { () -> Bool in
            guard self.updateRequestID == requestID else {
              _ = self.finishPreparation(requestID)
              return false
            }
            guard fresh.fingerprint == plan.fingerprint else {
              guard self.finishPreparation(requestID) else { return false }
              self.removalPlan = fresh
              self.sendUpdate([
                "kind": "plan", "plan": fresh.record, "changed": true, "requestID": requestID,
              ])
              return false
            }
            let active = self.runningApps(for: [fresh.package])
            guard active.isEmpty else {
              guard self.finishPreparation(requestID) else { return false }
              self.sendUpdate([
                "kind": "error", "runningApps": active, "requestID": requestID,
                "message": "Close these apps before uninstalling: "
                  + active.joined(separator: ", "),
              ])
              return false
            }
            self.updatePreparing = false
            self.preparationControl = nil
            self.sendUpdate(["kind": "started", "plan": fresh.record, "requestID": requestID])
            return true
          }
          guard shouldStart else { return }
          var result = try removal.execute(fresh) { event in
            var event = event
            event["requestID"] = requestID
            DispatchQueue.main.async { self.sendUpdate(event) }
          }
          do {
            let snapshot = try removal.engine.inventory.collect(
              refreshMetadata: false, previous: try? InventoryStore.load(destination),
              invalidatingSizes: Set(fresh.packages.map(\.id)))
            try InventoryStore.save(snapshot, to: destination)
            result["snapshot"] = InventoryStore.displaySnapshot(snapshot)
          } catch { result["refreshError"] = error.localizedDescription }
          result["retryKeys"] = [fresh.package.id]
          result["requestID"] = requestID
          result["command"] =
            "HOMEBREW_NO_AUTOREMOVE=1 "
            + [
              removal.engine.inventory.brew, "uninstall",
              fresh.package.type == "cask" ? "--cask" : "--formula", fresh.package.argument,
            ]
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(
              separator: " ")
          if (result["packages"] as? [Record])?.first?["actualVersion"] as? String
            == "Not installed"
          {
            result.removeValue(forKey: "command")
          }
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
          if self.updatePreparing {
            guard self.finishPreparation(requestID) else { return }
          }
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
