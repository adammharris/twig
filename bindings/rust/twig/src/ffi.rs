use std::os::raw::{c_char, c_int};

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TwigStatus(pub c_int);

#[allow(dead_code)]
impl TwigStatus {
    pub const OK: c_int = 0;
    pub const INVALID_ARGUMENT: c_int = 1;
    pub const PARSE_ERROR: c_int = 2;
    pub const OUT_OF_MEMORY: c_int = 3;
    pub const UNSUPPORTED_FORMAT: c_int = 4;
    pub const INTERNAL_ERROR: c_int = 255;
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TwigFormat {
    Djot = 1,
    Markdown = 2,
    Xml = 3,
}

pub enum TwigDocument {}

unsafe extern "C" {
    pub fn twig_version() -> u32;
    pub fn twig_version_string() -> *const c_char;
    pub fn twig_parse(
        input: *const u8,
        input_len: usize,
        format: c_int,
        out_doc: *mut *mut TwigDocument,
    ) -> TwigStatus;
    pub fn twig_document_destroy(doc: *mut TwigDocument);
    pub fn twig_document_render_html(
        doc: *mut TwigDocument,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
}
