import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct Snippet: Identifiable, Codable, Hashable {
  var id: String
  var name: String
  var description: String
  var trigger: String
  var groupPath: [String]
  var body: String
  var isFavorite: Bool
}

struct GroupNode: Identifiable, Hashable {
  var id: String { path.joined(separator: "/") }
  let name: String
  let path: [String]
  let directCount: Int
  let totalCount: Int
  var children: [GroupNode]?
}

struct FlatGroupNode: Identifiable, Hashable {
  let node: GroupNode
  let depth: Int

  var id: String { node.id }
}

struct GroupCreateTarget: Identifiable {
  let id = UUID()
  let parentPath: [String]
}

struct GroupRenameTarget: Identifiable {
  let id = UUID()
  let path: [String]
}

struct TrashSnippetEntry: Identifiable, Codable, Hashable {
  var id: String
  var deletedAt: Date
  var originalGroupPath: [String]
  var snippet: Snippet
}

struct TrashGroupEntry: Identifiable, Codable, Hashable {
  struct GroupSnapshot: Codable, Hashable {
    var path: [String]
    var isHidden: Bool
  }

  var id: String
  var deletedAt: Date
  var originalPath: [String]
  var groups: [GroupSnapshot]
  var snippets: [Snippet]
}

enum SidebarSelection: Hashable {
  case all
  case group([String])
  case trash
}

final class SnippetStore: ObservableObject {
  @Published var snippets: [Snippet] = []
  @Published var groups: [[String]] = []
  @Published var disabledGroupKeys: Set<String> = []
  @Published var trashSnippets: [TrashSnippetEntry] = []
  @Published var trashGroups: [TrashGroupEntry] = []
  @Published private(set) var storageRootURL: URL
  @Published private(set) var storageFileURL: URL

  private var legacyFileURL: URL
  private var legacyGroupsRootURL: URL
  private var legacyDisabledGroupsFileURL: URL
  private var groupIDByPathKey: [String: String] = [:]
  private var groupOrderByPathKey: [String: Int] = [:]
  private var snippetOrderByID: [String: Int] = [:]
  private var timer: Timer?
  private var lastFingerprint: String = ""

  static func defaultStorageFilePath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Documents", isDirectory: true)
      .appendingPathComponent("mysnippets", isDirectory: true)
      .appendingPathComponent("snippets.json", isDirectory: false)
      .path
  }

  init(storageFilePath: String = SnippetStore.defaultStorageFilePath()) {
    let resolved = Self.resolveStorageFileURL(from: storageFilePath)
    let root = resolved.deletingLastPathComponent()
    self.storageFileURL = resolved
    self.storageRootURL = root
    self.legacyFileURL = root.appendingPathComponent("snippets.md", isDirectory: false)
    self.legacyGroupsRootURL = root.appendingPathComponent("groups", isDirectory: true)
    self.legacyDisabledGroupsFileURL = root.appendingPathComponent("disabled-groups.json", isDirectory: false)
    bootstrapIfNeeded()
    reload()
    startWatcher()
  }

  deinit {
    timer?.invalidate()
  }

  func updateStorageFilePath(_ path: String) {
    let resolved = Self.resolveStorageFileURL(from: path)
    guard resolved != storageFileURL else { return }
    storageFileURL = resolved
    storageRootURL = resolved.deletingLastPathComponent()
    legacyFileURL = storageRootURL.appendingPathComponent("snippets.md", isDirectory: false)
    legacyGroupsRootURL = storageRootURL.appendingPathComponent("groups", isDirectory: true)
    legacyDisabledGroupsFileURL = storageRootURL.appendingPathComponent("disabled-groups.json", isDirectory: false)
    groupIDByPathKey = [:]
    groupOrderByPathKey = [:]
    snippetOrderByID = [:]
    bootstrapIfNeeded()
    reload()
  }

  func reload() {
    try? FileManager.default.createDirectory(at: storageRootURL, withIntermediateDirectories: true)
    migrateLegacyIfNeeded()

    guard
      let data = try? Data(contentsOf: storageFileURL),
      let disk = try? JSONDecoder().decode(DiskStore.self, from: data)
    else {
      snippets = []
      groups = []
      disabledGroupKeys = []
      trashSnippets = []
      trashGroups = []
      groupIDByPathKey = [:]
      groupOrderByPathKey = [:]
      snippetOrderByID = [:]
      lastFingerprint = fingerprint()
      return
    }

    let loaded = decodeDiskStore(disk)
    groupIDByPathKey = loaded.groupIDByPathKey
    groupOrderByPathKey = loaded.groupOrderByPathKey
    snippetOrderByID = loaded.snippetOrderByID
    snippets = loaded.snippets.sorted(by: compareSnippets)
    groups = loaded.groups.sorted(by: comparePath)
    disabledGroupKeys = loaded.disabledKeys
    trashSnippets = loaded.trashSnippets.sorted(by: compareTrashSnippets)
    trashGroups = loaded.trashGroups.sorted(by: compareTrashGroups)
    lastFingerprint = fingerprint()
  }

  func upsert(_ snippet: Snippet) {
    var next = snippets
    var normalized = snippet
    normalized.groupPath = normalizeGroupPath(snippet.groupPath)
    if let idx = next.firstIndex(where: { $0.id == normalized.id }) {
      let previousGroupPath = next[idx].groupPath
      next.remove(at: idx)
      if previousGroupPath == normalized.groupPath {
        let insertionIndex = max(0, min(idx, next.count))
        next.insert(normalized, at: insertionIndex)
      } else {
        insertSnippet(normalized, into: &next)
      }
    } else {
      insertSnippet(normalized, into: &next)
    }
    persist(snippets: next, groups: groups, disabledKeys: disabledGroupKeys, trashSnippets: trashSnippets, trashGroups: trashGroups)
    applyCurrentState(snippets: next, groups: groups, disabledKeys: disabledGroupKeys, trashSnippets: trashSnippets, trashGroups: trashGroups)
  }

  func moveSnippets(in groupPath: [String], from source: IndexSet, to destination: Int) {
    let normalized = normalizeGroupPath(groupPath)
    let groupSnippets = snippets.filter { $0.groupPath == normalized }
    guard !groupSnippets.isEmpty else { return }

    var movedGroupSnippets = groupSnippets
    movedGroupSnippets.move(fromOffsets: source, toOffset: destination)
    var iterator = movedGroupSnippets.makeIterator()
    let nextSnippets = snippets.map { snippet in
      guard snippet.groupPath == normalized else { return snippet }
      return iterator.next() ?? snippet
    }

    persist(
      snippets: nextSnippets,
      groups: groups,
      disabledKeys: disabledGroupKeys,
      trashSnippets: trashSnippets,
      trashGroups: trashGroups
    )
    applyCurrentState(snippets: nextSnippets, groups: groups, disabledKeys: disabledGroupKeys, trashSnippets: trashSnippets, trashGroups: trashGroups)
  }

  func moveGroups(in parentPath: [String], from source: IndexSet, to destination: Int) {
    let normalizedParent = normalizeParentPath(parentPath)
    var siblings = directChildGroups(of: normalizedParent)
    guard !siblings.isEmpty else { return }

    siblings.move(fromOffsets: source, toOffset: destination)
    var childrenByParent: [String: [[String]]] = [:]
    for path in groups {
      childrenByParent[pathKey(Array(path.dropLast())), default: []].append(path)
    }
    childrenByParent[pathKey(normalizedParent)] = siblings

    persist(
      snippets: snippets,
      groups: flattenGroupTree(childrenByParent: childrenByParent),
      disabledKeys: disabledGroupKeys,
      trashSnippets: trashSnippets,
      trashGroups: trashGroups
    )
    applyCurrentState(
      snippets: snippets,
      groups: flattenGroupTree(childrenByParent: childrenByParent),
      disabledKeys: disabledGroupKeys,
      trashSnippets: trashSnippets,
      trashGroups: trashGroups
    )
  }

  func compareGroups(_ lhs: [String], _ rhs: [String]) -> Bool {
    comparePath(lhs, rhs)
  }

  func remove(_ snippet: Snippet) {
    let next = snippets.filter { $0.id != snippet.id }
    let entry = TrashSnippetEntry(
      id: UUID().uuidString,
      deletedAt: Date(),
      originalGroupPath: normalizeGroupPath(snippet.groupPath),
      snippet: snippet
    )
    persist(
      snippets: next,
      groups: groups,
      disabledKeys: disabledGroupKeys,
      trashSnippets: trashSnippets + [entry],
      trashGroups: trashGroups
    )
    reload()
  }

  func toggleFavorite(for snippet: Snippet) {
    guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
    var next = snippets
    next[idx].isFavorite.toggle()
    persist(snippets: next, groups: groups, disabledKeys: disabledGroupKeys, trashSnippets: trashSnippets, trashGroups: trashGroups)
    applyCurrentState(snippets: next, groups: groups, disabledKeys: disabledGroupKeys, trashSnippets: trashSnippets, trashGroups: trashGroups)
  }

  func createGroup(_ path: [String]) {
    let normalized = normalizeGroupPath(path)
    var nextGroups = groups
    appendGroupPath(normalized, to: &nextGroups)
    persist(
      snippets: snippets,
      groups: nextGroups,
      disabledKeys: disabledGroupKeys,
      trashSnippets: trashSnippets,
      trashGroups: trashGroups
    )
    applyCurrentState(snippets: snippets, groups: nextGroups, disabledKeys: disabledGroupKeys, trashSnippets: trashSnippets, trashGroups: trashGroups)
  }

  func disableGroup(_ path: [String]) {
    let key = pathKey(normalizeGroupPath(path))
    var next = disabledGroupKeys
    next.insert(key)
    persist(snippets: snippets, groups: groups, disabledKeys: next, trashSnippets: trashSnippets, trashGroups: trashGroups)
    applyCurrentState(snippets: snippets, groups: groups, disabledKeys: next, trashSnippets: trashSnippets, trashGroups: trashGroups)
  }

  func enableGroup(_ path: [String]) {
    let key = pathKey(normalizeGroupPath(path))
    var next = disabledGroupKeys
    next.remove(key)
    persist(snippets: snippets, groups: groups, disabledKeys: next, trashSnippets: trashSnippets, trashGroups: trashGroups)
    applyCurrentState(snippets: snippets, groups: groups, disabledKeys: next, trashSnippets: trashSnippets, trashGroups: trashGroups)
  }

  func isGroupDisabled(_ path: [String]) -> Bool {
    disabledGroupKeys.contains(pathKey(normalizeGroupPath(path)))
  }

  func isAnyAncestorDisabled(_ path: [String]) -> Bool {
    let normalized = normalizeGroupPath(path)
    for depth in 1...normalized.count {
      let key = pathKey(Array(normalized.prefix(depth)))
      if disabledGroupKeys.contains(key) {
        return true
      }
    }
    return false
  }

  func renameGroup(from oldPath: [String], to newName: String) {
    let normalizedOld = normalizeGroupPath(oldPath)
    let parent = Array(normalizedOld.dropLast())
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !normalizedOld.isEmpty else { return }
    let newPath = parent + [trimmed]
    if newPath == normalizedOld { return }

    let nextSnippets = snippets.map { snippet -> Snippet in
      guard hasPrefix(snippet.groupPath, prefix: normalizedOld) else { return snippet }
      var next = snippet
      next.groupPath = newPath + Array(snippet.groupPath.dropFirst(normalizedOld.count))
      return next
    }
    let nextGroups = groups.map { path -> [String] in
      guard hasPrefix(path, prefix: normalizedOld) else { return path }
      return newPath + Array(path.dropFirst(normalizedOld.count))
    }
    var nextDisabled = Set<String>()
    for key in disabledGroupKeys {
      let path = keyToPath(key)
      if hasPrefix(path, prefix: normalizedOld) {
        let replaced = newPath + Array(path.dropFirst(normalizedOld.count))
        nextDisabled.insert(pathKey(replaced))
      } else {
        nextDisabled.insert(key)
      }
    }
    var nextGroupIDMap: [String: String] = [:]
    for (key, id) in groupIDByPathKey {
      let path = keyToPath(key)
      if hasPrefix(path, prefix: normalizedOld) {
        let replaced = newPath + Array(path.dropFirst(normalizedOld.count))
        nextGroupIDMap[pathKey(replaced)] = id
      } else {
        nextGroupIDMap[key] = id
      }
    }
    groupIDByPathKey = nextGroupIDMap

    persist(
      snippets: nextSnippets,
      groups: nextGroups,
      disabledKeys: nextDisabled,
      trashSnippets: trashSnippets,
      trashGroups: trashGroups
    )
    applyCurrentState(snippets: nextSnippets, groups: nextGroups, disabledKeys: nextDisabled, trashSnippets: trashSnippets, trashGroups: trashGroups)
  }

  func deleteGroup(_ path: [String]) {
    let normalized = normalizeGroupPath(path)
    let removedSnippets = snippets.filter { hasPrefix($0.groupPath, prefix: normalized) }
    let removedGroups = groups
      .filter { hasPrefix($0, prefix: normalized) }
      .map { TrashGroupEntry.GroupSnapshot(path: $0, isHidden: disabledGroupKeys.contains(pathKey($0))) }
    let nextSnippets = snippets.filter { !hasPrefix($0.groupPath, prefix: normalized) }
    let nextGroups = groups.filter { !hasPrefix($0, prefix: normalized) }
    let nextDisabled = Set(disabledGroupKeys.filter { !hasPrefix(keyToPath($0), prefix: normalized) })
    groupIDByPathKey = groupIDByPathKey.filter { !hasPrefix(keyToPath($0.key), prefix: normalized) }
    let entry = TrashGroupEntry(
      id: UUID().uuidString,
      deletedAt: Date(),
      originalPath: normalized,
      groups: removedGroups,
      snippets: removedSnippets
    )
    persist(
      snippets: nextSnippets,
      groups: nextGroups,
      disabledKeys: nextDisabled,
      trashSnippets: trashSnippets,
      trashGroups: trashGroups + [entry]
    )
    applyCurrentState(snippets: nextSnippets, groups: nextGroups, disabledKeys: nextDisabled, trashSnippets: trashSnippets, trashGroups: trashGroups + [entry])
  }

  func restoreTrashSnippet(_ entry: TrashSnippetEntry) {
    guard let index = trashSnippets.firstIndex(where: { $0.id == entry.id }) else { return }
    var nextSnippets = snippets
    var restored = entry.snippet
    restored.groupPath = normalizeGroupPath(entry.originalGroupPath)
    if nextSnippets.contains(where: { $0.id == restored.id }) {
      restored.id = UUID().uuidString
    }
    insertSnippet(restored, into: &nextSnippets)
    var nextTrashSnippets = trashSnippets
    nextTrashSnippets.remove(at: index)
    persist(
      snippets: nextSnippets,
      groups: groups,
      disabledKeys: disabledGroupKeys,
      trashSnippets: nextTrashSnippets,
      trashGroups: trashGroups
    )
    applyCurrentState(snippets: nextSnippets, groups: groups, disabledKeys: disabledGroupKeys, trashSnippets: nextTrashSnippets, trashGroups: trashGroups)
  }

  func restoreTrashGroup(_ entry: TrashGroupEntry) {
    guard let index = trashGroups.firstIndex(where: { $0.id == entry.id }) else { return }

    var nextGroups = groups
    var nextDisabled = disabledGroupKeys
    for snapshot in entry.groups.sorted(by: { $0.path.count < $1.path.count }) {
      appendGroupPath(snapshot.path, to: &nextGroups)
      if snapshot.isHidden {
        nextDisabled.insert(pathKey(snapshot.path))
      } else {
        nextDisabled.remove(pathKey(snapshot.path))
      }
    }

    var nextSnippets = snippets
    for snippet in entry.snippets {
      var restored = snippet
      restored.groupPath = normalizeGroupPath(snippet.groupPath)
      if nextSnippets.contains(where: { $0.id == restored.id }) {
        restored.id = UUID().uuidString
      }
      insertSnippet(restored, into: &nextSnippets)
    }

    var nextTrashGroups = trashGroups
    nextTrashGroups.remove(at: index)
    persist(
      snippets: nextSnippets,
      groups: nextGroups,
      disabledKeys: nextDisabled,
      trashSnippets: trashSnippets,
      trashGroups: nextTrashGroups
    )
    applyCurrentState(snippets: nextSnippets, groups: nextGroups, disabledKeys: nextDisabled, trashSnippets: trashSnippets, trashGroups: nextTrashGroups)
  }

  func permanentlyDeleteTrashSnippet(_ entry: TrashSnippetEntry) {
    let nextTrashSnippets = trashSnippets.filter { $0.id != entry.id }
    persist(
      snippets: snippets,
      groups: groups,
      disabledKeys: disabledGroupKeys,
      trashSnippets: nextTrashSnippets,
      trashGroups: trashGroups
    )
    applyCurrentState(snippets: snippets, groups: groups, disabledKeys: disabledGroupKeys, trashSnippets: nextTrashSnippets, trashGroups: trashGroups)
  }

  func permanentlyDeleteTrashGroup(_ entry: TrashGroupEntry) {
    let nextTrashGroups = trashGroups.filter { $0.id != entry.id }
    persist(
      snippets: snippets,
      groups: groups,
      disabledKeys: disabledGroupKeys,
      trashSnippets: trashSnippets,
      trashGroups: nextTrashGroups
    )
    applyCurrentState(snippets: snippets, groups: groups, disabledKeys: disabledGroupKeys, trashSnippets: trashSnippets, trashGroups: nextTrashGroups)
  }

  func emptyTrash() {
    persist(
      snippets: snippets,
      groups: groups,
      disabledKeys: disabledGroupKeys,
      trashSnippets: [],
      trashGroups: []
    )
    applyCurrentState(snippets: snippets, groups: groups, disabledKeys: disabledGroupKeys, trashSnippets: [], trashGroups: [])
  }

  private func bootstrapIfNeeded() {
    try? FileManager.default.createDirectory(at: storageRootURL, withIntermediateDirectories: true)
    guard !FileManager.default.fileExists(atPath: storageFileURL.path), !hasLegacyData() else { return }

    let seed: [Snippet] = [
      Snippet(
        id: "eng-git-commit-template",
        name: "Conventional Commit (CN)",
        description: "带背景、影响范围和回滚方案占位的提交说明模板。",
        trigger: ";gcc",
        groupPath: ["Engineering", "Git", "Commit", "Templates"],
        body: "feat(scope): 简要说明\\n\\n{{! 发布前删除占位信息，复制时会自动删除此注释。}}\\n背景：...\\n影响范围：...\\n回滚方案：...",
        isFavorite: true
      ),
      Snippet(
        id: "work-sync-daily",
        name: "Daily Sync Update",
        description: "日常站会同步模板，包含昨天、今天和阻塞项。",
        trigger: ";dsu",
        groupPath: ["Work", "Sync", "Daily", "Standup"],
        body: "Yesterday:\\n- ...\\n\\nToday:\\n- ...\\n\\nBlockers:\\n- ...\\n{{! 预览提醒：别忘记 KPI。}}",
        isFavorite: false
      )
    ]
    persist(snippets: seed, groups: [], disabledKeys: [], trashSnippets: [], trashGroups: [])
  }

  private func startWatcher() {
    lastFingerprint = fingerprint()
    timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
      guard let self else { return }
      let current = self.fingerprint()
      if !self.lastFingerprint.isEmpty && current != self.lastFingerprint {
        self.reload()
      }
    }
  }

  private func fingerprint() -> String {
    guard FileManager.default.fileExists(atPath: storageFileURL.path) else { return "missing" }
    guard
      let attrs = try? FileManager.default.attributesOfItem(atPath: storageFileURL.path),
      let modified = attrs[.modificationDate] as? Date,
      let size = attrs[.size] as? NSNumber
    else {
      return "unknown"
    }
    return "\(storageFileURL.path):\(modified.timeIntervalSince1970):\(size.intValue)"
  }

  private static func resolveStorageFileURL(from rawPath: String) -> URL {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = trimmed.isEmpty ? defaultStorageFilePath() : NSString(string: trimmed).expandingTildeInPath
    return URL(fileURLWithPath: candidate, isDirectory: false)
  }

  private func parseLegacyMarkdown(_ raw: String, defaultGroupPath: [String]) -> [Snippet] {
    let pattern = "<!-- HIERASNIP:BEGIN (.+?) -->\\n([\\s\\S]*?)\\n<!-- HIERASNIP:END -->"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)

    return regex.matches(in: raw, range: nsRange).compactMap { m in
      guard
        let metaRange = Range(m.range(at: 1), in: raw),
        let bodyRange = Range(m.range(at: 2), in: raw),
        let data = raw[metaRange].data(using: .utf8)
      else { return nil }

      struct Meta: Codable { let id: String; let name: String; let trigger: String?; let groupPath: [String]? }
      guard let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }

      return Snippet(
        id: meta.id,
        name: meta.name,
        description: "",
        trigger: meta.trigger ?? "",
        groupPath: normalizeGroupPath(meta.groupPath ?? defaultGroupPath),
        body: String(raw[bodyRange]),
        isFavorite: false
      )
    }
  }

  func compareSnippets(_ lhs: Snippet, _ rhs: Snippet) -> Bool {
    if lhs.groupPath != rhs.groupPath {
      return comparePath(lhs.groupPath, rhs.groupPath)
    }

    let lhsOrder = snippetOrderByID[lhs.id] ?? Int.max
    let rhsOrder = snippetOrderByID[rhs.id] ?? Int.max
    if lhsOrder != rhsOrder {
      return lhsOrder < rhsOrder
    }

    let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
    if nameOrder != .orderedSame {
      return nameOrder == .orderedAscending
    }

    return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
  }

  func compareTrashSnippets(_ lhs: TrashSnippetEntry, _ rhs: TrashSnippetEntry) -> Bool {
    if lhs.deletedAt != rhs.deletedAt {
      return lhs.deletedAt > rhs.deletedAt
    }
    return compareSnippets(lhs.snippet, rhs.snippet)
  }

  func compareTrashGroups(_ lhs: TrashGroupEntry, _ rhs: TrashGroupEntry) -> Bool {
    if lhs.deletedAt != rhs.deletedAt {
      return lhs.deletedAt > rhs.deletedAt
    }
    return pathKey(lhs.originalPath).localizedStandardCompare(pathKey(rhs.originalPath)) == .orderedAscending
  }

  private func normalizeGroupPath(_ path: [String]) -> [String] {
    let trimmed = path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    return trimmed.isEmpty ? ["未分组"] : trimmed
  }

  private func hasPrefix(_ full: [String], prefix: [String]) -> Bool {
    if prefix.count > full.count { return false }
    for (idx, seg) in prefix.enumerated() where full[idx] != seg {
      return false
    }
    return true
  }

  private func pathKey(_ path: [String]) -> String {
    path.joined(separator: "/")
  }

  private func keyToPath(_ key: String) -> [String] {
    if key.isEmpty { return [] }
    return key.split(separator: "/").map(String.init)
  }

  private func comparePath(_ a: [String], _ b: [String]) -> Bool {
    if a == b { return false }

    let limit = min(a.count, b.count)
    for idx in 0..<limit {
      if a[idx] == b[idx] { continue }
      let lhsPath = Array(a.prefix(idx + 1))
      let rhsPath = Array(b.prefix(idx + 1))
      let lhsOrder = groupOrderByPathKey[pathKey(lhsPath)] ?? Int.max
      let rhsOrder = groupOrderByPathKey[pathKey(rhsPath)] ?? Int.max
      if lhsOrder != rhsOrder {
        return lhsOrder < rhsOrder
      }
      return a[idx].localizedStandardCompare(b[idx]) == .orderedAscending
    }

    return a.count < b.count
  }

  private func listLegacySnippetFiles() -> [URL] {
    guard let e = FileManager.default.enumerator(at: legacyGroupsRootURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
      return []
    }
    var result: [URL] = []
    for case let file as URL in e where file.pathExtension == "md" && file.lastPathComponent != "_group.md" && file.lastPathComponent != "group.md" {
      result.append(file)
    }
    return result
  }

  private func listLegacyGroupMarkerFiles() -> [URL] {
    guard let e = FileManager.default.enumerator(at: legacyGroupsRootURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
      return []
    }
    var result: [URL] = []
    for case let file as URL in e where file.lastPathComponent == "_group.md" || file.lastPathComponent == "group.md" {
      result.append(file)
    }
    return result
  }

  private func legacyGroupPathForFile(_ file: URL) -> [String] {
    let dir = file.deletingLastPathComponent()
    let relative = dir.path.replacingOccurrences(of: legacyGroupsRootURL.path + "/", with: "")
    if relative == dir.path { return ["未分组"] }
    return normalizeGroupPath(relative.split(separator: "/").map(String.init))
  }

  private func loadLegacyDisabledGroupKeys() -> Set<String> {
    guard
      let data = try? Data(contentsOf: legacyDisabledGroupsFileURL),
      let arr = try? JSONDecoder().decode([String].self, from: data)
    else {
      return []
    }
    return Set(arr)
  }

  private func hasLegacyData() -> Bool {
    if FileManager.default.fileExists(atPath: legacyFileURL.path) { return true }
    if FileManager.default.fileExists(atPath: legacyDisabledGroupsFileURL.path) { return true }
    return !listLegacySnippetFiles().isEmpty || !listLegacyGroupMarkerFiles().isEmpty
  }

  private func migrateLegacyIfNeeded() {
    guard !FileManager.default.fileExists(atPath: storageFileURL.path) else { return }
    guard hasLegacyData() else { return }

    var migratedSnippets: [Snippet] = []
    var groupSet = Set<String>()

    for file in listLegacySnippetFiles() {
      let groupPath = legacyGroupPathForFile(file)
      groupSet.insert(pathKey(groupPath))
      guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
      for snippet in parseLegacyMarkdown(raw, defaultGroupPath: groupPath) {
        var next = snippet
        next.groupPath = normalizeGroupPath(next.groupPath)
        migratedSnippets.append(next)
      }
    }

    for marker in listLegacyGroupMarkerFiles() {
      let path = legacyGroupPathForFile(marker)
      for depth in 0..<path.count {
        groupSet.insert(pathKey(Array(path.prefix(depth + 1))))
      }
    }

    if migratedSnippets.isEmpty, let raw = try? String(contentsOf: legacyFileURL, encoding: .utf8) {
      for snippet in parseLegacyMarkdown(raw, defaultGroupPath: ["未分组"]) {
        var next = snippet
        next.groupPath = normalizeGroupPath(next.groupPath)
        migratedSnippets.append(next)
      }
    }

    for snippet in migratedSnippets {
      for depth in 0..<snippet.groupPath.count {
        groupSet.insert(pathKey(Array(snippet.groupPath.prefix(depth + 1))))
      }
    }

    let migratedDisabled = loadLegacyDisabledGroupKeys()
    persist(
      snippets: migratedSnippets,
      groups: groupSet.map(keyToPath),
      disabledKeys: migratedDisabled,
      trashSnippets: [],
      trashGroups: []
    )
  }

  private func orderedGroupPaths(from groups: [[String]], snippets: [Snippet]) -> [[String]] {
    var ordered: [[String]] = []
    for path in groups {
      appendGroupPath(normalizeGroupPath(path), to: &ordered)
    }
    for snippet in snippets {
      appendGroupPath(snippet.groupPath, to: &ordered)
    }
    return ordered
  }

  private func appendGroupPath(_ path: [String], to groups: inout [[String]]) {
    for depth in 0..<path.count {
      let ancestor = Array(path.prefix(depth + 1))
      if !groups.contains(ancestor) {
        groups.append(ancestor)
      }
    }
  }

  private func insertSnippet(_ snippet: Snippet, into snippets: inout [Snippet]) {
    if let lastIndexInGroup = snippets.lastIndex(where: { $0.groupPath == snippet.groupPath }) {
      snippets.insert(snippet, at: lastIndexInGroup + 1)
    } else {
      snippets.append(snippet)
    }
  }

  private func normalizeParentPath(_ path: [String]) -> [String] {
    path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }

  private func directChildGroups(of parentPath: [String]) -> [[String]] {
    groups.filter { path in
      path.count == parentPath.count + 1 && Array(path.dropLast()) == parentPath
    }
  }

  private func flattenGroupTree(childrenByParent: [String: [[String]]], parentPath: [String] = []) -> [[String]] {
    let parentKey = pathKey(parentPath)
    var result: [[String]] = []
    for child in childrenByParent[parentKey] ?? [] {
      result.append(child)
      result.append(contentsOf: flattenGroupTree(childrenByParent: childrenByParent, parentPath: child))
    }
    return result
  }

  private func applyCurrentState(
    snippets: [Snippet],
    groups: [[String]],
    disabledKeys: Set<String>,
    trashSnippets: [TrashSnippetEntry],
    trashGroups: [TrashGroupEntry]
  ) {
    self.snippets = snippets.sorted(by: compareSnippets)
    self.groups = groups.sorted(by: comparePath)
    self.disabledGroupKeys = disabledKeys
    self.trashSnippets = trashSnippets.sorted(by: compareTrashSnippets)
    self.trashGroups = trashGroups.sorted(by: compareTrashGroups)
    lastFingerprint = fingerprint()
  }

  private func persist(
    snippets: [Snippet],
    groups: [[String]],
    disabledKeys: Set<String>,
    trashSnippets: [TrashSnippetEntry],
    trashGroups: [TrashGroupEntry]
  ) {
    let normalizedSnippets = snippets.map { snippet -> Snippet in
      var next = snippet
      next.groupPath = normalizeGroupPath(snippet.groupPath)
      return next
    }
    let orderedGroups = orderedGroupPaths(from: groups, snippets: normalizedSnippets)
    var nextGroupIDByPathKey: [String: String] = [:]
    for path in orderedGroups {
      let key = pathKey(path)
      nextGroupIDByPathKey[key] = groupIDByPathKey[key] ?? UUID().uuidString
    }

    var nextGroupOrderByParent: [String: Int] = [:]
    var diskGroups: [DiskGroup] = []
    var nextGroupOrderByPathKey: [String: Int] = [:]
    for path in orderedGroups {
      guard let id = nextGroupIDByPathKey[pathKey(path)], let name = path.last else { continue }
      let parent = Array(path.dropLast())
      let parentKey = pathKey(parent)
      let order = nextGroupOrderByParent[parentKey, default: 0]
      nextGroupOrderByParent[parentKey] = order + 1
      nextGroupOrderByPathKey[pathKey(path)] = order
      diskGroups.append(DiskGroup(
        id: id,
        name: name,
        parentID: parent.isEmpty ? nil : nextGroupIDByPathKey[parentKey],
        hidden: disabledKeys.contains(pathKey(path)),
        order: order
      ))
    }

    var nextSnippetOrderByGroupID: [String: Int] = [:]
    var diskSnippets: [DiskSnippet] = []
    var nextSnippetOrderByID: [String: Int] = [:]
    for snippet in normalizedSnippets {
      let key = pathKey(snippet.groupPath)
      guard let groupID = nextGroupIDByPathKey[key] else { continue }
      let order = nextSnippetOrderByGroupID[groupID, default: 0]
      nextSnippetOrderByGroupID[groupID] = order + 1
      nextSnippetOrderByID[snippet.id] = order
      diskSnippets.append(DiskSnippet(
        id: snippet.id,
        name: snippet.name,
        prefix: snippet.trigger,
        body: snippet.body.components(separatedBy: "\n"),
        description: snippet.description.isEmpty ? nil : snippet.description,
        favorite: snippet.isFavorite,
        groupID: groupID,
        order: order
      ))
    }

    let disk = DiskStore(
      version: "1.1",
      groups: diskGroups,
      snippets: diskSnippets,
      trash: DiskTrash(
        snippets: trashSnippets.map { entry in
          DiskTrashSnippet(
            id: entry.id,
            deletedAt: entry.deletedAt,
            originalGroupPath: entry.originalGroupPath,
            snippet: DiskTrashSnippetPayload(
              id: entry.snippet.id,
              name: entry.snippet.name,
              prefix: entry.snippet.trigger,
              body: entry.snippet.body.components(separatedBy: "\n"),
              description: entry.snippet.description.isEmpty ? nil : entry.snippet.description,
              favorite: entry.snippet.isFavorite
            )
          )
        },
        groups: trashGroups.map { entry in
          DiskTrashGroup(
            id: entry.id,
            deletedAt: entry.deletedAt,
            originalPath: entry.originalPath,
            groups: entry.groups.map { snapshot in
              DiskTrashGroupSnapshot(path: snapshot.path, hidden: snapshot.isHidden)
            },
            snippets: entry.snippets.map { snippet in
              DiskTrashGroupSnippet(
                id: snippet.id,
                name: snippet.name,
                prefix: snippet.trigger,
                body: snippet.body.components(separatedBy: "\n"),
                description: snippet.description.isEmpty ? nil : snippet.description,
                favorite: snippet.isFavorite,
                groupPath: snippet.groupPath
              )
            }
          )
        }
      )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(disk) else { return }
    try? data.write(to: storageFileURL, options: .atomic)
    groupIDByPathKey = nextGroupIDByPathKey
    groupOrderByPathKey = nextGroupOrderByPathKey
    snippetOrderByID = nextSnippetOrderByID
    lastFingerprint = fingerprint()
  }

  private func decodeDiskStore(_ disk: DiskStore) -> (snippets: [Snippet], groups: [[String]], disabledKeys: Set<String>, trashSnippets: [TrashSnippetEntry], trashGroups: [TrashGroupEntry], groupIDByPathKey: [String: String], groupOrderByPathKey: [String: Int], snippetOrderByID: [String: Int]) {
    let rootGroupID = "__root__"
    var childrenByParentID: [String: [DiskGroup]] = [:]
    for group in disk.groups {
      childrenByParentID[group.parentID ?? rootGroupID, default: []].append(group)
    }

    var resolvedPathByGroupID: [String: [String]] = [:]
    var loadedGroups: [[String]] = []
    var loadedDisabledKeys = Set<String>()
    var loadedGroupIDByPathKey: [String: String] = [:]
    var loadedGroupOrderByPathKey: [String: Int] = [:]

    func visitGroups(parentID: String, parentPath: [String]) {
      let children = (childrenByParentID[parentID] ?? []).sorted { lhs, rhs in
        if lhs.order != rhs.order {
          return lhs.order < rhs.order
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
      for child in children {
        let path = normalizeGroupPath(parentPath + [child.name])
        let key = pathKey(path)
        loadedGroups.append(path)
        resolvedPathByGroupID[child.id] = path
        loadedGroupIDByPathKey[key] = child.id
        loadedGroupOrderByPathKey[key] = child.order
        if child.hidden {
          loadedDisabledKeys.insert(key)
        }
        visitGroups(parentID: child.id, parentPath: path)
      }
    }
    visitGroups(parentID: rootGroupID, parentPath: [])

    var loadedSnippets: [Snippet] = []
    var loadedSnippetOrderByID: [String: Int] = [:]
    for snippet in disk.snippets {
      let path = resolvedPathByGroupID[snippet.groupID] ?? ["未分组"]
      for depth in 0..<path.count {
        let ancestor = Array(path.prefix(depth + 1))
        if !loadedGroups.contains(ancestor) {
          loadedGroups.append(ancestor)
        }
      }
      loadedSnippetOrderByID[snippet.id] = snippet.order
      loadedSnippets.append(Snippet(
        id: snippet.id,
        name: snippet.name,
        description: snippet.description ?? "",
        trigger: snippet.prefix,
        groupPath: path,
        body: snippet.body.joined(separator: "\n"),
        isFavorite: snippet.favorite ?? false
      ))
    }

    let loadedTrashSnippets = (disk.trash?.snippets ?? []).map { entry in
      TrashSnippetEntry(
        id: entry.id,
        deletedAt: entry.deletedAt,
        originalGroupPath: normalizeGroupPath(entry.originalGroupPath),
        snippet: Snippet(
          id: entry.snippet.id,
          name: entry.snippet.name,
          description: entry.snippet.description ?? "",
          trigger: entry.snippet.prefix,
          groupPath: normalizeGroupPath(entry.originalGroupPath),
          body: entry.snippet.body.joined(separator: "\n"),
          isFavorite: entry.snippet.favorite ?? false
        )
      )
    }

    let loadedTrashGroups = (disk.trash?.groups ?? []).map { entry in
      TrashGroupEntry(
        id: entry.id,
        deletedAt: entry.deletedAt,
        originalPath: normalizeGroupPath(entry.originalPath),
        groups: entry.groups.map { snapshot in
          TrashGroupEntry.GroupSnapshot(
            path: normalizeGroupPath(snapshot.path),
            isHidden: snapshot.hidden
          )
        },
        snippets: entry.snippets.map { snippet in
          Snippet(
            id: snippet.id,
            name: snippet.name,
            description: snippet.description ?? "",
            trigger: snippet.prefix,
            groupPath: normalizeGroupPath(snippet.groupPath),
            body: snippet.body.joined(separator: "\n"),
            isFavorite: snippet.favorite ?? false
          )
        }
      )
    }

    return (
      snippets: loadedSnippets,
      groups: loadedGroups,
      disabledKeys: loadedDisabledKeys,
      trashSnippets: loadedTrashSnippets,
      trashGroups: loadedTrashGroups,
      groupIDByPathKey: loadedGroupIDByPathKey,
      groupOrderByPathKey: loadedGroupOrderByPathKey,
      snippetOrderByID: loadedSnippetOrderByID
    )
  }

  private struct DiskStore: Codable {
    let version: String
    let groups: [DiskGroup]
    let snippets: [DiskSnippet]
    let trash: DiskTrash?
  }

  private struct DiskGroup: Codable {
    let id: String
    let name: String
    let parentID: String?
    let hidden: Bool
    let order: Int

    enum CodingKeys: String, CodingKey {
      case id
      case name
      case parentID = "parent_id"
      case hidden
      case order
    }
  }

  private struct DiskSnippet: Codable {
    let id: String
    let name: String
    let prefix: String
    let body: [String]
    let description: String?
    let favorite: Bool?
    let groupID: String
    let order: Int

    enum CodingKeys: String, CodingKey {
      case id
      case name
      case prefix
      case body
      case description
      case favorite
      case groupID = "group_id"
      case order
    }
  }

  private struct DiskTrash: Codable {
    let snippets: [DiskTrashSnippet]
    let groups: [DiskTrashGroup]
  }

  private struct DiskTrashSnippet: Codable {
    let id: String
    let deletedAt: Date
    let originalGroupPath: [String]
    let snippet: DiskTrashSnippetPayload

    enum CodingKeys: String, CodingKey {
      case id
      case deletedAt = "deleted_at"
      case originalGroupPath = "original_group_path"
      case snippet
    }
  }

  private struct DiskTrashSnippetPayload: Codable {
    let id: String
    let name: String
    let prefix: String
    let body: [String]
    let description: String?
    let favorite: Bool?
  }

  private struct DiskTrashGroup: Codable {
    let id: String
    let deletedAt: Date
    let originalPath: [String]
    let groups: [DiskTrashGroupSnapshot]
    let snippets: [DiskTrashGroupSnippet]

    enum CodingKeys: String, CodingKey {
      case id
      case deletedAt = "deleted_at"
      case originalPath = "original_path"
      case groups
      case snippets
    }
  }

  private struct DiskTrashGroupSnapshot: Codable {
    let path: [String]
    let hidden: Bool
  }

  private struct DiskTrashGroupSnippet: Codable {
    let id: String
    let name: String
    let prefix: String
    let body: [String]
    let description: String?
    let favorite: Bool?
    let groupPath: [String]

    enum CodingKeys: String, CodingKey {
      case id
      case name
      case prefix
      case body
      case description
      case favorite
      case groupPath = "group_path"
    }
  }
}

final class UISettings: ObservableObject {
  @AppStorage("fontSize") var fontSize: Double = 13
  @AppStorage("rowHeight") var rowHeight: Double = 22
  @AppStorage("storageFilePath") var storageFilePath: String = SnippetStore.defaultStorageFilePath()
  @AppStorage("hotKeyKeyCode") var hotKeyKeyCode: Int = Int(kVK_ANSI_0)
  @AppStorage("hotKeyModifiers") var hotKeyModifiers: Int = Int(optionKey)

  var hotKeyShortcut: HotKeyShortcut {
    get {
      HotKeyShortcut(
        keyCode: UInt32(hotKeyKeyCode),
        carbonModifiers: UInt32(hotKeyModifiers)
      )
    }
    set {
      hotKeyKeyCode = Int(newValue.keyCode)
      hotKeyModifiers = Int(newValue.carbonModifiers)
    }
  }
}

struct HotKeyShortcut: Equatable {
  let keyCode: UInt32
  let carbonModifiers: UInt32

  static let `default` = HotKeyShortcut(
    keyCode: UInt32(kVK_ANSI_0),
    carbonModifiers: UInt32(optionKey)
  )

  var displayString: String {
    modifierSymbols + (keyDisplay ?? "?")
  }

  var hasModifier: Bool {
    carbonModifiers & UInt32(cmdKey | optionKey | controlKey | shiftKey) != 0
  }

  var isRecordable: Bool {
    hasModifier && keyDisplay != nil
  }

  private var modifierSymbols: String {
    var parts: [String] = []
    if carbonModifiers & UInt32(controlKey) != 0 { parts.append("^") }
    if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
    if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
    if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
    return parts.joined()
  }

  private var keyDisplay: String? {
    Self.displayString(forKeyCode: keyCode)
  }

  static func from(event: NSEvent) -> HotKeyShortcut? {
    let relevantFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    let shortcut = HotKeyShortcut(
      keyCode: UInt32(event.keyCode),
      carbonModifiers: carbonModifiers(from: relevantFlags)
    )
    return shortcut.isRecordable ? shortcut : nil
  }

  static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var result: UInt32 = 0
    if flags.contains(.command) { result |= UInt32(cmdKey) }
    if flags.contains(.option) { result |= UInt32(optionKey) }
    if flags.contains(.control) { result |= UInt32(controlKey) }
    if flags.contains(.shift) { result |= UInt32(shiftKey) }
    return result
  }

  static func displayString(forKeyCode keyCode: UInt32) -> String? {
    let keys: [UInt32: String] = [
      UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
      UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
      UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
      UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
      UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
      UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
      UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
      UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
      UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5", UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
      UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
      UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return", UInt32(kVK_Tab): "Tab", UInt32(kVK_Delete): "Delete",
      UInt32(kVK_Escape): "Esc",
      UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
      UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
      UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
      UInt32(kVK_LeftArrow): "Left", UInt32(kVK_RightArrow): "Right", UInt32(kVK_UpArrow): "Up", UInt32(kVK_DownArrow): "Down"
    ]
    return keys[keyCode]
  }
}

final class GlobalHotKeyManager {
  static let shared = GlobalHotKeyManager()

  private static let hotKeySignature: OSType = 0x4D535048 // "MSPH"
  private static let hotKeyID: UInt32 = 1

  var onPressed: (() -> Void)?

  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private var isRegistered = false
  private var currentShortcut: HotKeyShortcut = .default

  private init() {}

  deinit {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
    if let handlerRef {
      RemoveEventHandler(handlerRef)
    }
  }

  func configure(shortcut: HotKeyShortcut, onPressed: @escaping () -> Void) {
    self.onPressed = onPressed
    registerIfNeeded()
    updateRegisteredShortcut(shortcut)
  }

  func registerIfNeeded() {
    if isRegistered { return }

    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

    InstallEventHandler(
      GetEventDispatcherTarget(),
      { _, event, userData in
        guard let userData else { return noErr }
        let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        return manager.handle(event: event)
      },
      1,
      &eventType,
      selfPointer,
      &handlerRef
    )

    isRegistered = true
  }

  private func updateRegisteredShortcut(_ shortcut: HotKeyShortcut) {
    guard shortcut.isRecordable else { return }
    if currentShortcut == shortcut, hotKeyRef != nil { return }

    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }

    let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
    let status = RegisterEventHotKey(
      shortcut.keyCode,
      shortcut.carbonModifiers,
      hotKeyID,
      GetEventDispatcherTarget(),
      0,
      &hotKeyRef
    )

    if status == noErr {
      currentShortcut = shortcut
    }
  }

  private func handle(event: EventRef?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &hotKeyID
    )
    guard status == noErr else { return status }

    if hotKeyID.signature == Self.hotKeySignature, hotKeyID.id == Self.hotKeyID {
      DispatchQueue.main.async { [weak self] in
        self?.onPressed?()
      }
    }
    return noErr
  }
}

final class QuickInsertController {
  static let shared = QuickInsertController()
  private static let quickPanelFrameDefaultsKey = "quickPanelSavedFrame"

  private weak var store: SnippetStore?
  private weak var settings: UISettings?
  private var panel: NSPanel?
  private var host: NSHostingController<AnyView>?
  private var previousActiveApp: NSRunningApplication?
  private var lastExternalActiveApp: NSRunningApplication?
  private var workspaceObserver: NSObjectProtocol?
  private var hasShownAccessibilityAlert = false
  private var hasShownAutomationAlert = false
  private var hasShownPasteFailedAlert = false
  private var presentationID = UUID()
  private var isApplyingPanelPosition = false
  private var panelMoveObserver: NSObjectProtocol?

  private init() {
    workspaceObserver = NotificationCenter.default.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: NSWorkspace.shared,
      queue: .main
    ) { [weak self] notification in
      guard
        let self,
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app != NSRunningApplication.current
      else { return }
      self.lastExternalActiveApp = app
    }
  }

  deinit {
    if let workspaceObserver {
      NotificationCenter.default.removeObserver(workspaceObserver)
    }
    if let panelMoveObserver {
      NotificationCenter.default.removeObserver(panelMoveObserver)
    }
  }

  func configure(store: SnippetStore, settings: UISettings) {
    self.store = store
    self.settings = settings
    updatePanelContentIfNeeded()
  }

  func show() {
    guard let store, let settings else { return }
    let frontmost = NSWorkspace.shared.frontmostApplication
    if let frontmost, frontmost != NSRunningApplication.current {
      previousActiveApp = frontmost
      lastExternalActiveApp = frontmost
    } else {
      previousActiveApp = lastExternalActiveApp
    }
    presentationID = UUID()
    let targetScreen = currentTargetScreen()
    let defaultFrame = WindowLayout.quickPanelFrame(for: WindowLayout.quickPanelDefaultSize, screen: targetScreen)
    let targetFrame = resolvedPanelFrame(for: targetScreen, fallback: defaultFrame)

    if panel == nil {
      let panel = QuickSearchPanel(
        contentRect: targetFrame,
        styleMask: [.titled, .closable, .fullSizeContentView],
        backing: .buffered,
        defer: false
      )
      panel.title = "快速搜索 Snippet"
      panel.level = .floating
      panel.titleVisibility = .hidden
      panel.titlebarAppearsTransparent = true
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.appearance = NSAppearance(named: .aqua)
      panel.hasShadow = true
      panel.isMovableByWindowBackground = true
      panel.minSize = WindowLayout.quickPanelMinimumSize
      panel.isReleasedWhenClosed = false
      panel.hidesOnDeactivate = false
      panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
      panel.isFloatingPanel = true
      panel.standardWindowButton(.closeButton)?.isHidden = true
      panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
      panel.standardWindowButton(.zoomButton)?.isHidden = true
      panel.onResignKey = { [weak self] in
        self?.hide()
      }
      self.panel = panel
      installPanelMoveObserver(for: panel)
    }

    let view = AnyView(QuickInsertView(
      onSubmit: { [weak self] snippet in
        self?.insert(snippet)
      },
      onCancel: { [weak self] in
        self?.hide()
      }
    )
    .environmentObject(store)
    .environmentObject(settings)
    .id(presentationID))

    if let host {
      host.rootView = view
    } else {
      let host = NSHostingController(rootView: view)
      self.host = host
      panel?.contentViewController = host
    }

    if let panel {
      apply(panel: panel, frame: targetFrame)
      NSApp.activate(ignoringOtherApps: true)
      panel.makeKeyAndOrderFront(nil)
      panel.orderFrontRegardless()
      apply(panel: panel, frame: targetFrame)
      DispatchQueue.main.async { [weak self] in
        guard let self, let panel = self.panel else { return }
        let screen = self.currentTargetScreen(for: panel)
        let fallback = WindowLayout.quickPanelFrame(for: panel.frame.size, screen: screen)
        let resolvedFrame = self.resolvedPanelFrame(for: screen, fallback: fallback, size: panel.frame.size)
        self.apply(panel: panel, frame: resolvedFrame)
      }
    }
  }

  func hide() {
    panel?.orderOut(nil)
  }

  private func currentTargetScreen() -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
      return screen
    }
    return NSScreen.main
  }

  private func currentTargetScreen(for panel: NSPanel) -> NSScreen? {
    currentTargetScreen() ?? panel.screen ?? NSScreen.main
  }

  private func resolvedPanelFrame(
    for screen: NSScreen?,
    fallback: NSRect,
    size: NSSize = WindowLayout.quickPanelDefaultSize
  ) -> NSRect {
    guard let savedFrame = savedPanelFrame() else { return fallback }
    let normalizedSavedFrame = NSRect(
      x: savedFrame.minX,
      y: savedFrame.minY,
      width: max(savedFrame.width, WindowLayout.quickPanelMinimumSize.width),
      height: max(savedFrame.height, WindowLayout.quickPanelMinimumSize.height)
    )
    guard let sourceScreen = screenContaining(frame: normalizedSavedFrame) else {
      return WindowLayout.clampedFrame(normalizedSavedFrame, on: screen, fallbackOrigin: fallback.origin)
    }
    guard let screen else {
      return WindowLayout.clampedFrame(normalizedSavedFrame, on: sourceScreen, fallbackOrigin: fallback.origin)
    }

    let translatedFrame = WindowLayout.translatedFrame(
      normalizedSavedFrame,
      from: sourceScreen,
      to: screen,
      fallbackSize: size
    )
    return WindowLayout.clampedFrame(translatedFrame, on: screen, fallbackOrigin: fallback.origin)
  }

  private func screenContaining(frame: NSRect) -> NSScreen? {
    let frameCenter = NSPoint(x: frame.midX, y: frame.midY)
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(frameCenter) }) {
      return screen
    }

    return NSScreen.screens.max { lhs, rhs in
      lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
    }
  }

  private func position(panel: NSPanel, on screen: NSScreen?) {
    let targetFrame = WindowLayout.quickPanelFrame(for: panel.frame.size, screen: screen)
    apply(panel: panel, frame: targetFrame)
  }

  private func apply(panel: NSPanel, frame: NSRect) {
    isApplyingPanelPosition = true
    panel.setFrame(frame, display: true)
    panel.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY))
    isApplyingPanelPosition = false
  }

  private func installPanelMoveObserver(for panel: NSPanel) {
    if let panelMoveObserver {
      NotificationCenter.default.removeObserver(panelMoveObserver)
    }
    panelMoveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification,
      object: panel,
      queue: .main
    ) { [weak self] notification in
      guard
        let self,
        !self.isApplyingPanelPosition,
        let window = notification.object as? NSWindow
      else { return }
      self.savePanelFrame(window.frame)
    }
  }

  private func savePanelFrame(_ frame: NSRect) {
    let value = NSStringFromRect(frame)
    UserDefaults.standard.set(value, forKey: Self.quickPanelFrameDefaultsKey)
  }

  private func savedPanelFrame() -> NSRect? {
    guard let raw = UserDefaults.standard.string(forKey: Self.quickPanelFrameDefaultsKey) else { return nil }
    let frame = NSRectFromString(raw)
    guard frame.width > 0, frame.height > 0 else { return nil }
    return frame
  }

  func resetSavedPanelFrame() {
    UserDefaults.standard.removeObject(forKey: Self.quickPanelFrameDefaultsKey)
    if let panel {
      position(panel: panel, on: currentTargetScreen(for: panel))
    }
  }

  private func updatePanelContentIfNeeded() {
    guard panel != nil, let store, let settings else { return }
    let view = AnyView(QuickInsertView(
      onSubmit: { [weak self] snippet in
        self?.insert(snippet)
      },
      onCancel: { [weak self] in
        self?.hide()
      }
    )
    .environmentObject(store)
    .environmentObject(settings))
    host?.rootView = view
  }

  private func insert(_ snippet: Snippet) {
    let expanded = expandSnippetBody(snippet.body)
    hide()
    pasteToPreviousApp(expanded)
  }

  private func pasteToPreviousApp(_ content: ExpandedSnippetContent) {
    let target = (previousActiveApp ?? lastExternalActiveApp)
    if let app = target, app != NSRunningApplication.current {
      app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
      pasteWhenTargetIsFrontmost(content: content, targetApp: app, attempt: 0)
      return
    }

    _ = pasteViaCommandV(content)
  }

  private func pasteWhenTargetIsFrontmost(content: ExpandedSnippetContent, targetApp: NSRunningApplication, attempt: Int) {
    let maxAttempts = 10
    let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp.processIdentifier

    if isFrontmost {
      if pasteViaCommandV(content) || attempt >= maxAttempts {
        return
      }
    } else if attempt >= maxAttempts {
      _ = pasteViaCommandV(content)
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      self?.pasteWhenTargetIsFrontmost(content: content, targetApp: targetApp, attempt: attempt + 1)
    }
  }

  @discardableResult
  private func pasteViaCommandV(_ content: ExpandedSnippetContent) -> Bool {
    guard AXIsProcessTrusted() else {
      showAccessibilityPermissionAlert()
      return false
    }

    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(content.text, forType: .string)

    let systemEvents = triggerPasteViaSystemEvents()
    if systemEvents.success {
      positionCursorIfNeeded(content.cursorOffsetFromEnd)
      return true
    }

    if systemEvents.errorNumber == -1743 || systemEvents.errorNumber == -1744 {
      showAutomationPermissionAlert(details: systemEvents.errorMessage)
    }

    if triggerPasteViaCGEvent() {
      positionCursorIfNeeded(content.cursorOffsetFromEnd)
      return true
    }

    showPasteFailedAlert(details: systemEvents.errorMessage)
    return false
  }

  private func triggerPasteViaSystemEvents() -> (success: Bool, errorNumber: Int?, errorMessage: String?) {
    let script = """
    tell application "System Events"
      keystroke "v" using command down
    end tell
    """
    var error: NSDictionary?
    let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
    if result != nil && error == nil {
      return (true, nil, nil)
    }
    let number = error?[NSAppleScript.errorNumber] as? Int
    let message = (error?[NSAppleScript.errorMessage] as? String) ?? "未知错误"
    return (false, number, message)
  }

  private func triggerPasteViaCGEvent() -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
    else { return false }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return true
  }

  private func positionCursorIfNeeded(_ offset: Int?) {
    guard let offset, offset > 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      self.sendLeftArrowKeyPresses(count: offset)
    }
  }

  private func sendLeftArrowKeyPresses(count: Int) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    for _ in 0..<count {
      guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x7B, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x7B, keyDown: false)
      else { return }
      keyDown.post(tap: .cghidEventTap)
      keyUp.post(tap: .cghidEventTap)
    }
  }

  private func showAccessibilityPermissionAlert() {
    guard !hasShownAccessibilityAlert else { return }
    hasShownAccessibilityAlert = true
    hasShownPasteFailedAlert = false
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "无法自动填入：缺少“辅助功能”权限"
    alert.informativeText = """
    请前往：
    系统设置 -> 隐私与安全性 -> 辅助功能
    将 mysnippets 勾选为允许。
    完成后重启 mysnippets 再试。
    """
    alert.addButton(withTitle: "知道了")
    alert.runModal()
  }

  private func showAutomationPermissionAlert(details: String?) {
    guard !hasShownAutomationAlert else { return }
    hasShownAutomationAlert = true
    let detailText = details?.isEmpty == false ? "\n系统返回：\(details!)" : ""
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "自动化权限被拒绝（System Events）"
    alert.informativeText = """
    请前往：
    系统设置 -> 隐私与安全性 -> 自动化
    在 mysnippets 下允许控制 System Events。\(detailText)
    """
    alert.addButton(withTitle: "知道了")
    alert.runModal()
  }

  private func showPasteFailedAlert(details: String?) {
    guard !hasShownPasteFailedAlert else { return }
    hasShownPasteFailedAlert = true
    let detailText = details?.isEmpty == false ? "\n系统返回：\(details!)" : ""
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "自动填入失败"
    alert.informativeText = """
    已尝试使用 System Events 和键盘事件模拟粘贴，但都未成功。请检查辅助功能/自动化权限。\(detailText)
    """
    alert.addButton(withTitle: "知道了")
    alert.runModal()
  }
}

final class QuickSearchPanel: NSPanel {
  var onResignKey: (() -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func resignKey() {
    super.resignKey()
    onResignKey?()
  }
}

enum WindowLayout {
  static let mainWindowWidthRatio: CGFloat = 0.744
  static let mainWindowHeightRatio: CGFloat = 0.82
  static let quickPanelTopInsetRatio: CGFloat = 0.20
  static let quickPanelMinimumSize = NSSize(width: 820, height: 500)
  static let quickPanelDefaultSize = NSSize(width: 860, height: 500)

  static func defaultMainWindowSize(for screen: NSScreen? = NSScreen.main) -> NSSize {
    let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return NSSize(
      width: floor(visibleFrame.width * mainWindowWidthRatio),
      height: floor(visibleFrame.height * mainWindowHeightRatio)
    )
  }

  static func centeredFrame(for size: NSSize, screen: NSScreen? = NSScreen.main) -> NSRect {
    let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return NSRect(
      x: visibleFrame.midX - (size.width / 2),
      y: visibleFrame.midY - (size.height / 2),
      width: size.width,
      height: size.height
    )
  }

  static func quickPanelFrame(for size: NSSize, screen: NSScreen? = NSScreen.main) -> NSRect {
    let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let x = visibleFrame.midX - (size.width / 2)
    let y = visibleFrame.maxY - size.height - floor(visibleFrame.height * quickPanelTopInsetRatio)
    return NSRect(x: x, y: y, width: size.width, height: size.height)
  }

  static func translatedFrame(
    _ frame: NSRect,
    from sourceScreen: NSScreen,
    to targetScreen: NSScreen,
    fallbackSize: NSSize
  ) -> NSRect {
    let sourceVisibleFrame = sourceScreen.visibleFrame
    let targetVisibleFrame = targetScreen.visibleFrame
    let size = NSSize(
      width: min(frame.width, targetVisibleFrame.width),
      height: min(frame.height, targetVisibleFrame.height)
    )
    let safeSize = NSSize(
      width: size.width > 0 ? size.width : fallbackSize.width,
      height: size.height > 0 ? size.height : fallbackSize.height
    )

    let relativeX = sourceVisibleFrame.width > frame.width
      ? (frame.minX - sourceVisibleFrame.minX) / (sourceVisibleFrame.width - frame.width)
      : 0.5
    let relativeY = sourceVisibleFrame.height > frame.height
      ? (frame.minY - sourceVisibleFrame.minY) / (sourceVisibleFrame.height - frame.height)
      : 0.5

    let clampedRelativeX = min(max(relativeX, 0), 1)
    let clampedRelativeY = min(max(relativeY, 0), 1)
    let x = targetVisibleFrame.minX + (targetVisibleFrame.width - safeSize.width) * clampedRelativeX
    let y = targetVisibleFrame.minY + (targetVisibleFrame.height - safeSize.height) * clampedRelativeY
    return NSRect(x: x, y: y, width: safeSize.width, height: safeSize.height)
  }

  static func clampedFrame(_ frame: NSRect, on screen: NSScreen?, fallbackOrigin: NSPoint) -> NSRect {
    guard let screen else { return frame }
    let visibleFrame = screen.visibleFrame
    let width = min(frame.width, visibleFrame.width)
    let height = min(frame.height, visibleFrame.height)
    let minX = visibleFrame.minX
    let maxX = visibleFrame.maxX - width
    let minY = visibleFrame.minY
    let maxY = visibleFrame.maxY - height
    let x = min(max(frame.minX, minX), maxX.isFinite ? maxX : fallbackOrigin.x)
    let y = min(max(frame.minY, minY), maxY.isFinite ? maxY : fallbackOrigin.y)
    return NSRect(x: x, y: y, width: width, height: height)
  }
}

private extension NSRect {
  var area: CGFloat {
    guard !isNull, !isEmpty else { return 0 }
    return width * height
  }
}

struct WindowAccessor: NSViewRepresentable {
  let onResolve: (NSWindow) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      if let window = view.window {
        onResolve(window)
      }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      if let window = nsView.window {
        onResolve(window)
      }
    }
  }
}

struct VisualEffectView: NSViewRepresentable {
  var material: NSVisualEffectView.Material
  var blendingMode: NSVisualEffectView.BlendingMode
  var emphasized: Bool = false

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    nsView.material = material
    nsView.blendingMode = blendingMode
    nsView.isEmphasized = emphasized
    nsView.state = .active
  }
}

enum AppIconFactory {
  static func makeIcon(size: CGFloat = 512) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    let basePath = NSBezierPath(roundedRect: bounds, xRadius: size * 0.22, yRadius: size * 0.22)
    let baseGradient = NSGradient(colors: [
      NSColor(calibratedRed: 0.94, green: 0.55, blue: 0.27, alpha: 1),
      NSColor(calibratedRed: 0.86, green: 0.24, blue: 0.20, alpha: 1),
    ])!
    baseGradient.draw(in: basePath, angle: -90)

    let paperRect = NSRect(x: size * 0.19, y: size * 0.14, width: size * 0.62, height: size * 0.72)
    let paperPath = NSBezierPath(roundedRect: paperRect, xRadius: size * 0.08, yRadius: size * 0.08)
    NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
    paperPath.fill()

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: paperRect.maxX - size * 0.15, y: paperRect.maxY))
    fold.line(to: NSPoint(x: paperRect.maxX, y: paperRect.maxY - size * 0.15))
    fold.line(to: NSPoint(x: paperRect.maxX, y: paperRect.maxY))
    fold.close()
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    fold.fill()

    let lineColor = NSColor(calibratedRed: 0.82, green: 0.32, blue: 0.22, alpha: 1)
    for index in 0..<4 {
      let y = size * (0.66 - CGFloat(index) * 0.11)
      let line = NSBezierPath(roundedRect: NSRect(x: size * 0.29, y: y, width: size * 0.33, height: size * 0.034), xRadius: size * 0.017, yRadius: size * 0.017)
      lineColor.setFill()
      line.fill()
    }

    let spark = NSBezierPath()
    spark.move(to: NSPoint(x: size * 0.69, y: size * 0.42))
    spark.line(to: NSPoint(x: size * 0.74, y: size * 0.52))
    spark.line(to: NSPoint(x: size * 0.84, y: size * 0.57))
    spark.line(to: NSPoint(x: size * 0.74, y: size * 0.62))
    spark.line(to: NSPoint(x: size * 0.69, y: size * 0.72))
    spark.line(to: NSPoint(x: size * 0.64, y: size * 0.62))
    spark.line(to: NSPoint(x: size * 0.54, y: size * 0.57))
    spark.line(to: NSPoint(x: size * 0.64, y: size * 0.52))
    spark.close()
    NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.33, alpha: 1).setFill()
    spark.fill()

    image.unlockFocus()
    image.isTemplate = false
    return image
  }

  static func makeStatusBarIcon() -> NSImage {
    let image = makeIcon(size: 36)
    image.size = NSSize(width: 18, height: 18)
    return image
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var statusItem: NSStatusItem?
  private weak var mainWindow: NSWindow?
  private var configuredWindowIDs: Set<ObjectIdentifier> = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.applicationIconImage = AppIconFactory.makeIcon()
    installStatusItem()
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      showMainWindow()
    }
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func registerMainWindow(_ window: NSWindow) {
    mainWindow = window
    let windowID = ObjectIdentifier(window)
    if !configuredWindowIDs.contains(windowID) {
      configuredWindowIDs.insert(windowID)
      window.delegate = self
      applyAdaptiveInitialSize(to: window)
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if sender == mainWindow {
      hideToMenuBar()
      return false
    }
    return true
  }

  @objc private func openFromStatusItem(_ sender: Any?) {
    showMainWindow()
  }

  @objc private func quickInsertFromStatusItem(_ sender: Any?) {
    QuickInsertController.shared.show()
  }

  @objc private func quitFromStatusItem(_ sender: Any?) {
    NSApp.terminate(nil)
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.image = AppIconFactory.makeStatusBarIcon()
      button.imagePosition = .imageOnly
      button.toolTip = "mysnippets"
    }

    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Open mysnippets", action: #selector(openFromStatusItem(_:)), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Quick Insert", action: #selector(quickInsertFromStatusItem(_:)), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitFromStatusItem(_:)), keyEquivalent: "q"))
    menu.items.forEach { $0.target = self }
    item.menu = menu
    statusItem = item
  }

  private func showMainWindow() {
    NSApp.setActivationPolicy(.regular)
    if let mainWindow {
      mainWindow.makeKeyAndOrderFront(nil)
      mainWindow.orderFrontRegardless()
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  private func hideToMenuBar() {
    NSApp.windows.forEach { $0.orderOut(nil) }
    NSApp.setActivationPolicy(.accessory)
  }

  private func applyAdaptiveInitialSize(to window: NSWindow) {
    let size = WindowLayout.defaultMainWindowSize(for: window.screen)
    let frame = WindowLayout.centeredFrame(for: size, screen: window.screen)
    window.setFrame(frame, display: true)
  }
}

@main
struct mysnippetsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @StateObject private var store = SnippetStore(storageFilePath: SnippetStore.defaultStorageFilePath())
  @StateObject private var settings = UISettings()
  private let initialWindowSize = WindowLayout.defaultMainWindowSize()

  var body: some Scene {
    WindowGroup("mysnippets") {
      ContentView()
        .environmentObject(store)
        .environmentObject(settings)
        .background(
          WindowAccessor { window in
            appDelegate.registerMainWindow(window)
          }
        )
        .onAppear {
          QuickInsertController.shared.configure(store: store, settings: settings)
          GlobalHotKeyManager.shared.configure(shortcut: settings.hotKeyShortcut) {
            QuickInsertController.shared.show()
          }
        }
        .onChange(of: settings.storageFilePath) { path in
          store.updateStorageFilePath(path)
          QuickInsertController.shared.configure(store: store, settings: settings)
        }
        .onChange(of: settings.hotKeyKeyCode) { _ in
          GlobalHotKeyManager.shared.configure(shortcut: settings.hotKeyShortcut) {
            QuickInsertController.shared.show()
          }
        }
        .onChange(of: settings.hotKeyModifiers) { _ in
          GlobalHotKeyManager.shared.configure(shortcut: settings.hotKeyShortcut) {
            QuickInsertController.shared.show()
          }
        }
    }
    .windowResizability(.contentSize)
    .defaultSize(width: initialWindowSize.width, height: initialWindowSize.height)

    Settings {
      SettingsView()
        .environmentObject(store)
        .environmentObject(settings)
    }
  }
}

struct QuickInsertView: View {
  @EnvironmentObject private var store: SnippetStore
  @EnvironmentObject private var settings: UISettings

  let onSubmit: (Snippet) -> Void
  let onCancel: () -> Void

  private struct QuickGroup: Hashable {
    let path: [String]
    let name: String
  }

  private enum QuickItem: Hashable, Identifiable {
    case group(QuickGroup)
    case snippet(Snippet)

    var id: String {
      switch self {
      case .group(let g): return "g:\(g.path.joined(separator: "/"))"
      case .snippet(let s): return "s:\(s.id)"
      }
    }
  }

  @State private var search = ""
  @State private var selectedItemID: String?
  @State private var currentGroupPath: [String] = []
  @State private var focusSearchField = false

  var body: some View {
    ZStack {
      VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(Color.white.opacity(0.18))
        .overlay(
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(Color.white.opacity(0.30), lineWidth: 1)
        )

      VStack(alignment: .leading, spacing: 10) {
        header

        HStack(alignment: .top, spacing: 12) {
          leftPane
          rightPane
        }
        .frame(minHeight: 360)
      }
      .padding(18)
    }
    .frame(
      minWidth: WindowLayout.quickPanelMinimumSize.width,
      idealWidth: WindowLayout.quickPanelDefaultSize.width,
      maxWidth: WindowLayout.quickPanelDefaultSize.width,
      minHeight: WindowLayout.quickPanelMinimumSize.height,
      idealHeight: WindowLayout.quickPanelDefaultSize.height,
      maxHeight: WindowLayout.quickPanelDefaultSize.height
    )
    .clipped()
    .shadow(color: .black.opacity(0.22), radius: 20, y: 12)
    .onAppear {
      selectedItemID = quickItems.first?.id
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        focusSearchField = true
      }
    }
    .onExitCommand {
      handleEscape()
    }
  }

  private var header: some View {
    HStack {
      Text("快速搜索并填充")
        .font(.headline)
        .lineLimit(1)
      Spacer()
      Text("快捷键: \(settings.hotKeyShortcut.displayString)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  private var leftPane: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !currentGroupPath.isEmpty {
        HStack(spacing: 8) {
          Text("当前位置: \(currentGroupPath.joined(separator: " / "))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer()
          Button("返回上一级") {
            navigateUpOneLevel()
          }
          .buttonStyle(.borderless)
        }
      }

      QuickSearchField(
        placeholder: "搜索名称、触发词、正文",
        text: $search,
        shouldFocus: $focusSearchField,
        onMoveUp: { moveSelection(step: -1) },
        onMoveDown: { moveSelection(step: 1) },
        onSubmit: { handleSubmit() },
        onEscape: { handleEscape() }
      )

      ScrollViewReader { proxy in
        List(quickItems, selection: $selectedItemID) { item in
          switch item {
          case .group(let group):
            HStack(spacing: 8) {
              Image(systemName: "folder")
                .foregroundStyle(.secondary)
              Text(group.name)
                .font(.system(size: settings.fontSize, weight: .medium))
              Spacer(minLength: 4)
              Text("组")
                .font(.system(size: max(10, settings.fontSize - 2)))
                .foregroundStyle(.secondary)
            }
            .tag(item.id)
            .id(item.id)
          case .snippet(let snippet):
            HStack(spacing: 8) {
              Image(systemName: snippet.isFavorite ? "star.fill" : "text.alignleft")
                .foregroundStyle(snippet.isFavorite ? .yellow : .secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name)
                  .font(.system(size: settings.fontSize))
                if !snippet.description.isEmpty {
                  Text(snippet.description)
                    .font(.system(size: max(10, settings.fontSize - 2)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }
              Spacer(minLength: 4)
              if !snippet.trigger.isEmpty {
                Text(snippet.trigger)
                  .font(.system(size: max(10, settings.fontSize - 1), weight: .medium, design: .monospaced))
                  .foregroundStyle(.secondary)
              }
            }
            .tag(item.id)
            .id(item.id)
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(panelSectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: quickItems.map(\.id)) { ids in
          if let current = selectedItemID, ids.contains(current) { return }
          selectedItemID = ids.first
        }
        .onChange(of: selectedItemID) { id in
          guard let id else { return }
          withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(id, anchor: .center)
          }
        }
      }
    }
    .frame(maxWidth: 332, maxHeight: .infinity, alignment: .topLeading)
  }

  private var rightPane: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("预览")
        .font(.headline)

      if let item = selectedItem {
        switch item {
        case .group(let group):
          Text(group.name)
            .font(.title3.weight(.semibold))
          Text(group.path.joined(separator: " / "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

          let directChildren = directChildGroupCount(of: group.path)
          let directSnippets = snippetsInExactGroup(group.path).count
          let allSnippets = activeSnippets.filter { isPrefixPath(group.path, of: $0.groupPath) }.count
          VStack(alignment: .leading, spacing: 4) {
            Text("下级分组: \(directChildren)")
            Text("本组 snippet: \(directSnippets)")
            Text("包含子组共 snippet: \(allSnippets)")
          }
          .font(.system(size: settings.fontSize))

          Spacer()
          Text("按 Enter 进入该组下一级")
            .font(.caption)
            .foregroundStyle(.secondary)
        case .snippet(let snippet):
          Text(snippet.name)
            .font(.title3.weight(.semibold))
          if !snippet.description.isEmpty {
            Text(snippet.description)
              .font(.system(size: settings.fontSize))
              .foregroundStyle(.secondary)
          }
          Text(snippet.groupPath.joined(separator: " / "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          if !snippet.trigger.isEmpty {
            Text("触发词: \(snippet.trigger)")
              .font(.system(size: settings.fontSize, design: .monospaced))
              .foregroundStyle(.secondary)
          }

          ScrollView {
            renderPreviewText(snippet.body)
              .font(.system(size: settings.fontSize, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .padding(10)
          }
          .background(panelSectionBackground)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
      } else {
        Text("无可预览内容")
          .foregroundStyle(.secondary)
      }
    }
    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var activeSnippets: [Snippet] {
    store.snippets.filter { !store.isAnyAncestorDisabled($0.groupPath) }
  }

  private var visibleChildGroups: [QuickGroup] {
    let prefixCount = currentGroupPath.count
    var set: [String: QuickGroup] = [:]

    for path in store.groups where !store.isAnyAncestorDisabled(path) {
      guard path.count > prefixCount else { continue }
      guard Array(path.prefix(prefixCount)) == currentGroupPath else { continue }
      let childPath = Array(path.prefix(prefixCount + 1))
      let key = childPath.joined(separator: "/")
      if set[key] == nil, let name = childPath.last {
        set[key] = QuickGroup(path: childPath, name: name)
      }
    }

    return set.values.sorted { lhs, rhs in
      store.compareGroups(lhs.path, rhs.path)
    }
  }

  private var filteredSnippets: [Snippet] {
    let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return activeSnippets.filter { s in
      if !currentGroupPath.isEmpty, Array(s.groupPath.prefix(currentGroupPath.count)) != currentGroupPath {
        return false
      }
      if q.isEmpty { return s.groupPath == currentGroupPath }
      let text = [
        s.name,
        s.description,
        s.trigger,
        s.groupPath.joined(separator: "/"),
        s.body,
        stripComments(s.body),
      ].joined(separator: "\n").lowercased()
      return text.contains(q)
    }
    .sorted(by: store.compareSnippets)
  }

  private var filteredGroups: [QuickGroup] {
    let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if q.isEmpty { return visibleChildGroups }

    return visibleChildGroups.filter { group in
      let full = group.path.joined(separator: "/").lowercased()
      return group.name.lowercased().contains(q) || full.contains(q)
    }
  }

  private var quickItems: [QuickItem] {
    filteredGroups.map { .group($0) } + filteredSnippets.map { .snippet($0) }
  }

  private var panelSectionBackground: some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
      .fill(Color.white.opacity(0.16))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(Color.white.opacity(0.20), lineWidth: 1)
      )
  }

  private var selectedItem: QuickItem? {
    guard let selectedItemID else { return quickItems.first }
    return quickItems.first(where: { $0.id == selectedItemID })
  }

  private func handleSubmit() {
    guard let id = selectedItemID,
          let selected = quickItems.first(where: { $0.id == id }) else { return }

    switch selected {
    case .group(let group):
      currentGroupPath = group.path
      search = ""
      selectedItemID = nil
      DispatchQueue.main.async {
        selectedItemID = quickItems.first?.id
      }
    case .snippet(let snippet):
      onSubmit(snippet)
    }
  }

  private func navigateUpOneLevel() {
    if !currentGroupPath.isEmpty {
      currentGroupPath = Array(currentGroupPath.dropLast())
      search = ""
      selectedItemID = nil
      DispatchQueue.main.async {
        selectedItemID = quickItems.first?.id
      }
    }
  }

  private func handleEscape() {
    if !currentGroupPath.isEmpty {
      navigateUpOneLevel()
      return
    }
    onCancel()
  }

  private func snippetsInExactGroup(_ path: [String]) -> [Snippet] {
    activeSnippets.filter { $0.groupPath == path }
  }

  private func directChildGroupCount(of path: [String]) -> Int {
    let targetDepth = path.count + 1
    let childPaths = store.groups.filter { group in
      group.count == targetDepth && Array(group.prefix(path.count)) == path
    }
    return childPaths.count
  }

  private func isPrefixPath(_ prefix: [String], of full: [String]) -> Bool {
    if prefix.count > full.count { return false }
    for (idx, seg) in prefix.enumerated() where full[idx] != seg {
      return false
    }
    return true
  }

  private func moveSelection(step: Int) {
    guard !quickItems.isEmpty else {
      selectedItemID = nil
      return
    }
    guard let current = selectedItemID,
          let currentIdx = quickItems.firstIndex(where: { $0.id == current }) else {
      selectedItemID = quickItems.first?.id
      return
    }

    let next = max(0, min(quickItems.count - 1, currentIdx + step))
    selectedItemID = quickItems[next].id
  }
}

struct QuickSearchField: NSViewRepresentable {
  let placeholder: String
  @Binding var text: String
  @Binding var shouldFocus: Bool
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void
  let onSubmit: () -> Void
  let onEscape: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.isBordered = true
    field.bezelStyle = .roundedBezel
    field.focusRingType = .default
    field.usesSingleLineMode = true
    field.lineBreakMode = .byTruncatingTail
    field.placeholderString = placeholder
    field.stringValue = text
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ nsView: NSTextField, context: Context) {
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
    nsView.placeholderString = placeholder

    if shouldFocus, let window = nsView.window, window.firstResponder !== nsView.currentEditor() {
      window.makeFirstResponder(nsView)
      DispatchQueue.main.async {
        shouldFocus = false
      }
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: QuickSearchField

    init(_ parent: QuickSearchField) {
      self.parent = parent
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      switch commandSelector {
      case #selector(NSResponder.moveUp(_:)):
        parent.onMoveUp()
        return true
      case #selector(NSResponder.moveDown(_:)):
        parent.onMoveDown()
        return true
      case #selector(NSResponder.insertNewline(_:)):
        parent.onSubmit()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        parent.onEscape()
        return true
      default:
        return false
      }
    }
  }
}

private enum TrashListItem: Identifiable, Hashable {
  case snippet(TrashSnippetEntry)
  case group(TrashGroupEntry)

  var id: String {
    switch self {
    case .snippet(let entry): return "ts:\(entry.id)"
    case .group(let entry): return "tg:\(entry.id)"
    }
  }
}

private struct SnippetRowDropDelegate: DropDelegate {
  let targetSnippet: Snippet
  let visibleSnippets: [Snippet]
  let groupPath: [String]
  let isEnabled: Bool
  @Binding var draggedSnippetID: String?
  @Binding var dropTargetSnippetID: String?
  let store: SnippetStore

  func performDrop(info: DropInfo) -> Bool {
    draggedSnippetID = nil
    dropTargetSnippetID = nil
    return true
  }

  func dropEntered(info: DropInfo) {
    guard isEnabled else { return }
    dropTargetSnippetID = targetSnippet.id
    guard let draggedSnippetID, draggedSnippetID != targetSnippet.id else { return }
    guard
      let fromIndex = visibleSnippets.firstIndex(where: { $0.id == draggedSnippetID }),
      let toIndex = visibleSnippets.firstIndex(where: { $0.id == targetSnippet.id })
    else { return }

    let destination = fromIndex < toIndex ? toIndex + 1 : toIndex
    guard destination != fromIndex, destination != fromIndex + 1 else { return }
    withAnimation(.easeInOut(duration: 0.18)) {
      store.moveSnippets(in: groupPath, from: IndexSet(integer: fromIndex), to: destination)
    }
  }

  func validateDrop(info: DropInfo) -> Bool {
    isEnabled
  }

  func dropExited(info: DropInfo) {
    if dropTargetSnippetID == targetSnippet.id {
      dropTargetSnippetID = nil
    }
  }
}

private struct GroupRowDropDelegate: DropDelegate {
  let targetPath: [String]
  let siblingGroups: [[String]]
  @Binding var draggedGroupPathKey: String?
  @Binding var dropTargetGroupPathKey: String?
  let store: SnippetStore

  func performDrop(info: DropInfo) -> Bool {
    draggedGroupPathKey = nil
    dropTargetGroupPathKey = nil
    return true
  }

  func dropEntered(info: DropInfo) {
    let targetKey = targetPath.joined(separator: "/")
    dropTargetGroupPathKey = targetKey
    guard let draggedGroupPathKey, draggedGroupPathKey != targetKey else { return }

    let parentPath = Array(targetPath.dropLast())
    let draggedPath = draggedGroupPathKey.split(separator: "/").map(String.init)
    guard Array(draggedPath.dropLast()) == parentPath else { return }
    guard
      let fromIndex = siblingGroups.firstIndex(of: draggedPath),
      let toIndex = siblingGroups.firstIndex(of: targetPath)
    else { return }

    let destination = fromIndex < toIndex ? toIndex + 1 : toIndex
    guard destination != fromIndex, destination != fromIndex + 1 else { return }
    withAnimation(.easeInOut(duration: 0.18)) {
      store.moveGroups(in: parentPath, from: IndexSet(integer: fromIndex), to: destination)
    }
  }

  func validateDrop(info: DropInfo) -> Bool {
    draggedGroupPathKey != nil
  }

  func dropExited(info: DropInfo) {
    if dropTargetGroupPathKey == targetPath.joined(separator: "/") {
      dropTargetGroupPathKey = nil
    }
  }
}

struct ContentView: View {
  @EnvironmentObject private var store: SnippetStore
  @EnvironmentObject private var settings: UISettings

  @State private var search = ""
  @State private var focusMainSearchField = false
  @State private var selectedSidebarSelection: SidebarSelection = .all
  @State private var selectedItemID: String?

  @State private var editorTarget: Snippet? = nil
  @State private var newGroupTarget: GroupCreateTarget? = nil
  @State private var renameGroupTarget: GroupRenameTarget? = nil
  @State private var draggedSnippetID: String? = nil
  @State private var draggedGroupPathKey: String? = nil
  @State private var dropTargetSnippetID: String? = nil
  @State private var dropTargetGroupPathKey: String? = nil

  var body: some View {
    NavigationSplitView {
      sidebarPane
    } content: {
      contentPane
    } detail: {
      detailPane
        .padding(12)
    }
    .sheet(item: $editorTarget) { target in
      SnippetEditorSheet(snippet: target) { updated in
        store.upsert(updated)
        selectedItemID = updated.id
      }
      .environmentObject(settings)
    }
    .sheet(item: $newGroupTarget) { target in
      GroupCreateSheet(parentPath: target.parentPath) { name in
        let groupPath = target.parentPath + [name]
        store.createGroup(groupPath)
        selectedSidebarSelection = .group(groupPath)
      }
    }
    .sheet(item: $renameGroupTarget) { target in
      GroupRenameSheet(path: target.path) { newName in
        store.renameGroup(from: target.path, to: newName)
        selectedSidebarSelection = .group(Array(target.path.dropLast()) + [newName])
      }
    }
    .onAppear {
      focusMainSearchField = true
      selectFirstItemIfNeeded()
    }
    .onChange(of: selectedSidebarSelection) { _ in
      search = ""
      selectFirstItem(force: true)
    }
    .onChange(of: normalItemIDs) { _ in
      if selectedSidebarSelection != .trash {
        selectFirstItemIfNeeded()
      }
    }
    .onChange(of: trashItemIDs) { _ in
      if selectedSidebarSelection == .trash {
        selectFirstItemIfNeeded()
      }
    }
  }

  private var sidebarPane: some View {
    VStack(spacing: 8) {
      HStack {
        Text("分组")
          .font(.headline)
        Spacer()
        if selectedSidebarSelection != .trash {
          Button("新建分组") { newGroupTarget = GroupCreateTarget(parentPath: selectedGroupPath) }
            .buttonStyle(.borderless)
        }
        Button("刷新") { store.reload() }
          .buttonStyle(.borderless)
      }
      .padding(.horizontal, 10)
      .padding(.top, 8)

      List(selection: $selectedSidebarSelection) {
        HStack(spacing: 6) {
          Text("全部")
            .font(.system(size: settings.fontSize))
            .lineLimit(1)
          Spacer(minLength: 4)
          Text("\(globalVisibleSnippetCount)")
            .font(.system(size: max(10, settings.fontSize - 1), design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .tag(SidebarSelection.all)

        OutlineGroup(groupTree, children: \.children) { node in
          let isDisabled = store.isAnyAncestorDisabled(node.path)
          let siblings = siblingGroupPaths(for: node.path)
          HStack(spacing: 6) {
            Image(systemName: "folder")
              .foregroundStyle(isDisabled ? .tertiary : .secondary)
            Text(node.name)
              .font(.system(size: settings.fontSize))
              .lineLimit(1)
              .foregroundStyle(isDisabled ? .secondary : .primary)
            Spacer(minLength: 4)
            Text("\(node.directCount)/\(node.totalCount)")
              .font(.system(size: max(10, settings.fontSize - 1), design: .monospaced))
              .foregroundStyle(isDisabled ? .tertiary : .secondary)
            Image(systemName: "line.3.horizontal")
              .font(.system(size: max(10, settings.fontSize - 1), weight: .semibold))
              .foregroundStyle(.tertiary)
              .help("拖拽排序")
              .onDrag {
                draggedGroupPathKey = node.path.joined(separator: "/")
                selectedSidebarSelection = .group(node.path)
                return NSItemProvider(object: draggedGroupPathKey! as NSString)
              }
          }
          .opacity(isDisabled ? 0.55 : 1.0)
          .tag(SidebarSelection.group(node.path))
          .onDrop(
            of: [UTType.plainText],
            delegate: GroupRowDropDelegate(
              targetPath: node.path,
              siblingGroups: siblings,
              draggedGroupPathKey: $draggedGroupPathKey,
              dropTargetGroupPathKey: $dropTargetGroupPathKey,
              store: store
            )
          )
          .contextMenu {
            Button("新建子分组") {
              newGroupTarget = GroupCreateTarget(parentPath: node.path)
            }
            Button("重命名分组") {
              renameGroupTarget = GroupRenameTarget(path: node.path)
            }
            if store.isGroupDisabled(node.path) {
              Button("启用分组") {
                store.enableGroup(node.path)
              }
            } else {
              Button("禁用分组") {
                store.disableGroup(node.path)
              }
            }
            Button("删除分组", role: .destructive) {
              let snippetCount = store.snippets.filter { isPrefixPath(node.path, of: $0.groupPath) }.count
              let subgroupCount = store.groups.filter { isPrefixPath(node.path, of: $0) }.count - 1
              if confirmDeleteGroup(path: node.path, snippetCount: snippetCount, subgroupCount: max(0, subgroupCount)) {
                store.deleteGroup(node.path)
                if case let .group(current) = selectedSidebarSelection, isPrefixPath(node.path, of: current) {
                  let parent = Array(node.path.dropLast())
                  selectedSidebarSelection = parent.isEmpty ? .all : .group(parent)
                }
              }
            }
            Button("在该分组新建片段") {
              editorTarget = Snippet(id: UUID().uuidString, name: "", description: "", trigger: "", groupPath: node.path, body: "", isFavorite: false)
            }
          }
        }

        HStack(spacing: 6) {
          Image(systemName: "trash")
            .foregroundStyle(.secondary)
          Text("回收站")
            .font(.system(size: settings.fontSize))
            .lineLimit(1)
          Spacer(minLength: 4)
          Text("\(trashItemCount)")
            .font(.system(size: max(10, settings.fontSize - 1), design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .tag(SidebarSelection.trash)
      }
      .environment(\.defaultMinListRowHeight, settings.rowHeight)
    }
    .navigationSplitViewColumnWidth(min: 245, ideal: 270, max: 320)
  }

  private var contentPane: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        QuickSearchField(
          placeholder: selectedSidebarSelection == .trash ? "搜索回收站内容" : "搜索名称、触发词、正文",
          text: $search,
          shouldFocus: $focusMainSearchField,
          onMoveUp: { moveSelection(step: -1) },
          onMoveDown: { moveSelection(step: 1) },
          onSubmit: {},
          onEscape: {}
        )
        if selectedSidebarSelection == .trash {
          Button("清空回收站", role: .destructive) {
            if confirmEmptyTrash(itemCount: trashItemCount) {
              store.emptyTrash()
            }
          }
          .disabled(trashItemCount == 0)
        } else {
          Button("新建") {
            editorTarget = Snippet(id: UUID().uuidString, name: "", description: "", trigger: "", groupPath: selectedGroupPath, body: "", isFavorite: false)
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.top, 8)

      if selectedSidebarSelection == .trash {
        List(filteredTrashItems, selection: $selectedItemID) { item in
          trashRow(for: item)
            .tag(item.id)
        }
      } else {
        List(filteredSnippets, selection: $selectedItemID) { snippet in
          snippetRow(for: snippet)
            .tag(snippet.id)
        }
      }
    }
    .environment(\.defaultMinListRowHeight, settings.rowHeight)
    .onMoveCommand { direction in
      switch direction {
      case .down:
        moveSelection(step: 1)
      case .up:
        moveSelection(step: -1)
      default:
        break
      }
    }
    .navigationSplitViewColumnWidth(min: 330, ideal: 382, max: 476)
  }

  @ViewBuilder
  private func snippetRow(for snippet: Snippet) -> some View {
    let isDisabled = store.isAnyAncestorDisabled(snippet.groupPath)
    let showPathInList = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    HStack(spacing: 8) {
      Image(systemName: snippet.isFavorite ? "star.fill" : "text.alignleft")
        .foregroundStyle(snippet.isFavorite ? Color.yellow : Color.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(snippet.name)
          .font(.system(size: settings.fontSize))
          .lineLimit(1)
          .foregroundStyle(isDisabled ? .secondary : .primary)
        if showPathInList {
          Text(groupLabel(snippet.groupPath))
            .font(.system(size: max(10, settings.fontSize - 2)))
            .foregroundStyle(isDisabled ? .tertiary : .secondary)
            .lineLimit(1)
        } else if !snippet.description.isEmpty {
          Text(snippet.description)
            .font(.system(size: max(10, settings.fontSize - 2)))
            .foregroundStyle(isDisabled ? .tertiary : .secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if !snippet.trigger.isEmpty {
        Text(snippet.trigger)
          .font(.system(size: max(10, settings.fontSize - 1), weight: .medium, design: .monospaced))
          .foregroundStyle(isDisabled ? .tertiary : .secondary)
      }
      if canReorderSnippets {
        Image(systemName: "line.3.horizontal")
          .font(.system(size: max(10, settings.fontSize - 1), weight: .semibold))
          .foregroundStyle(.tertiary)
          .help("拖拽排序")
          .onDrag {
            draggedSnippetID = snippet.id
            selectedItemID = snippet.id
            return NSItemProvider(object: snippet.id as NSString)
          }
      }
    }
    .opacity(isDisabled ? 0.62 : 1.0)
    .onDrop(
      of: [UTType.plainText],
      delegate: SnippetRowDropDelegate(
        targetSnippet: snippet,
        visibleSnippets: filteredSnippets,
        groupPath: selectedGroupPath,
        isEnabled: canReorderSnippets,
        draggedSnippetID: $draggedSnippetID,
        dropTargetSnippetID: $dropTargetSnippetID,
        store: store
      )
    )
    .contextMenu {
      Button("复制") { copyClean(snippet.body) }
      Button(snippet.isFavorite ? "取消星标" : "设为星标") {
        store.toggleFavorite(for: snippet)
      }
      Button("编辑") {
        editorTarget = snippet
      }
      Button("删除", role: .destructive) {
        store.remove(snippet)
      }
    }
  }

  @ViewBuilder
  private func trashRow(for item: TrashListItem) -> some View {
    switch item {
    case .snippet(let entry):
      HStack(spacing: 8) {
        Image(systemName: "text.alignleft")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.snippet.name)
            .font(.system(size: settings.fontSize))
            .lineLimit(1)
          Text("原位置: \(groupLabel(entry.originalGroupPath))")
            .font(.system(size: max(10, settings.fontSize - 2)))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        Text(trashDateLabel(entry.deletedAt))
          .font(.system(size: max(10, settings.fontSize - 2)))
          .foregroundStyle(.secondary)
      }
      .contextMenu {
        Button("恢复") {
          store.restoreTrashSnippet(entry)
        }
        Button("立即删除", role: .destructive) {
          store.permanentlyDeleteTrashSnippet(entry)
        }
      }
    case .group(let entry):
      HStack(spacing: 8) {
        Image(systemName: "folder")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.originalPath.last ?? "分组")
            .font(.system(size: settings.fontSize))
            .lineLimit(1)
          Text("原位置: \(groupLabel(entry.originalPath))")
            .font(.system(size: max(10, settings.fontSize - 2)))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        Text(trashDateLabel(entry.deletedAt))
          .font(.system(size: max(10, settings.fontSize - 2)))
          .foregroundStyle(.secondary)
      }
      .contextMenu {
        Button("恢复") {
          store.restoreTrashGroup(entry)
        }
        Button("立即删除", role: .destructive) {
          store.permanentlyDeleteTrashGroup(entry)
        }
      }
    }
  }

  @ViewBuilder
  private var detailPane: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("预览")
          .font(.headline)
        Spacer()
        if let snippet = selectedSnippet {
          Button(snippet.isFavorite ? "取消星标" : "星标") {
            store.toggleFavorite(for: snippet)
          }
          Button("复制") {
            copyClean(snippet.body)
          }
          Button("编辑") {
            editorTarget = snippet
          }
        } else if let trashItem = selectedTrashItem {
          Button("恢复") {
            restoreTrashItem(trashItem)
          }
          Button("立即删除", role: .destructive) {
            permanentlyDeleteTrashItem(trashItem)
          }
        }
      }

      if selectedSidebarSelection == .trash {
        trashDetailView
      } else if let snippet = selectedSnippet {
        snippetDetailView(snippet)
      } else if case let .group(path) = selectedSidebarSelection {
        groupDetailView(path)
      } else {
        Text("未选择 snippet")
          .foregroundStyle(.secondary)
      }

      Text("存储文件: \(store.storageFileURL.path)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var trashDetailView: some View {
    if let item = selectedTrashItem {
      switch item {
      case .snippet(let entry):
        HStack(spacing: 8) {
          Image(systemName: "text.alignleft")
            .foregroundStyle(.secondary)
          Text(entry.snippet.name)
            .font(.title3.weight(.semibold))
        }
        if !entry.snippet.description.isEmpty {
          Text(entry.snippet.description)
            .font(.system(size: settings.fontSize))
            .foregroundStyle(.secondary)
        }
        Text("原位置: \(groupLabel(entry.originalGroupPath))")
          .font(.system(size: settings.fontSize))
          .foregroundStyle(.secondary)
        Text("删除时间: \(trashDateLabel(entry.deletedAt))")
          .font(.caption)
          .foregroundStyle(.secondary)

        ScrollView {
          renderPreviewText(entry.snippet.body)
            .font(.system(size: settings.fontSize, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
      case .group(let entry):
        Text(entry.originalPath.last ?? "分组")
          .font(.title3.weight(.semibold))
        Text("原位置: \(groupLabel(entry.originalPath))")
          .font(.system(size: settings.fontSize))
          .foregroundStyle(.secondary)
        Text("删除时间: \(trashDateLabel(entry.deletedAt))")
          .font(.caption)
          .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 6) {
          Text("分组数量: \(entry.groups.count)")
          Text("包含 snippet: \(entry.snippets.count)")
        }
        .font(.system(size: settings.fontSize))

        if let firstSnippet = entry.snippets.sorted(by: store.compareSnippets).first {
          Divider()
          Text("示例预览")
            .font(.headline)
          ScrollView {
            renderPreviewText(firstSnippet.body)
              .font(.system(size: settings.fontSize, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(10)
          }
          .background(Color(NSColor.textBackgroundColor))
          .cornerRadius(8)
        } else {
          Spacer()
          Text("该回收站分组中暂无 snippet")
            .foregroundStyle(.secondary)
          Spacer()
        }
      }
    } else {
      Spacer()
      Text("回收站为空")
        .foregroundStyle(.secondary)
      Spacer()
    }
  }

  @ViewBuilder
  private func snippetDetailView(_ snippet: Snippet) -> some View {
    let isDisabled = store.isAnyAncestorDisabled(snippet.groupPath)
    HStack(spacing: 8) {
      Image(systemName: snippet.isFavorite ? "star.fill" : "text.alignleft")
        .foregroundStyle(snippet.isFavorite ? .yellow : .secondary)
      Text(snippet.name)
        .font(.title3.weight(.semibold))
    }
    if !snippet.description.isEmpty {
      Text(snippet.description)
        .font(.system(size: settings.fontSize))
        .foregroundStyle(.secondary)
    }
    Text(groupLabel(snippet.groupPath))
      .font(.system(size: settings.fontSize))
      .foregroundStyle(.secondary)
    if isDisabled {
      Text("该 snippet 所在分组已禁用，仍可在管理页预览和编辑，但不会出现在悬浮窗搜索中。")
        .font(.caption)
        .foregroundStyle(.orange)
    }

    ScrollView {
      renderPreviewText(snippet.body)
        .font(.system(size: settings.fontSize, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
    .background(Color(NSColor.textBackgroundColor))
    .cornerRadius(8)
  }

  @ViewBuilder
  private func groupDetailView(_ path: [String]) -> some View {
    let isDisabled = store.isAnyAncestorDisabled(path)
    let groupSnippets = store.snippets.filter { isPrefixPath(path, of: $0.groupPath) }
    let directSnippets = store.snippets.filter { $0.groupPath == path }
    let subgroupCount = store.groups.filter { isPrefixPath(path, of: $0) }.count - 1

    HStack(spacing: 8) {
      Image(systemName: "folder")
        .foregroundStyle(.secondary)
      Text(path.last ?? "分组")
        .font(.title3.weight(.semibold))
    }
    Text(groupLabel(path))
      .font(.system(size: settings.fontSize))
      .foregroundStyle(.secondary)
    if isDisabled {
      Text("该分组已禁用，仍可在管理页预览和编辑，但不会出现在悬浮窗搜索中。")
        .font(.caption)
        .foregroundStyle(.orange)
    }

    VStack(alignment: .leading, spacing: 6) {
      Text("本组 snippet: \(directSnippets.count)")
      Text("包含子组共 snippet: \(groupSnippets.count)")
      Text("子分组数量: \(max(0, subgroupCount))")
    }
    .font(.system(size: settings.fontSize))

    if let firstSnippet = groupSnippets.first {
      Divider()
      Text("示例预览")
        .font(.headline)
      ScrollView {
        renderPreviewText(firstSnippet.body)
          .font(.system(size: settings.fontSize, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .background(Color(NSColor.textBackgroundColor))
      .cornerRadius(8)
    } else {
      Spacer()
      Text("该分组下暂无 snippet")
        .foregroundStyle(.secondary)
      Spacer()
    }
  }

  private var selectedSnippet: Snippet? {
    guard selectedSidebarSelection != .trash, let selectedItemID else { return nil }
    return filteredSnippets.first(where: { $0.id == selectedItemID })
  }

  private var selectedTrashItem: TrashListItem? {
    guard selectedSidebarSelection == .trash, let selectedItemID else { return nil }
    return filteredTrashItems.first(where: { $0.id == selectedItemID })
  }

  private var selectedGroupPath: [String] {
    if case let .group(path) = selectedSidebarSelection { return path }
    return []
  }

  private var globalVisibleSnippetCount: Int {
    store.snippets.filter { !store.isAnyAncestorDisabled($0.groupPath) }.count
  }

  private var canReorderSnippets: Bool {
    selectedSidebarSelection != .trash
      && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !selectedGroupPath.isEmpty
  }

  private var trashItemCount: Int {
    store.trashSnippets.count + store.trashGroups.count
  }

  private var filteredSnippets: [Snippet] {
    let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return store.snippets.filter { s in
      if !selectedGroupPath.isEmpty && s.groupPath != selectedGroupPath { return false }
      if q.isEmpty { return true }
      let text = [
        s.name,
        s.description,
        s.trigger,
        s.groupPath.joined(separator: "/"),
        s.body,
        stripComments(s.body),
      ].joined(separator: "\n").lowercased()
      return text.contains(q)
    }
    .sorted(by: store.compareSnippets)
  }

  private var filteredTrashItems: [TrashListItem] {
    let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let snippets = store.trashSnippets.filter { entry in
      if q.isEmpty { return true }
      let text = [
        entry.snippet.name,
        entry.snippet.description,
        entry.snippet.trigger,
        entry.originalGroupPath.joined(separator: "/"),
        entry.snippet.body,
        stripComments(entry.snippet.body),
      ].joined(separator: "\n").lowercased()
      return text.contains(q)
    }
    .sorted(by: store.compareTrashSnippets)
    .map(TrashListItem.snippet)

    let groups = store.trashGroups.filter { entry in
      if q.isEmpty { return true }
      let text = [
        entry.originalPath.joined(separator: "/"),
        entry.snippets.map(\.name).joined(separator: "\n"),
        entry.snippets.map(\.description).joined(separator: "\n"),
      ].joined(separator: "\n").lowercased()
      return text.contains(q)
    }
    .sorted(by: store.compareTrashGroups)
    .map(TrashListItem.group)

    return (snippets + groups).sorted(by: compareTrashItems)
  }

  private var normalItemIDs: [String] {
    filteredSnippets.map(\.id)
  }

  private var trashItemIDs: [String] {
    filteredTrashItems.map(\.id)
  }

  private var groupTree: [GroupNode] {
    buildGroupTree(groups: store.groups, snippets: store.snippets)
  }

  private func buildGroupTree(groups: [[String]], snippets: [Snippet]) -> [GroupNode] {
    var childrenByPath: [String: Set<String>] = [:]
    var directByPath: [String: Int] = [:]
    var totalByPath: [String: Int] = [:]

    for groupPath in groups where !groupPath.isEmpty {
      for depth in 0..<groupPath.count {
        let parent = Array(groupPath.prefix(depth))
        let parentKey = parent.joined(separator: "/")
        childrenByPath[parentKey, default: []].insert(groupPath[depth])
      }
    }

    for snippet in snippets where !snippet.groupPath.isEmpty {
      let exactKey = snippet.groupPath.joined(separator: "/")
      directByPath[exactKey, default: 0] += 1
      for depth in 0..<snippet.groupPath.count {
        let current = Array(snippet.groupPath.prefix(depth + 1))
        totalByPath[current.joined(separator: "/"), default: 0] += 1
      }
    }

    func build(path: [String]) -> [GroupNode] {
      let pathKey = path.joined(separator: "/")
      let names = Array(childrenByPath[pathKey] ?? [])
        .sorted { lhs, rhs in
          let lhsPath = path + [lhs]
          let rhsPath = path + [rhs]
          let lhsDisabled = store.isAnyAncestorDisabled(lhsPath)
          let rhsDisabled = store.isAnyAncestorDisabled(rhsPath)
          if lhsDisabled != rhsDisabled {
            return !lhsDisabled && rhsDisabled
          }
          return store.compareGroups(lhsPath, rhsPath)
        }

      return names.map { name in
        let nextPath = path + [name]
        let nextKey = nextPath.joined(separator: "/")
        let nextChildren = build(path: nextPath)
        return GroupNode(
          name: name,
          path: nextPath,
          directCount: directByPath[nextKey, default: 0],
          totalCount: totalByPath[nextKey, default: 0],
          children: nextChildren.isEmpty ? nil : nextChildren
        )
      }
    }

    return build(path: [])
  }

  private func isPrefixPath(_ prefix: [String], of full: [String]) -> Bool {
    if prefix.count > full.count { return false }
    for (idx, seg) in prefix.enumerated() where full[idx] != seg {
      return false
    }
    return true
  }

  private func compareTrashItems(_ lhs: TrashListItem, _ rhs: TrashListItem) -> Bool {
    switch (lhs, rhs) {
    case (.snippet(let left), .snippet(let right)):
      return store.compareTrashSnippets(left, right)
    case (.group(let left), .group(let right)):
      return store.compareTrashGroups(left, right)
    case (.snippet(let left), .group(let right)):
      if left.deletedAt != right.deletedAt {
        return left.deletedAt > right.deletedAt
      }
      return true
    case (.group(let left), .snippet(let right)):
      if left.deletedAt != right.deletedAt {
        return left.deletedAt > right.deletedAt
      }
      return false
    }
  }

  private func siblingGroupPaths(for path: [String]) -> [[String]] {
    let parentPath = Array(path.dropLast())
    return store.groups.filter { candidate in
      candidate.count == parentPath.count + 1 && Array(candidate.dropLast()) == parentPath
    }
  }

  private func currentItemIDs() -> [String] {
    selectedSidebarSelection == .trash ? trashItemIDs : normalItemIDs
  }

  private func selectFirstItemIfNeeded() {
    let ids = currentItemIDs()
    if let current = selectedItemID, ids.contains(current) { return }
    selectedItemID = ids.first
  }

  private func selectFirstItem(force: Bool) {
    if force {
      selectedItemID = currentItemIDs().first
      return
    }
    selectFirstItemIfNeeded()
  }

  private func restoreTrashItem(_ item: TrashListItem) {
    switch item {
    case .snippet(let entry):
      store.restoreTrashSnippet(entry)
    case .group(let entry):
      store.restoreTrashGroup(entry)
    }
  }

  private func permanentlyDeleteTrashItem(_ item: TrashListItem) {
    switch item {
    case .snippet(let entry):
      store.permanentlyDeleteTrashSnippet(entry)
    case .group(let entry):
      store.permanentlyDeleteTrashGroup(entry)
    }
  }

  private func trashDateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  private func moveSelection(step: Int) {
    let ids = currentItemIDs()
    guard !ids.isEmpty else {
      selectedItemID = nil
      return
    }

    guard let currentID = selectedItemID,
          let currentIdx = ids.firstIndex(of: currentID) else {
      selectedItemID = ids.first
      return
    }

    let next = max(0, min(ids.count - 1, currentIdx + step))
    selectedItemID = ids[next]
  }
}

struct SnippetEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var settings: UISettings

  @State var snippet: Snippet
  let onSave: (Snippet) -> Void

  @State private var groupText: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(snippet.name.isEmpty ? "新建 Snippet" : "编辑 Snippet")
        .font(.headline)

      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          VStack(alignment: .leading, spacing: 4) {
            Text("名称")
            TextField("例如：Java 空值判断模板", text: $snippet.name)
            Text("用于列表展示和搜索。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("触发词（可选）")
            TextField("例如：;nullcheck", text: $snippet.trigger)
            Text("用于快速识别该片段，不填也可使用。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("描述（可选）")
            TextField("例如：给 Java 空值判断快速起手", text: $snippet.description)
            Text("用于列表补充说明、搜索和后续导出。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("分组路径")
            TextField("例如：Backend/Java/Utils", text: $groupText)
            Text("使用 / 分隔层级；为空会归到“未分组”。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Text("正文（多行）")
          TextEditor(text: $snippet.body)
            .font(.system(size: settings.fontSize, design: .monospaced))
            .frame(minHeight: 220)
            .border(Color.secondary.opacity(0.2))
          Text("最终复制/粘贴的内容。支持注释块 {{! ... }}，以及 {cursor}、{clipboard}、{date}、{time}、{datetime}、{uuid}。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Divider()
      HStack {
        Spacer()
        Button("取消") { dismiss() }
        Button("保存") {
          snippet.groupPath = splitPath(groupText)
          onSave(snippet)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(width: 700, height: 560)
    .onAppear {
      groupText = snippet.groupPath.joined(separator: "/")
    }
  }

  private func splitPath(_ v: String) -> [String] {
    v.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }
}

struct GroupCreateSheet: View {
  @Environment(\.dismiss) private var dismiss

  let parentPath: [String]
  let onCreate: (String) -> Void
  @State private var name: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("新建分组")
        .font(.headline)

      Text("父分组: \(parentPath.isEmpty ? "根分组" : parentPath.joined(separator: " / "))")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      TextField("分组名称", text: $name)

      HStack {
        Spacer()
        Button("取消") { dismiss() }
        Button("创建") {
          let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty {
            onCreate(trimmed)
          }
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(width: 420, height: 170)
  }
}

struct GroupRenameSheet: View {
  @Environment(\.dismiss) private var dismiss

  let path: [String]
  let onRename: (String) -> Void
  @State private var name: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("重命名分组")
        .font(.headline)

      Text("当前路径: \(path.joined(separator: " / "))")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      TextField("新分组名称", text: $name)

      HStack {
        Spacer()
        Button("取消") { dismiss() }
        Button("保存") {
          let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty {
            onRename(trimmed)
          }
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(width: 460, height: 180)
    .onAppear {
      name = path.last ?? ""
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var store: SnippetStore
  @EnvironmentObject private var settings: UISettings
  @State private var storagePathDraft: String = ""
  @State private var isRecordingHotKey = false
  private let fontSizeOptions: [Double] = [11, 12, 13, 14, 15, 16, 18]
  private let rowHeightOptions: [Double] = [18, 20, 22, 24, 26, 28, 30]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("软件设置")
        .font(.headline)

      HStack(spacing: 12) {
        Text("字号")
          .frame(width: 52, alignment: .leading)
        Picker("字号", selection: $settings.fontSize) {
          ForEach(fontSizeOptions, id: \.self) { size in
            Text("\(Int(size))").tag(size)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 96, alignment: .leading)
      }

      HStack(spacing: 12) {
        Text("行高")
          .frame(width: 52, alignment: .leading)
        Picker("行高", selection: $settings.rowHeight) {
          ForEach(rowHeightOptions, id: \.self) { size in
            Text("\(Int(size))").tag(size)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 96, alignment: .leading)
      }

      HStack(spacing: 12) {
        Text("唤醒键")
          .frame(width: 52, alignment: .leading)
        ShortcutRecorderField(shortcut: Binding(
          get: { settings.hotKeyShortcut },
          set: { settings.hotKeyShortcut = $0 }
        ), isRecording: $isRecordingHotKey)
        .frame(width: 76, height: 28)
        Button(isRecordingHotKey ? "取消录制" : "录制") {
          isRecordingHotKey.toggle()
        }
        .controlSize(.small)
        Button("恢复默认") {
          settings.hotKeyShortcut = .default
          isRecordingHotKey = false
        }
        .buttonStyle(.borderless)
        Button("重置位置") {
          QuickInsertController.shared.resetSavedPanelFrame()
        }
        .buttonStyle(.borderless)
      }
      Text("点击“录制”后，直接按下新的快捷键组合即可保存。至少需要一个修饰键。")
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 6) {
        Text("存储文件")
        TextField("snippets.json 路径", text: $storagePathDraft)
          .textFieldStyle(.roundedBorder)
        Text("填写 snippets.json 的完整路径；修改后会立即切换到该文件。支持 ~。")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack(spacing: 10) {
          Button("应用") {
            applyStoragePath()
          }
          Button("恢复默认") {
            storagePathDraft = SnippetStore.defaultStorageFilePath()
            applyStoragePath()
          }
          .buttonStyle(.borderless)
          Text(store.storageFileURL.path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
    .padding(16)
    .frame(width: 520, height: 320)
    .onAppear {
      storagePathDraft = settings.storageFilePath
    }
  }

  private func applyStoragePath() {
    let trimmed = storagePathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let next = trimmed.isEmpty ? SnippetStore.defaultStorageFilePath() : trimmed
    storagePathDraft = next
    settings.storageFilePath = next
  }
}

struct ShortcutRecorderField: NSViewRepresentable {
  @Binding var shortcut: HotKeyShortcut
  @Binding var isRecording: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> ShortcutRecorderNSView {
    let view = ShortcutRecorderNSView()
    view.onShortcutRecorded = { recorded in
      shortcut = recorded
      isRecording = false
    }
    view.onRecordingCancelled = {
      isRecording = false
    }
    return view
  }

  func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
    nsView.displayString = isRecording ? "按下新的快捷键..." : shortcut.displayString
    nsView.isRecording = isRecording
    if isRecording, let window = nsView.window, window.firstResponder !== nsView {
      window.makeFirstResponder(nsView)
    }
  }

  final class Coordinator: NSObject {
    let parent: ShortcutRecorderField

    init(_ parent: ShortcutRecorderField) {
      self.parent = parent
    }
  }
}

final class ShortcutRecorderNSView: NSView {
  var onShortcutRecorded: ((HotKeyShortcut) -> Void)?
  var onRecordingCancelled: (() -> Void)?
  var isRecording = false {
    didSet { needsDisplay = true }
  }
  var displayString = "" {
    didSet { needsDisplay = true }
  }

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
  }

  override func keyDown(with event: NSEvent) {
    guard isRecording else {
      super.keyDown(with: event)
      return
    }

    if event.keyCode == UInt16(kVK_Escape) {
      onRecordingCancelled?()
      return
    }

    if let shortcut = HotKeyShortcut.from(event: event) {
      onShortcutRecorded?(shortcut)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let background = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
    (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.08) : NSColor.controlBackgroundColor).setFill()
    background.fill()

    let strokeColor = isRecording ? NSColor.controlAccentColor : NSColor.separatorColor
    strokeColor.setStroke()
    background.lineWidth = 1
    background.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraph,
    ]
    let textRect = rect.insetBy(dx: 8, dy: 6)
    NSAttributedString(string: displayString, attributes: attrs).draw(in: textRect)
  }

  override func resignFirstResponder() -> Bool {
    if isRecording {
      onRecordingCancelled?()
    }
    return true
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 76, height: 28)
  }
}

func confirmDeleteGroup(path: [String], snippetCount: Int, subgroupCount: Int) -> Bool {
  let alert = NSAlert()
  alert.messageText = "移到回收站？"
  alert.informativeText = """
  分组：\(path.joined(separator: " / "))
  将把 \(snippetCount) 条 snippet，\(subgroupCount) 个子分组移到回收站。
  之后仍可从回收站恢复到原位置。
  """
  alert.alertStyle = .warning
  alert.addButton(withTitle: "移到回收站")
  alert.addButton(withTitle: "取消")
  return alert.runModal() == .alertFirstButtonReturn
}

func confirmEmptyTrash(itemCount: Int) -> Bool {
  let alert = NSAlert()
  alert.messageText = "清空回收站？"
  alert.informativeText = """
  将永久删除回收站中的 \(itemCount) 项内容。
  此操作不可恢复。
  """
  alert.alertStyle = .warning
  alert.addButton(withTitle: "清空")
  alert.addButton(withTitle: "取消")
  return alert.runModal() == .alertFirstButtonReturn
}

func groupLabel(_ path: [String]) -> String {
  path.isEmpty ? "(No Group)" : path.joined(separator: " / ")
}

struct ExpandedSnippetContent {
  let text: String
  let cursorOffsetFromEnd: Int?
}

func stripComments(_ body: String) -> String {
  body.replacingOccurrences(of: #"\{\{!([\s\S]*?)\}\}"#, with: "", options: .regularExpression)
    .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func expandSnippetBody(_ body: String, now: Date = Date()) -> ExpandedSnippetContent {
  let cleaned = stripComments(body)
  let pasteboard = NSPasteboard.general
  let clipboard = pasteboard.string(forType: .string) ?? ""

  let dateFormatter = DateFormatter()
  dateFormatter.locale = .autoupdatingCurrent
  dateFormatter.timeZone = .autoupdatingCurrent

  let replacements: [String: () -> String] = [
    "clipboard": { clipboard },
    "date": {
      dateFormatter.dateStyle = .medium
      dateFormatter.timeStyle = .none
      return dateFormatter.string(from: now)
    },
    "time": {
      dateFormatter.dateStyle = .none
      dateFormatter.timeStyle = .short
      return dateFormatter.string(from: now)
    },
    "datetime": {
      dateFormatter.dateStyle = .medium
      dateFormatter.timeStyle = .short
      return dateFormatter.string(from: now)
    },
    "uuid": { UUID().uuidString.lowercased() },
  ]

  var output = ""
  var cursorIndex: String.Index?
  var index = cleaned.startIndex

  while index < cleaned.endIndex {
    if cleaned[index] == "{", let closing = cleaned[index...].firstIndex(of: "}") {
      let tokenStart = cleaned.index(after: index)
      let name = String(cleaned[tokenStart..<closing]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if name == "cursor" {
        cursorIndex = output.endIndex
        index = cleaned.index(after: closing)
        continue
      }
      if let replacement = replacements[name] {
        output.append(replacement())
        index = cleaned.index(after: closing)
        continue
      }
    }

    output.append(cleaned[index])
    index = cleaned.index(after: index)
  }

  let offset = cursorIndex.map { output.distance(from: $0, to: output.endIndex) }
  return ExpandedSnippetContent(text: output, cursorOffsetFromEnd: offset)
}

func renderPreviewText(_ body: String) -> Text {
  struct Segment {
    let text: String
    let isComment: Bool
  }

  let ns = body as NSString
  guard let regex = try? NSRegularExpression(pattern: #"\{\{!([\s\S]*?)\}\}"#) else {
    return Text(body)
  }

  let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
  if matches.isEmpty { return Text(body) }

  var segments: [Segment] = []
  var cursor = 0
  for match in matches {
    let full = match.range(at: 0)
    let comment = match.range(at: 1)
    if full.location > cursor {
      segments.append(Segment(text: ns.substring(with: NSRange(location: cursor, length: full.location - cursor)), isComment: false))
    }
    if comment.location != NSNotFound {
      let note = ns.substring(with: comment).trimmingCharacters(in: .whitespacesAndNewlines)
      segments.append(Segment(text: "\n[注释] \(note)\n", isComment: true))
    }
    cursor = full.location + full.length
  }
  if cursor < ns.length {
    segments.append(Segment(text: ns.substring(from: cursor), isComment: false))
  }

  return segments.reduce(Text("")) { partial, segment in
    let piece = Text(segment.text).foregroundColor(segment.isComment ? .orange : .primary)
    return partial + piece
  }
}

func copyClean(_ body: String) {
  let pb = NSPasteboard.general
  pb.clearContents()
  pb.setString(expandSnippetBody(body).text, forType: .string)
}
