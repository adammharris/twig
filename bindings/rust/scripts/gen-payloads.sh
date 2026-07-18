#!/usr/bin/env bash
#
# Generate the per-target `twig-sys-<key>` payload crates from
# prebuilt-targets.tsv. Each payload crate carries a prebuilt `lib/libtwig.a`
# (produced separately by build-payload-lib.sh / CI, git-ignored) and a tiny
# build script that hands its location to `twig-sys` via `links` metadata.
#
# Idempotent: safe to re-run after editing the table. Does NOT touch lib/.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)" # bindings/rust
table="$root/prebuilt-targets.tsv"

while IFS=$'\t' read -r rust_target zig_target key cfg; do
    [[ "$rust_target" =~ ^#|^$ ]] && continue
    dir="$root/twig-sys-$key"
    underscored="${key//-/_}"
    links="twig_prebuilt_$underscored"
    libname="twig_sys_$underscored"
    # Zig names the static library `twig.lib` on Windows (MSVC/GNU) and
    # `libtwig.a` everywhere else. rustc's `-l static=twig` resolves either name
    # from the search dir, so we ship whichever Zig actually produced.
    if [[ "$rust_target" == *windows* ]]; then archive="twig.lib"; else archive="libtwig.a"; fi
    mkdir -p "$dir/src"

    cat >"$dir/Cargo.toml" <<EOF
[package]
name = "twig-sys-$key"
version.workspace = true
edition.workspace = true
license.workspace = true
description = "Prebuilt libtwig.a for $rust_target. Support crate for twig-sys; not for direct use."
repository = "https://github.com/adammharris/twig"
# The build script hands \`lib/libtwig.a\`'s location to \`twig-sys\` via this
# \`links\` key (as \`DEP_${links^^}_LIBDIR\`). Unique per payload crate.
links = "$links"
# Allowlist: the prebuilt archive plus the trivial crate skeleton. \`lib/\` is
# git-ignored and populated by scripts/build-payload-lib.sh (or CI) before publish.
include = ["build.rs", "src/lib.rs", "lib/$archive", "README.md"]

[lib]
name = "$libname"
path = "src/lib.rs"
EOF

    cat >"$dir/build.rs" <<'EOF'
// Hand the prebuilt archive's directory to `twig-sys`'s build script. Because
// this crate sets `links`, the `cargo:libdir=…` line below reaches dependents
// as `DEP_<LINKS>_LIBDIR`. This crate emits no link directives itself —
// `twig-sys` is the single place that decides to link the static library.
use std::env;
use std::path::Path;

fn main() {
    let manifest = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let libdir = Path::new(&manifest).join("lib");
    println!("cargo:libdir={}", libdir.display());
    println!("cargo:rerun-if-changed={}", libdir.display());
}
EOF

    cat >"$dir/src/lib.rs" <<EOF
//! Prebuilt \`libtwig.a\` for \`$rust_target\`.
//!
//! Support crate for [\`twig-sys\`](https://docs.rs/twig-sys); do not depend on
//! it directly. The archive is delivered to \`twig-sys\`'s build script through
//! this crate's \`links\` metadata (see \`build.rs\`); there is no Rust API here.
EOF

    cat >"$dir/README.md" <<EOF
# twig-sys-$key

Prebuilt \`libtwig.a\` for \`$rust_target\`, letting \`twig-sys\` link Twig's
native library on this target **without a Zig toolchain**.

This is an implementation detail of [\`twig-sys\`](https://crates.io/crates/twig-sys)
and [\`twig-doc\`](https://crates.io/crates/twig-doc). You should not depend on it
directly; \`twig-sys\` pulls in the right payload crate automatically for your
target.

## License

MIT OR Apache-2.0
EOF

    echo "gen-payloads: wrote twig-sys-$key ($rust_target)"
done <"$table"
