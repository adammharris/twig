# twig-sys-windows-x64-msvc

Prebuilt `libtwig.a` for `x86_64-pc-windows-msvc`, letting `twig-sys` link Twig's
native library on this target **without a Zig toolchain**.

This is an implementation detail of [`twig-sys`](https://crates.io/crates/twig-sys)
and [`twig-doc`](https://crates.io/crates/twig-doc). You should not depend on it
directly; `twig-sys` pulls in the right payload crate automatically for your
target.

## License

MIT OR Apache-2.0
