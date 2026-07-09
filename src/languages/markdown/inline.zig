//! Phase 1 inline scanning: the minimal inline subset the mission scopes in
//! (see `markdown.zig`'s module doc comment) — plain text, backslash
//! escapes, entity/numeric character references, code spans, and
//! soft/hard breaks. Everything else CommonMark's inline grammar defines
//! (emphasis/strong, links, images, autolinks, raw inline HTML) is Phase 2 —
//! per the mission, unhandled markup passes through as literal `str` text,
//! so e.g. `*foo*` today parses as the six-character string `*foo*`, not an
//! `emph` node. That also means `<...>`-shaped text (which Phase 2 would
//! parse as either an autolink or raw inline HTML) is untouched here and
//! falls out as plain text too — there is no HTML-tag recognition at the
//! inline level yet.
//!
//! Fed a single already-assembled text buffer per leaf block (a paragraph's
//! lines joined by `\n`, an ATX heading's single line, ...) — never the raw
//! source directly, since block-level container markers (`>　`, list-item
//! indentation, ATX `#`s) have already been stripped out by `block.zig`
//! before this is called. A `\n` inside that buffer is exactly a line break
//! within the block; whether it renders as `soft_break` or `hard_break`
//! depends on what precedes it (two-or-more spaces, or a backslash) per
//! CommonMark's "Hard line breaks" section. The block assembler is
//! responsible for having already stripped trailing whitespace from the
//! very LAST line (there is no line break to classify there — trailing
//! whitespace at the end of a block is just gone), so every `\n` this file
//! sees is an internal break to classify.
//!
//! ── Entity decoding ──────────────────────────────────────────────────────
//! Named character references are matched against `entities.zig`'s
//! generated table (the full WHATWG HTML5 list, semicolon-terminated names
//! only — see that file's doc comment for why). To regenerate that table:
//! `curl https://html.spec.whatwg.org/entities.json`, filter to keys ending
//! in `;`, strip the leading `&`/trailing `;`, and emit a
//! `std.StaticStringMap([]const u8).initComptime` literal keyed by the bare
//! name with the entry's `characters` string as the value.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../../ast/ast.zig");
const Node = AST.Node;
const Builder = AST.Builder;
const entities = @import("entities.zig");

/// Parse `text` (a single leaf block's already-assembled content — see this
/// file's module doc comment) into a flat sequence of inline children, added
/// to `b` but not yet attached to any parent. Returns the ordered list of
/// child ids (caller's to free; typically immediately handed to
/// `b.setChildren`).
pub fn parseInline(b: *Builder, text: []const u8) Allocator.Error![]Node.Id {
    var children = std.ArrayList(Node.Id).empty;
    defer children.deinit(b.allocator);
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(b.allocator);

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '\\' => {
                if (i + 1 < text.len and text[i + 1] == '\n') {
                    // Backslash immediately before a line ending: hard break.
                    try flushStr(b, &buf, &children);
                    try children.append(b.allocator, try b.addLeaf(.hard_break));
                    i += 2;
                    i = skipLeadingLineSpace(text, i);
                    continue;
                }
                if (i + 1 < text.len and isAsciiPunct(text[i + 1])) {
                    try buf.append(b.allocator, text[i + 1]);
                    i += 2;
                    continue;
                }
                try buf.append(b.allocator, '\\');
                i += 1;
            },
            '\n' => {
                const hard = trailingHardBreakSpaces(buf.items);
                buf.items.len -= hard;
                try flushStr(b, &buf, &children);
                const kind: Node.Kind = if (hard >= 2) .hard_break else .soft_break;
                try children.append(b.allocator, try b.addLeaf(kind));
                i += 1;
                i = skipLeadingLineSpace(text, i);
            },
            '`' => {
                if (scanCodeSpan(text, i)) |span| {
                    try flushStr(b, &buf, &children);
                    const content = try normalizeCodeSpan(b.allocator, text[span.content_start..span.content_end]);
                    defer b.allocator.free(content);
                    try children.append(b.allocator, try b.addLeaf(.{ .verbatim = content }));
                    i = span.end;
                } else {
                    // No closing run of the SAME length as this opening
                    // run exists anywhere later in `text`: per CommonMark,
                    // the ENTIRE opening run is literal backticks (not
                    // just one -- emitting one and retrying from the next
                    // backtick would let a shorter run inside this one
                    // spuriously pair with a later close, which is not
                    // what a leftmost-longest-run match does).
                    var run_end = i;
                    while (run_end < text.len and text[run_end] == '`') run_end += 1;
                    try buf.appendSlice(b.allocator, text[i..run_end]);
                    i = run_end;
                }
            },
            '&' => {
                if (try decodeCharRef(b.allocator, text, i)) |ref| {
                    try buf.appendSlice(b.allocator, ref.text);
                    b.allocator.free(ref.text);
                    i = ref.end;
                } else {
                    try buf.append(b.allocator, '&');
                    i += 1;
                }
            },
            else => {
                try buf.append(b.allocator, c);
                i += 1;
            },
        }
    }
    try flushStr(b, &buf, &children);
    return children.toOwnedSlice(b.allocator);
}

/// Backslash-escape and entity/numeric-character-reference decoding only —
/// no code spans, no break detection — for the plain-text contexts that
/// need *some* inline processing without being a full inline scan: a fenced
/// code block's info string (whose first word becomes `code_block.lang`;
/// CommonMark decodes entities there, e.g. `` ```f&ouml;&ouml; `` names the
/// language `föö`) and link reference definition destinations/titles
/// (`block.zig`'s `stripLinkReferenceDefinitions`). Caller-owned result.
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

fn flushStr(b: *Builder, buf: *std.ArrayList(u8), children: *std.ArrayList(Node.Id)) Allocator.Error!void {
    if (buf.items.len == 0) return;
    const id = try b.addLeaf(.{ .str = buf.items });
    try children.append(b.allocator, id);
    buf.clearRetainingCapacity();
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

fn parseAndFinish(text: []const u8) !AST {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const children = try parseInline(&b, text);
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

test "unhandled inline markup (emphasis/links) passes through as literal text" {
    var ast = try parseAndFinish("*em* [link](url) <tag>");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("*em* [link](url) <tag>", ast.nodes[child].kind.str);
}
