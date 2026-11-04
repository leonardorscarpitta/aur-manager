# AUR Manager

A small AUR helper for Arch Linux written in Bash.

<p>
  <img src="https://img.shields.io/badge/shell-bash-4eaa25" alt="Bash">
  <img src="https://img.shields.io/badge/platform-Arch%20Linux-1793d1" alt="Arch Linux">
</p>

## Requirements

`bash`, `curl`, `jq`, `git` and `base-devel` (`makepkg`, `vercmp`).

```
sudo pacman -S --needed bash curl jq git base-devel
```

## Install

Download the script straight into your `PATH` as `aur`.

For your user only (`~/.local/bin` must be in your `PATH`):

```
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/leonardorscarpitta/aur-manager/develop/aur.sh -o ~/.local/bin/aur
chmod +x ~/.local/bin/aur
```

For all users:

```
sudo curl -fsSL https://raw.githubusercontent.com/leonardorscarpitta/aur-manager/develop/aur.sh -o /usr/local/bin/aur
sudo chmod +x /usr/local/bin/aur
```

Then run `aur help`. To update the script itself, run the same commands again.

For development, clone the repo instead:

```
git clone git@github.com:leonardorscarpitta/aur-manager.git
cd aur-manager
./aur.sh help
```

## Usage

```
aur <term>             #     shortcut for search
aur search <term>      # -s  search the AUR, sorted by popularity
aur info <pkg>         # -i  package details
aur install <pkg>...   # -S  build and install, resolving AUR dependencies
aur update             # -u  upgrade installed AUR packages
aur list               # -l  installed foreign packages
aur clean              # -c  remove the build cache
```

Output is coloured when writing to a terminal. Set `NO_COLOR=1` to turn colours off.

## How it works

- Queries the [AUR RPC v5 API](https://wiki.archlinux.org/title/Aurweb_RPC_interface) with `curl` and parses it with `jq`. A spinner shows while requests are in flight.
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
