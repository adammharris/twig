//! HTML: the entry point for this language module, mirroring
//! `languages/xml/xml.zig`'s role for XML. Unlike XML (a parser + a
//! serializer for the SAME format), this module today is PRINTER-only: a
//! generic `AST` -> HTML text renderer (`serializer.zig`) with no matching
//! `parse` yet. It exists to prove that one shared printer can reproduce
//! `languages/djot/html.zig`'s output exactly (see `conformance.zig`), as
//! the first step toward that bespoke djot renderer being retired in favor
//! of this one. An HTML *parser* — the natural next addition, feeding
//! `element`/`comment`/`doctype`/... nodes into the same `AST` XML's parser
//! already knows how to produce — is out of scope here.
//!
//! Aggregates every sibling file's `test {}` blocks (the fig/djot/xml
//! convention).

const std = @import("std");

pub const AST = @import("../../ast/ast.zig");

const serializer_mod = @import("serializer.zig");

pub const RenderOptions = serializer_mod.RenderOptions;
pub const Context = serializer_mod.Context;
pub const KV = serializer_mod.KV;
pub const RenderError = serializer_mod.RenderError;
pub const Renderer = serializer_mod.Renderer;

pub const serialize = serializer_mod.serialize;
pub const serializeNode = serializer_mod.serializeNode;
pub const serializeAlloc = serializer_mod.serializeAlloc;

test {
    _ = serializer_mod;
    _ = @import("conformance.zig");
}
