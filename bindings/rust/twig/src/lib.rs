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
        let raw = self.raw.as_ptr();
        collect_bytes(|ptr, len| unsafe { ffi::twig_document_render_html(raw, ptr, len) })
    }

    /// Serialize the document to `format`'s own source syntax: a round-trip
    /// when `format` matches the document's own format, cross-format
    /// conversion otherwise (e.g. parse Markdown, serialize as Djot). Returns
    /// [`Error::UnsupportedFormat`] when the requested direction has no
    /// serializer (today: converting into XML from another format).
    pub fn serialize(&mut self, format: Format) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        let ffi_format: ffi::TwigFormat = format.into();
        collect_bytes(|ptr, len| unsafe {
            ffi::twig_document_serialize(raw, ffi_format as i32, ptr, len)
        })
    }

    /// Encode the document's AST as pretty-printed JSON (the same encoding as
    /// `twig convert -o ast`).
    pub fn ast_json(&mut self) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        collect_bytes(|ptr, len| unsafe { ffi::twig_document_ast_json(raw, ptr, len) })
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
        let raw = self.raw.as_ptr();
        collect_matches(|ptr, len| unsafe {
            ffi::twig_document_query(raw, selector.as_ptr(), selector.len(), ptr, len)
        })
    }
}

impl Drop for Document {
    fn drop(&mut self) {
        unsafe { ffi::twig_document_destroy(self.raw.as_ptr()) }
    }
}

/// Markdown extensions to enable for an [`Editor`] parse (see
/// [`Editor::new_ext`]). Ignored for non-Markdown formats. Both default off,
/// matching the library.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct MarkdownExtensions {
    /// Generic directives: `:name`, `::name`, `:::name`.
    pub directives: bool,
    /// `$...$` / `$$...$$` math.
    pub math: bool,
}

impl MarkdownExtensions {
    fn to_flags(self) -> u32 {
        let mut flags = 0;
        if self.directives {
            flags |= ffi::TWIG_MD_DIRECTIVES;
        }
        if self.math {
            flags |= ffi::TWIG_MD_MATH;
        }
        flags
    }
}

/// A span-splice editor over a document: applies lossless, in-place edits and
/// reparses after each one, so node addressing stays valid as the document
/// evolves. Every op is addressed by a `locator` — a dot-separated index path
/// (`"0.3.1"`) or a selector that must match exactly one node
/// (`heading("Status")`). A failed edit leaves the document unchanged.
#[derive(Debug)]
pub struct Editor {
    raw: NonNull<ffi::TwigEditor>,
}

impl Editor {
    /// Create an editor over a private copy of `input`, parsed as `format` with
    /// default options.
    pub fn new(input: &[u8], format: Format) -> Result<Self, Error> {
        let mut raw = std::ptr::null_mut();
        let ffi_format: ffi::TwigFormat = format.into();
        let status =
            unsafe { ffi::twig_editor_create(input.as_ptr(), input.len(), ffi_format as i32, &mut raw) };
        Error::from_status(status)?;
        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(Self { raw })
    }

    pub fn new_str(input: &str, format: Format) -> Result<Self, Error> {
        Self::new(input.as_bytes(), format)
    }

    /// Like [`Editor::new`], plus Markdown `extensions` to enable (ignored for
    /// other formats). The editor reparses with these after every edit, so a
    /// directive-bearing document stays parseable — needed before
    /// [`Editor::filter`] can match `directive[...]` selectors.
    pub fn new_ext(input: &[u8], format: Format, extensions: MarkdownExtensions) -> Result<Self, Error> {
        let mut raw = std::ptr::null_mut();
        let ffi_format: ffi::TwigFormat = format.into();
        let status = unsafe {
            ffi::twig_editor_create_ext(
                input.as_ptr(),
                input.len(),
                ffi_format as i32,
                extensions.to_flags(),
                &mut raw,
            )
        };
        Error::from_status(status)?;
        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(Self { raw })
    }

    /// Replace the whole source of the located node with `text`.
    pub fn replace(&mut self, locator: &str, text: &str) -> Result<(), Error> {
        self.apply(locator, text, |ed, loc, loc_len, txt, txt_len| unsafe {
            ffi::twig_editor_replace(ed, loc, loc_len, txt, txt_len)
        })
    }

    /// Replace the interior (between-delimiters content) of the located
    /// container.
    pub fn replace_content(&mut self, locator: &str, text: &str) -> Result<(), Error> {
        self.apply(locator, text, |ed, loc, loc_len, txt, txt_len| unsafe {
            ffi::twig_editor_replace_content(ed, loc, loc_len, txt, txt_len)
        })
    }

    /// Insert `text` immediately before the located node.
    pub fn insert_before(&mut self, locator: &str, text: &str) -> Result<(), Error> {
        self.apply(locator, text, |ed, loc, loc_len, txt, txt_len| unsafe {
            ffi::twig_editor_insert_before(ed, loc, loc_len, txt, txt_len)
        })
    }

    /// Insert `text` immediately after the located node.
    pub fn insert_after(&mut self, locator: &str, text: &str) -> Result<(), Error> {
        self.apply(locator, text, |ed, loc, loc_len, txt, txt_len| unsafe {
            ffi::twig_editor_insert_after(ed, loc, loc_len, txt, txt_len)
        })
    }

    /// Insert `text` as the `index`-th child of the located container (an index
    /// at or past the child count appends).
    pub fn insert_child(&mut self, locator: &str, index: usize, text: &str) -> Result<(), Error> {
        let status = unsafe {
            ffi::twig_editor_insert_child(
                self.raw.as_ptr(),
                locator.as_ptr(),
                locator.len(),
                index,
                text.as_ptr(),
                text.len(),
            )
        };
        Error::from_status(status)
    }

    /// Delete the located node (removes exactly its span; no whitespace
    /// cleanup).
    pub fn delete(&mut self, locator: &str) -> Result<(), Error> {
        let status = unsafe {
            ffi::twig_editor_delete(self.raw.as_ptr(), locator.as_ptr(), locator.len())
        };
        Error::from_status(status)
    }

    /// Delete the located node, tidying surrounding blank lines for a
    /// whole-line (block) node; an inline node degrades to the exact delete.
    pub fn delete_smart(&mut self, locator: &str) -> Result<(), Error> {
        let status = unsafe {
            ffi::twig_editor_delete_smart(self.raw.as_ptr(), locator.as_ptr(), locator.len())
        };
        Error::from_status(status)
    }

    /// Unwrap the located node: replace it with its interior (drop the wrapper,
    /// keep the children) — e.g. peel a `:::vis{...}` container. A node with no
    /// interior (a leaf, or an empty container) is removed.
    pub fn unwrap_node(&mut self, locator: &str) -> Result<(), Error> {
        let status = unsafe {
            ffi::twig_editor_unwrap(self.raw.as_ptr(), locator.as_ptr(), locator.len())
        };
        Error::from_status(status)
    }

    /// Prune the document in place: remove every node matching the `drop`
    /// selector except those also matching `keep` (`None` spares nothing),
    /// then — if `unwrap_kept` — unwrap the survivors. Read the result with
    /// [`Editor::source`].
    pub fn filter(&mut self, drop: &str, keep: Option<&str>, unwrap_kept: bool) -> Result<(), Error> {
        let (keep_ptr, keep_len) = match keep {
            Some(k) => (k.as_ptr(), k.len()),
            None => (std::ptr::null(), 0),
        };
        let status = unsafe {
            ffi::twig_editor_filter(
                self.raw.as_ptr(),
                drop.as_ptr(),
                drop.len(),
                keep_ptr,
                keep_len,
                unwrap_kept as i32,
            )
        };
        Error::from_status(status)
    }

    /// The editor's current (edited) source bytes.
    pub fn source(&mut self) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        collect_bytes(|ptr, len| unsafe { ffi::twig_editor_source(raw, ptr, len) })
    }

    /// The editor's current source bytes as a UTF-8 string.
    pub fn source_str(&mut self) -> Result<String, Error> {
        String::from_utf8(self.source()?).map_err(|_| Error::Internal)
    }

    /// Encode the editor's current tree as pretty-printed JSON — the live
    /// counterpart of [`Document::ast_json`], for inspecting between edits.
    pub fn ast_json(&mut self) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        collect_bytes(|ptr, len| unsafe { ffi::twig_editor_ast_json(raw, ptr, len) })
    }

    /// Resolve a selector against the editor's current tree — the live
    /// counterpart of [`Document::query`].
    pub fn query(&mut self, selector: &str) -> Result<Vec<QueryMatch>, Error> {
        let raw = self.raw.as_ptr();
        collect_matches(|ptr, len| unsafe {
            ffi::twig_editor_query(raw, selector.as_ptr(), selector.len(), ptr, len)
        })
    }

    /// Shared plumbing for the `(locator, text)` edit ops.
    fn apply(
        &mut self,
        locator: &str,
        text: &str,
        op: impl FnOnce(*mut ffi::TwigEditor, *const u8, usize, *const u8, usize) -> ffi::TwigStatus,
    ) -> Result<(), Error> {
        let status = op(
            self.raw.as_ptr(),
            locator.as_ptr(),
            locator.len(),
            text.as_ptr(),
            text.len(),
        );
        Error::from_status(status)
    }
}

impl Drop for Editor {
    fn drop(&mut self) {
        unsafe { ffi::twig_editor_destroy(self.raw.as_ptr()) }
    }
}

/// Run `call` (which writes a borrowed `(ptr, len)` byte buffer) and copy the
/// result into an owned `Vec` — the buffer is only valid until the next
/// same-accessor call on the handle, so we copy before returning. Shared by
/// [`Document`] and [`Editor`].
fn collect_bytes(
    call: impl FnOnce(*mut *const u8, *mut usize) -> ffi::TwigStatus,
) -> Result<Vec<u8>, Error> {
    let mut ptr = std::ptr::null();
    let mut len = 0usize;
    let status = call(&mut ptr, &mut len);
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

/// Run `call` (which writes a borrowed `(ptr, len)` match array) and copy each
/// match into an owned [`QueryMatch`]. Shared by [`Document`] and [`Editor`].
fn collect_matches(
    call: impl FnOnce(*mut *const ffi::TwigQueryMatch, *mut usize) -> ffi::TwigStatus,
) -> Result<Vec<QueryMatch>, Error> {
    let mut ptr = std::ptr::null();
    let mut len = 0usize;
    let status = call(&mut ptr, &mut len);
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

    #[test]
    fn editor_edits_by_index_path() {
        let mut ed = Editor::new_str("<a><b>hi</b></a>", Format::Xml).expect("editor");
        ed.replace_content("0.0", "bye").expect("replace_content");
        assert_eq!(ed.source_str().expect("source"), "<a><b>bye</b></a>");
    }

    #[test]
    fn editor_insert_child_and_delete() {
        let mut ed = Editor::new_str("<r><a/><c/></r>", Format::Xml).expect("editor");
        ed.insert_child("0", 1, "<b/>").expect("insert_child");
        assert_eq!(ed.source_str().expect("source"), "<r><a/><b/><c/></r>");
        ed.delete("0.1").expect("delete");
        assert_eq!(ed.source_str().expect("source"), "<r><a/><c/></r>");
    }

    #[test]
    fn editor_edits_by_selector() {
        let mut ed = Editor::new_str("# One\n\n## Two\n", Format::Markdown).expect("editor");
        ed.replace("heading(\"Two\")", "## Renamed").expect("replace");
        assert_eq!(ed.source_str().expect("source"), "# One\n\n## Renamed\n");
    }

    #[test]
    fn editor_locator_errors_are_distinct() {
        let mut ed = Editor::new_str("<r><a/><a/></r>", Format::Xml).expect("editor");
        assert_eq!(ed.replace("0.9", "x"), Err(Error::NotFound));
        assert_eq!(ed.replace("element", "x"), Err(Error::Ambiguous));
        assert_eq!(ed.replace("element(", "x"), Err(Error::InvalidArgument));
        // Untouched by the failed edits.
        assert_eq!(ed.source_str().expect("source"), "<r><a/><a/></r>");
    }

    #[test]
    fn editor_reparse_break_rolls_back() {
        let mut ed = Editor::new_str("<a>ok</a>", Format::Xml).expect("editor");
        assert_eq!(ed.replace_content("0", "<b>"), Err(Error::EditConflict));
        assert_eq!(ed.source_str().expect("source"), "<a>ok</a>");
    }

    #[test]
    fn editor_leaf_content_is_not_editable() {
        let mut ed = Editor::new_str("<a>hi</a>", Format::Xml).expect("editor");
        assert_eq!(ed.replace_content("0.0", "x"), Err(Error::NotEditable));
    }

    #[test]
    fn editor_query_reflects_current_tree() {
        let mut ed = Editor::new_str("<r><a/></r>", Format::Xml).expect("editor");
        ed.insert_child("0", 1, "<b/>").expect("insert_child");
        // Root <r> plus <a/> and <b/>.
        assert_eq!(ed.query("element").expect("query").len(), 3);
        let json = ed.ast_json().expect("ast_json");
        assert!(String::from_utf8_lossy(&json).contains("\"kind\": \"doc\""));
    }

    #[test]
    fn editor_unwrap_and_smart_delete() {
        let mut ed = Editor::new_str("<r><box><b/><c/></box></r>", Format::Xml).expect("editor");
        ed.unwrap_node("0.0").expect("unwrap"); // <box>
        assert_eq!(ed.source_str().expect("source"), "<r><b/><c/></r>");

        let mut md = Editor::new_str("A\n\nB\n\nC\n", Format::Markdown).expect("editor");
        md.delete_smart("1").expect("delete_smart"); // the "B" paragraph
        assert_eq!(md.source_str().expect("source"), "A\n\nC\n");
    }

    #[test]
    fn editor_directives_require_the_extension_flag() {
        let src = ":::vis{.public}\nhi\n:::\n";
        // Without the flag, the colon-fence lines are plain paragraph text —
        // no directive node.
        let mut plain = Editor::new_str(src, Format::Markdown).expect("editor");
        assert_eq!(plain.query("directive").expect("query").len(), 0);
        // With it enabled, the container directive is recognized.
        let mut ext = Editor::new_ext(
            src.as_bytes(),
            Format::Markdown,
            MarkdownExtensions { directives: true, ..Default::default() },
        )
        .expect("editor");
        assert_eq!(ext.query("directive").expect("query").len(), 1);
    }

    #[test]
    fn editor_filter_public_audience_view() {
        let src = "# Archive\n\n:::vis{.public}\nPublic.\n:::\n\n:::vis{.family}\nPrivate.\n:::\n";
        let mut ed = Editor::new_ext(
            src.as_bytes(),
            Format::Markdown,
            MarkdownExtensions { directives: true, ..Default::default() },
        )
        .expect("editor");
        // Drop every vis block except the public one, then unwrap it.
        ed.filter(
            "directive[name=vis]",
            Some("directive[class~=public]"),
            true,
        )
        .expect("filter");
        assert_eq!(ed.source_str().expect("source"), "# Archive\n\nPublic.\n");
    }

    #[test]
    fn editor_filter_rejects_a_malformed_selector() {
        let mut ed = Editor::new_str("hi\n", Format::Markdown).expect("editor");
        assert_eq!(ed.filter("list >", None, false), Err(Error::InvalidArgument));
    }
}
