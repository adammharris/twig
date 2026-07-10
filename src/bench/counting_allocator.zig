//! A pass-through `Allocator` wrapper that counts every call and tracks live
//! bytes, for answering "how much does this parse actually allocate?" — the
//! question `/usr/bin/time` can't, because Twig's CLI runs on an arena that
//! turns per-node `dupe`s into cheap bumps (so allocation *count* and process
//! RSS are decoupled). Wrap the real backing allocator, hand the result to a
//! parser, and read `.stats` afterward. Not thread-safe; a bench runs on one
//! thread by design.
//!
//! `bytes_live`/`bytes_peak` need the wrapped allocator to actually see the
//! `free`s — so wrap the *page/gpa* allocator, NOT an arena (an arena never
//! frees until `deinit`, so every `bytes_live` reads as a monotonic climb and
//! `bytes_peak` == `bytes_allocated`). Counts (`alloc_count` etc.) are
//! meaningful either way.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Stats = struct {
    /// Cumulative call counts (never decremented).
    alloc_count: usize = 0,
    resize_count: usize = 0,
    remap_count: usize = 0,
    free_count: usize = 0,

    /// Cumulative bytes ever handed out by `alloc` (ignores in-place grows).
    bytes_allocated: usize = 0,
    /// Cumulative bytes handed back to `free`.
    bytes_freed: usize = 0,

    /// Currently-outstanding bytes (alloc − free, adjusted by resize/remap).
    bytes_live: usize = 0,
    /// High-water mark of `bytes_live` across the run.
    bytes_peak: usize = 0,

    pub fn format(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            \\allocations : {d}
            \\resizes     : {d} (in-place grow/shrink, no new allocation)
            \\remaps      : {d}
            \\frees       : {d}
            \\bytes alloc : {d}
            \\bytes freed : {d}
            \\bytes peak  : {d} (live high-water mark)
        , .{
            self.alloc_count,
            self.resize_count,
            self.remap_count,
            self.free_count,
            self.bytes_allocated,
            self.bytes_freed,
            self.bytes_peak,
        });
    }
};

pub const CountingAllocator = struct {
    child: Allocator,
    stats: Stats = .{},

    pub fn init(child: Allocator) CountingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn bumpPeak(self: *CountingAllocator) void {
        if (self.stats.bytes_live > self.stats.bytes_peak)
            self.stats.bytes_peak = self.stats.bytes_live;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.stats.alloc_count += 1;
        self.stats.bytes_allocated += len;
        self.stats.bytes_live += len;
        self.bumpPeak();
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.stats.resize_count += 1;
        self.stats.bytes_live = self.stats.bytes_live - memory.len + new_len;
        self.bumpPeak();
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.stats.remap_count += 1;
        self.stats.bytes_live = self.stats.bytes_live - memory.len + new_len;
        self.bumpPeak();
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.stats.free_count += 1;
        self.stats.bytes_freed += memory.len;
        self.stats.bytes_live -= memory.len;
    }
};

test "counts a matched alloc/free pair and tracks peak" {
    var counter = CountingAllocator.init(std.testing.allocator);
    const a = counter.allocator();

    const buf = try a.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 1), counter.stats.alloc_count);
    try std.testing.expectEqual(@as(usize, 100), counter.stats.bytes_live);
    try std.testing.expectEqual(@as(usize, 100), counter.stats.bytes_peak);

    a.free(buf);
    try std.testing.expectEqual(@as(usize, 1), counter.stats.free_count);
    try std.testing.expectEqual(@as(usize, 0), counter.stats.bytes_live);
    // peak is a high-water mark: it survives the free.
    try std.testing.expectEqual(@as(usize, 100), counter.stats.bytes_peak);
}
