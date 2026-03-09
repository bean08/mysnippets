import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import SwiftUI

struct Snippet: Identifiable, Codable, Hashable {
  var id: String
  var name: String
  var description: String
  var trigger: String
  var groupPath: [String]
  var body: String
}

struct GroupNode: Identifiable, Hashable {
  var id: String { path.joined(separator: "/") }
  let name: String
  let path: [String]
  let totalCount: Int
  var children: [GroupNode]?
}

struct GroupCreateTarget: Identifiable {
  let id = UUID()
  let parentPath: [String]
}

struct GroupRenameTarget: Identifiable {
  let id = UUID()
  let path: [String]
}

enum GroupSelection: Hashable {
  case all
  case group([String])
}

final class SnippetStore: ObservableObject {
  @Published var snippets: [Snippet] = []
  @Published var groups: [[String]] = []
  @Published var disabledGroupKeys: Set<String> = []
  @Published private(set) var storageRootURL: URL
  @Published private(set) var storageFileURL: URL

  private var legacyFileURL: URL
  private var legacyGroupsRootURL: URL
  private var legacyDisabledGroupsFileURL: URL
  private var groupIDByPathKey: [String: String] = [:]
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
      groupIDByPathKey = [:]
      lastFingerprint = fingerprint()
      return
    }

    let loaded = decodeDiskStore(disk)
    snippets = loaded.snippets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    groups = loaded.groups.sorted(by: comparePath)
    disabledGroupKeys = loaded.disabledKeys
    groupIDByPathKey = loaded.groupIDByPathKey
    lastFingerprint = fingerprint()
  }

  func upsert(_ snippet: Snippet) {
    var next = snippets
    var normalized = snippet
    normalized.groupPath = normalizeGroupPath(snippet.groupPath)
    if let idx = next.firstIndex(where: { $0.id == normalized.id }) {
      next[idx] = normalized
    } else {
      next.append(normalized)
    }
    persist(snippets: next, groups: groups, disabledKeys: disabledGroupKeys)
    reload()
  }

  func remove(_ snippet: Snippet) {
    let next = snippets.filter { $0.id != snippet.id }
    persist(snippets: next, groups: groups, disabledKeys: disabledGroupKeys)
    reload()
  }

  func createGroup(_ path: [String]) {
    let normalized = normalizeGroupPath(path)
    var nextGroups = Set(groups.map(pathKey))
    for depth in 0..<normalized.count {
      nextGroups.insert(pathKey(Array(normalized.prefix(depth + 1))))
    }
    persist(
      snippets: snippets,
      groups: nextGroups.map(keyToPath),
      disabledKeys: disabledGroupKeys
    )
    reload()
  }

  func disableGroup(_ path: [String]) {
    let key = pathKey(normalizeGroupPath(path))
    var next = disabledGroupKeys
    next.insert(key)
    persist(snippets: snippets, groups: groups, disabledKeys: next)
    disabledGroupKeys = next
  }

  func enableGroup(_ path: [String]) {
    let key = pathKey(normalizeGroupPath(path))
    var next = disabledGroupKeys
    next.remove(key)
    persist(snippets: snippets, groups: groups, disabledKeys: next)
    disabledGroupKeys = next
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

    persist(snippets: nextSnippets, groups: nextGroups, disabledKeys: nextDisabled)
    reload()
  }

  func deleteGroup(_ path: [String]) {
    let normalized = normalizeGroupPath(path)
    let nextSnippets = snippets.filter { !hasPrefix($0.groupPath, prefix: normalized) }
    let nextGroups = groups.filter { !hasPrefix($0, prefix: normalized) }
    let nextDisabled = Set(disabledGroupKeys.filter { !hasPrefix(keyToPath($0), prefix: normalized) })
    groupIDByPathKey = groupIDByPathKey.filter { !hasPrefix(keyToPath($0.key), prefix: normalized) }
    persist(snippets: nextSnippets, groups: nextGroups, disabledKeys: nextDisabled)
    disabledGroupKeys = nextDisabled
    reload()
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
        body: "feat(scope): 简要说明\\n\\n{{! 发布前删除占位信息，复制时会自动删除此注释。}}\\n背景：...\\n影响范围：...\\n回滚方案：..."
      ),
      Snippet(
        id: "work-sync-daily",
        name: "Daily Sync Update",
        description: "日常站会同步模板，包含昨天、今天和阻塞项。",
        trigger: ";dsu",
        groupPath: ["Work", "Sync", "Daily", "Standup"],
        body: "Yesterday:\\n- ...\\n\\nToday:\\n- ...\\n\\nBlockers:\\n- ...\\n{{! 预览提醒：别忘记 KPI。}}"
      )
    ]
    persist(snippets: seed, groups: [], disabledKeys: [])
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
        body: String(raw[bodyRange])
      )
    }
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
    a.joined(separator: "/").localizedStandardCompare(b.joined(separator: "/")) == .orderedAscending
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
      disabledKeys: migratedDisabled
    )
  }

  private func persist(snippets: [Snippet], groups: [[String]], disabledKeys: Set<String>) {
    let normalizedSnippets = snippets.map { snippet -> Snippet in
      var next = snippet
      next.groupPath = normalizeGroupPath(snippet.groupPath)
      return next
    }

    var groupSet = Set(groups.map(pathKey))
    for snippet in normalizedSnippets {
      for depth in 0..<snippet.groupPath.count {
        groupSet.insert(pathKey(Array(snippet.groupPath.prefix(depth + 1))))
      }
    }

    let orderedGroups = groupSet.map(keyToPath).sorted(by: comparePath)
    var nextGroupIDByPathKey: [String: String] = [:]
    for path in orderedGroups {
      let key = pathKey(path)
      nextGroupIDByPathKey[key] = groupIDByPathKey[key] ?? UUID().uuidString
    }

    var nextGroupOrderByParent: [String: Int] = [:]
    var diskGroups: [DiskGroup] = []
    for path in orderedGroups {
      guard let id = nextGroupIDByPathKey[pathKey(path)], let name = path.last else { continue }
      let parent = Array(path.dropLast())
      let parentKey = pathKey(parent)
      let order = nextGroupOrderByParent[parentKey, default: 0]
      nextGroupOrderByParent[parentKey] = order + 1
      diskGroups.append(DiskGroup(
        id: id,
        name: name,
        parentID: parent.isEmpty ? nil : nextGroupIDByPathKey[parentKey],
        hidden: disabledKeys.contains(pathKey(path)),
        order: order
      ))
    }

    let sortedSnippets = normalizedSnippets.sorted { lhs, rhs in
      let g1 = pathKey(lhs.groupPath)
      let g2 = pathKey(rhs.groupPath)
      if g1 != g2 { return g1.localizedStandardCompare(g2) == .orderedAscending }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    var nextSnippetOrderByGroupID: [String: Int] = [:]
    var diskSnippets: [DiskSnippet] = []
    for snippet in sortedSnippets {
      let key = pathKey(snippet.groupPath)
      guard let groupID = nextGroupIDByPathKey[key] else { continue }
      let order = nextSnippetOrderByGroupID[groupID, default: 0]
      nextSnippetOrderByGroupID[groupID] = order + 1
      diskSnippets.append(DiskSnippet(
        id: snippet.id,
        name: snippet.name,
        prefix: snippet.trigger,
        body: snippet.body.components(separatedBy: "\n"),
        description: snippet.description.isEmpty ? nil : snippet.description,
        groupID: groupID,
        order: order
      ))
    }

    let disk = DiskStore(version: "1.0", groups: diskGroups, snippets: diskSnippets)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(disk) else { return }
    try? data.write(to: storageFileURL, options: .atomic)
    groupIDByPathKey = nextGroupIDByPathKey
  }

  private func decodeDiskStore(_ disk: DiskStore) -> (snippets: [Snippet], groups: [[String]], disabledKeys: Set<String>, groupIDByPathKey: [String: String]) {
    let groupByID = Dictionary(uniqueKeysWithValues: disk.groups.map { ($0.id, $0) })
    var pathCache: [String: [String]] = [:]

    func resolvePath(_ id: String, visiting: Set<String> = []) -> [String]? {
      if let cached = pathCache[id] { return cached }
      if visiting.contains(id) { return nil }
      guard let group = groupByID[id] else { return nil }

      let path: [String]
      if let parentID = group.parentID {
        guard let parentPath = resolvePath(parentID, visiting: visiting.union([id])) else { return nil }
        path = normalizeGroupPath(parentPath + [group.name])
      } else {
        path = normalizeGroupPath([group.name])
      }
      pathCache[id] = path
      return path
    }

    var loadedGroups = Set<String>()
    var loadedDisabledKeys = Set<String>()
    var loadedGroupIDByPathKey: [String: String] = [:]
    for group in disk.groups {
      guard let path = resolvePath(group.id) else { continue }
      let key = pathKey(path)
      loadedGroups.insert(key)
      loadedGroupIDByPathKey[key] = group.id
      if group.hidden {
        loadedDisabledKeys.insert(key)
      }
    }

    var loadedSnippets: [Snippet] = []
    for snippet in disk.snippets {
      let path = resolvePath(snippet.groupID) ?? ["未分组"]
      for depth in 0..<path.count {
        loadedGroups.insert(pathKey(Array(path.prefix(depth + 1))))
      }
      loadedSnippets.append(Snippet(
        id: snippet.id,
        name: snippet.name,
        description: snippet.description ?? "",
        trigger: snippet.prefix,
        groupPath: path,
        body: snippet.body.joined(separator: "\n")
      ))
    }

    return (
      snippets: loadedSnippets,
      groups: loadedGroups.map(keyToPath),
      disabledKeys: loadedDisabledKeys,
      groupIDByPathKey: loadedGroupIDByPathKey
    )
  }

  private struct DiskStore: Codable {
    let version: String
    let groups: [DiskGroup]
    let snippets: [DiskSnippet]
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
    let groupID: String
    let order: Int

    enum CodingKeys: String, CodingKey {
      case id
      case name
      case prefix
      case body
      case description
      case groupID = "group_id"
      case order
    }
  }
}

final class UISettings: ObservableObject {
  @AppStorage("fontSize") var fontSize: Double = 13
  @AppStorage("rowHeight") var rowHeight: Double = 22
  @AppStorage("storageFilePath") var storageFilePath: String = SnippetStore.defaultStorageFilePath()
}

final class GlobalHotKeyManager {
  static let shared = GlobalHotKeyManager()

  private static let hotKeySignature: OSType = 0x4D535048 // "MSPH"
  private static let hotKeyID: UInt32 = 1

  var onPressed: (() -> Void)?

  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private var isRegistered = false

  private init() {}

  deinit {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
    if let handlerRef {
      RemoveEventHandler(handlerRef)
    }
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

    let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
    RegisterEventHotKey(
      UInt32(kVK_ANSI_0),
      UInt32(optionKey),
      hotKeyID,
      GetEventDispatcherTarget(),
      0,
      &hotKeyRef
    )

    isRegistered = true
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

    if panel == nil {
      let panel = QuickSearchPanel(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
        styleMask: [.titled, .closable, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      panel.title = "快速搜索 Snippet"
      panel.level = .floating
      panel.center()
      panel.isReleasedWhenClosed = false
      panel.hidesOnDeactivate = false
      panel.collectionBehavior = [.moveToActiveSpace]
      self.panel = panel
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

    panel?.makeKeyAndOrderFront(nil)
    panel?.orderFrontRegardless()
  }

  func hide() {
    panel?.orderOut(nil)
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
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
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
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.applicationIconImage = AppIconFactory.makeIcon()
    NSApp.activate(ignoringOtherApps: true)
  }
}

@main
struct mysnippetsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @StateObject private var store = SnippetStore(storageFilePath: SnippetStore.defaultStorageFilePath())
  @StateObject private var settings = UISettings()

  var body: some Scene {
    WindowGroup("mysnippets") {
      ContentView()
        .environmentObject(store)
        .environmentObject(settings)
        .onAppear {
          QuickInsertController.shared.configure(store: store, settings: settings)
          GlobalHotKeyManager.shared.registerIfNeeded()
          GlobalHotKeyManager.shared.onPressed = {
            QuickInsertController.shared.show()
          }
        }
        .onChange(of: settings.storageFilePath) { path in
          store.updateStorageFilePath(path)
          QuickInsertController.shared.configure(store: store, settings: settings)
        }
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 1450, height: 760)

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
    VStack(alignment: .leading, spacing: 10) {
      header

      HStack(alignment: .top, spacing: 12) {
        leftPane
        rightPane
      }
      .frame(minHeight: 360)

    }
    .padding(14)
    .frame(width: 860, height: 500)
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
      Spacer()
      Text("快捷键: Option + 0")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var leftPane: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !currentGroupPath.isEmpty {
        HStack(spacing: 8) {
          Text("当前位置: \(currentGroupPath.joined(separator: " / "))")
            .font(.caption)
            .foregroundStyle(.secondary)
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
              Image(systemName: "text.alignleft")
                .foregroundStyle(.secondary)
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
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
              .padding(10)
          }
          .background(Color(NSColor.textBackgroundColor))
          .cornerRadius(8)
        }
      } else {
        Text("无可预览内容")
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    return set.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

struct ContentView: View {
  @EnvironmentObject private var store: SnippetStore
  @EnvironmentObject private var settings: UISettings

  @State private var search = ""
  @State private var focusMainSearchField = false
  @State private var selectedGroupSelection: GroupSelection = .all
  @State private var selectedSnippetID: String?

  @State private var editorTarget: Snippet? = nil
  @State private var newGroupTarget: GroupCreateTarget? = nil
  @State private var renameGroupTarget: GroupRenameTarget? = nil

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 8) {
        HStack {
          Text("分组")
            .font(.headline)
          Spacer()
          Button("新建分组") { newGroupTarget = GroupCreateTarget(parentPath: selectedGroupPath) }
            .buttonStyle(.borderless)
          Button("刷新") { store.reload() }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)

        List(selection: $selectedGroupSelection) {
          HStack(spacing: 6) {
            Text("全部")
              .font(.system(size: settings.fontSize))
              .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(globalVisibleSnippetCount)")
              .font(.system(size: max(10, settings.fontSize - 1), design: .monospaced))
              .foregroundStyle(.secondary)
          }
          .tag(GroupSelection.all)

          OutlineGroup(groupTree, children: \.children) { node in
            let isDisabled = store.isAnyAncestorDisabled(node.path)
            HStack(spacing: 6) {
              Text(node.name)
                .font(.system(size: settings.fontSize))
                .lineLimit(1)
                .foregroundStyle(isDisabled ? .secondary : .primary)
              Spacer(minLength: 4)
              Text("\(node.totalCount)")
                .font(.system(size: max(10, settings.fontSize - 1), design: .monospaced))
                .foregroundStyle(isDisabled ? .tertiary : .secondary)
            }
            .opacity(isDisabled ? 0.55 : 1.0)
            .tag(GroupSelection.group(node.path))
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
                  if case let .group(current) = selectedGroupSelection, isPrefixPath(node.path, of: current) {
                    let parent = Array(node.path.dropLast())
                    selectedGroupSelection = parent.isEmpty ? .all : .group(parent)
                  }
                }
              }
              Button("在该分组新建片段") {
                editorTarget = Snippet(id: UUID().uuidString, name: "", description: "", trigger: "", groupPath: node.path, body: "")
              }
            }
          }
        }
        .environment(\.defaultMinListRowHeight, settings.rowHeight)
      }
      .navigationSplitViewColumnWidth(min: 245, ideal: 270, max: 320)
    } content: {
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          QuickSearchField(
            placeholder: "搜索名称、触发词、正文",
            text: $search,
            shouldFocus: $focusMainSearchField,
            onMoveUp: { moveSelection(step: -1) },
            onMoveDown: { moveSelection(step: 1) },
            onSubmit: {},
            onEscape: {}
          )
          Button("新建") {
            editorTarget = Snippet(id: UUID().uuidString, name: "", description: "", trigger: "", groupPath: selectedGroupPath, body: "")
          }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)

        List(filteredSnippets, selection: $selectedSnippetID) { snippet in
          let isDisabled = store.isAnyAncestorDisabled(snippet.groupPath)
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text(snippet.name)
                .font(.system(size: settings.fontSize))
                .lineLimit(1)
                .foregroundStyle(isDisabled ? .secondary : .primary)
              if !snippet.description.isEmpty {
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
          }
          .opacity(isDisabled ? 0.62 : 1.0)
          .contextMenu {
            Button("复制") { copyClean(snippet.body) }
            Button("编辑") {
              editorTarget = snippet
            }
            Button("删除", role: .destructive) { store.remove(snippet) }
          }
          .tag(snippet.id)
        }
        .environment(\.defaultMinListRowHeight, settings.rowHeight)
      }
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
      .navigationSplitViewColumnWidth(min: 390, ideal: 450, max: 560)
    } detail: {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("预览")
            .font(.headline)
          Spacer()
          Button("复制") {
            if let s = selectedSnippet { copyClean(s.body) }
          }
          Button("编辑") {
            if let s = selectedSnippet {
              editorTarget = s
            }
          }
        }

        if let snippet = selectedSnippet {
          let isDisabled = store.isAnyAncestorDisabled(snippet.groupPath)
          Text(snippet.name)
            .font(.title3.weight(.semibold))
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
        } else if case let .group(path) = selectedGroupSelection {
          let isDisabled = store.isAnyAncestorDisabled(path)
          let groupSnippets = store.snippets.filter { isPrefixPath(path, of: $0.groupPath) }
          let directSnippets = store.snippets.filter { $0.groupPath == path }
          let subgroupCount = store.groups.filter { isPrefixPath(path, of: $0) }.count - 1

          Text(path.last ?? "分组")
            .font(.title3.weight(.semibold))
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
        } else {
          Text("未选择 snippet")
            .foregroundStyle(.secondary)
        }

        Text("存储文件: \(store.storageFileURL.path)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(12)
    }
    .sheet(item: $editorTarget) { target in
      SnippetEditorSheet(snippet: target) { updated in
        store.upsert(updated)
        selectedSnippetID = updated.id
      }
      .environmentObject(settings)
    }
    .sheet(item: $newGroupTarget) { target in
      GroupCreateSheet(parentPath: target.parentPath) { name in
        let groupPath = target.parentPath + [name]
        store.createGroup(groupPath)
        selectedGroupSelection = .group(groupPath)
      }
    }
    .sheet(item: $renameGroupTarget) { target in
      GroupRenameSheet(path: target.path) { newName in
        store.renameGroup(from: target.path, to: newName)
        selectedGroupSelection = .group(Array(target.path.dropLast()) + [newName])
      }
    }
    .onAppear {
      focusMainSearchField = true
      if selectedSnippetID == nil {
        selectedSnippetID = filteredSnippets.first?.id
      }
    }
    .onChange(of: filteredSnippets.map(\.id)) { ids in
      if let current = selectedSnippetID, ids.contains(current) { return }
      selectedSnippetID = ids.first
    }
  }

  private var selectedSnippet: Snippet? {
    guard let selectedSnippetID else { return nil }
    return filteredSnippets.first(where: { $0.id == selectedSnippetID })
  }

  private var selectedGroupPath: [String] {
    if case let .group(path) = selectedGroupSelection { return path }
    return []
  }

  private var globalVisibleSnippetCount: Int {
    store.snippets.filter { !store.isAnyAncestorDisabled($0.groupPath) }.count
  }

  private var filteredSnippets: [Snippet] {
    let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return store.snippets.filter { s in
      if !selectedGroupPath.isEmpty && !isPrefixPath(selectedGroupPath, of: s.groupPath) { return false }
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
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private var groupTree: [GroupNode] {
    return buildGroupTree(groups: store.groups, snippets: store.snippets)
  }

  private func buildGroupTree(groups: [[String]], snippets: [Snippet]) -> [GroupNode] {
    var childrenByPath: [String: Set<String>] = [:]
    var totalByPath: [String: Int] = [:]

    for groupPath in groups where !groupPath.isEmpty {
      for depth in 0..<groupPath.count {
        let parent = Array(groupPath.prefix(depth))
        let parentKey = parent.joined(separator: "/")
        childrenByPath[parentKey, default: []].insert(groupPath[depth])
      }
    }

    for snippet in snippets where !snippet.groupPath.isEmpty {
      for depth in 0..<snippet.groupPath.count {
        let current = Array(snippet.groupPath.prefix(depth + 1))
        totalByPath[current.joined(separator: "/"), default: 0] += 1
      }
    }

    func build(path: [String]) -> [GroupNode] {
      let pathKey = path.joined(separator: "/")
      let names = Array(childrenByPath[pathKey] ?? [])
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

      return names.map { name in
        let nextPath = path + [name]
        let nextKey = nextPath.joined(separator: "/")
        let nextChildren = build(path: nextPath)
        return GroupNode(
          name: name,
          path: nextPath,
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

  private func moveSelection(step: Int) {
    guard !filteredSnippets.isEmpty else { return }

    guard let currentID = selectedSnippetID,
          let currentIdx = filteredSnippets.firstIndex(where: { $0.id == currentID }) else {
      selectedSnippetID = filteredSnippets.first?.id
      return
    }

    let next = max(0, min(filteredSnippets.count - 1, currentIdx + step))
    selectedSnippetID = filteredSnippets[next].id
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

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("软件设置")
        .font(.headline)

      HStack(spacing: 12) {
        Text("字号")
          .frame(width: 52, alignment: .leading)
        Slider(value: $settings.fontSize, in: 11...18, step: 1)
        Text("\(Int(settings.fontSize))")
          .frame(width: 28, alignment: .trailing)
      }

      HStack(spacing: 12) {
        Text("行高")
          .frame(width: 52, alignment: .leading)
        Slider(value: $settings.rowHeight, in: 18...30, step: 1)
        Text("\(Int(settings.rowHeight))")
          .frame(width: 28, alignment: .trailing)
      }

      HStack(spacing: 12) {
        Text("唤醒键")
          .frame(width: 52, alignment: .leading)
        Text("Option + 0（当前固定）")
          .foregroundStyle(.secondary)
      }

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
    .frame(width: 560, height: 280)
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

func confirmDeleteGroup(path: [String], snippetCount: Int, subgroupCount: Int) -> Bool {
  let alert = NSAlert()
  alert.messageText = "删除分组？"
  alert.informativeText = """
  分组：\(path.joined(separator: " / "))
  将删除 \(snippetCount) 条 snippet，\(subgroupCount) 个子分组。
  此操作不可恢复。
  """
  alert.alertStyle = .warning
  alert.addButton(withTitle: "删除")
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
