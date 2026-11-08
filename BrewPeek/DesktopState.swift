import Foundation

/// Main-queue state owned by the native package worker, including its cancellation gate.
struct PackageOperationState {
  enum PreparationCompletion { case obsolete, cancelled, ready }

  var phase: PackageOperationPhase = .idle
  var requestID: String?
  var cancelledRequestID: String?
  // Read-only recovery inspection also uses the native preparation control.
  var control: UpgradePreparation?
  var blockedUpdateToken: String?
  var plan: PackageOperationPlan?
  var isPreparing: Bool { phase.isPreparing }
  var isExecuting: Bool { phase.isExecuting }
  var hasPlan: Bool { plan != nil }

  mutating func beginPreparation(requestID: String, rechecking: Bool) -> UpgradePreparation {
    phase = rechecking ? .rechecking : .preparing
    self.requestID = requestID
    cancelledRequestID = nil
    blockedUpdateToken = nil
    plan = nil
    let control = UpgradePreparation()
    self.control = control
    return control
  }

  func ownsPreparation(_ requestID: String) -> Bool {
    self.requestID == requestID && cancelledRequestID != requestID
  }

  mutating func finishPreparation(_ requestID: String) -> PreparationCompletion {
    guard self.requestID == requestID else { return .obsolete }
    phase = .idle
    control = nil
    if cancelledRequestID == requestID {
      cancelledRequestID = nil
      self.requestID = nil
      plan = nil
      return .cancelled
    }
    return .ready
  }

  /// A late callback must not clear the state belonging to a newer request.
  mutating func complete(_ requestID: String) -> Bool {
    guard self.requestID == requestID else { return false }
    self = PackageOperationState()
    return true
  }
}

/// Display recovery is independent of native worker ownership and never restarts a command.
struct WebRecoveryState {
  var isRecovering = false
  var isLoading = false
  var isRestoring = false
  var pendingEvent: Record?
  var lastResult: Record?
  var operationKind = "update"
  var keys: [String] = []

  mutating func remember(_ event: Record) {
    let kind = event["kind"] as? String
    if let operation = event["operation"] as? String { operationKind = operation }
    if let plan = event["plan"] as? Record {
      operationKind = plan["operation"] as? String ?? "update"
    }
    if kind == "started" { lastResult = nil }
    if kind == "result" {
      var result = event
      result.removeValue(forKey: "snapshot")
      lastResult = result
    } else if kind == "cleanupDiscarded", var result = lastResult {
      for key in ["recoveryID", "pendingCleanup", "recovered"] { result.removeValue(forKey: key) }
      lastResult = result
    }
    if kind == "checking" || kind == "cancelled" || kind == "cleanupDiscarded" {
      pendingEvent = nil
    }
    if kind == "error" || (isRecovering && kind == "plan") {
      var pending = event
      pending["operation"] = operationKind
      pending["retryKeys"] = keys
      pendingEvent = pending
    }
    if kind == "result" || kind == "started" { pendingEvent = nil }
  }

  func replayEvents(plan: PackageOperationPlan?, requestID: String?) -> [Record] {
    var events: [Record] = []
    if let result = lastResult { events.append(result) }
    if let pending = pendingEvent {
      if pending["kind"] as? String == "error" {
        events.append(["kind": "checking", "operation": operationKind])
      }
      events.append(pending)
    } else if let plan {
      events.append(["kind": "plan", "plan": plan.record, "requestID": requestID ?? ""])
    }
    return events
  }

  mutating func beginRecovery() {
    isRestoring = false
    isRecovering = true
    isLoading = false
  }

  /// Keep retained result/retry context; only the recovery attempt has finished.
  mutating func finishRecovery() {
    isRestoring = false
    isRecovering = false
    isLoading = false
    pendingEvent = nil
  }
}
