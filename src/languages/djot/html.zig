//! Document -> HTML renderer. Historically a ~600-line bespoke renderer
//! (ported from djot.js's `src/html.ts`); now a THIN ADAPTER over the
//! shared, language-neutral printer at `languages/html/serializer.zig`
//! (`Html`), which was built and proven (see `languages/html/conformance.zig`)
//! to reproduce this module's output byte-for-byte across the full djot.js
//! conformance corpus.
//!
//! The split exists because reference/footnote resolution is deferred
//! entirely to render time (see `Document`'s doc comment in `djot.zig`): a
//! `link`/`image`'s `reference` label and a `footnote_reference`'s label are
//! resolved against side tables that live on djot's `Document`, not on the
//! shared `AST` itself — XML/HTML have nothing like them, so they can't live
//! in `AST` without leaking djot-only baggage into a language-neutral type.
//! `Html`'s printer stays entirely djot-agnostic by taking those side tables
//! as an optional, generically-shaped `Html.Context` instead of importing
//! djot; this module's whole job is building that `Context` from a
//! `Document`'s public `references`/`auto_references`/`footnotes` fields and
//! handing it, plus the render-time `warn` hook, to `Html.Renderer`.
//!
//! Used both as a genuinely useful output format and — via `conformance.zig`
//! — as the parser's main correctness oracle: djot.js's own test suite is
//! entirely input-djot -> expected-HTML pairs, so an accurate renderer is
//! what makes that corpus usable here too.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const djot = @import("djot.zig");
const Document = djot.Document;
const Html = @import("../html/html.zig");

pub const RenderOptions = struct {
    warn: ?*const fn (message: []const u8) void = null,
};

/// Same error set `Html`'s printer returns: write failures from `writer`
/// merged with allocation failures (footnote index/id tracking, `alt`-text
/// extraction all need to allocate).
pub const RenderError = Html.RenderError;

/// Build the shared printer's reference/footnote side tables straight from
/// `doc`'s public fields -- same pattern `languages/html/conformance.zig`
/// uses to drive `Html` against the djot.js corpus directly.
fn contextFor(doc: *const Document) Html.Context {
    return .{
        .references = doc.references,
        .auto_references = doc.auto_references,
        .footnotes = doc.footnotes,
    };
}

/// Render `doc` (rooted at `doc.ast.root`, normally a `doc` node) to HTML,
/// writing to `writer`. Delegates to `Html.Renderer` directly (rather than
/// `Html.serialize`) so `options.warn` can be threaded through to the
/// printer's own `RenderOptions`, which `Html.serialize`'s convenience
/// signature doesn't expose.
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
    var doc = try djot.parse(testing.allocator, "hello *world*\n");
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<p>hello <strong>world</strong></p>\n", html);
}

test "heading renders with level and section wrapper" {
    var doc = try djot.parse(testing.allocator, "# Hi\n");
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<section id=\"Hi\">\n<h1>Hi</h1>\n</section>\n", html);
}

test "tight list renders without <p> wrappers" {
    var doc = try djot.parse(testing.allocator, "- a\n- b\n");
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<ul>\n<li>\na\n</li>\n<li>\nb\n</li>\n</ul>\n", html);
}

test "a bare (null-value) attribute renders as just its key" {
    // Djot can't produce a bare attribute, so build the tree by hand (the
    // way an XML/HTML parser would) and wrap it in a side-table-less
    // `Document` to reach the shared attr-rendering path.
    const AST = Html.AST;
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const text = try b.addLeaf(.{ .str = "x" });
    const para = try b.addContainer(.para, &.{text});
    try b.setAttrs(para, .{ .entries = &.{ .{ .key = "disabled", .value = null }, .{ .key = "id", .value = "y" } } });

    var doc: Document = .{ .ast = try b.finish(para) };
    defer doc.deinit();

    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<p disabled id=\"y\">x</p>\n", html);
}

test "warn fires for an unresolved reference" {
    var doc = try djot.parse(testing.allocator, "[foo][bar]\n");
    defer doc.deinit();

    const Watcher = struct {
        var fired: bool = false;
        fn warn(_: []const u8) void {
            fired = true;
        }
    };
    Watcher.fired = false;

    const html = try renderAlloc(testing.allocator, &doc, .{ .warn = Watcher.warn });
    defer testing.allocator.free(html);
    try testing.expect(Watcher.fired);
}
