#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TWIG_FORMAT_DJOT 1
#define TWIG_FORMAT_MARKDOWN 2
#define TWIG_FORMAT_XML 3
#define TWIG_FORMAT_HTML 4

// Markdown extension flags for twig_editor_create_ext's `md_flags` bitmask
// (ignored for non-Markdown formats).
#define TWIG_MD_DIRECTIVES (1u << 0)  // generic directives: :name, ::name, :::name
#define TWIG_MD_MATH       (1u << 1)  // $...$ / $$...$$ math

typedef enum TwigStatus {
    TWIG_STATUS_OK = 0,
    TWIG_STATUS_INVALID_ARGUMENT = 1,
    TWIG_STATUS_PARSE_ERROR = 2,
    TWIG_STATUS_OUT_OF_MEMORY = 3,
    TWIG_STATUS_UNSUPPORTED_FORMAT = 4,
    // Editor-only. A locator resolved to no node (out-of-bounds index path, or
    // a selector with zero matches).
    TWIG_STATUS_NOT_FOUND = 5,
    // Editor-only. A selector locator matched more than one node.
    TWIG_STATUS_AMBIGUOUS = 6,
    // Editor-only. The target node has no editable span/interior.
    TWIG_STATUS_NOT_EDITABLE = 7,
    // Editor-only. The edit produced a document that no longer parses; it was
    // rolled back and nothing changed.
    TWIG_STATUS_EDIT_CONFLICT = 8,
    TWIG_STATUS_INTERNAL_ERROR = 255,
} TwigStatus;

typedef struct TwigDocument TwigDocument;

// A span-splice editor over a document: applies lossless, in-place edits and
// reparses after each one. Independent of TwigDocument.
typedef struct TwigEditor TwigEditor;

// A byte range [start, end) into the source.
typedef struct TwigSpan {
    size_t start;
    size_t end;
} TwigSpan;

// One node matched by `twig_document_query`. `content_span` is only meaningful
// when `has_content_span` is non-zero (a leaf, or a container the parser left
// without a known interior, reports has_content_span == 0 and a zeroed
// content_span). `kind` is a NUL-terminated node-kind name (e.g. "heading",
// "code_block") in static, library-owned storage: never free it; it stays
// valid for the process lifetime.
typedef struct TwigQueryMatch {
    uint32_t node_id;
    TwigSpan span;
    TwigSpan content_span;
    int has_content_span;
    const char *kind;
} TwigQueryMatch;

// Packed as (major << 16) | (minor << 8) | patch.
uint32_t twig_version(void);
// Null-terminated "major.minor.patch" string in static library-owned storage.
const char *twig_version_string(void);

// Parse input bytes into a document handle. `format` is one of the
// TWIG_FORMAT_* codes.
TwigStatus twig_parse(
    const uint8_t *input,
    size_t input_len,
    int format,
    TwigDocument **out_doc
);

// Destroy a document handle.
void twig_document_destroy(TwigDocument *doc);

// Render a parsed document to HTML. For Djot/Markdown this is the rich
// rendering path that resolves reference/footnote side tables.
//
// The returned bytes are borrowed from `doc` and remain valid until the next
// `twig_document_render_html` call on that same handle, or until the handle is
// destroyed.
TwigStatus twig_document_render_html(
    TwigDocument *doc,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Serialize a parsed document to `format`'s own source syntax: a round-trip
// when `format` matches the document's own format, cross-format conversion
// otherwise (e.g. parse Markdown, serialize as Djot). Returns
// TWIG_STATUS_UNSUPPORTED_FORMAT when the requested direction has no
// serializer (today: converting into XML from another format).
//
// The returned bytes are borrowed from `doc` and remain valid until the next
// `twig_document_serialize` call on that same handle, or until the handle is
// destroyed.
TwigStatus twig_document_serialize(
    TwigDocument *doc,
    int format,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Encode the parsed document's AST as pretty-printed JSON (the same encoding
// as `twig convert -o ast`).
//
// The returned bytes are borrowed from `doc` and remain valid until the next
// `twig_document_ast_json` call on that same handle, or until the handle is
// destroyed.
TwigStatus twig_document_ast_json(
    TwigDocument *doc,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Resolve a CSS-lite selector (e.g. "heading[level=2]", "link[dest^=\"http\"]",
// "code", "list > item") against a parsed document, yielding one match per
// node in document order. A malformed selector returns
// TWIG_STATUS_INVALID_ARGUMENT.
//
// The returned matches are borrowed from `doc` and remain valid until the next
// `twig_document_query` call on that same handle, or until the handle is
// destroyed.
TwigStatus twig_document_query(
    TwigDocument *doc,
    const uint8_t *selector,
    size_t selector_len,
    const TwigQueryMatch **out_ptr,
    size_t *out_len
);

// ── Editor ──────────────────────────────────────────────────────────────────
// Lossless, in-place span-splice editing. Create an editor over some source,
// apply edits addressed by a `locator` — either a dot-separated index path
// ("0.3.1") or a selector that must match exactly one node (`heading("Status")`)
// — and read the edited bytes back. Each successful edit reparses, so a
// locator is resolved against the tree as it stands at that call; a failed edit
// leaves the document byte-for-byte unchanged. Use twig_editor_query /
// twig_editor_ast_json to inspect the current tree between edits.

// Create an editor over a private copy of `input`, parsed as `format` (a
// TWIG_FORMAT_* code) with default options.
TwigStatus twig_editor_create(
    const uint8_t *input,
    size_t input_len,
    int format,
    TwigEditor **out_editor
);

// Like twig_editor_create, plus `md_flags` — a bitmask of TWIG_MD_* Markdown
// extensions to enable (ignored for other formats). The editor reparses with
// these flags after every edit, so a directive-bearing document stays
// parseable — required before twig_editor_filter can match `directive[...]`
// selectors.
TwigStatus twig_editor_create_ext(
    const uint8_t *input,
    size_t input_len,
    int format,
    uint32_t md_flags,
    TwigEditor **out_editor
);

// Destroy an editor handle.
void twig_editor_destroy(TwigEditor *editor);

// Replace the whole source of the located node with `text`.
TwigStatus twig_editor_replace(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len,
    const uint8_t *text,
    size_t text_len
);

// Replace the interior (between-delimiters content) of the located container.
TwigStatus twig_editor_replace_content(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len,
    const uint8_t *text,
    size_t text_len
);

// Insert `text` immediately before the located node.
TwigStatus twig_editor_insert_before(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len,
    const uint8_t *text,
    size_t text_len
);

// Insert `text` immediately after the located node.
TwigStatus twig_editor_insert_after(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len,
    const uint8_t *text,
    size_t text_len
);

// Insert `text` as the `child_index`-th child of the located container (an
// index at or past the child count appends).
TwigStatus twig_editor_insert_child(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len,
    size_t child_index,
    const uint8_t *text,
    size_t text_len
);

// Delete the located node (removes exactly its span; no whitespace cleanup).
TwigStatus twig_editor_delete(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len
);

// Delete the located node, tidying surrounding blank lines for a whole-line
// (block) node; an inline node degrades to the exact-span delete.
TwigStatus twig_editor_delete_smart(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len
);

// Unwrap the located node: replace it with its interior (drop the wrapper, keep
// the children) — e.g. peel a `:::vis{...}` container. A node with no interior
// (a leaf, or an empty container) is removed.
TwigStatus twig_editor_unwrap(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len
);

// Prune the document in place: remove every node matching the `drop` selector
// except those also matching `keep` (pass keep == NULL to spare nothing), then
// — if `unwrap_kept` is non-zero — unwrap the survivors. Read the result via
// twig_editor_source. A malformed selector returns TWIG_STATUS_INVALID_ARGUMENT;
// a reparse-breaking edit (rolled back) TWIG_STATUS_EDIT_CONFLICT.
TwigStatus twig_editor_filter(
    TwigEditor *editor,
    const uint8_t *drop,
    size_t drop_len,
    const uint8_t *keep,
    size_t keep_len,
    int unwrap_kept
);

// The editor's current (edited) source bytes. Borrowed from `editor` and valid
// until the next successful edit on this handle, or until it is destroyed.
TwigStatus twig_editor_source(
    TwigEditor *editor,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Encode the editor's current tree as pretty-printed JSON. Borrowed from
// `editor` and valid until the next twig_editor_ast_json call, or until it is
// destroyed.
TwigStatus twig_editor_ast_json(
    TwigEditor *editor,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Resolve a selector against the editor's current tree. Borrowed from `editor`
// and valid until the next twig_editor_query call, or until it is destroyed.
TwigStatus twig_editor_query(
    TwigEditor *editor,
    const uint8_t *selector,
    size_t selector_len,
    const TwigQueryMatch **out_ptr,
    size_t *out_len
);

#ifdef __cplusplus
}
#endif
