# mysnippets (macOS)

A native macOS prototype for Alfred-like snippets:
- Nested group tree
- Compact list with adjustable row height and font size
- Preview-only comments (`{{! ... }}`)
- Markdown-backed storage with auto reload

## Run

```bash
cd mysnippets
swift run mysnippets
```

## Storage

Default markdown file:
- `~/Documents/mysnippets/snippets.md`

Format per block:
- `<!-- HIERASNIP:BEGIN {json-meta} -->`
- `...body...`
- `<!-- HIERASNIP:END -->`
