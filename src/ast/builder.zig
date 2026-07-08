//! Builder — bottom-up, allocation-owning construction of an `AST`. Mirrors
//! fig's `src/ast/builder.zig`: this file IS the `Builder` type (re-exported
//! as `AST.Builder`), ids are array indices, siblings link via
//! `next_sibling`, and every string handed to the builder is *copied* into
//! `owned_strings` so a finished `AST` never borrows the caller's buffers.
//!
//! This is the *simple*, batch-children API (give it a kind and an already-
//! built slice of child ids). A source-driven parser typically needs a more
//! incremental, container-stack style of construction instead (open a node
//! before its children exist, attach them one at a time, possibly rewrite
//! its `Kind` once more is known at close time — e.g. a list's `tight` flag).
//! Rather than generalize this API to cover that (and risk making the common
//! case awkward), `languages/djot/parser.zig` manages its own flat node
//! arrays directly during the build and only produces `AST` values at the
//! boundary — the same division of labor fig's `languages/json/parser.zig`
//! uses relative to this file.

const Builder = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

const AST = @import("ast.zig");
const Node = AST.Node;
const Span = @import("../span.zig");

allocator: Allocator,
nodes: std.ArrayList(Node) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,
attrs: std.ArrayList(AST.Attrs) = .empty,

pub fn init(allocator: Allocator) Builder {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Builder) void {
    for (self.owned_strings.items) |s| self.allocator.free(s);
    self.owned_strings.deinit(self.allocator);
    self.nodes.deinit(self.allocator);
    for (self.attrs.items) |a| {
        self.allocator.free(a.entries);
    }
    self.attrs.deinit(self.allocator);
}

/// Add a node with no children (yet) and the given kind, copying any string
/// payload the kind carries into owned storage. Pair with `setChildren` (via
/// `addContainer`, or directly) to give it children afterward.
pub fn addNode(self: *Builder, kind: Node.Kind) Allocator.Error!Node.Id {
    const id: Node.Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{
        .id = id,
        .kind = try self.dupeKind(kind),
    });
    return id;
}

/// Add a childless node. An alias for `addNode` — use whichever name reads
/// better at the call site.
pub fn addLeaf(self: *Builder, kind: Node.Kind) Allocator.Error!Node.Id {
    return self.addNode(kind);
}

/// Add a node with the given kind and children (already-built ids, in
/// order). Empty `ids` is fine, yielding a node with no children.
pub fn addContainer(self: *Builder, kind: Node.Kind, ids: []const Node.Id) Allocator.Error!Node.Id {
    const id = try self.addNode(kind);
    self.setChildren(id, ids);
    return id;
}

/// Chain `ids` as `parent`'s children (`parent.first_child = ids[0]`, each
/// linked to the next via `next_sibling`). The ids must already be in
/// `nodes`. Replaces any children `parent` had before.
pub fn setChildren(self: *Builder, parent: Node.Id, ids: []const Node.Id) void {
    self.nodes.items[parent].first_child = if (ids.len == 0) null else ids[0];
    if (ids.len == 0) return;
    for (ids[0 .. ids.len - 1], ids[1..]) |cur, nxt| {
        self.nodes.items[cur].next_sibling = nxt;
    }
    self.nodes.items[ids[ids.len - 1]].next_sibling = null;
}

pub fn setSpan(self: *Builder, id: Node.Id, span: Span) void {
    self.nodes.items[id].span = span;
}

/// Attach `attrs` to `id` (copying its strings into owned storage),
/// replacing any attributes previously set. Passing an empty `Attrs` clears
/// the attachment (`node.attrs` goes back to `null`) without growing the
/// side-table.
pub fn setAttrs(self: *Builder, id: Node.Id, attrs: AST.Attrs) Allocator.Error!void {
    if (attrs.isEmpty()) {
        self.nodes.items[id].attrs = null;
        return;
    }
    const entries = try self.allocator.alloc(AST.KeyVal, attrs.entries.len);
    errdefer self.allocator.free(entries);
    for (attrs.entries, entries) |src, *dst| {
        dst.* = .{ .key = try self.dupe(src.key), .value = try self.dupe(src.value) };
    }

    const idx: u32 = @intCast(self.attrs.items.len);
    try self.attrs.append(self.allocator, .{ .entries = entries });
    self.nodes.items[id].attrs = idx;
}

/// Freeze the builder into an owned `AST` rooted at `root`. The builder is
/// left empty, so a subsequent `deinit` is harmless.
pub fn finish(self: *Builder, root: Node.Id) Allocator.Error!AST {
    const nodes = try self.nodes.toOwnedSlice(self.allocator);
    self.nodes = .empty;
    const owned_strings = try self.owned_strings.toOwnedSlice(self.allocator);
    self.owned_strings = .empty;
    const attrs = try self.attrs.toOwnedSlice(self.allocator);
    self.attrs = .empty;
    return .{
        .allocator = self.allocator,
        .owned_strings = owned_strings,
        .root = root,
        .nodes = nodes,
        .attrs = attrs,
    };
}

// ── internals ────────────────────────────────────────────────────────────

/// Take ownership of an already-allocated string. Freed, not leaked, if
/// registration fails.
fn own(self: *Builder, owned: []const u8) Allocator.Error![]const u8 {
    errdefer self.allocator.free(owned);
    try self.owned_strings.append(self.allocator, owned);
    return owned;
}

fn dupe(self: *Builder, s: []const u8) Allocator.Error![]const u8 {
    return self.own(try self.allocator.dupe(u8, s));
}

/// Copy every string payload a `Kind` carries into owned storage, returning
/// the equivalent `Kind` pointing at the copies. Kinds with no string
/// payload (most container kinds) pass through unchanged. This is the single
/// place that needs a new arm whenever `Kind` grows a string-bearing variant.
fn dupeKind(self: *Builder, kind: Node.Kind) Allocator.Error!Node.Kind {
    return switch (kind) {
        .code_block => |v| .{ .code_block = .{
            .lang = if (v.lang) |l| try self.dupe(l) else null,
            .text = try self.dupe(v.text),
        } },
        .raw_block => |v| .{ .raw_block = .{ .format = try self.dupe(v.format), .text = try self.dupe(v.text) } },
        .footnote => |v| .{ .footnote = .{ .label = try self.dupe(v.label) } },
        .reference => |v| .{ .reference = .{ .label = try self.dupe(v.label), .destination = try self.dupe(v.destination) } },
        .str => |v| .{ .str = try self.dupe(v) },
        .symb => |v| .{ .symb = try self.dupe(v) },
        .verbatim => |v| .{ .verbatim = try self.dupe(v) },
        .raw_inline => |v| .{ .raw_inline = .{ .format = try self.dupe(v.format), .text = try self.dupe(v.text) } },
        .inline_math => |v| .{ .inline_math = try self.dupe(v) },
        .display_math => |v| .{ .display_math = try self.dupe(v) },
        .url => |v| .{ .url = try self.dupe(v) },
        .email => |v| .{ .email = try self.dupe(v) },
        .footnote_reference => |v| .{ .footnote_reference = try self.dupe(v) },
        .smart_punctuation => |v| .{ .smart_punctuation = .{ .kind = v.kind, .text = try self.dupe(v.text) } },
        .link => |v| .{ .link = .{
            .destination = if (v.destination) |d| try self.dupe(d) else null,
            .reference = if (v.reference) |r| try self.dupe(r) else null,
        } },
        .image => |v| .{ .image = .{
            .destination = if (v.destination) |d| try self.dupe(d) else null,
            .reference = if (v.reference) |r| try self.dupe(r) else null,
        } },
        else => kind,
    };
}

test "Builder constructs a small tree bottom-up" {
    const testing = std.testing;
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    const s1 = try b.addLeaf(.{ .str = "hello " });
    const em_text = try b.addLeaf(.{ .str = "world" });
    const em = try b.addContainer(.emph, &.{em_text});
    const para = try b.addContainer(.para, &.{ s1, em });

    var ast = try b.finish(para);
    defer ast.deinit();

    try testing.expectEqual(para, ast.root);
    try testing.expectEqualStrings("hello ", ast.nodes[s1].kind.str);
    try testing.expect(ast.nodes[para].kind == .para);
    try testing.expectEqual(@as(?Node.Id, em), ast.nodes[s1].next_sibling);
}

test "setAttrs copies attribute strings into owned storage" {
    const testing = std.testing;
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    var class_buf = [_]u8{ 'w', 'a', 'r', 'n' };
    const id = try b.addLeaf(.{ .str = "x" });
    try b.setAttrs(id, .{ .entries = &.{ .{ .key = "class", .value = class_buf[0..] }, .{ .key = "id", .value = "y" } } });
    class_buf[0] = 'Z'; // mutate the source buffer; the copy must be unaffected

    var ast = try b.finish(id);
    defer ast.deinit();

    const attrs = ast.attrsOf(id);
    try testing.expectEqualStrings("warn", attrs.get("class").?);
    try testing.expectEqualStrings("y", attrs.get("id").?);
}
