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
