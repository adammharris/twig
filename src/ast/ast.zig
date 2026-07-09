//! AST = Abstract Syntax Tree for a parsed document.
//!
//! This is Twig's SHARED node vocabulary: every language module
//! (`src/languages/djot/` today; XML/HTML next) parses into this one node
//! model, so structural operations and printers written against `AST` work
//! regardless of which format produced the tree. The kinds below form a
//! common semantic core (headings, emphasis, lists, tables, ...) plus a
//! small generic-markup escape hatch (`element`, `comment`, `doctype`, ...)
//! for constructs with no semantic mapping — languages map what they can to
//! semantic kinds (`<em>` → `emph`) and fall back to `element` for the rest,
//! which is what keeps this vocabulary closed. Djot's tag-by-tag mapping
//! (mirroring djot.js's `src/ast.ts`) is one language's mapping, not this
//! file's definition; anything djot-specific (the reference/footnote
//! side-tables, the block/inline dichotomy) lives in the djot module.
//!
//! Structurally this is the document-format counterpart to fig's config-tree
//! `AST` https://github.com/adammharris/fig/blob/main/src/ast/ast.zig`
//! and follows the same conventions:
//! an index-based arena (`Node.Id = u32`, a flat `[]Node`),
//! containers link their children via `first_child`/`next_sibling`
//! rather than owning a `[]Node.Id` slice per node, and the AST is fully self-contained —
//! every string a node carries is copied into `owned_strings` at build time,
//! so a finished `AST` never borrows the original source text and printers can take `*const AST` alone.
//!
//! Node *shape* is much more heterogeneous here than in fig's config AST
//! (~50 kinds vs. ~8), so unlike fig — which folds a container's child
//! pointer directly into its `Kind` union payload (`sequence: ?Id`) — every
//! `Node` carries its own `first_child`/`next_sibling` fields uniformly,
//! regardless of kind. `Kind` then only needs to carry each kind's *extra*
//! data (a heading's level, a code block's language/text, ...); kinds with no
//! extra data beyond their children (e.g. `emph`, `block_quote`) are `void`
//! payloads, following fig's `null_,` shorthand.

const AST = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Span = @import("../span.zig");

const reader = @import("reader.zig");
pub const Builder = @import("builder.zig");

pub const children = reader.children;
pub const ChildIterator = reader.ChildIterator;
pub const attrsOf = reader.attrsOf;
pub const getIdByPath = reader.getIdByPath;
pub const getNodeByPath = reader.getNodeByPath;
pub const PathError = reader.PathError;

allocator: Allocator,
owned_strings: []const []const u8 = &.{},

/// The single `doc` node all content hangs off of.
root: Node.Id,

/// Complete node arena, such that `ast.nodes[id] == node` for every id handed
/// out during the build.
nodes: []const Node,

/// Indexed by `Node.attrs` (when non-null): the classes/id/keyvals attached
/// to that node. A side-table (like fig's `node_tags`/`node_comments`)
/// because most nodes carry no attributes at all.
attrs: []const Attrs = &.{},

pub fn deinit(self: *AST) void {
    for (self.owned_strings) |s| self.allocator.free(s);
    self.allocator.free(self.owned_strings);
    self.allocator.free(self.nodes);
    for (self.attrs) |a| {
        self.allocator.free(a.entries);
    }
    self.allocator.free(self.attrs);
}

pub const Node = struct {
    id: Id,
    kind: Kind,
    first_child: ?Id = null,
    next_sibling: ?Id = null,
    /// Byte range `[start, end)` into the source this node was parsed from.
    span: Span = Span.init(0, 0),
    /// For container nodes: the byte range of the node's *interior* — the
    /// region between its opening and closing delimiters where its children
    /// live, and where an editor may splice new children (for
    /// `<div class=x>abc</div>`, the span of `abc`; for a djot `::: div`,
    /// the lines between the fences). `null` = unknown or not meaningful
    /// (leaves; synthesized nodes). Parsers should populate it when it is
    /// cheap to compute; a parser that leaves it `null` is still correct,
    /// just less useful to editors.
    content_span: ?Span = null,
    /// Index into `AST.attrs`, or `null` if this node has no `{...}`
    /// attributes attached.
    attrs: ?u32 = null,

    pub const Id = u32;

    /// The shared kind vocabulary: a semantic core (one kind per djot.js
    /// `ast.ts` tag) plus generic-markup kinds for what XML/HTML can't map
    /// semantically. Container kinds (whose payload is `void` below) still
    /// get children like any other node, via the uniform
    /// `first_child`/`next_sibling` fields on `Node` itself — see this
    /// file's module doc comment for why that's a `Node`-level field rather
    /// than folded into each variant here (as fig does for its much smaller,
    /// config-oriented `Kind`).
    pub const Kind = union(enum) {
        // ── Document root ───────────────────────────────────────────────
        doc,

        // ── Blocks ──────────────────────────────────────────────────────
        para,
        heading: struct { level: u32 },
        thematic_break,
        /// A heading-implied nesting wrapper; never appears in raw djot
        /// syntax, only synthesized by the parser (see djot.js's `parse.ts`
        /// section handling).
        section,
        div,
        code_block: struct { lang: ?[]const u8, text: []const u8 },
        raw_block: struct { format: []const u8, text: []const u8 },
        block_quote,
        bullet_list: struct { style: BulletListStyle, tight: bool },
        ordered_list: struct { style: OrderedListStyle, tight: bool, start: ?u32 },
        task_list: struct { tight: bool },
        definition_list,
        /// Children: `[Caption, Row, Row, ...]` — the first child is always
        /// a `caption` (possibly an empty one), matching djot.js's tuple type.
        table,

        // ── Container children of the above ──────────────────────────────
        list_item,
        task_list_item: struct { checked: bool },
        definition_list_item,
        term,
        definition,
        row: struct { head: bool },
        cell: struct { head: bool, alignment: Alignment },
        caption,
        footnote: struct { label: []const u8 },
        reference: struct { label: []const u8, destination: []const u8 },

        // ── Inlines ───────────────────────────────────────────────────────
        str: []const u8,
        soft_break,
        hard_break,
        non_breaking_space,
        /// A `:name:` symbol/emoji shortcode; payload is the name, no
        /// leading/trailing `:`.
        symb: []const u8,
        verbatim: []const u8,
        raw_inline: struct { format: []const u8, text: []const u8 },
        inline_math: []const u8,
        display_math: []const u8,
        url: []const u8,
        email: []const u8,
        /// `[^label]` used inline; payload is the label (no `^`/brackets).
        footnote_reference: []const u8,
        smart_punctuation: struct { kind: SmartPunctuationKind, text: []const u8 },
        emph,
        strong,
        link: struct { destination: ?[]const u8, reference: ?[]const u8 },
        image: struct { destination: ?[]const u8, reference: ?[]const u8 },
        span,
        mark,
        superscript,
        subscript,
        insert,
        delete,
        double_quoted,
        single_quoted,

        // ── Generic markup ────────────────────────────────────────────────
        /// A named element with no semantic mapping (HTML `<video>`,
        /// arbitrary XML) — the escape hatch that keeps this vocabulary
        /// closed: languages map what they can to semantic kinds (`<em>` →
        /// `emph`) and fall back to `element` for the rest. Children are
        /// parsed nodes like any container; attributes go in the normal
        /// `attrs` side-table. `name` is stored as written, including any
        /// namespace prefix (`svg:rect`) — prefix resolution is a
        /// reader-side helper, later.
        element: struct { name: []const u8 },
        /// HTML/XML `<!-- ... -->`; payload is the text between the
        /// delimiters, as written.
        comment: []const u8,
        /// Payload is everything between `<!DOCTYPE` and `>`, as written
        /// (e.g. `html`, or a full XML public/system id soup). Not parsed
        /// further.
        doctype: []const u8,
        /// XML `<?target data?>`.
        processing_instruction: struct { target: []const u8, data: []const u8 },
        /// XML `<![CDATA[...]]>`; payload is the raw contents. (Plain text
        /// nodes are `str`; `cdata` exists separately so the distinction
        /// round-trips.)
        cdata: []const u8,
    };
};

/// A single attribute pair (`AttributeParser`'s `keyval`). A `null` value
/// means a *bare* attribute — HTML `disabled`, which must round-trip
/// distinctly from `disabled=""`. Djot attribute syntax has no way to write
/// a bare attribute, so djot parses always produce non-null values.
pub const KeyVal = struct { key: []const u8, value: ?[]const u8 };

/// The parsed contents of a `{.class #id key="val"}` attribute block, as
/// attached to a `Node` via `Node.attrs`. See djot.js's `attributes.ts`.
///
/// Deliberately a single ORDER-PRESERVING list rather than separate
/// `classes`/`id`/`keyvals` fields: djot.js stores attributes as one plain
/// object whose iteration order is insertion order, and renders them back in
/// that same order — `{key1=val1 .foo key2=val2}` renders
/// `key1="val1" class="foo" key2="val2"`, interleaved exactly as written,
/// not grouped by kind. `class` and `id` are therefore just ordinary keys
/// here (`class`'s value accumulates multiple `.foo .bar` occurrences
/// space-joined, at the position of its FIRST occurrence — matching
/// djot.js's "mutate the existing object property" behavior). Use `get` for
/// lookups; there is no dedicated `id`/`class` accessor because callers that
/// care about rendering need the entries in order anyway.
pub const Attrs = struct {
    entries: []const KeyVal = &.{},

    pub fn isEmpty(self: Attrs) bool {
        return self.entries.len == 0;
    }

    /// Look up an attribute's whole entry by key — the presence test that
    /// distinguishes "key absent" (`null` here) from "key present but bare"
    /// (an entry whose `value` is `null`, e.g. HTML `disabled`).
    pub fn find(self: Attrs, key: []const u8) ?KeyVal {
        for (self.entries) |kv| {
            if (std.mem.eql(u8, kv.key, key)) return kv;
        }
        return null;
    }

    /// Look up an attribute's value by key (e.g. `"id"`, `"class"`). Both
    /// an absent key and a bare (valueless) attribute yield `null` — use
    /// `find` when that distinction matters.
    pub fn get(self: Attrs, key: []const u8) ?[]const u8 {
        const kv = self.find(key) orelse return null;
        return kv.value;
    }
};

pub const BulletListStyle = enum { dash, plus, star };

pub const OrderedListStyle = struct {
    numbering: Numbering,
    delim: Delim,

    pub const Numbering = enum { decimal, lower_alpha, upper_alpha, lower_roman, upper_roman };
    /// Which punctuation wraps the number: `1.`, `1)`, or `(1)`.
    pub const Delim = enum { period, paren_after, paren_both };
};

pub const Alignment = enum { default, left, right, center };

pub const SmartPunctuationKind = enum {
    left_single_quote,
    right_single_quote,
    left_double_quote,
    right_double_quote,
    ellipses,
    em_dash,
    en_dash,
};

test {
    _ = Builder;
    _ = reader;
}

test "Attrs.find distinguishes a bare attribute from an absent key" {
    const testing = std.testing;
    const attrs: Attrs = .{ .entries = &.{
        .{ .key = "disabled", .value = null },
        .{ .key = "id", .value = "x" },
    } };

    // Bare attribute: present per `find`, but `get` can't tell it apart
    // from an absent key.
    const bare = attrs.find("disabled") orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("disabled", bare.key);
    try testing.expectEqual(@as(?[]const u8, null), bare.value);
    try testing.expectEqual(@as(?[]const u8, null), attrs.get("disabled"));

    // Valued attribute: both accessors agree.
    try testing.expectEqualStrings("x", attrs.find("id").?.value.?);
    try testing.expectEqualStrings("x", attrs.get("id").?);

    // Absent key: `find` is the only way to see the difference.
    try testing.expectEqual(@as(?KeyVal, null), attrs.find("missing"));
    try testing.expectEqual(@as(?[]const u8, null), attrs.get("missing"));
}
