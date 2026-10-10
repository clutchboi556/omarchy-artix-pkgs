# omarchy-artix-pkgs

Builds of the packages [omarchy-artix](https://github.com/clutchboi556/omarchy-artix)
boxes need but cannot get anywhere else without the AUR:

- **aarch64**, against [Armtix](https://armtix.artixlinux.org): Omarchy's own
  apps that its package repo only ships for x86_64 -- omasnap, omacalc, omacut,
  omawrite, tzupdate, asdcontrol, cliamp, herdr, hyprland-preview-share-picker,
  pinta (with the .NET runtime it needs) and localsend.
- **both arches**, against Armtix and Artix: wayland-pipewire-idle-inhibit,
  without which the session locks during video.
- **aarch64**, from Arch Linux's official recipes with `aarch64` added: the
  packages in omarchy's list that Artix carries on x86_64 but Armtix lacks --
  bluez-tools, kernel-modules-hook, nautilus-python, usage.

No AUR. `omarchy` entries build Omarchy's own recipes from
[omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs), which already
declare `aarch64`; `arch` entries build Arch Linux's official recipes from
[archlinux/packaging](https://gitlab.archlinux.org/archlinux/packaging/packages);
`local` entries are recipes in `pkgbuilds/` here, used only where neither can
be built (see each recipe's header). See `packages.txt`.

## How it works

- `.github/workflows/build.yml` runs one job per arch, on GitHub's native
  runners, on every push and daily. `ci/build.sh` unpacks Armtix's dinit image
  (checksum verified) on aarch64, or Artix's `base-dinit` container image on
  x86_64, updates it, and builds with `makepkg` any package whose version is
  not already published. `packages.txt` says which arches each package is for.
- Packages are signed with the key in `keys/` and published to a rolling
  release per arch, which is the pacman repo:

      Server = https://github.com/clutchboi556/omarchy-artix-pkgs/releases/download/aarch64
      Server = https://github.com/clutchboi556/omarchy-artix-pkgs/releases/download/x86_64

## Installing

Don't add the repo to `pacman.conf`. `omarchy-artix-repo` in omarchy-artix
installs named packages from it with `pacman -U`, trusting only the pinned
key, and offers their updates from `omarchy-artix-update`.

Signing key: `C2462E8089B725931A1EC502A583C277941807AB`
