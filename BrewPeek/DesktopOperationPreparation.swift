import Cocoa

extension DesktopApp {
  /// The worker owns the lock; only its current request may publish a plan or failure.
  func preparePackagePlan(
    requestID: String, operation: String,
    prepare: @escaping (UpgradePreparation, URL) throws -> PackageOperationPlan
  ) {
    let control = beginPackagePreparation(requestID: requestID, operation: operation)
    let destination = output
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result { try Upgrade.withLock(at: destination) { try prepare(control, destination) } }
      DispatchQueue.main.async {
        switch result {
        case .success(let plan):
          self.publishPackagePlan(plan, requestID: requestID)
        case .failure(let error):
          guard self.finishPreparation(requestID) else { return }
          self.sendUpdate([
            "kind": "error", "message": error.localizedDescription, "requestID": requestID,
          ])
        }
      }
    }
  }

  /// Shared by initial preparation and changed-plan confirmation, on the main queue.
  func publishPackagePlan(
    _ plan: PackageOperationPlan, requestID: String, changed: Bool = false
  ) {
    guard finishPreparation(requestID) else { return }
    operationPlan = plan
    var event: Record = ["kind": "plan", "plan": plan.record, "requestID": requestID]
    if changed { event["changed"] = true }
    sendUpdate(event)
  }

  /// Preserve cancellation ownership and require confirmation again if the plan changed.
  func acceptRecheckedPlan(
    _ plan: PackageOperationPlan, unchanged: Bool, requestID: String
  ) -> Bool {
    guard isCurrentPreparation(requestID) else {
      _ = finishPreparation(requestID)
      return false
    }
    guard unchanged else {
      publishPackagePlan(plan, requestID: requestID, changed: true)
      return false
    }
    return true
  }

  /// Call after the operation-specific checks, immediately before mutation.
  func beginPackageExecution(record: Record, requestID: String) -> Bool {
    guard isCurrentPreparation(requestID) else {
      _ = finishPreparation(requestID)
      return false
    }
    operationPhase = .running
    preparationControl = nil
    sendUpdate(["kind": "started", "plan": record, "requestID": requestID])
    return true
  }
}
