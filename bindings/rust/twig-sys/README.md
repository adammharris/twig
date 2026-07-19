# twig-sys

Low-level FFI bindings and the native static library for
[Twig](https://github.com/diaryx-org/twig) — the Djot / Markdown / HTML / XML
document engine.

This crate exists to build and link `libtwig.a` and to expose the raw C ABI
(`extern "C"` declarations and `#[repr(C)]` types). You almost certainly want
the safe, ergonomic wrapper instead:

```toml
twig-doc = "…"
```

## Building the native library

`build.rs` compiles the vendored Zig source with the `zig` toolchain. Prebuilt
static libraries are provided for common targets via per-target
`twig-sys-<target>` payload crates, so most consumers need **no** Zig toolchain
installed; the source build is used only as a fallback for targets without a
prebuilt library.

## License

MIT OR Apache-2.0
