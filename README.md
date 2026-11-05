# AUR Manager

A small package manager front end for Arch Linux written in Bash. It handles the official repos (core, extra, multilib, …) and the AUR in one place.

<p>
  <img src="https://img.shields.io/badge/shell-bash-4eaa25" alt="Bash">
  <img src="https://img.shields.io/badge/platform-Arch%20Linux-1793d1" alt="Arch Linux">
</p>

## Requirements

`bash`, `curl`, `jq`, `git` and `base-devel` (`makepkg`, `vercmp`, `sudo`).

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

Then run `aur -h`. To update the script itself, run the same commands again.

For development, clone the repo instead:

```
git clone git@github.com:leonardorscarpitta/aur-manager.git
cd aur-manager
./aur.sh -h
```

## Usage

```
aur <term>                    # search and pick packages to install from a numbered list
aur -s, --search <term>       # search only
aur -i, --info <pkg>          # package details
aur -S, --install <pkg>...    # install from the official repos or the AUR
aur -R[ns], --remove <pkg>... # uninstall one or more packages
aur -u, --update              # pacman -Syu, then upgrade AUR packages
aur -l, --list                # installed AUR (foreign) packages
aur -c, --clean               # remove the build cache
aur -h, --help                # help
```

### Official repos and the AUR

By default every command covers both sources:

- **Search** lists official repo results first (`core/`, `extra/`, `multilib/`, …), then AUR results sorted by popularity, in one numbered list.
- **Install** sends packages found in the official repos to `sudo pacman -S --needed` and builds the rest from the AUR. If a name exists in both, the official repo wins. A prefix forces the source: `aur -S extra/neovim aur/yay`.
- **Info** shows `pacman -Si` for official packages and AUR details otherwise.
- **Update** runs `sudo pacman -Syu` first, then checks AUR packages.

- **Remove** works the same for both sources. `aur -R claude-code visual-studio-code linux` removes all three; if any of them isn't installed, nothing is removed. Add `n` and/or `s` to the flag in any order (`R` must appear exactly once). The flag is passed to `sudo pacman` as typed:

  | Flag              | pacman | Also removes                     |
  |-------------------|--------|----------------------------------|
  | `-R` / `--remove` | `-R`   | nothing else                     |
  | `-Rs`             | `-Rs`  | dependencies nothing else needs  |
  | `-Rn`             | `-Rn`  | saved config backups (`.pacsave`) |
  | `-Rns`, `-Rsn`, … | same   | both                             |

  Names must match exactly, so `aur -R sh` won't remove `bash` through its `provides`. Build files in the cache are kept; use `aur -c` to clear them.

Modifiers limit a command to one source and can go anywhere on the command line:

```
aur neovim -a        # search the AUR only
aur -r -u            # only pacman -Syu
aur -S foo --aur     # build foo from the AUR even if the official repos have it
```

### Selecting packages

`aur <term>` lists search results with numbers and asks which ones to install. That prompt only accepts numbers, ranges and commas (e.g. `2`, `1-3`, `1,4`), and Enter installs nothing. `aur -u` lists available updates the same way, and before building you're asked which PKGBUILDs to review:

```
==> 3 package(s) available to update:
    (1) brave-bin               1:1.98.62-1  →  1:1.98.63-1
    (2) claude-code             2.1.316-1    →  2.1.318-1
    (3) visual-studio-code-bin  1.105.0-1    →  1.106.0-1
:: Packages to update? [Enter = all, e.g. 1-2,4, n = none]
```

| Input   | Selects                                                           |
|---------|-------------------------------------------------------------------|
| Enter   | the default: every update, but no search results or PKGBUILD reviews |
| `a`     | everything (not available when installing from search)            |
| `n`     | nothing (not available when installing from search)               |
| `1-2`   | 1 and 2                                                           |
| `1,3`   | 1 and 3                                                           |
| `1-2,4` | ranges and numbers combined                                       |

Only flags are commands. Any other word is a search term, so `aur search` searches for packages named "search".

Output is coloured when writing to a terminal. Set `NO_COLOR=1` to turn colours off.

## How it works

- Official repos are queried with `pacman -Ss` / `pacman -Si` against your local sync databases. The script never runs `pacman -Sy` on its own, so it can't cause a partial upgrade.
- Queries the [AUR RPC v5 API](https://wiki.archlinux.org/title/Aurweb_RPC_interface) with `curl` and parses it with `jq`. While fetching, a spinner says what is being queried (`fetching from aur.archlinux.org...`, `searching core, extra, multilib...` from your `pacman.conf`). It stays up for at least 0.5s, fetch time included. It's only shown on a terminal, so scripts and pipes don't get the delay.
- Package repos are cloned into `${XDG_CACHE_HOME:-~/.cache}/aur/<pkg>` and built with `makepkg -si`.
- Dependencies that aren't installed and aren't in the official repos are treated as AUR packages and built first (installed with `--asdeps`).
- Updates compare `pacman -Qm` versions against the AUR with `vercmp`, using a single RPC request.

## Security

- Before building, you choose which PKGBUILDs to read in `$PAGER` (`a` for all). Pressing Enter skips the review, and you get a warning. On updates, only the diff since the last build is shown, and packages whose build files changed are marked `(changed)`.
- Nothing is built until you confirm.
- Package names are validated before they are used in URLs or paths.
- Refuses to run as root. `sudo` is only used for `pacman` (repo installs, `-Syu`, and makepkg's install step).

## Limitations

- VCS packages (`-git`, `-svn`, …) aren't detected as outdated, because their AUR version only changes when the PKGBUILD changes.
- Virtual dependencies only provided by AUR packages have to be installed manually.
