```fig
title = Twig
author = adammharris
created = 2026-07-08T22:39:41-07:00
updated = 2026-07-08T22:40:04-07:00
```

# Twig

A sister project to [`fig`](https://github.com/adammharris/fig).
While `fig` parses configuration files like JSON, YAML, and TOML,
Twig parses **document** files, like HTML, Markdown, and Djot.

In this way, Twig is comparable to [Pandoc](https://pandoc.org),
but Twig has different design goals:

- In Twig, the goal isn't just to be a converter,
  but to expose the abstract syntax tree of a document,
  so that precise operations can be performed on it,
  similarly to how `fig` allows editing of config files.

- Twig doesn't plan to support citations or bibliographies,
  at least not directly.

- Twig intends to primarily support "round-trippable" formats,
  which excludes not-editable documents such as PDF.

# Status

The following languages are implemented:

- Djot (265/271 cases passing; the remaining 6 rely on an AST pretty-printer this project doesn't implement yet)
- Markdown (647/652 CommonMark tests passing; the remaining 5 are two column-model gaps — partial-tab expansion in code blocks, and block-quote-relative column tracking for nested list continuation)
- HTML (generic-markup parser + serializer; forgiving document-oriented tree construction)
