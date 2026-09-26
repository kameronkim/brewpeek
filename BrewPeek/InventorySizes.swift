import CryptoKit
import Darwin
import Foundation

struct InventorySizeRequest {
  let path: String
  let metadata: Record
  var force = false
}

/// A disposable cache: installed-package data remains authoritative.
enum InventorySizes {
  private static let lifetime: TimeInterval = 7 * 24 * 60 * 60
  struct Result {
    var values: [String: Int]
    var cache: Record
  }
  enum ScanError: Error { case directoryHardLinks }

  private static func fileState(_ path: String) -> [Int64]? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return [
      Int64(info.st_dev), Int64(bitPattern: info.st_ino), Int64(info.st_mode),
      info.st_size, Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
      Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec),
    ]
  }
  private static func digest(_ object: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static func signature(_ request: InventorySizeRequest) -> String? {
    guard let state = fileState(request.path) else { return nil }
    var files: Record = [".": state]
    if state[2] & Int64(S_IFMT) == Int64(S_IFDIR) {
      guard let children = try? FileManager.default.contentsOfDirectory(atPath: request.path)
      else { return nil }
      for name in children {
        guard let child = fileState(request.path + "/" + name) else { return nil }
        files[name] = child
      }
    }
    return digest(["metadata": request.metadata, "files": files])
  }
  private static func contains(_ parent: String, _ child: String) -> Bool {
    child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
  }
  static func collect(
    _ requests: [InventorySizeRequest], previous: Record?, now: Date = Date(),
    measure: ([String]) throws -> [String: Int]
  ) throws -> Result {
    let time = now.timeIntervalSince1970
    let old = previous?["version"] as? Int == 1 ? previous?["entries"] as? Record ?? [:] : [:]
    var inputs: [String: InventorySizeRequest] = [:]
    for request in requests {
      var value = request
      value.force = value.force || inputs[value.path]?.force == true
      inputs[value.path] = value
    }
    let own = inputs.compactMapValues(signature)
    var signatures: [String: String] = [:]
    var pending: [String] = []
    var entries: Record = [:]
    var values: [String: Int] = [:]
    for path in inputs.keys.sorted() {
      let members = inputs.keys.filter { contains(path, $0) }
      if let stamp = own[path], members.allSatisfy({ own[$0] != nil }) {
        signatures[path] = digest([
          "self": stamp,
          "members": Dictionary(
            uniqueKeysWithValues:
              members.map { ($0, own[$0]!) }),
        ])
      }
      let forced = inputs[path]!.force || members.contains { inputs[$0]!.force }
      if !forced, let signature = signatures[path], let cached = old[path] as? Record,
        cached["signature"] as? String == signature,
        let number = cached["bytes"] as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(), let bytes = cached["bytes"] as? Int,
        bytes >= 0,
        let measured = cached["measuredAt"] as? Double, measured.isFinite,
        time >= measured, time - measured < lifetime
      {
        values[path] = bytes
        entries[path] = cached
      } else {
        pending.append(path)
      }
    }
    if !pending.isEmpty {
      let measured = try measure(pending)
      for path in pending {
        guard let bytes = measured[path], bytes >= 0 else { continue }
        values[path] = bytes
        if let signature = signatures[path] {
          entries[path] = ["signature": signature, "bytes": bytes, "measuredAt": time]
        }
      }
    }
    return Result(values: values, cache: ["version": 1, "entries": entries])
  }

  private struct FileID: Hashable {
    let device: dev_t
    let inode: ino_t
  }
  private final class Total {
    let path: String
    var blocks: Int64 = 0
    var valid = true
    var links = Set<FileID>()
    init(_ path: String) { self.path = path }
  }
  /// Read each overlapping tree once, keeping an independent hard-link count for each target.
  static func measure(_ paths: [String], checkCancellation: () throws -> Void) throws -> [String:
    Int]
  {
    let targets = Set(paths)
    let directories = targets.filter { path in
      var info = stat()
      return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
    // Unreached targets (for example, below a symlink) get their own physical walk.
    let roots =
      targets.filter { path in !directories.contains { contains($0, path) } }.sorted()
      + targets.sorted()
    var result: [String: Int] = [:]
    var visitedTargets = Set<String>()
    for root in roots {
      if visitedTargets.contains(root) { continue }
      try checkCancellation()
      visitedTargets.insert(root)
      guard let name = strdup(root) else { continue }
      defer { free(name) }
      var names: [UnsafeMutablePointer<CChar>?] = [name, nil]
      guard let walk = fts_open(&names, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { continue }
      defer { fts_close(walk) }
      var active: [Total] = []
      var seenDirectories = Set<FileID>()
      var visited = 0
      while true {
        errno = 0
        guard let node = fts_read(walk) else {
          if errno != 0 { for total in active { total.valid = false } }
          break
        }
        visited += 1
        if visited % 256 == 0 { try checkCancellation() }
        let item = node.pointee
        let path = String(cString: item.fts_path)
        let kind = Int32(item.fts_info)
        if targets.contains(path) && kind != FTS_DP {
          visitedTargets.insert(path)
          if active.last?.path != path { active.append(Total(path)) }
        }
        if kind == FTS_D {
          let info = item.fts_statp.pointee
          if !seenDirectories.insert(FileID(device: info.st_dev, inode: info.st_ino)).inserted {
            throw ScanError.directoryHardLinks
          }
          continue
        }
        if [FTS_DNR, FTS_ERR, FTS_NS, FTS_DC].contains(kind) || item.fts_statp == nil {
          for total in active { total.valid = false }
        } else {
          let info = item.fts_statp.pointee
          for total in active {
            if kind != FTS_DP && info.st_nlink > 1,
              !total.links.insert(FileID(device: info.st_dev, inode: info.st_ino)).inserted
            {
              continue
            }
            total.blocks += info.st_blocks
          }
        }
        if let total = active.last, total.path == path {
          if total.valid { result[path] = Int((total.blocks + 1) / 2) * 1024 }
          active.removeLast()
        }
      }
    }
    try checkCancellation()
    return result
  }
}
