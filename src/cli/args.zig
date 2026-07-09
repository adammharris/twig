//! Command-line parsing: turns the raw argv iterator into a `CliConfig`
//! (`parseConfig`). Mirrors fig's `cli/args.zig` at Twig's smaller scale — no
//! embed archetypes, no structural edit paths, just the `-i`/`-o` format-flag
//! convention fig established plus Twig's two verbs (`convert`, `identify`).
//!
//! Diagnostics are printed here, at the exact point a flag/format fails to
//! resolve (via the `stderr` writer every parse function takes), rather than
//! deferred to `main.zig`'s catch site the way fig routes through `std.log` —
//! Twig's CLI has no `std.log`/terminal-color machinery (see `main.zig`'s
//! module doc comment), so a plain writer threaded through is the modest
//! equivalent. `main.zig` only adds a short usage reminder on the handful of
//! `ArgError` variants that reach it without their own message already
//! printed (`MissingFile`, `MissingFormatValue`, `TooManyPositionals`).

const std = @import("std");
const Writer = std.Io.Writer;

const format = @import("format.zig");
const InputFormat = format.InputFormat;
const OutputMode = format.OutputMode;

pub const Action = enum { help, version, convert, identify };

pub const ConvertOptions = struct {
    /// The file to convert, or `"-"` for stdin.
    file: []const u8 = "",
    /// Resolved by `parseConfig` (via `format.resolveInputFormat`) — always a
    /// definite `InputFormat` by the time a `ConvertOptions` exists, never
    /// re-resolved by `actions.zig`.
    input: InputFormat = .djot,
    /// Defaults to `.html` — `convert file.dj` alone renders HTML, per the
    /// mission's "the workhorse" framing of this command.
    output: OutputMode = .html,
};

pub const IdentifyOptions = struct {
    file: []const u8 = "",
    input: InputFormat = .djot,
};

pub const CliActionOptions = union(Action) {
    help: void,
    version: void,
    convert: ConvertOptions,
    identify: IdentifyOptions,
};

pub const CliConfig = struct {
    action: Action = .help,
    options: CliActionOptions = .{ .help = {} },
    binary_name: []const u8 = "twig",
};

/// Errors `parseConfig` can return. The `Missing*`/`TooManyPositionals`
/// variants carry no message of their own (there is nothing tailored to say
/// beyond "here's the usage"); every other variant has already printed a
/// specific diagnostic to `stderr` by the time it's returned — see this
/// file's module doc comment.
pub const ArgError = error{
    UnsupportedFormat,
    MissingFormatValue,
    MissingFile,
    TooManyPositionals,
} || format.ResolveInputFormatError;

/// A `[:0]const u8`-argv-slice-backed iterator satisfying the `.next()`
/// contract `parseConfig` expects (`anytype`, so the same function also
/// accepts the plain-slice `TestArgs` the unit tests below use — mirroring
/// fig's `cli/args.zig` split between real argv and its own `TestArgs`).
pub const ArgIterator = struct {
    items: []const [:0]const u8,
    i: usize = 0,

    pub fn next(self: *ArgIterator) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

fn isAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

pub fn parseConfig(args: anytype, stderr: *Writer) ArgError!CliConfig {
    var config = CliConfig{};
    config.binary_name = args.next() orelse "twig";

    const action_str = args.next() orelse {
        config.action = .help;
        return config;
    };

    if (isAny(action_str, &.{ "help", "--help", "-h" })) {
        config.action = .help;
        return config;
    }
    if (isAny(action_str, &.{ "version", "--version", "-v" })) {
        config.action = .version;
        config.options = .{ .version = {} };
        return config;
    }
    if (std.mem.eql(u8, action_str, "convert")) {
        return parseConvert(args, stderr, config.binary_name);
    }
    if (std.mem.eql(u8, action_str, "identify")) {
        return parseIdentify(args, stderr, config.binary_name);
    }

    // Unrecognized verb: fall back to help, same as no args / an explicit
    // `twig help` (mirrors fig's `parseConfig` falling back rather than
    // hard-erroring on a typo'd action).
    config.action = .help;
    return config;
}

fn parseConvert(args: anytype, stderr: *Writer, binary_name: []const u8) ArgError!CliConfig {
    var input_override: ?InputFormat = null;
    var output: OutputMode = .html;
    var file: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            const name = args.next() orelse return ArgError.MissingFormatValue;
            input_override = format.parseFormatName(name) orelse {
                try stderr.print("error: unsupported input format '{s}'\n", .{name});
                try format.printSupportedInputFormats(stderr);
                try stderr.flush();
                return ArgError.UnsupportedFormat;
            };
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            const name = args.next() orelse return ArgError.MissingFormatValue;
            output = format.parseOutputMode(name) orelse {
                try stderr.print("error: unsupported output format '{s}' (expected html, ast, or canonical)\n", .{name});
                try stderr.flush();
                return ArgError.UnsupportedFormat;
            };
        } else if (file == null) {
            file = arg;
        } else {
            return ArgError.TooManyPositionals;
        }
    }

    const path = file orelse return ArgError.MissingFile;
    const resolved = try format.resolveInputFormat(stderr, path, input_override);

    return .{
        .action = .convert,
        .binary_name = binary_name,
        .options = .{ .convert = .{ .file = path, .input = resolved, .output = output } },
    };
}

fn parseIdentify(args: anytype, stderr: *Writer, binary_name: []const u8) ArgError!CliConfig {
    var input_override: ?InputFormat = null;
    var file: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            const name = args.next() orelse return ArgError.MissingFormatValue;
            input_override = format.parseFormatName(name) orelse {
                try stderr.print("error: unsupported input format '{s}'\n", .{name});
                try format.printSupportedInputFormats(stderr);
                try stderr.flush();
                return ArgError.UnsupportedFormat;
            };
        } else if (file == null) {
            file = arg;
        } else {
            return ArgError.TooManyPositionals;
        }
    }

    const path = file orelse return ArgError.MissingFile;
    const resolved = try format.resolveInputFormat(stderr, path, input_override);

    return .{
        .action = .identify,
        .binary_name = binary_name,
        .options = .{ .identify = .{ .file = path, .input = resolved } },
    };
}

const testing = std.testing;

/// A plain-slice-backed stand-in for the real argv iterator, for unit tests
/// that don't want to build a `[:0]const u8` slice — mirrors fig's own
/// `TestArgs` in `cli/args.zig`.
const TestArgs = struct {
    items: []const []const u8,
    i: usize = 0,
    fn next(self: *TestArgs) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

/// A generously-sized scratch `Writer` for tests that don't care about the
/// diagnostic text, just that parsing succeeds or fails as expected. Backed
/// by a fixed buffer (not `Writer.Discarding`, whose drain implementation
/// recovers its owning struct via `@fieldParentPtr` and so isn't safe to hand
/// back out of a helper function by value).
fn scratchWriter(buf: []u8) Writer {
    return Writer.fixed(buf);
}

test "parseConfig: no args and explicit help/--help/-h all select help" {
    var buf: [256]u8 = undefined;
    inline for (&.{
        &[_][]const u8{"twig"},
        &[_][]const u8{ "twig", "help" },
        &[_][]const u8{ "twig", "--help" },
        &[_][]const u8{ "twig", "-h" },
    }) |argv| {
        var w = scratchWriter(&buf);
        var a = TestArgs{ .items = argv };
        const c = try parseConfig(&a, &w);
        try testing.expectEqual(Action.help, c.action);
    }
}

test "parseConfig: version/--version/-v select version" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "version" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(Action.version, c.action);
}

test "parseConfig: convert infers input format from extension, defaults output to html" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "convert", "doc.dj" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(Action.convert, c.action);
    try testing.expectEqualStrings("doc.dj", c.options.convert.file);
    try testing.expectEqual(InputFormat.djot, c.options.convert.input);
    try testing.expectEqual(OutputMode.html, c.options.convert.output);
}

test "parseConfig: convert -i/-o override inference, in either flag order" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "convert", "-i", "md", "-o", "ast", "weird.ext" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(InputFormat.markdown, c.options.convert.input);
    try testing.expectEqual(OutputMode.ast, c.options.convert.output);

    var w2 = scratchWriter(&buf);
    var a2 = TestArgs{ .items = &.{ "twig", "convert", "--output", "canonical", "--input", "xml", "f" } };
    const c2 = try parseConfig(&a2, &w2);
    try testing.expectEqual(InputFormat.xml, c2.options.convert.input);
    try testing.expectEqual(OutputMode.canonical, c2.options.convert.output);
}

test "parseConfig: convert stdin ('-') without -i errors clearly" {
    var buf: [512]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "convert", "-" } };
    try testing.expectError(error.StdinRequiresInputFormat, parseConfig(&a, &w));
}

test "parseConfig: convert stdin with -i succeeds" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "convert", "-i", "djot", "-" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqualStrings("-", c.options.convert.file);
    try testing.expectEqual(InputFormat.djot, c.options.convert.input);
}

test "parseConfig: convert with an unrecognized extension and no -i errors" {
    var buf: [512]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "convert", "notes.txt" } };
    try testing.expectError(error.UnknownExtension, parseConfig(&a, &w));
}

test "parseConfig: convert rejects an unknown -i/-o value, a missing file, and extra positionals" {
    var buf: [512]u8 = undefined;

    var w1 = scratchWriter(&buf);
    var bad_i = TestArgs{ .items = &.{ "twig", "convert", "-i", "bogus", "f.dj" } };
    try testing.expectError(error.UnsupportedFormat, parseConfig(&bad_i, &w1));

    var w2 = scratchWriter(&buf);
    var bad_o = TestArgs{ .items = &.{ "twig", "convert", "-o", "bogus", "f.dj" } };
    try testing.expectError(error.UnsupportedFormat, parseConfig(&bad_o, &w2));

    var w3 = scratchWriter(&buf);
    var no_file = TestArgs{ .items = &.{ "twig", "convert" } };
    try testing.expectError(error.MissingFile, parseConfig(&no_file, &w3));

    var w4 = scratchWriter(&buf);
    var extra = TestArgs{ .items = &.{ "twig", "convert", "a.dj", "b.dj" } };
    try testing.expectError(error.TooManyPositionals, parseConfig(&extra, &w4));
}

test "parseConfig: identify resolves the input format and takes no -o" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "identify", "post.md" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(Action.identify, c.action);
    try testing.expectEqual(InputFormat.markdown, c.options.identify.input);
}

test "parseConfig: an unrecognized verb falls back to help rather than erroring" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "frobnicate", "f.dj" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(Action.help, c.action);
}
