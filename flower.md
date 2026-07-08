```fig
title = flower
author = adammharris
created = 2026-07-07T17:27:37-06:00
```

# Flower

A sister project to [`fig`](https://github.com/adammharris/fig).
While `fig` parses configuration files like JSON, YAML, and TOML,
Flower parses **document** files, like HTML, Markdown, and Djot.

In this way, Flower is comparable to [Pandoc](https://pandoc.org),
but Flower has different design goals:

- In Flower, the goal isn't just to be a converter,
  but to expose the abstract syntax tree of a document,
  so that precise operations can be performed on it,
  similarly to how `fig` allows editing of config files.

- Flower doesn't plan to support citations or bibliographies,
  at least not directly.

- Flower intends to primarily support "round-trippable" formats,
  which excludes not-editable documents such as PDF.

# Status

No code yet.