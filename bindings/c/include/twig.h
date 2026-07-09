#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TWIG_FORMAT_DJOT 1
#define TWIG_FORMAT_MARKDOWN 2
#define TWIG_FORMAT_XML 3

typedef enum TwigStatus {
    TWIG_STATUS_OK = 0,
    TWIG_STATUS_INVALID_ARGUMENT = 1,
    TWIG_STATUS_PARSE_ERROR = 2,
    TWIG_STATUS_OUT_OF_MEMORY = 3,
    TWIG_STATUS_UNSUPPORTED_FORMAT = 4,
    TWIG_STATUS_INTERNAL_ERROR = 255,
} TwigStatus;

typedef struct TwigDocument TwigDocument;

// A byte range [start, end) into the source. One entry per code-like AST
// node (inline code span, fenced/indented code block, raw inline/block
// escape) from `twig_document_code_spans` — everything a plain-text scan
// for a link-like construct (e.g. a wikilink `[[...]]`) should treat as
// opaque, since it is code, not prose.
typedef struct TwigSpan {
    size_t start;
    size_t end;
} TwigSpan;

// Packed as (major << 16) | (minor << 8) | patch.
uint32_t twig_version(void);
// Null-terminated "major.minor.patch" string in static library-owned storage.
const char *twig_version_string(void);

// Parse input bytes into a document handle.
TwigStatus twig_parse(
    const uint8_t *input,
    size_t input_len,
    int format,
    TwigDocument **out_doc
);

// Destroy a document handle.
void twig_document_destroy(TwigDocument *doc);

// Render a parsed document to HTML.
//
// The returned bytes are borrowed from `doc` and remain valid until the next
// `twig_document_render_html` call on that same handle, or until the handle is
// destroyed.
TwigStatus twig_document_render_html(
    TwigDocument *doc,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Find every code-like span (inline code, code blocks, raw inline/block
// escapes) in a parsed document, so a caller doing its own text-level scan
// for link-like constructs can exclude matches that fall inside one.
//
// The returned spans are borrowed from `doc` and remain valid until the next
// `twig_document_code_spans` call on that same handle, or until the handle
// is destroyed.
TwigStatus twig_document_code_spans(
    TwigDocument *doc,
    const TwigSpan **out_ptr,
    size_t *out_len
);

#ifdef __cplusplus
}
#endif
