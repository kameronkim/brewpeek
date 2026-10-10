import Cocoa
import WebKit

enum PackageOperationPhase {
  case idle
  case preparing
  case rechecking
  case running

  var isPreparing: Bool { self == .preparing || self == .rechecking }
  var isExecuting: Bool { self == .rechecking || self == .running }
}

enum PackageOperationPlan {
  case update(UpgradePlan)
  case uninstall(PackageRemovalPlan)
  case cleanup(CleanupPlan)
  case versions(VersionCleanupPlan)

  var record: Record {
    switch self {
    case .update(let plan): return plan.record
    case .uninstall(let plan): return plan.record
    case .cleanup(let plan): return plan.record
    case .versions(let plan): return plan.record
    }
  }
}

final class DesktopApp: NSObject, NSApplicationDelegate, WKNavigationDelegate,
  NSMenuItemValidation, WKScriptMessageHandler, NSWindowDelegate
{
  var window: NSWindow!
  var web: WKWebView!
  let refreshButton = NSButton(
    title: NSLocalizedString("Refresh", comment: ""), target: nil, action: nil)
  let loading = NSStackView()
  let loadingSpinner = NSProgressIndicator()
  let loadingTitle = NSTextField(
    labelWithString: NSLocalizedString("Loading Homebrew information…", comment: ""))
  var hasDisplayedData = false
  var inventoryRefreshState = "idle"
  var collectingInventory: Inventory?
  // Inventory refresh, recovery inspection and app removal have separate lifetimes.
  var auxiliaryBusy = false
  var operationPhase: PackageOperationPhase = .idle
  var busy: Bool { auxiliaryBusy || restoringWebState || operationPhase != .idle }
  var updateInProgress: Bool { operationPhase.isExecuting }
  var updateRequestID: String?
  var cancelledPreparationRequestID: String?
  var updatePreparing: Bool { operationPhase.isPreparing }
  var preparationControl: UpgradePreparation?
  var operationPlan: PackageOperationPlan?
  var hasOperationPlan: Bool { operationPlan != nil }
  var recoveryChecked = false
  var recoveringWebContent = false
  var webRecoveryLoading = false
  var webRecoveryEvent: Record?
  var lastOperationResult: Record?
  var restoringWebState = false
  var lastWebOperationKind = "update"
  var webRecoveryKeys: [String] = []
  var output: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BrewPeek", isDirectory: true)
      .appendingPathComponent("inventory.json")
  }
  var reportLoadID: UUID?
  var pageReady = false
  var page: URL { Bundle.main.resourceURL!.appendingPathComponent("index.html") }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    installMenu()
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "BrewPeek"
    window.delegate = self
    window.minSize = NSSize(width: 480, height: 520)
    window.appearance = NSAppearance(named: .darkAqua)
    window.isReleasedWhenClosed = false
    let root = NSView()
    window.contentView = root
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.preferences.tabFocusesLinks = true
    config.userContentController.add(self, name: "refreshInventory")
    config.userContentController.add(self, name: "packageUpdate")
    web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = self
    web.allowsBackForwardNavigationGestures = false
    web.isHidden = true
    loadingSpinner.style = .spinning
    loadingSpinner.controlSize = .regular
    loadingSpinner.startAnimation(nil)
    loadingTitle.font = .systemFont(ofSize: 15, weight: .medium)
    loadingTitle.textColor = .secondaryLabelColor
    loading.orientation = .vertical
    loading.alignment = .centerX
    loading.spacing = 18
    loading.addArrangedSubview(loadingSpinner)
    loading.addArrangedSubview(loadingTitle)
    refreshButton.target = self
    refreshButton.action = #selector(refresh)
    refreshButton.isHidden = true
    loading.addArrangedSubview(refreshButton)
    root.addSubview(web)
    root.addSubview(loading)
    loading.translatesAutoresizingMaskIntoConstraints = false
    web.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      loading.centerXAnchor.constraint(equalTo: web.centerXAnchor),
      loading.centerYAnchor.constraint(equalTo: web.centerYAnchor),
      web.topAnchor.constraint(equalTo: root.topAnchor),
      web.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
    ])
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    do {
      let legacy = output.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Homebrew Report Desktop", isDirectory: true)
      let current = output.deletingLastPathComponent()
      if !FileManager.default.fileExists(atPath: current.path),
        FileManager.default.fileExists(atPath: legacy.path)
      {
        try FileManager.default.moveItem(at: legacy, to: current)
      }
      try InventoryStore.migrateLegacy(to: output)
    } catch {
      // Keep legacy files intact if migration fails; fresh collection can still proceed.
    }
    refresh()
  }
  func installMenu() {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    menu.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    let remove = appMenu.addItem(
      withTitle: NSLocalizedString("Remove BrewPeek…", comment: ""), action: #selector(removeApp),
      keyEquivalent: "")
    remove.target = self
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: NSLocalizedString("Quit BrewPeek", comment: ""),
      action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let editItem = NSMenuItem(
      title: NSLocalizedString("Edit", comment: ""), action: nil, keyEquivalent: "")
    menu.addItem(editItem)
    let edit = NSMenu(title: NSLocalizedString("Edit", comment: ""))
    editItem.submenu = edit
    for (name, action, key) in [
      (NSLocalizedString("Undo", comment: ""), "undo:", "z"),
      (NSLocalizedString("Cut", comment: ""), "cut:", "x"),
      (NSLocalizedString("Copy", comment: ""), "copy:", "c"),
      (NSLocalizedString("Paste", comment: ""), "paste:", "v"),
      (NSLocalizedString("Select All", comment: ""), "selectAll:", "a"),
    ] { edit.addItem(withTitle: name, action: Selector(action), keyEquivalent: key) }
    let reportItem = NSMenuItem(
      title: NSLocalizedString("Report", comment: ""), action: nil, keyEquivalent: "")
    menu.addItem(reportItem)
    let reportMenu = NSMenu(title: NSLocalizedString("Report", comment: ""))
    reportItem.submenu = reportMenu
    let refresh = reportMenu.addItem(
      withTitle: NSLocalizedString("Refresh Inventory", comment: ""),
      action: #selector(self.refresh), keyEquivalent: "r")
    refresh.target = self
    let search = reportMenu.addItem(
      withTitle: NSLocalizedString("Search Packages", comment: ""), action: #selector(focusSearch),
      keyEquivalent: "f")
    search.target = self
    NSApp.mainMenu = menu
  }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame,
      message.frameInfo.request.url?.standardizedFileURL == page.standardizedFileURL
    else { return }
    if message.name == "packageUpdate" {
      handleUpdate(message.body)
    } else if message.name == "refreshInventory" {
      refresh()
    }
  }
  @objc func refresh() {
    guard !busy, !hasOperationPlan, updateRequestID == nil
    else { return }
    reportLoadID = nil
    recoveryChecked = false
    auxiliaryBusy = true
    inventoryRefreshState = "refreshing"
    refreshButton.isEnabled = false
    refreshButton.isHidden = true
    web.isHidden = !hasDisplayedData
    loading.isHidden = hasDisplayedData
    loadingTitle.stringValue = NSLocalizedString("Loading Homebrew information…", comment: "")
    loadingSpinner.startAnimation(nil)
    sendRefreshState()
    if !pageReady {
      web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }
    let destination = output
    let inventory: Inventory
    do {
      inventory = Inventory(brew: try Inventory.locateBrew())
      collectingInventory = inventory
    } catch {
      finishRefresh(error: error)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try inventory.generate(output: destination)
        try InventoryStore.migrateLegacy(to: destination)
        DispatchQueue.main.async {
          self.finishRefresh()
        }
      } catch {
        DispatchQueue.main.async {
          self.finishRefresh(error: error)
        }
      }
    }
  }
  func finishRefresh(error: Error? = nil) {
    collectingInventory = nil
    auxiliaryBusy = false
    inventoryRefreshState = error == nil ? "idle" : "failed"
    refreshButton.isEnabled = true
    if recoveringWebContent {
      reloadTerminatedWebContentIfReady()
      if let error { showError(error.localizedDescription) }
      return
    }
    if let error {
      showLoadingFailure(useSavedData: true)
      sendRefreshState()
      showError(error.localizedDescription)
    } else {
      loadReport()
    }
  }
  func sendRefreshState() {
    guard pageReady else { return }
    web.callAsyncJavaScript(
      "window.setRefreshState(state)",
      arguments: ["state": inventoryRefreshState], in: nil, in: .page
    ) { _ in }
  }
  @objc func focusSearch() {
    guard hasDisplayedData else { return }
    web.evaluateJavaScript("window.focusPackageSearch()", completionHandler: nil)
  }
  func loadReport() {
    guard pageReady else { return }
    let requestID = UUID()
    reportLoadID = requestID
    let destination = output
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result<Record?, Error> {
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
        return InventoryStore.displaySnapshot(try InventoryStore.load(destination))
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.reportLoadID == requestID, self.pageReady else { return }
        switch result {
        case .success(let snapshot):
          guard let snapshot else {
            if self.inventoryRefreshState != "refreshing" { self.showLoadingFailure() }
            return
          }
          self.web.isHidden = false
          self.web.callAsyncJavaScript(
            """
            window.setInventory(snapshot);
            window.setRefreshState(refreshState);
            return true;
            """,
            arguments: ["snapshot": snapshot, "refreshState": self.inventoryRefreshState], in: nil,
            in: .page
          ) { [weak self] result in
            guard let self, self.reportLoadID == requestID, self.pageReady else { return }
            if case .failure(let error) = result {
              self.showLoadingFailure()
              self.showError(error.localizedDescription)
            } else {
              self.hasDisplayedData = true
              self.loadingSpinner.stopAnimation(nil)
              self.loading.isHidden = true
              self.web.isHidden = false
              self.restoreWebOperationState()
              self.restorePendingRemoval()
            }
          }
        case .failure(let error):
          // A corrupt saved snapshot must not interrupt the fresh collection.
          if self.inventoryRefreshState == "refreshing" { return }
          self.showLoadingFailure()
          self.showError(error.localizedDescription)
        }
      }
    }
  }
  func showLoadingFailure(useSavedData: Bool = false) {
    if recoveringWebContent {
      // The native worker still owns its request until it finishes.
      guard !auxiliaryBusy, operationPhase == .idle else { return }
      reportLoadID = nil
      restoringWebState = false
      recoveringWebContent = false
      webRecoveryLoading = false
      webRecoveryEvent = nil
      operationPlan = nil
      updateRequestID = nil
      pageReady = false
      hasDisplayedData = false
      web.isHidden = true
      loading.isHidden = false
    }
    loadingSpinner.stopAnimation(nil)
    if hasDisplayedData {
      loading.isHidden = true
      web.isHidden = false
      return
    }
    if useSavedData, pageReady, FileManager.default.fileExists(atPath: output.path) {
      loadReport()
      return
    }
    loadingTitle.stringValue = NSLocalizedString(
      "Could not load the inventory. Please refresh to try again.", comment: "")
    refreshButton.isHidden = false
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    pageReady = true
    loadReport()
    sendRefreshState()
  }
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(focusSearch) { return hasDisplayedData }
    if menuItem.action == #selector(removeApp) || menuItem.action == #selector(refresh) {
      return !busy && !hasOperationPlan
        && updateRequestID == nil
    }
    return true
  }
  @objc func removeApp() {
    guard !busy, !hasOperationPlan, updateRequestID == nil
    else { return }
    auxiliaryBusy = true
    refreshButton.isEnabled = false
    let app = Bundle.main.bundleURL
    let reports = output.deletingLastPathComponent()
    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Remove BrewPeek?", comment: "")
    alert.informativeText = NSLocalizedString(
      "Move the app and its data to the Trash.\n\nYour Homebrew packages will be kept.", comment: ""
    )
    alert.alertStyle = .warning
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
    alert.addButton(withTitle: NSLocalizedString("Move to Trash", comment: ""))
    alert.beginSheetModal(for: window) { response in
      guard response == .alertSecondButtonReturn else {
        self.auxiliaryBusy = false
        self.refreshButton.isEnabled = true
        return
      }
      do {
        try DesktopRemoval.remove(app: app, reports: reports)
        self.auxiliaryBusy = false
        NSApp.terminate(nil)
      } catch {
        self.auxiliaryBusy = false
        self.refreshButton.isEnabled = true
        self.showError(error.localizedDescription)
      }
    }
  }
  func showError(_ message: String) {
    let alert = NSAlert()
    alert.messageText = NSLocalizedString(
      "Could not complete the inventory operation.", comment: "")
    alert.informativeText = message
    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
    alert.beginSheetModal(for: window)
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    if url.isFileURL && url.standardizedFileURL.path == page.standardizedFileURL.path {
      decisionHandler(.allow)
      return
    }
    if url.absoluteString == "about:blank" {
      decisionHandler(.allow)
      return
    }
    if navigationAction.navigationType == .linkActivated
      && ["https", "http"].contains(url.scheme ?? "")
    {
      NSWorkspace.shared.open(url)
    }
    decisionHandler(.cancel)
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    reportLoadID = nil
    pageReady = false
    hasDisplayedData = false
    showLoadingFailure()
    showError(error.localizedDescription)
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    if (error as NSError).code != NSURLErrorCancelled {
      reportLoadID = nil
      pageReady = false
      hasDisplayedData = false
      showLoadingFailure()
      showError(error.localizedDescription)
    }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func windowWillClose(_ notification: Notification) {
    pageReady = false
    reportLoadID = nil
  }
  func applicationWillTerminate(_ notification: Notification) {
    reportLoadID = nil
    collectingInventory?.cancel()
    preparationControl?.cancelAndWait()
  }
}
@main
struct DesktopMain {
  static func main() {
    let app = NSApplication.shared
    let delegate = DesktopApp()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
  }
}
