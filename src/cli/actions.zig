//! The four verb implementations `main.zig` dispatches into: `help`,
//! `version`, `identify`, `convert`. Mirrors the role of fig's
//! `cli/actions.zig`, at Twig's smaller scale — no terminal/diff/gron
//! machinery, just plain `std.Io.Writer`s in and (for `convert`/`identify`)
//! file/stdin reads via `io`.
//!
//! Every failure mode an action can hit — a file that won't read, a parse
//! error, `-o canonical` on a format with no serializer — gets its own clear
//! message printed to `stderr` right where it's detected, then the action
//! returns `error.ActionFailed`: one sentinel `main.zig` recognizes to exit
//! non-zero *without* also dumping a Zig error return trace on top of the
//! message this file already gave the user. Errors that are NOT
//! `ActionFailed` (there are none on the paths below in practice) would mean
//! something unexpected happened — a real bug, not a user-facing condition —
//! and are left to propagate and be reported the normal way.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

const twig = @import("twig");

const format = @import("format.zig");
const args_mod = @import("args.zig");
const ast_json = @import("ast_json.zig");

/// The single error every action in this file returns after it has already
/// printed (and flushed) an explanatory message to `stderr` — see this
/// file's module doc comment.
pub const ActionError = error{ActionFailed};

/// The maximum size of a source file (or stdin stream) `convert`/`identify`
/// will read into memory. Generous for hand-authored documents; guards
/// against accidentally piping something enormous into an arena that's never
/// freed mid-process.
const max_source_bytes = 16 * 1024 * 1024;

const version = "twig 0.1.0";

pub fn runVersion(stdout: *Writer) !void {
    try stdout.print("{s}\n", .{version});
    try stdout.flush();
}

pub fn runHelp(w: *Writer, binary_name: []const u8) !void {
    try w.print(
        \\usage: {s} <command> [options] <file>
        \\
        \\commands:
        \\  convert [-i <format>] [-o <format>] <file|->
        \\      Convert a document. `-o` selects the output; default is `html`.
        \\        html       render to HTML (default)
        \\        ast        dump the shared AST as pretty-printed JSON
        \\        canonical  round-trip serialize back to the source format
        \\                   (only formats with a serializer support this)
        \\
        \\  identify <file>
        \\      Detect and print a file's input format; performs no conversion.
        \\
        \\  query [-i <format>] <file> <selector>
        \\      List nodes matching a CSS-lite selector, one per line:
        \\      `[index.path]  kind  "text preview"`. Feed a printed path
        \\      straight to `edit`. Selector examples:
        \\        heading            heading[level=2]    heading("Status")
        \\        item[2]            link[dest^="http"]  code[lang=zig]
        \\
        \\  edit [-i <format>] <file|-> <operation>
        \\      Losslessly edit a document in place, addressing a node by its
        \\      dot-separated index path (e.g. 0.3.1). Use `convert -o ast` to
        \\      see the tree and read off paths. Operations:
        \\        --replace <path> <text>          replace a node's whole source
        \\        --replace-content <path> <text>  replace a container's interior
        \\        --insert-before <path> <text>    insert text before a node
        \\        --insert-after <path> <text>     insert text after a node
        \\        --insert-child <path> <i> <text> insert as a container's i-th child
        \\        --delete <path>                  remove a node
        \\      Writes back in place; pass --dry-run to print the result instead.
        \\
        \\  help              show this message
        \\  version           show the version
        \\
        \\options:
        \\  -i, --input <format>   override input-format detection
        \\                         (djot/dj, markdown/md, xml)
        \\  -o, --output <format>  select convert's output (html, ast, canonical)
        \\  --dry-run              (edit) print the result instead of writing it
        \\
        \\Input format is normally inferred from the file extension
        \\(.dj/.djot, .md/.markdown, .xml). Pass `-` as the file to read from
        \\stdin — this requires an explicit `-i`, since there is no extension
        \\to infer from.
        \\
        \\examples:
        \\  {s} convert doc.dj
        \\  {s} convert -o ast doc.dj
        \\  {s} convert -o canonical feed.xml
        \\  {s} identify doc.md
        \\  {s} convert -i markdown - < doc.md
        \\
    , .{ binary_name, binary_name, binary_name, binary_name, binary_name, binary_name });
    try w.flush();
}

pub fn runIdentify(stdout: *Writer, opts: args_mod.IdentifyOptions) !void {
    try stdout.print("{s}\n", .{@tagName(opts.input)});
    try stdout.flush();
}

/// Convert `opts.file` (or stdin, for `"-"`) from `opts.input` to whatever
/// `opts.output` selects:
///   - `.html`      — the language's HTML rendering path (djot uses
///                    `Djot.html.render` for its footnote/reference
///                    resolution; everything else uses the generic
///                    `Html.serialize`) — see `format.zig`'s `renderHtml`
///                    adapters.
///   - `.ast`       — `ast_json.encode`, a stable pretty-printed JSON dump
///                    of the shared `AST`.
///   - `.canonical` — the format's own round-trip serializer
///                    (`format.FormatEntry.serializeCanonical`), or a clear
///                    "not supported yet" error when the format has none.
pub fn runConvert(allocator: Allocator, io: Io, stdout: *Writer, stderr: *Writer, opts: args_mod.ConvertOptions) ActionError!void {
    const source = try readSource(allocator, io, opts.file, stderr);
    try convertSource(allocator, source, opts.file, opts.input, opts.output, stdout, stderr);
    stdout.flush() catch |err| {
        stderr.print("error: failed to write output: {t}\n", .{err}) catch {};
        stderr.flush() catch {};
        return error.ActionFailed;
    };
}

/// The parse-then-dispatch core of `runConvert`, split out from the
/// file/stdin read (`readSource`) so it can be exercised directly against an
/// in-memory source string in tests, without touching the filesystem.
/// `display_name` is only used in diagnostics (it's `opts.file`, which may be
/// `"-"` for stdin).
fn convertSource(
    allocator: Allocator,
    source: []const u8,
    display_name: []const u8,
    input: format.InputFormat,
    output: format.OutputMode,
    stdout: *Writer,
    stderr: *Writer,
) ActionError!void {
    const entry = format.entryFor(input);

    var doc = entry.parse(allocator, source) catch |err| {
        stderr.print("error: failed to parse '{s}' as {s}: {t}\n", .{ display_name, @tagName(input), err }) catch {};
        stderr.flush() catch {};
        return error.ActionFailed;
    };
    defer doc.deinit();

    switch (output) {
        .html => entry.renderHtml(allocator, &doc, stdout) catch |err| {
            stderr.print("error: failed to render '{s}' to html: {t}\n", .{ display_name, err }) catch {};
            stderr.flush() catch {};
            return error.ActionFailed;
        },
        .ast => ast_json.encode(doc.ast(), stdout) catch |err| {
            stderr.print("error: failed to write the AST dump for '{s}': {t}\n", .{ display_name, err }) catch {};
            stderr.flush() catch {};
            return error.ActionFailed;
        },
        .canonical => {
            const serializeFn = entry.serializeCanonical orelse {
                stderr.print(
                    "error: canonical output is not supported for {s} yet: no serializer\n",
                    .{@tagName(input)},
                ) catch {};
                stderr.flush() catch {};
                return error.ActionFailed;
            };
            const out = serializeFn(allocator, &doc) catch |err| {
                stderr.print("error: failed to serialize '{s}' to canonical form: {t}\n", .{ display_name, err }) catch {};
                stderr.flush() catch {};
                return error.ActionFailed;
            };
            // Safe to free unconditionally: in the real CLI, `allocator` is
            // the process-lifetime arena (`main.zig`'s `init.arena`), where
            // `free` is a harmless no-op; in tests it's a leak-checking GPA,
            // where this is the only thing standing between `out` and a
            // reported leak (`stdout` has already copied whatever it needs
            // into its own buffer by the time `writeAll` returns).
            defer allocator.free(out);
            stdout.writeAll(out) catch |err| {
                stderr.print("error: failed to write output: {t}\n", .{err}) catch {};
                stderr.flush() catch {};
                return error.ActionFailed;
            };
        },
    }
}

/// Parse `opts.file`, resolve `opts.selector` against it, and list every
/// match — one line each: `[index.path]  kind  "text preview"`. The index path
/// bridges content-based addressing back to the raw paths `edit` also accepts,
/// and the whole thing is just `Select.resolveAll` + a printer over the library
/// engine (`ast/select.zig`).
pub fn runQuery(allocator: Allocator, io: Io, stdout: *Writer, stderr: *Writer, opts: args_mod.QueryOptions) ActionError!void {
    const source = try readSource(allocator, io, opts.file, stderr);

    // Editing/querying only needs the bare AST — reuse the editor's per-format
    // reparse adapter (which discards any `Document` side tables).
    var ast = format.entryFor(opts.input).parseToAst(allocator, source) catch |err| {
        stderr.print("error: failed to parse '{s}' as {s}: {t}\n", .{ opts.file, @tagName(opts.input), err }) catch {};
        stderr.flush() catch {};
        return error.ActionFailed;
    };
    defer ast.deinit();

    var selector = twig.Select.parse(allocator, opts.selector) catch |err| {
        stderr.print("error: could not parse selector '{s}': {t}\n", .{ opts.selector, err }) catch {};
        stderr.flush() catch {};
        return error.ActionFailed;
    };
    defer selector.deinit();

    const matches = twig.Select.resolveAll(allocator, &ast, &selector) catch return error.ActionFailed;

    if (matches.len == 0) {
        stderr.print("no matches for selector '{s}'\n", .{opts.selector}) catch {};
        stderr.flush() catch {};
        return;
    }

    for (matches) |m| {
        printMatchLine(allocator, &ast, m.id, stdout) catch |err| {
            stderr.print("error: failed to write output: {t}\n", .{err}) catch {};
            stderr.flush() catch {};
            return error.ActionFailed;
        };
    }
    stdout.flush() catch |err| {
        stderr.print("error: failed to write output: {t}\n", .{err}) catch {};
        stderr.flush() catch {};
        return error.ActionFailed;
    };
}

/// One `query` result line: `[0.3.1]  heading  "some text…"`.
fn printMatchLine(allocator: Allocator, ast: *const twig.AST, id: twig.AST.Node.Id, stdout: *Writer) !void {
    try stdout.writeByte('[');
    if (try ast.pathOf(allocator, id)) |path| {
        defer allocator.free(path);
        for (path, 0..) |seg, i| {
            if (i != 0) try stdout.writeByte('.');
            try stdout.print("{d}", .{seg});
        }
    }
    try stdout.print("]\t{s}\t", .{@tagName(std.meta.activeTag(ast.nodes[id].kind))});

    const text = try twig.Select.textOf(allocator, ast, id);
    defer allocator.free(text);
    try stdout.writeByte('"');
    try writePreview(text, stdout);
    try stdout.writeAll("\"\n");
}

/// Write up to 60 bytes of `text` with newlines/tabs collapsed to spaces, so a
/// match preview stays on one tidy line.
fn writePreview(text: []const u8, stdout: *Writer) !void {
    const limit = 60;
    const n = @min(text.len, limit);
    for (text[0..n]) |c| {
        try stdout.writeByte(if (c == '\n' or c == '\t' or c == '\r') ' ' else c);
    }
    if (text.len > limit) try stdout.writeAll("…");
}

/// Apply one span-splice edit to `opts.file` (or stdin) and either write the
/// result back in place or — for `--dry-run`, or when reading stdin (which
/// can't be written back) — print it to stdout. The parse/edit core is
/// `applyEdit`, split out so tests can drive it against an in-memory string.
pub fn runEdit(allocator: Allocator, io: Io, stdout: *Writer, stderr: *Writer, opts: args_mod.EditOptions) ActionError!void {
    const source = try readSource(allocator, io, opts.file, stderr);
    const path = try parsePath(allocator, opts.path_str, stderr);
    const edited = try applyEdit(allocator, source, opts.input, opts.op, path, opts.child_index, opts.text, stderr);

    // stdin has no file to write back to, so it always prints; `--dry-run`
    // prints for a real file too, leaving it untouched.
    if (opts.dry_run or std.mem.eql(u8, opts.file, "-")) {
        stdout.writeAll(edited) catch {};
        stdout.flush() catch |err| {
            stderr.print("error: failed to write output: {t}\n", .{err}) catch {};
            stderr.flush() catch {};
            return error.ActionFailed;
        };
        return;
    }

    writeFileInPlace(io, opts.file, edited) catch |err| {
        stderr.print("error: could not write '{s}': {t}\n", .{ opts.file, err }) catch {};
        stderr.flush() catch {};
        return error.ActionFailed;
    };
}

/// Parse a dot-separated index path (`"0.3.1"` -> `&.{0,3,1}`; empty -> the
/// root, `&.{}`). A non-numeric segment prints a message and fails.
fn parsePath(allocator: Allocator, path_str: []const u8, stderr: *Writer) ActionError![]const usize {
    if (path_str.len == 0) return &.{};
    var list: std.ArrayList(usize) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, path_str, '.');
    while (it.next()) |seg| {
        const n = std.fmt.parseInt(usize, seg, 10) catch {
            stderr.print("error: invalid path segment '{s}' in '{s}' (expected dot-separated indices like 0.3.1)\n", .{ seg, path_str }) catch {};
            stderr.flush() catch {};
            return error.ActionFailed;
        };
        list.append(allocator, n) catch return error.ActionFailed;
    }
    return list.toOwnedSlice(allocator) catch error.ActionFailed;
}

/// Parse `source` as `input`, apply the one edit, and return the edited bytes
/// (owned by `allocator`). Every failure — parse, a bad path/interior, or a
/// reparse-breaking edit that rolls back — prints a clear message and folds
/// into `ActionError`.
fn applyEdit(
    allocator: Allocator,
    source: []const u8,
    input: format.InputFormat,
    op: args_mod.EditOp,
    path: []const usize,
    child_index: usize,
    text: []const u8,
    stderr: *Writer,
) ActionError![]u8 {
    const entry = format.entryFor(input);
    var editor = twig.Editor.init(allocator, source, entry.parseToAst) catch |err| {
        stderr.print("error: failed to parse input as {s}: {t}\n", .{ @tagName(input), err }) catch {};
        stderr.flush() catch {};
        return error.ActionFailed;
    };
    defer editor.deinit();

    const result = switch (op) {
        .replace => editor.replaceNode(path, text),
        .replace_content => editor.replaceContent(path, text),
        .insert_before => editor.insertBefore(path, text),
        .insert_after => editor.insertAfter(path, text),
        .insert_child => editor.insertChild(path, child_index, text),
        .delete => editor.deleteNode(path),
    };
    result catch |err| {
        switch (err) {
            error.PathOutOfBounds => stderr.print("error: no node at that path (index out of bounds)\n", .{}) catch {},
            error.NoContentSpan => stderr.print("error: that node has no editable interior (it's a leaf, or a container the parser left without a known interior)\n", .{}) catch {},
            else => stderr.print("error: the edit produced a document that no longer parses ({t}); nothing was changed\n", .{err}) catch {},
        }
        stderr.flush() catch {};
        return error.ActionFailed;
    };

    return allocator.dupe(u8, editor.sourceBytes()) catch return error.ActionFailed;
}

/// Overwrite `path` with `data` (truncating create + positional write). Used
/// by `runEdit`'s in-place write-back.
fn writeFileInPlace(io: Io, path: []const u8, data: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, data, 0);
}

/// Read `path`'s full contents, or stdin's when `path == "-"`. Both paths go
/// through the same `max_source_bytes` cap; failures print a clear message to
/// `stderr` and fold into `ActionError` rather than propagating the
/// underlying `Io`/allocator error type, so callers have one uniform failure
/// mode to handle.
fn readSource(allocator: Allocator, io: Io, path: []const u8, stderr: *Writer) ActionError![]const u8 {
    if (std.mem.eql(u8, path, "-")) {
        var buffer: [4096]u8 = undefined;
        var stdin_reader = Io.File.stdin().reader(io, &buffer);
        return stdin_reader.interface.allocRemaining(allocator, .limited(max_source_bytes)) catch |err| {
            stderr.print("error: could not read stdin: {t}\n", .{err}) catch {};
            stderr.flush() catch {};
            return error.ActionFailed;
        };
    }

    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_bytes)) catch |err| {
        stderr.print("error: could not read '{s}': {t}\n", .{ path, err }) catch {};
        stderr.flush() catch {};
        return error.ActionFailed;
    };
}

const testing = std.testing;

test "runIdentify prints the resolved format name and nothing else" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try runIdentify(&w, .{ .file = "post.md", .input = .markdown });
    try testing.expectEqualStrings("markdown\n", w.buffered());
}

test "runVersion prints a 'twig <version>'-shaped line" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try runVersion(&w);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "twig "));
}

test "runHelp mentions every command and both format flags" {
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try runHelp(&w, "twig");
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "convert") != null);
    try testing.expect(std.mem.indexOf(u8, out, "identify") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-i") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-o") != null);
}

test "convertSource: html output for djot goes through Djot.html.render (footnotes resolve)" {
    var out_buf: [4096]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var err: Writer = .fixed(&err_buf);

    try convertSource(testing.allocator, "hi[^1]\n\n[^1]: a note\n", "-", .djot, .html, &out, &err);
    // `role="doc-endnotes"`/`id="fn1"` only appear when the djot-specific
    // side-table-aware render path (`Djot.html.render`) actually resolved the
    // footnote reference — the generic `Html.serialize(..., null)` path
    // (correctly) can't do this at all, since it has no `Document` to pull
    // `doc.footnotes` from. This is the assertion that proves `convertSource`
    // dispatches djot through `renderHtmlDjot`, not `renderHtmlGeneric`.
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "doc-endnotes") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "id=\"fn1\"") != null);
}

test "convertSource: ast output is JSON starting with a doc-kind object" {
    var out_buf: [4096]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var err: Writer = .fixed(&err_buf);

    try convertSource(testing.allocator, "hello\n", "-", .djot, .ast, &out, &err);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"kind\": \"doc\"") != null);
}

test "convertSource: xml canonical output round-trips through Xml.serializeAlloc" {
    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var err: Writer = .fixed(&err_buf);

    try convertSource(testing.allocator, "<a><b/></a>", "-", .xml, .canonical, &out, &err);
    try testing.expectEqualStrings("<a><b/></a>", out.buffered());
}

test "convertSource: canonical output on a format with no serializer fails clearly" {
    var out_buf: [256]u8 = undefined;
    var err_buf: [512]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var err: Writer = .fixed(&err_buf);

    // djot has no serializer yet: this must fail with `ActionFailed` and a
    // message naming djot and "no serializer", not crash or emit nothing.
    try testing.expectError(error.ActionFailed, convertSource(testing.allocator, "hello\n", "-", .djot, .canonical, &out, &err));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "no serializer") != null);
}

test "parsePath: dotted indices, empty = root, non-numeric errors" {
    var buf: [256]u8 = undefined;
    var err: Writer = .fixed(&buf);

    const p = try parsePath(testing.allocator, "0.3.1", &err);
    defer testing.allocator.free(p);
    try testing.expectEqualSlices(usize, &.{ 0, 3, 1 }, p);

    const root = try parsePath(testing.allocator, "", &err);
    try testing.expectEqual(@as(usize, 0), root.len);

    try testing.expectError(error.ActionFailed, parsePath(testing.allocator, "0.x", &err));
}

test "applyEdit: xml replace-content, markdown insert-child, djot replace, delete" {
    var buf: [512]u8 = undefined;
    var err: Writer = .fixed(&buf);

    // XML: replace <b>'s interior.
    const xml = try applyEdit(testing.allocator, "<a><b>hi</b></a>", .xml, .replace_content, &.{ 0, 0 }, 0, "bye", &err);
    defer testing.allocator.free(xml);
    try testing.expectEqualStrings("<a><b>bye</b></a>", xml);

    // Markdown: insert a new first list item. The list is doc's child 0; its
    // items are the list's children.
    const md = try applyEdit(testing.allocator, "- one\n- two\n", .markdown, .insert_child, &.{0}, 0, "- zero\n", &err);
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("- zero\n- one\n- two\n", md);

    // Djot: replace the first paragraph's whole source. deleteNode on the
    // second one then removes it.
    const dj = try applyEdit(testing.allocator, "one\n\ntwo\n", .djot, .replace, &.{0}, 0, "ONE", &err);
    defer testing.allocator.free(dj);
    try testing.expect(std.mem.startsWith(u8, dj, "ONE"));
}

test "applyEdit: a leaf interior yields a clear NoContentSpan failure" {
    var buf: [512]u8 = undefined;
    var err: Writer = .fixed(&buf);
    try testing.expectError(error.ActionFailed, applyEdit(testing.allocator, "<a>hi</a>", .xml, .replace_content, &.{ 0, 0 }, 0, "x", &err));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "no editable interior") != null);
}

test "applyEdit: an edit that breaks the reparse rolls back and reports it" {
    var buf: [512]u8 = undefined;
    var err: Writer = .fixed(&buf);
    // Replacing <a>'s interior with "<b>" makes `<a><b></a>` — malformed.
    try testing.expectError(error.ActionFailed, applyEdit(testing.allocator, "<a>ok</a>", .xml, .replace_content, &.{0}, 0, "<b>", &err));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "no longer parses") != null);
}
