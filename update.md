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
- **HTML** (`src/languages/html/`) — forgiving, document-oriented parser plus
  general shared-AST → HTML serializer over the *whole* vocabulary. The parser
  produces generic-markup nodes, decodes common/numeric character references,
  handles RAWTEXT/RCDATA and common optional closures (`li`, `p`, table/select
  cells), and preserves source spans. The printer takes an optional `Context`
  carrying djot-only render-time state (reference/footnote resolution);
  `ctx=null` for generic input. Djot's `html.zig` is now a 137-line adapter over it.
- **Markdown** (`src/languages/markdown/`) — CommonMark parser targeting the
  shared AST, rendered via the shared HTML printer. Extensions gated by
  `ParseOptions` (CommonMark+GFM+extras: math and directives opt-in, rest on). Raw HTML →
  `raw_block`/`raw_inline` (format="html"); frontmatter → raw metadata block.
  - Phase 1 DONE: block structure + basic inline (text, escapes, entities, code
    spans, breaks) + CommonMark 0.31.2 conformance harness (652 vendored
    examples).
  - Phase 2 DONE: full inline — emphasis/strong (delimiter-run algorithm),
    links/images (inline + reference, resolved at parse time; forward-referenced
    defs handled via deferred inline resolution after the block scan), CommonMark
    autolinks, raw inline HTML.
  - Phase 3 DONE: GFM (tables, strikethrough, task lists, ext autolinks) +
    math, definition lists, frontmatter — all behind the flags.
  - Phase 3b DONE: footnotes — `Document.footnotes` table + a `markdown/html.zig`
    adapter (mirrors djot's) that builds an `Html.Context` so the shared printer
    does the numbering/backlinks/endnotes. CLI routes markdown through it.
  - Phase 3c DONE: generic directives + attributes (`options.directives`, OFF by
    default like `math` — the colon grammar could otherwise disturb prose). The
    remark/CommonMark "generic directives" family, NOT djot semantics: inline
    `:name[label]{attrs}` (`inline.zig`), leaf `::name[label]{attrs}` and
    container `:::name{attrs}` … `:::` (`block.zig`, a new `ContainerKind
    .directive` that matches every line with no prefix, closed by a colon-fence
    of ≥ its own length; nests, interrupts paragraphs, works inside block
    quotes/lists). New shared-AST kind `directive{form,name}` +
    `DirectiveForm{text,leaf,container}`; the `{#id .class k=v}` shorthand is a
    markdown-local one-shot parser (`markdown/attributes.zig`, distinct from
    djot's event-stream `attributes.zig`) stored in the normal `attrs`
    side-table. Renders like an element whose tag = the directive name with the
    shorthand applied (remark-directive's documented default); round-trips
    through the markdown serializer. Selectors can address it as `directive`.
  - Markdown parsing is now FEATURE-COMPLETE. Remaining markdown work is
    render-side only (Phase 4, below).
- **CLI** (`src/main.zig` + `src/cli/`) — `twig convert [-i F] [-o html|ast|
  canonical] <file|->`, `twig identify`, `twig edit`, `twig query`, and `twig
  filter`. Extension inference +
  `-i` override (including `.html`/`.htm`); extensible format registry (one entry per language — `parse`,
  `parseToAst`, `renderHtml`, optional `serializeCanonical`). `-o ast` = pretty
  JSON dump; `-o canonical` = round-trip serializer (XML, Djot, Markdown).
  Markdown extension flags (`--directives`/`--math`/`--commonmark`/`--gfm`) on
  `convert`/`query`/`edit`/`filter`, threaded as a `format.ParseConfig` through the parse
  adapters (and through the editor's reparse, so an edited directive document
  stays parseable). The registry's `parseToAst` now matches `Editor.ParseFn`
  (leading opaque parse-config context — see below).
  `twig filter <file> --drop <sel> [--keep <sel>] [--unwrap]` prunes a document
  (the `Filter` library helper below): removes every `--drop` match except those
  also matching `--keep`, then optionally unwraps the survivors — the Diaryx
  audience-filter path (`--drop 'directive[name=vis]' --keep
  'directive[class~=public]' --unwrap` = "public view").
- **Editor** (`src/ast/editor.zig`, reader path-nav, `twig edit`) — the
  span-splice layer: lossless in-place edits via index paths. Primitive
  `replaceAtSpan` (splice → reparse → byte-for-byte rollback on failure); ops
  `replaceNode`/`replaceContent`/`insertBefore`/`insertAfter`/`insertChild`/
  `deleteNode`/`deleteNodeSmart`/`unwrapNode`. Runtime-dispatched over a `parseToAst`
  callback whose signature carries an opaque parse-config `ctx`
  (`Editor.ParseFn`), so an edited Markdown document reparses with the same
  extension flags (`--directives`, …) on every keystroke; djot/markdown
  adapters free the `Document` side-table maps and hand back the bare `AST`.
  `deleteNodeSmart` (the CLI `--delete` default) is block-aware whitespace
  cleanup: for a whole-line node it also swallows the block's terminating
  newline and one blank-line separator (`A⏎⏎B⏎⏎C` → `A⏎⏎C`, trimming a dangling
  separator at a document edge), and for a mid-line inline node it degrades to
  the exact-span `deleteNode` (`tidyDeletionSpan`). `unwrapNode` (CLI
  `--unwrap`) replaces a node with the verbatim source of its `content_span` —
  peel a `:::vis{…}` container down to just its blocks — degrading to a smart
  delete for an empty/childless one; exact for unprefixed containers
  (directives/divs), but a marker-prefixed container (block quote `>`, list
  indent) keeps its markers (serializer-assisted stripping is future work).
  Remaining limits: no per-field spans (payload edits = whole-node replace),
  empty-djot-container inserts need a `content_span` the parser leaves null.
  Ops come in path and `…ById` (node-id) forms; both converge on `replaceAtSpan`.
- **Selectors** (`src/ast/select.zig`, `twig query`) — content-based node
  addressing, the friendly alternative to raw index paths. CSS-lite:
  `heading[level=2]`, `heading("Status")`, `item[2]`, `link[dest^="http"]`,
  `code[lang=zig]` (kind names + friendly aliases + `:contains`/shorthand +
  `:nth`/`[k]` + attr predicates). Payload-field predicates resolve through the
  same special-case-then-side-table machine: `level`/`dest`/`lang`/`ordered`/
  `checked` and now `name` (`directive[name=vis]`, `element[name=video]`). The
  `~=` operator (`[class~=public]`) is CSS whitespace-word membership — the
  clean class-set test for directive audiences (`directive[name=vis][class~=public]`).
  Library API: `Select.parse` →
  `resolveAll`/`resolveOne`/`textOf` + `AST.pathOf` (id → path). `twig query`
  lists matches as `[path] kind "preview"`; `twig edit` accepts a selector
  anywhere it takes a path (auto-detected — all-digits-and-dots = index path,
  else selector), refusing an ambiguous match with a candidate list. Descendant
  (`a b`) and child (`a > b`) combinators work, with per-step `:nth` scoping
  (`list:nth(2) > item("dishes")` = that bullet in the 2nd list only). NOT yet:
  `section("Title")` — layers on this same engine (needs a small CLI span-wire).
- **Filter** (`src/ast/filter.zig`, `twig.Filter`, `twig filter`) — declarative
  document pruning over Select + Editor, one layer up from the single-node edit
  ops. `Filter.apply(gpa, *Editor, .{ .drop, .keep, .unwrap_kept })`: remove
  every `drop`-selector match except those also matched by `keep`, then
  optionally unwrap the survivors. Loops + re-resolves both selectors against
  the CURRENT tree each step (the editor reparses per edit, invalidating ids),
  acting on one node at a time; bounded by the initial node count with a
  `FilterDidNotConverge` backstop. The Diaryx audience filter is exactly this:
  drop `directive[name=vis]`, keep `directive[class~=public]`, unwrap → a
  public-only rendering of the document. Exposed across all three surfaces: the
  `twig filter` CLI verb, the C ABI (`twig_editor_filter`, plus
  `twig_editor_unwrap`/`twig_editor_delete_smart` and a
  `twig_editor_create_ext` that takes a `TWIG_MD_*` extension bitmask so the
  editor parses directives), and the Rust bindings (`Editor::filter`/
  `unwrap_node`/`delete_smart`/`new_ext` with `MarkdownExtensions`).

## Test status

`zig build test --summary all` → **223/223**.
Conformance: **djot 265/271**, **html printer 265/271** (both skip the same 6
AST-print-mode cases), **markdown 496/652** (`BASELINE=496` in
`markdown/conformance.zig`; harness uses the `.commonmark` preset, so extensions
don't move it). Of the 156 remaining markdown failures, `other`(parser bugs)=0:
~6 are minor block-level gaps and ~150 are CommonMark-vs-djot *rendering*
divergences from issues #1/#3 below — i.e. remaining markdown work is render-side.

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
6. **Markdown inline node spans: DONE** (commit `4d127c8`). `inline.zig`/`block
   .zig` thread a buffer→source segment map so inline nodes (link/emph/strong/
   code span/autolink/…) get byte-accurate absolute spans covering the full
   construct (delimiters included), with `content_span` = the interior. Editing
   links/emphasis by selector now works. Contract is accurate-or-unset: a
   construct that straddles a multi-line-paragraph line-join is left `(0,0)` and
   the editor guard refuses it cleanly (never a wrong span). GFM extended email
   autolinks after an escaped/entity run are the other intentional unset case.

## Next steps

0. **Document metadata (`---<lang>`)** — design in
   [`document-metadata.md`](./document-metadata.md).
   - DONE (1a): first-class `metadata{lang,text}` node replacing the frontmatter
     `raw_block` hack; tagged `---<lang>` fences (`---` = yaml, `+++` = toml,
     `----` stays a thematic break); stored as-written (lossless), HTML
     projected to a `<script type="application/<lang>">` data island; a
     `</script` detect-and-refuse guard (`error.UnsafeMetadata`, C ABI
     `unsafe_metadata`, Rust `Error::UnsafeMetadata`); selectors `metadata`/
     `meta`/`frontmatter` + `[lang=…]`; Markdown/Djot canonical round-trip.
   - DONE (1b): trailing **endmatter** — a tagged `---<lang>` … `---` block at
     the document tail (blank-separated from the body), appended as the doc's
     last child. Front+end coexist as two sibling `metadata` nodes.
   - OUT OF SCOPE for Twig: parsing a `metadata` block's `text` into a
     structured value, merging front+end into one record, and editing keys is a
     **fig-integration layer** (a separate `twig-fig` library / optional
     module), NOT Twig core — Twig deliberately treats the bytes as opaque and
     never links a config parser. The merge/collision policy and per-key
     provenance are fig's (config) decisions; the round-trip composes fig's
     per-key spans with Twig's existing `replaceAtSpan` splice. Seam hook for
     when it's built: give `metadata` a `content_span` (verbatim interior) so
     fig's spans map to absolute offsets by `base + offset` even on `\r\n`.
     See `document-metadata.md` → "Library boundary". Twig's own metadata work
     is complete.
1. **Markdown Phase 4 — CommonMark-faithful HTML rendering.** The ~150 residual
   conformance failures are all rendering conventions, needing a "CommonMark
   mode" on the shared printer (which djot depends on, so this needs a design
   decision — a `RenderOptions` flag set, a mode enum, or per-construct
   options). Divergences to reconcile: void elements `<hr>`→`<hr />`; `"` escaped
   in text; tight-list `<li>text</li>`; GFM table `align=` attr vs `style=`;
   task-list `<input>` self-close; `<dd>` trailing newline. PLUS fix the latent
   tightness-leak bug (issue #1).
2. **HTML parser follow-up** — expand the named-character-reference table and
   optional-end-tag coverage toward full HTML5 tree construction. Then upgrade
   markdown's raw-HTML nodes to parsed `element`s.
3. **`section("Title")` selector** — "edit everything under a heading"; layers on
   `ast/select.zig` (heading → section span) plus a small CLI change so the edit
   uses the Match's section span rather than the heading node's own. (Descendant/
   child combinators already landed.)
4. **Editor increment 2** — the original motivation is now landed (increment 1:
   index-path splice ops + `twig edit`; plus content-based selectors). Next:
   per-field spans (so a `link` destination or `code_block`
   lang is editable without whole-node replace); smart delete (whitespace/
   separator cleanup); move/reorder ops; richer container interiors so
   empty-container inserts work everywhere.
5. **CLI follow-ups** — HTML is now an input format; add canonical HTML
   serialization only after defining its normalization contract.
