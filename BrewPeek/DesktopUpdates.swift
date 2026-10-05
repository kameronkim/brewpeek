import Cocoa
import WebKit

extension DesktopApp {
  func sendUpdate(_ event: Record) {
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
    if action == "cancel" {
      cancelUpdatePreparation()
      return
    }
    guard !busy else { return }

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
      updateRequestID = nil
      operationPlan = nil
      preparationControl?.cancel()
    } else if !busy {
      updateRequestID = nil
      operationPlan = nil
      sendUpdate(["kind": "cancelled"])
    }
  }

  private func prepareUpdate(keys: [String], requestID: String) {
    reportLoadID = nil
    operationPhase = .preparing
    updateRequestID = requestID
    operationPlan = nil
    sendUpdate(["kind": "checking", "requestID": requestID])
    let destination = output
    let control = UpgradePreparation()
    preparationControl = control
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
    operationPhase = .rechecking
    operationPlan = nil
    sendUpdate([
      "kind": "checking", "message": "Rechecking the confirmed plan…", "requestID": requestID,
    ])
    let destination = output
    let control = UpgradePreparation()
    preparationControl = control
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
            self.operationPhase = .idle
            self.updateRequestID = nil
            self.sendUpdate(completed)
          }
        }
      } catch {
        DispatchQueue.main.async {
          if self.updatePreparing {
            guard self.finishPreparation(requestID) else { return }
          } else {
            self.updateRequestID = nil
          }
          self.operationPhase = .idle
          self.sendUpdate([
            "kind": "error", "message": error.localizedDescription, "requestID": requestID,
          ])
        }
      }
    }
  }

  /// Check the freshly prepared targets on the main queue immediately before mutation.
  func beginPreparedUpdate(_ plan: UpgradePlan, requestID: String) -> Bool {
    guard updateRequestID == requestID else {
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
  func finishPreparation(_ requestID: String) -> Bool {
    operationPhase = .idle
    preparationControl = nil
    guard updateRequestID == requestID else {
      operationPlan = nil
      sendUpdate(["kind": "cancelled"])
      return false
    }
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
