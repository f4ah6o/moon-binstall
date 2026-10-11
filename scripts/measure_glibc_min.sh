#!/usr/bin/env bash
# measure_glibc_min.sh <asset> <tag> <dest-dir>
#
# Prints the newest GLIBC_* symbol version the release asset requires, or
# nothing when the asset declares no GLIBC_* versions (for example a static
# or musl-linked build). Any download or inspection failure exits nonzero:
# a failed measurement must never masquerade as "no glibc requirement",
# which would stamp nothing and let an incompatible binary ship.
set -uo pipefail

asset="$1"
tag="$2"
dest_dir="${3:-/tmp}"

gh release download "$tag" -p "$asset" -O "$dest_dir/$asset" --clobber || exit 1

# Keep objdump's own exit status visible: masking it with a `| grep || true`
# pipeline would turn a broken binary/tool into an empty, "successful" result.
dump="$(objdump -T "$dest_dir/$asset")" || exit 1
printf '%s\n' "$dump" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -n1 | sed 's/^GLIBC_//' || true
