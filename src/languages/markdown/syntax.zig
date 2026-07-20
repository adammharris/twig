//! Markdown's surface spelling — the table `Editor`'s authoring gestures
//! consult. See `src/syntax.zig` for the model.
//!
//! Markdown spells strictly LESS than djot: three inline marks against djot's
//! eight. That gap is the whole reason `Syntax.inline_delims` is a table of
//! optionals — `Editor.toggleInline(.mark)` has to be a clean
//! `error.UnsupportedFormat` here while it works one file over.

const std = @import("std");
const syntax = @import("../../syntax.zig");
const markdown = @import("markdown.zig");

/// Defers to the parser's own autolink scanner: Markdown wants an absolute URI
/// or a CommonMark email and silently reads anything else as RAW HTML, so a
/// re-derived rule here could turn `<foo>` into a tag.
fn spellsAutolink(angled: []const u8) bool {
    return markdown.spellsAutolink(angled);
}

pub const table: syntax.Syntax = .{
    // No `mark`/`superscript`/`subscript`/`insert`/`delete`: Markdown has no
    // lightweight spelling for any of them, so they stay `null` and every
    // gesture over them is refused rather than mis-spelled.
    .inline_delims = .init(.{
        .strong = .{ .open = "**", .close = "**" },
        .emph = .{ .open = "*", .close = "*" },
        .verbatim = .{ .open = "`", .close = "`" },
        .mark = null,
        .superscript = null,
        .subscript = null,
        .insert = null,
        .delete = null,
    }),
    .container_spelling = .init(.{
        .block_quote = .{ .marker = "> ", .cont = "> ", .blank = ">" },
        .bullet_list = .{ .marker = "- ", .cont = "  ", .blank = "" },
        .ordered_list = .{ .marker = "", .cont = "", .blank = "", .numbered = true },
    }),
    .heading_marker = '#',
    // `<` and `&` where djot has `{`/`}` and smart punctuation: Markdown reads
    // `<…>` as raw HTML and `&…;` as an entity.
    .link_text_escapes = "\\[]*_^`~<>&",
    .link_dest_escapes = .{
        .plain = "\\()<&",
        // Markdown's `<dest>` form carries a destination containing whitespace.
        // Inside it the brackets are what must be escaped, not the parens — and
        // `&` still is, because Markdown DECODES entity references in a
        // destination in both forms (an `a&amp;b` handed in would come back out
        // as `a&b`, corrupting the URL rather than breaking the link).
        .angle = .{ .escapes = "\\<>&" },
    },
    // Body-text literals. Narrower than `link_text_escapes` in reasoning but
    // reaching the same specials: `\` (escape), the emphasis/strike/code runs,
    // the link brackets, and — unlike link TEXT, which is already bounded by its
    // `[…]` — the two that mint markup out in the open, `<` (autolink / raw HTML)
    // and `&` (entity). Block openers that only bite at column zero are in
    // `block_start_escapes`, not here.
    .text_escapes = "\\*_`[]~<&",
    // `#` heading, `>` quote, `-`/`+` bullets (and `-` a thematic break or setext
    // underline), `=` a setext underline. `*`/`_` also open bullets/breaks but are
    // already escaped everywhere by `text_escapes`, so they need no entry here.
    .block_start_escapes = "#>-+=",
    .spellsAutolink = spellsAutolink,
};

test "markdown spells three inline kinds and refuses the other five" {
    try std.testing.expect(table.inline_delims.get(.strong) != null);
    try std.testing.expect(table.inline_delims.get(.emph) != null);
    try std.testing.expect(table.inline_delims.get(.verbatim) != null);
    for ([_]syntax.InlineKind{ .mark, .superscript, .subscript, .insert, .delete }) |k| {
        try std.testing.expect(table.inline_delims.get(k) == null);
    }
    table.assertCoherent();
    try std.testing.expect(table.authorable());
}

test "markdown spells body-text and line-start literals" {
    const te = table.text_escapes.?;
    // The always-on inline specials.
    for ("\\*_`[]~<&") |c| try std.testing.expect(std.mem.indexOfScalar(u8, te, c) != null);
    const bse = table.block_start_escapes.?;
    for ("#>-+=") |c| try std.testing.expect(std.mem.indexOfScalar(u8, bse, c) != null);
    // The two sets are disjoint: a byte escaped everywhere needs no line-start
    // entry, and `assertCoherent` pairs their nullness.
    for (te) |c| try std.testing.expect(std.mem.indexOfScalar(u8, bse, c) == null);
    table.assertCoherent();
}

test "markdown autolinks by scheme, so a bare word would be raw HTML" {
    try std.testing.expect(spellsAutolink("<https://x.dev>"));
    try std.testing.expect(spellsAutolink("<a@b.dev>"));
    // `<foo>` is a TAG, not an autolink — the reason this asks the parser.
    try std.testing.expect(!spellsAutolink("<foo>"));
    try std.testing.expect(!spellsAutolink("<foo/bar>"));
}
