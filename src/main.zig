const std = @import("std");
const Io = std.Io;

const twig = @import("twig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try stderr_writer.print("usage: {s} <file.dj>\n\nParses a Djot file and prints its HTML rendering.\n", .{if (args.len > 0) args[0] else "twig"});
        try stderr_writer.flush();
        return;
    }

    const path = args[1];
    const source = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |err| {
        try stderr_writer.print("error: could not read '{s}': {t}\n", .{ path, err });
        try stderr_writer.flush();
        return err;
    };

    var doc = try twig.Djot.parse(arena, source);
    defer doc.deinit();

    try twig.Djot.html.render(arena, &doc, stdout_writer, .{});
    try stdout_writer.flush();
}
