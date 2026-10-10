import Cocoa
import WebKit

extension DesktopApp {
  /// Keep only the latest display result, without retaining a second inventory snapshot.
  func rememberWebOperationEvent(_ event: Record) {
    let kind = event["kind"] as? String
    if let operation = event["operation"] as? String { lastWebOperationKind = operation }
    if let plan = event["plan"] as? Record {
      lastWebOperationKind = plan["operation"] as? String ?? "update"
    }
    if kind == "started" { lastOperationResult = nil }
    if kind == "result" {
      var result = event
      result.removeValue(forKey: "snapshot")
      lastOperationResult = result
    } else if kind == "cleanupDiscarded", var result = lastOperationResult {
      for key in ["recoveryID", "pendingCleanup", "recovered"] { result.removeValue(forKey: key) }
      lastOperationResult = result
    }
    if kind == "checking" || kind == "cancelled" || kind == "cleanupDiscarded" {
      webRecoveryEvent = nil
    }
    if kind == "error" || (recoveringWebContent && kind == "plan") {
      var pending = event
      pending["operation"] = lastWebOperationKind
      pending["retryKeys"] = webRecoveryKeys
      webRecoveryEvent = pending
    }
    if kind == "result" || kind == "started" { webRecoveryEvent = nil }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    reportLoadID = nil
    restoringWebState = false
    pageReady = false
    hasDisplayedData = false
    recoveringWebContent = true
    webRecoveryLoading = false
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
    guard recoveringWebContent, !webRecoveryLoading, !busy else { return }
    webRecoveryLoading = true
    loadingTitle.stringValue = NSLocalizedString("Restoring BrewPeek…", comment: "")
    web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
  }

  func restoreWebOperationState() {
    guard recoveringWebContent else { return }
    var events: [Record] = []
    if let result = lastOperationResult { events.append(result) }
    if let pending = webRecoveryEvent {
      // Errors from preparation need a checking state so the retry dialog is restored.
      if pending["kind"] as? String == "error" {
        events.append(["kind": "checking", "operation": lastWebOperationKind])
      }
      events.append(pending)
    } else if let plan = operationPlan {
      events.append(["kind": "plan", "plan": plan.record, "requestID": updateRequestID ?? ""])
    }
    // No worker can be admitted while restoration is delivering its state.
    restoringWebState = true
    let loadID = reportLoadID
    web.callAsyncJavaScript(
      "window.restoreUpdateState(events)", arguments: ["events": events], in: nil, in: .page
    ) { [weak self] result in
      guard let self, self.reportLoadID == loadID else { return }
      self.restoringWebState = false
      if case .failure(let error) = result {
        self.showLoadingFailure()
        self.showError(error.localizedDescription)
      } else {
        self.recoveringWebContent = false
        self.webRecoveryLoading = false
        self.webRecoveryEvent = nil
        self.restorePendingRemoval()
      }
    }
  }

}
