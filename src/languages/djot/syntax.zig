//! Djot's surface spelling — the table `Editor`'s authoring gestures consult.
//! See `src/syntax.zig` for the model and why this is data rather than a
//! `switch (format)` at some boundary.
//!
//! This lives beside djot's parser on purpose: every value here is a claim
//! about what `djot/parser.zig` will read back and what `djot/serializer.zig`
//! emits, so it belongs where a change to either would be noticed.

const std = @import("std");
const syntax = @import("../../syntax.zig");
const inline_mod = @import("inline.zig");

/// Djot classifies an autolink on content alone, so this defers to the parser's
/// own scanner rather than re-deriving the rule. `angled` arrives with its
/// brackets, which `autolinkKindOf` doesn't want.
fn spellsAutolink(angled: []const u8) bool {
    if (angled.len < 2) return false;
    return inline_mod.InlineParser.autolinkKindOf(angled[1 .. angled.len - 1]) != null;
}

/// Djot spells all eight inline marks — the reason `InlineKind` has eight
/// variants at all.
pub const table: syntax.Syntax = .{
    .inline_delims = .init(.{
        .strong = .{ .open = "*", .close = "*" },
        .emph = .{ .open = "_", .close = "_" },
        .verbatim = .{ .open = "`", .close = "`" },
        .mark = .{ .open = "{=", .close = "=}" },
        .superscript = .{ .open = "^", .close = "^" },
        .subscript = .{ .open = "~", .close = "~" },
        .insert = .{ .open = "{+", .close = "+}" },
        .delete = .{ .open = "{-", .close = "-}" },
    }),
    .container_spelling = .init(.{
        .block_quote = .{ .marker = "> ", .cont = "> ", .blank = ">" },
        .bullet_list = .{ .marker = "- ", .cont = "  ", .blank = "" },
        .ordered_list = .{ .marker = "", .cont = "", .blank = "", .numbered = true },
    }),
    .heading_marker = '#',
    // Djot has attributes (`{…}`) and smart punctuation (`"`/`'`/`-`/`.`/`:`)
    // where Markdown has entities and raw HTML — hence the divergence from
    // `markdown/syntax.zig`'s set.
    .link_text_escapes = "\\[]*_^`~\"'-.:{}",
    .link_dest_escapes = .{
        // No angle form: djot strips a newline and has no `<…>` destination
        // spelling, so a space is escaped in place.
        .plain = "\\()[`",
    },
    // Djot's inline metacharacters: its marks (`*_^~` and `` ` ``), its bracket
    // and brace constructs (`[]`, `{}`), the smart punctuation that would
    // transform (`"'-.:`), and — crucially — the delimiters INSIDE the braces
    // that a `{…}` span keys on, `=` (highlight) and `+` (insert). Escaping the
    // braces alone is not enough: djot reads `\{=m=\}` back as a `mark`, so the
    // `=`/`+` must go too. `<` guards the `<url>` autolink form. A superset of
    // `link_text_escapes`, which predates this and never needed the brace-inner
    // delimiters.
    .text_escapes = "\\[]*_^`~\"'-.:{}=+<",
    // `#` heading, `>` quote, `|` table row. The bullet openers (`-`/`+`/`*`),
    // the div `:` and the code fences (`` ` ``/`~`) are already escaped on every
    // line by `text_escapes`, so they need no line-start entry.
    .block_start_escapes = "#>|",
    .spellsAutolink = spellsAutolink,
};

test "djot spells every inline kind" {
    inline for (std.meta.fields(syntax.InlineKind)) |f| {
        try std.testing.expect(table.inline_delims.get(@enumFromInt(f.value)) != null);
    }
    table.assertCoherent();
    try std.testing.expect(table.authorable());
}

test "djot body-text literals extend the link-text alphabet with brace delimiters" {
    const te = table.text_escapes.?;
    // A superset of link text: every link-text escape, plus the brace-inner
    // delimiters (`=`/`+`) and the autolink `<` that body text also needs.
    for (table.link_text_escapes.?) |c| try std.testing.expect(std.mem.indexOfScalar(u8, te, c) != null);
    for ("=+<") |c| try std.testing.expect(std.mem.indexOfScalar(u8, te, c) != null);
    const bse = table.block_start_escapes.?;
    for ("#>|") |c| try std.testing.expect(std.mem.indexOfScalar(u8, bse, c) != null);
    // Disjoint from the always-on set.
    for (te) |c| try std.testing.expect(std.mem.indexOfScalar(u8, bse, c) == null);
    table.assertCoherent();
}

test "djot autolinks by content, so a bare mailto: is an email" {
    try std.testing.expect(spellsAutolink("<https://x.dev>"));
    try std.testing.expect(spellsAutolink("<a@b.dev>"));
    try std.testing.expect(spellsAutolink("<mailto:a@b.dev>"));
    // A relative path is not an autolink in either format.
    try std.testing.expect(!spellsAutolink("<foo/bar>"));
    try std.testing.expect(!spellsAutolink("<>"));
}
