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
    const ast = astOf(&handle.parsed);

    var selector = twig.Select.parse(allocator, selector_src) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.InvalidSelector => return .invalid_argument,
    };
    defer selector.deinit();

    const matches = twig.Select.resolveAll(allocator, ast, &selector) catch return .out_of_memory;
    defer allocator.free(matches);

    const out: []TwigQueryMatch = if (matches.len == 0) &.{} else blk: {
        const buf = allocator.alloc(TwigQueryMatch, matches.len) catch return .out_of_memory;
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
        break :blk buf;
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
