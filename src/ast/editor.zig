//! The span-splice editor — Twig's reason for existing: precise, LOSSLESS
//! in-place edits to a document, driven by the AST's byte spans. The document
//! analogue of how `fig` edits config files (see `~/Documents/fig/src/editor
//! .zig`), reduced to its essence.
//!
//! ── The one primitive ──────────────────────────────────────────────────────
//! Everything reduces to `replaceAtSpan(span, replacement)`: build a new source
//! buffer that is the old bytes with `[span.start, span.end)` overwritten by
//! `replacement`, reparse it, and — only if the reparse succeeds — swap it in.
//! On reparse failure the edit is abandoned and the editor is left exactly as
//! it was (the new buffer is discarded; the old source and AST are untouched),
//! so a failed edit can never corrupt the document. Losslessness is automatic:
//! bytes outside the spliced span are copied verbatim and never reflow — Twig
//! never reformats what it didn't edit. An insertion is just a zero-width span.
//!
//! ── Language-agnostic by construction ──────────────────────────────────────
//! The editor holds only source bytes plus a `parse_fn` callback (source ->
//! `AST`), so the same engine edits djot, Markdown, or XML — the caller
//! supplies the right parser. It deliberately does NOT import any language
//! module (the CLI wires the per-language `parse_fn` adapters; djot/Markdown's
//! `Document` side tables are irrelevant to editing, so an adapter frees those
//! maps and hands back the bare `AST`). Tests below `@import` a real language
//! (XML) only inside the test bodies, so non-test builds carry no such dep.
//!
//! ── What it can't do yet (honest limits) ───────────────────────────────────
//!   - `replaceContent`/`insertChild`-into-empty need a container's interior
//!     offset (`content_span`); djot leaves that `null` for empty containers
//!     (XML always has it), so those ops return `error.NoContentSpan` there.
//!   - Payload fields (a `link`'s destination, a `code_block`'s language) are
//!     string payloads, not child nodes with their own spans — so there is no
//!     sub-node span to splice; editing one means `replaceNode` on the whole
//!     node's source. Per-field spans are future parser work.
//!   - `deleteNode` removes exactly the node's span and nothing else (no
//!     surrounding-whitespace cleanup) — predictable and lossless, but it can
//!     leave a blank line behind. `deleteNodeSmart` is the block-aware variant
//!     that tidies the surrounding blank lines (and falls back to the exact
//!     delete for an inline, mid-line node); the CLI's `--delete` uses it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("ast.zig");
const Node = AST.Node;
const Span = @import("../span.zig");

pub const Editor = struct {
    /// Source -> a freshly-allocated `AST` the editor takes ownership of.
    /// Runtime (not comptime-generic) so the CLI can pick the language at run
    /// time; the error set is open (`anyerror`) because each language's parse
    /// error set differs and a reparse failure is a legitimate, caller-visible
    /// outcome.
    ///
    /// The leading `ctx` is an opaque pointer the caller supplies to `init`
    /// and the editor passes back to every reparse, unread — the hook for
    /// parse configuration the editor itself has no business knowing about
    /// (the CLI passes a `*const format.ParseConfig` so an edited Markdown
    /// document reparses with the SAME extension flags, e.g. `--directives`,
    /// it was first parsed with; a callback that needs no configuration just
    /// ignores it). It must outlive the editor.
    pub const ParseFn = *const fn (ctx: *const anyopaque, Allocator, []const u8) anyerror!AST;

    allocator: Allocator,
    /// The current (edited) document bytes. Owns its memory.
    source: std.ArrayList(u8),
    /// The parse of `source.items` as of the last successful edit. Owns its
    /// memory; replaced wholesale on every successful edit.
    ast: AST,
    parse_fn: ParseFn,
    /// Opaque configuration handed to `parse_fn` on every reparse (see
    /// `ParseFn`). Borrowed; must outlive the editor.
    parse_ctx: *const anyopaque,

    /// Parse `source_bytes` and build an editor over a private copy of them.
    /// `parse_ctx` is forwarded verbatim to `parse_fn` on the initial parse
    /// and every reparse — see `ParseFn`.
    pub fn init(allocator: Allocator, source_bytes: []const u8, parse_ctx: *const anyopaque, parse_fn: ParseFn) !Editor {
        var source: std.ArrayList(u8) = .empty;
        errdefer source.deinit(allocator);
        try source.appendSlice(allocator, source_bytes);
        const ast = try parse_fn(parse_ctx, allocator, source.items);
        return .{ .allocator = allocator, .source = source, .ast = ast, .parse_fn = parse_fn, .parse_ctx = parse_ctx };
    }

    pub fn deinit(self: *Editor) void {
        self.ast.deinit();
        self.source.deinit(self.allocator);
    }

    /// The current edited document bytes.
    pub fn sourceBytes(self: *const Editor) []const u8 {
        return self.source.items;
    }

    /// The current parse (valid until the next successful edit).
    pub fn astView(self: *const Editor) *const AST {
        return &self.ast;
    }

    // ── the primitive ──────────────────────────────────────────────────────

    /// Overwrite `[span.start, span.end)` of the source with `replacement`,
    /// reparse, and swap in the result. On reparse failure nothing changes and
    /// the parser's error is returned. A zero-width `span` is an insertion.
    pub fn replaceAtSpan(self: *Editor, span: Span, replacement: []const u8) !void {
        std.debug.assert(span.start <= span.end);
        std.debug.assert(span.end <= self.source.items.len);
        const s = self.source.items;

        // Assemble the whole new source once, then reparse it. Building a fresh
        // buffer (rather than mutating in place) means the rollback path is
        // just "throw the new buffer away" — the old source/AST never moved.
        const total = span.start + replacement.len + (s.len - span.end);
        var new_src: std.ArrayList(u8) = .empty;
        new_src.ensureTotalCapacityPrecise(self.allocator, total) catch |err| {
            new_src.deinit(self.allocator);
            return err;
        };
        new_src.appendSliceAssumeCapacity(s[0..span.start]);
        new_src.appendSliceAssumeCapacity(replacement);
        new_src.appendSliceAssumeCapacity(s[span.end..]);

        const new_ast = self.parse_fn(self.parse_ctx, self.allocator, new_src.items) catch |err| {
            new_src.deinit(self.allocator);
            return err;
        };

        // Commit: the reparse succeeded, so retire the old state.
        self.ast.deinit();
        self.ast = new_ast;
        self.source.deinit(self.allocator);
        self.source = new_src;
    }

    // ── ops ─────────────────────────────────────────────────────────────
    // Two flavors of each op: a `…ById` form taking a resolved `Node.Id` (what
    // a selector match hands you), and a path form that just resolves the index
    // path and delegates. Both converge on `replaceAtSpan`. Ids are valid only
    // against the CURRENT `ast` (recompute after any successful edit).

    /// A node's span, or `error.NoNodeSpan` if it's the degenerate `(0,0)` that
    /// means "unset". Some parsers don't populate spans for every kind yet
    /// (notably Markdown inline nodes — links, emphasis), and splicing at a
    /// `(0,0)` span would silently corrupt the document at offset 0 instead of
    /// touching the intended node. Guarding the whole-node ops turns that into
    /// a clear error. (A real node never legitimately occupies zero bytes at
    /// offset 0.)
    fn nodeSpan(self: *Editor, id: Node.Id) !Span {
        const s = self.ast.nodes[id].span;
        if (s.start == 0 and s.end == 0) return error.NoNodeSpan;
        return s;
    }

    /// Replace the whole source of the node at `path`.
    pub fn replaceNode(self: *Editor, path: []const usize, text: []const u8) !void {
        try self.replaceNodeById(try self.ast.getIdByPath(path), text);
    }
    pub fn replaceNodeById(self: *Editor, id: Node.Id, text: []const u8) !void {
        try self.replaceAtSpan(try self.nodeSpan(id), text);
    }

    /// Replace the interior (between-delimiters `content_span`) of the
    /// container. `error.NoContentSpan` if it has none (a leaf, or a djot
    /// container the parser left with a null interior — see the module doc).
    pub fn replaceContent(self: *Editor, path: []const usize, text: []const u8) !void {
        try self.replaceContentById(try self.ast.getIdByPath(path), text);
    }
    pub fn replaceContentById(self: *Editor, id: Node.Id, text: []const u8) !void {
        const cs = self.ast.nodes[id].content_span orelse return error.NoContentSpan;
        try self.replaceAtSpan(cs, text);
    }

    /// Insert `text` immediately before / after the node (at its span start /
    /// end). The caller supplies any needed separators/newlines — the editor
    /// does no whitespace guessing.
    pub fn insertBefore(self: *Editor, path: []const usize, text: []const u8) !void {
        try self.insertBeforeById(try self.ast.getIdByPath(path), text);
    }
    pub fn insertBeforeById(self: *Editor, id: Node.Id, text: []const u8) !void {
        const at = (try self.nodeSpan(id)).start;
        try self.replaceAtSpan(Span.init(at, at), text);
    }
    pub fn insertAfter(self: *Editor, path: []const usize, text: []const u8) !void {
        try self.insertAfterById(try self.ast.getIdByPath(path), text);
    }
    pub fn insertAfterById(self: *Editor, id: Node.Id, text: []const u8) !void {
        const at = (try self.nodeSpan(id)).end;
        try self.replaceAtSpan(Span.init(at, at), text);
    }

    /// Insert `text` as the `index`-th child of the container. Anchor rules:
    /// `index == 0` -> before the current first child; an index at or past the
    /// child count -> after the current last child; otherwise -> before the
    /// index-th child. An *empty* container is anchored at its `content_span`
    /// start (`error.NoContentSpan` if it has none).
    pub fn insertChild(self: *Editor, path: []const usize, index: usize, text: []const u8) !void {
        try self.insertChildById(try self.ast.getIdByPath(path), index, text);
    }
    pub fn insertChildById(self: *Editor, id: Node.Id, index: usize, text: []const u8) !void {
        const first = self.ast.nodes[id].first_child orelse {
            const cs = self.ast.nodes[id].content_span orelse return error.NoContentSpan;
            return self.replaceAtSpan(Span.init(cs.start, cs.start), text);
        };

        var cur: ?Node.Id = first;
        var i: usize = 0;
        var last: Node.Id = first;
        while (cur) |c| {
            if (i == index) {
                const at = self.ast.nodes[c].span.start;
                return self.replaceAtSpan(Span.init(at, at), text);
            }
            last = c;
            cur = self.ast.nodes[c].next_sibling;
            i += 1;
        }
        const at = self.ast.nodes[last].span.end;
        try self.replaceAtSpan(Span.init(at, at), text);
    }

    /// Delete the node (remove exactly its span; no whitespace cleanup). The
    /// predictable primitive — see `deleteNodeSmart` for the block-aware
    /// variant that also tidies the surrounding blank lines.
    pub fn deleteNode(self: *Editor, path: []const usize) !void {
        try self.deleteNodeById(try self.ast.getIdByPath(path));
    }
    pub fn deleteNodeById(self: *Editor, id: Node.Id) !void {
        try self.replaceAtSpan(try self.nodeSpan(id), "");
    }

    /// Delete the node, tidying surrounding whitespace so no dangling blank
    /// line is left behind. For a node that occupies WHOLE LINES (a block —
    /// paragraph, heading, list, container directive, …) this also removes the
    /// block's terminating newline and one blank-line separator, collapsing
    /// `A⏎⏎B⏎⏎C` down to `A⏎⏎C` when `B` is deleted (and trimming the now-
    /// dangling separator at a document edge). For a MID-LINE node (an inline
    /// — emphasis, a link) line surgery would be wrong, so it falls back to the
    /// exact-span delete of `deleteNode`. See `tidyDeletionSpan`.
    pub fn deleteNodeSmart(self: *Editor, path: []const usize) !void {
        try self.deleteNodeSmartById(try self.ast.getIdByPath(path));
    }
    pub fn deleteNodeSmartById(self: *Editor, id: Node.Id) !void {
        const span = try self.nodeSpan(id);
        try self.replaceAtSpan(tidyDeletionSpan(self.source.items, span), "");
    }
};

// ── smart-delete whitespace tidying ────────────────────────────────────────

/// A line's content (its bytes excluding the terminating newline) is "blank"
/// if it holds only spaces/tabs (and a lone `\r` from a CRLF ending).
fn isBlankRun(s: []const u8) bool {
    for (s) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

/// From `from` (a line start), consume consecutive blank lines, returning the
/// offset of the first non-blank line (or `source.len`). A trailing blank
/// "line" with no newline (just whitespace before EOF) is consumed too.
fn consumeBlankLinesForward(source: []const u8, from: usize) usize {
    var i = from;
    while (i < source.len) {
        var j = i;
        while (j < source.len and source[j] != '\n') j += 1;
        if (!isBlankRun(source[i..j])) break;
        i = if (j < source.len) j + 1 else j;
        if (j >= source.len) break; // trailing blank without a newline
    }
    return i;
}

/// From `from` (a line start), consume consecutive PRECEDING blank lines,
/// returning the start offset of the earliest one (or `from` if the previous
/// line isn't blank / there is none).
fn consumeBlankLinesBackward(source: []const u8, from: usize) usize {
    var s = from;
    while (s > 0 and source[s - 1] == '\n') {
        const nl = s - 1; // the newline terminating the previous line
        var pstart = nl;
        while (pstart > 0 and source[pstart - 1] != '\n') pstart -= 1;
        if (!isBlankRun(source[pstart..nl])) break;
        s = pstart;
    }
    return s;
}

/// The range to delete for a "tidy" removal of a node whose exact span is
/// `span`. If `span` occupies whole lines (starts at a line start and ends at
/// a line end — i.e. a block), the returned range also swallows the block's
/// terminating newline and the blank-line separator on one side: the trailing
/// blanks normally (leaving the leading blank as the surviving neighbors'
/// separator), or — when the block was the LAST thing in the document — the
/// leading blanks too, so nothing dangles at EOF. A mid-line span (an inline
/// node) is returned unchanged: exact delete, since line surgery there would
/// clip unrelated text.
fn tidyDeletionSpan(source: []const u8, span: Span) Span {
    const len = source.len;
    var s = span.start;
    var e = span.end;

    const at_line_start = (s == 0) or (s <= len and source[s - 1] == '\n');
    const at_line_end = (e == len) or (e < len and (source[e] == '\n' or source[e] == '\r'));
    if (!at_line_start or !at_line_end) return span;

    if (e < len and source[e] == '\r') e += 1;
    if (e < len and source[e] == '\n') e += 1;
    e = consumeBlankLinesForward(source, e);
    if (e >= len) s = consumeBlankLinesBackward(source, s);

    return Span.init(s, e);
}

// ── tests ────────────────────────────────────────────────────────────────
// XML is the test vehicle: it has real spans + `content_span` and, uniquely
// among Twig's languages, can fail to parse — which is what exercises the
// rollback path. Imported inside the test bodies so non-test builds of this
// module stay language-dependency-free.

const testing = std.testing;

fn parseXml(ctx: *const anyopaque, a: Allocator, s: []const u8) anyerror!AST {
    _ = ctx;
    const Xml = @import("../languages/xml/xml.zig");
    return Xml.parse(a, s);
}

/// A throwaway context for the tests below, which use `parseXml` (which
/// ignores its `ctx`). Any stable pointer works; this is the conventional one.
const test_ctx: u8 = 0;

test "replaceContent rewrites an element interior, losslessly" {
    var ed = try Editor.init(testing.allocator, "<a><b>hi</b></a>", &test_ctx, parseXml);
    defer ed.deinit();

    // Path [0,0] = doc -> <a> -> <b>. Replace <b>'s interior "hi".
    try ed.replaceContent(&.{ 0, 0 }, "bye");
    try testing.expectEqualStrings("<a><b>bye</b></a>", ed.sourceBytes());
}

test "insertChild appends and inserts by index" {
    var ed = try Editor.init(testing.allocator, "<r><a/><c/></r>", &test_ctx, parseXml);
    defer ed.deinit();

    // Insert between the two children (index 1 of <r>).
    try ed.insertChild(&.{0}, 1, "<b/>");
    try testing.expectEqualStrings("<r><a/><b/><c/></r>", ed.sourceBytes());

    // Append at the end (index past child count).
    try ed.insertChild(&.{0}, 99, "<d/>");
    try testing.expectEqualStrings("<r><a/><b/><c/><d/></r>", ed.sourceBytes());

    // Insert at the front (index 0).
    try ed.insertChild(&.{0}, 0, "<z/>");
    try testing.expectEqualStrings("<r><z/><a/><b/><c/><d/></r>", ed.sourceBytes());
}

test "insertBefore / insertAfter / deleteNode" {
    var ed = try Editor.init(testing.allocator, "<r><a/><b/></r>", &test_ctx, parseXml);
    defer ed.deinit();

    try ed.insertAfter(&.{ 0, 0 }, "<x/>");
    try testing.expectEqualStrings("<r><a/><x/><b/></r>", ed.sourceBytes());

    try ed.deleteNode(&.{ 0, 0 });
    try testing.expectEqualStrings("<r><x/><b/></r>", ed.sourceBytes());

    try ed.insertBefore(&.{ 0, 0 }, "<y/>");
    try testing.expectEqualStrings("<r><y/><x/><b/></r>", ed.sourceBytes());
}

test "a reparse-breaking edit rolls back and leaves the document untouched" {
    var ed = try Editor.init(testing.allocator, "<a>ok</a>", &test_ctx, parseXml);
    defer ed.deinit();

    // Replace <a>'s interior with a fragment that makes the doc malformed
    // (`<a><b></a>` — the close tag no longer matches) -> the reparse fails
    // and the whole edit is abandoned.
    try testing.expectError(error.MismatchedCloseTag, ed.replaceContent(&.{0}, "<b>"));
    // Byte-for-byte unchanged, and still a valid, navigable tree.
    try testing.expectEqualStrings("<a>ok</a>", ed.sourceBytes());
    _ = try ed.astView().getIdByPath(&.{0});
}

test "replaceContent on a leaf yields NoContentSpan" {
    var ed = try Editor.init(testing.allocator, "<a>hi</a>", &test_ctx, parseXml);
    defer ed.deinit();
    // [0,0] = the "hi" text node, a leaf: no interior to splice.
    try testing.expectError(error.NoContentSpan, ed.replaceContent(&.{ 0, 0 }, "x"));
}

test "path navigation reports out-of-bounds" {
    var ed = try Editor.init(testing.allocator, "<a><b/></a>", &test_ctx, parseXml);
    defer ed.deinit();
    try testing.expectError(error.PathOutOfBounds, ed.astView().getIdByPath(&.{ 0, 5 }));
    try testing.expectError(error.PathOutOfBounds, ed.astView().getIdByPath(&.{ 0, 0, 0 }));
}

// ── smart-delete (tidyDeletionSpan) ─────────────────────────────────────────

/// Apply `tidyDeletionSpan` to `src` at `[start,end)` and return the resulting
/// bytes (what a smart delete of that span would leave behind).
fn tidyDelete(src: []const u8, start: usize, end: usize) [256]u8 {
    var buf: [256]u8 = undefined;
    const del = tidyDeletionSpan(src, Span.init(start, end));
    const n = del.start + (src.len - del.end);
    @memcpy(buf[0..del.start], src[0..del.start]);
    @memcpy(buf[del.start..n], src[del.end..]);
    return buf;
}

fn expectTidy(src: []const u8, start: usize, end: usize, want: []const u8) !void {
    const buf = tidyDelete(src, start, end);
    const del = tidyDeletionSpan(src, Span.init(start, end));
    const got = buf[0 .. del.start + (src.len - del.end)];
    try testing.expectEqualStrings(want, got);
}

test "tidyDeletionSpan: middle block leaves exactly one blank-line separator" {
    // "A\n\nB\n\nC\n", delete B ([3,4)).
    try expectTidy("A\n\nB\n\nC\n", 3, 4, "A\n\nC\n");
}

test "tidyDeletionSpan: first block leaves the rest clean at the top" {
    try expectTidy("A\n\nB\n\nC\n", 0, 1, "B\n\nC\n");
}

test "tidyDeletionSpan: last block trims the now-dangling trailing blank" {
    // "A\n\nB\n\nC\n", delete C ([6,7)) -> no trailing blank left after B.
    try expectTidy("A\n\nB\n\nC\n", 6, 7, "A\n\nB\n");
}

test "tidyDeletionSpan: adjacent blocks with no blank line between them" {
    try expectTidy("# A\n# B\n# C\n", 4, 7, "# A\n# C\n");
}

test "tidyDeletionSpan: a multi-line block plus its blank separator" {
    // A two-line block between two others; delete it and one separator.
    const src = "top\n\n:::x\nbody\n:::\n\nbottom\n";
    // block span = the ":::x\nbody\n:::" region = [5, 18)
    try expectTidy(src, 5, 18, "top\n\nbottom\n");
}

test "tidyDeletionSpan: the only block empties the document" {
    try expectTidy("A\n", 0, 1, "");
}

test "tidyDeletionSpan: a mid-line (inline) span is deleted exactly, no line surgery" {
    // "a *b* c\n", delete the "*b*" at [2,5): must NOT swallow the line.
    try expectTidy("a *b* c\n", 2, 5, "a  c\n");
}
