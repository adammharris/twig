# Document Metadata: the `---<lang>` proposal

> Status: **implemented** in Twig at the block level (the `metadata` node,
> front + end matter, HTML `<script>` projection with the `</script` refusal
> guard). Parsing that block's text into a structured, queryable, editable
> value is **out of scope for Twig** — it belongs to a fig-integration layer
> (see "Library boundary" below).
> Scope of this doc: **document-level** metadata only. Region-scoped
> metadata is a separate concern (see "Two scopes" and "Future work").

## The one-line idea

Document metadata is a **`fig` value attached to a scope**. A `---<lang>`
block, and where it sits in the file, are just an *encoding* of that value —
not the thing itself.

Everything below follows from taking that sentence literally. Note the division
of labor it implies: Twig owns the *block* (an inert, typed, span-carrying
region of the document); **fig** owns turning that block's bytes into the
*value*. Twig never parses config.

## What metadata *is*

A working definition:

> Metadata is a **structured, out-of-band record asserting facts about a
> scope** — independent of the encoding it's written in, and (for document
> scope) independent of where in the file it appears.

- **Out-of-band** — it is *about* the document, not part of the prose a reader
  reads. Title, author, date, tags, layout, provenance.
- **Encoding-independent** — YAML, TOML, JSON, and fig are all just surface
  syntaxes for the same underlying key/value tree. `fig` already unifies them;
  metadata is where that pays off.
- **Position-independent (for document scope)** — the title is the title
  whether you write it at the top or the bottom of the file.

## Two scopes (and why this proposal only covers one)

Almost all the confusion in this space comes from conflating two different
things that both get called "metadata":

1. **Document-scope** — assertions about *the whole document* (title, author,
   date). Logically **one record per document**, no matter how it's physically
   written. **This proposal.**
2. **Region-scope** — assertions about *a part* of the document ("this section
   is a draft", "this code block uses this highlighter"). Inherently
   positional, because it attaches to the node it's near.

Twig already has mechanism #2: it's `Attrs` — Djot's `{...}` attribute blocks
and the `attrs` side-table. So `---<lang>` frontmatter is **only** about #1,
and #1's defining property (position-independence) is what makes the design
clean.

## The rule

> **Document metadata lives at the edges; region metadata is an attribute on
> the region.**

Concretely, a `---<lang>` block may appear:

- at the **top** of the document (frontmatter), and/or
- at the **bottom** of the document (endmatter),
- **not** in the middle.

Both are **implemented** (Markdown parser). Frontmatter is a leading `---`/
`+++`/`---<lang>` fence. Endmatter is a trailing `---<lang>` fence — it *must*
carry a language tag (a bare `---` away from the top is a thematic break /
setext underline, so only a tagged opener is unambiguous) and *must* be
separated from the body by a blank line (which also lets the body scan close
cleanly at it). A front and an end block on the same document coexist as two
distinct sibling `metadata` nodes today; collapsing them into one logical
record is a fig-integration concern, not Twig's (see "Library boundary").

### The book analogy

This maps exactly onto how a physical book carries metadata:

- **Front matter** — the colophon: title page, author, publisher, edition,
  "set in Garamond", printing history.
- **Back matter** — the ISBN, catalog-in-publication block, jacket summary,
  copyright details.

Metadata about the *whole book* naturally lives at its **boundaries**. The same
instinct shows up in email and HTTP (headers before the body). The middle is
content territory. Allowing `---` blocks to float mid-document would re-open the
"is this metadata, a thematic break, or content?" ambiguity for no gain — so we
don't.

Allowing **both** front and end matter lets a document be genuinely clean:
colophon-style info up top, ISBN/summary-style info at the bottom, each where a
reader would expect it.

## Syntax: `---` plus an optional language tag

```
---fig
title = Twig
author = adammharris
created = 2026-07-08T22:39:41-07:00
---

# Twig

...document body...

---toml
isbn = "978-..."
summary = "A sister project to fig."
---
```

Rules:

- **Bare `---` = YAML.** Full back-compat with the entire frontmatter
  ecosystem (Jekyll, Hugo, Pandoc, MDX). Twig is a strict *superset*.
- **`---toml`, `---fig`, `---json` = self-describing.** The language tag sits
  exactly where a fenced-code-block info string sits; allow optional spaces
  (`--- fig`), trim, first token wins.
- **Closing line is the bare delimiter (`---`)**, no tag — same as a closing
  code fence.

### Why the info string, not a new delimiter

The `---<lang>` form keeps the *good* part of the old ` ```fig ` code-block
habit (naming the language, self-describing) while dropping the *bad* part (a
code block is **markup** — "render this as a sample" — which is the wrong
semantics for inert data).

Rejected alternatives:

- **`+++` / `;;;` / one delimiter per language** — not self-describing (a
  reader can't decode `;;;`), and it burns a delimiter per format forever.
- **Leading code block by convention** — ambiguous: is the first ` ```fig `
  block metadata, or a fig config sample the author wanted rendered?
  Position-dependent magic is exactly the trap we're escaping.
- **Djot attributes for document metadata** — Djot-only, and they're Djot's
  own key=value mini-language; they can't carry an embedded TOML/fig document.
  (They *are* the right tool for region scope — see Future work.)

## Library boundary: where Twig stops and fig begins

The seam is the `metadata` node itself. Twig produces an inert, typed block
with its raw `text`, its `lang`, and its absolute span, and treats the bytes as
opaque. Turning those bytes into a structured value — and merging, querying, and
editing it — is **fig's** job, reached through a thin integration layer. Twig
never links a config parser.

| Concern | Owner |
|---|---|
| Where metadata lives, that it's inert, its raw `text`, its `lang`, its span, refusing unsafe HTML | **Twig** (done) |
| Parse `(lang, text)` → a structured value; merge two config trees; per-key spans; edit a key and re-serialize | **fig** |
| "These front + end blocks are one doc scope; hand their text to fig; splice fig's edits back" | **thin glue** (a `twig-fig` integration / optional module) |

Why this cut:

- **No duplicated grammars.** yaml/toml/figl/json parsing is fig's competency;
  baking it into Twig would fork four evolving config grammars. The `lang`+`text`
  node was the escape from exactly that.
- **The core dependency stays clean and optional.** Twig stays format-agnostic
  and config-parser-free; "parse my metadata into values" is opt-in glue.
- **The round-trip composes.** fig edits the text slice and returns new bytes;
  Twig splices the node with its existing `replaceAtSpan` editor. Neither
  reimplements the other — editing a metadata key is the same splice machinery
  as any other edit.
- **The hard decisions belong to fig, not Twig.** Merge/collision policy and
  per-key provenance are *config* semantics; they were only ever "open" because
  they were mis-filed under Twig. See "Handed to the fig layer" below.

What stays in Twig: the *convention* that document metadata lives at the edges
and that front + end are one logical scope. Twig's parser encodes that. fig
merges the values; Twig decides which blocks feed the merge.

**Seam hook for the round-trip.** For fig's per-key spans to map to absolute
document offsets by a clean `base + offset`, the node's interior bytes must be a
*verbatim* slice of the source. Today `text` is a newline-normalized copy, so
the mapping is exact only for `\n` files (it diverges on `\r\n`). Giving the
node a `content_span` (the verbatim interior, like Twig's other containers) is
the natural hook to add when the integration is built — not needed before then.

### AST node

Store the **language token exactly as the fence wrote it** (`yaml`, `toml`,
`fig`, `figl`, `json`, …) — **no normalization**, so it round-trips losslessly
(a `---fig` block comes back `---fig`, never rewritten). Twig holds no opinion
about a language's canonical spelling; that's the language's business.

Derive the MIME only when projecting to HTML, by a single mechanical rule:

> **`application/<lang>`**

That rule is *already* correct for the whole config-language family —
`toml`→`application/toml`, `json`→`application/json`, `yaml`→`application/yaml`,
and even `ld+json`→`application/ld+json` (the registered JSON-LD type) — and
generalizes to any future language (`fig`→`application/fig`,
`figl`→`application/figl`) with zero table maintenance. It also sidesteps the
deprecated `x-` prefix and the historical `x-fig` = xfig collision by never
using `x-` at all. The tag grammar (`isLangTag`) is a strict subset of RFC
6838's subtype grammar, so `application/<lang>` is always a legal MIME and needs
no escaping.

The one accepted consequence: `fig` and `figl` are **distinct** identities
(distinct MIME, distinct `metadata[lang=…]` matches). That's the price of
losslessness; unify at query time via a selector alias if ever needed, never in
storage.

Shipped: `metadata: struct { lang: []const u8, text: []const u8 }`. Any parsed
`fig` value lives in the integration layer, not on the Twig node.

## Round-trip across formats

One semantic node, three surface projections:

| AST | Markdown / Djot | HTML |
|---|---|---|
| `metadata{ lang:"yaml", … }` | `---` … `---` | `<script type="application/yaml">` |
| `metadata{ lang:"toml", … }` | `---toml` … `---` | `<script type="application/toml">` |
| `metadata{ lang:"fig", … }` | `---fig` … `---` | `<script type="application/fig">` |
| `metadata{ lang:"figl", … }` | `---figl` … `---` | `<script type="application/figl">` |
| `metadata{ lang:"json", … }` | `---json` … `---` | `<script type="application/ld+json">` |

HTML's established form for inert, typed, non-rendered data is the
**`<script type="…">` data island** — browsers don't execute a script whose
`type` they don't recognize as JS. This is exactly the pattern behind
`application/json` hydration blobs and `application/ld+json` (JSON-LD /
schema.org), which is the web's own "document metadata" mechanism. On the HTML
parse side, a `<script>` with a non-JS `type` becomes a `metadata` node instead
of the usual `element{name:"script"}`.

**Raw-text safety guard (implemented).** A `<script>` is a *raw text* element:
its body is verbatim with no escape mechanism, terminated only by the literal
`</script`. That's what makes it round-trip losslessly (the raw slice between
the fences *is* the config source, no entity-decoding) — but it also means a
`</script` inside the body would end the element early, corrupting the document
and opening a script-injection vector. Since raw text has no fidelity-preserving
escape, the HTML printer **refuses** (`error.UnsafeMetadata`, C ABI
`unsafe_metadata`) rather than emit unsafe output; it never writes a partial
document. The guard is deliberately conservative (any `</script`,
case-insensitive) — legitimate frontmatter never contains it. The obscurer
`<!--`+`<script` double-escape can only *swallow* trailing markup (a
non-injection corruption) and is left as a documented edge (a per-format safe
re-encode would live in the fig-integration layer, which knows the value's
structure). Contrast `<code>`
(the old code-block projection), which is PCDATA and entity-encodes `<`/`&`/`>`
on disk — safe, but the raw slice is no longer verbatim config.

## Input liberal, output opinionated

- **Liberal on input:** Twig accepts `---`/`---<lang>` at top, bottom, or both,
  in any language, and preserves each as its own `metadata` node.
- **Opinionated on output:** Twig re-emits each block losslessly in its own
  language, at its own edge.
- **The one-logical-record view** (merging front + end into a single queryable
  record) is the fig-integration layer's model, not Twig's — see below.

## Handed to the fig layer (not Twig's to decide)

These were the "open decisions" while this was mis-scoped as Twig work. They are
*config* semantics, so they belong to fig / the integration layer:

1. **Merge / collision policy.** When the front block says `title = A` and the
   back block says `title = B`, what wins? Candidate: deep-merge maps,
   last-in-document-order wins for scalar collisions, with a diagnostic;
   hard-error-on-conflict is the stricter alternative. Either way it's a
   config-tree merge — fig's operation, not Twig's.
2. **Provenance for editing.** If a key came from the back block and someone
   edits it, the round-trip must rewrite the **back** block. fig produces
   per-key spans *within* a block's text; Twig already owns the block's absolute
   span and the splice (`replaceAtSpan`); the glue composes the two offsets (via
   the `content_span` seam hook above). Most tools can't do this because they
   have neither half; Twig + fig have both.

## Why hasn't anyone done this?

They've done it in disconnected pieces, but never at the intersection where
Twig sits:

- **Jekyll / Hugo / 11ty are renderers, not document models.** Frontmatter is a
  config side-channel for a template engine; they read it, populate template
  variables, and discard the AST. So metadata gets welded to two accidents —
  one encoding (YAML) and one position (top) — because a streaming renderer
  never needs it to be encoding- or position-independent.
- **Pandoc got the concept right and stopped short.** It has a real `Meta` map
  in its AST, separate from the block list, and merges YAML metadata from
  anywhere (even across files). But it's welded to YAML and is lossy back to
  source — a converter, not a round-trippable editor.
- **MDX / Obsidian** added the *region-scope* kind (inline fields) as ad-hoc
  bolt-ons, muddying the two concepts rather than separating them.

The gap nobody filled is the intersection of: **(a)** a round-trippable,
editable document AST whose whole thesis is exposing structure, **(b)** an
**encoding-agnostic config model** — which is exactly what `fig` is — so every
`---<lang>` is just a surface encoding of one structured value, and **(c)**
span-tracking precise enough to edit a single key and rewrite the right block.
Nobody had `fig` sitting next to a document AST. Twig does.

The feature this unlocks that nobody else can ship: point Twig at a folder and
the documents' metadata records become a **queryable dataset** —
`twig select "*.md" where meta.tags has 'draft'`. Frontmatter stops being
template glue and becomes a database keyed on your corpus.

## Future work (explicitly out of scope for now)

- **The fig-integration layer** — parse a `metadata` node's `text` as its
  `lang` into a fig value; merge front + end into one record; edit keys and
  splice back through Twig's editor. A separate library / optional module, per
  "Library boundary" above. Needs, on the fig side, string-level span-preserving
  edits and graceful handling of a `lang` fig doesn't support (Twig accepts any
  `---<anything>`; the glue returns raw-text-only for unknown languages rather
  than failing).
- **Region-scope metadata with a language declaration.** Djot already solves
  scoped attributes (`{...}`) — but only in Djot's own key=value mini-language,
  with no way to say "this scoped block is fig / toml / json". A future markup
  design could add a **scope declaration next to the language declaration** —
  e.g. some `---<lang> <scope>` form, or an attribute that names both a config
  language and the region it governs — unifying "which region" with "which
  config language." That's a language-design question for later, not something
  this proposal needs to settle. For now: **document scope via `---<lang>` at
  the edges; region scope via existing attributes.**
