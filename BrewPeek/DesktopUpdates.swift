import Cocoa
import WebKit

extension DesktopApp {
  func sendUpdate(_ event: Record) {
    rememberWebOperationEvent(event)
    if recoveringWebContent {
      reloadTerminatedWebContentIfReady()
      return
    }
    guard pageReady else { return }
    web.callAsyncJavaScript(
      "window.receiveUpdate(event)", arguments: ["event": event], in: nil, in: .page
    ) { result in
      if case .failure(let error) = result {
        NSLog("Update UI delivery failed: %@", error.localizedDescription)
      }
    }
  }
  func handleUpdate(_ body: Any) {
    guard let request = body as? Record, let action = request["action"] as? String else { return }
    if action == "dismissResults" {
      guard !busy, !hasOperationPlan else { return }
      lastOperationResult = nil
      return
    }
    if action == "cancel" {
      cancelUpdatePreparation()
      return
    }
    guard !busy else { return }

    if ["prepare", "prepareUninstall", "prepareVersions"].contains(action),
      let keys = request["keys"] as? [String] { webRecoveryKeys = keys }
    switch action {
    case "prepareVersions":
      guard let keys = request["keys"] as? [String], keys.count == 1 else { return }
      prepareVersionCleanup(
        key: keys[0], requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "startVersions":
      guard let token = request["token"] as? String, case let .versions(plan)? = operationPlan,
        token == plan.token, let selected = request["versions"] as? [String]
      else { return }
      startVersionCleanup(
        plan, selected: selected, requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "prepareCleanup":
      guard let id = request["recoveryID"] as? String else { return }
      prepareSavedCleanup(id: id, requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "startCleanup":
      guard let token = request["token"] as? String, case let .cleanup(plan)? = operationPlan, token == plan.token
      else { return }
      startSavedCleanup(plan, requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "discardCleanup":
      guard let id = request["recoveryID"] as? String else { return }
      discardSavedCleanup(id: id, requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "prepareUninstall":
      guard let keys = request["keys"] as? [String], keys.count == 1 else { return }
      preparePackageRemoval(
        key: keys[0], requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "startUninstall":
      guard let token = request["token"] as? String,
        case let .uninstall(plan)? = operationPlan, token == plan.token
      else { return }
      startPackageRemoval(plan, requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "prepare":
      guard let keys = request["keys"] as? [String], !keys.isEmpty else { return }
      prepareUpdate(keys: keys, requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "start":
      guard let token = request["token"] as? String,
        case let .update(plan)? = operationPlan, token == plan.token
      else { return }
      startUpdate(plan, requestID: request["requestID"] as? String ?? UUID().uuidString)
    default:
      break
    }
  }

  private func cancelUpdatePreparation() {
    if updatePreparing {
      // Keep ownership until the worker acknowledges cancellation; do not admit another task yet.
      cancelledPreparationRequestID = updateRequestID
      operationPlan = nil
      preparationControl?.cancel()
    } else if !busy {
      updateRequestID = nil
      operationPlan = nil
      sendUpdate(["kind": "cancelled"])
    }
  }

  /// Register read-only work before notifying the web UI, on the main queue.
  func beginPackagePreparation(
    requestID: String, rechecking: Bool = false,
    operation: String? = nil, message: String? = nil
  ) -> UpgradePreparation {
    reportLoadID = nil
    operationPhase = rechecking ? .rechecking : .preparing
    updateRequestID = requestID
    cancelledPreparationRequestID = nil
    operationPlan = nil
    let control = UpgradePreparation()
    preparationControl = control
    var event: Record = ["kind": "checking", "requestID": requestID]
    if let operation { event["operation"] = operation }
    if let message { event["message"] = message }
    sendUpdate(event)
    return control
  }

  private func prepareUpdate(keys: [String], requestID: String) {
    let control = beginPackagePreparation(requestID: requestID, operation: "update")
    let destination = output
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let engine = Upgrade(brew: try Inventory.locateBrew())
        let plan = try Upgrade.withLock(at: destination) {
          try engine.prepare(keys: keys, control: control)
        }
        DispatchQueue.main.async {
          guard self.finishPreparation(requestID) else { return }
          self.operationPlan = .update(plan)
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

  private func startUpdate(_ plan: UpgradePlan, requestID: String) {
    updateRequestID = requestID
    let active = runningApps(for: plan.packages)
    guard active.isEmpty else {
      operationPlan = nil
      sendUpdate([
        "kind": "error", "runningApps": Array(Set(active)).sorted(),
        "message": "Close these apps before updating, then retry: "
          + active.joined(separator: ", "), "requestID": requestID,
      ])
      return
    }
    let control = beginPackagePreparation(
      requestID: requestID, rechecking: true, operation: "update", message: "Rechecking the confirmed plan…")
    let destination = output
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let engine = Upgrade(brew: try Inventory.locateBrew())
        try Upgrade.withLock(at: destination) {
          let fresh = try engine.prepare(keys: plan.selected.map(\.id), control: control)
          guard fresh.fingerprint == plan.fingerprint else {
            DispatchQueue.main.async {
              guard self.finishPreparation(requestID) else { return }
              self.operationPlan = .update(fresh)
              self.sendUpdate([
                "kind": "plan", "plan": fresh.record, "changed": true, "requestID": requestID,
              ])
            }
            return
          }
          let shouldStart = DispatchQueue.main.sync {
            self.beginPreparedUpdate(fresh, requestID: requestID)
          }
          guard shouldStart else { return }
          var result = try engine.execute(fresh) { event in
            var event = event
            event["requestID"] = requestID
            DispatchQueue.main.async { self.sendUpdate(event) }
          }
          // Keep results even if inventory collection fails after an otherwise completed upgrade.
          OperationInventory.append(
            to: &result, inventory: engine.inventory, destination: destination,
            invalidatingSizes: Set((result["packages"] as? [Record] ?? []).compactMap { $0["id"] as? String }), installedInfo: engine.latestInstalledInfo)
          result["retryKeys"] = fresh.selected.map(\.id)
          result["command"] =
            ([engine.inventory.brew, "upgrade"] + fresh.selected.map(\.argument)).map {
              "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }.joined(separator: " ")
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

  /// Check the freshly prepared targets on the main queue immediately before mutation.
  func beginPreparedUpdate(_ plan: UpgradePlan, requestID: String) -> Bool {
    guard isCurrentPreparation(requestID) else {
      _ = finishPreparation(requestID)
      return false
    }
    let active = runningApps(for: plan.packages)
    guard active.isEmpty else {
      guard finishPreparation(requestID) else { return false }
      sendUpdate([
        "kind": "error", "runningApps": active, "requestID": requestID,
        "message": "Close these apps before updating, then retry: "
          + active.joined(separator: ", "),
      ])
      return false
    }
    operationPhase = .running
    preparationControl = nil
    sendUpdate(["kind": "started", "plan": plan.record, "requestID": requestID])
    return true
  }

  /// Runs on the main queue, including the final cancellation gate before mutation.
  func isCurrentPreparation(_ requestID: String) -> Bool {
    updateRequestID == requestID && cancelledPreparationRequestID != requestID
  }

  func finishPreparation(_ requestID: String) -> Bool {
    // An obsolete callback must not release the current worker's state or cancellation control.
    guard updateRequestID == requestID else { return false }
    operationPhase = .idle
    preparationControl = nil
    if cancelledPreparationRequestID == requestID {
      cancelledPreparationRequestID = nil
      updateRequestID = nil
      operationPlan = nil
      sendUpdate(["kind": "cancelled", "requestID": requestID])
      return false
    }
    return true
  }
  /// Complete only the operation that still owns the native state, on the main queue.
  @discardableResult
  func finishPackageOperation(_ event: Record, requestID: String) -> Bool {
    guard updateRequestID == requestID else { return false }
    if updatePreparing, !finishPreparation(requestID) { return false }
    operationPhase = .idle
    operationPlan = nil
    preparationControl = nil
    cancelledPreparationRequestID = nil
    updateRequestID = nil
    var completed = event
    completed["requestID"] = requestID
    sendUpdate(completed)
    return true
  }

  func runningApps(for packages: [UpgradePackage]) -> [String] {
    let names = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
      guard let url = app.bundleURL,
        packages.contains(where: { package in
          package.type == "cask"
            && package.apps.contains { path in
              CaskApps.matches(path, running: url)
            }
        })
      else { return nil }
      return app.localizedName ?? url.deletingPathExtension().lastPathComponent
    }
    return Array(Set(names)).sorted()
  }
  private func permitClose() -> Bool {
    guard
      updateInProgress || hasOperationPlan
    else {
      return true
    }
    sendUpdate([
      "kind": "closeBlocked",
      "message": updateInProgress
        ? "Keep BrewPeek open until Homebrew finishes. Closing now could interrupt the package operation."
        : "Wait for the current operation to finish or cancel the package confirmation before closing BrewPeek."
        ,
    ])
    return false
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool { permitClose() }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    permitClose() ? .terminateNow : .terminateCancel
  }
}
