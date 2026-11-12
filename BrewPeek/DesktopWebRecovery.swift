import Cocoa
import WebKit

extension DesktopApp {
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    reportLoadID = nil
    webRecovery.beginRecovery()
    pageReady = false
    hasDisplayedData = false
    web.isHidden = true
    loading.isHidden = false
    refreshButton.isHidden = true
    loadingTitle.stringValue = NSLocalizedString(
      busy ? "Waiting for Homebrew to finish…" : "Restoring BrewPeek…", comment: "")
    loadingSpinner.startAnimation(nil)
    reloadTerminatedWebContentIfReady()
  }

  /// Wait for the owned native worker. A screen failure must never restart or cancel a mutation.
  func reloadTerminatedWebContentIfReady() {
    guard webRecovery.isRecovering, !webRecovery.isLoading, !busy else { return }
    webRecovery.isLoading = true
    loadingTitle.stringValue = NSLocalizedString("Restoring BrewPeek…", comment: "")
    web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
  }

  func restoreWebOperationState() {
    guard webRecovery.isRecovering else { return }
    let events = webRecovery.replayEvents(plan: operation.plan, requestID: operation.requestID)
    // No worker can be admitted while restoration is delivering its state.
    webRecovery.isRestoring = true
    let loadID = reportLoadID
    web.callAsyncJavaScript(
      "window.restoreUpdateState(events)", arguments: ["events": events], in: nil, in: .page
    ) { [weak self] result in
      guard let self, self.reportLoadID == loadID else { return }
      self.webRecovery.isRestoring = false
      if case .failure(let error) = result {
        self.showLoadingFailure()
        self.showError(error.localizedDescription)
      } else {
        self.webRecovery.finishRecovery()
        self.restorePendingRemoval()
        self.restoreSecurityReport()
      }
    }
  }

}
