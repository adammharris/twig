#!/usr/bin/env bash
#
# Build the prebuilt `libtwig.a` for one tier-1 target (by `key`, or `all`) and
# drop it into the matching `twig-sys-<key>/lib/` payload crate. Uses Zig's
# cross-compiler, so every target builds from a single host. Run before
# `cargo package`/publish of the payload crates (this is what CI does).
#
#   scripts/build-payload-lib.sh macos-arm64
#   scripts/build-payload-lib.sh all
#
# Env: TWIG_ZIG_ROOT overrides the Zig source root (defaults to the repo root).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"                 # bindings/rust
repo_root="$(cd "$root/../.." && pwd)"
zig_root="${TWIG_ZIG_ROOT:-$repo_root}"
table="$root/prebuilt-targets.tsv"
want="${1:-all}"

build_one() {
    local rust_target="$1" zig_target="$2" key="$3"
    local dir="$root/twig-sys-$key"
    local prefix
    prefix="$(mktemp -d)"

    echo "build-payload-lib: $key ($rust_target -> zig $zig_target)"
    zig build install-c-lib \
        -Doptimize=ReleaseFast \
        -Dcpu=baseline \
        -Dtarget="$zig_target" \
        --prefix "$prefix" \
        --build-file "$zig_root/build.zig"

    # Zig names the static library `twig.lib` on Windows, `libtwig.a` elsewhere.
    local name="libtwig.a"
    [[ "$rust_target" == *windows* ]] && name="twig.lib"
    local archive="$prefix/lib/$name"
    [ -f "$archive" ] || { echo "  ERROR: $archive not produced" >&2; exit 1; }

    # Apple's ld rejects static-archive members that aren't 8-byte aligned, and
    # Zig 0.16's archiver can emit an unaligned member. Repack apple archives
    # with `ar` (writes aligned members) at build time so the shipped archive
    # links cleanly with no repack needed on the consumer side.
    if [[ "$rust_target" == *apple* ]]; then
        local work; work="$(mktemp -d)"
        ( cd "$work" && ar x "$archive" && chmod u+rw ./*.o \
            && ar crs "$name" ./*.o )
        archive="$work/$name"
    fi

    mkdir -p "$dir/lib"
    cp "$archive" "$dir/lib/$name"
    echo "  -> $dir/lib/$name ($(du -h "$dir/lib/$name" | cut -f1))"
}

matched=0
while IFS=$'\t' read -r rust_target zig_target key cfg; do
    [[ "$rust_target" =~ ^#|^$ ]] && continue
    if [ "$want" = "all" ] || [ "$want" = "$key" ]; then
        build_one "$rust_target" "$zig_target" "$key"
        matched=1
    fi
done <"$table"

[ "$matched" = 1 ] || { echo "build-payload-lib: no target matched '$want'" >&2; exit 1; }
