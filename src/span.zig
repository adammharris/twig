//! A helper struct for selecting parts of a slice — a byte range `[start, end)`
//! into the original source text. Mirrors fig's `src/util/span.zig`; kept here
//! (rather than under a `util/` directory) since Twig doesn't have enough
//! shared utilities yet to warrant one.

pub const Span = @This();

start: usize,
end: usize,

pub fn init(start: usize, end: usize) Span {
    return .{ .start = start, .end = end };
}

pub fn len(self: Span) usize {
    return self.end - self.start;
}

pub fn eql(self: Span, other: Span) bool {
    return self.start == other.start and self.end == other.end;
}

/// Take the span out of a slice.
pub fn of(comptime T: type, self: Span, slice: []const T) []const T {
    return slice[self.start..self.end];
}
