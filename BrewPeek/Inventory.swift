import Darwin
import Foundation

typealias Record = [String: Any]
struct InventoryError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
final class Inventory {
  let brew: String
  let null = NSNull()
  private let processLock = NSLock()
  private var cancelled = false
  private var currentProcess: Process?
  init(brew: String) { self.brew = brew }
  func cancel() {
    processLock.lock()
    cancelled = true
    let task = currentProcess
    if let task, task.isRunning { task.terminate() }
    processLock.unlock()
    // App termination must not leave the current read-only command running.
    if let task, task.isRunning {
      let deadline = ProcessInfo.processInfo.systemUptime + 0.2
      while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.01)
      }
      if task.isRunning { kill(task.processIdentifier, SIGKILL) }
    }
  }
  private func checkCancellation() throws {
    processLock.lock()
    defer { processLock.unlock() }
    if cancelled { throw InventoryError(message: "정보 수집을 취소했습니다.") }
  }
  static func locateBrew() throws -> String {
    let candidates =
      ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
      + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
        String($0) + "/brew"
      }
    guard let result = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else {
      throw InventoryError(message: "Homebrew 실행 파일을 찾지 못했습니다.")
    }
    return result
  }
  func run(_ executable: String, _ arguments: [String], timeout: Double = 180) throws -> String {
    try checkCancellation()
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("brew-report-" + UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let out = dir.appendingPathComponent("stdout")
    let err = dir.appendingPathComponent("stderr")
    fm.createFile(atPath: out.path, contents: nil)
    fm.createFile(atPath: err.path, contents: nil)
    let stdout = try FileHandle(forWritingTo: out)
    let stderr = try FileHandle(forWritingTo: err)
    defer {
      try? stdout.close()
      try? stderr.close()
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
    env["HOMEBREW_NO_API_AUTO_UPDATE"] = "1"
    env["HOMEBREW_NO_ANALYTICS"] = "1"
    env["HOMEBREW_NO_UPDATE_CLEANUP"] = "1"
    env["PATH"] =
      URL(fileURLWithPath: brew).deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
    task.environment = env
    task.standardOutput = stdout
    task.standardError = stderr
    task.standardInput = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in finished.signal() }
    processLock.lock()
    if cancelled {
      processLock.unlock()
      throw InventoryError(message: "정보 수집을 취소했습니다.")
    }
    do {
      try task.run()
      currentProcess = task
    } catch {
      processLock.unlock()
      throw error
    }
    processLock.unlock()
    defer {
      processLock.lock()
      currentProcess = nil
      processLock.unlock()
    }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
      task.terminate()
      if finished.wait(timeout: .now() + 2) == .timedOut {
        kill(task.processIdentifier, SIGKILL)
        finished.wait()
      }
      throw InventoryError(
        message: "명령 실행 시간이 초과되었습니다: " + executable + " " + arguments.joined(separator: " "))
    }
    try checkCancellation()
    guard task.terminationStatus == 0 else {
      let detail = (try? String(contentsOf: err, encoding: .utf8)) ?? ""
      throw InventoryError(
        message: executable + " " + arguments.joined(separator: " ") + "\n" + detail)
    }
    return try String(contentsOf: out, encoding: .utf8).trimmingCharacters(
      in: .whitespacesAndNewlines)
  }
  func lines(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline).map(String.init)
  }
  func size(_ path: String) -> Int? {
    guard FileManager.default.fileExists(atPath: path),
      let result = try? run("/usr/bin/du", ["-sk", path]),
      let first = result.split(whereSeparator: \.isWhitespace).first, let kib = Int(first)
    else { return nil }
    return kib * 1024
  }
  func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? null }
  func category(_ name: String, _ description: String) -> String {
    let groups = [
      "CLI": "bat eza fd fzf", "Development": "cask emacs uv", "Build": "m4 libtool",
      "Version Control": "git gh git-lfs git-filter-repo", "Runtime": "node deno",
      "Media": "ffmpeg imagemagick exiftool yt-dlp", "Network": "openfortivpn unbound",
      "Database": "sqlite", "Utility": "fish coreutils gnupg sevenzip unar pinentry",
    ]
    for (category, names) in groups where names.split(separator: " ").contains(Substring(name)) {
      return category
    }
    if name.hasPrefix("python@") { return "Runtime" }
    if description.lowercased().contains("library")
      || description.lowercased().contains("libraries")
    {
      return "Library"
    }
    return "Other"
  }
  func dependencies(_ formula: Record) -> [String] {
    let receipts = formula["installed"] as? [Record] ?? []
    return Array(
      Set(
        receipts.flatMap {
          ($0["runtime_dependencies"] as? [Record] ?? []).compactMap { $0["full_name"] as? String }
        })
    ).sorted()
  }
  /// Use Homebrew's outdated result, including its default cask and revision rules.
  func checkUpdates(refreshMetadata: Bool = true) -> (
    formulae: [String: String], casks: [String: String], state: Record
  ) {
    do {
      if refreshMetadata { _ = try run(brew, ["update", "--quiet"], timeout: 90) }
      let text = try run(brew, ["outdated", "--json=v2"], timeout: 90)
      guard let result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? Record else {
        throw InventoryError(message: "Homebrew 업데이트 정보를 읽지 못했습니다.")
      }
      func versions(_ value: Any?) throws -> [String: String] {
        guard let records = value as? [Record] else {
          throw InventoryError(message: "Homebrew 업데이트 목록의 형식이 올바르지 않습니다.")
        }
        var versions: [String: String] = [:]
        for record in records {
          guard let name = record["name"] as? String, !name.isEmpty,
            let version = record["current_version"] as? String, !version.isEmpty
          else { throw InventoryError(message: "Homebrew 업데이트 버전 정보가 누락되었습니다.") }
          versions[name] = version
        }
        return versions
      }
      return (
        try versions(result["formulae"]), try versions(result["casks"]),
        ["status": "succeeded"]
      )
    } catch {
      return ([:], [:], ["status": "failed", "error": error.localizedDescription])
    }
  }
  func collect(refreshMetadata: Bool = true) throws -> Record {
    let updates = checkUpdates(refreshMetadata: refreshMetadata)
    let text = try run(brew, ["info", "--json=v2", "--installed"])
    guard let raw = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? Record,
      let formulae = raw["formulae"] as? [Record], let casks = raw["casks"] as? [Record]
    else { throw InventoryError(message: "Homebrew 데이터 형식을 확인할 수 없습니다.") }
    let leaves = Set(lines(try run(brew, ["leaves"])))
    let taps = lines(try run(brew, ["tap"]))
    let prefix = try run(brew, ["--prefix"])
    let cellar = try run(brew, ["--cellar"])
    let caskroom = try run(brew, ["--caskroom"])
    var reverse: [String: Set<String>] = [:]
    for formula in formulae {
      guard let name = formula["name"] as? String else {
        throw InventoryError(message: "Formula 이름 누락")
      }
      for dep in dependencies(formula) {
        reverse[String(dep.split(separator: "/").last ?? Substring(dep)), default: []].insert(name)
      }
    }
    var formulas: [Record] = []
    for formula in formulae {
      guard let name = formula["name"] as? String, let receipts = formula["installed"] as? [Record]
      else { throw InventoryError(message: "Formula 설치 기록 누락") }
      let versions = receipts.compactMap { $0["version"] as? String }
      guard versions.count == receipts.count else {
        throw InventoryError(message: "설치 버전 누락: " + name)
      }
      formulas.append([
        "id": "formula:" + (formula["full_name"] as? String ?? name),
        "name": name, "displayName": name, "version": versions.joined(separator: ", "),
        "availableVersion": nullable(updates.formulae[formula["full_name"] as? String ?? name]),
        "type": "formula", "description": formula["desc"] ?? null, "tap": formula["tap"] ?? null,
        "category": category(name, formula["desc"] as? String ?? ""), "leaf": leaves.contains(name),
        "direct": receipts.contains { $0["installed_on_request"] as? Bool == true },
        "homepage": formula["homepage"] ?? null, "dependencies": dependencies(formula),
        "usedBy": Array(reverse[name] ?? []).sorted(),
        "paths": versions.map { cellar + "/" + name + "/" + $0 },
        "size": nullable(size(cellar + "/" + name)), "apps": [Record](),
      ])
    }
    var applications: [Record] = []
    for cask in casks {
      guard let name = cask["token"] as? String else {
        throw InventoryError(message: "Cask token 누락")
      }
      var apps: [Record] = []
      var expected = false
      for artifact in cask["artifacts"] as? [Record] ?? [] {
        guard let appNames = artifact["app"] as? [Any], let appName = appNames.first as? String
        else { continue }
        expected = true
        let path = artifact["target"] as? String ?? "/Applications/" + appName
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path + "/Contents/Info.plist")),
          let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil))
            as? Record
        {
          apps.append([
            "path": path,
            "version": plist["CFBundleShortVersionString"] ?? plist["CFBundleVersion"] ?? null,
            "kib": nullable(size(path).map { $0 / 1024 }),
          ])
        }
      }
      let version: Any =
        (cask["installed"] as? [String]).map { $0.joined(separator: ", ") } ?? cask["installed"]
        ?? null
      let names = cask["name"] as? [String] ?? [name]
      applications.append([
        "id": "cask:" + (cask["full_token"] as? String ?? name),
        "name": name, "displayName": names.joined(separator: " / "), "version": version,
        "availableVersion": nullable(updates.casks[name]),
        "type": "cask", "description": cask["desc"] ?? null, "tap": cask["tap"] ?? null,
        "category": "Other", "leaf": false, "direct": null, "homepage": cask["homepage"] ?? null,
        "dependencies": (cask["depends_on"] as? Record)?["formula"] ?? [String](), "usedBy": null,
        "paths": [caskroom + "/" + name], "size": nullable(size(caskroom + "/" + name)),
        "apps": apps, "appExpected": expected,
      ])
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy.MM.dd HH:mm z"
    let environment: Record = [
      "updated": formatter.string(from: Date()), "prefix": prefix,
      "brewVersion": try run(brew, ["--version"]),
      "architecture": try run("/usr/bin/uname", ["-m"]),
      "macOS": try run("/usr/bin/sw_vers", ["-productVersion"]),
      "build": try run("/usr/bin/sw_vers", ["-buildVersion"]), "cellarSize": nullable(size(cellar)),
      "caskSize": nullable(size(caskroom)),
    ]
    return [
      "formulae": formulas, "casks": applications, "taps": taps, "environment": environment,
      "updateCheck": updates.state,
    ]
  }
  func generate(output: URL) throws {
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lockPath = output.deletingLastPathComponent().appendingPathComponent(
      ".homebrew-report.lock"
    ).path
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw InventoryError(message: "저장 폴더에 쓸 수 없습니다.") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      throw InventoryError(message: "다른 보고서 생성이 진행 중입니다. 잠시 후 다시 실행해 주세요.")
    }
    defer { flock(fd, LOCK_UN) }
    let snapshot = try collect()
    try checkCancellation()
    try InventoryStore.save(snapshot, to: output)
  }
}
