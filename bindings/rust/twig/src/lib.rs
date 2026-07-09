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
}

impl From<Format> for ffi::TwigFormat {
    fn from(value: Format) -> Self {
        match value {
            Format::Djot => ffi::TwigFormat::Djot,
            Format::Markdown => ffi::TwigFormat::Markdown,
            Format::Xml => ffi::TwigFormat::Xml,
        }
    }
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

    pub fn render_html(&mut self) -> Result<Vec<u8>, Error> {
        let mut ptr = std::ptr::null();
        let mut len = 0usize;
        let status = unsafe { ffi::twig_document_render_html(self.raw.as_ptr(), &mut ptr, &mut len) };
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

    /// The byte ranges in this document's source that are code, not prose:
    /// inline code spans, fenced/indented code blocks, and raw inline/block
    /// escapes. Meant for filtering a caller's own plain-text scan for
    /// link-like constructs (e.g. a wikilink `[[...]]`) down to the matches
    /// that are not actually inside code.
    pub fn code_spans(&mut self) -> Result<Vec<Range<usize>>, Error> {
        let mut ptr = std::ptr::null();
        let mut len = 0usize;
        let status = unsafe { ffi::twig_document_code_spans(self.raw.as_ptr(), &mut ptr, &mut len) };
        Error::from_status(status)?;
        if len == 0 {
            return Ok(Vec::new());
        }
        if ptr.is_null() {
            return Err(Error::Internal);
        }
        let spans = unsafe { std::slice::from_raw_parts(ptr, len) };
        Ok(spans.iter().map(|s| s.start..s.end).collect())
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
    fn code_spans_cover_verbatim_and_code_blocks_but_not_prose() {
        let source = "prose `code` more prose\n\n```\nblock\n```\n\ntail prose\n";
        let mut doc = Document::parse_str(source, Format::Markdown).expect("parse markdown");
        let spans = doc.code_spans().expect("code spans");

        assert_eq!(spans.len(), 2, "one inline code span, one fenced code block");
        for span in &spans {
            let text = &source[span.clone()];
            assert!(!text.contains("prose"), "span {span:?} unexpectedly covers prose: {text:?}");
        }
        assert!(spans.iter().any(|s| &source[s.clone()] == "`code`"));
    }
}
