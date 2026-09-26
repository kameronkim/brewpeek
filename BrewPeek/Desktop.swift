import Cocoa
import WebKit

final class DesktopApp: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate,
  NSMenuItemValidation, WKScriptMessageHandler, NSWindowDelegate
{
  var window: NSWindow!
  var web: WKWebView!
  let refreshButton = NSButton(title: "새로고침", target: nil, action: nil)
  let loading = NSStackView()
  let loadingSpinner = NSProgressIndicator()
  let loadingTitle = NSTextField(labelWithString: "Homebrew 정보를 불러오는 중입니다…")
  var hasDisplayedData = false
  var inventoryRefreshState = "idle"
  var collectingInventory: Inventory?
  var busy = false
  var updateInProgress = false
  var updateRequestID: String?
  var updatePreparing = false
  var preparationControl: UpgradePreparation?
  var updatePlan: UpgradePlan?
  var output: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BrewPeek", isDirectory: true)
      .appendingPathComponent("inventory.json")
  }
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
    web.uiDelegate = self
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
      withTitle: "BrewPeek 제거…", action: #selector(removeApp), keyEquivalent: "")
    remove.target = self
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "BrewPeek 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let editItem = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
    menu.addItem(editItem)
    let edit = NSMenu(title: "편집")
    editItem.submenu = edit
    for (name, action, key) in [
      ("실행 취소", "undo:", "z"), ("오려두기", "cut:", "x"), ("복사", "copy:", "c"), ("붙여넣기", "paste:", "v"),
      ("전체 선택", "selectAll:", "a"),
    ] { edit.addItem(withTitle: name, action: Selector(action), keyEquivalent: key) }
    let reportItem = NSMenuItem(title: "보고서", action: nil, keyEquivalent: "")
    menu.addItem(reportItem)
    let reportMenu = NSMenu(title: "보고서")
    reportItem.submenu = reportMenu
    let refresh = reportMenu.addItem(
      withTitle: "정보 새로고침", action: #selector(self.refresh), keyEquivalent: "r")
    refresh.target = self
    let search = reportMenu.addItem(
      withTitle: "패키지 검색", action: #selector(focusSearch), keyEquivalent: "f")
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
    guard !busy, updatePlan == nil, updateRequestID == nil else { return }
    busy = true
    inventoryRefreshState = "refreshing"
    refreshButton.isEnabled = false
    refreshButton.isHidden = true
    web.isHidden = !hasDisplayedData
    loading.isHidden = hasDisplayedData
    loadingTitle.stringValue = "Homebrew 정보를 불러오는 중입니다…"
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
    busy = false
    inventoryRefreshState = error == nil ? "idle" : "failed"
    refreshButton.isEnabled = true
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
    guard pageReady, FileManager.default.fileExists(atPath: output.path) else { return }
    do {
      let snapshot = try InventoryStore.load(output)
      web.isHidden = false
      web.callAsyncJavaScript(
        """
        window.setInventory(snapshot);
        window.setRefreshState(refreshState);
        return true;
        """,
        arguments: ["snapshot": snapshot, "refreshState": inventoryRefreshState], in: nil,
        in: .page
      ) { result in
        if case .failure(let error) = result {
          self.showLoadingFailure()
          self.showError(error.localizedDescription)
        } else {
          self.hasDisplayedData = true
          self.loadingSpinner.stopAnimation(nil)
          self.loading.isHidden = true
          self.web.isHidden = false
        }
      }
    } catch {
      // A corrupt saved snapshot must not interrupt the fresh collection.
      if inventoryRefreshState == "refreshing" { return }
      showLoadingFailure()
      showError(error.localizedDescription)
    }
  }
  func showLoadingFailure(useSavedData: Bool = false) {
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
    loadingTitle.stringValue = "정보를 불러오지 못했습니다. 새로고침해 주세요."
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
      return !busy && updatePlan == nil && updateRequestID == nil
    }
    return true
  }
  @objc func removeApp() {
    guard !busy, updatePlan == nil, updateRequestID == nil else { return }
    busy = true
    refreshButton.isEnabled = false
    let app = Bundle.main.bundleURL
    let reports = output.deletingLastPathComponent()
    let alert = NSAlert()
    alert.messageText = "앱을 제거할까요?"
    alert.informativeText = "앱과 데이터를 휴지통으로 이동합니다.\n\nHomebrew 패키지는 유지됩니다."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "취소")
    alert.addButton(withTitle: "휴지통으로 이동")
    alert.beginSheetModal(for: window) { response in
      guard response == .alertSecondButtonReturn else {
        self.busy = false
        self.refreshButton.isEnabled = true
        return
      }
      do {
        try DesktopRemoval.remove(app: app, reports: reports)
        self.busy = false
        NSApp.terminate(nil)
      } catch {
        self.busy = false
        self.refreshButton.isEnabled = true
        self.showError(error.localizedDescription)
      }
    }
  }
  func showError(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "보고서 작업을 완료하지 못했습니다."
    alert.informativeText = message
    alert.addButton(withTitle: "확인")
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
      pageReady = false
      hasDisplayedData = false
      showLoadingFailure()
      showError(error.localizedDescription)
    }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationWillTerminate(_ notification: Notification) {
    collectingInventory?.cancel()
    preparationControl?.cancel()
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
