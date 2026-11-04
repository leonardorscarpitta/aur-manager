# AUR Manager

A small AUR helper for Arch Linux written in Bash.

<p>
  <img src="https://img.shields.io/badge/shell-bash-4eaa25" alt="Bash">
  <img src="https://img.shields.io/badge/platform-Arch%20Linux-1793d1" alt="Arch Linux">
</p>

## Requirements

`bash`, `curl`, `jq`, `git` and `base-devel` (`makepkg`, `vercmp`).

## Usage

```
./aur.sh search <term>      # -s  search the AUR, sorted by popularity
./aur.sh info <pkg>         # -i  package details
./aur.sh install <pkg>...   # -S  build and install, resolving AUR dependencies
./aur.sh update             # -u  upgrade installed AUR packages
./aur.sh list               # -l  installed foreign packages
./aur.sh clean              # -c  remove the build cache
```

## How it works

- Queries the [AUR RPC v5 API](https://wiki.archlinux.org/title/Aurweb_RPC_interface) with `curl` and parses it with `jq`.
- Package repos are cloned into `${XDG_CACHE_HOME:-~/.cache}/aur/<pkg>` and built with `makepkg -si`.
- Dependencies that aren't installed and aren't in the official repos are treated as AUR packages and built first (installed with `--asdeps`).
- Updates compare `pacman -Qm` versions against the AUR with `vercmp`, using a single RPC request.

## Security

- Every PKGBUILD is shown in `$PAGER` before building. On updates, only the diff since the last build is shown.
- Nothing is built until you confirm.
- Package names are validated before they are used in URLs or paths.
- Refuses to run as root. `makepkg` calls `sudo` only for the install step.

## Limitations

- VCS packages (`-git`, `-svn`, …) aren't detected as outdated, because their AUR version only changes when the PKGBUILD changes.
- Virtual dependencies only provided by AUR packages have to be installed manually.
