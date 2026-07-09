//! Phase 2 inline scanning: the full CommonMark inline grammar. Phase 1
//! (still intact below: backslash escapes, entity/numeric references, code
//! spans, soft/hard breaks) is extended here with emphasis/strong, links,
//! images, autolinks, and raw inline HTML — see `markdown.zig`'s module doc
//! comment for the phase boundary.
//!
//! ── Strategy ─────────────────────────────────────────────────────────────
//! Mirrors the strategy CommonMark's spec appendix ("A parsing strategy")
//! and `cmark`'s `inlines.c` both use: a single left-to-right scan produces a
//! flat sequence of inline "items" (`Scanner.items`, a doubly-linked list
//! built over an arena array rather than real pointers, since Zig arrays give
//! us stable indices without a GC) — most items are already-finished AST
//! nodes (text runs, code spans, breaks, autolinks, raw HTML), but `*`/`_`
//! delimiter runs and `[`/`![` brackets are pushed as PLACEHOLDER text items
//! (holding their literal run text) alongside a side-table entry on a
//! delimiter stack (`Scanner.delims`) or bracket stack (`Scanner.brackets`).
//! Links/images resolve eagerly, right when their closing `]` is scanned
//! (per spec, this can't wait for a second pass, since "links cannot contain
//! links" needs to know about closures as they happen); emphasis resolves
//! lazily, via the bottom-up `process_emphasis` pass over the delimiter
//! stack, run once over each link/image's contents (right before that
//! bracket resolves, so nested emphasis binds inside the link text) and once
//! more over whatever's left at the very end of the scan.
//!
//! Code spans, autolinks, and raw HTML are recognized as part of the SAME
//! left-to-right scan as backslash escapes and entities (all higher
//! precedence than emphasis/link delimiters, per spec), so e.g. `` *`a*` ``
//! never lets the `*` inside the code span participate in emphasis matching
//! — by the time the delimiter stack sees anything, the code span has
//! already been consumed as one atomic item.
//!
//! ── Reference links resolve at PARSE time ───────────────────────────────
//! Unlike djot (which keeps a reference table for the renderer to consult),
//! CommonMark reference links/images are resolved HERE, against
//! `Document.link_references` (threaded in as `link_refs`), producing a
//! `link`/`image` node with `destination` set and `reference == null` — this
//! file's caller (`block.zig`) defers calling `parseInline` until the WHOLE
//! document's block structure (and therefore every link reference
//! definition, including ones that appear after their first use) has been
//! parsed, specifically so forward references resolve correctly. See
//! `block.zig`'s `pending_inline`/`resolvePendingInline` for that
//! deferral. An unresolved label's brackets fall back to literal text, per
//! spec.
//!
//! ── Documented approximations ───────────────────────────────────────────
//! - Emphasis flanking (`computeFlanking`) classifies "Unicode whitespace"
//!   and "Unicode punctuation" fully for ASCII (matching `isAsciiPunct`
//!   below) but only approximately for non-ASCII code points (a curated
//!   table of common punctuation/space blocks — General Punctuation, CJK
//!   punctuation, fullwidth ASCII forms — rather than the complete Unicode
//!   General Category tables). Spec examples that hinge on obscure non-ASCII
//!   punctuation classification may not pass; this is the same style of
//!   tradeoff `block.zig`'s tab-handling approximation makes.
//! - `process_emphasis` (below) deliberately omits cmark's `openers_bottom`
//!   memoization table (a pure performance optimization that's easy to get
//!   subtly wrong — a 2-bucket, rather than 3-bucket, `length % 3`
//!   memoization can silently skip valid matches). Always rescanning back to
//!   `stack_bottom` is O(n^2) in the delimiter count instead of amortized
//!   O(n), which is fine at paragraph scale.
//! - Reference-form fallback: if `]` is immediately followed by a `[...]`
//!   that fails to scan as a syntactically valid label (e.g. contains an
//!   unescaped nested `[`), this falls back to trying the SHORTCUT form
//!   (the opening bracket's own text) rather than failing outright. This is
//!   a defensible reading of the spec's fallback chain but not exhaustively
//!   cross-checked against cmark's exact behavior for this rare corner.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../../ast/ast.zig");
const Node = AST.Node;
const Builder = AST.Builder;
const entities = @import("entities.zig");

/// Parse `text` (a single leaf block's already-assembled content — see this
/// file's module doc comment) into a flat sequence of inline children, added
/// to `b` but not yet attached to any parent. `link_refs` is
/// `Document.link_references`'s underlying map (label, already normalized
/// per `block.zig`'s `normalizeLabel` -> the `reference` node holding that
/// definition's destination/title), consulted for reference-style links and
/// images; it must already be COMPLETE (every link reference definition in
/// the document registered), which is why `block.zig` defers calling this
/// until block-level parsing has finished. Returns the ordered list of child
/// ids (caller's to free; typically immediately handed to `b.setChildren`).
pub fn parseInline(b: *Builder, text: []const u8, link_refs: *const std.StringHashMapUnmanaged(Node.Id)) Allocator.Error![]Node.Id {
    var sc: Scanner = .{ .b = b, .link_refs = link_refs };
    defer sc.deinit();

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '\\' => {
                if (i + 1 < text.len and text[i + 1] == '\n') {
                    // Backslash immediately before a line ending: hard break.
                    try sc.flushBuf();
                    _ = try sc.appendItem(try b.addLeaf(.hard_break));
                    i += 2;
                    i = skipLeadingLineSpace(text, i);
                    continue;
                }
                if (i + 1 < text.len and isAsciiPunct(text[i + 1])) {
                    try sc.buf.append(b.allocator, text[i + 1]);
                    i += 2;
                    continue;
                }
                try sc.buf.append(b.allocator, '\\');
                i += 1;
            },
            '\n' => {
                const hard = trailingHardBreakSpaces(sc.buf.items);
                sc.buf.items.len -= hard;
                try sc.flushBuf();
                const kind: Node.Kind = if (hard >= 2) .hard_break else .soft_break;
                _ = try sc.appendItem(try b.addLeaf(kind));
                i += 1;
                i = skipLeadingLineSpace(text, i);
            },
            '`' => {
                if (scanCodeSpan(text, i)) |span| {
                    try sc.flushBuf();
                    const content = try normalizeCodeSpan(b.allocator, text[span.content_start..span.content_end]);
                    defer b.allocator.free(content);
                    _ = try sc.appendItem(try b.addLeaf(.{ .verbatim = content }));
                    i = span.end;
                } else {
                    // No closing run of the SAME length as this opening run
                    // exists anywhere later in `text`: the whole opening run
                    // is literal backticks -- see `scanCodeSpan`'s doc
                    // comment.
                    var run_end = i;
                    while (run_end < text.len and text[run_end] == '`') run_end += 1;
                    try sc.buf.appendSlice(b.allocator, text[i..run_end]);
                    i = run_end;
                }
            },
            '&' => {
                if (try decodeCharRef(b.allocator, text, i)) |ref| {
                    try sc.buf.appendSlice(b.allocator, ref.text);
                    b.allocator.free(ref.text);
                    i = ref.end;
                } else {
                    try sc.buf.append(b.allocator, '&');
                    i += 1;
                }
            },
            '<' => {
                if (scanAutolinkUri(text, i)) |end| {
                    try sc.flushBuf();
                    _ = try sc.appendItem(try b.addLeaf(.{ .url = text[i + 1 .. end - 1] }));
                    i = end;
                } else if (scanAutolinkEmail(text, i)) |end| {
                    try sc.flushBuf();
                    _ = try sc.appendItem(try b.addLeaf(.{ .email = text[i + 1 .. end - 1] }));
                    i = end;
                } else if (scanHtmlTag(text, i)) |end| {
                    try sc.flushBuf();
                    _ = try sc.appendItem(try b.addLeaf(.{ .raw_inline = .{ .format = "html", .text = text[i..end] } }));
                    i = end;
                } else {
                    try sc.buf.append(b.allocator, '<');
                    i += 1;
                }
            },
            '*', '_' => {
                var run_end = i;
                while (run_end < text.len and text[run_end] == c) run_end += 1;
                const flank = computeFlanking(text, i, run_end, c);
                if (flank.can_open or flank.can_close) {
                    // Only a run that could ever participate in matching
                    // needs its own item (so `spliceEmphasis` can shrink/
                    // bypass it later) -- a run with neither flag is
                    // permanently inert, so just fold it into the ambient
                    // literal-text buffer like any other character, which
                    // also keeps the AST from fragmenting into a fresh `str`
                    // node at every non-flanking `*`/`_` (e.g. `a_b_c`).
                    try sc.flushBuf();
                    const item_idx = try sc.appendItem(try b.addLeaf(.{ .str = text[i..run_end] }));
                    try sc.delims.append(b.allocator, .{
                        .item = item_idx,
                        .char = c,
                        .count = run_end - i,
                        .can_open = flank.can_open,
                        .can_close = flank.can_close,
                    });
                } else {
                    try sc.buf.appendSlice(b.allocator, text[i..run_end]);
                }
                i = run_end;
            },
            '[' => {
                try sc.flushBuf();
                const item_idx = try sc.appendItem(try b.addLeaf(.{ .str = "[" }));
                try sc.brackets.append(b.allocator, .{
                    .item = item_idx,
                    .is_image = false,
                    .active = true,
                    .content_start = i + 1,
                    .delim_stack_len = sc.delims.items.len,
                });
                i += 1;
            },
            '!' => {
                if (i + 1 < text.len and text[i + 1] == '[') {
                    try sc.flushBuf();
                    const item_idx = try sc.appendItem(try b.addLeaf(.{ .str = "![" }));
                    try sc.brackets.append(b.allocator, .{
                        .item = item_idx,
                        .is_image = true,
                        .active = true,
                        .content_start = i + 2,
                        .delim_stack_len = sc.delims.items.len,
                    });
                    i += 2;
                } else {
                    try sc.buf.append(b.allocator, '!');
                    i += 1;
                }
            },
            ']' => {
                try sc.flushBuf();
                i = try handleCloseBracket(&sc, text, i);
            },
            else => {
                try sc.buf.append(b.allocator, c);
                i += 1;
            },
        }
    }
    try sc.flushBuf();
    // Resolve whatever emphasis delimiters are left over the WHOLE stack.
    try sc.processEmphasis(0);

    var out = std.ArrayList(Node.Id).empty;
    errdefer out.deinit(b.allocator);
    var cur = sc.head;
    while (cur) |ci| {
        try out.append(b.allocator, sc.items.items[ci].node);
        cur = sc.items.items[ci].next;
    }
    return out.toOwnedSlice(b.allocator);
}

/// Backslash-escape and entity/numeric-character-reference decoding only —
/// no code spans, no break detection — for the plain-text contexts that
/// need *some* inline processing without being a full inline scan: a fenced
/// code block's info string (whose first word becomes `code_block.lang`;
/// CommonMark decodes entities there, e.g. `` ```f&ouml;&ouml; `` names the
/// language `föö`), link reference definition destinations/titles
/// (`block.zig`'s `stripLinkReferenceDefinitions`), and this file's own
/// inline link destination/title decoding (`handleCloseBracket`). Caller-
/// owned result.
pub fn decodeText(allocator: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\\' and i + 1 < text.len and isAsciiPunct(text[i + 1])) {
            try out.append(allocator, text[i + 1]);
            i += 2;
        } else if (c == '&') {
            if (try decodeCharRef(allocator, text, i)) |ref| {
                try out.appendSlice(allocator, ref.text);
                allocator.free(ref.text);
                i = ref.end;
            } else {
                try out.append(allocator, c);
                i += 1;
            }
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── the item list / delimiter stack / bracket stack ─────────────────────

const ItemIdx = u32;

/// One entry of the flat inline sequence `Scanner` builds. `node` is always
/// a real, already-`Builder`-owned AST node id — for a `*`/`_` delimiter run
/// or a `[`/`![` bracket, that's a placeholder `str` leaf holding the
/// literal run/bracket text, which `spliceEmphasis`/`finishLinkOrImage` may
/// later shrink (mutating `.node` in place, e.g. `"**"` -> `"*"` when one of
/// two delimiters gets consumed by a match) or bypass entirely (splicing an
/// `emph`/`strong`/`link`/`image` node in around it). `prev`/`next` link the
/// sequence WITHOUT requiring index-shifting array surgery on every match —
/// see this file's module doc comment.
const Item = struct {
    node: Node.Id,
    prev: ?ItemIdx = null,
    next: ?ItemIdx = null,
};

/// One `*`/`_` delimiter run currently eligible to participate in emphasis
/// matching (pushed only when `can_open or can_close` -- see `parseInline`),
/// referencing the `Item` (a placeholder `str` leaf) that holds its literal
/// text. `count` starts as the run's length and shrinks by 1 or 2 each time
/// `process_emphasis` consumes it as an opener/closer; the entry is dropped
/// from the stack once its count reaches 0 (see `removeDelimRange`).
const Delim = struct {
    item: ItemIdx,
    char: u8,
    count: usize,
    can_open: bool,
    can_close: bool,
};

/// One `[`/`![` opener currently eligible to close into a link/image,
/// referencing the `Item` (a placeholder `str` leaf holding `"["` or
/// `"!["`) that will be entirely discarded if this bracket successfully
/// resolves. `active` is CommonMark's "links may not contain other links"
/// flag: a just-closed LINK (not image) deactivates every non-image bracket
/// still on the stack below it (see `finishLinkOrImage`), so an outer `[`
/// can never also close around this same span.
const Bracket = struct {
    item: ItemIdx,
    is_image: bool,
    active: bool,
    /// Byte offset into the scanned text right after the opening `[`/`![`
    /// token -- the start of this bracket's own raw content, used both for
    /// the shortcut-reference fallback (the bracket's own text as the
    /// label) and to slice that text once the closing `]` is found.
    content_start: usize,
    /// `Scanner.delims.items.len` at the moment this bracket was pushed --
    /// the `stack_bottom` boundary `finishLinkOrImage` passes to
    /// `process_emphasis` when this bracket resolves, so emphasis matching
    /// for THIS bracket's contents never reaches back past delimiters that
    /// existed before it opened.
    delim_stack_len: usize,
};

const Scanner = struct {
    b: *Builder,
    link_refs: *const std.StringHashMapUnmanaged(Node.Id),
    buf: std.ArrayList(u8) = .empty,
    items: std.ArrayList(Item) = .empty,
    head: ?ItemIdx = null,
    tail: ?ItemIdx = null,
    delims: std.ArrayList(Delim) = .empty,
    brackets: std.ArrayList(Bracket) = .empty,

    fn deinit(self: *Scanner) void {
        self.buf.deinit(self.b.allocator);
        self.items.deinit(self.b.allocator);
        self.delims.deinit(self.b.allocator);
        self.brackets.deinit(self.b.allocator);
    }

    /// Flush accumulated plain-text `buf` into a single `str` item, if any
    /// is pending. Called before every non-literal item is pushed, so plain
    /// runs stay coalesced into one node exactly like Phase 1 did.
    fn flushBuf(self: *Scanner) Allocator.Error!void {
        if (self.buf.items.len == 0) return;
        const id = try self.b.addLeaf(.{ .str = self.buf.items });
        _ = try self.appendItem(id);
        self.buf.clearRetainingCapacity();
    }

    /// Append `node` as a new item at the current tail of the sequence.
    fn appendItem(self: *Scanner, node: Node.Id) Allocator.Error!ItemIdx {
        return self.insertItemBetween(self.tail, null, node);
    }

    /// Splice a new item wrapping `node` in between `left` and `right`
    /// (either may be `null` for "sequence start"/"sequence end"), updating
    /// `head`/`tail` as needed. Used both for plain appends (`appendItem`,
    /// `right = null`) and for splicing an `emph`/`strong`/`link`/`image`
    /// node into the middle of the sequence in place of whatever it just
    /// consumed.
    fn insertItemBetween(self: *Scanner, left: ?ItemIdx, right: ?ItemIdx, node: Node.Id) Allocator.Error!ItemIdx {
        const idx: ItemIdx = @intCast(self.items.items.len);
        try self.items.append(self.b.allocator, .{ .node = node, .prev = left, .next = right });
        if (left) |l| self.items.items[l].next = idx else self.head = idx;
        if (right) |r| self.items.items[r].prev = idx else self.tail = idx;
        return idx;
    }

    /// Remove `delims[start..end)` from the delimiter stack (bookkeeping
    /// only -- the underlying `Item`s/text are untouched; delimiters that
    /// never matched simply remain literal text). `Delim` has no pointers
    /// into itself, so a plain compaction is correct and simple.
    fn removeDelimRange(self: *Scanner, start: usize, end: usize) void {
        if (end <= start) return;
        const tail = self.delims.items[end..];
        std.mem.copyForwards(Delim, self.delims.items[start..][0..tail.len], tail);
        self.delims.items.len -= (end - start);
    }

    /// CommonMark's `process_emphasis`: bottom-up matching of `*`/`_`
    /// delimiter runs at stack positions `[stack_bottom..)` into `emph`/
    /// `strong` nodes. Scans closers left to right; for each, scans
    /// backward (no further than `stack_bottom`) for the nearest matching
    /// opener, applying the "rule of 3" (a delimiter that can both open and
    /// close can't pair with one whose combined run length is a multiple of
    /// 3 unless both individual lengths are). A match consumes 1 delimiter
    /// from each side (or 2, forming `strong`, when both runs have >= 2
    /// left) and may leave a shorter run in place on either side to be
    /// matched again. Delimiters within `[stack_bottom..)` that end up
    /// unmatched are simply left as literal text (their placeholder items
    /// are never touched) -- only the STACK bookkeeping above `stack_bottom`
    /// is discarded once this returns (see this file's module doc comment's
    /// note on the `openers_bottom` optimization this deliberately skips).
    fn processEmphasis(self: *Scanner, stack_bottom: usize) Allocator.Error!void {
        var closer_idx = stack_bottom;
        while (closer_idx < self.delims.items.len) {
            const closer = self.delims.items[closer_idx];
            if (!closer.can_close) {
                closer_idx += 1;
                continue;
            }

            var opener_idx: ?usize = null;
            if (closer_idx > stack_bottom) {
                var k = closer_idx;
                while (k > stack_bottom) {
                    k -= 1;
                    const cand = self.delims.items[k];
                    if (cand.can_open and cand.char == closer.char) {
                        if ((cand.can_open and cand.can_close) or (closer.can_open and closer.can_close)) {
                            const sum = cand.count + closer.count;
                            if (sum % 3 == 0 and !(cand.count % 3 == 0 and closer.count % 3 == 0)) {
                                // Rule of 3 violation for this pairing --
                                // keep scanning further back for another
                                // (earlier) opener instead.
                                continue;
                            }
                        }
                        opener_idx = k;
                        break;
                    }
                }
            }

            if (opener_idx) |oi| {
                const use_delims: usize = if (self.delims.items[oi].count >= 2 and closer.count >= 2) 2 else 1;
                const ch = closer.char;
                const opener_item = self.delims.items[oi].item;
                const closer_item = self.delims.items[closer_idx].item;

                var kids = std.ArrayList(Node.Id).empty;
                defer kids.deinit(self.b.allocator);
                var cur = self.items.items[opener_item].next;
                while (cur) |ci| {
                    if (ci == closer_item) break;
                    try kids.append(self.b.allocator, self.items.items[ci].node);
                    cur = self.items.items[ci].next;
                }
                const new_node = try self.b.addContainer(if (use_delims == 2) .strong else .emph, kids.items);

                self.delims.items[oi].count -= use_delims;
                self.delims.items[closer_idx].count -= use_delims;
                const opener_count = self.delims.items[oi].count;
                const closer_count = self.delims.items[closer_idx].count;

                try self.spliceEmphasis(opener_item, opener_count, closer_item, closer_count, ch, new_node);

                const del_start = if (opener_count > 0) oi + 1 else oi;
                const del_end = if (closer_count > 0) closer_idx else closer_idx + 1;
                self.removeDelimRange(del_start, del_end);
                closer_idx = if (closer_count > 0) oi + 1 else del_start;
            } else if (!closer.can_open) {
                // No opener found, and this closer can never itself open --
                // it will never match anything; drop it from the stack (it
                // stays as literal text) and re-examine whatever shifted
                // into this position.
                self.removeDelimRange(closer_idx, closer_idx + 1);
            } else {
                closer_idx += 1;
            }
        }
        // Whatever's left above `stack_bottom` had its chance; discard the
        // bookkeeping (the literal text underneath is untouched).
        self.delims.items.len = stack_bottom;
    }

    /// Insert the `emph`/`strong` node `new_node` (already built from
    /// `use_delims` delimiters' worth of content) in place of the matched
    /// portion of the opener/closer runs. If either run has leftover
    /// (unconsumed) delimiters, its placeholder item's text is shrunk in
    /// place to just the leftover characters and kept adjacent to
    /// `new_node`; if fully consumed, the item is dropped from the sequence
    /// entirely.
    fn spliceEmphasis(self: *Scanner, opener_item: ItemIdx, opener_count: usize, closer_item: ItemIdx, closer_count: usize, ch: u8, new_node: Node.Id) Allocator.Error!void {
        var left: ?ItemIdx = undefined;
        if (opener_count > 0) {
            self.items.items[opener_item].node = try makeRunStr(self.b, ch, opener_count);
            left = opener_item;
        } else {
            left = self.items.items[opener_item].prev;
        }
        var right: ?ItemIdx = undefined;
        if (closer_count > 0) {
            self.items.items[closer_item].node = try makeRunStr(self.b, ch, closer_count);
            right = closer_item;
        } else {
            right = self.items.items[closer_item].next;
        }
        _ = try self.insertItemBetween(left, right, new_node);
    }

    /// Resolve a just-matched link/image: `br` is the bracket being closed
    /// (already known active), `dest`/`title` its (already decoded)
    /// destination/title. Runs emphasis matching over the bracket's own
    /// contents first (so nested `*`/`_` bind INSIDE the link text, not
    /// across its boundary), gathers that content as the new node's
    /// children, splices the node in over the whole `[`/`![...]` span, and
    /// applies the "links cannot contain links" deactivation.
    fn finishLinkOrImage(self: *Scanner, br: Bracket, dest: []const u8, title: ?[]const u8) Allocator.Error!void {
        try self.processEmphasis(br.delim_stack_len);

        var kids = std.ArrayList(Node.Id).empty;
        defer kids.deinit(self.b.allocator);
        var cur = self.items.items[br.item].next;
        while (cur) |ci| {
            try kids.append(self.b.allocator, self.items.items[ci].node);
            cur = self.items.items[ci].next;
        }

        const kind: Node.Kind = if (br.is_image)
            .{ .image = .{ .destination = dest, .reference = null } }
        else
            .{ .link = .{ .destination = dest, .reference = null } };
        const node_id = try self.b.addContainer(kind, kids.items);
        if (title) |t| {
            try self.b.setAttrs(node_id, .{ .entries = &.{.{ .key = "title", .value = t }} });
        }

        const left = self.items.items[br.item].prev;
        _ = try self.insertItemBetween(left, null, node_id);

        _ = self.brackets.pop();
        if (!br.is_image) {
            // Links may not contain other links: any outer, still-open
            // plain `[` opener can never close into a link now (an outer
            // `![` image opener is unaffected -- images may contain links).
            for (self.brackets.items) |*outer| {
                if (!outer.is_image) outer.active = false;
            }
        }
    }
};

fn makeRunStr(b: *Builder, ch: u8, count: usize) Allocator.Error!Node.Id {
    const buf = try b.allocator.alloc(u8, count);
    defer b.allocator.free(buf);
    @memset(buf, ch);
    return b.addLeaf(.{ .str = buf });
}

// ── links / images ───────────────────────────────────────────────────────

/// The `Attrs` attached to `id` within an in-progress `Builder` -- the
/// `Builder`-side equivalent of `AST.attrsOf` (which only exists on a
/// finished `AST`). `block.zig`'s own `tryParseLinkRefDef` reaches into
/// `Builder.nodes`/`.attrs` directly the same way; struct fields in Zig have
/// no cross-file privacy, so this is the established pattern here.
fn builderAttrsOf(b: *Builder, id: Node.Id) AST.Attrs {
    const idx = b.nodes.items[id].attrs orelse return .{};
    return b.attrs.items[idx];
}

/// Trim + collapse internal whitespace runs to a single space + ASCII
/// lowercase -- duplicated from `block.zig`'s (private) `normalizeLabel`
/// rather than shared across files, so this file's link-label resolution
/// stays self-contained. Must stay byte-for-byte in sync with that
/// function, since both normalize against the SAME `Document.link_references`
/// keys.
fn normalizeRefLabel(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var in_ws = false;
    for (trimmed) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            if (!in_ws) try out.append(allocator, ' ');
            in_ws = true;
        } else {
            try out.append(allocator, std.ascii.toLower(c));
            in_ws = false;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Handle a `]` at `text[close_i]`: try to close it into a link/image
/// against the topmost bracket on the stack (inline `(...)` form first,
/// then full/collapsed/shortcut reference forms against `link_refs`), or
/// fall back to literal text. Returns the index to resume scanning from
/// (either just past a successfully matched link/image, or `close_i + 1`
/// for a literal `]`). See this file's module doc comment for the
/// "position only advances past a FAILED attempt's own `]`, never past
/// whatever it tentatively looked ahead at" rule this implements.
fn handleCloseBracket(sc: *Scanner, text: []const u8, close_i: usize) Allocator.Error!usize {
    if (sc.brackets.items.len == 0) {
        try sc.buf.append(sc.b.allocator, ']');
        return close_i + 1;
    }
    const br = sc.brackets.items[sc.brackets.items.len - 1];
    if (!br.active) {
        _ = sc.brackets.pop();
        try sc.buf.append(sc.b.allocator, ']');
        return close_i + 1;
    }

    // Inline form: `](dest "title")`, immediately following, no whitespace
    // allowed between `]` and `(`.
    if (close_i + 1 < text.len and text[close_i + 1] == '(') {
        if (scanInlineLinkTail(text, close_i + 1)) |raw| {
            const dest = try decodeText(sc.b.allocator, raw.dest_raw);
            defer sc.b.allocator.free(dest);
            const title = if (raw.title_raw) |t| try decodeText(sc.b.allocator, t) else null;
            defer if (title) |t| sc.b.allocator.free(t);
            try sc.finishLinkOrImage(br, dest, title);
            return raw.end;
        }
    }

    // Reference forms: full `][label]`, collapsed `][]`, or shortcut (no
    // second bracket at all -- the opener's own text is the label).
    var label_raw: []const u8 = text[br.content_start..close_i];
    var ref_end = close_i + 1;
    if (close_i + 1 < text.len and text[close_i + 1] == '[') {
        if (scanBracketLabel(text, close_i + 1)) |lbl| {
            ref_end = lbl.end;
            if (lbl.content.len > 0) label_raw = lbl.content; // else: collapsed, keep opener text
        }
        // An invalid second bracket (e.g. unescaped nested `[`) falls back
        // to the shortcut form using the opener's own text, WITHOUT
        // consuming the malformed second bracket -- see module doc comment.
    }
    const norm = try normalizeRefLabel(sc.b.allocator, label_raw);
    defer sc.b.allocator.free(norm);
    if (norm.len > 0) {
        if (sc.link_refs.get(norm)) |ref_id| {
            const dest = sc.b.nodes.items[ref_id].kind.reference.destination;
            const title = builderAttrsOf(sc.b, ref_id).get("title");
            try sc.finishLinkOrImage(br, dest, title);
            return ref_end;
        }
    }

    // No match: this bracket is spent (pop it), and only the `]` itself is
    // consumed as literal text -- whatever came after it (including any
    // `[...]` we just tentatively scanned as a label) is left for the main
    // loop to rescan from scratch.
    _ = sc.brackets.pop();
    try sc.buf.append(sc.b.allocator, ']');
    return close_i + 1;
}

const RawLinkTail = struct { dest_raw: []const u8, title_raw: ?[]const u8, end: usize };

/// `text[start] == '('`. Scans (without allocating) an inline link/image
/// tail: optional whitespace, an optional destination (`<...>` or a
/// balanced-paren/backslash-aware bareword; empty is valid, e.g. `[x]()`),
/// optional whitespace + an optional quoted title, optional whitespace, and
/// a closing `)`. Returns raw (still backslash/entity-encoded) slices into
/// `text` on success -- the caller decodes only once it knows the whole
/// thing matched, so a failed attempt never allocates.
fn scanInlineLinkTail(text: []const u8, start: usize) ?RawLinkTail {
    var i = start + 1;
    i = skipWs(text, i);
    var dest_raw: []const u8 = "";
    if (i < text.len and text[i] == ')') {
        return .{ .dest_raw = "", .title_raw = null, .end = i + 1 };
    }
    if (i < text.len and text[i] == '<') {
        const dstart = i + 1;
        var j = dstart;
        while (j < text.len and text[j] != '>' and text[j] != '\n') : (j += 1) {
            if (text[j] == '\\' and j + 1 < text.len) j += 1;
        }
        if (j >= text.len or text[j] != '>') return null;
        dest_raw = text[dstart..j];
        i = j + 1;
    } else {
        const dstart = i;
        var depth: usize = 0;
        var j = i;
        while (j < text.len) : (j += 1) {
            const ch = text[j];
            if (ch == '\\' and j + 1 < text.len and isAsciiPunct(text[j + 1])) {
                j += 1;
                continue;
            }
            if (ch == ' ' or ch == '\t' or ch == '\n' or std.ascii.isControl(ch)) break;
            if (ch == '(') depth += 1;
            if (ch == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
        }
        if (j == dstart or depth != 0) return null;
        dest_raw = text[dstart..j];
        i = j;
    }

    const after_dest = i;
    const ws_end = skipWs(text, after_dest);
    var title_raw: ?[]const u8 = null;
    if (ws_end > after_dest and ws_end < text.len and (text[ws_end] == '"' or text[ws_end] == '\'' or text[ws_end] == '(')) {
        const open = text[ws_end];
        const close: u8 = if (open == '(') ')' else open;
        var j = ws_end + 1;
        while (j < text.len and text[j] != close) : (j += 1) {
            if (text[j] == '\\' and j + 1 < text.len) j += 1;
        }
        if (j >= text.len) return null;
        title_raw = text[ws_end + 1 .. j];
        i = j + 1;
    } else {
        i = after_dest;
    }
    i = skipWs(text, i);
    if (i >= text.len or text[i] != ')') return null;
    return .{ .dest_raw = dest_raw, .title_raw = title_raw, .end = i + 1 };
}

const RawLabel = struct { content: []const u8, end: usize };

/// `text[start] == '['`. Scans a link LABEL (as opposed to link TEXT --
/// no nested brackets allowed at all, even balanced ones, per spec) up to
/// its closing `]`. Returns `null` if unterminated or if an unescaped `[`
/// appears before the close (an invalid label, per spec's "cannot contain
/// unescaped brackets" rule) or the label exceeds the spec's 999-character
/// cap.
fn scanBracketLabel(text: []const u8, start: usize) ?RawLabel {
    var i = start + 1;
    const content_start = i;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (c == '[') return null;
        if (c == ']') break;
    }
    if (i >= text.len or text[i] != ']') return null;
    if (i - content_start > 999) return null;
    return .{ .content = text[content_start..i], .end = i + 1 };
}

/// Whitespace per the inline link-tail/HTML-tag grammars: any run of
/// spaces, tabs, and line endings (line endings are always bare `\n` here --
/// see this file's module doc comment on `text` never containing `\r`).
fn skipWs(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n')) i += 1;
    return i;
}

// ── autolinks ────────────────────────────────────────────────────────────

/// `text[at] == '<'`. An absolute-URI autolink: `<scheme:rest>` where
/// `scheme` is 2-32 characters (a letter, then letters/digits/`+`/`-`/`.`)
/// and `rest` contains no ASCII control characters, space, `<`, or `>`.
fn scanAutolinkUri(text: []const u8, at: usize) ?usize {
    var i = at + 1;
    if (i >= text.len or !std.ascii.isAlphabetic(text[i])) return null;
    const scheme_start = i;
    i += 1;
    while (i < text.len and (i - scheme_start) < 32 and
        (std.ascii.isAlphanumeric(text[i]) or text[i] == '+' or text[i] == '-' or text[i] == '.')) : (i += 1)
    {}
    if (i - scheme_start < 2) return null;
    if (i >= text.len or text[i] != ':') return null;
    i += 1;
    while (i < text.len and text[i] != '>' and text[i] != '<' and text[i] != ' ' and !std.ascii.isControl(text[i])) : (i += 1) {}
    if (i >= text.len or text[i] != '>') return null;
    return i + 1;
}

fn isEmailLocalChar(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return switch (c) {
        '.', '!', '#', '$', '%', '&', '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', '-' => true,
        else => false,
    };
}

/// One dot-separated domain label of an email autolink:
/// `[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?` -- must start AND end
/// with an alphanumeric, with up to 63 characters total. Advances `i.*` past
/// the label (trimming any trailing hyphens off the accepted length, since
/// the label must end in an alphanumeric) and returns whether a label was
/// present at all.
fn scanEmailDomainLabel(text: []const u8, i: *usize) bool {
    const start = i.*;
    if (start >= text.len or !std.ascii.isAlphanumeric(text[start])) return false;
    var j = start + 1;
    var end = j;
    while (j < text.len and (j - start) < 63 and (std.ascii.isAlphanumeric(text[j]) or text[j] == '-')) : (j += 1) {
        if (std.ascii.isAlphanumeric(text[j])) end = j + 1;
    }
    i.* = end;
    return true;
}

/// `text[at] == '<'`. An email autolink per CommonMark's (deliberately
/// restrictive, not RFC 5322) grammar: a nonempty local part, `@`, and one
/// or more dot-separated domain labels.
fn scanAutolinkEmail(text: []const u8, at: usize) ?usize {
    var i = at + 1;
    const local_start = i;
    while (i < text.len and isEmailLocalChar(text[i])) i += 1;
    if (i == local_start) return null;
    if (i >= text.len or text[i] != '@') return null;
    i += 1;
    if (!scanEmailDomainLabel(text, &i)) return null;
    while (i < text.len and text[i] == '.') {
        const save = i;
        i += 1;
        if (!scanEmailDomainLabel(text, &i)) {
            i = save;
            break;
        }
    }
    if (i >= text.len or text[i] != '>') return null;
    return i + 1;
}

// ── raw inline HTML ─────────────────────────────────────────────────────

fn isAttrNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == ':';
}

fn isAttrNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == ':' or c == '-';
}

/// `text[at] == '<'`, dispatching to whichever raw-HTML production
/// applies based on the next character (`/` close tag, `?` processing
/// instruction, `!` comment/CDATA/declaration, else an open tag).
fn scanHtmlTag(text: []const u8, at: usize) ?usize {
    if (at + 1 >= text.len) return null;
    return switch (text[at + 1]) {
        '/' => scanHtmlCloseTag(text, at),
        '?' => scanHtmlPI(text, at),
        '!' => blk: {
            if (std.mem.startsWith(u8, text[at..], "<!--")) break :blk scanHtmlComment(text, at);
            if (std.mem.startsWith(u8, text[at..], "<![CDATA[")) break :blk scanHtmlCData(text, at);
            break :blk scanHtmlDeclaration(text, at);
        },
        else => scanHtmlOpenTag(text, at),
    };
}

/// `text[at] == '<'`. An HTML open tag: a tag name, zero or more
/// attributes, optional whitespace, an optional `/`, and `>`.
fn scanHtmlOpenTag(text: []const u8, at: usize) ?usize {
    var i = at + 1;
    if (i >= text.len or !std.ascii.isAlphabetic(text[i])) return null;
    i += 1;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-')) i += 1;

    while (true) {
        const before_ws = i;
        const after_ws = skipWs(text, i);
        if (after_ws == before_ws) break;
        if (after_ws < text.len and isAttrNameStart(text[after_ws])) {
            var j = after_ws + 1;
            while (j < text.len and isAttrNameChar(text[j])) j += 1;
            const name_end = j;
            const after_name_ws = skipWs(text, name_end);
            if (after_name_ws < text.len and text[after_name_ws] == '=') {
                var k = skipWs(text, after_name_ws + 1);
                if (k >= text.len) return null;
                const qc = text[k];
                if (qc == '"' or qc == '\'') {
                    k += 1;
                    while (k < text.len and text[k] != qc) k += 1;
                    if (k >= text.len) return null;
                    i = k + 1;
                } else {
                    const vstart = k;
                    while (k < text.len and !std.ascii.isWhitespace(text[k]) and
                        text[k] != '"' and text[k] != '\'' and text[k] != '=' and
                        text[k] != '<' and text[k] != '>' and text[k] != '`') : (k += 1)
                    {}
                    if (k == vstart) return null;
                    i = k;
                }
            } else {
                i = name_end;
            }
        } else {
            i = before_ws;
            break;
        }
    }

    i = skipWs(text, i);
    if (i < text.len and text[i] == '/') i += 1;
    if (i >= text.len or text[i] != '>') return null;
    return i + 1;
}

/// `text[at] == '<'`. An HTML closing tag: `</`, a tag name, optional
/// whitespace, `>`.
fn scanHtmlCloseTag(text: []const u8, at: usize) ?usize {
    var i = at + 2;
    if (i >= text.len or !std.ascii.isAlphabetic(text[i])) return null;
    i += 1;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-')) i += 1;
    i = skipWs(text, i);
    if (i >= text.len or text[i] != '>') return null;
    return i + 1;
}

/// `text[at..at+4] == "<!--"`. An HTML comment per the HTML5-aligned
/// grammar: text that does not start with `>`/`->`, does not contain `--`,
/// and (implied by "does not contain --", since the closer itself starts
/// with `--`) does not end with `-`.
fn scanHtmlComment(text: []const u8, at: usize) ?usize {
    var j = at + 4;
    if (j < text.len and text[j] == '>') return null;
    if (j + 1 < text.len and text[j] == '-' and text[j + 1] == '>') return null;
    while (j + 1 < text.len) : (j += 1) {
        if (text[j] == '-' and text[j + 1] == '-') {
            if (j + 2 < text.len and text[j + 2] == '>') return j + 3;
            return null;
        }
    }
    return null;
}

/// `text[at..at+2] == "<?"`. A processing instruction: everything up to
/// the first `?>`.
fn scanHtmlPI(text: []const u8, at: usize) ?usize {
    const start = at + 2;
    const idx = std.mem.indexOfPos(u8, text, start, "?>") orelse return null;
    return idx + 2;
}

/// `text[at..at+2] == "<!"`. A declaration: `<!`, one or more uppercase
/// ASCII letters, at least one whitespace character, then everything up to
/// the first `>`.
fn scanHtmlDeclaration(text: []const u8, at: usize) ?usize {
    var i = at + 2;
    const name_start = i;
    while (i < text.len and std.ascii.isUpper(text[i])) i += 1;
    if (i == name_start) return null;
    if (i >= text.len or !std.ascii.isWhitespace(text[i])) return null;
    const gt = std.mem.indexOfScalarPos(u8, text, i, '>') orelse return null;
    return gt + 1;
}

/// `text[at..].startsWith("<![CDATA[")`. A CDATA section: everything up to
/// the first `]]>`.
fn scanHtmlCData(text: []const u8, at: usize) ?usize {
    const start = at + "<![CDATA[".len;
    const idx = std.mem.indexOfPos(u8, text, start, "]]>") orelse return null;
    return idx + 3;
}

// ── emphasis flanking (CommonMark 6.2) ──────────────────────────────────

const Flank = struct { can_open: bool, can_close: bool };

/// Classify a `*`/`_` delimiter run `text[run_start..run_end)` per
/// CommonMark's left/right-flanking rules, folding in `_`'s extra
/// "intraword" restriction (rules 1-8 of "Emphasis and strong emphasis").
/// The "rule of 3" (multiples-of-3 length interaction between an opener and
/// closer) is a separate, pairwise concern handled during matching
/// (`Scanner.processEmphasis`), not here.
fn computeFlanking(text: []const u8, run_start: usize, run_end: usize, ch: u8) Flank {
    const before_cp = codepointBefore(text, run_start);
    const after_cp = codepointAfter(text, run_end);

    const before_is_ws = before_cp == null or isUnicodeWhitespaceCp(before_cp.?);
    const before_is_punct = before_cp != null and isUnicodePunctuationCp(before_cp.?);
    const after_is_ws = after_cp == null or isUnicodeWhitespaceCp(after_cp.?);
    const after_is_punct = after_cp != null and isUnicodePunctuationCp(after_cp.?);

    const left_flanking = !after_is_ws and (!after_is_punct or before_is_ws or before_is_punct);
    const right_flanking = !before_is_ws and (!before_is_punct or after_is_ws or after_is_punct);

    if (ch == '_') {
        return .{
            .can_open = left_flanking and (!right_flanking or before_is_punct),
            .can_close = right_flanking and (!left_flanking or after_is_punct),
        };
    }
    return .{ .can_open = left_flanking, .can_close = right_flanking };
}

fn codepointAt(text: []const u8, i: usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return text[i];
    if (i + len > text.len) return text[i];
    return std.unicode.utf8Decode(text[i .. i + len]) catch text[i];
}

/// The code point starting at byte offset `i`, or `null` at end of text
/// (end of text counts as Unicode whitespace for flanking purposes, per
/// spec, which callers get for free by treating `null` as whitespace).
fn codepointAfter(text: []const u8, i: usize) ?u21 {
    if (i >= text.len) return null;
    return codepointAt(text, i);
}

/// The code point ending at byte offset `i` (i.e. immediately before it),
/// or `null` at start of text. Walks back over UTF-8 continuation bytes to
/// find the lead byte of the preceding code point.
fn codepointBefore(text: []const u8, i: usize) ?u21 {
    if (i == 0) return null;
    var start = i - 1;
    var back: usize = 0;
    while (start > 0 and (text[start] & 0xC0) == 0x80 and back < 3) : (back += 1) start -= 1;
    return codepointAt(text, start);
}

/// Unicode whitespace per CommonMark: Unicode `Zs` (space separator) code
/// points, plus tab/LF/FF/CR (which, for ASCII, is exactly
/// `std.ascii.isWhitespace`). Non-ASCII coverage is the common `Zs` code
/// points, not the complete set -- see this file's module doc comment.
fn isUnicodeWhitespaceCp(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isWhitespace(@intCast(cp));
    return switch (cp) {
        0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// Unicode punctuation per CommonMark: code points in the Unicode P
/// (punctuation) or S (symbol) general categories. For ASCII this is
/// exactly `isAsciiPunct`; non-ASCII coverage is a curated table of common
/// blocks (General Punctuation, CJK punctuation, fullwidth ASCII forms),
/// not the complete Unicode category tables -- see this file's module doc
/// comment.
fn isUnicodePunctuationCp(cp: u21) bool {
    if (cp < 0x80) return isAsciiPunct(@intCast(cp));
    return switch (cp) {
        0x2010...0x2027, 0x2030...0x205E => true, // General Punctuation (dashes, quotes, ellipsis, etc.)
        0x3001...0x303F => true, // CJK punctuation
        0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65 => true, // fullwidth ASCII punctuation
        else => false,
    };
}

/// After a break has just been consumed (the input cursor is right past the
/// `\n`), skip leading spaces/tabs on the following line — CommonMark's "a
/// line ending... [with] spaces at the end of the line and the beginning of
/// the next line ... removed" rule.
fn skipLeadingLineSpace(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

/// How many of `buf`'s trailing bytes are the spaces that (per the hard-break
/// rule) should be stripped before the line break they precede — 0 if fewer
/// than two, otherwise the full run length (all get stripped either way; the
/// caller distinguishes hard vs. soft by comparing this count against 2).
fn trailingHardBreakSpaces(buf: []const u8) usize {
    var n: usize = 0;
    while (n < buf.len and buf[buf.len - 1 - n] == ' ') n += 1;
    return n;
}

fn isAsciiPunct(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

// ── code spans ───────────────────────────────────────────────────────────

const CodeSpan = struct { end: usize, content_start: usize, content_end: usize };

/// `text[start] == '\''`, sorry — `'`` '`. Finds a closing backtick run of
/// exactly the same length as the opening run, per CommonMark's "Code
/// spans": the shortest such match starting after the opener. Returns `null`
/// if no run of matching length exists anywhere later in `text`, in which
/// case the opening backticks are literal text (handled by the caller).
fn scanCodeSpan(text: []const u8, start: usize) ?CodeSpan {
    var i = start;
    while (i < text.len and text[i] == '`') i += 1;
    const open_len = i - start;
    const content_start = i;
    var j = i;
    while (j < text.len) {
        if (text[j] == '`') {
            const run_start = j;
            while (j < text.len and text[j] == '`') j += 1;
            if (j - run_start == open_len) {
                return .{ .end = j, .content_start = content_start, .content_end = run_start };
            }
        } else {
            j += 1;
        }
    }
    return null;
}

/// Line endings inside a code span become spaces, and if the resulting
/// string both begins and ends with a space (but isn't all spaces), one
/// leading and one trailing space are stripped. Mirrors CommonMark's code
/// span content normalization.
fn normalizeCodeSpan(allocator: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (raw) |c| try out.append(allocator, if (c == '\n') ' ' else c);

    if (out.items.len >= 2 and out.items[0] == ' ' and out.items[out.items.len - 1] == ' ') {
        var all_spaces = true;
        for (out.items) |c| {
            if (c != ' ') {
                all_spaces = false;
                break;
            }
        }
        if (!all_spaces) {
            _ = out.orderedRemove(0);
            out.items.len -= 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── entity / numeric character references ──────────────────────────────

const CharRef = struct { text: []u8, end: usize };

/// `text[at] == '&'`. Returns the decoded UTF-8 replacement (caller-owned)
/// and the index just past the reference on success, or `null` if `text[at]`
/// doesn't begin a valid reference (in which case the `&` is literal).
fn decodeCharRef(allocator: Allocator, text: []const u8, at: usize) Allocator.Error!?CharRef {
    var i = at + 1;
    if (i < text.len and text[i] == '#') {
        i += 1;
        const hex = i < text.len and (text[i] == 'x' or text[i] == 'X');
        if (hex) i += 1;
        const digits_start = i;
        while (i < text.len and (if (hex) std.ascii.isHex(text[i]) else std.ascii.isDigit(text[i]))) i += 1;
        const digits = text[digits_start..i];
        // CommonMark caps decimal numeric references at 7 digits and
        // hexadecimal ones at 6 (`&#87654321;`, at 8 digits, is NOT a
        // reference at all -- it stays literal text, distinct from a
        // reference whose value is merely out of Unicode's range, which
        // decodes to U+FFFD).
        const max_digits: usize = if (hex) 6 else 7;
        if (digits.len == 0 or digits.len > max_digits) return null;
        if (i >= text.len or text[i] != ';') return null;
        const value = std.fmt.parseInt(u32, digits, if (hex) 16 else 10) catch return null;
        const cp: u21 = if (value == 0 or value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF))
            0xFFFD
        else
            @intCast(value);
        var stack_buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &stack_buf) catch blk: {
            // A surrogate or otherwise-invalid scalar slipped through the
            // check above (shouldn't happen given it above); fall back to
            // the replacement character rather than propagate the error.
            break :blk std.unicode.utf8Encode(0xFFFD, &stack_buf) catch unreachable;
        };
        // Allocate exactly `n` bytes (not the 4-byte scratch buffer's
        // size) so the caller can `free` the returned slice directly —
        // freeing a slice shorter than its original allocation is invalid.
        return .{ .text = try allocator.dupe(u8, stack_buf[0..n]), .end = i + 1 };
    }

    const name_start = i;
    while (i < text.len and std.ascii.isAlphanumeric(text[i])) i += 1;
    const name = text[name_start..i];
    if (name.len == 0 or i >= text.len or text[i] != ';') return null;
    const replacement = entities.table.get(name) orelse return null;
    return .{ .text = try allocator.dupe(u8, replacement), .end = i + 1 };
}

const testing = std.testing;

const empty_refs: std.StringHashMapUnmanaged(Node.Id) = .empty;

fn parseAndFinish(text: []const u8) !AST {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const children = try parseInline(&b, text, &empty_refs);
    defer b.allocator.free(children);
    const root = try b.addContainer(.para, children);
    return b.finish(root);
}

test "plain text becomes a single str node" {
    var ast = try parseAndFinish("hello world");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("hello world", ast.nodes[child].kind.str);
}

test "backslash escape yields the literal punctuation character" {
    var ast = try parseAndFinish("\\*not emphasis\\*");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("*not emphasis*", ast.nodes[child].kind.str);
}

test "a backslash before a non-punctuation character is literal" {
    var ast = try parseAndFinish("\\a");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("\\a", ast.nodes[child].kind.str);
}

test "named and numeric entities decode to UTF-8" {
    var ast = try parseAndFinish("&amp; &#65; &#x41;");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("& A A", ast.nodes[child].kind.str);
}

test "an unknown entity name stays literal" {
    var ast = try parseAndFinish("&nosuchentity;");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("&nosuchentity;", ast.nodes[child].kind.str);
}

test "code span strips one matching leading/trailing space and converts newlines to spaces" {
    var ast = try parseAndFinish("a `` `foo` `` b");
    defer ast.deinit();
    var it = ast.children(ast.root);
    const s1 = it.next().?;
    try testing.expectEqualStrings("a ", s1.kind.str);
    const code = it.next().?;
    try testing.expectEqualStrings("`foo`", code.kind.verbatim);
    const s2 = it.next().?;
    try testing.expectEqualStrings(" b", s2.kind.str);
}

test "two trailing spaces before a line ending produce a hard break" {
    var ast = try parseAndFinish("foo  \nbar");
    defer ast.deinit();
    var it = ast.children(ast.root);
    const s1 = it.next().?;
    try testing.expectEqualStrings("foo", s1.kind.str);
    const brk = it.next().?;
    try testing.expect(brk.kind == .hard_break);
    const s2 = it.next().?;
    try testing.expectEqualStrings("bar", s2.kind.str);
}

test "a backslash before a line ending produces a hard break" {
    var ast = try parseAndFinish("foo\\\nbar");
    defer ast.deinit();
    var it = ast.children(ast.root);
    _ = it.next().?;
    const brk = it.next().?;
    try testing.expect(brk.kind == .hard_break);
}

test "a plain line ending is a soft break" {
    var ast = try parseAndFinish("foo\nbar");
    defer ast.deinit();
    var it = ast.children(ast.root);
    _ = it.next().?;
    const brk = it.next().?;
    try testing.expect(brk.kind == .soft_break);
}

test "simple emphasis and strong emphasis" {
    var ast = try parseAndFinish("*em* and **strong**");
    defer ast.deinit();
    var it = ast.children(ast.root);
    const em = it.next().?;
    try testing.expect(em.kind == .emph);
    try testing.expectEqualStrings("em", ast.nodes[em.first_child.?].kind.str);
    _ = it.next().?; // " and "
    const strong = it.next().?;
    try testing.expect(strong.kind == .strong);
    try testing.expectEqualStrings("strong", ast.nodes[strong.first_child.?].kind.str);
}

test "nested emphasis inside strong inside emphasis" {
    // *a **b** c* -> <em>a <strong>b</strong> c</em>
    var ast = try parseAndFinish("*a **b** c*");
    defer ast.deinit();
    const em = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[em].kind == .emph);
    var it = ast.children(em);
    const t1 = it.next().?;
    try testing.expectEqualStrings("a ", t1.kind.str);
    const strong = it.next().?;
    try testing.expect(strong.kind == .strong);
    try testing.expectEqualStrings("b", ast.nodes[strong.first_child.?].kind.str);
    const t2 = it.next().?;
    try testing.expectEqualStrings(" c", t2.kind.str);
}

test "underscore emphasis and asterisk strong side by side" {
    var ast = try parseAndFinish("**a** and _b_");
    defer ast.deinit();
    var it = ast.children(ast.root);
    const strong = it.next().?;
    try testing.expect(strong.kind == .strong);
    _ = it.next().?; // " and "
    const em = it.next().?;
    try testing.expect(em.kind == .emph);
    try testing.expectEqualStrings("b", ast.nodes[em.first_child.?].kind.str);
}

test "intraword underscore does not open emphasis" {
    var ast = try parseAndFinish("a_b_c");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("a_b_c", ast.nodes[child].kind.str);
}

test "asterisk strong can start immediately after a word (no intraword restriction)" {
    var ast = try parseAndFinish("foo**bar**baz");
    defer ast.deinit();
    var it = ast.children(ast.root);
    const t1 = it.next().?;
    try testing.expectEqualStrings("foo", t1.kind.str);
    const strong = it.next().?;
    try testing.expect(strong.kind == .strong);
    try testing.expectEqualStrings("bar", ast.nodes[strong.first_child.?].kind.str);
    const t2 = it.next().?;
    try testing.expectEqualStrings("baz", t2.kind.str);
}

test "inline link with a title" {
    var ast = try parseAndFinish("[foo](/url \"title\")");
    defer ast.deinit();
    const link = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[link].kind == .link);
    try testing.expectEqualStrings("/url", ast.nodes[link].kind.link.destination.?);
    try testing.expectEqual(@as(?[]const u8, null), ast.nodes[link].kind.link.reference);
    try testing.expectEqualStrings("title", ast.attrsOf(link).get("title").?);
    try testing.expectEqualStrings("foo", ast.nodes[ast.nodes[link].first_child.?].kind.str);
}

test "inline image" {
    var ast = try parseAndFinish("![alt text](/img.png)");
    defer ast.deinit();
    const img = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[img].kind == .image);
    try testing.expectEqualStrings("/img.png", ast.nodes[img].kind.image.destination.?);
    try testing.expectEqualStrings("alt text", ast.nodes[ast.nodes[img].first_child.?].kind.str);
}

test "autolink URI and email" {
    var ast = try parseAndFinish("<https://example.com> <foo@bar.com>");
    defer ast.deinit();
    var it = ast.children(ast.root);
    const url = it.next().?;
    try testing.expect(url.kind == .url);
    try testing.expectEqualStrings("https://example.com", url.kind.url);
    _ = it.next().?; // " "
    const email = it.next().?;
    try testing.expect(email.kind == .email);
    try testing.expectEqualStrings("foo@bar.com", email.kind.email);
}

test "raw inline HTML passes through as raw_inline" {
    var ast = try parseAndFinish("a <span class=\"x\"> b");
    defer ast.deinit();
    var it = ast.children(ast.root);
    _ = it.next().?; // "a "
    const raw = it.next().?;
    try testing.expect(raw.kind == .raw_inline);
    try testing.expectEqualStrings("html", raw.kind.raw_inline.format);
    try testing.expectEqualStrings("<span class=\"x\">", raw.kind.raw_inline.text);
}

/// Builds a one-entry `link_references` table (mirroring what `block.zig`
/// hands `parseInline` for a real document) so full/collapsed/shortcut
/// reference-link resolution can be exercised without going through the
/// block parser.
fn parseWithOneReference(text: []const u8, label: []const u8, dest: []const u8) !AST {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const ref_id = try b.addLeaf(.{ .reference = .{ .label = label, .destination = dest } });
    var refs: std.StringHashMapUnmanaged(Node.Id) = .empty;
    defer refs.deinit(testing.allocator);
    try refs.put(testing.allocator, b.nodes.items[ref_id].kind.reference.label, ref_id);

    const children = try parseInline(&b, text, &refs);
    defer b.allocator.free(children);
    const root = try b.addContainer(.para, children);
    return b.finish(root);
}

test "full reference link resolves against link_references" {
    var ast = try parseWithOneReference("[foo][bar]", "bar", "/url");
    defer ast.deinit();
    const link = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[link].kind == .link);
    try testing.expectEqualStrings("/url", ast.nodes[link].kind.link.destination.?);
    try testing.expectEqualStrings("foo", ast.nodes[ast.nodes[link].first_child.?].kind.str);
}

test "collapsed reference link resolves against link_references" {
    var ast = try parseWithOneReference("[foo][]", "foo", "/url");
    defer ast.deinit();
    const link = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[link].kind == .link);
    try testing.expectEqualStrings("/url", ast.nodes[link].kind.link.destination.?);
}

test "shortcut reference link resolves against link_references" {
    var ast = try parseWithOneReference("[foo]", "foo", "/url");
    defer ast.deinit();
    const link = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[link].kind == .link);
    try testing.expectEqualStrings("/url", ast.nodes[link].kind.link.destination.?);
}

test "an unresolved reference label falls back to literal brackets" {
    var ast = try parseWithOneReference("[foo][nope]", "bar", "/url");
    defer ast.deinit();
    // A failed match doesn't re-coalesce its `[`/text/`]` fragments back
    // into one node (each bracket attempt got its own placeholder item
    // along the way) -- concatenating every child's literal text is the
    // right way to check "this rendered as plain text", not a single node's
    // `.str` field. (The HTML output is identical either way.)
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    var it = ast.children(ast.root);
    while (it.next()) |n| try buf.appendSlice(testing.allocator, n.kind.str);
    try testing.expectEqualStrings("[foo][nope]", buf.items);
}

test "unhandled inline markup (unresolved brackets) passes through as literal text" {
    var ast = try parseAndFinish("[link](url)");
    defer ast.deinit();
    // No reference table entry and a syntactically valid inline destination
    // -- this one DOES resolve (Phase 2); assert the structured result
    // instead of literal passthrough, which was Phase 1's contract for this
    // exact input.
    const link = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[link].kind == .link);
}
