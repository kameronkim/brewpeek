import Cocoa

extension DesktopApp {
  func preparePackageRemoval(key: String, requestID: String) {
    reportLoadID = nil
    operationPhase = .preparing
    updateRequestID = requestID
    operationPlan = nil
    let control = UpgradePreparation()
    preparationControl = control
    let destination = output
    sendUpdate(["kind": "checking", "operation": "uninstall", "requestID": requestID])
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let removal = PackageRemoval(brew: try Inventory.locateBrew())
        let plan = try Upgrade.withLock(at: destination) {
          if let task = try RemovalTaskStore.load(at: destination), task.root.package.id != key {
            throw InventoryError(
              message: "Finish or discard the saved cleanup task before starting another uninstall."
            )
          }
          return try removal.prepare(key: key, control: control)
        }
        DispatchQueue.main.async {
          guard self.finishPreparation(requestID) else { return }
          self.operationPlan = .uninstall(plan)
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
    operationPhase = .rechecking
    updateRequestID = requestID
    operationPlan = nil
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
          if let task = try RemovalTaskStore.load(at: destination),
            task.root.package.id != plan.package.id
          {
            throw InventoryError(
              message: "Another saved cleanup task exists. Review it before continuing.")
          }
          let fresh = try removal.prepare(key: plan.package.id, control: control)
          let shouldStart = DispatchQueue.main.sync { () -> Bool in
            guard self.isCurrentPreparation(requestID) else {
              _ = self.finishPreparation(requestID)
              return false
            }
            guard fresh.fingerprint == plan.fingerprint else {
              guard self.finishPreparation(requestID) else { return false }
              self.operationPlan = .uninstall(fresh)
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
            self.operationPhase = .running
            self.preparationControl = nil
            self.sendUpdate(["kind": "started", "plan": fresh.record, "requestID": requestID])
            return true
          }
          guard shouldStart else { return }
          let task = RemovalTask(fresh)
          try RemovalTaskStore.save(task, at: destination)
          var result = try removal.execute(fresh) { event in
            var event = event
            event["requestID"] = requestID
            DispatchQueue.main.async { self.sendUpdate(event) }
          }
          let pending = try RemovalTaskStore.finish(task, result: result, at: destination)
          if pending {
            result["recoveryID"] = task.id
            result["pendingCleanup"] =
              (result["packages"] as? [Record])?.first?["actualVersion"] as? String
              == "Not installed"
          }
          OperationInventory.append(
            to: &result, inventory: removal.engine.inventory, destination: destination,
            invalidatingSizes: Set(fresh.packages.map(\.id)), installedInfo: removal.engine.latestInstalledInfo)
          result["retryKeys"] = [fresh.package.id]
          result["requestID"] = requestID
          var command = [
            removal.engine.inventory.brew, "uninstall",
            fresh.package.type == "cask" ? "--cask" : "--formula",
          ]
          if fresh.package.type == "formula" && fresh.package.current.count > 1 {
            command.append("--force")
          }
          command.append(fresh.package.argument)
          result["command"] =
            "HOMEBREW_NO_AUTOREMOVE=1 "
            + command
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(
              separator: " ")
          if (result["packages"] as? [Record])?.first?["actualVersion"] as? String
            == "Not installed"
          {
            result.removeValue(forKey: "command")
          }
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
          self.recoveryChecked = false
          self.restorePendingRemoval()
        }
      }
    }
  }

  func restorePendingRemoval() {
    guard !recoveryChecked, !busy, inventoryRefreshState == "idle" else { return }
    recoveryChecked = true
    auxiliaryBusy = true
    sendUpdate(["kind": "recoveryChecking"])
    let destination = output
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result<Record?, Error> {
        try Upgrade.withLock(at: destination) {
          guard let task = try RemovalTaskStore.load(at: destination) else { return nil }
          let removal = PackageRemoval(brew: try Inventory.locateBrew())
          var result = try removal.recoveryResult(task)
          if !(try RemovalTaskStore.finish(task, result: result, at: destination)) {
            result.removeValue(forKey: "recoveryID")
          }
          return result
        }
      }
      DispatchQueue.main.async {
        self.auxiliaryBusy = false
        switch result {
        case .success(let record): self.sendUpdate(record ?? ["kind": "recoveryEmpty"])
        case .failure(let error):
          self.sendUpdate(["kind": "recoveryError", "message": error.localizedDescription])
        }
      }
    }
  }

  func prepareSavedCleanup(id: String, requestID: String) {
    reportLoadID = nil
    operationPhase = .preparing
    updateRequestID = requestID
    operationPlan = nil
    let control = UpgradePreparation()
    preparationControl = control
    let destination = output
    sendUpdate(["kind": "checking", "operation": "cleanup", "requestID": requestID])
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let plan = try Upgrade.withLock(at: destination) {
          guard let task = try RemovalTaskStore.load(at: destination), task.id == id else {
            throw InventoryError(
              message: "The saved cleanup task changed. Refresh before retrying.")
          }
          return try PackageRemoval(brew: Inventory.locateBrew()).prepareCleanup(
            task, control: control)
        }
        DispatchQueue.main.async {
          guard self.finishPreparation(requestID) else { return }
          self.operationPlan = .cleanup(plan)
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

  func startSavedCleanup(_ plan: CleanupPlan, requestID: String) {
    operationPhase = .rechecking
    updateRequestID = requestID
    operationPlan = nil
    let control = UpgradePreparation()
    preparationControl = control
    let destination = output
    sendUpdate([
      "kind": "checking", "operation": "cleanup", "message": "Rechecking remaining dependencies…",
      "requestID": requestID,
    ])
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let removal = PackageRemoval(brew: try Inventory.locateBrew())
        try Upgrade.withLock(at: destination) {
          guard let task = try RemovalTaskStore.load(at: destination), task.id == plan.task.id
          else {
            throw InventoryError(message: "The saved cleanup task changed. Review it again.")
          }
          let fresh = try removal.prepareCleanup(task, control: control)
          let shouldStart = DispatchQueue.main.sync { () -> Bool in
            guard self.isCurrentPreparation(requestID) else {
              _ = self.finishPreparation(requestID)
              return false
            }
            guard fresh.fingerprint == plan.fingerprint else {
              guard self.finishPreparation(requestID) else { return false }
              self.operationPlan = .cleanup(fresh)
              self.sendUpdate([
                "kind": "plan", "plan": fresh.record, "changed": true, "requestID": requestID,
              ])
              return false
            }
            self.operationPhase = .running
            self.preparationControl = nil
            self.sendUpdate(["kind": "started", "plan": fresh.record, "requestID": requestID])
            return true
          }
          guard shouldStart else { return }
          var result = try removal.executeCleanup(fresh) { event in
            var event = event
            event["requestID"] = requestID
            DispatchQueue.main.async { self.sendUpdate(event) }
          }
          let pending = try RemovalTaskStore.finish(task, result: result, at: destination)
          if pending {
            result["recoveryID"] = task.id
            result["pendingCleanup"] = result["verified"] as? Bool != true
              || (result["packages"] as? [Record])?.first?["actualVersion"] as? String == "Not installed"
          }
          OperationInventory.append(
            to: &result, inventory: removal.engine.inventory, destination: destination,
            invalidatingSizes: Set(fresh.packages.map(\.id)), installedInfo: removal.engine.latestInstalledInfo)
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
          self.recoveryChecked = false
          self.restorePendingRemoval()
        }
      }
    }
  }

  func discardSavedCleanup(id: String, requestID: String) {
    auxiliaryBusy = true
    updateRequestID = requestID
    let destination = output
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try Upgrade.withLock(at: destination) {
          try RemovalTaskStore.clear(at: destination, id: id)
        }
        DispatchQueue.main.async {
          self.auxiliaryBusy = false
          self.updateRequestID = nil
          self.sendUpdate(["kind": "cleanupDiscarded", "requestID": requestID])
        }
      } catch {
        DispatchQueue.main.async {
          self.auxiliaryBusy = false
          self.updateRequestID = nil
          self.sendUpdate([
            "kind": "error", "message": error.localizedDescription, "requestID": requestID,
          ])
        }
      }
    }
  }

}
