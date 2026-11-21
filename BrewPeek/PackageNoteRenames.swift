import Foundation

extension Inventory {
  /// A package's oldnames/old_tokens can include migrations from another Tap.
  /// Verify candidate pairs against the owning Tap's rename table before showing a note.
  func formerNoteIDs(in installed: InstalledPackageInfo, notesFile: URL?) -> [String: [String]] {
    guard let notesFile, let notes = try? PackageNotes(file: notesFile).read(), !notes.isEmpty else { return [:] }
    let installedIDs = Set(installed.formulae.map { "formula:" + $0.fullName } + installed.casks.map { "cask:" + $0.fullName })
    let orphanIDs = Set(notes.keys).subtracting(installedIDs)
    guard !orphanIDs.isEmpty else { return [:] }

    struct Pair: Encodable {
      let type, tap, old, new, oldID, newID: String
    }
    var pairs: [Pair] = []
    func consider(_ raw: Record, type: String, name: String, fullName: String, formerNames: Any?) {
      guard let tap = raw["tap"] as? String, HomebrewPackageName.isValid(tap),
        tap.split(separator: "/").count == 2, !name.contains("/"),
        let formerNames = formerNames as? [String] else { return }
      let official = type == "formula" ? "homebrew/core" : "homebrew/cask"
      guard fullName == tap + "/" + name || (tap == official && fullName == name) else { return }
      let prefix = type + ":" + (fullName == name ? "" : tap + "/")
      for old in Set(formerNames) {
        let token = old.hasPrefix(tap + "/") ? String(old.dropFirst(tap.count + 1)) : old
        guard !token.contains("/"), HomebrewPackageName.isValid(token), orphanIDs.contains(prefix + token) else { continue }
        pairs.append(Pair(type: type, tap: tap, old: token, new: name, oldID: prefix + token, newID: type + ":" + fullName))
      }
    }
    for f in installed.formulae { consider(f.raw, type: "formula", name: f.name, fullName: f.fullName, formerNames: f.raw["oldnames"]) }
    for c in installed.casks { consider(c.raw, type: "cask", name: c.name, fullName: c.fullName, formerNames: c.raw["old_tokens"]) }
    guard !pairs.isEmpty, let encoded = try? JSONEncoder().encode(pairs).base64EncodedString() else { return [:] }
    let script = """
      require "json"
      pairs = JSON.parse("\(encoded)".unpack1("m0"))
      matches = pairs.each_index.select do |i|
        p = pairs.fetch(i)
        tap = Tap.fetch(p.fetch("tap"))
        next false unless tap.installed? || (tap.official? && !Homebrew::EnvConfig.no_install_from_api?)
        names = p.fetch("type") == "formula" ? tap.formula_renames : tap.cask_renames
        names[p.fetch("old")] == p.fetch("new")
      rescue StandardError
        false
      end
      puts JSON.generate(matches)
      """
    guard let output = try? run("/usr/bin/env", ["HOMEBREW_DEV_CMD_RUN=1", brew, "ruby", "-e", script], timeout: 10),
      let indices = try? JSONDecoder().decode([Int].self, from: Data(output.utf8)) else { return [:] }
    var result: [String: [String]] = [:]
    for index in Set(indices) where pairs.indices.contains(index) {
      let pair = pairs[index]
      result[pair.newID, default: []].append(pair.oldID)
    }
    return result.mapValues { Array(Set($0)).sorted() }
  }
}
