mod error;
mod ffi;

use std::ops::Range;
use std::ptr::NonNull;

pub use error::Error;
pub use ffi::TwigSpan as Span;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Format {
    Djot,
    Markdown,
    Xml,
    Html,
}

impl From<Format> for ffi::TwigFormat {
    fn from(value: Format) -> Self {
        match value {
            Format::Djot => ffi::TwigFormat::Djot,
            Format::Markdown => ffi::TwigFormat::Markdown,
            Format::Xml => ffi::TwigFormat::Xml,
            Format::Html => ffi::TwigFormat::Html,
        }
    }
}

/// One node returned by [`Document::query`]: its AST id, byte spans, and kind.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueryMatch {
    /// The node's id in the shared AST.
    pub node_id: u32,
    /// The node's whole byte range in the source.
    pub span: Range<usize>,
    /// The node's interior byte range (between its delimiters), or `None` for
    /// a leaf / a container with no known interior.
    pub content_span: Option<Range<usize>>,
    /// The node-kind name (e.g. `"heading"`, `"code_block"`).
    pub kind: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Version {
    pub major: u8,
    pub minor: u8,
    pub patch: u8,
}

pub fn version() -> Version {
    let packed = unsafe { ffi::twig_version() };
    Version {
        major: (packed >> 16) as u8,
        minor: (packed >> 8) as u8,
        patch: packed as u8,
    }
}

pub fn version_string() -> &'static str {
    let ptr = unsafe { ffi::twig_version_string() };
    unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_str()
        .unwrap_or("")
}

#[derive(Debug)]
pub struct Document {
    raw: NonNull<ffi::TwigDocument>,
}

impl Document {
    pub fn parse(input: &[u8], format: Format) -> Result<Self, Error> {
        let mut raw = std::ptr::null_mut();
        let ffi_format: ffi::TwigFormat = format.into();
        let status = unsafe { ffi::twig_parse(input.as_ptr(), input.len(), ffi_format as i32, &mut raw) };
        Error::from_status(status)?;
        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(Self { raw })
    }

    pub fn parse_str(input: &str, format: Format) -> Result<Self, Error> {
        Self::parse(input.as_bytes(), format)
    }

    /// Render the document to HTML. For Djot/Markdown this is the rich
    /// rendering path that resolves reference/footnote side tables.
    pub fn render_html(&mut self) -> Result<Vec<u8>, Error> {
        self.borrowed_bytes(|doc, ptr, len| unsafe {
            ffi::twig_document_render_html(doc, ptr, len)
        })
    }

    /// Serialize the document to `format`'s own source syntax: a round-trip
    /// when `format` matches the document's own format, cross-format
    /// conversion otherwise (e.g. parse Markdown, serialize as Djot). Returns
    /// [`Error::UnsupportedFormat`] when the requested direction has no
    /// serializer (today: converting into XML from another format).
    pub fn serialize(&mut self, format: Format) -> Result<Vec<u8>, Error> {
        let ffi_format: ffi::TwigFormat = format.into();
        self.borrowed_bytes(|doc, ptr, len| unsafe {
            ffi::twig_document_serialize(doc, ffi_format as i32, ptr, len)
        })
    }

    /// Encode the document's AST as pretty-printed JSON (the same encoding as
    /// `twig convert -o ast`).
    pub fn ast_json(&mut self) -> Result<Vec<u8>, Error> {
        self.borrowed_bytes(|doc, ptr, len| unsafe {
            ffi::twig_document_ast_json(doc, ptr, len)
        })
    }

    /// Resolve a CSS-lite selector (e.g. `heading[level=2]`,
    /// `link[dest^="http"]`, `code`, `list > item`) against the document,
    /// returning one [`QueryMatch`] per matching node in document order. A
    /// malformed selector yields [`Error::InvalidArgument`].
    ///
    /// This is the general replacement for scanning code spans by hand: a
    /// `verbatim` / `code_block` / `raw_inline` / `raw_block` selector recovers
    /// those, and every other node kind is reachable too.
    pub fn query(&mut self, selector: &str) -> Result<Vec<QueryMatch>, Error> {
        let mut ptr = std::ptr::null();
        let mut len = 0usize;
        let status = unsafe {
            ffi::twig_document_query(
                self.raw.as_ptr(),
                selector.as_ptr(),
                selector.len(),
                &mut ptr,
                &mut len,
            )
        };
        Error::from_status(status)?;
        if len == 0 {
            return Ok(Vec::new());
        }
        if ptr.is_null() {
            return Err(Error::Internal);
        }
        let matches = unsafe { std::slice::from_raw_parts(ptr, len) };
        matches
            .iter()
            .map(|m| {
                let kind = unsafe { std::ffi::CStr::from_ptr(m.kind) }
                    .to_str()
                    .map_err(|_| Error::Internal)?
                    .to_owned();
                Ok(QueryMatch {
                    node_id: m.node_id,
                    span: m.span.start..m.span.end,
                    content_span: if m.has_content_span != 0 {
                        Some(m.content_span.start..m.content_span.end)
                    } else {
                        None
                    },
                    kind,
                })
            })
            .collect()
    }

    /// Shared plumbing for the accessors that return a caller-borrowed byte
    /// buffer (`render_html`/`serialize`/`ast_json`): run `call`, then copy the
    /// borrowed bytes into an owned `Vec` before returning (the buffer is only
    /// valid until the next same-accessor call on this handle).
    fn borrowed_bytes(
        &mut self,
        call: impl FnOnce(*mut ffi::TwigDocument, *mut *const u8, *mut usize) -> ffi::TwigStatus,
    ) -> Result<Vec<u8>, Error> {
        let mut ptr = std::ptr::null();
        let mut len = 0usize;
        let status = call(self.raw.as_ptr(), &mut ptr, &mut len);
        Error::from_status(status)?;
        if len == 0 {
            return Ok(Vec::new());
        }
        if ptr.is_null() {
            return Err(Error::Internal);
        }
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
        Ok(bytes.to_vec())
    }
}

impl Drop for Document {
    fn drop(&mut self) {
        unsafe { ffi::twig_document_destroy(self.raw.as_ptr()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_renders_markdown_html() {
        let mut doc = Document::parse_str("# hi\n", Format::Markdown).expect("parse markdown");
        let html = doc.render_html().expect("render html");
        assert_eq!(String::from_utf8_lossy(&html), "<h1>hi</h1>\n");
    }

    #[test]
    fn parses_html_input() {
        let mut doc = Document::parse_str("<p>hi</p>", Format::Html).expect("parse html");
        let html = doc.render_html().expect("render html");
        assert!(String::from_utf8_lossy(&html).contains("hi"));
    }

    #[test]
    fn serialize_round_trips_and_cross_converts() {
        let mut doc = Document::parse_str("# hi\n", Format::Markdown).expect("parse markdown");

        let canonical = doc.serialize(Format::Markdown).expect("serialize markdown");
        assert!(String::from_utf8_lossy(&canonical).contains("# hi"));

        // Cross-format Markdown -> XML has no serializer.
        assert_eq!(doc.serialize(Format::Xml), Err(Error::UnsupportedFormat));
    }

    #[test]
    fn serialize_markdown_to_djot() {
        let mut doc =
            Document::parse_str("This is *markdown*.\n", Format::Markdown).expect("parse markdown");
        let djot = doc.serialize(Format::Djot).expect("serialize djot");
        assert!(String::from_utf8_lossy(&djot).contains("_markdown_"));
    }

    #[test]
    fn ast_json_dumps_the_tree() {
        let mut doc = Document::parse_str("hello\n", Format::Djot).expect("parse djot");
        let json = doc.ast_json().expect("ast json");
        assert!(String::from_utf8_lossy(&json).contains("\"kind\": \"doc\""));
    }

    #[test]
    fn query_finds_nodes_by_selector() {
        let source = "# One\n\n## Two\n";
        let mut doc = Document::parse_str(source, Format::Markdown).expect("parse markdown");
        let matches = doc.query("heading").expect("query");

        assert_eq!(matches.len(), 2);
        for m in &matches {
            assert_eq!(m.kind, "heading");
            assert!(m.span.start < m.span.end);
        }
    }

    #[test]
    fn query_recovers_code_spans() {
        let source = "prose `code` more prose\n";
        let mut doc = Document::parse_str(source, Format::Markdown).expect("parse markdown");
        let matches = doc.query("verbatim").expect("query");

        assert_eq!(matches.len(), 1);
        assert_eq!(&source[matches[0].span.clone()], "`code`");
    }

    #[test]
    fn query_rejects_a_malformed_selector() {
        let mut doc = Document::parse_str("hi\n", Format::Markdown).expect("parse markdown");
        assert_eq!(doc.query("list >"), Err(Error::InvalidArgument));
    }
}
