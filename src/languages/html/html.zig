//! HTML: the entry point for this language module, mirroring
//! `languages/xml/xml.zig`'s role for XML. It provides a forgiving HTML
//! parser (`parser.zig`) and a generic `AST` -> HTML text renderer
//! (`serializer.zig`). The parser feeds generic markup (`element`/`comment`/
//! `doctype`/...) into the shared AST; the serializer also covers the full
//! semantic vocabulary, proving it can reproduce `languages/djot/html.zig`'s
//! output exactly (see `conformance.zig`).
//!
//! Aggregates every sibling file's `test {}` blocks (the fig/djot/xml
//! convention).

const std = @import("std");

pub const AST = @import("../../ast/ast.zig");

const serializer_mod = @import("serializer.zig");
const parser_mod = @import("parser.zig");

pub const RenderOptions = serializer_mod.RenderOptions;
pub const Context = serializer_mod.Context;
pub const KV = serializer_mod.KV;
pub const RenderError = serializer_mod.RenderError;
pub const Renderer = serializer_mod.Renderer;
pub const Parser = parser_mod.Parser;
pub const ParseError = parser_mod.ParseError;

pub const serialize = serializer_mod.serialize;
pub const serializeNode = serializer_mod.serializeNode;
pub const serializeAlloc = serializer_mod.serializeAlloc;

/// Parse forgiving HTML into the shared generic-markup AST.  This is a
/// document-oriented parser rather than a browser DOM implementation: it
/// recognizes normal HTML token forms and common optional end tags, while
/// preserving unknown markup in the generic AST vocabulary.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!AST {
    var parser = Parser.init(allocator, source);
    defer parser.deinit();
    return parser.parse();
}

test {
    _ = serializer_mod;
    _ = parser_mod;
    _ = @import("conformance.zig");
}
