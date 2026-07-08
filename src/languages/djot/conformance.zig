//! Runs the vendored djot.js conformance corpus (`testdata/djot/*.test`,
//! copied verbatim from `djot.js/test/*.test`) against `parse` + `html`.
//!
//! Fixture format (reverse-engineered from djot.js's own test runner,
//! `src/functional.spec.ts`, since there's no spec document for it): each
//! file is prose with embedded fenced blocks,
//!
//! ```` ```<options>
//! <djot input, one or more lines>
//! .
//! <expected HTML output>
//! ```` ````
//!
//! opened by a line of 3+ backticks optionally followed by an "options"
//! string, closed by a line starting with AT LEAST as many backticks as the
//! opener (so input containing its own ``` fences can be wrapped in a
//! longer run, e.g. four backticks). `options` containing `a` means "compare
//! against the AST pretty-printer, not HTML" — a debug dump format
//! (`renderAST` in djot.js's `parse.ts`) this port doesn't implement yet, so
//! those ~6 of 271 cases are skipped rather than failed; `options`
//! containing `p` enables source-position tracking, which doesn't change
//! HTML output and needs no special handling here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const djot = @import("djot.zig");
const html = @import("html.zig");

const testfiles = [_][]const u8{
    "attributes.test",
    "block_quote.test",
    "code_blocks.test",
    "definition_lists.test",
    "symb.test",
    "emphasis.test",
    "escapes.test",
    "fenced_divs.test",
    "footnotes.test",
    "headings.test",
    "insert_delete_mark.test",
    "links_and_images.test",
    "lists.test",
    "math.test",
    "para.test",
    "raw.test",
    "regression.test",
    "smart.test",
    "spans.test",
    "sourcepos.test",
    "super_subscript.test",
    "tables.test",
    "task_lists.test",
    "thematic_breaks.test",
    "verbatim.test",
};

const TestCase = struct {
    line: usize,
    options: []const u8,
    input: []const u8,
    expected: []const u8,
};

fn startsWithFence(line: []const u8) bool {
    return line.len >= 3 and line[0] == '`' and line[1] == '`' and line[2] == '`';
}

fn isCloseFence(line: []const u8, tick_len: usize) bool {
    if (line.len < tick_len) return false;
    for (line[0..tick_len]) |c| {
        if (c != '`') return false;
    }
    return true;
}

fn stripCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

/// Parse every fenced test case out of `content`. Returned `TestCase`s
/// borrow slices of `content`'s lines (joined with '\n' into freshly
/// allocated buffers, since a case spans many lines) -- `input`/`expected`
/// are owned and must be freed by the caller.
fn parseTests(allocator: Allocator, content: []const u8, out: *std.ArrayList(TestCase)) !void {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| try lines.append(allocator, stripCr(line));

    var idx: usize = 0;
    while (true) {
        var open_line: ?[]const u8 = null;
        while (idx < lines.items.len) {
            const l = lines.items[idx];
            idx += 1;
            if (startsWithFence(l)) {
                open_line = l;
                break;
            }
        }
        const line = open_line orelse break;
        const testlinenum = idx;

        var tick_len: usize = 0;
        while (tick_len < line.len and line[tick_len] == '`') tick_len += 1;
        const options = std.mem.trim(u8, line[tick_len..], " \t");

        var input = std.ArrayList(u8).empty;
        errdefer input.deinit(allocator);
        while (idx < lines.items.len) {
            const l = lines.items[idx];
            idx += 1;
            if (std.mem.eql(u8, l, ".") or std.mem.eql(u8, l, "!")) break;
            try input.appendSlice(allocator, l);
            try input.append(allocator, '\n');
        }

        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        while (idx < lines.items.len) {
            const l = lines.items[idx];
            idx += 1;
            if (isCloseFence(l, tick_len)) break;
            try output.appendSlice(allocator, l);
            try output.append(allocator, '\n');
        }

        try out.append(allocator, .{
            .line = testlinenum,
            .options = options,
            .input = try input.toOwnedSlice(allocator),
            .expected = try output.toOwnedSlice(allocator),
        });
    }
}

pub const Summary = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
};

/// A fully owned record of one failing case: `input`/`expected`/`actual`
/// are all copied (never borrowed from the per-file `cases` list in `run`,
/// which is freed before the whole corpus finishes), so a `Failure` outlives
/// the run and the caller frees it via `Failure.deinit`.
pub const Failure = struct {
    file: []const u8,
    line: usize,
    input: []const u8,
    expected: []const u8,
    actual: []const u8,

    fn deinit(self: Failure, allocator: Allocator) void {
        allocator.free(self.file);
        allocator.free(self.input);
        allocator.free(self.expected);
        allocator.free(self.actual);
    }
};

/// Run every fixture in every vendored file, collecting a summary and (up
/// to `max_failures`) detailed failure records. Paths are resolved relative
/// to the process's current directory, matching fig's `testdata/`
/// convention of vendoring conformance corpora at the repo root and reading
/// them relative to wherever `zig build test` is invoked from.
pub fn run(allocator: Allocator, max_failures: usize, failures: *std.ArrayList(Failure)) !Summary {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var summary: Summary = .{};
    for (testfiles) |name| {
        const path = try std.fmt.allocPrint(allocator, "testdata/djot/{s}", .{name});
        defer allocator.free(path);
        const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(content);

        var cases = std.ArrayList(TestCase).empty;
        defer {
            for (cases.items) |c| {
                allocator.free(c.input);
                allocator.free(c.expected);
            }
            cases.deinit(allocator);
        }
        try parseTests(allocator, content, &cases);

        for (cases.items) |c| {
            summary.total += 1;
            if (std.mem.indexOfScalar(u8, c.options, 'a') != null) {
                summary.skipped += 1;
                continue;
            }
            var doc = djot.parse(allocator, c.input) catch {
                summary.failed += 1;
                if (failures.items.len < max_failures) {
                    try failures.append(allocator, .{
                        .file = try allocator.dupe(u8, name),
                        .line = c.line,
                        .input = try allocator.dupe(u8, c.input),
                        .expected = try allocator.dupe(u8, c.expected),
                        .actual = try allocator.dupe(u8, "<parse error>"),
                    });
                }
                continue;
            };
            defer doc.deinit();
            const rendered = try html.renderAlloc(allocator, &doc, .{});
            if (std.mem.eql(u8, rendered, c.expected)) {
                summary.passed += 1;
                allocator.free(rendered);
            } else {
                summary.failed += 1;
                if (failures.items.len < max_failures) {
                    try failures.append(allocator, .{
                        .file = try allocator.dupe(u8, name),
                        .line = c.line,
                        .input = try allocator.dupe(u8, c.input),
                        .expected = try allocator.dupe(u8, c.expected),
                        .actual = rendered,
                    });
                } else {
                    allocator.free(rendered);
                }
            }
        }
    }
    return summary;
}

test "djot.js conformance corpus" {
    const allocator = std.testing.allocator;
    var failures = std.ArrayList(Failure).empty;
    defer {
        for (failures.items) |f| f.deinit(allocator);
        failures.deinit(allocator);
    }
    const summary = try run(allocator, 40, &failures);

    if (summary.failed > 0) {
        std.debug.print(
            "\ndjot conformance: {d}/{d} passed, {d} failed, {d} skipped (AST-print mode not implemented)\n",
            .{ summary.passed, summary.total, summary.failed, summary.skipped },
        );
        for (failures.items) |f| {
            std.debug.print(
                "\n-- {s}:{d} --\ninput:\n{s}\nexpected:\n{s}\nactual:\n{s}\n",
                .{ f.file, f.line, f.input, f.expected, f.actual },
            );
        }
    } else {
        std.debug.print(
            "\ndjot conformance: {d}/{d} passed, {d} skipped (AST-print mode not implemented)\n",
            .{ summary.passed, summary.total, summary.skipped },
        );
    }
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
}
