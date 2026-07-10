//! Acceptance test: runs Phase 2's `parse` + the shared `Html` printer
//! against the vendored CommonMark spec test suite
//! (`testdata/commonmark-spec-0.31.2.json`, fetched from
//! `https://spec.commonmark.org/0.31.2/spec.json` — see this file's git log
//! for the exact vendoring commit if the upstream URL ever moves) and
//! reports a pass/total tally, broken down by spec section.
//!
//! This suite now passes in FULL — all 652 examples of CommonMark 0.31.2 —
//! so, like `languages/djot/conformance.zig`, it asserts zero failures. It
//! reached here through a RATCHET: `BASELINE` was pinned to the pass count
//! observed when each phase landed and the test asserted `passed >= BASELINE`,
//! so a regression in already-working parsing failed the build immediately
//! rather than being masked by "that extension isn't done yet anyway". With
//! `BASELINE` now at the full total, `passed >= BASELINE` is equivalent to
//! zero failures; the categorization below is retained as living diagnostics
//! (and to catch any future regression by section). Keep it at the total.
//!
//! Failures are cheaply bucketed into three categories, printed as counts
//! (this categorization — not the raw pass/fail number — is the real
//! intel: it tells future phases what kind of work closes the gap):
//!   - `inline_not_yet`: the expected output uses a construct
//!     (`<em>`/`<strong>`/`<a `/`<img `, or unescaped `<...>` markup) that
//!     the ACTUAL output shows no sign of recognizing either — see
//!     `categorize`'s doc comment for why this checks `actual` too, not
//!     just `expected`. As of Phase 2 this should be small (GFM extended
//!     autolinks are the main remaining gap, deferred to Phase 3).
//!   - `rendering_divergence`: the parse is plausibly structurally right
//!     (the actual output's HTML tags substantially overlap the expected
//!     one's — see `tagOverlapRatio`) but doesn't match byte-for-byte,
//!     suggesting a shared-printer rendering-convention mismatch (e.g. list
//!     tight/loose whitespace, percent-encoding of destinations, `"`-in-text
//!     escaping) rather than a parsing bug. Where a convention genuinely
//!     differs between formats — CommonMark's XHTML void self-close (`<br />`)
//!     and `src`-before-`alt` image attributes vs djot's HTML forms — the fix
//!     is a per-caller flag on the shared printer's `RenderOptions`
//!     (`Html.commonmark_render_options`), NOT a global edit that would
//!     regress djot; this runner renders through those options. It still never
//!     silently mutates the shared printer's defaults to chase a divergence.
//!   - `other`: neither of the above; most likely a genuine parsing gap or
//!     bug (as of Phase 2, this is 0 against the vendored suite).

const std = @import("std");
const Allocator = std.mem.Allocator;
const markdown = @import("markdown.zig");
const Html = @import("../html/html.zig");
const options_mod = @import("options.zig");

const spec_json = @embedFile("testdata/commonmark-spec-0.31.2.json");

/// Ratchet floor (see this file's module doc comment): now the FULL suite,
/// 652/652 of CommonMark 0.31.2. The climb from the Phase 2 baseline of 496:
///   - `Html.commonmark_render_options`: XHTML void self-close +
///     `src`-before-`alt` image attributes, text `"`→`&quot;` escaping, and
///     URL percent-encoding of link/image/autolink destinations — CommonMark
///     render conventions the shared printer applies for markdown but not djot
///     (Images, Thematic/Hard/Setext breaks, Links, Link-ref-defs, inline text).
///   - CommonMark tight/loose lists: `commonmark_lists` `<li>` rendering,
///     `self.tight` no longer leaking into a nested blockquote, blank lines
///     interior to a fenced/HTML leaf not arming looseness, a blank marking
///     only the *deepest* open list loose, blanks scoped inside a nested
///     blockquote arming nothing, and the "at most one leading blank" empty-item
///     rule (whole Lists + List-items sections).
///   - Emphasis: delimiter-stack leftover re-matches an earlier opener
///     (`*foo *bar**`), and Unicode Symbol categories in the flanking table.
///   - HTML5-aligned inline comment grammar, stripping leading ref definitions
///     before a setext underline, and Unicode simple case-folding of reference
///     labels (Greek/Cyrillic/Latin-1/sharp-s).
///   - The column model: a partial-tab `Cursor` (`spent`) so a tab straddling
///     a container prefix materializes its leftover columns as content spaces
///     (ex5/6/7), and list-item continuation indent stored RELATIVE to the
///     parent's content start rather than as an absolute column, so a nested
///     blockquote's varying prefix width resolves correctly (ex259/260).
/// `other` is 0 and every section is complete. Keep this at 652 — a drop means
/// a real regression in a construct that used to parse.
pub const BASELINE: usize = 652;

const SpecExample = struct {
    markdown: []const u8,
    html: []const u8,
    example: u32,
    start_line: u32,
    end_line: u32,
    section: []const u8,
};

pub const Category = enum { inline_not_yet, rendering_divergence, other };

pub const CategoryCounts = struct {
    inline_not_yet: usize = 0,
    rendering_divergence: usize = 0,
    other: usize = 0,
};

pub const SectionStat = struct {
    name: []const u8,
    passed: usize = 0,
    total: usize = 0,
};

pub const Summary = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
};

/// A fully owned record of one failing case (`section`/`markdown`/`expected`
/// are duped rather than borrowed from the `std.json`-parsed spec, which is
/// freed before `run` returns; `actual` is already an owned
/// `Html.serializeAlloc` result) — mirrors `languages/djot/conformance.zig`'s
/// `Failure`.
pub const Failure = struct {
    example: u32,
    section: []const u8,
    category: Category,
    markdown: []const u8,
    expected: []const u8,
    actual: []const u8,

    pub fn deinit(self: Failure, allocator: Allocator) void {
        allocator.free(self.section);
        allocator.free(self.markdown);
        allocator.free(self.expected);
        allocator.free(self.actual);
    }
};

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, haystack, n) != null) return true;
    }
    return false;
}

/// Extract lowercase tag names (duplicates kept, closing-slash ignored) from
/// `html`, e.g. `<p>a<em>b</em></p>` -> `{"p","em","em","p"}`.
fn extractTags(allocator: Allocator, html: []const u8) Allocator.Error![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            var j = i + 1;
            if (j < html.len and html[j] == '/') j += 1;
            const name_start = j;
            while (j < html.len and (std.ascii.isAlphanumeric(html[j]))) j += 1;
            if (j > name_start) try out.append(allocator, html[name_start..j]);
            i = j;
        } else i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// A cheap structural-similarity signal: the fraction of tag occurrences in
/// `expected` also found (as a multiset intersection) in `actual`.
fn tagOverlapRatio(allocator: Allocator, expected: []const u8, actual: []const u8) Allocator.Error!f64 {
    const exp_tags = try extractTags(allocator, expected);
    defer allocator.free(exp_tags);
    const act_tags = try extractTags(allocator, actual);
    defer allocator.free(act_tags);
    if (exp_tags.len == 0) return if (act_tags.len == 0) 1.0 else 0.0;

    var used = try allocator.alloc(bool, act_tags.len);
    defer allocator.free(used);
    @memset(used, false);

    var matched: usize = 0;
    for (exp_tags) |et| {
        for (act_tags, 0..) |at, idx| {
            if (!used[idx] and std.mem.eql(u8, et, at)) {
                used[idx] = true;
                matched += 1;
                break;
            }
        }
    }
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(exp_tags.len));
}

fn categorize(allocator: Allocator, expected: []const u8, actual: []const u8) Allocator.Error!Category {
    // `inline_not_yet` means "the construct never got recognized at all",
    // so it must ALSO be absent from `actual` -- checking `expected` alone
    // (Phase 1's original heuristic, back when none of these tags could
    // possibly appear in `actual`) would now misclassify a Phase-2 case
    // like an `<img>` that parsed correctly but renders with different
    // attribute order/self-closing syntax as "not yet implemented" instead
    // of the `rendering_divergence` it actually is.
    const inline_tags = &.{ "<em>", "<strong>", "<a>", "<a ", "<img>", "<img " };
    if (containsAny(expected, inline_tags) and !containsAny(actual, inline_tags)) return .inline_not_yet;
    // Autolinks (`<https://...>`) and raw inline HTML (`<a><bab>`) are also
    // Phase 2 (see `inline.zig`'s module doc comment); when NOT recognized,
    // a bare `<...>` passes through as literal text, which the printer then
    // HTML-escapes to `&lt;...&gt;`. When the SPEC expects that same `<`
    // literally (unescaped, i.e. real markup) but our output escaped it,
    // that's the same "not yet" gap even though it isn't one of the tag
    // names above.
    if (std.mem.indexOf(u8, actual, "&lt;") != null and std.mem.indexOf(u8, expected, "&lt;") == null and
        std.mem.indexOfScalar(u8, expected, '<') != null) return .inline_not_yet;
    const ratio = try tagOverlapRatio(allocator, expected, actual);
    if (ratio > 0.6) return .rendering_divergence;
    return .other;
}

pub const RunResult = struct {
    summary: Summary,
    categories: CategoryCounts,
    sections: std.ArrayList(SectionStat),

    pub fn deinit(self: *RunResult, allocator: Allocator) void {
        for (self.sections.items) |s| allocator.free(s.name);
        self.sections.deinit(allocator);
    }
};

pub fn run(allocator: Allocator, max_failures: usize, failures: *std.ArrayList(Failure)) !RunResult {
    var parsed = try std.json.parseFromSlice([]const SpecExample, allocator, spec_json, .{});
    defer parsed.deinit();

    var summary: Summary = .{};
    var categories: CategoryCounts = .{};
    var sections = std.ArrayList(SectionStat).empty;
    errdefer sections.deinit(allocator);

    for (parsed.value) |ex| {
        summary.total += 1;

        var section_idx: ?usize = null;
        for (sections.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.name, ex.section)) {
                section_idx = i;
                break;
            }
        }
        if (section_idx == null) {
            section_idx = sections.items.len;
            // `ex.section` is a slice of the `std.json`-parsed spec, which
            // `run` frees (`defer parsed.deinit()` above) before returning
            // — dupe it so `RunResult.sections` stays valid for the caller.
            try sections.append(allocator, .{ .name = try allocator.dupe(u8, ex.section) });
        }
        const sec = &sections.items[section_idx.?];
        sec.total += 1;

        var doc = markdown.parse(allocator, ex.markdown, options_mod.commonmark) catch {
            summary.failed += 1;
            categories.other += 1;
            if (failures.items.len < max_failures) {
                try failures.append(allocator, .{
                    .example = ex.example,
                    .section = try allocator.dupe(u8, ex.section),
                    .category = .other,
                    .markdown = try allocator.dupe(u8, ex.markdown),
                    .expected = try allocator.dupe(u8, ex.html),
                    .actual = try allocator.dupe(u8, "<parse error>"),
                });
            }
            continue;
        };
        defer doc.deinit();

        const rendered = try Html.serializeAllocOpts(allocator, &doc.ast, null, Html.commonmark_render_options);
        if (std.mem.eql(u8, rendered, ex.html)) {
            summary.passed += 1;
            sec.passed += 1;
            allocator.free(rendered);
        } else {
            summary.failed += 1;
            const cat = try categorize(allocator, ex.html, rendered);
            switch (cat) {
                .inline_not_yet => categories.inline_not_yet += 1,
                .rendering_divergence => categories.rendering_divergence += 1,
                .other => categories.other += 1,
            }
            if (failures.items.len < max_failures) {
                try failures.append(allocator, .{
                    .example = ex.example,
                    .section = try allocator.dupe(u8, ex.section),
                    .category = cat,
                    .markdown = try allocator.dupe(u8, ex.markdown),
                    .expected = try allocator.dupe(u8, ex.html),
                    .actual = rendered,
                });
            } else {
                allocator.free(rendered);
            }
        }
    }

    return .{ .summary = summary, .categories = categories, .sections = sections };
}

test "CommonMark 0.31.2 spec conformance (full)" {
    const allocator = std.testing.allocator;
    var failures = std.ArrayList(Failure).empty;
    defer failures.deinit(allocator);
    var result = try run(allocator, 0, &failures);
    defer result.deinit(allocator);

    std.debug.print(
        "\nmarkdown conformance: {d}/{d} passed ({d} failed)\n",
        .{ result.summary.passed, result.summary.total, result.summary.failed },
    );
    std.debug.print(
        "  failure categories: inline-not-yet={d} rendering-divergence={d} other={d}\n",
        .{ result.categories.inline_not_yet, result.categories.rendering_divergence, result.categories.other },
    );
    std.debug.print("  by section:\n", .{});
    for (result.sections.items) |s| {
        std.debug.print("    {s:<40} {d}/{d}\n", .{ s.name, s.passed, s.total });
    }

    // Full conformance: the ratchet floor is the whole suite, so this is
    // equivalent to zero failures -- asserted explicitly for a clearer message.
    try std.testing.expect(result.summary.passed >= BASELINE);
    try std.testing.expectEqual(@as(usize, 0), result.summary.failed);
}
