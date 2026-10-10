import Darwin
import Foundation

/// Resolve Homebrew app artifacts once for display, size measurement and operation guards.
enum CaskApps {
  private static func target(_ artifact: Record) -> String? {
    guard let arguments = artifact["app"] as? [Any], let source = arguments.first as? String,
      !source.isEmpty
    else { return nil }
    if let resolved = artifact["target"] as? String, !resolved.isEmpty { return resolved }
    if let renamed = arguments.dropFirst().compactMap({ ($0 as? Record)?["target"] as? String })
      .first, !renamed.isEmpty
    {
      return renamed
    }
    return (source as NSString).lastPathComponent
  }
  static func needsAppDirectory(_ cask: Record) -> Bool {
    (cask["artifacts"] as? [Record] ?? []).compactMap(target).contains {
      !$0.hasPrefix("/") && !$0.hasPrefix("~")
    }
  }
  private static func appDirectory(_ cask: Record, caskroom: String?) -> String {
    guard let caskroom, let token = cask["token"] as? String,
      token.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9@+_.-]*$"#, options: .regularExpression) != nil,
      let data = try? Data(
        contentsOf: URL(fileURLWithPath: caskroom)
          .appendingPathComponent(token).appendingPathComponent(".metadata/config.json")),
      let config = (try? JSONSerialization.jsonObject(with: data)) as? Record
    else { return "/Applications" }
    for layer in ["explicit", "env", "default"] {
      if let directory = (config[layer] as? Record)?["appdir"] as? String, !directory.isEmpty {
        let expanded = (directory as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
      }
    }
    return "/Applications"
  }
  static func paths(_ cask: Record, caskroom: String? = nil) -> [String] {
    let targets = (cask["artifacts"] as? [Record] ?? []).compactMap(target)
    var directory: String?
    var seen = Set<String>()
    return targets.compactMap { target in
      let expanded = (target as NSString).expandingTildeInPath
      let url: URL
      if expanded.hasPrefix("/") {
        url = URL(fileURLWithPath: expanded)
      } else {
        if directory == nil { directory = appDirectory(cask, caskroom: caskroom) }
        url = URL(fileURLWithPath: directory!).appendingPathComponent(expanded)
      }
      let path = url.standardizedFileURL.path
      return seen.insert(path).inserted ? path : nil
    }
  }
  static func matches(_ path: String, running url: URL) -> Bool {
    guard path.hasPrefix("/"), url.isFileURL else { return false }
    let installed = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    let running = url.standardizedFileURL.resolvingSymlinksInPath()
    if installed == running { return true }
    // File identity also handles equivalent spellings on case-insensitive volumes.
    var expected = stat()
    var actual = stat()
    guard stat(installed.path, &expected) == 0, stat(running.path, &actual) == 0 else {
      return false
    }
    return expected.st_dev == actual.st_dev && expected.st_ino == actual.st_ino
  }
}
