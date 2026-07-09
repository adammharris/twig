//! Document -> HTML renderer, mirroring `languages/djot/html.zig` exactly
//! (see that file's module doc comment for the full rationale — this is the
//! same "thin adapter over the shared, language-neutral printer at
//! `languages/html/serializer.zig`" split, for the same reason).
//!
//! Markdown resolves `link`/`image` references at PARSE time (Phase 2), so
//! — unlike djot — this adapter's `Html.Context` always has EMPTY
//! `references`/`auto_references`: there is nothing for the shared printer
//! to look up for those. Footnotes are the one Markdown construct that
//! (like djot's) resolves at RENDER time instead (see `markdown.zig`'s
//! module doc comment and `Document.footnotes`'s doc comment), so
//! `Context.footnotes` is the only side table this adapter actually
//! populates from `doc`.
//!
//! This is the module `cli/format.zig`'s markdown registry entry renders
//! through (`renderHtmlMarkdown`) instead of the bare generic
//! `Html.serialize`, precisely so footnotes resolve when converting via the
//! CLI — using the generic printer directly (`ctx = null`) would silently
//! drop every footnote reference/definition (an unresolved
//! `footnote_reference` renders as if its definition were simply missing —
//! see `languages/html/serializer.zig`'s module doc comment).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const markdown = @import("markdown.zig");
const Document = markdown.Document;
const Html = @import("../html/html.zig");

pub const RenderOptions = struct {
    warn: ?*const fn (message: []const u8) void = null,
};

/// Same error set `Html`'s printer returns: write failures from `writer`
/// merged with allocation failures (footnote index/id tracking needs to
/// allocate).
pub const RenderError = Html.RenderError;

/// Build the shared printer's reference/footnote side tables from `doc`'s
/// public fields. `references`/`auto_references` stay at their `.empty`
/// default -- Markdown has no render-time reference table (see this file's
/// module doc comment) -- so only `footnotes` is ever non-empty here.
fn contextFor(doc: *const Document) Html.Context {
    return .{ .footnotes = doc.footnotes };
}

/// Render `doc` (rooted at `doc.ast.root`, normally a `doc` node) to HTML,
/// writing to `writer`. Delegates to `Html.Renderer` directly (rather than
/// `Html.serialize`) so `options.warn` can be threaded through to the
/// printer's own `RenderOptions` -- mirrors `Djot.html.render` exactly.
pub fn render(allocator: Allocator, doc: *const Document, writer: *Writer, options: RenderOptions) RenderError!void {
    const ctx = contextFor(doc);
    var r = Html.Renderer.init(allocator, &doc.ast, writer, &ctx, .{ .warn = options.warn });
    defer r.deinit();
    try r.renderNode(doc.ast.root);
}

/// Convenience wrapper: render to an owned string.
pub fn renderAlloc(allocator: Allocator, doc: *const Document, options: RenderOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    // `Writer.Allocating` only ever fails (`error.WriteFailed`) when its own
    // backing allocation fails, so both halves of `RenderError` collapse to
    // `error.OutOfMemory` here.
    render(allocator, doc, &out.writer, options) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

const testing = std.testing;

test "renders a simple paragraph with emphasis" {
    var doc = try markdown.parse(testing.allocator, "hello *world*\n", .{});
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<p>hello <em>world</em></p>\n", html);
}

test "footnote: a reference + definition render the noteref, sup, and endnotes section" {
    var doc = try markdown.parse(testing.allocator,
        \\text[^a] more
        \\
        \\[^a]: the note
        \\
    , .{ .footnotes = true });
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "id=\"fnref1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "role=\"doc-noteref\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<sup>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "role=\"doc-endnotes\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"fn1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "the note") != null);
    // A backlink from the note back to its reference.
    try testing.expect(std.mem.indexOf(u8, html, "href=\"#fnref1\"") != null);
}

test "footnote: a forward reference (used before its definition) still resolves" {
    var doc = try markdown.parse(testing.allocator,
        \\see[^a]
        \\
        \\[^a]: later
        \\
    , .{ .footnotes = true });
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"fnref1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "later") != null);
}

test "footnote: multiple footnotes are numbered in reference order" {
    var doc = try markdown.parse(testing.allocator,
        \\one[^b] two[^a]
        \\
        \\[^a]: A
        \\[^b]: B
        \\
    , .{ .footnotes = true });
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    // `[^b]` is referenced first in the text, so it claims footnote 1.
    try testing.expect(std.mem.indexOf(u8, html, "id=\"fnref1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"fnref2\"") != null);
    const fn1 = std.mem.indexOf(u8, html, "id=\"fn1\"").?;
    const fn2 = std.mem.indexOf(u8, html, "id=\"fn2\"").?;
    try testing.expect(fn1 < fn2);
    try testing.expect(std.mem.indexOf(u8, html[fn1..fn2], "B") != null);
}

test "footnotes OFF: '[^a]' with no definition falls back to ordinary CommonMark link parsing" {
    // With `footnotes = false`, `'['` never special-cases `^` at all -- this
    // is ordinary shortcut-reference-link syntax with an unresolved label
    // ("^a", no matching `link_references` entry), which CommonMark falls
    // back to literal bracket text for (same as any other undefined
    // `[label]` -- see `block.zig`'s own "unresolved reference falls back
    // to literal brackets" coverage).
    var doc = try markdown.parse(testing.allocator, "see [^a]\n", .{ .footnotes = false });
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "doc-endnotes") == null);
    try testing.expect(std.mem.indexOf(u8, html, "doc-noteref") == null);
    try testing.expect(std.mem.indexOf(u8, html, "[^a]") != null);
}

test "footnotes OFF: '[^a]: note' is an ordinary link reference definition (the '^' has no special meaning)" {
    // Confirms the flag genuinely gates the `^`-prefixed grammar rather than
    // just suppressing rendering: with it off, `[^a]: note` is valid,
    // ordinary CommonMark link reference definition syntax (labels may
    // contain `^`), so a shortcut reference to it resolves as a normal
    // link, NOT a footnote noteref.
    var doc = try markdown.parse(testing.allocator, "see[^a]\n\n[^a]: /note\n", .{ .footnotes = false });
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "doc-endnotes") == null);
    try testing.expect(std.mem.indexOf(u8, html, "doc-noteref") == null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"/note\"") != null);
}
