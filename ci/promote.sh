#!/bin/bash
# ci/promote.sh -- copy the current [omartix-testing] snapshot for one arch to
# [omartix], the stable channel.
#
#   ARCH=aarch64 ci/promote.sh
#
# Stable is never built: it is always exactly a testing snapshot that someone
# chose to promote. The database is copied as-is and only renamed (pacman reads
# the repo name from pacman.conf, not from inside the db, and the signature
# covers the content, so the .sig stays valid). Every package and .sig the
# testing db lists is copied; anything else in the stable release is removed
# afterwards, so a stable box never sees a db pointing at a missing file.
set -euo pipefail
ARCH=${ARCH:?set ARCH}
FROM=omartix-testing
TO=omartix
FROM_TAG=$FROM-$ARCH
TO_TAG=$TO-$ARCH
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

gh release download "$FROM_TAG" -D "$work/in" -p "$FROM.db" -p "$FROM.db.sig" -p "$FROM.files" -p "$FROM.files.sig"
[[ -s $work/in/$FROM.db.sig ]] || { echo "::error::$FROM_TAG has no signed database; refusing to promote" >&2; exit 1; }

# EXPECT ("aarch64=<sha256>,x86_64=<sha256>") pins the testing snapshot the
# promoter actually tried. A build that lands between their check and this run
# changes the db, and promoting it would ship something nobody ran.
want=$(tr ',' '\n' <<<"${EXPECT:-}" | sed -n "s/^[[:space:]]*$ARCH=//p")
if [[ -n $want ]]; then
  got=$(sha256sum "$work/in/$FROM.db" | cut -d' ' -f1)
  [[ $got == "$want" ]] || { echo "::error::$FROM_TAG changed since it was checked (db $got, expected $want); refusing to promote" >&2; exit 1; }
  echo "testing db matches the checked snapshot ($got)"
fi

mkdir -p "$work/db" "$work/out"
tar -xf "$work/in/$FROM.db" -C "$work/db"
mapfile -t files < <(sed -n '/^%FILENAME%$/{n;p}' "$work"/db/*/desc | sort -u)
(( ${#files[@]} )) || { echo "::error::$FROM_TAG lists no packages" >&2; exit 1; }

for f in "${files[@]}"; do
  gh release download "$FROM_TAG" -D "$work/out" -p "$f" -p "$f.sig"
done
for k in db files; do
  for s in "" .sig; do
    cp "$work/in/$FROM.$k$s" "$work/out/$TO.$k$s"
    cp "$work/in/$FROM.$k$s" "$work/out/$TO.$k.tar.gz$s"
  done
done

gh release view "$TO_TAG" >/dev/null 2>&1 || gh release create "$TO_TAG" \
  --title "omartix ($ARCH)" --latest=false \
  --notes "pacman repo [omartix] (stable) for $ARCH. Server = https://github.com/${GITHUB_REPOSITORY:-clutchboi556/omarchy-artix-pkgs}/releases/download/omartix-\$arch"

# Packages first, the database last, then remove what the new db no longer lists.
shopt -s nullglob
pkgs=("$work"/out/*.pkg.tar.*)
(( ${#pkgs[@]} )) && gh release upload "$TO_TAG" "${pkgs[@]}" --clobber
gh release upload "$TO_TAG" "$work"/out/$TO.* --clobber
keep=$(cd "$work/out" && ls)
gh release view "$TO_TAG" --json assets --jq '.assets[].name' | while read -r a; do
  grep -qxF -- "$a" <<<"$keep" && continue
  gh release delete-asset "$TO_TAG" "$a" --yes && echo "removed $a"
done
echo "promoted ${#files[@]} package(s) from $FROM_TAG to $TO_TAG"
