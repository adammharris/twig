//! Navigation helpers — the read-path surface of `AST` (the mirror of the
//! write path in `builder.zig`). Every public function here is re-exported as
//! an `AST` method from `ast.zig`, and — like `AST` itself — is language-
//! neutral: anything that encodes one language's node taxonomy (e.g. djot's
//! block/inline dichotomy, `Djot.isBlock`/`isInline`) belongs in that
//! language's module instead. Mirrors fig's `src/ast/reader.zig`, minus the
//! YAML-specific alias/merge-key resolution (no analogue here).

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

/// Error from index-path navigation (`getIdByPath`/`getNodeByPath`).
pub const PathError = error{
    /// A path segment asked for a child index the node doesn't have — either
    /// the node has fewer children than the index, or none at all (a leaf).
    PathOutOfBounds,
};

/// Navigate from the root to a node by a pure *index path*: `path[i]` selects
/// the `path[i]`-th child (0-based, source order) of the node reached so far.
/// An empty path returns the root. This is the document analogue of fig's
/// `getIdByPath`, but with only an index segment — documents have no keys to
/// address by (see `editor.zig`). The returned id is valid only against the
/// `AST` it was resolved from; after an edit + reparse, paths must be
/// recomputed against the new tree.
pub fn getIdByPath(self: *const AST, path: []const usize) PathError!Node.Id {
    var id = self.root;
    for (path) |idx| {
        var child = self.nodes[id].first_child orelse return error.PathOutOfBounds;
        var i: usize = 0;
        while (i < idx) : (i += 1) {
            child = self.nodes[child].next_sibling orelse return error.PathOutOfBounds;
        }
        id = child;
    }
    return id;
}

/// Like `getIdByPath`, but returns a pointer to the node itself.
pub fn getNodeByPath(self: *const AST, path: []const usize) PathError!*const Node {
    return &self.nodes[try getIdByPath(self, path)];
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
