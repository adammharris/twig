# Twig — status & handoff

Twig parses **document** formats (Djot, XML, Markdown; HTML in progress) into a
single language-neutral **shared AST** (`src/ast/`), so precise structural
operations can be performed on a document — not just format conversion. Sister
project to `fig` (which does the same for config formats).

## Pipeline / languages

- **Shared AST** (`src/ast/`) — djot.js-modeled semantic kinds + generic-markup
  kinds (`element`/`comment`/`doctype`/`processing_instruction`/`cdata`). Every
  node carries `span` and (for containers) `content_span` — the editor-splice
  interior contract.
- **Djot** (`src/languages/djot/`) — full parser (block+inline scan →
  event-stream → AST) + HTML output. Renders through the shared HTML printer.
- **XML** (`src/languages/xml/`) — recursive-descent parser + serializer
  (byte-identical round-trip for canonical input).
- **HTML printer** (`src/languages/html/`) — general shared-AST → HTML
  serializer over the *whole* vocabulary. Takes an optional `Context` carrying
  djot-only render-time state (reference/footnote resolution); `ctx=null` for
  generic input. Djot's `html.zig` is now a 137-line adapter over it. The HTML
  **parser** (HTML→AST) is deferred.
- **Markdown** (`src/languages/markdown/`) — CommonMark parser targeting the
  shared AST, rendered via the shared HTML printer. Extensions gated by
  `ParseOptions` (CommonMark+GFM+extras: math opt-in, rest on). Raw HTML →
  `raw_block`/`raw_inline` (format="html"); frontmatter → raw metadata block.
  - Phase 1 DONE: block structure + basic inline (text, escapes, entities, code
    spans, breaks) + CommonMark 0.31.2 conformance harness (652 vendored
    examples).
  - Phase 2 DONE: full inline — emphasis/strong (delimiter-run algorithm),
    links/images (inline + reference, resolved at parse time; forward-referenced
    defs handled via deferred inline resolution after the block scan), CommonMark
    autolinks, raw inline HTML.
  - Phase 3 PENDING: GFM (tables, strikethrough, task lists, ext autolinks) +
    footnotes, definition lists, math, frontmatter — behind the flags.
- **CLI** (`src/main.zig` + `src/cli/`) — `twig convert [-i F] [-o html|ast|
  canonical] <file|->` and `twig identify`. Extension inference + `-i` override;
  extensible format registry (one entry per language). `-o ast` = pretty JSON
  dump; `-o canonical` = round-trip (XML only so far).

## Test status

`zig build test --summary all` → **133/133**.
Conformance: **djot 265/271**, **html printer 265/271** (both skip the same 6
AST-print-mode cases), **markdown 496/652** (Phase 2 ratchet, `BASELINE=496` in
`markdown/conformance.zig` — bump it as phases land). Of the 156 remaining
markdown failures, `other`(parser bugs)=0: ~6 are minor block-level Phase-1 gaps
and ~150 are the CommonMark-vs-djot rendering divergences from issues #1/#3 below.

## Known issues / deferred (for the Phase-4 rendering pass unless noted)

1. **Shared-printer tightness leak**: list "tightness" propagates transitively
   into non-list descendants — a `block_quote` inside a tight list item wrongly
   drops its `<p>`. `renderChildren` only resets `self.tight` for list kinds.
   Latent (doesn't affect djot's corpus); fix when doing CommonMark rendering.
2. **AST `reference` has no `title` field** — markdown link/LRD titles are
   carried as a `title` *attribute* (works via the printer's attr merge).
3. **No CommonMark-vs-djot HTML mode switch** on the shared printer. Observed
   divergences to reconcile in Phase 4: void elements `<hr>` vs `<hr />`; `"` not
   escaped in text content; tight-list `<li>text</li>` vs `<li>\ntext\n</li>`.
4. **Pre-existing `zig fmt` failures** in `djot/inline.zig` and `djot/block.zig`
   (predate this work) — worth a standalone cleanup commit.
5. XML deviations from strict 1.0 are documented in `xml.zig`'s header.

## Next steps

1. **Markdown Phase 3** — GFM (tables, strikethrough, task lists, ext autolinks)
   + footnotes, definition lists, math, frontmatter behind `ParseOptions`. Note
   the `pending_inline` deferral pattern (Phase 2) generalizes to any future
   "resolved-by-label, possibly-defined-later" construct (e.g. footnotes).
3. **Phase 4** — a CommonMark-faithful HTML rendering mode on the shared printer
   (resolve the divergences in #1/#3, fix the tightness leak).
4. **HTML parser** (deferred "HTML phase") — forked tokenizer (RCDATA/RAWTEXT,
   entity refs), implicit tag closing (`<li>`/`<p>`), conservative tree
   construction. Then upgrade markdown's raw-HTML nodes to parsed `element`s.
5. **CLI follow-ups** — wire Markdown into `-o canonical` once a markdown
   serializer exists; add HTML as an input format once the parser lands.
6. **Editor / span-splice layer** — the original motivation: use
   `span`/`content_span` for precise in-place document edits.
