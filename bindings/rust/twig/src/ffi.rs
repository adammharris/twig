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
    pub const NOT_FOUND: c_int = 5;
    pub const AMBIGUOUS: c_int = 6;
    pub const NOT_EDITABLE: c_int = 7;
    pub const EDIT_CONFLICT: c_int = 8;
    pub const INTERNAL_ERROR: c_int = 255;
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TwigFormat {
    Djot = 1,
    Markdown = 2,
    Xml = 3,
    Html = 4,
}

/// Markdown extension flags for `twig_editor_create_ext`'s `md_flags` bitmask.
pub const TWIG_MD_DIRECTIVES: u32 = 1 << 0;
pub const TWIG_MD_MATH: u32 = 1 << 1;

pub enum TwigDocument {}

pub enum TwigEditor {}

/// C ABI mirror of Zig's `TwigSpan` — a byte range `[start, end)`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TwigSpan {
    pub start: usize,
    pub end: usize,
}

/// C ABI mirror of Zig's `TwigQueryMatch` — one node returned by
/// `twig_document_query`. `content_span` is only meaningful when
/// `has_content_span` is non-zero. `kind` is a NUL-terminated node-kind name
/// in static, library-owned storage (never freed).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigQueryMatch {
    pub node_id: u32,
    pub span: TwigSpan,
    pub content_span: TwigSpan,
    pub has_content_span: c_int,
    pub kind: *const c_char,
}

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
    pub fn twig_document_serialize(
        doc: *mut TwigDocument,
        format: c_int,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_document_ast_json(
        doc: *mut TwigDocument,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_document_query(
        doc: *mut TwigDocument,
        selector: *const u8,
        selector_len: usize,
        out_ptr: *mut *const TwigQueryMatch,
        out_len: *mut usize,
    ) -> TwigStatus;

    pub fn twig_editor_create(
        input: *const u8,
        input_len: usize,
        format: c_int,
        out_editor: *mut *mut TwigEditor,
    ) -> TwigStatus;
    pub fn twig_editor_create_ext(
        input: *const u8,
        input_len: usize,
        format: c_int,
        md_flags: u32,
        out_editor: *mut *mut TwigEditor,
    ) -> TwigStatus;
    pub fn twig_editor_destroy(editor: *mut TwigEditor);
    pub fn twig_editor_replace(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
        text: *const u8,
        text_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_replace_content(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
        text: *const u8,
        text_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_insert_before(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
        text: *const u8,
        text_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_insert_after(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
        text: *const u8,
        text_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_insert_child(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
        child_index: usize,
        text: *const u8,
        text_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_delete(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_delete_smart(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_unwrap(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_filter(
        editor: *mut TwigEditor,
        drop: *const u8,
        drop_len: usize,
        keep: *const u8,
        keep_len: usize,
        unwrap_kept: c_int,
    ) -> TwigStatus;
    pub fn twig_editor_source(
        editor: *mut TwigEditor,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_editor_ast_json(
        editor: *mut TwigEditor,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_editor_query(
        editor: *mut TwigEditor,
        selector: *const u8,
        selector_len: usize,
        out_ptr: *mut *const TwigQueryMatch,
        out_len: *mut usize,
    ) -> TwigStatus;
}
