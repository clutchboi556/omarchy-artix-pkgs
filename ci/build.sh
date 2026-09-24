#!/bin/bash
# ci/build.sh -- build packages.txt for aarch64 inside a clean Armtix root and
# stage an updated pacman repo for ci/publish.sh.
#
# Runs as root on an aarch64 host (the GitHub ubuntu-24.04-arm runner). Inputs:
#   out/current/omarchy-artix.db.tar.gz   the published db, if there is one
#   PKG_SIGNING_KEY                        armored secret key (optional locally)
#   FORCE=true                             rebuild even when the version is published
# Outputs, in out/:
#   publish/   new packages + .sig, and the rebuilt db/files archives
#   stale      release assets that the new db no longer references
#   failed     packages that did not build (the job fails after publishing the rest)
#
# ⚠ WHY ARMTIX AND NOT AN ARCH LINUX ARM CONTAINER. The packages are linked
#   against whatever Qt, ffmpeg and tesseract the build root has. Build them
#   against a different distribution's versions and they install fine and then
#   fail to start on the uConsole. The root is Armtix's own dinit image, updated
#   to the current repos, so it matches what an updated box runs.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
ROOT=${ROOT:-/armtix}
OUT=${OUT:-$HERE/out}
# ⚠ armtix.artixlinux.org is behind Cloudflare, which answers GitHub's runners
#   with 403. armtixlinux.org serves the same images from plain nginx. Same for
#   the package mirrors below.
IMAGE_MIRRORS=(https://armtixlinux.org/images https://armtix.artixlinux.org/images)
PKG_MIRRORS=('https://repo.armtixlinux.org/$repo/os/$arch' 'https://armtix.artixlinux.org/repos/$repo/os/$arch')
REPO=omarchy-artix
OMARCHY_PKGS=https://github.com/omacom/omarchy-pkgs.git
PUBLISHED=https://github.com/${GITHUB_REPOSITORY:-clutchboi556/omarchy-artix-pkgs}/releases/download/aarch64

[[ $(uname -m) == aarch64 ]] || { echo "build.sh: needs an aarch64 host" >&2; exit 1; }
(( EUID == 0 )) || { echo "build.sh: run as root" >&2; exit 1; }
mkdir -p "$OUT/publish" "$OUT/current"
: >"$OUT/stale"; : >"$OUT/failed"

inroot() { chroot "$ROOT" /usr/bin/env -i PATH=/usr/bin HOME=/root LANG=C.UTF-8 TERM=dumb "$@"; }
asbuilder() { chroot "$ROOT" /usr/bin/env -i PATH=/usr/bin HOME=/home/builder LANG=C.UTF-8 TERM=dumb \
  /usr/bin/setpriv --reuid=builder --regid=builder --init-groups -- /bin/bash -c "$1"; }

# ── 1. the build root ──────────────────────────────────────────────────────
echo "::group::Armtix root"
if [[ ! -x $ROOT/usr/bin/pacman ]]; then
  for IMAGES in "${IMAGE_MIRRORS[@]}"; do
    line=$(curl -fsSL "$IMAGES/sha256sums" | grep -E ' armtix-dinit-[0-9]+\.tar\.xz$' | sort -k2 | tail -1) && break
  done
  [[ -n ${line:-} ]] || { echo "no Armtix image mirror answered" >&2; exit 1; }
  img=${line##* }
  echo "image: $IMAGES/$img"
  curl -fsSL --retry 3 -o "/tmp/$img" "$IMAGES/$img"
  (cd /tmp && sha256sum -c - <<<"$line")
  mkdir -p "$ROOT"
  tar -xpf "/tmp/$img" -C "$ROOT" --numeric-owner
  # Tolerate an image wrapped in one top-level directory.
  if [[ ! -e $ROOT/usr ]] && [[ $(ls "$ROOT" | wc -l) == 1 ]]; then
    sub=$ROOT/$(ls "$ROOT"); mv "$sub"/* "$sub"/.[!.]* "$ROOT"/ 2>/dev/null || true; rmdir "$sub"
  fi
fi
# The root must be a mount point itself: pacman's CheckSpace looks up the mount
# holding its cachedir and aborts with "not enough free disk space" when it
# cannot. arch-chroot does the same self-bind.
mountpoint -q "$ROOT" || mount --bind "$ROOT" "$ROOT"
for m in dev sys; do mountpoint -q "$ROOT/$m" || mount --rbind "/$m" "$ROOT/$m"; done
mountpoint -q "$ROOT/proc" || mount -t proc proc "$ROOT/proc"
# The runner's /etc/resolv.conf points at systemd-resolved's stub; the real
# upstream list works the same from inside the chroot.
rm -f "$ROOT/etc/resolv.conf"
cp -L /run/systemd/resolve/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"

printf 'Server = %s\n' "${PKG_MIRRORS[@]}" >"$ROOT/etc/pacman.d/mirrorlist"
inroot pacman-key --init >/dev/null
inroot pacman-key --populate >/dev/null 2>&1 || true
inroot pacman -Syu --noconfirm --needed base-devel git sudo
inroot id -u builder >/dev/null 2>&1 || inroot useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: /usr/bin/pacman' >"$ROOT/etc/sudoers.d/builder"
chmod 440 "$ROOT/etc/sudoers.d/builder"
sed -i "s/^#\?MAKEFLAGS=.*/MAKEFLAGS=\"-j$(nproc)\"/" "$ROOT/etc/makepkg.conf"
echo "::endgroup::"

# ── 2. what is published now ───────────────────────────────────────────────
declare -A PUBVER=() PUBFILE=()
db=$OUT/current/$REPO.db.tar.gz
if [[ -s $db ]]; then
  t=$(mktemp -d); tar -xf "$db" -C "$t"
  for desc in "$t"/*/desc; do
    n=$(sed -n '/^%NAME%$/{n;p}' "$desc")
    PUBVER[$n]=$(sed -n '/^%VERSION%$/{n;p}' "$desc")
    PUBFILE[$n]=$(sed -n '/^%FILENAME%$/{n;p}' "$desc")
  done
  rm -rf "$t"
fi

# ── 3. recipes ─────────────────────────────────────────────────────────────
echo "::group::recipes"
rm -rf "$ROOT/home/builder/build" /tmp/omarchy-pkgs
mkdir -p "$ROOT/home/builder/build"
git clone -q --depth 1 --branch master "$OMARCHY_PKGS" /tmp/omarchy-pkgs
echo "omarchy-pkgs at $(git -C /tmp/omarchy-pkgs rev-parse --short HEAD)"
wanted=()
while read -r src name; do
  [[ -z $src || $src == \#* ]] && continue
  dst=$ROOT/home/builder/build/$name
  case $src in
    omarchy) cp -a "/tmp/omarchy-pkgs/pkgbuilds/$name" "$dst" ;;
    local)   cp -a "$HERE/pkgbuilds/$name" "$dst" ;;
    *) echo "unknown source '$src' for $name" >&2; echo "$name" >>"$OUT/failed"; continue ;;
  esac
  wanted+=("$name")
done <"$HERE/packages.txt"
inroot chown -R builder:builder /home/builder/build
echo "::endgroup::"

# Dependencies that are themselves ours (pinta needs dotnet-core-bin's split
# packages) must be installable by `makepkg -s`, which only resolves from sync
# repos. Two repos inside the build root, never on a box: [localbuild] holds
# what this run built (so order in packages.txt is build order), and the
# published release holds everything built before.
mkdir -p "$ROOT/localrepo"
tar -czf "$ROOT/localrepo/localbuild.db.tar.gz" -T /dev/null
ln -sf localbuild.db.tar.gz "$ROOT/localrepo/localbuild.db"
if ! grep -q '^\[localbuild\]' "$ROOT/etc/pacman.conf"; then
  printf '\n[localbuild]\nSigLevel = Never\nServer = file:///localrepo\n' >>"$ROOT/etc/pacman.conf"
  if [[ -s $OUT/current/$REPO.db.tar.gz ]]; then
    printf '\n[%s]\nSigLevel = Never\nServer = %s\n' "$REPO" "$PUBLISHED" >>"$ROOT/etc/pacman.conf"
  fi
fi
inroot pacman -Sy --noconfirm >/dev/null

# ── 4. build what is new ───────────────────────────────────────────────────
built=()
wanted_pkgs=()   # every package name the recipes produce (split packages too)
for name in "${wanted[@]}"; do
  srcinfo=$(asbuilder "cd ~/build/$name && makepkg --printsrcinfo")
  field() { sed -n "s/^\t$1 = //p" <<<"$srcinfo" | head -1; }
  mapfile -t pkgs < <(sed -n 's/^pkgname = //p' <<<"$srcinfo")
  wanted_pkgs+=("${pkgs[@]}")
  # A split recipe (dotnet-core-bin) publishes under its package names, never
  # its base name, so compare against the first of them.
  ver=$(field pkgver)-$(field pkgrel); ep=$(field epoch); [[ -n $ep ]] && ver=$ep:$ver
  if [[ ${FORCE:-false} != true && ${PUBVER[${pkgs[0]}]:-} == "$ver" ]]; then
    echo "$name $ver: already published"
    continue
  fi
  echo "::group::$name ${PUBVER[${pkgs[0]}]:-(new)} -> $ver"
  if asbuilder "cd ~/build/$name && makepkg -s --noconfirm --cleanbuild --needed"; then
    built+=("$name")
    mapfile -t made < <(asbuilder "cd ~/build/$name && makepkg --packagelist")
    for f in "${made[@]}"; do [[ -f $ROOT$f ]] && cp "$ROOT$f" "$ROOT/localrepo/"; done
    inroot bash -c 'cd /localrepo && repo-add -q localbuild.db.tar.gz *.pkg.tar.*' >/dev/null
    inroot pacman -Sy --noconfirm >/dev/null
  else
    echo "::error::$name failed to build"
    echo "$name" >>"$OUT/failed"
  fi
  echo "::endgroup::"
done

# ── 5. sign, index, stage ──────────────────────────────────────────────────
mkdir -p "$ROOT/repo"; rm -f "$ROOT/repo"/*
[[ -s $db ]] && cp "$OUT/current/$REPO".{db,files}.tar.gz "$ROOT/repo/" 2>/dev/null || true
export GNUPGHOME=$(mktemp -d)
if [[ -n ${PKG_SIGNING_KEY:-} ]]; then
  gpg --batch --quiet --import <<<"$PKG_SIGNING_KEY"
  signer=$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr/{print $10; exit}')
fi
new=()
for name in "${built[@]}"; do
  # Ask makepkg where it put them: Armtix's makepkg.conf does not use the
  # PKGEXT/PKGDEST an Arch-shaped glob assumes (it found nothing).
  mapfile -t files < <(asbuilder "cd ~/build/$name && makepkg --packagelist")
  for f in "${files[@]}"; do
    f=$ROOT$f
    [[ -f $f ]] || continue
    [[ $f == *-debug-* ]] && continue
    # GitHub rewrites ':' in asset names, so an epoch'd package (asdcontrol is
    # 1:0.6.0) would be listed under a name that 404s. The name is only a
    # locator -- pacman and repo-add read the version from .PKGINFO -- so
    # publish it with '_' and let repo-add record that name.
    b=$(basename "$f"); b=${b//:/_}
    cp "$f" "$ROOT/repo/$b"
    [[ -z ${signer:-} ]] || gpg --batch --yes --detach-sign --local-user "$signer" --output "$ROOT/repo/$b.sig" "$ROOT/repo/$b"
    new+=("/repo/$b")
    old=${PUBFILE[$(tar -xOf "$f" .PKGINFO | sed -n 's/^pkgname = //p')]:-}
    if [[ -n $old && $old != "$b" ]]; then printf '%s\n%s.sig\n' "$old" "$old" >>"$OUT/stale"; fi
  done
done

# Anything published but no longer listed in packages.txt leaves the index.
gone=()
for n in "${!PUBVER[@]}"; do
  printf '%s\n' "${wanted_pkgs[@]}" | grep -qx "$n" && continue
  gone+=("$n"); printf '%s\n%s.sig\n' "${PUBFILE[$n]}" "${PUBFILE[$n]}" >>"$OUT/stale"
done

if (( ${#new[@]} || ${#gone[@]} )); then
  (( ${#new[@]} )) && inroot repo-add --quiet "/repo/$REPO.db.tar.gz" "${new[@]}"
  (( ${#gone[@]} )) && inroot repo-remove --quiet "/repo/$REPO.db.tar.gz" "${gone[@]}"
  # Release assets cannot be symlinks; publish the names pacman asks for as copies.
  for k in db files; do cp -L "$ROOT/repo/$REPO.$k.tar.gz" "$ROOT/repo/$REPO.$k.tmp"; rm -f "$ROOT/repo/$REPO.$k"; mv "$ROOT/repo/$REPO.$k.tmp" "$ROOT/repo/$REPO.$k"; done
  find "$ROOT/repo" -maxdepth 1 -type f ! -name "*.old" -exec cp -t "$OUT/publish/" {} +
fi
rm -rf "$GNUPGHOME"

echo "built: ${built[*]:-none}"
echo "removed: ${gone[*]:-none}"
echo "failed: $(tr '\n' ' ' <"$OUT/failed")"
