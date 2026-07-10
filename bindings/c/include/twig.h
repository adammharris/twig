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

typedef enum TwigStatus {
    TWIG_STATUS_OK = 0,
    TWIG_STATUS_INVALID_ARGUMENT = 1,
    TWIG_STATUS_PARSE_ERROR = 2,
    TWIG_STATUS_OUT_OF_MEMORY = 3,
    TWIG_STATUS_UNSUPPORTED_FORMAT = 4,
    TWIG_STATUS_INTERNAL_ERROR = 255,
} TwigStatus;

typedef struct TwigDocument TwigDocument;

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

#ifdef __cplusplus
}
#endif
