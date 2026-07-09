mod error;
mod ffi;

use std::ptr::NonNull;

pub use error::Error;

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
}
