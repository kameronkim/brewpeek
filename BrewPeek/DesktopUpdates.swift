import Cocoa
import WebKit

extension DesktopApp {
  func sendUpdate(_ event: Record) {
    if let snapshot = event["snapshot"] as? Record { observeSecuritySnapshot(snapshot) }
    webRecovery.remember(event)
    if webRecovery.isRecovering {
      reloadTerminatedWebContentIfReady()
      return
    }
    guard pageReady else {
      if let snapshot = event["snapshot"] as? Record { startSecurityRefresh(snapshot) }
      return
    }
    web.callAsyncJavaScript(
      "window.receiveUpdate(event)", arguments: ["event": event], in: nil, in: .page
    ) { result in
      if case .failure(let error) = result {
        NSLog("Update UI delivery failed: %@", error.localizedDescription)
      }
      if let snapshot = event["snapshot"] as? Record { self.startSecurityRefresh(snapshot) }
    }
  }
  func handleUpdate(_ body: Any) {
    guard let request = body as? Record, let action = request["action"] as? String else { return }
    if action == "dismissResults" {
      guard !busy, !operation.hasPlan else { return }
      webRecovery.lastResult = nil
      return
    }
    if action == "cancel" {
      cancelUpdatePreparation()
      return
    }
    guard !busy else { return }

    if ["prepare", "prepareUninstall", "prepareVersions"].contains(action),
      let keys = request["keys"] as? [String] { webRecovery.keys = keys }
    switch action {
    case "quitUpdateApps":
      guard let token = request["token"] as? String,
        let requestID = request["requestID"] as? String, requestID == operation.requestID,
        case let .update(plan)? = operation.plan, token == plan.token,
        token == operation.blockedUpdateToken
      else { return }
      let apps = matchingRunningApps(for: plan.packages).filter {
        $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
      }
      var declined: [String] = []
      for app in apps {
        if !app.terminate() { declined.append(app.localizedName ?? "App") }
      }
      sendUpdate([
        "kind": "appQuitRequested", "requestID": requestID,
        "message": apps.isEmpty
          ? "The apps are no longer running. Retry to continue."
          : declined.isEmpty
            ? "Quit requested. Save any open work and wait for the apps to close, then retry."
            : "Some apps could not be asked to quit. Close them manually, then retry.",
      ])
    case "startTrust":
      guard let token = request["token"] as? String, case let .trust(plan)? = operation.plan,
        token == plan.token else { return }
      startUpdateTrust(plan, requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "prepareVersions":
      guard let keys = request["keys"] as? [String], keys.count == 1 else { return }
      prepareVersionCleanup(
        key: keys[0], requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "startVersions":
      guard let token = request["token"] as? String, case let .versions(plan)? = operation.plan,
        token == plan.token, let selected = request["versions"] as? [String]
      else { return }
      startVersionCleanup(
        plan, selected: selected, requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "prepareCleanup":
      guard let id = request["recoveryID"] as? String else { return }
      prepareSavedCleanup(id: id, requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "startCleanup":
      guard let token = request["token"] as? String, case let .cleanup(plan)? = operation.plan, token == plan.token
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
        case let .uninstall(plan)? = operation.plan, token == plan.token
      else { return }
      startPackageRemoval(plan, requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "prepare":
      guard let keys = request["keys"] as? [String], !keys.isEmpty else { return }
      prepareUpdate(keys: keys, requestID: request["requestID"] as? String ?? UUID().uuidString)
    case "start":
      guard let token = request["token"] as? String,
        case let .update(plan)? = operation.plan, token == plan.token
      else { return }
      startUpdate(plan, requestID: request["requestID"] as? String ?? UUID().uuidString)
    default:
      break
    }
  }

  private func cancelUpdatePreparation() {
    operation.blockedUpdateToken = nil
    if operation.isPreparing {
      // Keep ownership until the worker acknowledges cancellation; do not admit another task yet.
      operation.cancelledRequestID = operation.requestID
      operation.plan = nil
      operation.control?.cancel()
    } else if !busy {
      operation.requestID = nil
      operation.plan = nil
      sendUpdate(["kind": "cancelled"])
    }
  }

  /// Register read-only work before notifying the web UI, on the main queue.
  func beginPackagePreparation(
    requestID: String, rechecking: Bool = false,
    operation: String? = nil, message: String? = nil
  ) -> UpgradePreparation {
    reportLoadID = nil
    let control = self.operation.beginPreparation(requestID: requestID, rechecking: rechecking)
    var event: Record = ["kind": "checking", "requestID": requestID]
    if let operation { event["operation"] = operation }
    if let message { event["message"] = message }
    sendUpdate(event)
    return control
  }

  func prepareUpdate(keys: [String], requestID: String, brew: String? = nil) {
    preparePackagePlan(requestID: requestID, operation: "update") { control, _ in
      .update(try Upgrade(brew: brew ?? Inventory.locateBrew()).prepare(keys: keys, control: control))
    }
  }

  private func startUpdate(_ plan: UpgradePlan, requestID: String) {
    operation.requestID = requestID
    let active = runningApps(for: plan.packages)
    guard active.isEmpty else {
      reportRunningUpdateApps(active, plan: plan, requestID: requestID)
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
          let shouldStart = DispatchQueue.main.sync {
            guard self.acceptRecheckedPlan(
              .update(fresh), unchanged: fresh.fingerprint == plan.fingerprint,
              requestID: requestID
            ) else { return false }
            return self.beginPreparedUpdate(fresh, requestID: requestID)
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
          result["command"] = try UpgradeTrust.commands(fresh.selected, preview: false).map { arguments in
            ([engine.inventory.brew] + arguments).map {
              "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }.joined(separator: " ")
          }.joined(separator: " && ")
          let completed = result
          DispatchQueue.main.async {
            self.finishPackageOperation(completed, requestID: requestID)
          }
        }
      } catch {
        DispatchQueue.main.async {
          if let required = error as? UpgradeTrustRequired {
            self.publishPackagePlan(.trust(required.plan), requestID: requestID)
            return
          }
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
      reportRunningUpdateApps(active, plan: plan, requestID: requestID)
      return false
    }
    return beginPackageExecution(record: plan.record, requestID: requestID)
  }

  /// Retain the approved plan so Retry rechecks it instead of requesting approval again.
  private func reportRunningUpdateApps(_ names: [String], plan: UpgradePlan, requestID: String) {
    operation.plan = .update(plan)
    operation.blockedUpdateToken = plan.token
    sendUpdate([
      "kind": "error", "runningApps": names, "retryUpdateToken": plan.token,
      "message": "Close these apps before updating, then retry: " + names.joined(separator: ", "),
      "requestID": requestID,
    ])
  }

  /// Runs on the main queue, including the final cancellation gate before mutation.
  func isCurrentPreparation(_ requestID: String) -> Bool {
    operation.ownsPreparation(requestID)
  }

  func finishPreparation(_ requestID: String) -> Bool {
    switch operation.finishPreparation(requestID) {
    case .obsolete: return false
    case .cancelled:
      sendUpdate(["kind": "cancelled", "requestID": requestID])
      return false
    case .ready: return true
    }
  }
  /// Complete only the operation that still owns the native state, on the main queue.
  @discardableResult
  func finishPackageOperation(_ event: Record, requestID: String) -> Bool {
    guard operation.requestID == requestID else { return false }
    if operation.isPreparing, !finishPreparation(requestID) { return false }
    guard operation.complete(requestID) else { return false }
    var completed = event
    completed["requestID"] = requestID
    sendUpdate(completed)
    finishInterruptedSecurity(hasFreshSnapshot: completed["snapshot"] is Record)
    return true
  }

  func matchingRunningApps(for packages: [UpgradePackage]) -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { app in
      guard let url = app.bundleURL else { return false }
      return packages.contains { package in
        package.type == "cask" && package.apps.contains { CaskApps.matches($0, running: url) }
      }
    }
  }

  func runningApps(for packages: [UpgradePackage]) -> [String] {
    Array(Set(matchingRunningApps(for: packages).map {
      $0.localizedName ?? $0.bundleURL?.deletingPathExtension().lastPathComponent ?? "App"
    })).sorted()
  }
  private func permitClose() -> Bool {
    guard
      operation.isExecuting || operation.hasPlan
    else {
      return true
    }
    sendUpdate([
      "kind": "closeBlocked",
      "message": operation.isExecuting
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
