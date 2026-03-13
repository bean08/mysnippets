# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project uses Semantic Versioning for releases.

## [0.0.1] - 2026-03-10

### Added
- Native macOS snippet manager with three-column management UI
- Global quick insert panel with hierarchical group browsing
- Raycast-like dynamic placeholders such as `{cursor}` and `{clipboard}`
- Configurable `snippets.json` storage path
- Universal macOS packaging script that produces `.app` and `.dmg`

### Changed
- Added English and Chinese README files
- Polished project metadata for open-source release

## [0.0.2] - 2026-03-11

### Added
- Snippet favorites with star toggle actions and priority sorting
- Custom global hotkey recording in Settings
- Reset action for remembered quick panel position

### Changed
- Group selection now shows only direct snippets in the main list
- Main-window search results now show snippet paths for matched items
- Group tree now shows direct and total snippet counts in `direct/total` format
- Main window default size now scales relative to the current screen
- Quick insert panel now closes on blur and remembers user-dragged position
- Settings UI now uses compact dropdowns for font size and row height

## [0.0.3] - 2026-03-13

### Changed
- Main window group rows now show folder icons to match the quick insert panel
- Group detail headers now show a folder icon in the main window
- Disabled groups now sort after enabled groups within the same sidebar level
