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
    pub const UNSAFE_METADATA: c_int = 9;
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

pub enum TwigBuilder {}

/// C ABI mirror of Zig's `TwigKeyVal` — one attribute pair for
/// `twig_builder_set_attrs`. A NULL `value` is a bare attribute.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigKeyVal {
    pub key: *const u8,
    pub key_len: usize,
    pub value: *const u8,
    pub value_len: usize,
}

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

/// The sentinel `node_id` for "no such node" in a [`TwigFlatNode`] link field.
pub const TWIG_NO_NODE: u32 = u32::MAX;

/// C ABI mirror of Zig's `TwigChange` — the byte effect of an edit. `old_span`
/// is the replaced range in the pre-edit source; `new_span` is the range the
/// replacement occupies in the post-edit source (same start).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigChange {
    pub old_span: TwigSpan,
    pub new_span: TwigSpan,
}

/// C ABI mirror of Zig's `TwigFlatNode` — one node of the editor's flat tree
/// snapshot. Link fields (`parent`/`first_child`/`next_sibling`) are ids or
/// [`TWIG_NO_NODE`]. `content_span` is meaningful only when `has_content_span`.
/// `kind` is static, library-owned storage; `text`/`destination` pointers
/// borrow the current parse's payloads (NULL when the kind carries none).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigFlatNode {
    pub id: u32,
    pub parent: u32,
    pub first_child: u32,
    pub next_sibling: u32,
    pub span: TwigSpan,
    pub content_span: TwigSpan,
    pub has_content_span: c_int,
    pub level: u32,
    pub kind: *const c_char,
    pub text_ptr: *const u8,
    pub text_len: usize,
    pub destination_ptr: *const u8,
    pub destination_len: usize,
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
    pub fn twig_editor_edit_range(
        editor: *mut TwigEditor,
        start: usize,
        end: usize,
        text: *const u8,
        text_len: usize,
        out_change: *mut TwigChange,
    ) -> TwigStatus;
    pub fn twig_editor_last_change(
        editor: *mut TwigEditor,
        out_change: *mut TwigChange,
    ) -> TwigStatus;
    pub fn twig_editor_nodes(
        editor: *mut TwigEditor,
        out_ptr: *mut *const TwigFlatNode,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_editor_node_at(
        editor: *mut TwigEditor,
        offset: usize,
        out_match: *mut TwigQueryMatch,
    ) -> TwigStatus;
    pub fn twig_editor_nodes_at(
        editor: *mut TwigEditor,
        offset: usize,
        out_ptr: *mut *const TwigQueryMatch,
        out_len: *mut usize,
    ) -> TwigStatus;

    pub fn twig_builder_create(out_builder: *mut *mut TwigBuilder) -> TwigStatus;
    pub fn twig_builder_destroy(builder: *mut TwigBuilder);
    pub fn twig_builder_add(builder: *mut TwigBuilder, kind: c_int, out_id: *mut u32) -> TwigStatus;
    pub fn twig_builder_add_text(
        builder: *mut TwigBuilder,
        kind: c_int,
        text: *const u8,
        text_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_heading(builder: *mut TwigBuilder, level: u32, out_id: *mut u32) -> TwigStatus;
    pub fn twig_builder_add_code_block(
        builder: *mut TwigBuilder,
        lang: *const u8,
        lang_len: usize,
        has_lang: c_int,
        text: *const u8,
        text_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_raw_block(
        builder: *mut TwigBuilder,
        format: *const u8,
        format_len: usize,
        text: *const u8,
        text_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_metadata(
        builder: *mut TwigBuilder,
        lang: *const u8,
        lang_len: usize,
        text: *const u8,
        text_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_raw_inline(
        builder: *mut TwigBuilder,
        format: *const u8,
        format_len: usize,
        text: *const u8,
        text_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_smart_punctuation(
        builder: *mut TwigBuilder,
        punct_kind: c_int,
        text: *const u8,
        text_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_link(
        builder: *mut TwigBuilder,
        destination: *const u8,
        destination_len: usize,
        has_destination: c_int,
        reference: *const u8,
        reference_len: usize,
        has_reference: c_int,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_image(
        builder: *mut TwigBuilder,
        destination: *const u8,
        destination_len: usize,
        has_destination: c_int,
        reference: *const u8,
        reference_len: usize,
        has_reference: c_int,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_directive(
        builder: *mut TwigBuilder,
        form: c_int,
        name: *const u8,
        name_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_element(
        builder: *mut TwigBuilder,
        name: *const u8,
        name_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_processing_instruction(
        builder: *mut TwigBuilder,
        target: *const u8,
        target_len: usize,
        data: *const u8,
        data_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_footnote(
        builder: *mut TwigBuilder,
        label: *const u8,
        label_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_reference(
        builder: *mut TwigBuilder,
        label: *const u8,
        label_len: usize,
        destination: *const u8,
        destination_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_bullet_list(
        builder: *mut TwigBuilder,
        style: c_int,
        tight: c_int,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_ordered_list(
        builder: *mut TwigBuilder,
        numbering: c_int,
        delim: c_int,
        tight: c_int,
        start: u32,
        has_start: c_int,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_task_list(builder: *mut TwigBuilder, tight: c_int, out_id: *mut u32) -> TwigStatus;
    pub fn twig_builder_add_task_list_item(builder: *mut TwigBuilder, checked: c_int, out_id: *mut u32) -> TwigStatus;
    pub fn twig_builder_add_row(builder: *mut TwigBuilder, head: c_int, out_id: *mut u32) -> TwigStatus;
    pub fn twig_builder_add_cell(builder: *mut TwigBuilder, head: c_int, alignment: c_int, out_id: *mut u32) -> TwigStatus;
    pub fn twig_builder_set_children(
        builder: *mut TwigBuilder,
        parent: u32,
        ids: *const u32,
        ids_len: usize,
    ) -> TwigStatus;
    pub fn twig_builder_set_attrs(
        builder: *mut TwigBuilder,
        id: u32,
        kvs: *const TwigKeyVal,
        kvs_len: usize,
    ) -> TwigStatus;
    pub fn twig_builder_render_html(
        builder: *mut TwigBuilder,
        root: u32,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_builder_serialize(
        builder: *mut TwigBuilder,
        root: u32,
        format: c_int,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_builder_ast_json(
        builder: *mut TwigBuilder,
        root: u32,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_builder_query(
        builder: *mut TwigBuilder,
        root: u32,
        selector: *const u8,
        selector_len: usize,
        out_ptr: *mut *const TwigQueryMatch,
        out_len: *mut usize,
    ) -> TwigStatus;
}
