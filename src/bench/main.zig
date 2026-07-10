//! `zig build bench -- [--format <fmt>] [--iters N] <file>` — parse a document
//! under a `CountingAllocator` and report exactly how many allocations and how
//! many bytes the parse costs. This is the tool that answers the memory
//! questions `/usr/bin/time` can't: the CLI runs on an arena (per-node `dupe`s
//! become cheap bumps, so RSS barely moves when you remove allocations),
//! whereas this harness wraps the *page allocator* and counts every call, so a
//! change like "borrow source instead of duping" shows up as a real drop in
//! `allocations`/`bytes alloc` even when wall-clock is flat.
//!
//! Format defaults to inference from the file extension; override with
//! `--format djot|markdown|html|xml`. `--iters N` reparses N times (each parse
//! fully deinit'd) and reports the *per-iteration* averages, which steadies
//! the numbers and lets you eyeball allocator throughput.

const std = @import("std");
const Io = std.Io;
const twig = @import("twig");
const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;

const Format = enum { djot, markdown, html, xml };

const max_source_bytes = 64 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_fw.interface;

    const argv = try init.minimal.args.toSlice(arena);
    var path: ?[]const u8 = null;
    var forced: ?Format = null;
    var iters: usize = 1;

    var i: usize = 1; // skip argv[0]
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--format") or std.mem.eql(u8, a, "-f")) {
            i += 1;
            if (i >= argv.len) return fail(stderr, "--format needs a value", .{});
            forced = std.meta.stringToEnum(Format, argv[i]) orelse
                return fail(stderr, "unknown format '{s}' (djot|markdown|html|xml)", .{argv[i]});
        } else if (std.mem.eql(u8, a, "--iters") or std.mem.eql(u8, a, "-n")) {
            i += 1;
            if (i >= argv.len) return fail(stderr, "--iters needs a value", .{});
            iters = std.fmt.parseInt(usize, argv[i], 10) catch
                return fail(stderr, "bad --iters '{s}'", .{argv[i]});
            if (iters == 0) return fail(stderr, "--iters must be >= 1", .{});
        } else if (path == null) {
            path = a;
        } else {
            return fail(stderr, "unexpected extra argument '{s}'", .{a});
        }
    }

    const file = path orelse return fail(stderr, "usage: bench [--format <fmt>] [--iters N] <file>", .{});
    const fmt = forced orelse inferFormat(file) orelse
        return fail(stderr, "cannot infer format of '{s}'; pass --format", .{file});

    const source = Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(max_source_bytes)) catch |err|
        return fail(stderr, "could not read '{s}': {t}", .{ file, err });

    // Wrap the page allocator (NOT the arena) so frees are real and
    // `bytes peak` reflects the true live high-water mark of one parse.
    var counter = CountingAllocator.init(std.heap.page_allocator);
    const galloc = counter.allocator();

    var n: usize = 0;
    while (n < iters) : (n += 1) {
        switch (fmt) {
            .djot => {
                var doc = try twig.Djot.parse(galloc, source);
                doc.deinit();
            },
            .markdown => {
                var doc = try twig.Markdown.parse(galloc, source, .{});
                doc.deinit();
            },
            .html => {
                var ast = try twig.Html.parse(galloc, source);
                ast.deinit();
            },
            .xml => {
                var ast = twig.Xml.parse(galloc, source) catch |err|
                    return fail(stderr, "xml parse failed: {t}", .{err});
                ast.deinit();
            },
        }
    }

    const s = counter.stats;
    const fi: f64 = @floatFromInt(iters);
    try stdout.print(
        \\file        : {s}
        \\format      : {t}
        \\source      : {d} bytes
        \\iterations  : {d}
        \\
        \\── totals over all iterations ──
        \\{f}
        \\
        \\── per iteration ──
        \\allocations : {d:.1}
        \\bytes alloc : {d:.0}
        \\bytes/byte  : {d:.2}  (alloc'd bytes per source byte)
        \\
    , .{
        file,
        fmt,
        source.len,
        iters,
        s,
        @as(f64, @floatFromInt(s.alloc_count)) / fi,
        @as(f64, @floatFromInt(s.bytes_allocated)) / fi,
        if (source.len == 0) 0 else @as(f64, @floatFromInt(s.bytes_allocated)) / (fi * @as(f64, @floatFromInt(source.len))),
    });

    // A clean parse frees everything; a nonzero live count means a leak.
    if (s.bytes_live != 0)
        try stdout.print("\nWARNING: {d} bytes still live after deinit (leak?)\n", .{s.bytes_live});

    try stdout.flush();
}

fn inferFormat(path: []const u8) ?Format {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    const ext = path[dot + 1 ..];
    if (std.ascii.eqlIgnoreCase(ext, "dj") or std.ascii.eqlIgnoreCase(ext, "djot")) return .djot;
    if (std.ascii.eqlIgnoreCase(ext, "md") or std.ascii.eqlIgnoreCase(ext, "markdown")) return .markdown;
    if (std.ascii.eqlIgnoreCase(ext, "html") or std.ascii.eqlIgnoreCase(ext, "htm")) return .html;
    if (std.ascii.eqlIgnoreCase(ext, "xml")) return .xml;
    return null;
}

fn fail(stderr: *Io.Writer, comptime fmt: []const u8, args: anytype) error{BenchFailed} {
    stderr.print("bench: " ++ fmt ++ "\n", args) catch {};
    stderr.flush() catch {};
    return error.BenchFailed;
}
