# Document Metadata: the `---<lang>` proposal

> Status: proposal / design note. Nothing here is implemented yet.
> Scope of this doc: **document-level** metadata only. Region-scoped
> metadata is a separate concern (see "Two scopes" and "Future work").

## The one-line idea

Document metadata is a **`fig` value attached to a scope**. A `---<lang>`
block, and where it sits in the file, are just an *encoding* of that value —
not the thing itself.

Everything below follows from taking that sentence literally.

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

## Model: one record per scope, hoisted out of the block stream

- Document metadata is **exactly one logical record** per document, stored in a
  **side-table on the doc node** (like `attrs`) — not left as a positioned
  block in the content stream. Block children stay pure content; metadata is
  queryable separately.
- The record's value is a **`fig` value**. `---yaml` / `---toml` / `---fig` /
  `---json` are all parsed *into* that one structured model.

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

Sketch (not final): `metadata: struct { lang: []const u8, text: []const u8 }`,
plus a parsed `fig` value on the doc node once fig-parsing is wired in.

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

## Input liberal, output opinionated

- **Liberal on input:** accept `---`/`---<lang>` at top, bottom, or both; any
  supported language; merge them all into the scope's one record.
- **Opinionated on model:** one logical record per scope, hoisted to a
  side-table.
- **Opinionated on output:** when Twig *writes*, emit one canonical block
  (default position/encoding, or preserve what it read), so round-tripping
  doesn't multiply blocks.

## Two decisions still open

1. **Merge / collision policy.** When the front block says `title = A` and the
   back block says `title = B`, what wins? Candidate: deep-merge maps,
   last-in-document-order wins for scalar collisions, with a diagnostic.
   Alternative: hard error on conflict (defensible for a precision tool).
2. **Provenance for editing.** This is the hard part and the thing that makes
   Twig *Twig*: if a key came from the back block and someone edits it, the
   round-trip must rewrite the **back** block, not the front. That means
   tracking a source span **per key**, not just per block. The span machinery
   can do it; most tools can't, which is why they don't offer editable
   metadata.

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

- **Region-scope metadata with a language declaration.** Djot already solves
  scoped attributes (`{...}`) — but only in Djot's own key=value mini-language,
  with no way to say "this scoped block is fig / toml / json". A future markup
  design could add a **scope declaration next to the language declaration** —
  e.g. some `---<lang> <scope>` form, or an attribute that names both a config
  language and the region it governs — unifying "which region" with "which
  config language." That's a language-design question for later, not something
  this proposal needs to settle. For now: **document scope via `---<lang>` at
  the edges; region scope via existing attributes.**
