# mysnippets

[中文文档](README.zh.md) · License: [Apache-2.0](LICENSE)

`mysnippets` is a native macOS snippet manager for fast text insertion with hierarchical organization, dynamic placeholders, and a keyboard-first quick panel.

## Features

- Native macOS app built with SwiftUI and AppKit
- Three-column management UI for groups, snippets, and preview
- Global quick insert panel with nested group navigation
- Optional snippet descriptions for search and export
- Preview-only comments via `{{! ... }}`
- Raycast-like placeholders: `{cursor}`, `{clipboard}`, `{date}`, `{time}`, `{datetime}`, `{uuid}`
- Configurable `snippets.json` storage path
- Universal macOS packaging script for Apple Silicon and Intel

## Requirements

- macOS 13.0 or later
- Xcode / Swift toolchain with Swift 5.9+

## Development

```bash
cd mysnippets
swift run mysnippets
```

## Packaging

```bash
cd mysnippets
./scripts/package-macos.sh
```

Outputs:
- `dist/mysnippets.app`
- `dist/mysnippets.dmg`

The packaging script builds both `arm64` and `x86_64` release binaries and merges them into a universal app bundle.

## Placeholders

Supported placeholders:

- `{cursor}`: removed from the pasted text and restores the caret to that position after paste
- `{clipboard}`: inserts current clipboard text
- `{date}`: inserts current date using the system locale
- `{time}`: inserts current time using the system locale
- `{datetime}`: inserts current date and time using the system locale
- `{uuid}`: inserts a newly generated lowercase UUID

Notes:

- If multiple `{cursor}` placeholders exist, the last one wins.
- Unknown `{...}` placeholders are left unchanged.
- Preview-only comments in the form `{{! ... }}` are removed before copy/paste.

Example:

```text
Title: {clipboard}
Created: {datetime}

Summary:
{cursor}
```

## Storage

Default storage file:

- `~/Documents/mysnippets/snippets.json`

The path can be changed in `Settings -> 存储文件`. Enter a full path to `snippets.json`; `~` is supported.

Storage schema:

- top-level keys: `version`, `groups`, `snippets`
- nested groups via `groups[].parent_id`
- group enabled/disabled state via `groups[].hidden`
- multi-line body content via `snippets[].body`
- optional snippet summary via `snippets[].description`

## Release

- Current version: `0.0.3` (from [`VERSION`](VERSION))
- Recommended Git tag: `v0.0.3`
- Latest changes in `v0.0.3`:
  - Added folder icons to main-window group rows and group detail headers
  - Disabled groups now sort after enabled groups in the sidebar
- Release notes: [CHANGELOG.md](CHANGELOG.md)

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
