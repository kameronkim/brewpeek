import Cocoa

/// Lives with one running update. Only the reopen preference survives completion.
struct UpdateQuit {
  static let preferenceKey = "reopenUpdatedAppsBeforeQuitting"
  let closedApps: Set<QuitCaskApp>
  var reopenBeforeQuit: Bool?
  var isReopening = false

  func prompt(requestID: String, preferences: UserDefaults) -> Record {
    [
      "kind": "offerUpdateQuit", "requestID": requestID,
      "apps": closedApps.map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent }.sorted(),
      "reopen": preferences.object(forKey: Self.preferenceKey) as? Bool ?? true,
    ]
  }

  static func canQuit(after result: Record) -> Bool {
    guard result["kind"] as? String == "result", result["verified"] as? Bool == true,
      result["exitCode"] as? Int32 == 0, (result["commandWarning"] as? String ?? "").isEmpty,
      result["refreshError"] == nil, result["snapshot"] is Record,
      let packages = result["packages"] as? [Record], !packages.isEmpty else { return false }
    return packages.allSatisfy {
      let outcome = $0["outcome"] as? String
      return outcome == "updated" || outcome == "installed"
    }
  }
}

extension DesktopApp {
  func setUpdateQuit(action: String, request: Record) {
    guard let id = request["requestID"] as? String, id == operation.requestID,
      var update = operation.updateQuit else { return }
    if action == "cancelScheduledQuit" {
      update.reopenBeforeQuit = nil
    } else {
      guard !update.isReopening, let reopen = request["reopen"] as? Bool else { return }
      update.reopenBeforeQuit = !update.closedApps.isEmpty && reopen
      if !update.closedApps.isEmpty { preferences.set(reopen, forKey: UpdateQuit.preferenceKey) }
    }
    operation.updateQuit = update
    sendUpdate(["kind": "quitScheduled", "requestID": id, "scheduled": update.reopenBeforeQuit != nil])
  }

  func finishUpdate(
    _ result: Record, requestID: String,
    open: (Record, @escaping (String?) -> Void) -> Void = QuitCaskApp.open,
    quit: @escaping () -> Void = { NSApp.terminate(nil) }
  ) {
    guard operation.requestID == requestID, operation.updateQuit?.isReopening != true else { return }
    guard let update = operation.updateQuit, let reopen = update.reopenBeforeQuit,
      UpdateQuit.canQuit(after: result) else {
      finishPackageOperation(result, requestID: requestID)
      return
    }
    guard reopen else {
      if finishPackageOperation(result, requestID: requestID) { quit() }
      return
    }

    // The updater emits one native token per verified app. An absent target must keep BrewPeek open.
    let targets = result["reopenApps"] as? [String: Record] ?? [:]
    var messages = targets.count == update.closedApps.count ? [] : ["Some updated apps could not be located."]
    var remaining = Set(targets.keys)
    var retryTargets = targets
    operation.updateQuit?.isReopening = true
    func finishReopening() {
      var completed = result
      completed["reopenApps"] = retryTargets
      if !messages.isEmpty { completed["reopenWarning"] = messages.sorted().joined(separator: " ") }
      let shouldQuit = messages.isEmpty && operation.updateQuit?.reopenBeforeQuit == true
      if finishPackageOperation(completed, requestID: requestID), shouldQuit { quit() }
    }
    guard !targets.isEmpty else { finishReopening(); return }
    sendUpdate(["kind": "reopeningForQuit", "requestID": requestID])
    for (token, target) in targets {
      open(target) { error in
        guard self.operation.requestID == requestID, remaining.remove(token) != nil else { return }
        if let error {
          let name = target["name"] as? String ?? "App"
          messages.append("\(name) could not be reopened. \(error)")
        } else {
          retryTargets.removeValue(forKey: token)
        }
        if remaining.isEmpty { finishReopening() }
      }
    }
  }
}
