# mysnippets (macOS)

A native macOS prototype for Alfred-like snippets:
- Nested group tree
- Compact list with adjustable row height and font size
- Preview-only comments (`{{! ... }}`)
- Single-file JSON storage with auto reload

## Run

```bash
cd mysnippets
swift run mysnippets
```

## Storage

Default file:
- `~/Documents/mysnippets/snippets.json`

Format:
- Top-level `version`, `groups`, `snippets`
- Nested groups via `groups[].parent_id`
- Group hidden state via `groups[].hidden`
- Snippet body stored as multi-line array `snippets[].body`
