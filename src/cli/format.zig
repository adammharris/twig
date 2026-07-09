//! The format registry: the single place a new Twig language plugs into the
//! CLI. Each `FormatEntry` bundles a parser adapter (`parse`), an HTML
//! renderer adapter (`renderHtml`), and an optional round-trip serializer
//! (`serializeCanonical`) behind one uniform shape (`ParsedDoc`), so `convert`
//! and `identify` never need format-specific branches of their own — adding a
//! language is "write three small adapter functions, add one `registry`
//! entry", not touching `args.zig`/`actions.zig` at all.
//!
//! This module also owns extension inference and `-i`/`--input` name
//! resolution (`detectFromExtension`, `parseFormatName`), and the
//! "unsupported/undetectable format" diagnostics `args.zig` prints on
//! failure — mirroring fig's `cli/args.zig` (`detectLanguageFromFileEnding`,
//! `parseFormatName`) and `cli/types.zig` (`Format`) at Twig's smaller scale.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const twig = @import("twig");

/// Every language Twig can PARSE. This is the `-i`/`--input` vocabulary and
/// the enum `ParsedDoc` is tagged by — see `registry` below for what each
/// variant does.
pub const InputFormat = enum {
    djot,
    markdown,
    xml,
    // `html` is deliberately not a variant yet: Twig has an HTML *printer*
    // (`twig.Html`) but no HTML *parser* to feed a `registry` entry's
    // `parse` — see `languages/html/html.zig`'s module doc comment. Add the
    // variant, a `registry` entry wrapping the future `twig.Html.parse`, and
    // an `.html`/`.htm` extension mapping once that lands; nothing else in
    // this file or `args.zig`/`actions.zig` needs to change.
};

/// What `-o`/`--output` selects: not a source language like `InputFormat`,
/// but one of the three ways `convert` can render a parsed document. `html`
/// is the default; `ast` and `canonical` are documented on `registry`'s
/// module doc comment above and on `actions.zig`'s `runConvert`.
pub const OutputMode = enum { html, ast, canonical };

pub fn parseOutputMode(name: []const u8) ?OutputMode {
    return std.meta.stringToEnum(OutputMode, name);
}

/// A parsed document, tagged by which `InputFormat` produced it. Exists
/// because `Djot.parse`/`Markdown.parse` return a `Document` wrapper (the
/// shared `AST` plus side tables — see `Djot.Document`'s doc comment) while
/// `Xml.parse` returns the shared `AST` directly; this union gives
/// `actions.zig` one type to hold, deinit, and pull an `*const AST` out of,
/// regardless of which language produced it.
pub const ParsedDoc = union(InputFormat) {
    djot: twig.Djot.Document,
    markdown: twig.Markdown.Document,
    xml: twig.AST,

    /// The shared `AST` underneath, regardless of variant.
    pub fn ast(self: *const ParsedDoc) *const twig.AST {
        return switch (self.*) {
            .djot => |*d| &d.ast,
            .markdown => |*d| &d.ast,
            .xml => |*a| a,
        };
    }

    pub fn deinit(self: *ParsedDoc) void {
        switch (self.*) {
            .djot => |*d| d.deinit(),
            .markdown => |*d| d.deinit(),
            .xml => |*a| a.deinit(),
        }
    }
};

fn parseDjot(allocator: Allocator, source: []const u8) anyerror!ParsedDoc {
    return .{ .djot = try twig.Djot.parse(allocator, source) };
}

fn parseMarkdown(allocator: Allocator, source: []const u8) anyerror!ParsedDoc {
    return .{ .markdown = try twig.Markdown.parse(allocator, source, .{}) };
}

fn parseXml(allocator: Allocator, source: []const u8) anyerror!ParsedDoc {
    return .{ .xml = try twig.Xml.parse(allocator, source) };
}

// ── editor reparse adapters ────────────────────────────────────────────────
// The span-splice editor (`twig.Editor`) reparses after every edit and only
// needs the bare shared `AST` — spans/structure, never a `Document`'s side
// tables. These unwrap djot/Markdown's `Document`: its side-table map KEYS are
// slices into `ast.owned_strings` and the maps own no AST memory (see each
// `Document`'s doc comment), so freeing just the map *structures* and handing
// back `.ast` is leak-free and leaves a fully valid tree. XML already returns a
// bare `AST`.

fn parseToAstDjot(allocator: Allocator, source: []const u8) anyerror!twig.AST {
    var doc = try twig.Djot.parse(allocator, source);
    doc.references.deinit(allocator);
    doc.auto_references.deinit(allocator);
    doc.footnotes.deinit(allocator);
    return doc.ast;
}

fn parseToAstMarkdown(allocator: Allocator, source: []const u8) anyerror!twig.AST {
    var doc = try twig.Markdown.parse(allocator, source, .{});
    doc.link_references.deinit(allocator);
    doc.footnotes.deinit(allocator);
    return doc.ast;
}

fn parseToAstXml(allocator: Allocator, source: []const u8) anyerror!twig.AST {
    return twig.Xml.parse(allocator, source);
}

/// Djot needs its own HTML rendering path (`Djot.html.render`) rather than
/// the generic printer: it resolves reference/footnote labels against
/// `Document`'s side tables at render time (see `djot/html.zig`'s module doc
/// comment) — the generic `Html.serialize` has no djot `Document` to pull
/// those tables from. Using the generic printer here would silently drop
/// footnotes and reference-style links.
fn renderHtmlDjot(allocator: Allocator, doc: *const ParsedDoc, writer: *Writer) anyerror!void {
    try twig.Djot.html.render(allocator, &doc.djot, writer, .{});
}

/// Every other language (xml; a future html parse) has no side tables to
/// resolve, so the shared, language-neutral printer
/// (`languages/html/serializer.zig`) is the whole story — `ctx = null`.
fn renderHtmlGeneric(allocator: Allocator, doc: *const ParsedDoc, writer: *Writer) anyerror!void {
    try twig.Html.serialize(allocator, doc.ast(), writer, null);
}

/// Markdown needs its own HTML rendering path (`Markdown.html.render`)
/// rather than the generic printer for the same reason djot does
/// (`renderHtmlDjot`'s doc comment): footnotes (`self.options.footnotes`)
/// resolve/number/backlink entirely at RENDER time, against
/// `Document.footnotes` — see `markdown/html.zig`'s module doc comment.
/// Using the generic printer here would silently drop footnotes (every
/// `link`/`image`, by contrast, is already fully resolved at PARSE time, so
/// those are unaffected either way).
fn renderHtmlMarkdown(allocator: Allocator, doc: *const ParsedDoc, writer: *Writer) anyerror!void {
    try twig.Markdown.html.render(allocator, &doc.markdown, writer, .{});
}

fn serializeCanonicalXml(allocator: Allocator, doc: *const ParsedDoc) anyerror![]u8 {
    return twig.Xml.serializeAlloc(allocator, doc.ast());
}

/// One entry per `InputFormat`. This IS the extensibility point the CLI is
/// built around: a new language is a new `parse`/`renderHtml` adapter pair
/// (plus `serializeCanonical` if it has a serializer) and one more line here
/// — `args.zig`'s extension/name resolution and `actions.zig`'s `convert`/
/// `identify` handlers are written entirely against this table, never against
/// a per-language switch of their own.
pub const FormatEntry = struct {
    id: InputFormat,
    /// Lowercase, dot-less extensions that infer this format (checked
    /// case-insensitively against a path's last `.`-separated segment).
    extensions: []const []const u8,
    /// Extra `-i`/`--input` names accepted besides `@tagName(id)` itself
    /// (which `parseFormatName` always accepts via `std.meta.stringToEnum`).
    aliases: []const []const u8 = &.{},
    parse: *const fn (Allocator, []const u8) anyerror!ParsedDoc,
    /// Source -> the bare shared `AST`, the reparse callback the span-splice
    /// editor (`twig.Editor`, driving `twig edit`) needs. Discards any
    /// `Document` side tables (see the editor-adapter note above) — editing is
    /// language-neutral and only touches spans/structure. Every format has one.
    parseToAst: *const fn (Allocator, []const u8) anyerror!twig.AST,
    renderHtml: *const fn (Allocator, *const ParsedDoc, *Writer) anyerror!void,
    /// Round-trip serializer back to this format's own source syntax —
    /// `convert -o canonical`'s implementation. `null` means the language has
    /// no serializer yet (djot, markdown today); `actions.zig` turns that
    /// into a clear "not supported yet" error rather than a crash, and
    /// wiring one up later is exactly one field here, no dispatch changes.
    serializeCanonical: ?*const fn (Allocator, *const ParsedDoc) anyerror![]u8 = null,
};

pub const registry = [_]FormatEntry{
    .{
        .id = .djot,
        .extensions = &.{ "dj", "djot" },
        .aliases = &.{"dj"},
        .parse = parseDjot,
        .parseToAst = parseToAstDjot,
        .renderHtml = renderHtmlDjot,
    },
    .{
        .id = .markdown,
        .extensions = &.{ "md", "markdown" },
        .aliases = &.{"md"},
        .parse = parseMarkdown,
        .parseToAst = parseToAstMarkdown,
        .renderHtml = renderHtmlMarkdown,
    },
    .{
        .id = .xml,
        .extensions = &.{"xml"},
        .parse = parseXml,
        .parseToAst = parseToAstXml,
        .renderHtml = renderHtmlGeneric,
        .serializeCanonical = serializeCanonicalXml,
    },
};

/// Look up `fmt`'s entry. Every `InputFormat` variant has exactly one
/// `registry` entry (enforced by inspection, not the type system — same
/// trust boundary fig's own hand-maintained tables rely on), so this never
/// legitimately misses.
pub fn entryFor(fmt: InputFormat) *const FormatEntry {
    for (&registry) |*e| {
        if (e.id == fmt) return e;
    }
    unreachable;
}

/// Map a `-i`/`--input` token to an `InputFormat`: the enum's own tag name
/// first (`std.meta.stringToEnum`, so `"djot"`/`"markdown"`/`"xml"` always
/// work), then each entry's `aliases` (`"dj"`, `"md"`). Returns `null` for an
/// unrecognized name so the caller can print a tailored error.
pub fn parseFormatName(name: []const u8) ?InputFormat {
    if (std.meta.stringToEnum(InputFormat, name)) |f| return f;
    for (&registry) |*e| {
        for (e.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) return e.id;
        }
    }
    return null;
}

/// Infer an `InputFormat` from a file path's extension (the part after its
/// last `.`), matched case-insensitively against every `registry` entry's
/// `extensions`. Returns `null` when the path has no extension or it matches
/// no known format — the caller then either falls back to `-i`/`--input` or
/// reports the "couldn't infer a format" error (`resolveInputFormat`).
pub fn detectFromExtension(file_path: []const u8) ?InputFormat {
    const dot = std.mem.lastIndexOfScalar(u8, file_path, '.') orelse return null;
    const ext = file_path[dot + 1 ..];
    if (ext.len == 0) return null;
    for (&registry) |*e| {
        for (e.extensions) |known| {
            if (std.ascii.eqlIgnoreCase(known, ext)) return e.id;
        }
    }
    return null;
}

/// Write a "supported input formats" list to `w` — the same list an unknown
/// `-i`/`--input` name or an undetectable extension both point the user at
/// (mirrors fig's `main.zig` inline loop over `types.Format`'s fields).
pub fn printSupportedInputFormats(w: *Writer) Writer.Error!void {
    try w.writeAll("supported input formats:\n");
    for (&registry) |*e| {
        try w.print("  - {s}", .{@tagName(e.id)});
        for (e.aliases) |alias| try w.print(" ({s})", .{alias});
        try w.writeByte('\n');
    }
}

/// Errors `resolveInputFormat` can produce, beyond the write failures its own
/// diagnostics can hit. Folded into `args.zig`'s `ArgError` via `||`.
pub const ResolveInputFormatError = Writer.Error || error{
    /// `-`  (stdin) was given as the file with no `-i`/`--input` override —
    /// there is no extension to infer from, so the caller MUST say what it
    /// is.
    StdinRequiresInputFormat,
    /// A real file path was given, but its extension is missing or matches no
    /// `registry` entry, and no `-i`/`--input` override was given either.
    UnknownExtension,
};

/// Resolve the definitive `InputFormat` for `convert`/`identify`: an explicit
/// `override` (from `-i`/`--input`) always wins; otherwise infer from
/// `file_path`'s extension; otherwise fail with a diagnostic written to
/// `stderr` (mirrors fig's `ArgError.UnsupportedFileFormat` handling in
/// `main.zig`, but resolved eagerly here in one place instead of deferred to
/// every action). `file_path == "-"` (stdin) skips extension inference
/// entirely, since there is no path to infer from.
pub fn resolveInputFormat(stderr: *Writer, file_path: []const u8, override: ?InputFormat) ResolveInputFormatError!InputFormat {
    if (override) |f| return f;

    if (std.mem.eql(u8, file_path, "-")) {
        try stderr.writeAll("error: reading from stdin ('-') requires an explicit --input/-i format (there is no file extension to infer one from).\n");
        try stderr.flush();
        return error.StdinRequiresInputFormat;
    }

    if (detectFromExtension(file_path)) |f| return f;

    try stderr.print("error: could not infer an input format for '{s}' from its extension.\n", .{file_path});
    try stderr.writeAll("Try using --input/-i <format> to specify one explicitly.\n");
    try printSupportedInputFormats(stderr);
    try stderr.flush();
    return error.UnknownExtension;
}

const testing = std.testing;

test "detectFromExtension matches known extensions case-insensitively, else null" {
    try testing.expectEqual(@as(?InputFormat, .djot), detectFromExtension("post.dj"));
    try testing.expectEqual(@as(?InputFormat, .djot), detectFromExtension("post.DJOT"));
    try testing.expectEqual(@as(?InputFormat, .markdown), detectFromExtension("readme.md"));
    try testing.expectEqual(@as(?InputFormat, .markdown), detectFromExtension("readme.markdown"));
    try testing.expectEqual(@as(?InputFormat, .xml), detectFromExtension("feed.xml"));
    try testing.expectEqual(@as(?InputFormat, null), detectFromExtension("noext"));
    try testing.expectEqual(@as(?InputFormat, null), detectFromExtension("data.json"));
    try testing.expectEqual(@as(?InputFormat, null), detectFromExtension("-"));
}

test "parseFormatName accepts both canonical names and aliases" {
    try testing.expectEqual(@as(?InputFormat, .djot), parseFormatName("djot"));
    try testing.expectEqual(@as(?InputFormat, .djot), parseFormatName("dj"));
    try testing.expectEqual(@as(?InputFormat, .markdown), parseFormatName("markdown"));
    try testing.expectEqual(@as(?InputFormat, .markdown), parseFormatName("md"));
    try testing.expectEqual(@as(?InputFormat, .xml), parseFormatName("xml"));
    try testing.expectEqual(@as(?InputFormat, null), parseFormatName("bogus"));
}

test "entryFor round-trips every InputFormat variant" {
    inline for (@typeInfo(InputFormat).@"enum".fields) |field| {
        const fmt = @field(InputFormat, field.name);
        try testing.expectEqual(fmt, entryFor(fmt).id);
    }
}

test "resolveInputFormat: explicit override wins over both stdin and extension" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try testing.expectEqual(InputFormat.xml, try resolveInputFormat(&w, "-", .xml));
    try testing.expectEqual(InputFormat.djot, try resolveInputFormat(&w, "post.md", .djot));
}

test "resolveInputFormat: stdin without an override errors" {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try testing.expectError(error.StdinRequiresInputFormat, resolveInputFormat(&w, "-", null));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "--input") != null);
}

test "resolveInputFormat: undetectable extension errors and lists supported formats" {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try testing.expectError(error.UnknownExtension, resolveInputFormat(&w, "notes.txt", null));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "supported input formats") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "djot") != null);
}

test "resolveInputFormat: recognized extension infers without an override" {
    var buf: [16]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try testing.expectEqual(InputFormat.xml, try resolveInputFormat(&w, "feed.xml", null));
    try testing.expectEqual(@as(usize, 0), w.end); // nothing written on the success path
}
