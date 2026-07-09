//! Markdown: the entry point for this language module, mirroring
//! `languages/djot/djot.zig`'s / `languages/xml/xml.zig`'s role for their
//! formats. Wires the block parser (`block.zig`, which delegates inline
//! content to `inline.zig`) into one `parse` call, and aggregates every
//! sibling file's `test {}` blocks (the fig/djot/xml convention).
//!
//! ── Scope: this is Phase 1 of 3 ─────────────────────────────────────────
//! Twig's Markdown support targets CommonMark 0.31.2
//! (https://spec.commonmark.org/0.31.2/), built in three phases:
//!   - Phase 1 (this): block structure (headings, lists, block quotes, code
//!     blocks, HTML blocks, thematic breaks, link reference definitions)
//!     plus a minimal inline subset (plain text, backslash escapes, entity/
//!     numeric character references, code spans, soft/hard breaks). See
//!     `block.zig` and `inline.zig`'s module doc comments for the precise
//!     boundary and documented simplifications.
//!   - Phase 2 (later): the rest of CommonMark's inline grammar — emphasis/
//!     strong (the delimiter-run algorithm), links, images, autolinks, raw
//!     inline HTML — resolved against the `link_references` table this
//!     phase already populates.
//!   - Phase 3 (later): GFM extensions and other options `ParseOptions`
//!     already declares (tables, strikethrough, task lists, footnotes,
//!     definition lists, frontmatter, math).
//! Do not read the presence of `ParseOptions` fields as "already
//! implemented" — see that file's doc comment.
//!
//! ── Rendering ────────────────────────────────────────────────────────────
//! No bespoke Markdown->HTML renderer: `Markdown.parse` targets the same
//! shared `AST` every other language module does, so MD->HTML goes through
//! the existing generic printer, `Html.serialize`/`Html.serializeAlloc`
//! (`languages/html/serializer.zig`), the same way `languages/html/conformance.zig`
//! proves it works for djot. Markdown produces no djot-style footnote/
//! reference-in-prose rendering need beyond what `Document.link_references`
//! captures, and even that isn't consulted by the renderer until Phase 2
//! wires up link/image resolution (`Html.Context.references` is shaped to
//! accept it already — see `conformance.zig` for how a `Document` feeds a
//! `Context`).
//!
//! ── `Document` ───────────────────────────────────────────────────────────
//! Like djot (and unlike XML, which needs no side tables), Markdown needs a
//! wrapper around the shared `AST`: link reference definitions
//! (`[label]: url "title"`) are parsed and stripped out of the block stream
//! by `block.zig` (see its module doc comment), but their labels only
//! become useful once Phase 2 resolves `link`/`image` nodes against them —
//! so, exactly like djot's `Document.references`, they're carried
//! alongside the `AST` rather than folded into it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const block = @import("block.zig");
const inline_mod = @import("inline.zig");

pub const AST = @import("../../ast/ast.zig");
pub const ParseOptions = @import("options.zig");

pub const Parser = block.Parser;

/// A parsed Markdown document: the language-neutral `AST` plus the
/// label -> `reference`-node table Phase 2's link/image resolution will
/// consult. Mirrors `Djot.Document` — see that type's doc comment for the
/// rationale (side tables live here, not on the shared `AST`, because
/// XML/HTML have nothing like them).
pub const Document = struct {
    ast: AST,

    /// Label (normalized: trimmed, internal whitespace collapsed, ASCII
    /// lowercased — see `block.zig`'s `normalizeLabel`) -> the `reference`
    /// node holding that link reference definition's destination (and, as
    /// a `title` attribute when present, its title). These `reference`
    /// nodes are NOT attached anywhere in `ast`'s tree (matching djot's
    /// `references`: they're pure side-table entries, resolved by label at
    /// render time, never rendered in place).
    ///
    /// This map's KEYS are slices of `ast.owned_strings` (each key is the
    /// same string as its `reference` node's own `.label` field, not a
    /// separate copy — see `block.zig`'s `tryParseLinkRefDef`), exactly
    /// like `Djot.Document.references`, so `deinit` only needs to free the
    /// map structure itself.
    link_references: std.StringHashMapUnmanaged(AST.Node.Id) = .empty,

    pub fn deinit(self: *Document) void {
        self.link_references.deinit(self.ast.allocator);
        self.ast.deinit();
    }
};

/// Parse `source` (Markdown/CommonMark text) into a `Document`. The
/// returned document is fully self-contained (its AST owns copies of every
/// string it needs) and must be freed with `doc.deinit()`.
pub fn parse(allocator: Allocator, source: []const u8, options: ParseOptions) Allocator.Error!Document {
    const result = try block.parse(allocator, source, options);
    return .{ .ast = result.ast, .link_references = result.link_references };
}

test {
    _ = @import("entities.zig");
    _ = inline_mod;
    _ = block;
    _ = @import("conformance.zig");
}

const testing = std.testing;

test "parse produces a doc with a paragraph" {
    var doc = try parse(testing.allocator, "hello world\n", .{});
    defer doc.deinit();

    const ast = doc.ast;
    try testing.expect(ast.nodes[ast.root].kind == .doc);
    const para_id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[para_id].kind == .para);
}

test "headings are flat -- no section wrapper, no auto id (unlike djot)" {
    var doc = try parse(testing.allocator, "# Hello World\n\npara\n", .{});
    defer doc.deinit();

    const ast = doc.ast;
    const heading_id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[heading_id].kind == .heading);
    try testing.expectEqual(@as(u32, 1), ast.nodes[heading_id].kind.heading.level);
    try testing.expect(ast.attrsOf(heading_id).isEmpty());

    const para_id = ast.nodes[heading_id].next_sibling orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[para_id].kind == .para);
}
