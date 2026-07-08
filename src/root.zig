//! By convention, root.zig is the root source file when making a package.
//!
//! Twig parses document formats (Djot first) into a shared, index-based
//! `AST` — the document-format counterpart to fig's config-tree `AST` — so
//! that precise structural operations can be performed on a document,
//! rather than just converting between formats. See `twig.md` for the
//! project's goals and `AST`'s module doc comment for the node model.

/// The shared document AST every format parses into. See its module doc
/// comment for the node/kind model and the ownership discipline (every
/// string a node carries is copied, so a finished `AST` never borrows the
/// original source and is safe to hold onto after parsing).
pub const AST = @import("ast/ast.zig");

/// Djot support: `Djot.parse(allocator, source) !Djot.Document` (the shared
/// `AST` plus djot's reference/footnote side tables) plus `Djot.html` for
/// rendering. See `languages/djot/djot.zig`'s module doc comment.
pub const Djot = @import("languages/djot/djot.zig");

/// XML support: `Xml.parse(allocator, source) !AST` (well-formed XML 1.0, no
/// external DTD processing) plus `Xml.serialize`/`Xml.serializeAlloc` for
/// rendering back to text. Unlike `Djot`, XML needs no side-table wrapper —
/// `parse` returns the shared `AST` directly. See `languages/xml/xml.zig`'s
/// module doc comment.
pub const Xml = @import("languages/xml/xml.zig");

test {
    _ = AST;
    _ = Djot;
    _ = Xml;
}
