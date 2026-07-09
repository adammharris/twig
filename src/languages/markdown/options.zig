//! `ParseOptions` — feature flags threaded through the block parser. Phase 1
//! (see `markdown.zig`'s module doc comment) implements only core
//! CommonMark block structure and a minimal inline subset; none of the
//! extensions these flags name are implemented yet, so none of them is
//! actually consulted anywhere in Phase 1's parser — there is no dispatch
//! point yet where an extension would shadow a core construct (e.g. task
//! lists, which shadow core bullet-list-item parsing, aren't recognized at
//! all yet; every bullet list parses as a plain `bullet_list` regardless of
//! this struct's `task_lists` flag). What Phase 1 DOES do is thread
//! `ParseOptions` all the way through (`Markdown.parse` -> `block.parse` ->
//! `Parser.init` -> `self.options`), so Phase 3 only has to add the actual
//! recognition logic at the appropriate dispatch points and read
//! `self.options.*` there, rather than also having to plumb a new parameter
//! through every layer from scratch.
//!
//! Defaults follow GFM-ish expectations (most extensions on) except `math`,
//! which is not part of GFM and stays opt-in.

const Options = @This();

tables: bool = true,
strikethrough: bool = true,
task_lists: bool = true,
autolinks: bool = true,
footnotes: bool = true,
definition_lists: bool = true,
frontmatter: bool = true,
/// Not part of GFM; off by default.
math: bool = false,

/// Strict CommonMark: every extension off. Use this to compare Phase 1's
/// output against the CommonMark spec's own test suite (`conformance.zig`
/// uses this preset).
pub const commonmark: Options = .{
    .tables = false,
    .strikethrough = false,
    .task_lists = false,
    .autolinks = false,
    .footnotes = false,
    .definition_lists = false,
    .frontmatter = false,
    .math = false,
};

/// GitHub-Flavored Markdown's extension set (tables/strikethrough/task
/// lists/autolinks on; footnotes/definition lists/math off — GFM proper
/// doesn't define those).
pub const gfm: Options = .{
    .tables = true,
    .strikethrough = true,
    .task_lists = true,
    .autolinks = true,
    .footnotes = false,
    .definition_lists = false,
    .frontmatter = false,
    .math = false,
};
