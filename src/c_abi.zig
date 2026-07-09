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
};

/// A byte range `[start, end)` into the source, C-ABI shape of `Span`.
/// Used by `twig_document_code_spans` — one entry per code-like node
/// (`verbatim`/`code_block`/`raw_inline`/`raw_block`), so a caller doing its
/// own lightweight text scan (e.g. for a wikilink-style construct the AST
/// itself doesn't know about) can tell which matches fall inside code and
/// should not be treated as prose.
pub const TwigSpan = extern struct {
    start: usize,
    end: usize,
};

pub const TwigDocument = opaque {};

const ParsedDocument = union(TwigFormat) {
    djot: twig.Djot.Document,
    markdown: twig.Markdown.Document,
    xml: twig.AST,

    fn deinit(self: *ParsedDocument) void {
        switch (self.*) {
            .djot => |*doc| doc.deinit(),
            .markdown => |*doc| doc.deinit(),
            .xml => |*ast| ast.deinit(),
        }
    }
};

const DocumentHandle = struct {
    parsed: ParsedDocument,
    rendered: []u8 = &.{},
    code_spans: []TwigSpan = &.{},
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

    const parsed: ParsedDocument = switch (format) {
        @intFromEnum(TwigFormat.djot) => .{
            .djot = twig.Djot.parse(activeAllocator(), source) catch |err| switch (err) {
                error.OutOfMemory => return .out_of_memory,
            },
        },
        @intFromEnum(TwigFormat.markdown) => .{
            .markdown = twig.Markdown.parse(activeAllocator(), source, .{}) catch |err| switch (err) {
                error.OutOfMemory => return .out_of_memory,
            },
        },
        @intFromEnum(TwigFormat.xml) => .{
            .xml = twig.Xml.parse(activeAllocator(), source) catch |err| switch (err) {
                error.OutOfMemory => return .out_of_memory,
                else => return .parse_error,
            },
        },
        else => return .unsupported_format,
    };

    const allocator = activeAllocator();
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
    if (handle.code_spans.len != 0) allocator.free(handle.code_spans);
    handle.parsed.deinit();
    allocator.destroy(handle);
}

fn renderHtml(allocator: Allocator, parsed: *const ParsedDocument) Allocator.Error![]u8 {
    return switch (parsed.*) {
        .djot => |*doc| twig.Djot.html.renderAlloc(allocator, doc, .{}),
        .markdown => |*doc| twig.Markdown.html.renderAlloc(allocator, doc, .{}),
        .xml => |*ast| twig.Html.serializeAlloc(allocator, ast, null),
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

/// The shared `AST` underlying a parsed document, regardless of which
/// language produced it — `Djot.Document`/`Markdown.Document` wrap it
/// alongside their own side tables, `Xml.parse` returns it bare.
fn astOf(parsed: *const ParsedDocument) *const twig.AST {
    return switch (parsed.*) {
        .djot => |*doc| &doc.ast,
        .markdown => |*doc| &doc.ast,
        .xml => |*ast| ast,
    };
}

/// AST node kinds that hold verbatim/raw source text rather than parsed
/// prose: inline code spans, fenced/indented code blocks, and raw inline/
/// block escapes (e.g. Markdown's raw HTML passthrough). A link-like
/// construct spotted inside one of these by a plain text scan is not a real
/// link — see `twig_document_code_spans`.
fn isCodeKind(kind: twig.AST.Node.Kind) bool {
    return switch (kind) {
        .verbatim, .code_block, .raw_inline, .raw_block => true,
        else => false,
    };
}

/// Collect one `TwigSpan` per code-like node in `ast`, in arena order (which
/// is source order for how every parser here builds nodes). A flat scan over
/// `ast.nodes` rather than a tree walk — the arena already holds every node
/// regardless of nesting, and callers only want spans, not structure.
fn collectCodeSpans(allocator: Allocator, ast: *const twig.AST) Allocator.Error![]TwigSpan {
    var list: std.ArrayList(TwigSpan) = .empty;
    errdefer list.deinit(allocator);
    for (ast.nodes) |node| {
        if (isCodeKind(node.kind)) {
            try list.append(allocator, .{ .start = node.span.start, .end = node.span.end });
        }
    }
    return list.toOwnedSlice(allocator);
}

/// The byte ranges in `doc`'s source that are code, not prose (see
/// `isCodeKind`) — everything a plain-text link scan should treat as opaque.
///
/// The returned spans are borrowed from `doc` and remain valid until the
/// next `twig_document_code_spans` call on that same handle, or until the
/// handle is destroyed (same contract as `twig_document_render_html`).
pub export fn twig_document_code_spans(
    doc: ?*TwigDocument,
    out_ptr: ?*?[*]const TwigSpan,
    out_len: ?*usize,
) TwigStatus {
    const raw = doc orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;

    const allocator = activeAllocator();
    const handle = asHandle(raw);

    const spans = collectCodeSpans(allocator, astOf(&handle.parsed)) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
    };

    if (handle.code_spans.len != 0) allocator.free(handle.code_spans);
    handle.code_spans = spans;

    ptr_out.* = if (spans.len == 0) null else spans.ptr;
    len_out.* = spans.len;
    return .ok;
}

test "twig_document_code_spans finds verbatim and code_block, not prose" {
    const source = "See `x` and\n\n```\nblock\n```\n\nprose\n";

    var doc: ?*TwigDocument = null;
    const parse_status = twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.markdown), &doc);
    try std.testing.expectEqual(TwigStatus.ok, parse_status);
    defer twig_document_destroy(doc);

    var ptr: ?[*]const TwigSpan = null;
    var len: usize = 0;
    const span_status = twig_document_code_spans(doc, &ptr, &len);
    try std.testing.expectEqual(TwigStatus.ok, span_status);
    try std.testing.expect(len == 2);

    const spans = ptr.?[0..len];
    for (spans) |span| {
        try std.testing.expect(span.start < span.end);
        // Neither code span covers "prose".
        try std.testing.expect(!std.mem.containsAtLeast(u8, source[span.start..span.end], 1, "prose"));
    }
}

