//! Djot: the entry point for this language module. Wires the block scanner,
//! inline scanner, and event-stream-to-AST builder together into one
//! `parse` call, and aggregates every sibling file's `test {}` blocks (the
//! fig convention — see `~/Documents/fig/src/languages/json/json.zig`).
//!
//! Block/inline scanning is naturally two cooperating files rather than
//! fig's usual single `tokenizer.zig`, since Djot's block and inline levels
//! are mutually interleaved (each paragraph/heading gets its own inline scan
//! as the block scanner reaches its content) — see `event.zig`'s doc
//! comment for the full picture of how the pieces fit together.

const std = @import("std");
const Allocator = std.mem.Allocator;

const block = @import("block.zig");
const parser = @import("parser.zig");

pub const AST = @import("../../ast/ast.zig");
pub const html = @import("html.zig");

/// Parse `source` (Djot markup) into an `AST`. The returned AST is fully
/// self-contained (owns copies of every string it needs) and must be freed
/// with `ast.deinit()`.
pub fn parse(allocator: Allocator, source: []const u8) Allocator.Error!AST {
    var block_parser = try block.Parser.init(allocator, source);
    defer block_parser.deinit();
    const events = try block_parser.scan();
    defer allocator.free(events);

    var tree_builder = parser.TreeBuilder.init(allocator, block_parser.subject);
    return tree_builder.build(events);
}

test {
    _ = @import("event.zig");
    _ = @import("attributes.zig");
    _ = @import("block.zig");
    _ = @import("inline.zig");
    _ = @import("parser.zig");
    _ = @import("html.zig");
    _ = @import("conformance.zig");
}

const testing = std.testing;

test "parse produces a doc with a paragraph" {
    var ast = try parse(testing.allocator, "hello *world*\n");
    defer ast.deinit();

    try testing.expect(ast.nodes[ast.root].kind == .doc);
    const para_id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[para_id].kind == .para);
    const str_id = ast.nodes[para_id].first_child orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("hello ", ast.nodes[str_id].kind.str);
    const strong_id = ast.nodes[str_id].next_sibling orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[strong_id].kind == .strong);
}

test "heading gets an auto id and wraps a section" {
    var ast = try parse(testing.allocator, "# Hello World\n\npara\n");
    defer ast.deinit();

    const section_id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[section_id].kind == .section);
    const attrs = ast.attrsOf(section_id);
    try testing.expectEqualStrings("Hello-World", attrs.get("id").?);

    const heading_id = ast.nodes[section_id].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[heading_id].kind.heading.level == 1);
}

test "reference link resolves via the references map" {
    var ast = try parse(testing.allocator,
        \\[foo][bar]
        \\
        \\[bar]: http://example.com
        \\
    );
    defer ast.deinit();
    try testing.expect(ast.references.contains("bar"));
}

test "bullet list is tight, definition list restructures term/definition" {
    var ast = try parse(testing.allocator, "- a\n- b\n");
    defer ast.deinit();
    const list_id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[list_id].kind.bullet_list.tight);

    var ast2 = try parse(testing.allocator, "orange\n\n: a citrus fruit\n");
    defer ast2.deinit();
}
