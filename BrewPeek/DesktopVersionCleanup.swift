import Cocoa

extension DesktopApp {
  func prepareVersionCleanup(key: String, requestID: String) {
    preparePackagePlan(requestID: requestID, operation: "version-cleanup") { control, _ in
      .versions(try VersionCleanup(brew: Inventory.locateBrew()).prepare(key: key, control: control))
    }
  }

  func startVersionCleanup(_ plan: VersionCleanupPlan, selected: [String], requestID: String) {
    guard !selected.isEmpty, Set(selected).count == selected.count,
      selected.allSatisfy({ v in plan.versions.contains { $0.version == v && $0.removable } })
    else { return }
    let control = beginPackagePreparation(
      requestID: requestID, rechecking: true, operation: "version-cleanup",
      message: "Rechecking installed versions…")
    let destination = output
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let cleanup = VersionCleanup(brew: try Inventory.locateBrew())
        try Upgrade.withLock(at: destination) {
          let fresh = try cleanup.prepare(key: plan.key, control: control)
          let shouldStart = DispatchQueue.main.sync { () -> Bool in
            guard self.acceptRecheckedPlan(
              .versions(fresh), unchanged: fresh.fingerprint == plan.fingerprint,
              requestID: requestID
            ) else { return false }
            var record = fresh.record
            record["packages"] = (record["packages"] as? [Record])?.filter {
              selected.contains($0["version"] as? String ?? "")
            }
            return self.beginPackageExecution(record: record, requestID: requestID)
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
