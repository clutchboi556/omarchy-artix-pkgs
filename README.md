# omarchy-artix-pkgs

aarch64 builds, against [Armtix](https://armtix.artixlinux.org), of the packages
[omarchy-artix](https://github.com/clutchboi556/omarchy-artix) boxes need but
cannot get anywhere else: Omarchy's own apps that its package repo only ships
for x86_64: omasnap, omacalc, omacut, omawrite, tzupdate, asdcontrol, cliamp,
herdr, hyprland-preview-share-picker, pinta (with the .NET runtime it needs)
and localsend.

No AUR. `omarchy` entries build Omarchy's own recipes from
[omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs), which already
declare `aarch64`; `local` entries are recipes in `pkgbuilds/` here, used only
where omarchy's cannot be built (localsend: see its header). See `packages.txt`.

## How it works

- `.github/workflows/build.yml` runs on GitHub's native arm64 runners on every
  push and daily. `ci/build.sh` unpacks Armtix's dinit image (checksum
  verified), updates it, and builds with `makepkg` any package whose version
  is not already published.
- Packages are signed with the key in `keys/` and published to the rolling
  [`aarch64` release](../../releases/tag/aarch64), which is the pacman repo:

      Server = https://github.com/clutchboi556/omarchy-artix-pkgs/releases/download/aarch64

## Installing

Don't add the repo to `pacman.conf`. `omarchy-artix-repo` in omarchy-artix
installs named packages from it with `pacman -U`, trusting only the pinned
key, and offers their updates from `omarchy-artix-update`.

Signing key: `C2462E8089B725931A1EC502A583C277941807AB`
