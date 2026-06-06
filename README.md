# emacs-mac-builder

A single, self-contained Bash pipeline that builds a **natively-compiled,
self-contained `Emacs.app`** for macOS from a *local Emacs git checkout* — and
deploys it to `~/Applications` with `emacs`/`emacsclient` on your `PATH`.

It is inspired by — but fully independent of — the
[d12frosted/emacs-plus](https://github.com/d12frosted/homebrew-emacs-plus)
project. It reads a `build.yml` in the same shape (so your icon and patch set stay
familiar), but it is **not** a Homebrew formula and has **no Homebrew-tap
dependency**: patches come from your `build.yml`, the icon is bundled in this repo.

## Philosophy

- **Build from a git ref, not a tarball.** You point it at a local Emacs checkout
  (typically your own fork tracking `master`) and it builds whatever `REF` you
  choose. Ideal for living on `master` and testing your own patches.
- **Never touch your working checkout.** Each build happens in an *isolated,
  detached `git worktree`* under a cache dir. Your source tree is never reset,
  patched, or dirtied.
- **Truly self-contained app.** Unlike a Homebrew keg (which splits files across a
  Unix prefix), everything — binaries, Lisp, `native-lisp`, info — lives *inside*
  `Emacs.app`. No `--prefix`, no `locallisppath`. The bundle is the install.
- **Reproducible, verified patches.** Every patch in `build.yml` is a local file or
  a URL, each pinned by `sha256` and verified before it's applied.
- **Native compilation, wired correctly.** AOT-compiles the full Lisp tree against
  Homebrew's `gcc`/`libgccjit`, and handles the fiddly macOS bits (eln relocation so
  `codesign` can seal the bundle, ad-hoc signing, `LSEnvironment`, etc.).
- **Debug/Release like an IDE.** A fast `DEBUG` mode (no optimization, no AOT,
  uncompressed Lisp) lives in its *own* worktree alongside the optimized release
  build, so switching between them never throws away the other's incremental state.

## Requirements

- **macOS** (developed on Apple Silicon).
- **Homebrew**, with `gcc` and `libgccjit` (for native compilation) plus the image
  / feature libraries Emacs links against: `gnutls librsvg little-cms2 tree-sitter
  webp sqlite zlib libxml2 jpeg gmp`.
- **GNU Make** (`gmake`).
- **`python3`** — `build.yml` is parsed by `scripts/build-config.py`; the script
  auto-provisions a venv with pinned PyYAML on first run.
- **Full Xcode** (not just the Command Line Tools) **if** `build.yml` sets an
  `icon:` — the icon is compiled with `actool`.
- **A local Emacs git checkout** to build from (see `EMACS_SRC_REPO` below).

## Quick start

```sh
# 1. Point the builder at your Emacs source checkout (a fork tracking master, say):
export EMACS_SRC_REPO="$HOME/src/emacs"

# 2. Create your build config (see below):
mkdir -p ~/.config/emacs-plus
$EDITOR ~/.config/emacs-plus/build.yml

# 3. Build + install the optimized app (~20 min the first time):
./build.sh

# -> ~/Applications/Emacs.app, plus ~/.local/bin/{emacs,emacsclient}
```

## Configuration — `build.yml`

Lives at `~/.config/emacs-plus/build.yml` by default (override with
`EMACS_PLUS_BUILD_CONFIG`). All keys are optional.

```yaml
# Application icon. Names a loose Icon Composer source in this repo,
# assets/icons/<name>.icon, compiled to Assets.car with actool.
icon: dragon-plus

# Patches applied to the source before configuring. Each entry is
# {name: {url, sha256}}. `url` is either a local path (starting with
# / ./ ../ or ~) or a remote URL (downloaded). Both are sha256-verified.
patches:
  - my-local-fix:
      url: ~/patches/my-local-fix.patch
      sha256: 0123...abcd
  - upstream-commit:
      url: https://github.com/emacs-mirror/emacs/commit/<sha>.patch
      sha256: 89ab...ef01

# Whether to bake your PATH into the app's Info.plist LSEnvironment so
# GUI-launched Emacs sees your shell PATH. Default: true.
inject_path: false
```

> **Note:** unlike the emacs-plus formula, the tap-backed shorthands (community
> patch names, tap/remote *icons*) are intentionally **not** supported — patches
> are always `{url, sha256}`, and the icon is a local `.icon` in `assets/icons/`.
> Pin patch URLs to a commit SHA (not a moving branch) so the `sha256` stays stable.

## Usage — `./build.sh [stage]`

The pipeline has ordered, cumulative stages; naming one runs everything up to and
including it. Default (no argument) is `package` — the whole thing.

| Command | Runs | Use when |
|---|---|---|
| `./build.sh prepare` | export ref + apply patches | just refresh the patched tree |
| `./build.sh configure` | … + `./configure` | validate the toolchain |
| `./build.sh build` | … + `gmake` + AOT | compile (the long step) |
| `./build.sh package` *(default)* | … + install, icon, sign, **deploy** | full build & install |
| `./build.sh make` | `gmake` on the tree **as-is** (no reset/re-patch) | iterate on code already in the worktree |
| `./build.sh repackage` | `make` + install/sign/**deploy** | re-deploy without re-patching |

`prepare` resets the worktree to a clean `REF` and re-applies all patches (so
patched files always recompile). `make`/`repackage` skip that and reuse the tree.

### Fast iteration

For tight edit-build-test loops, skip the expensive parts:

```sh
# Fast build (no AOT), then run the worktree binary directly — ~seconds:
DEBUG=1 ./build.sh make && "$HOME/.cache/emacs-plus/emacs-debug/src/emacs" -Q
```

- **`SKIP_AOT=1`** — skip the *bulk* native compilation (~20 min → seconds). The
  Lisp runs as byte-code; only the handful of preloaded elns the dump needs are built.
- **`DEBUG=1`** — implies `SKIP_AOT`, and additionally compiles C at `-O0 -g3` (no
  release optimization, full debug symbols) and installs uncompressed `.el`. It
  builds in a **separate worktree** (`…/emacs-debug`), so it never disturbs your
  optimized release build. First `DEBUG` build is a full from-scratch compile;
  after that, `DEBUG=1 ./build.sh make` is ~bare-`make` fast.

Note `make`/`build` do **not** deploy — they only update the worktree binary. Run
`repackage` when you want `~/Applications/Emacs.app` refreshed.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `EMACS_SRC_REPO` | *(set me)* | the Emacs git checkout to build from |
| `EMACS_SRC_REF` | `master` | git ref to build |
| `EMACS_MAJOR` | `32` | Emacs major version (for `site-start.el`) |
| `EMACS_BUILD_DIR` | `~/.cache/emacs-plus` | build cache (worktrees, objects, venv) |
| `EMACS_APPS_DIR` | `~/Applications` | where `Emacs.app` is deployed |
| `EMACS_BIN_DIR` | `~/.local/bin` | where `emacs`/`emacsclient` go on `PATH` |
| `EMACS_PLUS_BUILD_CONFIG` | `~/.config/emacs-plus/build.yml` | the config file |
| `EMACS_ICONS_DIR` | `./assets/icons` | loose `.icon` sources |
| `EMACS_PY_VENV` | `$EMACS_BUILD_DIR/venv` | venv holding PyYAML |
| `SKIP_PREPARE=1` | — | reuse the worktree untouched (implied by `make`/`repackage`) |
| `RECONFIGURE=1` | — | force `autogen.sh` + `./configure` to re-run |
| `SKIP_AOT=1` | — | skip bulk native compilation |
| `DEBUG=1` | — | fast unoptimized debug build (implies `SKIP_AOT`) |

## What it produces

- **`~/Applications/Emacs.app`** — the self-contained, ad-hoc-signed bundle.
- **`~/.local/bin/emacs`** — a small wrapper that `exec`s the in-bundle binary
  (a wrapper, not a symlink, so bundle self-location works), and
  **`~/.local/bin/emacsclient`** — a symlink into the bundle.
- **`~/.cache/emacs-plus/`** — the build cache: the `emacs` (release) and
  `emacs-debug` worktrees, their object files/`native-lisp`, and the venv.

To run Emacs as a daemon, point a LaunchAgent at `~/.local/bin/emacs --fg-daemon`.

## Credits & license

The bundled **dragon-plus** icon is redistributed from
[d12frosted/homebrew-emacs-plus](https://github.com/d12frosted/homebrew-emacs-plus);
see [`assets/README.md`](assets/README.md) for attribution. The technique of
compiling a loose `.icon` into `Assets.car` with `actool` follows emacs-plus's
`generate-tahoe-assets`.

[MIT](LICENSE) © Andrea Alberti
