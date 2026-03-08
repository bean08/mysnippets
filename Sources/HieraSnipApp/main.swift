import AppKit
import Foundation
import SwiftUI

struct Snippet: Identifiable, Codable, Hashable {
  var id: String
  var name: String
  var trigger: String
  var groupPath: [String]
  var keywords: [String]
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

  let storageRootURL: URL
  private let legacyFileURL: URL
  private let disabledGroupsFileURL: URL
  private var fileURLBySnippetID: [String: URL] = [:]
  private var timer: Timer?
  private var lastFingerprint: String = ""

  init() {
    let doc = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Documents", isDirectory: true)
      .appendingPathComponent("mysnippets", isDirectory: true)
    self.storageRootURL = doc.appendingPathComponent("groups", isDirectory: true)
    self.legacyFileURL = doc.appendingPathComponent("snippets.md", isDirectory: false)
    self.disabledGroupsFileURL = doc.appendingPathComponent("disabled-groups.json", isDirectory: false)
    bootstrapIfNeeded()
    reload()
    startWatcher()
  }

  deinit {
    timer?.invalidate()
  }

  func reload() {
    try? FileManager.default.createDirectory(at: storageRootURL, withIntermediateDirectories: true)

    migrateIfNeeded()

    let files = listSnippetFiles()
    var loadedSnippets: [Snippet] = []
    var loadedGroups = Set<String>()
    var loadedFileMap: [String: URL] = [:]

    for file in files {
      let groupPath = groupPathForSnippetFile(file)
      loadedGroups.insert(pathKey(groupPath))
      if let raw = try? String(contentsOf: file, encoding: .utf8) {
        let parsed = parseMarkdown(raw, defaultGroupPath: groupPath)
        for snippet in parsed {
          var next = snippet
          next.groupPath = normalizeGroupPath(next.groupPath)
          loadedSnippets.append(next)
          loadedFileMap[next.id] = file
        }
      }
    }
    for group in discoverGroupPaths(from: loadedSnippets) {
      loadedGroups.insert(pathKey(group))
    }

    loadedSnippets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    snippets = loadedSnippets
    groups = loadedGroups.map { keyToPath($0) }.sorted(by: comparePath)
    fileURLBySnippetID = loadedFileMap
    disabledGroupKeys = loadDisabledGroupKeys()
    lastFingerprint = fingerprint()
  }

  func upsert(_ snippet: Snippet) {
    var normalized = snippet
    normalized.groupPath = normalizeGroupPath(snippet.groupPath)
    let target = snippetFileURL(for: normalized)
    let targetDir = target.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
    try? serializeMarkdown([normalized]).write(to: target, atomically: true, encoding: .utf8)

    if let old = fileURLBySnippetID[normalized.id], old.path != target.path {
      try? FileManager.default.removeItem(at: old)
    }

    ensureGroupExists(normalized.groupPath)
    cleanupEmptyDirs()
    reload()
  }

  func remove(_ snippet: Snippet) {
    if let file = fileURLBySnippetID[snippet.id] {
      try? FileManager.default.removeItem(at: file)
    }
    cleanupEmptyDirs()
    reload()
  }

  func createGroup(_ path: [String]) {
    let normalized = normalizeGroupPath(path)
    ensureGroupExists(normalized)
    reload()
  }

  func disableGroup(_ path: [String]) {
    let key = pathKey(normalizeGroupPath(path))
    var next = disabledGroupKeys
    next.insert(key)
    saveDisabledGroupKeys(next)
    disabledGroupKeys = next
  }

  func enableGroup(_ path: [String]) {
    let key = pathKey(normalizeGroupPath(path))
    var next = disabledGroupKeys
    next.remove(key)
    saveDisabledGroupKeys(next)
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

    let oldDir = groupDirURL(for: normalizedOld)
    let newDir = groupDirURL(for: newPath)
    try? FileManager.default.createDirectory(at: newDir.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.moveItem(at: oldDir, to: newDir)

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
    saveDisabledGroupKeys(nextDisabled)
    disabledGroupKeys = nextDisabled

    cleanupEmptyDirs()
    reload()
  }

  func deleteGroup(_ path: [String]) {
    let normalized = normalizeGroupPath(path)
    let dir = groupDirURL(for: normalized)
    try? FileManager.default.removeItem(at: dir)

    let nextDisabled = Set(disabledGroupKeys.filter { !hasPrefix(keyToPath($0), prefix: normalized) })
    saveDisabledGroupKeys(nextDisabled)
    disabledGroupKeys = nextDisabled

    cleanupEmptyDirs()
    reload()
  }

  private func bootstrapIfNeeded() {
    try? FileManager.default.createDirectory(at: storageRootURL, withIntermediateDirectories: true)
    guard listSnippetFiles().isEmpty, !FileManager.default.fileExists(atPath: legacyFileURL.path) else { return }

    let seed: [Snippet] = [
      Snippet(
        id: "eng-git-commit-template",
        name: "Conventional Commit (CN)",
        trigger: ";gcc",
        groupPath: ["Engineering", "Git", "Commit", "Templates"],
        keywords: ["git", "commit"],
        body: "feat(scope): 简要说明\\n\\n{{! 发布前删除占位信息，复制时会自动删除此注释。}}\\n背景：...\\n影响范围：...\\n回滚方案：..."
      ),
      Snippet(
        id: "work-sync-daily",
        name: "Daily Sync Update",
        trigger: ";dsu",
        groupPath: ["Work", "Sync", "Daily", "Standup"],
        keywords: ["daily", "sync"],
        body: "Yesterday:\\n- ...\\n\\nToday:\\n- ...\\n\\nBlockers:\\n- ...\\n{{! 预览提醒：别忘记 KPI。}}"
      )
    ]
    for snippet in seed {
      var s = snippet
      s.groupPath = normalizeGroupPath(s.groupPath)
      ensureGroupExists(s.groupPath)
      let file = snippetFileURL(for: s)
      try? serializeMarkdown([s]).write(to: file, atomically: true, encoding: .utf8)
    }
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
    let files = listSnippetFiles() + listGroupMarkerFiles()
    if files.isEmpty { return "missing" }
    var parts: [String] = []
    for file in files.sorted(by: { $0.path < $1.path }) {
      if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
         let modified = attrs[.modificationDate] as? Date,
         let size = attrs[.size] as? NSNumber {
        parts.append("\(file.path):\(modified.timeIntervalSince1970):\(size.intValue)")
      }
    }
    return parts.joined(separator: "|")
  }

  private func parseMarkdown(_ raw: String, defaultGroupPath: [String]) -> [Snippet] {
    let pattern = "<!-- HIERASNIP:BEGIN (.+?) -->\\n([\\s\\S]*?)\\n<!-- HIERASNIP:END -->"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)

    return regex.matches(in: raw, range: nsRange).compactMap { m in
      guard
        let metaRange = Range(m.range(at: 1), in: raw),
        let bodyRange = Range(m.range(at: 2), in: raw),
        let data = raw[metaRange].data(using: .utf8)
      else { return nil }

      struct Meta: Codable { let id: String; let name: String; let trigger: String?; let groupPath: [String]?; let keywords: [String]? }
      guard let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }

      return Snippet(
        id: meta.id,
        name: meta.name,
        trigger: meta.trigger ?? "",
        groupPath: normalizeGroupPath(meta.groupPath ?? defaultGroupPath),
        keywords: meta.keywords ?? [],
        body: String(raw[bodyRange])
      )
    }
  }

  private func serializeMarkdown(_ snippets: [Snippet]) -> String {
    var out: [String] = []
    out.append("# mysnippets Snippet File")
    out.append("")
    out.append("Auto-managed markdown storage for a single snippet.")
    out.append("")

    for s in snippets {
      let meta: [String: Any] = [
        "id": s.id,
        "name": s.name,
        "trigger": s.trigger,
        "groupPath": s.groupPath,
        "keywords": s.keywords,
      ]
      let metaData = (try? JSONSerialization.data(withJSONObject: meta, options: [])) ?? Data("{}".utf8)
      let metaText = String(decoding: metaData, as: UTF8.self)
      out.append("<!-- HIERASNIP:BEGIN \(metaText) -->")
      out.append(s.body)
      out.append("<!-- HIERASNIP:END -->")
      out.append("")
    }

    return out.joined(separator: "\n")
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

  private func groupDirURL(for path: [String]) -> URL {
    var dir = storageRootURL
    for seg in path {
      dir.appendPathComponent(seg, isDirectory: true)
    }
    return dir
  }

  private func groupMarkerURL(for path: [String]) -> URL {
    groupDirURL(for: path).appendingPathComponent("_group.md", isDirectory: false)
  }

  private func snippetFileURL(for snippet: Snippet) -> URL {
    groupDirURL(for: snippet.groupPath).appendingPathComponent("\(snippet.id).md", isDirectory: false)
  }

  private func groupPathForSnippetFile(_ file: URL) -> [String] {
    let relative = file.deletingLastPathComponent().path.replacingOccurrences(of: storageRootURL.path + "/", with: "")
    if relative == file.deletingLastPathComponent().path { return ["未分组"] }
    let parts = relative.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    return normalizeGroupPath(parts)
  }

  private func listSnippetFiles() -> [URL] {
    guard let e = FileManager.default.enumerator(at: storageRootURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
      return []
    }
    var result: [URL] = []
    for case let file as URL in e where file.pathExtension == "md" && file.lastPathComponent != "_group.md" && file.lastPathComponent != "group.md" {
      result.append(file)
    }
    return result
  }

  private func listGroupMarkerFiles() -> [URL] {
    guard let e = FileManager.default.enumerator(at: storageRootURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
      return []
    }
    var result: [URL] = []
    for case let file as URL in e where file.lastPathComponent == "_group.md" {
      result.append(file)
    }
    return result
  }

  private func discoverGroupPaths(from snippets: [Snippet]) -> [[String]] {
    var set = Set<String>()
    for snippet in snippets {
      for depth in 0..<snippet.groupPath.count {
        let p = Array(snippet.groupPath.prefix(depth + 1))
        set.insert(pathKey(p))
      }
    }
    for marker in listGroupMarkerFiles() {
      let path = groupPathForSnippetFile(marker)
      for depth in 0..<path.count {
        let p = Array(path.prefix(depth + 1))
        set.insert(pathKey(p))
      }
    }
    return set.map(keyToPath).sorted(by: comparePath)
  }

  private func ensureGroupExists(_ path: [String]) {
    let normalized = normalizeGroupPath(path)
    let dir = groupDirURL(for: normalized)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: groupMarkerURL(for: normalized).path) {
      try? "# Group Marker\n".write(to: groupMarkerURL(for: normalized), atomically: true, encoding: .utf8)
    }
  }

  private func migrateIfNeeded() {
    let groupFiles = listLegacyGroupFiles()
    if !groupFiles.isEmpty {
      for gf in groupFiles {
        let gp = groupPathForLegacyGroupFile(gf)
        if let raw = try? String(contentsOf: gf, encoding: .utf8) {
          let parsed = parseMarkdown(raw, defaultGroupPath: gp)
          ensureGroupExists(gp)
          for snippet in parsed {
            var s = snippet
            s.groupPath = normalizeGroupPath(s.groupPath)
            let file = snippetFileURL(for: s)
            if !FileManager.default.fileExists(atPath: file.path) {
              try? serializeMarkdown([s]).write(to: file, atomically: true, encoding: .utf8)
            }
          }
        }
        try? FileManager.default.removeItem(at: gf)
      }
      cleanupEmptyDirs()
    }

    let snippetFiles = listSnippetFiles()
    if !snippetFiles.isEmpty { return }

    if let raw = try? String(contentsOf: legacyFileURL, encoding: .utf8) {
      let parsed = parseMarkdown(raw, defaultGroupPath: ["未分组"])
      for snippet in parsed {
        var s = snippet
        s.groupPath = normalizeGroupPath(s.groupPath)
        ensureGroupExists(s.groupPath)
        try? serializeMarkdown([s]).write(to: snippetFileURL(for: s), atomically: true, encoding: .utf8)
      }
    }
  }

  private func loadDisabledGroupKeys() -> Set<String> {
    guard let data = try? Data(contentsOf: disabledGroupsFileURL),
          let arr = try? JSONDecoder().decode([String].self, from: data) else {
      return []
    }
    return Set(arr)
  }

  private func saveDisabledGroupKeys(_ keys: Set<String>) {
    let arr = Array(keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    if let data = try? JSONEncoder().encode(arr) {
      try? data.write(to: disabledGroupsFileURL, options: .atomic)
    }
  }

  private func listLegacyGroupFiles() -> [URL] {
    guard let e = FileManager.default.enumerator(at: storageRootURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
      return []
    }
    var result: [URL] = []
    for case let file as URL in e where file.lastPathComponent == "group.md" {
      result.append(file)
    }
    return result
  }

  private func groupPathForLegacyGroupFile(_ file: URL) -> [String] {
    groupPathForSnippetFile(file)
  }

  private func cleanupEmptyDirs() {
    guard let e = FileManager.default.enumerator(at: storageRootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: nil) else {
      return
    }
    let dirs = (e.allObjects as? [URL] ?? []).sorted { $0.path.count > $1.path.count }
    for dir in dirs {
      var isDir: ObjCBool = false
      if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
         (try? FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty) == true {
        try? FileManager.default.removeItem(at: dir)
      }
    }
  }
}

final class UISettings: ObservableObject {
  @AppStorage("fontSize") var fontSize: Double = 13
  @AppStorage("rowHeight") var rowHeight: Double = 22
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}

@main
struct mysnippetsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @StateObject private var store = SnippetStore()
  @StateObject private var settings = UISettings()

  var body: some Scene {
    WindowGroup("mysnippets") {
      ContentView()
        .environmentObject(store)
        .environmentObject(settings)
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 1150, height: 760)

    Settings {
      SettingsView()
        .environmentObject(settings)
    }
  }
}

struct ContentView: View {
  @EnvironmentObject private var store: SnippetStore
  @EnvironmentObject private var settings: UISettings

  @State private var search = ""
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
                editorTarget = Snippet(id: UUID().uuidString, name: "", trigger: "", groupPath: node.path, keywords: [], body: "")
              }
            }
          }
        }
        .environment(\.defaultMinListRowHeight, settings.rowHeight)
      }
    } content: {
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          TextField("搜索名称、触发词、正文", text: $search)
          Button("新建") {
            editorTarget = Snippet(id: UUID().uuidString, name: "", trigger: "", groupPath: selectedGroupPath, keywords: [], body: "")
          }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)

        List(filteredSnippets, selection: $selectedSnippetID) { snippet in
          HStack(spacing: 8) {
            Text(snippet.name)
              .font(.system(size: settings.fontSize))
              .lineLimit(1)
            Spacer(minLength: 4)
            if !snippet.trigger.isEmpty {
              Text(snippet.trigger)
                .font(.system(size: max(10, settings.fontSize - 1), weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            }
          }
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
          Text(snippet.name)
            .font(.title3.weight(.semibold))
          Text(groupLabel(snippet.groupPath))
            .font(.system(size: settings.fontSize))
            .foregroundStyle(.secondary)

          ScrollView {
            Text(renderPreview(snippet.body))
              .font(.system(size: settings.fontSize, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(10)
          }
          .background(Color(NSColor.textBackgroundColor))
          .cornerRadius(8)
        } else {
          Text("未选择 snippet")
            .foregroundStyle(.secondary)
        }

        Text("分组目录: \(store.storageRootURL.path)")
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
      if store.isAnyAncestorDisabled(s.groupPath) { return false }
      if q.isEmpty { return true }
      let text = [
        s.name,
        s.trigger,
        s.groupPath.joined(separator: "/"),
        s.keywords.joined(separator: " "),
        s.body,
        stripComments(s.body),
      ].joined(separator: "\n").lowercased()
      return text.contains(q)
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private var groupTree: [GroupNode] {
    let active = store.snippets.filter { !store.isAnyAncestorDisabled($0.groupPath) }
    return buildGroupTree(groups: store.groups, snippets: active)
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
  @State private var keywordText: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(snippet.name.isEmpty ? "新建 Snippet" : "编辑 Snippet")
        .font(.headline)

      TextField("名称", text: $snippet.name)
      TextField("触发词", text: $snippet.trigger)
      TextField("分组路径（A/B/C）", text: $groupText)
      TextField("关键词（逗号分隔）", text: $keywordText)

      Text("正文")
      TextEditor(text: $snippet.body)
        .font(.system(size: settings.fontSize, design: .monospaced))
        .frame(minHeight: 220)
        .border(Color.secondary.opacity(0.2))

      HStack {
        Spacer()
        Button("取消") { dismiss() }
        Button("保存") {
          snippet.groupPath = splitPath(groupText)
          snippet.keywords = keywordText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
          onSave(snippet)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(width: 700, height: 520)
    .onAppear {
      groupText = snippet.groupPath.joined(separator: "/")
      keywordText = snippet.keywords.joined(separator: ", ")
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
  @EnvironmentObject private var settings: UISettings

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
    }
    .padding(16)
    .frame(width: 460, height: 140)
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

func stripComments(_ body: String) -> String {
  body.replacingOccurrences(of: #"\{\{!([\s\S]*?)\}\}"#, with: "", options: .regularExpression)
    .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func renderPreview(_ body: String) -> String {
  let ns = body as NSString
  guard let regex = try? NSRegularExpression(pattern: #"\{\{!([\s\S]*?)\}\}"#) else { return body }
  let range = NSRange(location: 0, length: ns.length)
  var output = body
  for m in regex.matches(in: body, range: range).reversed() {
    guard m.numberOfRanges > 1, let cr = Range(m.range(at: 1), in: output), let fr = Range(m.range(at: 0), in: output) else { continue }
    let note = output[cr].trimmingCharacters(in: .whitespacesAndNewlines)
    output.replaceSubrange(fr, with: "\n[注释] \(note)\n")
  }
  return output
}

func copyClean(_ body: String) {
  let pb = NSPasteboard.general
  pb.clearContents()
  pb.setString(stripComments(body), forType: .string)
}
