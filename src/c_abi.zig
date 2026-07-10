const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const twig = @import("root.zig");

const Allocator = std.mem.Allocator;
pub const TwigStatus = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    parse_error = 2,
    out_of_memory = 3,
    unsupported_format = 4,
    /// A locator resolved to no node (an out-of-bounds index path, or a
    /// selector with zero matches). Editor-only.
    not_found = 5,
    /// A selector locator matched more than one node, so the intended target
    /// is ambiguous — refine it, add `:nth(k)`, or use an index path.
    /// Editor-only.
    ambiguous = 6,
    /// The target node has no editable span/interior: a leaf given to
    /// `replace_content`, or a node whose kind the parser doesn't span yet
    /// (e.g. some Markdown inline nodes). Editor-only.
    not_editable = 7,
    /// The edit produced a document that no longer parses; it was rolled back
    /// and nothing changed. Editor-only.
    edit_conflict = 8,
    internal_error = 255,
};

pub const TwigFormat = enum(c_int) {
    djot = 1,
    markdown = 2,
    xml = 3,
    html = 4,
};

/// A byte range `[start, end)` into the source, C-ABI shape of `Span`. Used by
/// `twig_document_query` for each matched node's whole extent (`span`) and
/// interior (`content_span`).
pub const TwigSpan = extern struct {
    start: usize,
    end: usize,
};

/// One node matched by `twig_document_query`, the C-ABI shape of
/// `Select.Match` plus the node's kind name. `content_span` is only
/// meaningful when `has_content_span` is non-zero (a leaf, or a container the
/// parser left without a known interior, reports `has_content_span == 0` and
/// a zeroed `content_span`). `kind` is a NUL-terminated `Node.Kind` tag name
/// (e.g. `"heading"`, `"code_block"`) in static, library-owned storage — it
/// is never freed and stays valid for the process lifetime.
pub const TwigQueryMatch = extern struct {
    node_id: u32,
    span: TwigSpan,
    content_span: TwigSpan,
    has_content_span: c_int,
    kind: [*:0]const u8,
};

pub const TwigDocument = opaque {};

const ParsedDocument = union(TwigFormat) {
    djot: twig.Djot.Document,
    markdown: twig.Markdown.Document,
    xml: twig.AST,
    html: twig.AST,

    fn deinit(self: *ParsedDocument) void {
        switch (self.*) {
            .djot => |*doc| doc.deinit(),
            .markdown => |*doc| doc.deinit(),
            .xml => |*ast| ast.deinit(),
            .html => |*ast| ast.deinit(),
        }
    }
};

/// A parsed document plus the caller-borrowed output buffers each accessor
/// caches on it. Every buffer follows the same contract: it is owned by the
/// handle, replaced on the next call to the same accessor, and freed when the
/// handle is destroyed — so a pointer handed out stays valid until the next
/// same-accessor call on this handle or `twig_document_destroy`, whichever
/// comes first. The buffers are independent: rendering HTML never invalidates
/// a serialize/ast-json/query result and vice versa.
const DocumentHandle = struct {
    parsed: ParsedDocument,
    rendered: []u8 = &.{},
    serialized: []u8 = &.{},
    ast_json: []u8 = &.{},
    query_matches: []TwigQueryMatch = &.{},
};

fn activeAllocator() Allocator {
    return if (builtin.cpu.arch.isWasm())
        std.heap.wasm_allocator
    else
        std.heap.c_allocator;
}

fn asHandle(doc: *TwigDocument) *DocumentHandle {
    return @ptrCast(@alignCast(doc));
}

fn sliceOf(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (ptr) |p| return p[0..len];
    if (len == 0) return &.{};
    return null;
}

/// Map a raw `int` format code to a `TwigFormat`, or `null` if it names no
/// known format (the caller turns that into `unsupported_format`).
fn intToFormat(format: c_int) ?TwigFormat {
    return switch (format) {
        @intFromEnum(TwigFormat.djot) => .djot,
        @intFromEnum(TwigFormat.markdown) => .markdown,
        @intFromEnum(TwigFormat.xml) => .xml,
        @intFromEnum(TwigFormat.html) => .html,
        else => null,
    };
}

pub export fn twig_version() u32 {
    return (@as(u32, build_options.version_major) << 16) |
        (@as(u32, build_options.version_minor) << 8) |
        @as(u32, build_options.version_patch);
}

pub export fn twig_version_string() [*:0]const u8 {
    const s = std.fmt.comptimePrint("{d}.{d}.{d}", .{
        build_options.version_major,
        build_options.version_minor,
        build_options.version_patch,
    });
    return s;
}

pub export fn twig_parse(
    input_ptr: ?[*]const u8,
    input_len: usize,
    format: c_int,
    out_doc: ?*?*TwigDocument,
) TwigStatus {
    const out = out_doc orelse return .invalid_argument;
    out.* = null;
    const source = sliceOf(input_ptr, input_len) orelse return .invalid_argument;
    const target = intToFormat(format) orelse return .unsupported_format;

    const allocator = activeAllocator();
    const parsed: ParsedDocument = switch (target) {
        .djot => .{
            .djot = twig.Djot.parse(allocator, source) catch |err| switch (err) {
                error.OutOfMemory => return .out_of_memory,
            },
        },
        .markdown => .{
            .markdown = twig.Markdown.parse(allocator, source, .{}) catch |err| switch (err) {
                error.OutOfMemory => return .out_of_memory,
            },
        },
        .xml => .{
            .xml = twig.Xml.parse(allocator, source) catch |err| switch (err) {
                error.OutOfMemory => return .out_of_memory,
                else => return .parse_error,
            },
        },
        .html => .{
            .html = twig.Html.parse(allocator, source) catch |err| switch (err) {
                error.OutOfMemory => return .out_of_memory,
            },
        },
    };

    const handle = allocator.create(DocumentHandle) catch return .out_of_memory;
    handle.* = .{ .parsed = parsed };
    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn twig_document_destroy(doc: ?*TwigDocument) void {
    const raw = doc orelse return;
    const allocator = activeAllocator();
    const handle = asHandle(raw);
    if (handle.rendered.len != 0) allocator.free(handle.rendered);
    if (handle.serialized.len != 0) allocator.free(handle.serialized);
    if (handle.ast_json.len != 0) allocator.free(handle.ast_json);
    if (handle.query_matches.len != 0) allocator.free(handle.query_matches);
    handle.parsed.deinit();
    allocator.destroy(handle);
}

/// The shared `AST` underlying a parsed document, regardless of which
/// language produced it — `Djot.Document`/`Markdown.Document` wrap it
/// alongside their own side tables, `Xml.parse`/`Html.parse` return it bare.
fn astOf(parsed: *const ParsedDocument) *const twig.AST {
    return switch (parsed.*) {
        .djot => |*doc| &doc.ast,
        .markdown => |*doc| &doc.ast,
        .xml => |*ast| ast,
        .html => |*ast| ast,
    };
}

fn renderHtml(allocator: Allocator, parsed: *const ParsedDocument) Allocator.Error![]u8 {
    return switch (parsed.*) {
        .djot => |*doc| twig.Djot.html.renderAlloc(allocator, doc, .{}),
        .markdown => |*doc| twig.Markdown.html.renderAlloc(allocator, doc, .{}),
        .xml => |*ast| twig.Html.serializeAlloc(allocator, ast, null),
        .html => |*ast| twig.Html.serializeAlloc(allocator, ast, null),
    };
}

pub export fn twig_document_render_html(
    doc: ?*TwigDocument,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const raw = doc orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;

    const allocator = activeAllocator();
    const handle = asHandle(raw);

    const rendered = renderHtml(allocator, &handle.parsed) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
    };

    if (handle.rendered.len != 0) allocator.free(handle.rendered);
    handle.rendered = rendered;

    ptr_out.* = if (rendered.len == 0) null else rendered.ptr;
    len_out.* = rendered.len;
    return .ok;
}

/// Serialize `parsed` as `target`'s own source syntax, mirroring
/// `twig convert`'s two paths (see `cli/actions.zig`'s `convertSource`):
///   - `target` == the document's own format: round-trip through that
///     format's `Document`-aware canonical serializer, which resolves djot/
///     Markdown reference/footnote side tables.
///   - `target` != it: cross-format conversion through the target's bare-`AST`
///     serializer (`serializeAstAlloc`), which rebuilds any side tables it
///     needs from the tree alone.
/// Returns `null` when `target` has no serializer for the requested direction
/// (today: converting *into* XML from another format — XML's serializer only
/// understands the generic-markup kinds its own parser produces), which the
/// caller turns into `unsupported_format`.
fn serializeDocument(
    allocator: Allocator,
    parsed: *const ParsedDocument,
    target: TwigFormat,
) Allocator.Error!?[]u8 {
    if (std.meta.activeTag(parsed.*) == target) {
        return switch (parsed.*) {
            .djot => |*doc| try twig.Djot.serializer.serializeAlloc(allocator, doc),
            .markdown => |*doc| try twig.Markdown.serializer.serializeAlloc(allocator, doc),
            .xml => |*ast| try twig.Xml.serializeAlloc(allocator, ast),
            .html => |*ast| try twig.Html.serializeAlloc(allocator, ast, null),
        };
    }

    const ast = astOf(parsed);
    return switch (target) {
        .djot => try twig.Djot.serializer.serializeAstAlloc(allocator, ast),
        .markdown => try twig.Markdown.serializer.serializeAstAlloc(allocator, ast),
        // The generic HTML printer renders the full shared vocabulary from a
        // bare AST, so cross-format-to-HTML works from any source (this is the
        // side-table-free path; `twig_document_render_html` is the richer
        // djot/Markdown HTML rendering).
        .html => try twig.Html.serializeAlloc(allocator, ast, null),
        // No cross-format serializer into XML — see this function's doc comment.
        .xml => null,
    };
}

/// Serialize a parsed document to `format`'s own source syntax (round-trip
/// when `format` matches the document's own format, cross-format conversion
/// otherwise).
///
/// The returned bytes are borrowed from `doc` and remain valid until the next
/// `twig_document_serialize` call on that same handle, or until the handle is
/// destroyed.
pub export fn twig_document_serialize(
    doc: ?*TwigDocument,
    format: c_int,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const raw = doc orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const target = intToFormat(format) orelse return .unsupported_format;

    const allocator = activeAllocator();
    const handle = asHandle(raw);

    const serialized = (serializeDocument(allocator, &handle.parsed, target) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
    }) orelse return .unsupported_format;

    if (handle.serialized.len != 0) allocator.free(handle.serialized);
    handle.serialized = serialized;

    ptr_out.* = if (serialized.len == 0) null else serialized.ptr;
    len_out.* = serialized.len;
    return .ok;
}

/// Encode a parsed document's shared `AST` as pretty-printed JSON — the same
/// stable encoding `twig convert -o ast` produces (see `ast/json.zig`).
///
/// The returned bytes are borrowed from `doc` and remain valid until the next
/// `twig_document_ast_json` call on that same handle, or until the handle is
/// destroyed.
pub export fn twig_document_ast_json(
    doc: ?*TwigDocument,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const raw = doc orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;

    const allocator = activeAllocator();
    const handle = asHandle(raw);

    const json = twig.ast_json.encodeAlloc(allocator, astOf(&handle.parsed)) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
    };

    if (handle.ast_json.len != 0) allocator.free(handle.ast_json);
    handle.ast_json = json;

    ptr_out.* = if (json.len == 0) null else json.ptr;
    len_out.* = json.len;
    return .ok;
}

/// Resolve a CSS-lite selector (see `ast/select.zig` for the grammar — e.g.
/// `heading[level=2]`, `link[dest^="http"]`, `code`, `list > item`) against a
/// parsed document and return one `TwigQueryMatch` per matching node, in
/// document order. This is the general replacement for the old bespoke
/// code-span scan: a `code` / `verbatim` / `raw_block` / `raw_inline` selector
/// recovers those spans, and every other node kind is reachable too.
///
/// A malformed selector returns `invalid_argument`. The returned matches are
/// borrowed from `doc` and remain valid until the next `twig_document_query`
/// call on that same handle, or until the handle is destroyed.
pub export fn twig_document_query(
    doc: ?*TwigDocument,
    selector_ptr: ?[*]const u8,
    selector_len: usize,
    out_ptr: ?*?[*]const TwigQueryMatch,
    out_len: ?*usize,
) TwigStatus {
    const raw = doc orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const selector_src = sliceOf(selector_ptr, selector_len) orelse return .invalid_argument;

    const allocator = activeAllocator();
    const handle = asHandle(raw);

    const out = buildQueryMatches(allocator, astOf(&handle.parsed), selector_src) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.InvalidSelector => return .invalid_argument,
    };

    if (handle.query_matches.len != 0) allocator.free(handle.query_matches);
    handle.query_matches = out;

    ptr_out.* = if (out.len == 0) null else out.ptr;
    len_out.* = out.len;
    return .ok;
}

/// Parse `selector_src`, resolve it against `ast`, and return a freshly
/// allocated `[]TwigQueryMatch` in document order (caller owns it). Shared by
/// `twig_document_query` and `twig_editor_query`.
fn buildQueryMatches(
    allocator: Allocator,
    ast: *const twig.AST,
    selector_src: []const u8,
) error{ OutOfMemory, InvalidSelector }![]TwigQueryMatch {
    var selector = try twig.Select.parse(allocator, selector_src);
    defer selector.deinit();

    const matches = try twig.Select.resolveAll(allocator, ast, &selector);
    defer allocator.free(matches);

    if (matches.len == 0) return &.{};
    const buf = try allocator.alloc(TwigQueryMatch, matches.len);
    for (matches, buf) |m, *slot| {
        slot.* = .{
            .node_id = m.id,
            .span = .{ .start = m.span.start, .end = m.span.end },
            .content_span = if (m.content_span) |cs|
                .{ .start = cs.start, .end = cs.end }
            else
                .{ .start = 0, .end = 0 },
            .has_content_span = if (m.content_span != null) 1 else 0,
            .kind = @tagName(std.meta.activeTag(ast.nodes[m.id].kind)).ptr,
        };
    }
    return buf;
}

// ── Editor ─────────────────────────────────────────────────────────────────
// A separate handle from `TwigDocument`: the span-splice editor
// (`twig.Editor`) owns evolving source bytes plus a bare-AST reparse of them,
// where `TwigDocument` holds a one-shot parse with its language's side tables.
// Editing reparses after every successful edit, so node ids/paths are only
// valid against the tree *as of the last edit* — which is why every op here is
// addressed by a fresh locator string (an index path or a unique selector),
// resolved against the current tree, exactly like `twig edit`.

pub const TwigEditor = opaque {};

const EditorHandle = struct {
    editor: twig.Editor,
    /// Caller-borrowed output buffers, same contract as `DocumentHandle`'s.
    ast_json: []u8 = &.{},
    query_matches: []TwigQueryMatch = &.{},
};

fn asEditor(ed: *TwigEditor) *EditorHandle {
    return @ptrCast(@alignCast(ed));
}

/// The one edit each `twig_editor_*` op performs, dispatched by `applyEdit`
/// onto the matching `twig.Editor` method.
const EditOp = enum { replace, replace_content, insert_before, insert_after, insert_child, delete };

// Per-format `source -> bare AST` reparse callbacks the editor drives. Djot and
// Markdown's `Document` side tables are irrelevant to editing (it only touches
// spans/structure), so these free those maps and hand back the bare `AST`;
// XML/HTML already parse to a bare `AST`. Mirrors `cli/format.zig`'s
// `parseToAst*` adapters.

// The editor reparse callback (`twig.Editor.ParseFn`) takes a leading opaque
// `ctx` for parse configuration; the C ABI exposes no parse options, so these
// adapters ignore it and use each language's default options, and
// `twig_editor_create` hands the editor `&c_abi_parse_ctx` (a stable, unread
// pointer).
const c_abi_parse_ctx: u8 = 0;

fn parseToAstDjot(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!twig.AST {
    _ = ctx;
    var doc = try twig.Djot.parse(allocator, source);
    doc.references.deinit(allocator);
    doc.auto_references.deinit(allocator);
    doc.footnotes.deinit(allocator);
    return doc.ast;
}

fn parseToAstMarkdown(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!twig.AST {
    _ = ctx;
    var doc = try twig.Markdown.parse(allocator, source, .{});
    doc.link_references.deinit(allocator);
    doc.footnotes.deinit(allocator);
    return doc.ast;
}

fn parseToAstXml(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!twig.AST {
    _ = ctx;
    return twig.Xml.parse(allocator, source);
}

fn parseToAstHtml(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!twig.AST {
    _ = ctx;
    return twig.Html.parse(allocator, source);
}

fn parseFnFor(format: TwigFormat) twig.Editor.ParseFn {
    return switch (format) {
        .djot => parseToAstDjot,
        .markdown => parseToAstMarkdown,
        .xml => parseToAstXml,
        .html => parseToAstHtml,
    };
}

/// Create an editor over a private copy of `input`, parsed as `format`. On the
/// initial parse failing, returns `parse_error` (or `out_of_memory`).
pub export fn twig_editor_create(
    input_ptr: ?[*]const u8,
    input_len: usize,
    format: c_int,
    out_editor: ?*?*TwigEditor,
) TwigStatus {
    const out = out_editor orelse return .invalid_argument;
    out.* = null;
    const source = sliceOf(input_ptr, input_len) orelse return .invalid_argument;
    const target = intToFormat(format) orelse return .unsupported_format;

    const allocator = activeAllocator();
    var editor = twig.Editor.init(allocator, source, &c_abi_parse_ctx, parseFnFor(target)) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        else => return .parse_error,
    };

    const handle = allocator.create(EditorHandle) catch {
        editor.deinit();
        return .out_of_memory;
    };
    handle.* = .{ .editor = editor };
    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn twig_editor_destroy(ed: ?*TwigEditor) void {
    const raw = ed orelse return;
    const allocator = activeAllocator();
    const handle = asEditor(raw);
    if (handle.ast_json.len != 0) allocator.free(handle.ast_json);
    if (handle.query_matches.len != 0) allocator.free(handle.query_matches);
    handle.editor.deinit();
    allocator.destroy(handle);
}

const LocatorError = error{ OutOfMemory, InvalidLocator, NotFound, Ambiguous };

/// A locator is an index path when it's made only of digits and dots (so an
/// empty string — the root — counts); anything else is a selector. Mirrors the
/// CLI's `isIndexPath`.
fn isIndexPath(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c) and c != '.') return false;
    return true;
}

fn parsePath(allocator: Allocator, path_str: []const u8) LocatorError![]const usize {
    if (path_str.len == 0) return &.{};
    var list: std.ArrayList(usize) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, path_str, '.');
    while (it.next()) |seg| {
        const n = std.fmt.parseInt(usize, seg, 10) catch return error.InvalidLocator;
        list.append(allocator, n) catch return error.OutOfMemory;
    }
    return list.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// Resolve a locator (index path or unique selector) to a single node id
/// against `ast`, mirroring the CLI's `resolveLocator` but reporting via
/// `LocatorError` instead of printing.
fn resolveLocator(allocator: Allocator, ast: *const twig.AST, locator: []const u8) LocatorError!twig.AST.Node.Id {
    if (isIndexPath(locator)) {
        const path = try parsePath(allocator, locator);
        defer if (path.len > 0) allocator.free(path);
        return ast.getIdByPath(path) catch return error.NotFound;
    }

    var selector = twig.Select.parse(allocator, locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSelector => return error.InvalidLocator,
    };
    defer selector.deinit();

    const matches = try twig.Select.resolveAll(allocator, ast, &selector);
    defer allocator.free(matches);

    if (matches.len == 0) return error.NotFound;
    if (matches.len > 1) return error.Ambiguous;
    return matches[0].id;
}

/// Resolve `locator` against the editor's current tree and apply `op`. Every
/// failure maps to a status: a malformed locator to `invalid_argument`, a
/// resolvable-but-missing one to `not_found`/`ambiguous`, an uneditable target
/// to `not_editable`, and a reparse-breaking edit (rolled back) to
/// `edit_conflict`.
fn applyEdit(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
    op: EditOp,
    child_index: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const locator = sliceOf(locator_ptr, locator_len) orelse return .invalid_argument;
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;

    const allocator = activeAllocator();
    const handle = asEditor(raw);

    const id = resolveLocator(allocator, handle.editor.astView(), locator) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.InvalidLocator => return .invalid_argument,
        error.NotFound => return .not_found,
        error.Ambiguous => return .ambiguous,
    };

    const result = switch (op) {
        .replace => handle.editor.replaceNodeById(id, text),
        .replace_content => handle.editor.replaceContentById(id, text),
        .insert_before => handle.editor.insertBeforeById(id, text),
        .insert_after => handle.editor.insertAfterById(id, text),
        .insert_child => handle.editor.insertChildById(id, child_index, text),
        .delete => handle.editor.deleteNodeById(id),
    };
    result catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.NoNodeSpan, error.NoContentSpan => return .not_editable,
        // Any other error is the parser rejecting the edited document; the
        // editor already rolled the edit back.
        else => return .edit_conflict,
    };
    return .ok;
}

/// Replace the whole source of the located node with `text`.
pub export fn twig_editor_replace(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .replace, 0, text_ptr, text_len);
}

/// Replace the interior (between-delimiters content) of the located container.
pub export fn twig_editor_replace_content(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .replace_content, 0, text_ptr, text_len);
}

/// Insert `text` immediately before the located node.
pub export fn twig_editor_insert_before(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .insert_before, 0, text_ptr, text_len);
}

/// Insert `text` immediately after the located node.
pub export fn twig_editor_insert_after(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .insert_after, 0, text_ptr, text_len);
}

/// Insert `text` as the `child_index`-th child of the located container (past
/// the child count appends).
pub export fn twig_editor_insert_child(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
    child_index: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .insert_child, child_index, text_ptr, text_len);
}

/// Delete the located node (removes exactly its span; no whitespace cleanup).
pub export fn twig_editor_delete(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .delete, 0, null, 0);
}

/// The editor's current (edited) source bytes.
///
/// Unlike the other accessors, these bytes are borrowed directly from the
/// editor and remain valid until the next *successful* edit on this handle (a
/// failed edit leaves them untouched), or until the handle is destroyed.
pub export fn twig_editor_source(
    ed: ?*TwigEditor,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;

    const bytes = asEditor(raw).editor.sourceBytes();
    ptr_out.* = if (bytes.len == 0) null else bytes.ptr;
    len_out.* = bytes.len;
    return .ok;
}

/// Encode the editor's current tree as pretty-printed JSON — the live
/// counterpart of `twig_document_ast_json`, for inspecting the document
/// between edits.
///
/// The returned bytes are borrowed from `ed` and remain valid until the next
/// `twig_editor_ast_json` call on that same handle, or until it is destroyed.
pub export fn twig_editor_ast_json(
    ed: ?*TwigEditor,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;

    const allocator = activeAllocator();
    const handle = asEditor(raw);

    const json = twig.ast_json.encodeAlloc(allocator, handle.editor.astView()) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
    };

    if (handle.ast_json.len != 0) allocator.free(handle.ast_json);
    handle.ast_json = json;

    ptr_out.* = if (json.len == 0) null else json.ptr;
    len_out.* = json.len;
    return .ok;
}

/// Resolve a selector against the editor's current tree — the live counterpart
/// of `twig_document_query`, e.g. to find a node's spans/kind before editing.
///
/// The returned matches are borrowed from `ed` and remain valid until the next
/// `twig_editor_query` call on that same handle, or until it is destroyed.
pub export fn twig_editor_query(
    ed: ?*TwigEditor,
    selector_ptr: ?[*]const u8,
    selector_len: usize,
    out_ptr: ?*?[*]const TwigQueryMatch,
    out_len: ?*usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const selector_src = sliceOf(selector_ptr, selector_len) orelse return .invalid_argument;

    const allocator = activeAllocator();
    const handle = asEditor(raw);

    const out = buildQueryMatches(allocator, handle.editor.astView(), selector_src) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.InvalidSelector => return .invalid_argument,
    };

    if (handle.query_matches.len != 0) allocator.free(handle.query_matches);
    handle.query_matches = out;

    ptr_out.* = if (out.len == 0) null else out.ptr;
    len_out.* = out.len;
    return .ok;
}

test "twig_parse + twig_document_render_html renders markdown" {
    const source = "# hi\n";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.markdown), &doc),
    );
    defer twig_document_destroy(doc);

    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_document_render_html(doc, &ptr, &len));
    try std.testing.expectEqualStrings("<h1>hi</h1>\n", ptr.?[0..len]);
}

test "twig_parse accepts HTML input" {
    const source = "<p>hi</p>";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.html), &doc),
    );
    defer twig_document_destroy(doc);

    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_document_render_html(doc, &ptr, &len));
    try std.testing.expect(std.mem.indexOf(u8, ptr.?[0..len], "hi") != null);
}

test "twig_parse rejects an unknown format code" {
    const source = "x";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.unsupported_format,
        twig_parse(source.ptr, source.len, 99, &doc),
    );
    try std.testing.expectEqual(@as(?*TwigDocument, null), doc);
}

test "twig_document_serialize round-trips markdown and rejects xml-target cross-conversion" {
    const source = "# hi\n";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.markdown), &doc),
    );
    defer twig_document_destroy(doc);

    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_document_serialize(doc, @intFromEnum(TwigFormat.markdown), &ptr, &len),
    );
    try std.testing.expect(std.mem.indexOf(u8, ptr.?[0..len], "# hi") != null);

    // Markdown -> XML has no serializer (see `serializeDocument`).
    try std.testing.expectEqual(
        TwigStatus.unsupported_format,
        twig_document_serialize(doc, @intFromEnum(TwigFormat.xml), &ptr, &len),
    );
}

test "twig_document_serialize cross-converts markdown to djot" {
    const source = "This is *markdown*.\n";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.markdown), &doc),
    );
    defer twig_document_destroy(doc);

    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_document_serialize(doc, @intFromEnum(TwigFormat.djot), &ptr, &len),
    );
    // Markdown `*markdown*` (emphasis) renders djot-style with underscores.
    try std.testing.expect(std.mem.indexOf(u8, ptr.?[0..len], "_markdown_") != null);
}

test "twig_document_ast_json dumps the shared AST as JSON" {
    const source = "hello\n";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.djot), &doc),
    );
    defer twig_document_destroy(doc);

    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_document_ast_json(doc, &ptr, &len));
    try std.testing.expect(std.mem.indexOf(u8, ptr.?[0..len], "\"kind\": \"doc\"") != null);
}

test "twig_document_query finds nodes by selector and reports kind + spans" {
    const source = "See `x` and\n\n```\nblock\n```\n\nprose\n";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.markdown), &doc),
    );
    defer twig_document_destroy(doc);

    // The inline code span (`verbatim`) recovers what the old code-span scan did.
    const selector = "verbatim";
    var ptr: ?[*]const TwigQueryMatch = null;
    var len: usize = 0;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_document_query(doc, selector.ptr, selector.len, &ptr, &len),
    );
    try std.testing.expect(len == 1);

    const m = ptr.?[0];
    try std.testing.expectEqualStrings("verbatim", std.mem.span(m.kind));
    try std.testing.expect(m.span.start < m.span.end);
    // The matched span is `x`, not the surrounding prose.
    try std.testing.expect(!std.mem.containsAtLeast(u8, source[m.span.start..m.span.end], 1, "prose"));
}

test "twig_document_query rejects a malformed selector" {
    const source = "hi\n";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.markdown), &doc),
    );
    defer twig_document_destroy(doc);

    const bad = "list >";
    var ptr: ?[*]const TwigQueryMatch = null;
    var len: usize = 0;
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_document_query(doc, bad.ptr, bad.len, &ptr, &len),
    );
}

// ── editor tests ────────────────────────────────────────────────────────────
// XML is the vehicle (real spans + `content_span`, and the only language that
// can fail to parse — exercising rollback), matching `ast/editor.zig`'s tests.

const EditorFixture = struct {
    ed: *TwigEditor,

    fn init(source: [:0]const u8) !EditorFixture {
        return initFmt(source, .xml);
    }

    fn initFmt(source: [:0]const u8, format: TwigFormat) !EditorFixture {
        var ed: ?*TwigEditor = null;
        try std.testing.expectEqual(
            TwigStatus.ok,
            twig_editor_create(source.ptr, source.len, @intFromEnum(format), &ed),
        );
        return .{ .ed = ed.? };
    }

    fn deinit(self: *EditorFixture) void {
        twig_editor_destroy(self.ed);
    }

    fn expectSource(self: *EditorFixture, expected: []const u8) !void {
        var ptr: ?[*]const u8 = null;
        var len: usize = 0;
        try std.testing.expectEqual(TwigStatus.ok, twig_editor_source(self.ed, &ptr, &len));
        try std.testing.expectEqualStrings(expected, if (len == 0) "" else ptr.?[0..len]);
    }
};

test "twig_editor: replace_content by index path, losslessly" {
    var fx = try EditorFixture.init("<a><b>hi</b></a>");
    defer fx.deinit();

    const path = "0.0";
    const text = "bye";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_replace_content(fx.ed, path.ptr, path.len, text.ptr, text.len),
    );
    try fx.expectSource("<a><b>bye</b></a>");
}

test "twig_editor: insert_child by index and delete" {
    var fx = try EditorFixture.init("<r><a/><c/></r>");
    defer fx.deinit();

    const root = "0";
    const b = "<b/>";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_insert_child(fx.ed, root.ptr, root.len, 1, b.ptr, b.len),
    );
    try fx.expectSource("<r><a/><b/><c/></r>");

    // Delete the node now at path 0.1 (the freshly inserted <b/>).
    const b_path = "0.1";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_delete(fx.ed, b_path.ptr, b_path.len),
    );
    try fx.expectSource("<r><a/><c/></r>");
}

test "twig_editor: insert_before / insert_after" {
    var fx = try EditorFixture.init("<r><a/></r>");
    defer fx.deinit();

    const a = "0.0";
    const x = "<x/>";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_insert_after(fx.ed, a.ptr, a.len, x.ptr, x.len),
    );
    try fx.expectSource("<r><a/><x/></r>");

    const a2 = "0.0";
    const y = "<y/>";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_insert_before(fx.ed, a2.ptr, a2.len, y.ptr, y.len),
    );
    try fx.expectSource("<r><y/><a/><x/></r>");
}

test "twig_editor: a selector locator resolves and edits the target node" {
    var fx = try EditorFixture.initFmt("# One\n\n## Two\n", .markdown);
    defer fx.deinit();

    // Address the second heading by its text instead of a path. (`doc` also
    // contains "Two", but it isn't a `heading`, so the match is unambiguous.)
    const sel = "heading(\"Two\")";
    const text = "## Renamed";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_replace(fx.ed, sel.ptr, sel.len, text.ptr, text.len),
    );
    try fx.expectSource("# One\n\n## Renamed\n");
}

test "twig_editor: locator errors map to distinct statuses" {
    var fx = try EditorFixture.init("<r><a/><a/></r>");
    defer fx.deinit();

    const text = "x";

    // No node at this path.
    const oob = "0.9";
    try std.testing.expectEqual(
        TwigStatus.not_found,
        twig_editor_replace(fx.ed, oob.ptr, oob.len, text.ptr, text.len),
    );

    // Two <a> elements match -> ambiguous.
    const amb = "element";
    try std.testing.expectEqual(
        TwigStatus.ambiguous,
        twig_editor_replace(fx.ed, amb.ptr, amb.len, text.ptr, text.len),
    );

    // Malformed selector.
    const bad = "element(";
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_editor_replace(fx.ed, bad.ptr, bad.len, text.ptr, text.len),
    );

    // Document is untouched by the failed edits.
    try fx.expectSource("<r><a/><a/></r>");
}

test "twig_editor: a reparse-breaking edit rolls back as edit_conflict" {
    var fx = try EditorFixture.init("<a>ok</a>");
    defer fx.deinit();

    // Replacing <a>'s interior with "<b>" makes `<a><b></a>` — malformed.
    const root = "0";
    const broken = "<b>";
    try std.testing.expectEqual(
        TwigStatus.edit_conflict,
        twig_editor_replace_content(fx.ed, root.ptr, root.len, broken.ptr, broken.len),
    );
    try fx.expectSource("<a>ok</a>");
}

test "twig_editor: replace_content on a leaf is not_editable" {
    var fx = try EditorFixture.init("<a>hi</a>");
    defer fx.deinit();

    // Path 0.0 is the "hi" text node, a leaf: no interior to splice.
    const leaf = "0.0";
    const text = "x";
    try std.testing.expectEqual(
        TwigStatus.not_editable,
        twig_editor_replace_content(fx.ed, leaf.ptr, leaf.len, text.ptr, text.len),
    );
}

test "twig_editor: ast_json and query reflect the current tree" {
    var fx = try EditorFixture.init("<r><a/></r>");
    defer fx.deinit();

    // Insert a second element, then confirm a query sees both.
    const root = "0";
    const b = "<b/>";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_insert_child(fx.ed, root.ptr, root.len, 1, b.ptr, b.len),
    );

    // Three elements now: the root <r> plus <a/> and <b/>.
    const sel = "element";
    var qptr: ?[*]const TwigQueryMatch = null;
    var qlen: usize = 0;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_query(fx.ed, sel.ptr, sel.len, &qptr, &qlen),
    );
    try std.testing.expect(qlen == 3);

    var jptr: ?[*]const u8 = null;
    var jlen: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_editor_ast_json(fx.ed, &jptr, &jlen));
    try std.testing.expect(std.mem.indexOf(u8, jptr.?[0..jlen], "\"kind\": \"doc\"") != null);
}
