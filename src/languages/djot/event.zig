//! Event = the flat intermediate representation between scanning
//! (`block.zig` + `inline.zig`) and tree-building (`parser.zig`). Mirrors
//! djot.js's `src/event.ts` (`{startpos, endpos, annot}`) plus the full
//! vocabulary of `annot` strings block.ts/inline.ts/attributes.ts actually
//! emit and parse.ts actually dispatches on — there is no single upstream
//! file enumerating them; they are literal string keys scattered across each
//! file's `addMatch`/`addEvent` calls and parse.ts's `handlers` table. This
//! file is the result of collecting all of them into one exhaustive enum.
//!
//! A whole document parses to one flat `[]Event` array. Container structure
//! is carried by *paired* annotations (`.emph_open` / `.emph_close`, matching
//! djot.js's `"+emph"` / `"-emph"` string pairs) rather than nesting; a
//! generic stack-based builder in `parser.zig` turns matched pairs into a
//! tree — see that file's module doc comment for why a flat stream (rather
//! than building the tree directly during scanning) matters here: forward
//! references/footnotes and tight/loose list determination both need to see
//! the *whole* stream before they can be resolved.
//!
//! One deliberate deviation from djot.js: where it packs extra data onto an
//! annot string via `|`-joined suffixes (`"+list|-|*"` for ambiguous bullet
//! styles), `Event` instead carries that data in a typed side field
//! (`list_styles`) — there's no need to serialize through a string when
//! producer and consumer are both this same codebase.

const std = @import("std");

pub const Event = struct {
    start: u32,
    end: u32,
    annot: Annotation,
    /// Only meaningful when `annot` is `.list_open` or `.list_item_open`:
    /// the candidate marker styles remaining after narrowing. djot.js calls
    /// this "ambiguous style" resolution — see `block.zig`'s `getListStyles`.
    list_styles: ListStyleCandidates = .{},
};

pub const EventList = std.ArrayList(Event);

/// A list item marker's possible interpretations. `getListStyles` in
/// `block.zig` produces these from marker text; at most two ever arise (a
/// lone `i.`/`I.` is ambiguous between roman numeral one and the first
/// letter of the alphabet — djot.js's `getListStyles` returns exactly those
/// two candidates in that order, roman first, so it wins if never narrowed).
pub const ListMarkerStyle = union(enum) {
    dash, // "-"
    plus, // "+"
    star, // "*"
    colon, // ":" (definition list)
    dash_task, // "- [ ]" / "- [x]"
    plus_task, // "+ [ ]" / "+ [x]"
    star_task, // "* [ ]" / "* [x]"
    ordered: struct { numbering: Numbering, delim: Delim },

    pub const Numbering = enum { decimal, lower_alpha, upper_alpha, lower_roman, upper_roman };
    /// Which punctuation wraps the number/letter: `1.`, `1)`, or `(1)`.
    pub const Delim = enum { period, paren_after, paren_both };

    pub fn eql(a: ListMarkerStyle, b: ListMarkerStyle) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .ordered => |av| av.numbering == b.ordered.numbering and av.delim == b.ordered.delim,
            else => true,
        };
    }

    pub fn isTask(self: ListMarkerStyle) bool {
        return switch (self) {
            .dash_task, .plus_task, .star_task => true,
            else => false,
        };
    }
};

/// At most two candidate styles for one marker (see `ListMarkerStyle` doc).
pub const ListStyleCandidates = struct {
    items: [2]ListMarkerStyle = undefined,
    len: u8 = 0,

    pub fn single(s: ListMarkerStyle) ListStyleCandidates {
        return .{ .items = .{ s, s }, .len = 1 };
    }

    pub fn two(a: ListMarkerStyle, b: ListMarkerStyle) ListStyleCandidates {
        return .{ .items = .{ a, b }, .len = 2 };
    }

    pub fn slice(self: *const ListStyleCandidates) []const ListMarkerStyle {
        return self.items[0..self.len];
    }

    pub fn isEmpty(self: ListStyleCandidates) bool {
        return self.len == 0;
    }

    pub fn contains(self: ListStyleCandidates, s: ListMarkerStyle) bool {
        for (self.slice()) |c| {
            if (c.eql(s)) return true;
        }
        return false;
    }

    /// Intersect two candidate sets (narrowing, per djot.js's continuation
    /// matching on a `list` container's `extra.styles`), preserving `self`'s
    /// order — so a still-ambiguous result keeps its original tie-break
    /// preference (roman before alpha).
    pub fn intersect(self: ListStyleCandidates, other: ListStyleCandidates) ListStyleCandidates {
        var result: ListStyleCandidates = .{};
        for (self.slice()) |c| {
            if (other.contains(c)) {
                result.items[result.len] = c;
                result.len += 1;
            }
        }
        return result;
    }
};

/// Every distinct event annotation the scanners emit and the parser
/// dispatches on. `_open`/`_close` pairs are djot.js's `"+x"`/`"-x"` strings;
/// everything else is a leaf (no matching close — its span alone carries the
/// meaning, sliced directly out of the source by whoever handles it).
///
/// Two annotations are deliberately asymmetric, mirroring djot.js exactly
/// rather than forcing a push/pop shape that doesn't fit: `.destination_open`
/// and `.reference_open` don't open a new container (the container was
/// already pushed by a preceding `.linktext_open`/`.imagetext_open` and is
/// still open) — they only toggle the parser's literal-text-accumulation
/// mode. Their `_close` counterparts are what actually finalize the node.
pub const Annotation = enum {
    // ── Containers ──────────────────────────────────────────────────────
    reference_definition_open,
    reference_definition_close,
    emph_open,
    emph_close,
    strong_open,
    strong_close,
    span_open,
    span_close,
    mark_open,
    mark_close,
    superscript_open,
    superscript_close,
    subscript_open,
    subscript_close,
    delete_open,
    delete_close,
    insert_open,
    insert_close,
    double_quoted_open,
    double_quoted_close,
    single_quoted_open,
    single_quoted_close,
    attributes_open,
    attributes_close,
    block_attributes_open,
    block_attributes_close,
    linktext_open,
    linktext_close,
    imagetext_open,
    imagetext_close,
    /// See the module doc comment: doesn't push a container.
    destination_open,
    destination_close,
    /// See the module doc comment: doesn't push a container.
    reference_open,
    reference_close,
    verbatim_open,
    verbatim_close,
    display_math_open,
    display_math_close,
    inline_math_open,
    inline_math_close,
    url_open,
    url_close,
    email_open,
    email_close,
    para_open,
    para_close,
    heading_open,
    heading_close,
    list_open,
    list_close,
    list_item_open,
    list_item_close,
    block_quote_open,
    block_quote_close,
    table_open,
    table_close,
    row_open,
    row_close,
    cell_open,
    cell_close,
    caption_open,
    caption_close,
    footnote_open,
    footnote_close,
    code_block_open,
    code_block_close,
    div_open,
    div_close,

    // ── Leaves ──────────────────────────────────────────────────────────
    str,
    soft_break,
    /// The backslash itself, immediately before an escaped char/newline/space.
    escape,
    hard_break,
    non_breaking_space,
    /// A `:name:` symbol shortcode (span covers the surrounding colons).
    symb,
    /// `[^label]` used inline (span covers the whole thing, incl. brackets).
    footnote_reference,
    reference_key,
    reference_value,
    checkbox_checked,
    checkbox_unchecked,
    note_label,
    code_language,
    raw_format,
    /// Reused for both a fenced div's `{.class}`-less bare class name and the
    /// attribute parser's `.class` token — same annotation, same meaning.
    class,
    thematic_break,
    left_single_quote,
    right_single_quote,
    left_double_quote,
    right_double_quote,
    ellipses,
    en_dash,
    em_dash,
    /// Recorded so `parser.zig` can determine tight/loose lists; carries no
    /// other meaning.
    blankline,
    separator_default,
    separator_left,
    separator_right,
    separator_center,
    /// The `!` before an image's `[`.
    image_marker,
    /// An explicit `{` open/close marker for a brace-delimited construct
    /// (insert/mark/delete). Consumed internally during inline scanning;
    /// `parser.zig` has no handler for it (a harmless no-op if seen).
    open_marker,

    // ── Attribute-parser leaves (attributes.zig) ───────────────────────
    attr_space,
    attr_id_marker,
    id,
    attr_class_marker,
    key,
    attr_equal_marker,
    attr_quote_marker,
    value,
    /// `%...%` comment inside an attribute block. No parser.zig handler —
    /// comments are discarded, same as upstream.
    comment,
};
