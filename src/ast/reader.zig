//! Navigation helpers — the read-path surface of `AST` (the mirror of the
//! write path in `builder.zig`). Every public function here is re-exported as
//! an `AST` method from `ast.zig`. Mirrors fig's `src/ast/reader.zig`, minus
//! the YAML-specific alias/merge-key resolution (not applicable to Djot).

const std = @import("std");
const AST = @import("ast.zig");
const Node = AST.Node;

/// Iterate a node's children in source order via `first_child`/`next_sibling`.
pub const ChildIterator = struct {
    ast: *const AST,
    next_id: ?Node.Id,

    pub fn next(self: *ChildIterator) ?*const Node {
        const id = self.next_id orelse return null;
        const node = &self.ast.nodes[id];
        self.next_id = node.next_sibling;
        return node;
    }
};

/// Iterate `id`'s children in source order. Works uniformly for every kind
/// (leaves simply yield an iterator that returns `null` immediately) since
/// `first_child`/`next_sibling` are plain `Node` fields, not folded into the
/// `Kind` payload — see `ast.zig`'s module doc comment.
pub fn children(self: *const AST, id: Node.Id) ChildIterator {
    return .{ .ast = self, .next_id = self.nodes[id].first_child };
}

/// The `Attrs` attached to `id`, or the empty value if it has none.
pub fn attrsOf(self: *const AST, id: Node.Id) AST.Attrs {
    const idx = self.nodes[id].attrs orelse return .{};
    return self.attrs[idx];
}

const block_tags = std.EnumSet(std.meta.Tag(AST.Node.Kind)).initMany(&.{
    .para,       .heading,         .thematic_break, .section,     .div,
    .code_block, .raw_block,       .block_quote,    .bullet_list, .ordered_list,
    .task_list,  .definition_list, .table,          .reference,   .footnote,
});

const inline_tags = std.EnumSet(std.meta.Tag(AST.Node.Kind)).initMany(&.{
    .str,       .soft_break,         .hard_break,         .non_breaking_space, .symb,
    .verbatim,  .raw_inline,         .inline_math,        .display_math,       .url,
    .email,     .footnote_reference, .smart_punctuation,  .emph,               .strong,
    .link,      .image,              .span,               .mark,               .superscript,
    .subscript, .insert,             .delete,             .double_quoted,      .single_quoted,
});

/// Mirrors djot.js `ast.ts`'s `isBlock`.
pub fn isBlock(kind: AST.Node.Kind) bool {
    return block_tags.contains(std.meta.activeTag(kind));
}

/// Mirrors djot.js `ast.ts`'s `isInline`.
pub fn isInline(kind: AST.Node.Kind) bool {
    return inline_tags.contains(std.meta.activeTag(kind));
}

test "children walks first_child/next_sibling in order" {
    const testing = std.testing;
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();

    const a = try b.addLeaf(.{ .str = "a" });
    const c = try b.addLeaf(.{ .str = "b" });
    const para = try b.addContainer(.para, &.{ a, c });

    var ast = try b.finish(para);
    defer ast.deinit();

    var it = ast.children(para);
    const first = it.next() orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("a", first.kind.str);
    const second = it.next() orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("b", second.kind.str);
    try testing.expectEqual(@as(?*const AST.Node, null), it.next());
}

test "isBlock/isInline classify kinds" {
    try std.testing.expect(isBlock(.{ .heading = .{ .level = 1 } }));
    try std.testing.expect(!isInline(.{ .heading = .{ .level = 1 } }));
    try std.testing.expect(isInline(.{ .str = "x" }));
    try std.testing.expect(!isBlock(.{ .str = "x" }));
}
