//! CommonMark block structure: source text -> `AST`, via an incremental
//! line-by-line scan that mirrors the strategy sketched in the CommonMark
//! spec's own "Appendix: A parsing strategy" (and implemented, in spirit, by
//! `cmark`/`commonmark.js`) — maintain a stack of currently OPEN block
//! containers (the document, plus any block quotes / list items nested
//! inside it) and, for each input line, (1) match as much of the line as
//! possible against that stack's markers/indentation, (2) decide whether
//! the containers that failed to match should really close (vs. this being
//! a *lazy continuation* line of an open paragraph, which doesn't need to
//! repeat its ancestors' markers), (3) either continue an open leaf block
//! (paragraph/code/HTML) or scan the remaining text for a new block start.
//!
//! Unlike `languages/djot/parser.zig` (which manages its own flat node
//! array because it needs to mutate already-emitted nodes), this builds
//! purely bottom-up — a container's children are fully known before the
//! container itself is ever handed to `AST.Builder.addContainer` — so
//! `Builder`'s batch-children API fits directly (see `languages/xml/parser.zig`
//! for the same shape of recursive-descent-onto-`Builder` this mirrors,
//! modulo the block scan being iterative-over-lines rather than
//! recursive-over-tags).
//!
//! ── Scope (Phase 1) ─────────────────────────────────────────────────────
//! Implements CommonMark block structure per the mission: blank lines, ATX
//! and setext headings, thematic breaks, indented and fenced code blocks,
//! block quotes (with lazy continuation), bullet/ordered lists (marker
//! parsing, start number, tight/loose detection), paragraphs, the 7 HTML
//! block start conditions, and link reference definitions (parsed, stripped
//! from the block stream, and recorded in `link_references` — never
//! rendered as nodes themselves). Inline content is delegated to
//! `inline.zig`'s deliberately minimal Phase 1 subset.
//!
//! ── Documented simplifications ───────────────────────────────────────────
//! These are approximations of the full CommonMark grammar, each chosen to
//! keep this file tractable; `conformance.zig` reports the resulting gap
//! against the spec's own test suite rather than papering over it:
//!   - Tabs: a tab always advances the column to the next multiple of 4 (per
//!     spec), but when consuming a *bounded* number of indent columns (e.g.
//!     "at most 3" before a block-quote marker), a tab that would overshoot
//!     the bound is left unconsumed rather than being split into partial
//!     spaces — CommonMark's own reference dialect partially expands such a
//!     tab; the "Tabs" section of the spec test suite exercises exactly this
//!     and is where this shows up.
//!   - List-item tight/loose detection uses the standard "blank line seen
//!     while the list is open, followed by more content added to it before
//!     it closes" rule (see `markListsLoose`/`Container.blank_pending`),
//!     which matches the spec's definition but is tracked with a simpler
//!     bookkeeping scheme than cmark's; deeply nested blank-line placements
//!     are less exhaustively tested here.
//!   - HTML block type 7 (a bare complete tag with nothing else on the
//!     line) uses a hand-rolled approximation of the HTML tag grammar
//!     (`parseCompleteTag`) rather than the full attribute-value grammar.
//!   - Link reference definitions: if a title candidate is present but
//!     malformed (trailing non-whitespace after its closing delimiter), the
//!     whole definition attempt is rejected rather than the spec's
//!     backtrack-and-retry-without-a-title.
//!   - Label/link-reference normalization case-folds ASCII only (not full
//!     Unicode case folding).

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../../ast/ast.zig");
const Node = AST.Node;
const Builder = AST.Builder;
const Span = @import("../../span.zig");
const Options = @import("options.zig");
const inline_mod = @import("inline.zig");

pub const BlockResult = struct {
    ast: AST,
    link_references: std.StringHashMapUnmanaged(Node.Id),
};

// ── low-level line/column helpers ───────────────────────────────────────

const Cursor = struct { pos: usize = 0, col: usize = 0 };

fn isBlankLine(s: []const u8) bool {
    for (s) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

/// Columns of leading whitespace from `cur`, tabs advancing to the next
/// multiple-of-4 column (per CommonMark's tab-handling rule).
fn indentCols(line: []const u8, cur: Cursor) usize {
    var col = cur.col;
    var i = cur.pos;
    while (i < line.len) {
        if (line[i] == ' ') {
            col += 1;
            i += 1;
        } else if (line[i] == '\t') {
            col += 4 - (col % 4);
            i += 1;
        } else break;
    }
    return col - cur.col;
}

/// Consume up to `max_cols` columns of leading whitespace. A tab that would
/// overshoot `max_cols` is left unconsumed (see this file's module doc
/// comment's "Tabs" simplification).
fn skipWsUpToCols(line: []const u8, cur: Cursor, max_cols: usize) Cursor {
    var col = cur.col;
    var i = cur.pos;
    var consumed: usize = 0;
    while (i < line.len and consumed < max_cols) {
        const c = line[i];
        if (c == ' ') {
            col += 1;
            i += 1;
            consumed += 1;
        } else if (c == '\t') {
            const step = 4 - (col % 4);
            if (consumed + step > max_cols) break;
            col += step;
            i += 1;
            consumed += step;
        } else break;
    }
    return .{ .pos = i, .col = col };
}

/// Consume leading whitespace until reaching (at least) `target_col`
/// columns, or until a non-whitespace byte is hit.
fn skipWsToTarget(line: []const u8, cur: Cursor, target_col: usize) Cursor {
    var col = cur.col;
    var i = cur.pos;
    while (i < line.len and col < target_col) {
        const c = line[i];
        if (c == ' ') {
            col += 1;
            i += 1;
        } else if (c == '\t') {
            col += 4 - (col % 4);
            i += 1;
        } else break;
    }
    return .{ .pos = i, .col = col };
}

fn stripUpTo3Indent(s: []const u8) []const u8 {
    const c = skipWsUpToCols(s, .{}, 3);
    return s[c.pos..];
}

fn trimLeadingWs(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

fn isAsciiLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn isAsciiLetterOrDigit(c: u8) bool {
    return isAsciiLetter(c) or (c >= '0' and c <= '9');
}

// ── block-start pattern matchers (pure; operate on an indent-stripped line) ─

fn isThematicBreak(s: []const u8) bool {
    var count: usize = 0;
    var ch: u8 = 0;
    for (s) |c| {
        if (c == '*' or c == '-' or c == '_') {
            if (ch == 0) ch = c else if (c != ch) return false;
            count += 1;
        } else if (c == ' ' or c == '\t') {
            // ok
        } else return false;
    }
    return count >= 3;
}

const AtxHeading = struct { level: u32, content: []const u8 };

fn tryAtxHeading(s: []const u8) ?AtxHeading {
    var i: usize = 0;
    while (i < s.len and s[i] == '#') i += 1;
    if (i == 0 or i > 6) return null;
    if (i < s.len and s[i] != ' ' and s[i] != '\t') return null;
    var content_start = i;
    while (content_start < s.len and (s[content_start] == ' ' or s[content_start] == '\t')) content_start += 1;
    var end = s.len;
    while (end > content_start and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    var hash_start = end;
    while (hash_start > content_start and s[hash_start - 1] == '#') hash_start -= 1;
    if (hash_start < end and (hash_start == content_start or s[hash_start - 1] == ' ' or s[hash_start - 1] == '\t')) {
        end = hash_start;
        while (end > content_start and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    }
    return .{ .level = @intCast(i), .content = s[content_start..end] };
}

/// A setext underline: a line consisting solely of `=` characters (level 1)
/// or solely of `-` characters (level 2), with any number of trailing
/// spaces/tabs.
fn trySetextUnderline(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    const ch = s[0];
    if (ch != '=' and ch != '-') return null;
    var i: usize = 0;
    while (i < s.len and s[i] == ch) i += 1;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    if (i != s.len) return null;
    return if (ch == '=') 1 else 2;
}

const FenceOpen = struct { char: u8, len: usize, info: []const u8 };

fn tryFenceOpen(s: []const u8) ?FenceOpen {
    if (s.len == 0) return null;
    const c = s[0];
    if (c != '`' and c != '~') return null;
    var i: usize = 0;
    while (i < s.len and s[i] == c) i += 1;
    if (i < 3) return null;
    const rest = s[i..];
    if (c == '`' and std.mem.indexOfScalar(u8, rest, '`') != null) return null;
    return .{ .char = c, .len = i, .info = std.mem.trim(u8, rest, " \t") };
}

fn isFenceClose(s: []const u8, fence_char: u8, fence_len: usize) bool {
    var i: usize = 0;
    while (i < s.len and s[i] == fence_char) i += 1;
    if (i < fence_len) return false;
    for (s[i..]) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

const ListMarker = struct {
    ordered: bool,
    bullet_char: u8 = 0,
    delim: AST.OrderedListStyle.Delim = .period,
    start: ?u32 = null,
    marker_len: usize,
};

fn tryListMarker(s: []const u8) ?ListMarker {
    if (s.len == 0) return null;
    const c = s[0];
    if (c == '-' or c == '+' or c == '*') {
        if (s.len > 1 and s[1] != ' ' and s[1] != '\t') return null;
        return .{ .ordered = false, .bullet_char = c, .marker_len = 1 };
    }
    if (c >= '0' and c <= '9') {
        var i: usize = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i > 9) return null;
        if (i >= s.len) return null;
        const delim_ch = s[i];
        if (delim_ch != '.' and delim_ch != ')') return null;
        const marker_len = i + 1;
        if (marker_len < s.len and s[marker_len] != ' ' and s[marker_len] != '\t') return null;
        const num = std.fmt.parseInt(u32, s[0..i], 10) catch return null;
        return .{ .ordered = true, .delim = if (delim_ch == '.') .period else .paren_after, .start = num, .marker_len = marker_len };
    }
    return null;
}

const TaskMarker = struct { checked: bool, rest: []const u8 };

/// GFM task list marker: `[ ]`, `[x]`, or `[X]`, immediately followed by a
/// space/tab or end of the item's first line (`after_marker` is the item's
/// content, i.e. everything after the list marker itself and its own
/// separating whitespace). Returns `null` for anything else, leaving the
/// item as an ordinary `list_item`.
fn tryTaskListMarker(after_marker: []const u8) ?TaskMarker {
    if (after_marker.len < 3) return null;
    if (after_marker[0] != '[') return null;
    const c = after_marker[1];
    if (c != ' ' and c != 'x' and c != 'X') return null;
    if (after_marker[2] != ']') return null;
    if (after_marker.len == 3) return .{ .checked = c != ' ', .rest = "" };
    if (after_marker[3] != ' ' and after_marker[3] != '\t') return null;
    return .{ .checked = c != ' ', .rest = after_marker[4..] };
}

/// True when `s` looks like the start of some OTHER block construct
/// (block quote / thematic break / ATX heading / fence / list marker / HTML
/// block) -- used by both `tryStartTable` and `tryStartDefinitionList` to
/// decide when a subsequent line ends their own multi-line construct rather
/// than continuing it (GFM: "The table is broken at ... the beginning of
/// another block-level structure"). Deliberately reuses the SAME pattern
/// matchers `tryStartBlocks` itself uses, rather than a separate/looser
/// heuristic, so "does this line start a new block" means the same thing in
/// both places.
fn looksLikeNewBlockStart(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '>') return true;
    if (isThematicBreak(s)) return true;
    if (tryAtxHeading(s) != null) return true;
    if (tryFenceOpen(s) != null) return true;
    if (tryListMarker(s) != null) return true;
    if (s.len > 0 and s[0] == '<' and detectHtmlBlockStart(s) != null) return true;
    return false;
}

/// A `:`-marked definition-list line: `:` followed by a space/tab (or
/// nothing else on the line) -- see `tryStartDefinitionList`.
fn isDefinitionMarkerLine(s: []const u8) bool {
    if (s.len == 0 or s[0] != ':') return false;
    return s.len == 1 or s[1] == ' ' or s[1] == '\t';
}

// ── GFM table row / delimiter-row parsing ────────────────────────────────

/// True if `s` contains a `|` not immediately preceded by an odd number of
/// backslashes (i.e. not itself backslash-escaped) -- the cheap pre-check
/// `tryStartTable` uses before committing to full row-splitting.
fn containsUnescapedPipe(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            continue;
        }
        if (s[i] == '|') return true;
    }
    return false;
}

/// Strip one leading `|` (if present) and one trailing, UNESCAPED `|` (if
/// present) -- the "outer" pipes of `| a | b |`-style rows, which don't
/// themselves delimit a cell.
fn stripEdgePipes(s: []const u8) []const u8 {
    var t = s;
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|') {
        var backslashes: usize = 0;
        var k = t.len - 1;
        while (k > 0 and t[k - 1] == '\\') : (k -= 1) backslashes += 1;
        if (backslashes % 2 == 0) t = t[0 .. t.len - 1];
    }
    return t;
}

/// Split a table row into its cell texts, on unescaped `|` (a `\|` stays a
/// literal pipe WITHIN a cell -- decoded later, like any other backslash
/// escape, when the cell's inline content is parsed), after stripping outer
/// edge pipes and trimming each cell's surrounding whitespace. Always
/// returns at least one cell (an all-blank/edge-pipes-only row yields one
/// empty cell). Caller frees the returned slice (not its (borrowed) string
/// contents).
fn splitTableRow(allocator: Allocator, s: []const u8) Allocator.Error![][]const u8 {
    const trimmed_outer = std.mem.trim(u8, s, " \t");
    const inner = stripEdgePipes(trimmed_outer);
    var cells = std.ArrayList([]const u8).empty;
    errdefer cells.deinit(allocator);
    var start: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            i += 1;
            continue;
        }
        if (inner[i] == '|') {
            try cells.append(allocator, std.mem.trim(u8, inner[start..i], " \t"));
            start = i + 1;
        }
    }
    try cells.append(allocator, std.mem.trim(u8, inner[start..], " \t"));
    return cells.toOwnedSlice(allocator);
}

/// Parse a table DELIMITER row (`---|:--:|--:`) into one `Alignment` per
/// cell, or `null` if any cell isn't of the form `:?-+:?` (at least one
/// hyphen, optionally flanked by a `:` on either/both sides) -- i.e. `s`
/// doesn't validly delimit a table at all. Caller frees the returned slice.
fn parseDelimiterRow(allocator: Allocator, s: []const u8) Allocator.Error!?[]AST.Alignment {
    const cells = try splitTableRow(allocator, s);
    defer allocator.free(cells);
    if (cells.len == 0) return null;
    for (cells) |cell| {
        var c = cell;
        if (c.len == 0) return null;
        if (c[0] == ':') c = c[1..];
        if (c.len > 0 and c[c.len - 1] == ':') c = c[0 .. c.len - 1];
        if (c.len == 0) return null;
        for (c) |ch| {
            if (ch != '-') return null;
        }
    }
    const aligns = try allocator.alloc(AST.Alignment, cells.len);
    for (cells, 0..) |cell, i| {
        var c = cell;
        var left = false;
        var right = false;
        if (c[0] == ':') {
            left = true;
            c = c[1..];
        }
        if (c.len > 0 and c[c.len - 1] == ':') {
            right = true;
            c = c[0 .. c.len - 1];
        }
        aligns[i] = if (left and right) .center else if (left) .left else if (right) .right else .default;
    }
    return aligns;
}

// ── HTML block start detection ──────────────────────────────────────────

const html_type1_tags = [_][]const u8{ "script", "pre", "style", "textarea" };

const html_type6_tags = std.StaticStringMap(void).initComptime(.{
    .{"address"},    .{"article"},  .{"aside"},   .{"base"},     .{"basefont"},
    .{"blockquote"}, .{"body"},     .{"caption"}, .{"center"},   .{"col"},
    .{"colgroup"},   .{"dd"},       .{"details"}, .{"dialog"},   .{"dir"},
    .{"div"},        .{"dl"},       .{"dt"},      .{"fieldset"}, .{"figcaption"},
    .{"figure"},     .{"footer"},   .{"form"},    .{"frame"},    .{"frameset"},
    .{"h1"},         .{"h2"},       .{"h3"},      .{"h4"},       .{"h5"},
    .{"h6"},         .{"head"},     .{"header"},  .{"hr"},       .{"html"},
    .{"iframe"},     .{"legend"},   .{"li"},      .{"link"},     .{"main"},
    .{"menu"},       .{"menuitem"}, .{"nav"},     .{"noframes"}, .{"ol"},
    .{"optgroup"},   .{"option"},   .{"p"},       .{"param"},    .{"section"},
    .{"summary"},    .{"table"},    .{"tbody"},   .{"td"},       .{"tfoot"},
    .{"th"},         .{"thead"},    .{"title"},   .{"tr"},       .{"track"},
    .{"ul"},
});

fn lowerInto(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..s.len];
}

/// If `s[1..]` starts with `name` (case-insensitive), returns the index
/// just past it.
fn matchTagNameCI(s: []const u8, name: []const u8) ?usize {
    if (s.len < name.len) return null;
    for (name, 0..) |c, i| {
        if (std.ascii.toLower(s[i]) != c) return null;
    }
    return name.len;
}

fn isUnquotedValueStop(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '"' or c == '\'' or c == '=' or c == '<' or c == '>' or c == '`';
}

/// A minimal HTML tag grammar for HTML block type 7 (see this file's module
/// doc comment). `s[0] == '<'`; `closing` reports whether `s[1] == '/'`.
/// Returns the index just past the tag's closing `>` on success.
fn parseCompleteTag(s: []const u8, closing: bool, name_end: usize) ?usize {
    var i = name_end;
    if (closing) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i < s.len and s[i] == '>') return i + 1;
        return null;
    }
    while (true) {
        const before = i;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n')) i += 1;
        if (i < s.len and s[i] == '/') {
            if (i + 1 < s.len and s[i + 1] == '>') return i + 2;
            return null;
        }
        if (i < s.len and s[i] == '>') return i + 1;
        // Every attribute -- including the FIRST -- must be preceded by
        // whitespace per CommonMark's tag grammar ("Zero or more
        // attributes, each preceded by one or more spaces or tabs"); `<m:abc>`
        // has no whitespace between the tag name `m` and `:abc`, so it must
        // NOT parse as an attribute there (this used to only guard
        // subsequent attributes, via `and i > name_end`, wrongly letting a
        // whitespace-less first "attribute" through).
        if (i == before) return null;
        if (i >= s.len or !(isAsciiLetter(s[i]) or s[i] == '_' or s[i] == ':')) return null;
        while (i < s.len and (isAsciiLetterOrDigit(s[i]) or s[i] == '_' or s[i] == ':' or s[i] == '.' or s[i] == '-')) i += 1;
        var j = i;
        while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\n')) j += 1;
        if (j < s.len and s[j] == '=') {
            j += 1;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\n')) j += 1;
            if (j >= s.len) return null;
            if (s[j] == '"') {
                const close = std.mem.indexOfScalarPos(u8, s, j + 1, '"') orelse return null;
                j = close + 1;
            } else if (s[j] == '\'') {
                const close = std.mem.indexOfScalarPos(u8, s, j + 1, '\'') orelse return null;
                j = close + 1;
            } else {
                const vstart = j;
                while (j < s.len and !isUnquotedValueStop(s[j])) j += 1;
                if (j == vstart) return null;
            }
            i = j;
        } else {
            i = j;
        }
    }
}

/// `s` is already indent-stripped (<=3 columns) and starts with `<`.
/// Returns the HTML block type (1-7) it begins, or `null`.
fn detectHtmlBlockStart(s: []const u8) ?u8 {
    if (s.len == 0 or s[0] != '<') return null;
    if (std.mem.startsWith(u8, s, "<!--")) return 2;
    if (std.mem.startsWith(u8, s, "<?")) return 3;
    if (std.mem.startsWith(u8, s, "<![CDATA[")) return 5;
    if (s.len >= 3 and s[1] == '!' and isAsciiLetter(s[2])) return 4;

    inline for (html_type1_tags) |name| {
        if (matchTagNameCI(s[1..], name)) |n| {
            const after = 1 + n;
            if (after == s.len or s[after] == ' ' or s[after] == '\t' or s[after] == '\n' or s[after] == '>') return 1;
        }
    }

    var i: usize = 1;
    var closing = false;
    if (i < s.len and s[i] == '/') {
        closing = true;
        i += 1;
    }
    const name_start = i;
    if (i >= s.len or !isAsciiLetter(s[i])) return null;
    while (i < s.len and (isAsciiLetterOrDigit(s[i]) or s[i] == '-')) i += 1;
    const name = s[name_start..i];

    var lower_buf: [32]u8 = undefined;
    if (lowerInto(&lower_buf, name)) |lname| {
        if (html_type6_tags.has(lname)) {
            if (i == s.len) return 6;
            const c = s[i];
            if (c == ' ' or c == '\t' or c == '>') return 6;
            if (c == '/' and i + 1 < s.len and s[i + 1] == '>') return 6;
            return null;
        }
    }

    if (parseCompleteTag(s, closing, i)) |end| {
        if (isBlankLine(s[end..])) return 7;
    }
    return null;
}

// ── label normalization (link reference definitions) ───────────────────

/// Trim + collapse internal whitespace runs to a single space + ASCII
/// lowercase (see this file's module doc comment: not full Unicode case
/// folding).
fn normalizeLabel(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
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

// ── container / leaf staging types ──────────────────────────────────────

const ContainerKind = enum { document, block_quote, list, list_item };

const Container = struct {
    kind: ContainerKind,
    children: std.ArrayList(Node.Id) = .empty,
    start_line: usize = 0,
    end_line: usize = 0,

    // .list_item
    content_col: usize = 0,
    /// GFM task list items (`self.options.task_lists`): this item's content
    /// began with a `[ ]`/`[x]` checkbox marker (already stripped from the
    /// content before parsing began -- see the list-marker handling in
    /// `tryStartBlocks`). `popContainer` emits `task_list_item` instead of
    /// `list_item` when set.
    is_task: bool = false,
    task_checked: bool = false,

    // .list
    ordered: bool = false,
    bullet_char: u8 = 0,
    delim: AST.OrderedListStyle.Delim = .period,
    start_num: ?u32 = null,
    tight: bool = true,
    blank_pending: bool = false,
    /// Set when ANY child item pushed this list turned out to be a task
    /// item (see `is_task` above); `popContainer` emits `task_list` instead
    /// of `bullet_list` when set (task lists are unordered-only, per the
    /// mission -- an ordered list marker is never eligible for task-item
    /// detection in the first place, so this only ever fires for a bullet
    /// list).
    any_task: bool = false,

    fn deinit(self: *Container, allocator: Allocator) void {
        self.children.deinit(allocator);
    }
};

const LeafKind = enum { paragraph, indented_code, fenced_code, html_block };

const Leaf = struct {
    kind: LeafKind,
    text: std.ArrayList(u8) = .empty,
    start_line: usize = 0,
    end_line: usize = 0,

    // .fenced_code / .indented_code: number of content lines appended so
    // far, INCLUDING blank ones -- `text.items.len > 0` can't distinguish
    // "no lines yet" from "one blank line so far" (both are empty), which
    // matters because a fenced/indented code block's very first content
    // line can itself be blank (see e.g. spec example 129, a fence whose
    // first line inside is blank) and the join logic (`continueFencedCode`)
    // needs to know whether to prepend a `\n` separator before this line.
    line_count: usize = 0,

    // .fenced_code
    fence_char: u8 = 0,
    fence_len: usize = 0,
    fence_col: usize = 0,
    lang: ?[]u8 = null,

    // .html_block
    html_type: u8 = 0,

    // .indented_code: trailing blank lines tentatively buffered, trimmed if
    // the block turns out to end there.
    trailing_blanks: usize = 0,

    fn deinit(self: *Leaf, allocator: Allocator) void {
        self.text.deinit(allocator);
        if (self.lang) |l| allocator.free(l);
    }
};

/// A leaf text block (paragraph/heading) whose inline content parsing has
/// been deferred until the whole document's block structure -- and
/// therefore every link reference definition -- is known. See
/// `emitTextBlock`/`resolvePendingInline`: link reference definitions can
/// appear AFTER their first use (`[foo][bar]` followed, later in the
/// document, by `[bar]: /url`), so `parseInline` can't safely run until
/// `self.link_references` is complete, which isn't true until `parse`'s
/// line-by-line scan has finished entirely.
const PendingInline = struct {
    id: Node.Id,
    /// Owned copy of the block's assembled text: the source this was sliced
    /// from (typically a `Leaf.text` buffer) is freed as soon as its block
    /// closes, long before `resolvePendingInline` runs.
    text: []u8,
};

pub const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    lines: []const []const u8,
    line_starts: []const usize,
    builder: Builder,
    stack: std.ArrayList(Container),
    leaf: ?Leaf = null,
    link_references: std.StringHashMapUnmanaged(Node.Id) = .empty,
    pending_inline: std.ArrayList(PendingInline) = .empty,
    options: Options,
    /// Phase 3's multi-line block extensions (GFM tables, definition lists,
    /// frontmatter) recognize and consume SEVERAL lines at once, ahead of
    /// the normal one-line-at-a-time driver in `parse`'s `for` loop -- rather
    /// than restructure that loop to let a single `processLine` call report
    /// back "advance by N lines", each of those extensions just directly
    /// reads `self.lines[idx+1..]` for as far as its own grammar allows, then
    /// sets this to the index of the first line it DIDN'T consume.
    /// `processLine` checks this first and no-ops for any `idx` still below
    /// it, so the driving loop doesn't need to change at all.
    skip_until_line: usize = 0,

    pub fn init(allocator: Allocator, source: []const u8, options: Options) Allocator.Error!Parser {
        var lines = std.ArrayList([]const u8).empty;
        errdefer lines.deinit(allocator);
        var starts = std.ArrayList(usize).empty;
        errdefer starts.deinit(allocator);

        var start: usize = 0;
        var i: usize = 0;
        while (i < source.len) {
            if (source[i] == '\n') {
                var end = i;
                if (end > start and source[end - 1] == '\r') end -= 1;
                try lines.append(allocator, source[start..end]);
                try starts.append(allocator, start);
                i += 1;
                start = i;
            } else i += 1;
        }
        if (start < source.len) {
            var end = source.len;
            if (end > start and source[end - 1] == '\r') end -= 1;
            try lines.append(allocator, source[start..end]);
            try starts.append(allocator, start);
        }

        var stack = std.ArrayList(Container).empty;
        errdefer stack.deinit(allocator);
        try stack.append(allocator, .{ .kind = .document });

        return .{
            .allocator = allocator,
            .source = source,
            .lines = try lines.toOwnedSlice(allocator),
            .line_starts = try starts.toOwnedSlice(allocator),
            .builder = Builder.init(allocator),
            .stack = stack,
            .options = options,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.lines);
        self.allocator.free(self.line_starts);
        for (self.stack.items) |*c| c.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        if (self.leaf) |*lf| lf.deinit(self.allocator);
        // Normally empty by the time `deinit` runs -- `parse` drains this
        // via `resolvePendingInline` before returning -- but freed
        // defensively here too in case `deinit` is ever reached without a
        // completed `parse` (e.g. a future early-return error path).
        for (self.pending_inline.items) |p| self.allocator.free(p.text);
        self.pending_inline.deinit(self.allocator);
        self.builder.deinit();
        // Keys are slices into the builder's `owned_strings` (see
        // `tryParseLinkRefDef`), not separately allocated, so — mirroring
        // djot's `Document.references` — only the map structure itself is
        // freed here; `self.builder.deinit()` above (on a failure path) or
        // the finished `AST`'s `deinit` (on success, via `Document.deinit`)
        // owns the actual bytes.
        self.link_references.deinit(self.allocator);
    }

    pub fn parse(self: *Parser) Allocator.Error!BlockResult {
        if (self.options.frontmatter) try self.tryConsumeFrontmatter();
        for (self.lines, 0..) |line, idx| {
            try self.processLine(line, idx);
        }
        // Every link reference definition has now been seen and registered
        // in `self.link_references` (they're only ever stripped off the
        // front of a closing paragraph, which the loop above and this
        // final `closeLeaf` cover) -- safe to resolve every deferred leaf
        // text block's inline content now, forward references included.
        try self.closeLeaf(if (self.lines.len == 0) 0 else self.lines.len - 1);
        while (self.stack.items.len > 1) try self.popContainer(if (self.lines.len == 0) 0 else self.lines.len - 1);
        try self.resolvePendingInline();

        var root = self.stack.pop().?;
        defer root.deinit(self.allocator);
        const doc_id = try self.builder.addContainer(.doc, root.children.items);
        self.builder.setSpan(doc_id, Span.init(0, self.source.len));
        setContentSpanFromChildren(&self.builder, doc_id);

        const ast = try self.builder.finish(doc_id);
        const refs = self.link_references;
        self.link_references = .empty;
        return .{ .ast = ast, .link_references = refs };
    }

    /// Parse every deferred leaf text block's inline content (see
    /// `PendingInline`'s doc comment) now that `self.link_references` is
    /// complete, attaching the result as that node's children.
    fn resolvePendingInline(self: *Parser) Allocator.Error!void {
        defer {
            self.pending_inline.deinit(self.allocator);
            self.pending_inline = .empty;
        }
        for (self.pending_inline.items) |p| {
            defer self.allocator.free(p.text);
            const kids = try inline_mod.parseInline(&self.builder, p.text, &self.link_references, self.options);
            defer self.allocator.free(kids);
            self.builder.setChildren(p.id, kids);
            setContentSpanFromChildren(&self.builder, p.id);
        }
    }

    // ── span helpers ─────────────────────────────────────────────────────

    fn lineStart(self: *Parser, idx: usize) usize {
        return self.line_starts[idx];
    }
    fn lineEnd(self: *Parser, idx: usize) usize {
        return self.line_starts[idx] + self.lines[idx].len;
    }

    fn setContentSpanFromChildren(b: *Builder, id: Node.Id) void {
        const first = b.nodes.items[id].first_child orelse return;
        var last = first;
        while (b.nodes.items[last].next_sibling) |next| last = next;
        b.setContentSpan(id, Span.init(b.nodes.items[first].span.start, b.nodes.items[last].span.end));
    }

    fn top(self: *Parser) *Container {
        return &self.stack.items[self.stack.items.len - 1];
    }

    fn appendToTop(self: *Parser, id: Node.Id) Allocator.Error!void {
        try self.top().children.append(self.allocator, id);
    }

    /// Called whenever genuinely new block-level content is added while
    /// some list(s) are open: converts any of those lists' pending blank
    /// line into a permanent tight=false, per CommonMark's tight/loose
    /// definition (see this file's module doc comment).
    fn markListsLoose(self: *Parser) void {
        for (self.stack.items) |*c| {
            if (c.kind == .list and c.blank_pending) c.tight = false;
        }
    }

    // ── container open/close ────────────────────────────────────────────

    fn pushContainer(self: *Parser, kind: ContainerKind, line_idx: usize) Allocator.Error!void {
        try self.stack.append(self.allocator, .{ .kind = kind, .start_line = line_idx, .end_line = line_idx });
    }

    fn popContainer(self: *Parser, line_idx: usize) Allocator.Error!void {
        var c = self.stack.pop().?;
        defer c.deinit(self.allocator);
        const kind: Node.Kind = switch (c.kind) {
            .document => unreachable,
            .block_quote => .block_quote,
            .list_item => if (c.is_task) .{ .task_list_item = .{ .checked = c.task_checked } } else .list_item,
            .list => if (c.ordered)
                .{ .ordered_list = .{ .style = .{ .numbering = .decimal, .delim = c.delim }, .tight = c.tight, .start = c.start_num } }
            else if (c.any_task)
                .{ .task_list = .{ .tight = c.tight } }
            else
                .{ .bullet_list = .{ .style = bulletStyle(c.bullet_char), .tight = c.tight } },
        };
        const id = try self.builder.addContainer(kind, c.children.items);
        self.builder.setSpan(id, Span.init(self.lineStart(c.start_line), self.lineEnd(@min(c.end_line, line_idx))));
        setContentSpanFromChildren(&self.builder, id);
        try self.appendToTop(id);
    }

    fn bulletStyle(c: u8) AST.BulletListStyle {
        return switch (c) {
            '+' => .plus,
            '*' => .star,
            else => .dash,
        };
    }

    /// Close containers from the top of the stack down to (not including)
    /// `matched_index`, finalizing the currently open leaf first (it
    /// belongs to whatever was on top before any popping).
    fn closeToDepth(self: *Parser, matched_index: usize, line_idx: usize) Allocator.Error!void {
        try self.closeLeaf(line_idx);
        while (self.stack.items.len > matched_index) try self.popContainer(line_idx);
    }

    // ── leaf open/close ──────────────────────────────────────────────────

    fn closeLeaf(self: *Parser, line_idx: usize) Allocator.Error!void {
        var lf = self.leaf orelse return;
        self.leaf = null;
        switch (lf.kind) {
            .paragraph => try self.finishParagraph(&lf),
            .indented_code => try self.finishIndentedCode(&lf),
            .fenced_code => try self.finishFencedCode(&lf),
            .html_block => try self.finishHtmlBlock(&lf),
        }
        _ = line_idx;
        lf.deinit(self.allocator);
    }

    fn finishParagraph(self: *Parser, lf: *Leaf) Allocator.Error!void {
        while (lf.text.items.len > 0 and (lf.text.items[lf.text.items.len - 1] == ' ' or lf.text.items[lf.text.items.len - 1] == '\t')) {
            lf.text.items.len -= 1;
        }
        const remaining = try self.stripLinkReferenceDefinitions(lf.text.items);
        const trimmed = std.mem.trim(u8, remaining, " \t\r\n");
        if (trimmed.len == 0) return;
        try self.emitTextBlock(.para, trimmed, lf.start_line, lf.end_line);
    }

    /// Adds a leaf text block (paragraph/heading) node with `text` as its
    /// eventual inline content -- eventual, because parsing that content is
    /// deferred (see `PendingInline`) until the whole document's link
    /// reference definitions are known. `text` is duped here since its
    /// backing storage (typically a soon-to-be-`deinit`'d `Leaf.text`
    /// buffer) will not outlive this call.
    fn emitTextBlock(self: *Parser, kind: Node.Kind, text: []const u8, start_line: usize, end_line: usize) Allocator.Error!void {
        const id = try self.addDeferredTextNode(kind, text, start_line, end_line);
        try self.appendToTop(id);
    }

    /// Like `emitTextBlock`, but returns the new node's id WITHOUT attaching
    /// it to `self.top()` -- for Phase 3 constructs (GFM table cells,
    /// definition-list terms/definitions) that assemble a node's own
    /// children (table rows, a `definition_list_item`'s term + definitions)
    /// themselves via `self.builder.addContainer` before the whole thing
    /// gets appended to the currently open container in one shot, rather
    /// than each leaf attaching itself as it's created.
    fn addDeferredTextNode(self: *Parser, kind: Node.Kind, text: []const u8, start_line: usize, end_line: usize) Allocator.Error!Node.Id {
        const id = try self.builder.addNode(kind);
        self.builder.setSpan(id, Span.init(self.lineStart(start_line), self.lineEnd(end_line)));
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        try self.pending_inline.append(self.allocator, .{ .id = id, .text = owned_text });
        return id;
    }

    fn finishIndentedCode(self: *Parser, lf: *Leaf) Allocator.Error!void {
        // Trim the tentatively-buffered trailing blank lines: an indented
        // code block's content never includes blank lines that turned out
        // to be trailing (see `continueIndentedCode`).
        var text = lf.text.items;
        var n = lf.trailing_blanks;
        while (n > 0) : (n -= 1) {
            if (std.mem.lastIndexOfScalar(u8, text, '\n')) |nl| {
                text = text[0..nl];
            } else {
                text = "";
            }
        }
        const owned = try self.allocator.dupe(u8, text);
        defer self.allocator.free(owned);
        var full = std.ArrayList(u8).empty;
        defer full.deinit(self.allocator);
        try full.appendSlice(self.allocator, owned);
        if (full.items.len > 0 and full.items[full.items.len - 1] != '\n') try full.append(self.allocator, '\n');
        const id = try self.builder.addLeaf(.{ .code_block = .{ .lang = null, .text = full.items } });
        self.builder.setSpan(id, Span.init(self.lineStart(lf.start_line), self.lineEnd(lf.end_line)));
        try self.appendToTop(id);
    }

    fn finishFencedCode(self: *Parser, lf: *Leaf) Allocator.Error!void {
        var full = std.ArrayList(u8).empty;
        defer full.deinit(self.allocator);
        try full.appendSlice(self.allocator, lf.text.items);
        if (full.items.len > 0) try full.append(self.allocator, '\n');
        const id = try self.builder.addLeaf(.{ .code_block = .{ .lang = lf.lang, .text = full.items } });
        self.builder.setSpan(id, Span.init(self.lineStart(lf.start_line), self.lineEnd(lf.end_line)));
        try self.appendToTop(id);
    }

    fn finishHtmlBlock(self: *Parser, lf: *Leaf) Allocator.Error!void {
        var full = std.ArrayList(u8).empty;
        defer full.deinit(self.allocator);
        try full.appendSlice(self.allocator, lf.text.items);
        if (full.items.len > 0) try full.append(self.allocator, '\n');
        const id = try self.builder.addLeaf(.{ .raw_block = .{ .format = "html", .text = full.items } });
        self.builder.setSpan(id, Span.init(self.lineStart(lf.start_line), self.lineEnd(lf.end_line)));
        try self.appendToTop(id);
    }

    // ── the per-line driver ──────────────────────────────────────────────

    fn matchContainers(self: *Parser, line: []const u8) struct { matched_index: usize, cur: Cursor } {
        var cur: Cursor = .{};
        var i: usize = 1;
        while (i < self.stack.items.len) : (i += 1) {
            const c = &self.stack.items[i];
            switch (c.kind) {
                .document => unreachable,
                .list => {},
                .block_quote => {
                    const nc = matchBlockQuote(line, cur) orelse break;
                    cur = nc;
                },
                .list_item => {
                    const nc = matchListItem(line, cur, c.content_col) orelse break;
                    cur = nc;
                },
            }
        }
        return .{ .matched_index = i, .cur = cur };
    }

    fn matchBlockQuote(line: []const u8, cur: Cursor) ?Cursor {
        const after_indent = skipWsUpToCols(line, cur, 3);
        if (after_indent.pos >= line.len or line[after_indent.pos] != '>') return null;
        var c2: Cursor = .{ .pos = after_indent.pos + 1, .col = after_indent.col + 1 };
        if (c2.pos < line.len and (line[c2.pos] == ' ' or line[c2.pos] == '\t')) {
            c2 = .{ .pos = c2.pos + 1, .col = c2.col + 1 };
        }
        return c2;
    }

    fn matchListItem(line: []const u8, cur: Cursor, content_col: usize) ?Cursor {
        if (isBlankLine(line[cur.pos..])) return cur;
        const target = skipWsToTarget(line, cur, content_col);
        if (target.col < content_col) return null;
        return target;
    }

    fn processLine(self: *Parser, line: []const u8, idx: usize) Allocator.Error!void {
        // Already consumed by a Phase 3 multi-line construct (a GFM table,
        // definition list, or frontmatter block) started at an earlier
        // `idx` -- see `skip_until_line`'s doc comment.
        if (idx < self.skip_until_line) return;
        const m = self.matchContainers(line);
        const cur = m.cur;

        if (m.matched_index < self.stack.items.len) {
            const remainder0 = line[cur.pos..];
            if (!isBlankLine(remainder0) and self.leaf != null and self.leaf.?.kind == .paragraph and
                !self.canInterruptParagraph(remainder0))
            {
                try self.appendParagraphLine(remainder0, idx);
                return;
            }
            try self.closeToDepth(m.matched_index, idx);
        }

        const remainder = line[cur.pos..];
        if (isBlankLine(remainder)) {
            try self.handleBlankLine(line, cur, idx);
            return;
        }

        if (self.leaf) |*lf| {
            switch (lf.kind) {
                .fenced_code => {
                    try self.continueFencedCode(lf, line, cur, idx);
                    return;
                },
                .html_block => {
                    try self.continueHtmlBlock(lf, remainder, idx);
                    return;
                },
                .indented_code => {
                    const indent = indentCols(remainder, .{});
                    if (indent >= 4) {
                        try self.continueIndentedCode(lf, remainder, idx);
                        return;
                    }
                    try self.closeLeaf(idx);
                },
                .paragraph => {
                    if (self.options.definition_lists and lf.start_line == lf.end_line) {
                        if (try self.tryStartDefinitionList(lf, line, cur, idx)) return;
                    }
                    if (trySetextUnderline(stripUpTo3Indent(remainder))) |level| {
                        try self.closeParagraphAsHeading(level, idx);
                        return;
                    }
                },
            }
        }

        if (try self.tryStartBlocks(line, cur, idx, self.leaf != null and self.leaf.?.kind == .paragraph)) return;

        if (self.leaf != null and self.leaf.?.kind == .paragraph) {
            try self.appendParagraphLine(remainder, idx);
        } else {
            try self.openParagraph(remainder, idx);
        }
    }

    /// A blank line is never *itself* fence/tag syntax, but it's still an
    /// ordinary CONTENT line for fenced code / non-6-7 HTML blocks (its
    /// whitespace, if any beyond the fence's own indentation, is preserved
    /// verbatim -- see spec example 129, a `"  "`-only line inside a fenced
    /// block) and a TENTATIVE content line for indented code (trimmed back
    /// off at close time if it turns out to be trailing -- `finishIndentedCode`).
    /// Every leaf branch below follows the same "prepend a `\n` separator
    /// only if there's already content, then append this line's own
    /// (possibly empty) text" join convention `continueFencedCode`/
    /// `continueIndentedCode` use for non-blank lines, so a blank line
    /// contributes exactly one line to the joined text either way.
    fn handleBlankLine(self: *Parser, line: []const u8, cur: Cursor, idx: usize) Allocator.Error!void {
        const remainder = line[cur.pos..];
        if (self.leaf) |*lf| {
            switch (lf.kind) {
                .paragraph => try self.closeLeaf(idx),
                .indented_code => {
                    if (lf.line_count > 0) try lf.text.append(self.allocator, '\n');
                    const stripped = skipWsUpToCols(remainder, .{}, 4);
                    try lf.text.appendSlice(self.allocator, remainder[stripped.pos..]);
                    lf.line_count += 1;
                    lf.trailing_blanks += 1;
                    lf.end_line = idx;
                },
                .fenced_code => try self.continueFencedCode(lf, line, cur, idx),
                .html_block => {
                    if (lf.html_type == 6 or lf.html_type == 7) {
                        try self.closeLeaf(idx);
                    } else {
                        if (lf.text.items.len > 0) try lf.text.append(self.allocator, '\n');
                        try lf.text.appendSlice(self.allocator, remainder);
                        lf.end_line = idx;
                    }
                },
            }
        }
        for (self.stack.items) |*c| {
            if (c.kind == .list) c.blank_pending = true;
        }
    }

    // ── paragraph accumulation ──────────────────────────────────────────

    fn openParagraph(self: *Parser, remainder: []const u8, idx: usize) Allocator.Error!void {
        // A `list`'s only valid children are `list_item`s (see the AST's
        // `bullet_list`/`ordered_list` doc comments) -- a fresh paragraph
        // can never be one directly. If a list_item just failed to match
        // (closed via `closeToDepth`) and nothing continued its parent
        // `.list` either, that dangling list must close FIRST -- before
        // `markListsLoose`, so the blank line that led here doesn't
        // retroactively mark this now-irrelevant list loose.
        try self.maybeCloseTopList(idx, null);
        self.markListsLoose();
        var lf: Leaf = .{ .kind = .paragraph, .start_line = idx, .end_line = idx };
        try lf.text.appendSlice(self.allocator, trimLeadingWs(remainder));
        self.leaf = lf;
    }

    fn appendParagraphLine(self: *Parser, remainder: []const u8, idx: usize) Allocator.Error!void {
        var lf = &self.leaf.?;
        try lf.text.append(self.allocator, '\n');
        try lf.text.appendSlice(self.allocator, trimLeadingWs(remainder));
        lf.end_line = idx;
    }

    fn closeParagraphAsHeading(self: *Parser, level: u32, idx: usize) Allocator.Error!void {
        var lf = self.leaf.?;
        self.leaf = null;
        defer lf.deinit(self.allocator);
        const trimmed = std.mem.trim(u8, lf.text.items, " \t\r\n");
        if (trimmed.len > 0) {
            try self.emitTextBlock(.{ .heading = .{ .level = level } }, trimmed, lf.start_line, idx);
        }
    }

    // ── indented code ────────────────────────────────────────────────────

    fn continueIndentedCode(self: *Parser, lf: *Leaf, remainder: []const u8, idx: usize) Allocator.Error!void {
        if (lf.line_count > 0) try lf.text.append(self.allocator, '\n');
        const stripped = skipWsUpToCols(remainder, .{}, 4);
        try lf.text.appendSlice(self.allocator, remainder[stripped.pos..]);
        lf.line_count += 1;
        lf.trailing_blanks = 0;
        lf.end_line = idx;
    }

    // ── fenced code ──────────────────────────────────────────────────────

    fn continueFencedCode(self: *Parser, lf: *Leaf, line: []const u8, cur: Cursor, idx: usize) Allocator.Error!void {
        const remainder = line[cur.pos..];
        if (indentCols(remainder, .{}) < 4 and isFenceClose(stripUpTo3Indent(remainder), lf.fence_char, lf.fence_len)) {
            try self.closeLeaf(idx);
            return;
        }
        if (lf.line_count > 0) try lf.text.append(self.allocator, '\n');
        const strip_cols = if (lf.fence_col > cur.col) lf.fence_col - cur.col else 0;
        const stripped = skipWsUpToCols(line, cur, strip_cols);
        try lf.text.appendSlice(self.allocator, line[stripped.pos..]);
        lf.line_count += 1;
        lf.end_line = idx;
    }

    // ── html block ───────────────────────────────────────────────────────

    fn continueHtmlBlock(self: *Parser, lf: *Leaf, remainder: []const u8, idx: usize) Allocator.Error!void {
        if (lf.text.items.len > 0) try lf.text.append(self.allocator, '\n');
        try lf.text.appendSlice(self.allocator, remainder);
        lf.end_line = idx;
        const ends = switch (lf.html_type) {
            1 => containsAnyCI(remainder, &.{ "</script>", "</pre>", "</style>", "</textarea>" }),
            2 => std.mem.indexOf(u8, remainder, "-->") != null,
            3 => std.mem.indexOf(u8, remainder, "?>") != null,
            4 => std.mem.indexOfScalar(u8, remainder, '>') != null,
            5 => std.mem.indexOf(u8, remainder, "]]>") != null,
            else => false, // 6/7 only end at a blank line, handled in handleBlankLine
        };
        if (ends) try self.closeLeaf(idx);
    }

    fn containsAnyCI(haystack: []const u8, needles: []const []const u8) bool {
        var buf: [4096]u8 = undefined;
        const n = @min(haystack.len, buf.len);
        for (haystack[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const lower = buf[0..n];
        for (needles) |needle| {
            if (std.mem.indexOf(u8, lower, needle) != null) return true;
        }
        return false;
    }

    // ── new block start scanning ────────────────────────────────────────

    /// Pure (non-mutating) check: would `remainder` (a lazily-continued
    /// line, i.e. one that failed to match one or more ancestor containers)
    /// start a block allowed to interrupt an open paragraph? If so, the
    /// caller should NOT treat this as a lazy continuation line.
    fn canInterruptParagraph(self: *Parser, remainder: []const u8) bool {
        const indent = indentCols(remainder, .{});
        if (indent >= 4) return false;
        const s = stripUpTo3Indent(remainder);
        if (s.len > 0 and s[0] == '>') return true;
        if (isThematicBreak(s)) return true;
        if (tryAtxHeading(s) != null) return true;
        if (tryFenceOpen(s) != null) return true;
        if (tryListMarker(s)) |mk| {
            const after = s[mk.marker_len..];
            if (self.isInsideListItem()) return true;
            if (!isBlankLine(after) and (!mk.ordered or mk.start.? == 1)) return true;
        }
        if (s.len > 0 and s[0] == '<') {
            if (detectHtmlBlockStart(s)) |t| {
                if (t != 7) return true;
            }
        }
        return false;
    }

    /// Attempt to recognize and consume one or more new block starts
    /// beginning at `cur` in `line` (container starts loop — a block quote
    /// or list item can directly contain another block start on the same
    /// line — before finally trying a leaf-block start). Returns `true` if
    /// anything was started (in which case the line has been fully
    /// handled), `false` if `remainder` matches no known block start (the
    /// caller falls back to paragraph continuation/creation).
    fn tryStartBlocks(self: *Parser, line: []const u8, cur_in: Cursor, idx: usize, interrupting_paragraph: bool) Allocator.Error!bool {
        var cur = cur_in;
        var interrupting = interrupting_paragraph;
        // Once a container (block quote / list item) has been pushed, this
        // line is "handled" even if nothing deeper matches on the
        // remainder — the remaining text becomes a fresh paragraph INSIDE
        // the newly pushed container(s), using the up-to-date `cur`, not
        // the pre-push position the caller knows about. Returning `false`
        // after already mutating the stack would make the caller retry
        // with stale state (see this function's tests / the module doc
        // comment's "List items"/"Block quotes" sections in
        // `conformance.zig` output for what that bug looked like).
        var pushed_any = false;
        while (true) {
            const remainder = line[cur.pos..];
            const indent = indentCols(remainder, .{});

            if (indent < 4) {
                const s = stripUpTo3Indent(remainder);
                const indent_bytes = remainder.len - s.len;

                if (s.len > 0 and s[0] == '>') {
                    if (interrupting) try self.closeLeaf(idx);
                    self.markListsLoose();
                    try self.pushContainer(.block_quote, idx);
                    cur = matchBlockQuote(line, cur).?;
                    interrupting = false;
                    pushed_any = true;
                    continue;
                }

                // Thematic break takes precedence over a same-character
                // list-marker reading (e.g. "- - -").
                if (isThematicBreak(s)) {
                    if (interrupting) try self.closeLeaf(idx);
                    try self.maybeCloseTopList(idx, null);
                    self.markListsLoose();
                    const id = try self.builder.addLeaf(.thematic_break);
                    self.builder.setSpan(id, Span.init(self.lineStart(idx), self.lineEnd(idx)));
                    try self.appendToTop(id);
                    return true;
                }

                if (tryAtxHeading(s)) |h| {
                    if (interrupting) try self.closeLeaf(idx);
                    try self.maybeCloseTopList(idx, null);
                    self.markListsLoose();
                    try self.emitTextBlock(.{ .heading = .{ .level = h.level } }, std.mem.trim(u8, h.content, " \t"), idx, idx);
                    return true;
                }

                if (tryFenceOpen(s)) |f| {
                    if (interrupting) try self.closeLeaf(idx);
                    try self.maybeCloseTopList(idx, null);
                    self.markListsLoose();
                    var lf: Leaf = .{
                        .kind = .fenced_code,
                        .start_line = idx,
                        .end_line = idx,
                        .fence_char = f.char,
                        .fence_len = f.len,
                        .fence_col = cur.col + indent_bytes,
                    };
                    if (f.info.len > 0) {
                        const decoded = try inline_mod.decodeText(self.allocator, f.info);
                        defer self.allocator.free(decoded);
                        var word_end: usize = 0;
                        while (word_end < decoded.len and decoded[word_end] != ' ' and decoded[word_end] != '\t') word_end += 1;
                        lf.lang = try self.allocator.dupe(u8, decoded[0..word_end]);
                    }
                    self.leaf = lf;
                    return true;
                }

                if (tryListMarker(s)) |mk| {
                    const after = s[mk.marker_len..];
                    const item_blank = isBlankLine(after);
                    const eligible = !interrupting or self.isInsideListItem() or (!item_blank and (!mk.ordered or mk.start.? == 1));
                    if (eligible) {
                        if (interrupting) try self.closeLeaf(idx);
                        const reuse = self.topIsCompatibleList(mk);
                        if (!reuse) {
                            try self.maybeCloseTopList(idx, mk);
                            self.markListsLoose();
                            try self.pushContainer(.list, idx);
                            var lc = self.top();
                            lc.ordered = mk.ordered;
                            lc.bullet_char = mk.bullet_char;
                            lc.delim = mk.delim;
                            lc.start_num = mk.start;
                            lc.tight = true;
                        } else {
                            self.markListsLoose();
                        }
                        const marker_col = cur.col + indent_bytes;
                        const after_marker_col = marker_col + mk.marker_len;
                        var content_col: usize = undefined;
                        if (item_blank) {
                            content_col = after_marker_col + 1;
                        } else {
                            const spaces = indentCols(after, .{ .pos = 0, .col = after_marker_col });
                            content_col = if (spaces >= 1 and spaces <= 4) after_marker_col + spaces else after_marker_col + 1;
                        }
                        try self.pushContainer(.list_item, idx);
                        self.top().content_col = content_col;
                        const after_marker_cursor: Cursor = .{ .pos = cur.pos + indent_bytes + mk.marker_len, .col = after_marker_col };
                        cur = skipWsToTarget(line, after_marker_cursor, content_col);
                        // GFM task list items (`self.options.task_lists`,
                        // shadowing core bullet-list-item parsing per the
                        // mission): only tried for a bullet item (never
                        // ordered) whose content begins with a `[ ]`/`[x]`
                        // checkbox marker -- see `tryTaskListMarker`. The
                        // marker text itself is consumed here (advancing
                        // `cur` past it) so it never reaches inline parsing;
                        // the enclosing `.list` is flagged `any_task` so
                        // `popContainer` promotes it to `task_list`.
                        if (self.options.task_lists and !mk.ordered) {
                            if (tryTaskListMarker(line[cur.pos..])) |tm| {
                                self.top().is_task = true;
                                self.top().task_checked = tm.checked;
                                if (self.stack.items.len >= 2) {
                                    self.stack.items[self.stack.items.len - 2].any_task = true;
                                }
                                const consumed = line[cur.pos..].len - tm.rest.len;
                                cur = .{ .pos = cur.pos + consumed, .col = cur.col + consumed };
                            }
                        }
                        interrupting = false;
                        pushed_any = true;
                        continue;
                    }
                }

                if (self.options.tables and !interrupting) {
                    if (try self.tryStartTable(line, cur, idx)) return true;
                }

                if (s.len > 0 and s[0] == '<') {
                    if (detectHtmlBlockStart(s)) |t| {
                        if (!interrupting or t != 7) {
                            if (interrupting) try self.closeLeaf(idx);
                            try self.maybeCloseTopList(idx, null);
                            self.markListsLoose();
                            var lf: Leaf = .{ .kind = .html_block, .start_line = idx, .end_line = idx, .html_type = t };
                            try lf.text.appendSlice(self.allocator, remainder);
                            self.leaf = lf;
                            const ends = switch (t) {
                                1 => containsAnyCI(remainder, &.{ "</script>", "</pre>", "</style>", "</textarea>" }),
                                2 => std.mem.indexOf(u8, remainder, "-->") != null,
                                3 => std.mem.indexOf(u8, remainder, "?>") != null,
                                4 => std.mem.indexOfScalar(u8, remainder, '>') != null,
                                5 => std.mem.indexOf(u8, remainder, "]]>") != null,
                                else => false,
                            };
                            if (ends) try self.closeLeaf(idx);
                            return true;
                        }
                    }
                }
            } else if (!interrupting) {
                // Indented code (indent >= 4) can never interrupt a
                // paragraph, and is only a *start* (continuing an already-
                // open one is handled before `tryStartBlocks` is called).
                try self.maybeCloseTopList(idx, null);
                var lf: Leaf = .{ .kind = .indented_code, .start_line = idx, .end_line = idx, .line_count = 1 };
                const stripped = skipWsUpToCols(remainder, .{}, 4);
                try lf.text.appendSlice(self.allocator, remainder[stripped.pos..]);
                self.markListsLoose();
                self.leaf = lf;
                return true;
            }

            if (!pushed_any) return false;
            // A container (or more than one) was pushed this line, but its
            // remaining text starts no further block itself: that
            // remainder becomes the first line of a fresh paragraph inside
            // whatever was just pushed (or nothing, if it's blank -- e.g.
            // a bare "> " or list marker with nothing after it).
            const final_remainder = line[cur.pos..];
            if (!isBlankLine(final_remainder)) try self.openParagraph(final_remainder, idx);
            return true;
        }
    }

    /// After popping a mismatched list_item (in `closeToDepth`), the parent
    /// `.list` is still open. A `list`'s only valid children are
    /// `list_item`s, so if the upcoming content at this depth is anything
    /// other than a compatible list marker (a new item of the SAME list),
    /// the list itself must close before that content is processed — see
    /// this file's module doc comment section on tight/loose and the
    /// `topIsCompatibleList` companion. Idempotent (a no-op when the top
    /// isn't a `.list`), so call sites don't need to check first.
    fn maybeCloseTopList(self: *Parser, idx: usize, mk: ?ListMarker) Allocator.Error!void {
        if (self.top().kind != .list) return;
        if (mk) |m| if (self.topIsCompatibleList(m)) return;
        try self.popContainer(idx);
    }

    fn listCompatible(c: *const Container, mk: ListMarker) bool {
        if (c.kind != .list) return false;
        if (c.ordered != mk.ordered) return false;
        if (mk.ordered) return c.delim == mk.delim;
        return c.bullet_char == mk.bullet_char;
    }

    fn topIsCompatibleList(self: *Parser, mk: ListMarker) bool {
        return listCompatible(self.top(), mk);
    }

    /// True when the currently open leaf's own container is a `.list_item`
    /// -- i.e. we are already somewhere inside a list, as opposed to a
    /// bare top-level (or block-quote-level, etc.) paragraph with no list
    /// context at all. Used by `canInterruptParagraph`: CommonMark's "an
    /// empty list item / an ordered list not starting at 1 can't interrupt
    /// a paragraph" restriction exists only to stop a bare paragraph from
    /// spuriously turning into a list (see the spec's "hard-wrapped
    /// numerals" rationale); it does NOT apply once we're already inside a
    /// list item, where "changing the bullet or ordered list delimiter
    /// starts a new list" applies UNCONDITIONALLY instead (spec examples
    /// 283 and 301-302: `1. foo / 2. / 3. bar` keeps an empty item 2, and
    /// `1. foo / 2. bar / 3) baz` starts a whole new `<ol>` at item 3,
    /// despite neither satisfying the "non-empty"/"starts at 1" gate).
    fn isInsideListItem(self: *Parser) bool {
        return self.top().kind == .list_item;
    }

    // ── Phase 3: frontmatter ─────────────────────────────────────────────

    /// A leading `---`/`+++` frontmatter block (`self.options.frontmatter`):
    /// only ever tried ONCE, before the main line-by-line scan even starts
    /// (see `parse`), since frontmatter is defined as a leading construct —
    /// unlike every other Phase 3 extension, it never competes with
    /// mid-document block starts. `self.lines[0]` must be EXACTLY `---` (a
    /// YAML block) or `+++` (a TOML block), ignoring only trailing
    /// whitespace; the block ends at the first later line that's exactly
    /// the SAME delimiter. If no such closing line exists, this is NOT
    /// frontmatter at all (falls through to ordinary parsing — a bare
    /// leading `---` with no closer is just a thematic break, same as with
    /// the flag off). On success, the whole block becomes a single
    /// `raw_block{format="yaml"|"toml"}` node (see this file's/the
    /// mission's rationale: the shared HTML printer only ever emits
    /// `raw_block` text for `format == "html"`, so this renders as nothing
    /// in the HTML body while staying fully inspectable via `-o ast`).
    fn tryConsumeFrontmatter(self: *Parser) Allocator.Error!void {
        if (self.lines.len == 0) return;
        const first = std.mem.trimEnd(u8, self.lines[0], " \t");
        const format: []const u8 = if (std.mem.eql(u8, first, "---"))
            "yaml"
        else if (std.mem.eql(u8, first, "+++"))
            "toml"
        else
            return;

        var i: usize = 1;
        while (i < self.lines.len) : (i += 1) {
            const line = std.mem.trimEnd(u8, self.lines[i], " \t");
            if (!std.mem.eql(u8, line, first)) continue;

            var text = std.ArrayList(u8).empty;
            defer text.deinit(self.allocator);
            for (self.lines[1..i]) |content_line| {
                try text.appendSlice(self.allocator, content_line);
                try text.append(self.allocator, '\n');
            }
            const id = try self.builder.addLeaf(.{ .raw_block = .{ .format = format, .text = text.items } });
            self.builder.setSpan(id, Span.init(self.lineStart(0), self.lineEnd(i)));
            try self.appendToTop(id);
            self.skip_until_line = i + 1;
            return;
        }
        // No closing delimiter anywhere in the document: not frontmatter.
    }

    // ── Phase 3: GFM tables ──────────────────────────────────────────────

    /// GFM pipe tables (`self.options.tables`). APPROXIMATIONS, documented:
    ///   - A table never interrupts an already-open paragraph (checked via
    ///     the caller's `!interrupting` gate) -- unlike CommonMark's other
    ///     block starts. Most real-world tables are preceded by a blank
    ///     line anyway; this keeps the "does this line start a table"
    ///     question fully local to a genuine fresh-block position instead
    ///     of needing paragraph-reinterpretation machinery.
    ///   - A header row is any non-blank, <=3-space-indented line containing
    ///     an unescaped `|` (`containsUnescapedPipe`), immediately followed
    ///     by a valid delimiter row (`parseDelimiterRow`: cells of the form
    ///     `:?-+:?`) with the exact SAME cell count.
    ///   - Body rows continue for as long as subsequent lines (i) still
    ///     match every currently open ancestor container (so a table nested
    ///     in a block quote/list item stays properly scoped), (ii) are
    ///     non-blank and not indented code, and (iii) don't themselves look
    ///     like the start of some other block construct
    ///     (`looksLikeNewBlockStart`). Per the GFM spec, ragged rows are
    ///     padded (missing cells) or truncated (extra cells) to the header's
    ///     column count rather than ending the table.
    ///   - `|` inside a backtick code span is NOT treated specially (unlike
    ///     real GFM); only a backslash-escaped `\|` is recognized as a
    ///     non-splitting pipe. A cell containing `` `a|b` `` therefore
    ///     splits where a strict implementation wouldn't.
    fn tryStartTable(self: *Parser, line: []const u8, cur: Cursor, idx: usize) Allocator.Error!bool {
        const remainder = line[cur.pos..];
        const s = stripUpTo3Indent(remainder);
        if (isBlankLine(s)) return false;
        if (!containsUnescapedPipe(s)) return false;
        if (idx + 1 >= self.lines.len) return false;

        const next_line = self.lines[idx + 1];
        const nm = self.matchContainers(next_line);
        if (nm.matched_index != self.stack.items.len) return false;
        const next_remainder = next_line[nm.cur.pos..];
        if (indentCols(next_remainder, .{}) >= 4) return false;
        const next_s = stripUpTo3Indent(next_remainder);

        const header_cells = try splitTableRow(self.allocator, s);
        defer self.allocator.free(header_cells);
        if (header_cells.len == 0) return false;

        const aligns = (try parseDelimiterRow(self.allocator, next_s)) orelse return false;
        defer self.allocator.free(aligns);
        if (aligns.len != header_cells.len) return false;

        try self.maybeCloseTopList(idx, null);
        self.markListsLoose();

        var row_ids = std.ArrayList(Node.Id).empty;
        defer row_ids.deinit(self.allocator);

        const header_row_id = try self.buildTableRow(header_cells, aligns, true, idx, idx);
        try row_ids.append(self.allocator, header_row_id);

        var last_idx = idx + 1;
        var scan = idx + 2;
        while (scan < self.lines.len) {
            const row_line = self.lines[scan];
            const rm = self.matchContainers(row_line);
            if (rm.matched_index != self.stack.items.len) break;
            const row_remainder = row_line[rm.cur.pos..];
            if (isBlankLine(row_remainder)) break;
            if (indentCols(row_remainder, .{}) >= 4) break;
            const row_s = stripUpTo3Indent(row_remainder);
            if (looksLikeNewBlockStart(row_s)) break;

            const raw_cells = try splitTableRow(self.allocator, row_s);
            defer self.allocator.free(raw_cells);
            const row_id = try self.buildTableRow(raw_cells, aligns, false, scan, scan);
            try row_ids.append(self.allocator, row_id);
            last_idx = scan;
            scan += 1;
        }

        const caption_id = try self.builder.addContainer(.caption, &.{});
        var all_children = std.ArrayList(Node.Id).empty;
        defer all_children.deinit(self.allocator);
        try all_children.append(self.allocator, caption_id);
        try all_children.appendSlice(self.allocator, row_ids.items);

        const table_id = try self.builder.addContainer(.table, all_children.items);
        self.builder.setSpan(table_id, Span.init(self.lineStart(idx), self.lineEnd(last_idx)));
        setContentSpanFromChildren(&self.builder, table_id);
        try self.appendToTop(table_id);

        self.skip_until_line = last_idx + 1;
        return true;
    }

    /// Build one `row` node with exactly `aligns.len` `cell` children,
    /// pulling text from `cells[i]` when present or `""` for a ragged
    /// row's missing trailing cells (extra `cells` entries beyond
    /// `aligns.len` are simply never visited -- GFM's "ignore extra cells"
    /// rule).
    fn buildTableRow(self: *Parser, cells: []const []const u8, aligns: []const AST.Alignment, head: bool, start_line: usize, end_line: usize) Allocator.Error!Node.Id {
        var cell_ids = std.ArrayList(Node.Id).empty;
        defer cell_ids.deinit(self.allocator);
        for (aligns, 0..) |al, i| {
            const text = if (i < cells.len) cells[i] else "";
            const cell_id = try self.addDeferredTextNode(.{ .cell = .{ .head = head, .alignment = al } }, text, start_line, end_line);
            try cell_ids.append(self.allocator, cell_id);
        }
        const row_id = try self.builder.addContainer(.{ .row = .{ .head = head } }, cell_ids.items);
        self.builder.setSpan(row_id, Span.init(self.lineStart(start_line), self.lineEnd(end_line)));
        return row_id;
    }

    // ── Phase 3: definition lists ────────────────────────────────────────

    /// PHP-Markdown-Extra / Pandoc style definition lists
    /// (`self.options.definition_lists`). Grammar implemented here
    /// (documented since this is a twig-chosen approximation, not a spec):
    ///
    ///   Term
    ///   : Definition text -- may lazily continue onto further lines
    ///     (joined with a soft break, like an ordinary paragraph) until a
    ///     blank line, another `:`-line, or a line that looks like some
    ///     other block construct.
    ///   : A second `:`-line right after the first starts ANOTHER
    ///     definition for the SAME term (a `definition_list_item` can hold
    ///     more than one `definition`).
    ///
    ///   Term 2
    ///   : Definition
    ///
    /// A "term" is a single-line paragraph (no blank line yet, exactly one
    /// line accumulated) immediately followed by a `:`-line (at <=3 space
    /// indent, `:` then a space/tab). Consecutive `Term\n: def...` groups,
    /// separated by at most ONE blank line, merge into a single
    /// `definition_list`; anything else ends it. Only tried when the
    /// currently open leaf is a single-line paragraph (mirrors the
    /// setext-heading check right next to this call site) -- a definition
    /// list therefore never interrupts a multi-line paragraph.
    fn tryStartDefinitionList(self: *Parser, lf: *Leaf, line: []const u8, cur: Cursor, idx: usize) Allocator.Error!bool {
        const s = stripUpTo3Indent(line[cur.pos..]);
        if (!isDefinitionMarkerLine(s)) return false;

        const trimmed_term = std.mem.trim(u8, lf.text.items, " \t\r\n");
        if (trimmed_term.len == 0) return false;
        const term_text = try self.allocator.dupe(u8, trimmed_term);
        defer self.allocator.free(term_text);
        var term_start_line = lf.start_line;
        // Free the paragraph leaf's own buffer FIRST (while `lf` -- a
        // pointer into `self.leaf`'s payload -- is still valid), THEN null
        // out `self.leaf` itself; doing it in the other order would zero
        // the memory `lf` points to before `deinit` ever reads it, leaking
        // the text buffer (`Leaf.deinit` on an already-zeroed `ArrayList`
        // is a silent no-op, not a double-free, which is exactly what made
        // this easy to miss).
        lf.deinit(self.allocator);
        self.leaf = null;

        try self.maybeCloseTopList(idx, null);
        self.markListsLoose();

        var item_ids = std.ArrayList(Node.Id).empty;
        defer item_ids.deinit(self.allocator);
        var scan = idx;
        var last_idx = idx;
        var current_term = term_text;
        var owned_term: ?[]u8 = null;
        defer if (owned_term) |t| self.allocator.free(t);

        while (true) {
            const term_id = try self.addDeferredTextNode(.term, current_term, term_start_line, term_start_line);
            var def_ids = std.ArrayList(Node.Id).empty;
            defer def_ids.deinit(self.allocator);

            while (scan < self.lines.len) {
                const dline = self.lines[scan];
                const dm = self.matchContainers(dline);
                if (dm.matched_index != self.stack.items.len) break;
                const ds = stripUpTo3Indent(dline[dm.cur.pos..]);
                if (!isDefinitionMarkerLine(ds)) break;

                var content = std.ArrayList(u8).empty;
                defer content.deinit(self.allocator);
                try content.appendSlice(self.allocator, trimLeadingWs(ds[1..]));
                const def_start = scan;
                var def_end = scan;
                scan += 1;
                while (scan < self.lines.len) {
                    const cline = self.lines[scan];
                    const cm = self.matchContainers(cline);
                    if (cm.matched_index != self.stack.items.len) break;
                    const crem = cline[cm.cur.pos..];
                    if (isBlankLine(crem)) break;
                    const cs = stripUpTo3Indent(crem);
                    if (isDefinitionMarkerLine(cs)) break;
                    if (looksLikeNewBlockStart(cs)) break;
                    try content.append(self.allocator, '\n');
                    try content.appendSlice(self.allocator, trimLeadingWs(crem));
                    def_end = scan;
                    scan += 1;
                }
                const def_id = try self.addDeferredTextNode(.definition, content.items, def_start, def_end);
                try def_ids.append(self.allocator, def_id);
                last_idx = def_end;
            }
            if (def_ids.items.len == 0) {
                // The term matched but not one single `:`-line actually
                // parsed (shouldn't happen given `isDefinitionMarkerLine`
                // gated entry, but guards against an empty item).
                break;
            }

            var item_children = std.ArrayList(Node.Id).empty;
            defer item_children.deinit(self.allocator);
            try item_children.append(self.allocator, term_id);
            try item_children.appendSlice(self.allocator, def_ids.items);
            const item_id = try self.builder.addContainer(.definition_list_item, item_children.items);
            self.builder.setSpan(item_id, Span.init(self.lineStart(term_start_line), self.lineEnd(last_idx)));
            try item_ids.append(self.allocator, item_id);

            // Look for another `Term\n: def` group, tolerating at most one
            // blank line before it.
            var next_idx = scan;
            if (next_idx < self.lines.len) {
                const bl = self.lines[next_idx];
                const bm = self.matchContainers(bl);
                if (bm.matched_index == self.stack.items.len and isBlankLine(bl[bm.cur.pos..])) next_idx += 1;
            }
            if (next_idx >= self.lines.len or next_idx + 1 >= self.lines.len) break;
            const tl = self.lines[next_idx];
            const tm = self.matchContainers(tl);
            if (tm.matched_index != self.stack.items.len) break;
            const trem = tl[tm.cur.pos..];
            if (isBlankLine(trem) or indentCols(trem, .{}) >= 4) break;
            const ts = stripUpTo3Indent(trem);
            if (isDefinitionMarkerLine(ts) or looksLikeNewBlockStart(ts)) break;

            const dl2 = self.lines[next_idx + 1];
            const dm2 = self.matchContainers(dl2);
            if (dm2.matched_index != self.stack.items.len) break;
            const ds2 = stripUpTo3Indent(dl2[dm2.cur.pos..]);
            if (!isDefinitionMarkerLine(ds2)) break;

            if (owned_term) |t| self.allocator.free(t);
            owned_term = try self.allocator.dupe(u8, std.mem.trim(u8, ts, " \t\r\n"));
            current_term = owned_term.?;
            term_start_line = next_idx;
            scan = next_idx + 1;
        }

        const list_id = try self.builder.addContainer(.definition_list, item_ids.items);
        self.builder.setSpan(list_id, Span.init(self.lineStart(idx), self.lineEnd(last_idx)));
        setContentSpanFromChildren(&self.builder, list_id);
        try self.appendToTop(list_id);
        self.skip_until_line = last_idx + 1;
        return true;
    }

    // ── link reference definitions ───────────────────────────────────────

    /// Strip as many consecutive link reference definitions as possible
    /// from the FRONT of `raw` (a to-be-closed paragraph's accumulated raw
    /// text), registering each in `self.link_references`. Returns whatever
    /// text is left (possibly all of it, if none matched, or empty, if the
    /// whole thing was definitions).
    fn stripLinkReferenceDefinitions(self: *Parser, raw: []const u8) Allocator.Error![]const u8 {
        var text = raw;
        while (true) {
            const consumed = try self.tryParseLinkRefDef(text);
            if (consumed == 0) break;
            text = text[consumed..];
            if (text.len > 0 and text[0] == '\n') text = text[1..];
        }
        return text;
    }

    /// Returns the number of bytes consumed from the front of `text` on a
    /// successful parse (0 = no definition there).
    fn tryParseLinkRefDef(self: *Parser, text: []const u8) Allocator.Error!usize {
        var i: usize = 0;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i >= text.len or text[i] != '[') return 0;
        i += 1;
        const label_start = i;
        var escaped = false;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '[') return 0;
            if (c == ']') break;
        }
        if (i >= text.len or text[i] != ']') return 0;
        const label = text[label_start..i];
        // A label needs at least one non-whitespace character -- `[]: /uri`
        // is not a link reference definition at all (CommonMark: "at least
        // one character other than blank space").
        if (std.mem.trim(u8, label, " \t\r\n").len == 0) return 0;
        i += 1;
        if (i >= text.len or text[i] != ':') return 0;
        i += 1;
        i = skipLrdWs(text, i);
        if (i >= text.len) return 0;

        var dest: []const u8 = undefined;
        if (text[i] == '<') {
            const start = i + 1;
            var j = start;
            while (j < text.len and text[j] != '>' and text[j] != '\n') : (j += 1) {
                if (text[j] == '\\' and j + 1 < text.len) j += 1;
            }
            if (j >= text.len or text[j] != '>') return 0;
            dest = text[start..j];
            i = j + 1;
        } else {
            const start = i;
            var depth: usize = 0;
            var j = i;
            while (j < text.len) : (j += 1) {
                const c = text[j];
                if (c == '\\' and j + 1 < text.len) {
                    j += 1;
                    continue;
                }
                if (c == ' ' or c == '\t' or c == '\n') break;
                if (c == '(') depth += 1;
                if (c == ')') {
                    if (depth == 0) break;
                    depth -= 1;
                }
            }
            if (j == start) return 0;
            dest = text[start..j];
            i = j;
        }

        const label_owned = try normalizeLabel(self.allocator, label);
        defer self.allocator.free(label_owned);
        const dest_decoded = try inline_mod.decodeText(self.allocator, dest);
        defer self.allocator.free(dest_decoded);

        // Try a title: whitespace (possibly with one line ending) then a
        // quoted/paren title, with only blank content after its closer on
        // that line. If a title-shaped thing is present but malformed, the
        // whole definition attempt fails (see this file's module doc
        // comment's documented simplification).
        const after_dest = i;
        const ws_end = skipLrdWs(text, after_dest);
        var title: ?[]const u8 = null;
        var end = after_dest;
        if (ws_end > after_dest and ws_end < text.len and (text[ws_end] == '"' or text[ws_end] == '\'' or text[ws_end] == '(')) {
            const open = text[ws_end];
            const close: u8 = if (open == '(') ')' else open;
            var j = ws_end + 1;
            while (j < text.len and text[j] != close) : (j += 1) {
                if (text[j] == '\\' and j + 1 < text.len) j += 1;
            }
            if (j < text.len) {
                const rest_start = j + 1;
                const line_end = std.mem.indexOfScalarPos(u8, text, rest_start, '\n') orelse text.len;
                if (isBlankLine(text[rest_start..line_end])) {
                    title = text[ws_end + 1 .. j];
                    end = line_end;
                } else return 0;
            } else return 0;
        } else {
            const line_end = std.mem.indexOfScalarPos(u8, text, after_dest, '\n') orelse text.len;
            if (!isBlankLine(text[after_dest..line_end])) return 0;
            end = line_end;
        }

        const ref_id = try self.builder.addLeaf(.{ .reference = .{ .label = label_owned, .destination = dest_decoded } });
        if (title) |t| {
            const title_decoded = try inline_mod.decodeText(self.allocator, t);
            defer self.allocator.free(title_decoded);
            try self.builder.setAttrs(ref_id, .{ .entries = &.{.{ .key = "title", .value = title_decoded }} });
        }
        if (!self.link_references.contains(label_owned)) {
            // Reuse the `reference` node's OWN label string (already
            // duped into `self.builder`'s `owned_strings` by `addLeaf` /
            // `dupeKind`) as the map key, rather than allocating yet
            // another copy — see `deinit`'s comment on why this map never
            // frees its own keys.
            const key = self.builder.nodes.items[ref_id].kind.reference.label;
            try self.link_references.put(self.allocator, key, ref_id);
        }
        return end;
    }

    fn skipLrdWs(text: []const u8, start: usize) usize {
        var i = start;
        var seen_nl = false;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (c == ' ' or c == '\t') continue;
            if (c == '\n' and !seen_nl) {
                seen_nl = true;
                continue;
            }
            break;
        }
        return i;
    }
};

pub fn parse(allocator: Allocator, source: []const u8, options: Options) Allocator.Error!BlockResult {
    var p = try Parser.init(allocator, source, options);
    defer p.deinit();
    return p.parse();
}

const testing = std.testing;
const Html = @import("../html/html.zig");

fn renderHtml(source: []const u8, options: Options) ![]u8 {
    var r = try parse(testing.allocator, source, options);
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    return Html.serializeAlloc(testing.allocator, &r.ast, null);
}

test "ATX heading" {
    var r = try parse(testing.allocator, "## Hello\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    const h = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[h].kind.heading.level == 2);
    const text = r.ast.nodes[h].first_child.?;
    try testing.expectEqualStrings("Hello", r.ast.nodes[text].kind.str);
}

test "fenced code block with a language" {
    var r = try parse(testing.allocator, "```zig\nconst x = 1;\n```\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    const cb = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expectEqualStrings("zig", r.ast.nodes[cb].kind.code_block.lang.?);
    try testing.expectEqualStrings("const x = 1;\n", r.ast.nodes[cb].kind.code_block.text);
}

test "tight bullet list with two items" {
    var r = try parse(testing.allocator, "- a\n- b\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    const list = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[list].kind.bullet_list.tight);
    const item1 = r.ast.nodes[list].first_child.?;
    const item2 = r.ast.nodes[item1].next_sibling.?;
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[item2].next_sibling);
}

test "block quote" {
    var r = try parse(testing.allocator, "> foo\n> bar\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    const bq = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[bq].kind == .block_quote);
    const para = r.ast.nodes[bq].first_child.?;
    try testing.expect(r.ast.nodes[para].kind == .para);
}

test "HTML block" {
    var r = try parse(testing.allocator, "<div>\n  <p>hi</p>\n</div>\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    const rb = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[rb].kind == .raw_block);
    try testing.expectEqualStrings("html", r.ast.nodes[rb].kind.raw_block.format);
}

test "paragraph with a code span and a hard break" {
    var r = try parse(testing.allocator, "foo `bar`  \nbaz\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    const para = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[para].kind == .para);
    var it = r.ast.children(para);
    _ = it.next().?; // "foo "
    const code = it.next().?;
    try testing.expectEqualStrings("bar", code.kind.verbatim);
    const brk = it.next().?;
    try testing.expect(brk.kind == .hard_break);
}

test "a link reference definition is stripped and recorded in the table" {
    var r = try parse(testing.allocator, "[foo]: /url \"title\"\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[r.ast.root].first_child);
    const ref_id = r.link_references.get("foo") orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("/url", r.ast.nodes[ref_id].kind.reference.destination);
    try testing.expectEqualStrings("title", r.ast.attrsOf(ref_id).get("title").?);
}

// ── Phase 3: GFM tables ─────────────────────────────────────────────────

test "table: header/delimiter/body with per-column alignment" {
    var r = try parse(testing.allocator,
        \\| a | b | c |
        \\|---|:--:|--:|
        \\| 1 | 2 | 3 |
        \\
    , .{ .tables = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);

    const table = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[table].kind == .table);
    const caption = r.ast.nodes[table].first_child.?;
    try testing.expect(r.ast.nodes[caption].kind == .caption);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[caption].first_child);

    const head_row = r.ast.nodes[caption].next_sibling.?;
    try testing.expect(r.ast.nodes[head_row].kind == .row);
    try testing.expect(r.ast.nodes[head_row].kind.row.head);
    const c1 = r.ast.nodes[head_row].first_child.?;
    try testing.expect(r.ast.nodes[c1].kind.cell.head);
    try testing.expectEqual(AST.Alignment.default, r.ast.nodes[c1].kind.cell.alignment);
    const c2 = r.ast.nodes[c1].next_sibling.?;
    try testing.expectEqual(AST.Alignment.center, r.ast.nodes[c2].kind.cell.alignment);
    const c3 = r.ast.nodes[c2].next_sibling.?;
    try testing.expectEqual(AST.Alignment.right, r.ast.nodes[c3].kind.cell.alignment);

    const body_row = r.ast.nodes[head_row].next_sibling.?;
    try testing.expect(!r.ast.nodes[body_row].kind.row.head);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[body_row].next_sibling);
}

test "table: ragged rows are padded/truncated to the header's column count" {
    var r = try parse(testing.allocator,
        \\| a | b |
        \\| - | - |
        \\| 1 |
        \\| 1 | 2 | 3 |
        \\
    , .{ .tables = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);

    const table = r.ast.nodes[r.ast.root].first_child.?;
    const caption = r.ast.nodes[table].first_child.?;
    const head_row = r.ast.nodes[caption].next_sibling.?;
    const short_row = r.ast.nodes[head_row].next_sibling.?;
    const short_c1 = r.ast.nodes[short_row].first_child.?;
    const short_c2 = r.ast.nodes[short_c1].next_sibling.?;
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[short_c2].next_sibling);

    const long_row = r.ast.nodes[short_row].next_sibling.?;
    const long_c1 = r.ast.nodes[long_row].first_child.?;
    const long_c2 = r.ast.nodes[long_c1].next_sibling.?;
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[long_c2].next_sibling);
}

test "table: renders through the shared HTML printer with an empty caption" {
    const html = try renderHtml("| a | b |\n| - | - |\n| 1 | 2 |\n", .{ .tables = true });
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(
        "<table>\n<tr>\n<th>a</th>\n<th>b</th>\n</tr>\n<tr>\n<td>1</td>\n<td>2</td>\n</tr>\n</table>\n",
        html,
    );
}

test "table OFF: a pipe 'table' parses as an ordinary CommonMark paragraph" {
    var r = try parse(testing.allocator, "| a | b |\n| - | - |\n", .{ .tables = false });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    const para = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[para].kind == .para);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[para].next_sibling);
}

// ── Phase 3: task lists ──────────────────────────────────────────────────

test "task list: unchecked and checked (case-insensitive) items" {
    var r = try parse(testing.allocator, "- [ ] todo\n- [x] done\n- [X] also done\n", .{ .task_lists = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);

    const list = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[list].kind == .task_list);
    const item1 = r.ast.nodes[list].first_child.?;
    try testing.expect(r.ast.nodes[item1].kind == .task_list_item);
    try testing.expect(!r.ast.nodes[item1].kind.task_list_item.checked);
    const para1 = r.ast.nodes[item1].first_child.?;
    const text1 = r.ast.nodes[para1].first_child.?;
    try testing.expectEqualStrings("todo", r.ast.nodes[text1].kind.str);

    const item2 = r.ast.nodes[item1].next_sibling.?;
    try testing.expect(r.ast.nodes[item2].kind.task_list_item.checked);
    const item3 = r.ast.nodes[item2].next_sibling.?;
    try testing.expect(r.ast.nodes[item3].kind.task_list_item.checked);
}

test "task list: renders an <input type=checkbox> via the shared HTML printer" {
    const html = try renderHtml("- [x] done\n", .{ .task_lists = true });
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(
        "<ul class=\"task-list\">\n<li>\n<input disabled=\"\" type=\"checkbox\" checked=\"\"/>\ndone\n</li>\n</ul>\n",
        html,
    );
}

test "task lists OFF: '- [ ] x' is a plain bullet list item with literal text" {
    var r = try parse(testing.allocator, "- [ ] x\n", .{ .task_lists = false });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    const list = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[list].kind == .bullet_list);
    const item = r.ast.nodes[list].first_child.?;
    try testing.expect(r.ast.nodes[item].kind == .list_item);
    const para = r.ast.nodes[item].first_child.?;
    // `[ ]` with no following `(`/`[` and no matching reference falls back
    // to literal brackets per Phase 2's existing (unrelated to this flag)
    // link-resolution rules -- it doesn't stay ONE `str` node (see
    // `inline.zig`'s "an unresolved reference label falls back to literal
    // brackets" test), so concatenate every child's text instead.
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    var it = r.ast.children(para);
    while (it.next()) |n| try buf.appendSlice(testing.allocator, n.kind.str);
    try testing.expectEqualStrings("[ ] x", buf.items);
}

// ── Phase 3: extended autolinks (block-level integration) ────────────────

test "extended autolinks render through the shared HTML printer" {
    const html = try renderHtml("visit www.example.com today\n", .{ .autolinks = true });
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<p>visit <a href=\"http://www.example.com\">www.example.com</a> today</p>\n", html);
}

// ── Phase 3: math (block-level integration) ──────────────────────────────

test "math renders through the shared HTML printer" {
    const html = try renderHtml("$x$ and $$y$$\n", .{ .math = true });
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(
        "<p><span class=\"math inline\">\\(x\\)</span> and <span class=\"math display\">\\[y\\]</span></p>\n",
        html,
    );
}

// ── Phase 3: definition lists ────────────────────────────────────────────

test "definition list: a term with two definitions" {
    var r = try parse(testing.allocator,
        \\Term
        \\: First definition
        \\: Second definition
        \\
    , .{ .definition_lists = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);

    const dl = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[dl].kind == .definition_list);
    const item = r.ast.nodes[dl].first_child.?;
    try testing.expect(r.ast.nodes[item].kind == .definition_list_item);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[item].next_sibling);

    const term = r.ast.nodes[item].first_child.?;
    try testing.expect(r.ast.nodes[term].kind == .term);
    const term_text = r.ast.nodes[term].first_child.?;
    try testing.expectEqualStrings("Term", r.ast.nodes[term_text].kind.str);

    const def1 = r.ast.nodes[term].next_sibling.?;
    try testing.expect(r.ast.nodes[def1].kind == .definition);
    const def1_text = r.ast.nodes[def1].first_child.?;
    try testing.expectEqualStrings("First definition", r.ast.nodes[def1_text].kind.str);

    const def2 = r.ast.nodes[def1].next_sibling.?;
    try testing.expect(r.ast.nodes[def2].kind == .definition);
    const def2_text = r.ast.nodes[def2].first_child.?;
    try testing.expectEqualStrings("Second definition", r.ast.nodes[def2_text].kind.str);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[def2].next_sibling);
}

test "definition list: two adjacent term groups merge into one definition_list" {
    var r = try parse(testing.allocator,
        \\Term A
        \\: def a
        \\
        \\Term B
        \\: def b
        \\
    , .{ .definition_lists = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);

    const dl = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[dl].kind == .definition_list);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[dl].next_sibling);
    const item1 = r.ast.nodes[dl].first_child.?;
    const item2 = r.ast.nodes[item1].next_sibling.?;
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[item2].next_sibling);
    const term2 = r.ast.nodes[item2].first_child.?;
    const term2_text = r.ast.nodes[term2].first_child.?;
    try testing.expectEqualStrings("Term B", r.ast.nodes[term2_text].kind.str);
}

test "definition list: renders as <dl><dt>...<dd>... via the shared HTML printer" {
    const html = try renderHtml("Term\n: def\n", .{ .definition_lists = true });
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<dl>\n<dt>Term</dt>\n<dd>\ndef</dd>\n</dl>\n", html);
}

test "definition lists OFF: 'Term\\n: def' lazily continues one CommonMark paragraph" {
    var r = try parse(testing.allocator, "Term\n: def\n", .{ .definition_lists = false });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    const para = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[para].kind == .para);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[para].next_sibling);
}

// ── Phase 3: frontmatter ──────────────────────────────────────────────────

test "frontmatter: a leading YAML block becomes a raw_block, not rendered to HTML" {
    var r = try parse(testing.allocator, "---\ntitle: Hi\n---\n# Heading\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);

    const fm = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[fm].kind == .raw_block);
    try testing.expectEqualStrings("yaml", r.ast.nodes[fm].kind.raw_block.format);
    try testing.expectEqualStrings("title: Hi\n", r.ast.nodes[fm].kind.raw_block.text);

    const heading = r.ast.nodes[fm].next_sibling.?;
    try testing.expect(r.ast.nodes[heading].kind == .heading);

    const html = try Html.serializeAlloc(testing.allocator, &r.ast, null);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<h1>Heading</h1>\n", html);
}

test "frontmatter: a leading TOML (+++) block is tagged format=\"toml\"" {
    var r = try parse(testing.allocator, "+++\ntitle = \"Hi\"\n+++\nbody\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    const fm = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[fm].kind == .raw_block);
    try testing.expectEqualStrings("toml", r.ast.nodes[fm].kind.raw_block.format);
    try testing.expectEqualStrings("title = \"Hi\"\n", r.ast.nodes[fm].kind.raw_block.text);
}

test "frontmatter: an unterminated leading '---' block falls back to ordinary parsing" {
    var r = try parse(testing.allocator, "---\ntitle: Hi\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    // No closing `---`: the first line is just a thematic break, same as
    // with the flag off.
    const first = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[first].kind == .thematic_break);
}

test "frontmatter OFF: a leading '---' is an ordinary CommonMark thematic break" {
    var r = try parse(testing.allocator, "---\nfoo\n", .{ .frontmatter = false });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    const first = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[first].kind == .thematic_break);
    const para = r.ast.nodes[first].next_sibling.?;
    try testing.expect(r.ast.nodes[para].kind == .para);
}
