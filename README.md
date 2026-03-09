# mysnippets (macOS)

Chinese version: [README.zh.md](README.zh.md)

A native macOS prototype for Alfred-like snippets:
- Nested group tree
- Compact list with adjustable row height and font size
- Optional snippet descriptions for list/search/export
- Preview-only comments (`{{! ... }}`)
- Raycast-like dynamic placeholders: `{cursor}` `{clipboard}` `{date}` `{time}` `{datetime}` `{uuid}`
- Single-file JSON storage with auto reload

## Run

```bash
cd mysnippets
swift run mysnippets
```

## Placeholders

`mysnippets` supports Raycast-like dynamic placeholders in snippet bodies.

Supported placeholders:
- `{cursor}`: removed from the pasted text, then the caret moves back to this position after paste
- `{clipboard}`: replaced with the current clipboard text
- `{date}`: replaced with the current date using the system locale
- `{time}`: replaced with the current time using the system locale
- `{datetime}`: replaced with the current date and time using the system locale
- `{uuid}`: replaced with a newly generated lowercase UUID

Notes:
- Only one final cursor position is used. If multiple `{cursor}` placeholders exist, the last one wins.
- Unknown placeholders are left unchanged.
- Preview-only comments in the form `{{! ... }}` are removed before copy/paste.

Example:

```text
Title: {clipboard}
Created: {datetime}

Summary:
{cursor}
```

## Storage

Default file:
- `~/Documents/mysnippets/snippets.json`

Format:
- Top-level `version`, `groups`, `snippets`
- Nested groups via `groups[].parent_id`
- Group hidden state via `groups[].hidden`
- Snippet body stored as multi-line array `snippets[].body`
- Optional snippet summary via `snippets[].description`
