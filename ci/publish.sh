#!/bin/bash
# ci/publish.sh -- push what ci/build.sh staged to the rolling release named for
# the arch, which IS the pacman repo: Server = https://github.com/<repo>/releases/download/<arch>
#
# New files first, stale ones after, so the db never points at a missing file.
set -euo pipefail
OUT=${OUT:-out}
TAG=${ARCH:-$(uname -m)}

shopt -s nullglob
files=("$OUT"/publish/*)
if (( ${#files[@]} )); then
  gh release upload "$TAG" "${files[@]}" --clobber
fi
sort -u "$OUT/stale" | while read -r a; do
  [[ -n $a ]] || continue
  gh release delete-asset "$TAG" "$a" --yes 2>/dev/null && echo "removed $a" || true
done

if [[ -s $OUT/failed ]]; then
  echo "::error::did not build: $(tr '\n' ' ' <"$OUT/failed")"
  exit 1
fi
