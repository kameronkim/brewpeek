import Cocoa

/// A registered app for which the user requested a normal quit during this update.
struct QuitCaskApp: Hashable {
  let packageID: String
  let path: String
  let bundleID: String

  static func targets(
    for quitApps: Set<Self>, updatedIDs: Set<String>, installed: [String: UpgradePackage]
  ) -> [String: Record] {
    var targets: [String: Record] = [:]
    for app in quitApps where updatedIDs.contains(app.packageID) {
      guard let cask = installed[app.packageID], cask.type == "cask",
        let path = cask.apps.first(where: { CaskApps.matches($0, running: URL(fileURLWithPath: app.path)) }),
        let url = installedURL(path: path, bundleID: app.bundleID)
      else { continue }
      targets[UUID().uuidString] = [
        "packageID": app.packageID, "name": url.deletingPathExtension().lastPathComponent,
        "path": path, "bundleID": app.bundleID,
      ]
    }
    return targets
  }

  static func installedURL(path: String, bundleID: String) -> URL? {
    let url = URL(fileURLWithPath: path)
    guard path.hasPrefix("/"), url.pathExtension.lowercased() == "app", !bundleID.isEmpty,
      let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
      let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? Record,
      info["CFBundlePackageType"] as? String == "APPL", info["CFBundleIdentifier"] as? String == bundleID
    else { return nil }
    return url
  }
}

extension DesktopApp {
  func reopenUpdatedApp(token: String, resultID: String) {
    guard let result = webRecovery.lastResult, result["requestID"] as? String == resultID,
      let apps = result["reopenApps"] as? [String: Record], let target = apps[token],
      let path = target["path"] as? String, let bundleID = target["bundleID"] as? String,
      openingApps.insert(token).inserted
    else { return }
    func finish(_ error: String? = nil) {
      openingApps.remove(token)
      guard webRecovery.lastResult?["requestID"] as? String == resultID else { return }
      var event: Record = ["kind": "reopenFinished", "resultID": resultID, "token": token]
      if let error { event["message"] = error }
      sendUpdate(event)
    }
    guard let url = QuitCaskApp.installedURL(path: path, bundleID: bundleID) else {
      finish("The updated app could not be found at its installed location.")
      return
    }
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = false
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
      DispatchQueue.main.async { finish(error?.localizedDescription) }
    }
  }
}
