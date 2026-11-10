import Cocoa
import WebKit
import XCTest

/// Hidden real WebKit page. Operation messages are captured, never sent to an app or Homebrew.
final class WebTestPage {
  final class Messages: NSObject, WKScriptMessageHandler {
    var values: [[String: Any]] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard let record = message.body as? [String: Any] else { XCTFail("Unexpected bridge message"); return }
      values.append(record)
    }
  }
  let messages = Messages()
  let web: WKWebView
  private let window: NSWindow

  init(width: CGFloat = 1100, height: CGFloat = 800) throws {
    _ = NSApplication.shared
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(messages, name: "packageUpdate")
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
    window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = web
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let base = root.appendingPathComponent("BrewPeek/Web")
    web.loadFileURL(base.appendingPathComponent("index.html"), allowingReadAccessTo: base)
    try wait { !self.web.isLoading }
    try run("if(typeof setInventory!=='function')throw Error('Inventory page did not load'); window.assert=(ok,message)=>{if(!ok)throw Error(message)}; return true;")
  }
  deinit {
    web.configuration.userContentController.removeScriptMessageHandler(forName: "packageUpdate")
    window.close()
  }
  func resize(width: CGFloat, height: CGFloat = 800) {
    web.frame.size = NSSize(width: width, height: height)
    window.setContentSize(web.frame.size)
  }
  func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 15
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    guard condition() else {
      XCTFail("WebKit callback timed out", file: file, line: line)
      throw NSError(domain: "WebTestPage", code: 1)
    }
  }
  @discardableResult func run(_ script: String, arguments: [String: Any] = [:]) throws -> Any {
    var result: Result<Any, Error>?
    web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result = $0 }
    try wait { result != nil }
    return try XCTUnwrap(result).get()
  }
  @discardableResult func fixture(_ name: String) throws -> Any {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "Fixtures"))
    return try run(String(contentsOf: url, encoding: .utf8))
  }
}
