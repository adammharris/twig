#!/usr/bin/env bash
#
# Keep the project's version in one place. `build.zig.zon` is the single source
# of truth (it already drives the C ABI's twig_version); this propagates that
# version into the Rust workspace (bindings/rust/Cargo.toml, whose
# [workspace.package] version every crate inherits).
#
#   scripts/sync-version.sh           # write: copy zon version -> Cargo.toml
#   scripts/sync-version.sh --check   # verify they match; exit 1 if not (CI)
#
# Deliberately pure bash + sed so it runs identically on a dev box and a bare
# CI runner — no fig, cargo-edit, or other tooling required.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
zon="$root/build.zig.zon"
cargo="$root/bindings/rust/Cargo.toml"

check=false
[ "${1:-}" = "--check" ] && check=true

# Canonical version: the `.version = "x.y.z",` line in build.zig.zon.
version="$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)".*/\1/p' "$zon" | head -1)"
if [ -z "$version" ]; then
    echo "sync-version: could not read .version from $zon" >&2
    exit 1
fi

# Current version: the `version = "x.y.z"` line under [workspace.package].
current="$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$cargo" | head -1)"
if [ -z "$current" ]; then
    echo "sync-version: could not read version from $cargo" >&2
    exit 1
fi

# Internal-crate dependency versions live in [workspace.dependencies] as lines
# like `name = { path = "…", version = "x.y.z" }`. Every intra-workspace crate
# shares the one project version, so these must track it too (twig-doc ->
# twig-sys -> per-target payload crates all resolve by version at publish time).
# Any such line whose version != canonical is drift.
internal_drift="$(grep -n 'path = ".*version = "' "$cargo" \
    | grep -v "version = \"$version\"" || true)"

if [ "$check" = true ]; then
    if [ "$current" != "$version" ]; then
        echo "sync-version: version drift — build.zig.zon is $version but $cargo is $current." >&2
        echo "              Run scripts/sync-version.sh and commit the result." >&2
        exit 1
    fi
    if [ -n "$internal_drift" ]; then
        echo "sync-version: internal [workspace.dependencies] version drift (want $version):" >&2
        echo "$internal_drift" >&2
        echo "              Run scripts/sync-version.sh and commit the result." >&2
        exit 1
    fi
    echo "sync-version: in sync ($version)"
    exit 0
fi

if [ "$current" = "$version" ] && [ -z "$internal_drift" ]; then
    echo "sync-version: already in sync ($version)"
    exit 0
fi

# Portable in-place edit (works with both BSD/macOS and GNU sed). Two rewrites:
#   1. the [workspace.package] `version = "…"` (anchored at line start), and
#   2. the `version = "…"` inside each internal `{ path = "…", version = "…" }`
#      line in [workspace.dependencies].
tmp="$(mktemp)"
sed -e 's/^version = "[^"]*"/version = "'"$version"'"/' \
    -e 's/\(path = "[^"]*", version = "\)[^"]*"/\1'"$version"'"/' \
    "$cargo" > "$tmp"
mv "$tmp" "$cargo"
echo "sync-version: bindings/rust/Cargo.toml -> $version (package + internal deps)"
