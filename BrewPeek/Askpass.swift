import Cocoa
import Darwin

final class PasswordInput: NSObject, NSTextFieldDelegate {
  let button: NSButton
  init(button: NSButton) {
    self.button = button
    button.isEnabled = false
  }
  func controlTextDidChange(_ notification: Notification) {
    button.isEnabled = !((notification.object as? NSTextField)?.stringValue.isEmpty ?? true)
  }
}

/// stdout belongs exclusively to sudo's askpass pipe. Never print credentials or diagnostics.
@main struct BrewPeekAskpass {
  struct Request: Decodable {
    let pid: pid_t
    let started: UInt64
    let microseconds: UInt64
    let operation: String
  }
  static func processPath(_ pid: pid_t) -> String? {
    var bytes = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
    return String(cString: bytes)
  }
  struct ProcessIdentity: Equatable {
    let pid: pid_t
    let parent: pid_t
    let started: UInt64
    let microseconds: UInt64
  }
  static func processIdentity(_ pid: pid_t) -> ProcessIdentity? {
    var info = proc_bsdinfo()
    guard pid > 1,
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_pid == UInt32(pid)
    else { return nil }
    return ProcessIdentity(
      pid: pid, parent: pid_t(info.pbi_ppid), started: info.pbi_start_tvsec,
      microseconds: info.pbi_start_tvusec)
  }
  /// The sudo caller must descend from the live BrewPeek process named by this request.
  /// Recheck the chain before accepting it so exited, reused or reparented processes fail closed.
  static func belongsToRequest(
    caller: pid_t, request: Request,
    inspect: (pid_t) -> ProcessIdentity? = processIdentity
  ) -> Bool {
    guard caller > 1, request.pid > 1 else { return false }
    var pid = caller
    var visited = Set<pid_t>()
    var chain: [ProcessIdentity] = []
    for _ in 0..<64 {
      guard pid > 1, visited.insert(pid).inserted, let identity = inspect(pid),
        identity.pid == pid
      else { return false }
      chain.append(identity)
      if pid == request.pid {
        guard identity.started == request.started,
          identity.microseconds == request.microseconds
        else { return false }
        return chain.allSatisfy { inspect($0.pid) == $0 }
      }
      pid = identity.parent
    }
    return false
  }
  static func request() -> Request? {
    let invocation = URL(fileURLWithPath: CommandLine.arguments[0])
    let caller = getppid()
    guard invocation.lastPathComponent == "askpass", processPath(caller) == "/usr/bin/sudo",
      let ownPath = processPath(getpid()),
      invocation.resolvingSymlinksInPath().path == ownPath
    else { return nil }
    let directory = invocation.deletingLastPathComponent()
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
      let data = try? Data(contentsOf: directory.appendingPathComponent("request.json")),
      let request = try? JSONDecoder().decode(Request.self, from: data), request.pid > 1,
      !FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled").path),
      ["upgrade", "uninstall"].contains(request.operation.components(separatedBy: " ").first ?? ""),
      processPath(request.pid)
        == URL(fileURLWithPath: ownPath).deletingLastPathComponent()
        .appendingPathComponent("BrewPeek").path
    else { return nil }
    var info = proc_bsdinfo()
    guard
      proc_pidinfo(request.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_uid == getuid(),
      info.pbi_start_tvsec == request.started, info.pbi_start_tvusec == request.microseconds,
      belongsToRequest(caller: caller, request: request), getppid() == caller
    else { return nil }
    return request
  }
  static var appBundle: Bundle {
    let executable = URL(fileURLWithPath: processPath(getpid()) ?? CommandLine.arguments[0])
    let app = executable.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    return Bundle(url: app) ?? .main
  }
  static func localized(_ key: String) -> String {
    appBundle.localizedString(forKey: key, value: nil, table: nil)
  }
  static var requestDirectory: URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
  }
  static func markCancelled(at directory: URL) {
    let file = directory.appendingPathComponent("cancelled")
    try? Data().write(to: file, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
  static func operationLabel(_ operation: String) -> String {
    let words = operation.split(separator: " ").map(String.init)
    let names = words.dropFirst().filter { !$0.hasPrefix("-") }
      .map { String($0.split(separator: "/").last ?? Substring($0)) }
    let format = words.first == "uninstall" ? "Uninstalling: %@" : "Updating: %@"
    return String(format: localized(format), names.joined(separator: ", "))
  }
  static func configure(_ alert: NSAlert, operation: String, retrying: Bool) -> NSSecureTextField {
    alert.icon =
      appBundle.resourceURL.flatMap {
        NSImage(contentsOf: $0.appendingPathComponent("AppIcon.icns"))
      }
      ?? NSWorkspace.shared.icon(forFile: appBundle.bundleURL.path)
    alert.messageText = localized("Administrator permission required")
    alert.informativeText =
      localized(
        "Homebrew needs administrator permission to finish this package operation. Enter your macOS account password. BrewPeek does not save it."
      )
      + "\n\n" + operationLabel(operation)
      + (retrying ? "\n\n" + localized("Authentication was not accepted. Please try again.") : "")
    alert.addButton(withTitle: localized("Authenticate"))
    alert.addButton(withTitle: localized("Cancel"))
    let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
    password.placeholderString = localized("Password")
    alert.accessoryView = password
    alert.window.initialFirstResponder = password
    return password
  }
  static func main() {
    guard let original = request() else { exit(1) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let directory = requestDirectory
    let attempted = directory.appendingPathComponent("attempted")
    let sudoPID = String(getppid())
    let retrying = (try? String(contentsOf: attempted, encoding: .utf8)) == sudoPID
    try? Data(sudoPID.utf8).write(to: attempted, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: attempted.path)
    let alert = NSAlert()
    let password = configure(alert, operation: original.operation, retrying: retrying)
    let input = PasswordInput(button: alert.buttons[0])
    password.delegate = input
    let timer = Timer(timeInterval: 1, repeats: true) { _ in
      if request()?.pid != original.pid {
        password.stringValue = ""
        NSApp.abortModal()
        alert.window.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
      }
    }
    RunLoop.main.add(timer, forMode: .modalPanel)
    defer {
      timer.invalidate()
      withExtendedLifetime(input) {}
    }
    app.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn, request()?.pid == original.pid,
      !password.stringValue.isEmpty
    else {
      password.stringValue = ""
      markCancelled(at: directory)
      exit(1)
    }
    var response = Data(password.stringValue.utf8)
    password.stringValue = ""
    response.append(10)
    FileHandle.standardOutput.write(response)
    response.resetBytes(in: response.startIndex..<response.endIndex)
  }
}
