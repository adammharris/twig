//! Parser for `{...}` attribute blocks, implemented as an incremental state
//! machine. Ported from djot.js's `src/attributes.ts`.
//!
//! ```
//! attributes <- '{' whitespace* attribute (whitespace attribute)* whitespace* '}'
//! attribute  <- identifier | class | keyval
//! identifier <- '#' name
//! class      <- '.' name
//! name       <- (nonspace, nonpunctuation other than ':', '_', '-')+
//! keyval     <- key '=' val
//! key        <- (ASCII_ALPHANUM | ':' | '_' | '-')+
//! val        <- bareval | quotedval
//! bareval    <- (ASCII_ALPHANUM | ':' | '_' | '-')+
//! quotedval  <- '"' ([^"] | '\"')* '"'
//! ```
//!
//! `feed` is incremental: it may be called with successive slices of the
//! subject (e.g. one per continuation line of a multi-line block attribute,
//! or one per "special character" chunk from the inline scanner) and picks
//! up state across calls — needed because an attribute block can span
//! multiple lines. Every scanned token is emitted as an `Event` with the same
//! annotation vocabulary `block.zig`/`inline.zig`/`parser.zig` share (see
//! `event.zig`): `attr_id_marker`/`id`, `attr_class_marker`/`class`,
//! `key`/`attr_equal_marker`/`attr_quote_marker`/`value`, `attr_space`,
//! `comment`. Callers forward these events into the main stream verbatim.

const std = @import("std");
const Allocator = std.mem.Allocator;
const event = @import("event.zig");
const Event = event.Event;
const EventList = event.EventList;

const AttributeParser = @This();

subject: []const u8,
state: State = .start,
begin: ?usize = null,
lastpos: ?usize = null,
matches: EventList = .empty,

pub const Status = enum { done, fail, continue_ };
pub const FeedResult = struct { status: Status, position: usize };

const State = enum {
    start,
    scanning,
    scanning_id,
    scanning_class,
    scanning_key,
    scanning_value,
    scanning_bare_value,
    scanning_quoted_value,
    scanning_quoted_value_continuation,
    scanning_escaped,
    scanning_escaped_in_continuation,
    scanning_comment,
    fail,
    done,
};

pub fn init(subject: []const u8) AttributeParser {
    return .{ .subject = subject };
}

pub fn deinit(self: *AttributeParser, allocator: Allocator) void {
    self.matches.deinit(allocator);
}

fn byteAt(self: *const AttributeParser, pos: usize) u8 {
    return if (pos < self.subject.len) self.subject[pos] else 0;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == ':' or c == '-';
}

/// SCANNING_ID's allowed char set: anything but `][~!@#$%^&*(){}`,.<>\|=+/?`
/// or whitespace.
fn isIdChar(c: u8) bool {
    if (isSpace(c)) return false;
    return switch (c) {
        ']', '[', '~', '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '{', '}', '`', ',', '.', '<', '>', '\\', '|', '=', '+', '/', '?' => false,
        else => true,
    };
}

/// SCANNING_CLASS's allowed char set: word chars plus `_`, `-`, `:`.
fn isClassChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':';
}

fn addEvent(self: *AttributeParser, allocator: Allocator, start: usize, end: usize, annot: event.Annotation) Allocator.Error!void {
    try self.matches.append(allocator, .{ .start = @intCast(start), .end = @intCast(end), .annot = annot });
}

/// Feed the parser a slice of text from the subject, `[start, end]`
/// inclusive. Returns the resulting status and a position: for `.done`, the
/// position of the closing `}`; for `.fail`, the first unparseable position;
/// for `.continue_`, `end` (the caller should feed more input).
pub fn feed(self: *AttributeParser, allocator: Allocator, start: usize, end: usize) Allocator.Error!FeedResult {
    var pos = start;
    while (pos <= end) {
        self.state = try self.step(allocator, pos);
        switch (self.state) {
            .done => return .{ .status = .done, .position = pos },
            .fail => {
                self.lastpos = pos;
                return .{ .status = .fail, .position = pos };
            },
            else => {
                self.lastpos = pos;
                pos += 1;
            },
        }
    }
    return .{ .status = .continue_, .position = end };
}

fn step(self: *AttributeParser, allocator: Allocator, pos: usize) Allocator.Error!State {
    const c = self.byteAt(pos);
    switch (self.state) {
        .start => return if (c == '{') .scanning else .fail,
        .fail => return .fail,
        .done => return .done,

        .scanning => {
            if (c == '\n' or c == '\r') {
                return .scanning;
            } else if (c == ' ' or c == '\t') {
                try self.addEvent(allocator, pos, pos, .attr_space);
                return .scanning;
            } else if (c == '}') {
                return .done;
            } else if (c == '#') {
                self.begin = pos;
                try self.addEvent(allocator, pos, pos, .attr_id_marker);
                return .scanning_id;
            } else if (c == '%') {
                self.begin = pos;
                return .scanning_comment;
            } else if (c == '.') {
                self.begin = pos;
                try self.addEvent(allocator, pos, pos, .attr_class_marker);
                return .scanning_class;
            } else if (isKeyChar(c)) {
                self.begin = pos;
                return .scanning_key;
            } else {
                return .fail;
            }
        },

        .scanning_comment => {
            if (c == '%') {
                if (self.begin) |b| {
                    if (pos > b) try self.addEvent(allocator, b, pos, .comment);
                }
                return .scanning;
            } else if (c == '}') {
                return .done;
            } else {
                return .scanning_comment;
            }
        },

        .scanning_id => {
            if (isIdChar(c)) {
                return .scanning_id;
            } else if (c == '}') {
                if (self.begin) |b| {
                    if (self.lastpos) |lp| {
                        if (lp > b) try self.addEvent(allocator, b + 1, lp, .id);
                    }
                }
                self.begin = null;
                return .done;
            } else if (isSpace(c)) {
                if (self.begin) |b| {
                    if (self.lastpos) |lp| {
                        if (lp > b) try self.addEvent(allocator, b + 1, lp, .id);
                    }
                }
                if (!(c == '\r' or c == '\n')) try self.addEvent(allocator, pos, pos, .attr_space);
                self.begin = null;
                return .scanning;
            } else {
                return .fail;
            }
        },

        .scanning_class => {
            if (isClassChar(c)) {
                return .scanning_class;
            } else if (c == '}') {
                if (self.begin) |b| {
                    if (self.lastpos) |lp| {
                        if (lp > b) try self.addEvent(allocator, b + 1, lp, .class);
                    }
                }
                self.begin = null;
                return .done;
            } else if (isSpace(c)) {
                if (self.begin) |b| {
                    if (self.lastpos) |lp| {
                        if (lp > b) try self.addEvent(allocator, b + 1, lp, .class);
                    }
                }
                if (!(c == '\r' or c == '\n')) try self.addEvent(allocator, pos, pos, .attr_space);
                self.begin = null;
                return .scanning;
            } else {
                return .fail;
            }
        },

        .scanning_key => {
            if (c == '=' and self.begin != null and self.lastpos != null) {
                try self.addEvent(allocator, self.begin.?, self.lastpos.?, .key);
                try self.addEvent(allocator, pos, pos, .attr_equal_marker);
                self.begin = null;
                return .scanning_value;
            } else if (isKeyChar(c)) {
                return .scanning_key;
            } else {
                return .fail;
            }
        },

        .scanning_value => {
            if (c == '"') {
                self.begin = pos;
                try self.addEvent(allocator, pos, pos, .attr_quote_marker);
                return .scanning_quoted_value;
            } else if (isKeyChar(c)) {
                self.begin = pos;
                return .scanning_bare_value;
            } else {
                return .fail;
            }
        },

        .scanning_bare_value => {
            if (isKeyChar(c)) {
                return .scanning_bare_value;
            } else if (c == '}' and self.begin != null and self.lastpos != null) {
                try self.addEvent(allocator, self.begin.?, self.lastpos.?, .value);
                self.begin = null;
                return .done;
            } else if (isSpace(c) and self.begin != null and self.lastpos != null) {
                try self.addEvent(allocator, self.begin.?, self.lastpos.?, .value);
                if (!(c == '\r' or c == '\n')) try self.addEvent(allocator, pos, pos, .attr_space);
                self.begin = null;
                return .scanning;
            } else {
                return .fail;
            }
        },

        .scanning_escaped => return .scanning_quoted_value,
        .scanning_escaped_in_continuation => return .scanning_quoted_value_continuation,

        .scanning_quoted_value => {
            if (c == '"' and self.begin != null and self.lastpos != null) {
                try self.addEvent(allocator, self.begin.? + 1, self.lastpos.?, .value);
                try self.addEvent(allocator, pos, pos, .attr_quote_marker);
                self.begin = null;
                return .scanning;
            } else if (c == '\n' and self.begin != null) {
                try self.addEvent(allocator, self.begin.? + 1, pos, .value);
                self.begin = null;
                return .scanning_quoted_value_continuation;
            } else if (c == '\\') {
                return .scanning_escaped;
            } else {
                return .scanning_quoted_value;
            }
        },

        .scanning_quoted_value_continuation => {
            if (self.begin == null) self.begin = pos;
            if (c == '"' and self.lastpos != null) {
                try self.addEvent(allocator, pos, pos, .attr_quote_marker);
                try self.addEvent(allocator, self.begin.?, self.lastpos.?, .value);
                self.begin = null;
                return .scanning;
            } else if (c == '\n' and self.lastpos != null) {
                try self.addEvent(allocator, self.begin.?, pos, .value);
                self.begin = null;
                return .scanning_quoted_value_continuation;
            } else if (c == '\\') {
                return .scanning_escaped_in_continuation;
            } else {
                return .scanning_quoted_value_continuation;
            }
        },
    }
}

const testing = std.testing;

fn parseAll(subject: []const u8) !AttributeParser {
    var p = AttributeParser.init(subject);
    const res = try p.feed(testing.allocator, 0, subject.len - 1);
    try testing.expectEqual(Status.done, res.status);
    return p;
}

test "parses classes, id, and bare/quoted keyvals" {
    var p = try parseAll("{.foo #bar key=\"val\" other=baz}");
    defer p.deinit(testing.allocator);

    var found_class = false;
    var found_id = false;
    var found_key_val = false;
    var found_key_other = false;
    var i: usize = 0;
    while (i < p.matches.items.len) : (i += 1) {
        const m = p.matches.items[i];
        const text = p.subject[m.start .. m.end + 1];
        switch (m.annot) {
            .class => {
                try testing.expectEqualStrings("foo", text);
                found_class = true;
            },
            .id => {
                try testing.expectEqualStrings("bar", text);
                found_id = true;
            },
            .key => {
                if (std.mem.eql(u8, text, "key")) found_key_val = true;
                if (std.mem.eql(u8, text, "other")) found_key_other = true;
            },
            else => {},
        }
    }
    try testing.expect(found_class);
    try testing.expect(found_id);
    try testing.expect(found_key_val);
    try testing.expect(found_key_other);
}

test "multi-line quoted value continuation" {
    const subject = "{key=\"a\nb\"}";
    var p = AttributeParser.init(subject);
    defer p.deinit(testing.allocator);
    const res = try p.feed(testing.allocator, 0, subject.len - 1);
    try testing.expectEqual(Status.done, res.status);

    var values = std.ArrayList([]const u8).empty;
    defer values.deinit(testing.allocator);
    for (p.matches.items) |m| {
        if (m.annot == .value) try values.append(testing.allocator, subject[m.start .. m.end + 1]);
    }
    try testing.expectEqual(@as(usize, 2), values.items.len);
    // The first slice's span deliberately includes the newline itself
    // (matching djot.js's `addEvent(begin + 1, pos, "value")`, where `pos`
    // is the newline's own position) -- whitespace collapsing happens later,
    // in parser.zig's `value` handler.
    try testing.expectEqualStrings("a\n", values.items[0]);
    try testing.expectEqualStrings("b", values.items[1]);
}

test "empty id name is dropped silently, but truly malformed input fails" {
    const subject = "{.foo #}";
    var p = AttributeParser.init(subject);
    defer p.deinit(testing.allocator);
    const res = try p.feed(testing.allocator, 0, subject.len - 1);
    // '#' followed directly by '}' with no name in between: id has zero
    // length so it's just silently dropped, and '}' finishes the block
    // successfully -- this mirrors djot.js exactly (no name is not a parse
    // failure, just an empty attribute). Assert accordingly.
    try testing.expectEqual(Status.done, res.status);

    const subject2 = "{.foo )bar}";
    var p2 = AttributeParser.init(subject2);
    defer p2.deinit(testing.allocator);
    const res2 = try p2.feed(testing.allocator, 0, subject2.len - 1);
    try testing.expectEqual(Status.fail, res2.status);
}

test "incremental feed across chunk boundaries" {
    const subject = "{.a\n.b}";
    var p = AttributeParser.init(subject);
    defer p.deinit(testing.allocator);
    // Feed line by line, like block.zig would for a multi-line block
    // attribute.
    var res = try p.feed(testing.allocator, 0, 2); // "{.a"
    try testing.expectEqual(Status.continue_, res.status);
    res = try p.feed(testing.allocator, 3, 3); // "\n"
    try testing.expectEqual(Status.continue_, res.status);
    res = try p.feed(testing.allocator, 4, subject.len - 1); // ".b}"
    try testing.expectEqual(Status.done, res.status);

    var classes: usize = 0;
    for (p.matches.items) |m| {
        if (m.annot == .class) classes += 1;
    }
    try testing.expectEqual(@as(usize, 2), classes);
}
