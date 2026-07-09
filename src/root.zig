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

/// HTML support: `Html.serialize`/`Html.serializeAlloc`, a generic `AST` ->
/// HTML printer covering the full shared kind vocabulary (djot's semantic
/// kinds plus XML/HTML's generic-markup kinds). Takes an optional
/// `Html.Context` to resolve djot-style reference/footnote side tables
/// without this module depending on `Djot`. No `parse` yet — see
/// `languages/html/html.zig`'s module doc comment.
pub const Html = @import("languages/html/html.zig");

/// Markdown support: `Markdown.parse(allocator, source, options) !Markdown.Document`
/// (the shared `AST` plus Markdown's link-reference-definition side table)
/// plus `Markdown.ParseOptions` for the (currently Phase-1-only) feature
/// flags. Rendering reuses `Html`, the same shared printer XML/djot prove
/// against. See `languages/markdown/markdown.zig`'s module doc comment for
/// the Phase 1/2/3 scope split.
pub const Markdown = @import("languages/markdown/markdown.zig");

test {
    _ = AST;
    _ = Djot;
    _ = Xml;
    _ = Html;
    _ = Markdown;
}
