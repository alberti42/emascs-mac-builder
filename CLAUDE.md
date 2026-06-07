# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`build.sh` is a single self-contained Bash pipeline that builds a self-contained,
natively-compiled `Emacs.app` for macOS from a local Emacs git checkout. It is
independent of, but deliberately interchangeable with,
[d12frosted/emacs-plus](https://github.com/d12frosted/homebrew-emacs-plus): it
reads the **same `build.yml` schema** and reuses the emacs-plus Homebrew tap as a
registry for baseline patches, community patches, and icons.

There is no lint config and no build system — `build.sh` is the core, with one
Python helper (`scripts/build-config.py`) for reading `build.yml`.

## Running it

```sh
./build.sh            # full pipeline (== ./build.sh package)
./build.sh prepare    # export ref into worktree + apply patches
./build.sh configure  # ... + ./configure (validates the toolchain)
./build.sh build      # ... + gmake + explicit AOT native-compile (the long step)
./build.sh package    # ... + install, icon, sign, deploy
./build.sh make       # resume: gmake on the worktree AS-IS (no reset/re-patch)
./build.sh repackage  # package the worktree AS-IS (no reset/re-patch/rebuild)
```

Stages are **cumulative and ordered**; each target runs every stage up to and
including the named one (see the `case` dispatch at the bottom of the script).

### Key environment variables (all have defaults near the top of the script)

- `EMACS_SRC_REPO` / `EMACS_SRC_REF` — source Emacs git repo and ref (default a
  local `fork-emacs` checkout, `master`).
- `EMACS_BUILD_DIR` — build cache holding the worktree + objects (default
  `~/.cache/emacs-plus`). **Persists across runs** for incremental rebuilds.
- `EMACS_PLUS_BUILD_CONFIG` — path to `build.yml` (default `~/.config/emacs-plus/build.yml`).
- `EMACS_APPS_DIR` / `EMACS_BIN_DIR` — deploy target (`~/Applications`) and the
  PATH bin dir where the `emacs`/`emacsclient` entry points go (`~/.local/bin`).
  Note `emacs` is installed as a wrapper script (not a symlink) so the
  self-contained bundle is located from its launch path; `emacsclient` is **also**
  a wrapper, so it can `export TERM=xterm-emacs` (see the terminfo note below).
- `SKIP_PREPARE=1` — reuse the worktree untouched (no reset, no re-patch).
- `RECONFIGURE=1` — force `autogen.sh` + `./configure` to re-run.

### Build host prerequisites

Homebrew `gcc-N` + `libgccjit` (native-comp), `python3` (`build.yml` is read by
`scripts/build-config.py`), and **full Xcode** (not just the Command Line Tools)
when `build.yml` sets an `icon:` — `compile_icon` runs `actool`. There is **no
emacs-plus tap dependency**: patches are fetched per `build.yml`, and the icon is
a local `.icon`. PyYAML is provisioned automatically — `ensure_python` creates a
venv (pinned via `scripts/requirements.txt`) at `$EMACS_PY_VENV` (default
`$EMACS_BUILD_DIR/venv`) on first use. The script `die()`s early if `build.yml` is
missing, and `compile_icon` `die()`s if `actool` is absent.

## Architecture

The script is organized as **resolvers → stages → dispatch**:

- **Config reader** — all `build.yml` parsing goes through `scripts/build-config.py`
  (run via the `build_config` shell wrapper, which lazily provisions the venv). It
  has three subcommands: `patches` emits TSV, classifying each entry
  (`{name: {url, sha256}}`) as `local` (a `/ ./ ../ ~` path, sha256-verified) or
  `external` (any other URL, downloaded + sha256-verified); `icon` prints the icon
  name; `inject-path` exits 1 iff `inject_path: false`. `build_config` routes
  `ensure_python`'s setup chatter to stderr so captured stdout stays clean.
- **Stages** (`stage_prepare`, `stage_configure`, `stage_build`, `stage_package`)
  are the pipeline. `stage_package` calls a series of helpers
  (`apply_icon`, `write_site_lisp`, `inject_lsenvironment`, `relocate_native_lisp`,
  `prune_stale_eln`).
- **Dispatch** maps the CLI target to the cumulative chain of stages; `run_prepare`
  wraps `stage_prepare` to honor `SKIP_PREPARE`.

This repo builds **only `Emacs.app`** (plus the `emacs`/`emacsclient` CLI entries).
It does not build any client/launcher app — that lives in a separate project.

### The `./assets` directory and the icon

`assets/icons/` holds **loose `.icon` sources only** (Icon Composer documents:
`icon.json` + image layers); no compiled `.car` is committed. When `build.yml`'s
`icon:` names a locally bundled icon (e.g. `icon: dragon-plus` ↔
`assets/icons/dragon-plus.icon`, resolved via `SCRIPT_DIR`/`EMACS_ICONS_DIR`),
`apply_icon` calls `compile_icon`, which runs `actool` to produce `Assets.car`
(macOS 26 "Tahoe" app icon) + an `.icns` for older macOS and sets `CFBundleIconName`
to the `.icon` basename. No `icon:` → skip; an `icon:` with no matching local
`.icon` → `die` (no fallback — a wrong icon would be obvious anyway). The
dragon-plus icon is redistributed from emacs-plus; see `assets/README.md` for attribution.

### Things that look wrong but are load-bearing

This script encodes hard-won workarounds for native-comp + `--with-ns` + codesign
interactions. The long comments above each are the source of truth — **do not
"simplify" these without understanding the comment**:

- **Isolated detached worktree** (`stage_prepare`): the build happens in a git
  worktree under the build cache, never in your working checkout. The worktree is
  reset to the ref and re-patched each `prepare`, but object files/`.eln` persist
  for incremental C builds.
- **Explicit AOT after `gmake`** (`stage_build`): `native-lisp/` is deleted before
  building, and a full `compile-eln-aot` is run *explicitly* afterward, because
  gmake's built-in `../native-lisp` AOT trigger only fires when the directory is
  absent and the dumped-Emacs step already recreates it — leaving most lisp
  uncompiled. `prune_stale_eln` later verifies the live version-dir has ≥100 `.eln`.
- **`SKIP_AOT=1` fast path** (`stage_build`): skips the **bulk** native compilation for
  quick patch testing (seconds vs ~20 min). NOT "byte-code only": an aot binary's dump
  bakes in (and `dlopen`s at startup) a minimal **preloaded** eln set, so those few are
  always built — only the bulk is skipped, and the rest of the lisp runs as byte-code.
  It `mkdir`s `native-lisp/` (present dir makes `src/Makefile`'s `test ! -d`-guarded
  `../native-lisp` recipe skip the bulk preloaded build + re-dump — the base dump still
  emits the few elns it needs). The wipe + forced dump rebuild (`rm -rf native-lisp` +
  `rm -f emacs.pdmp`) only runs on the **first** SKIP_AOT build of a worktree or when
  switching from a full build — tracked by `$SRC/.aot-mode` (`skip`/`aot`); a repeat
  SKIP_AOT build skips it so a no-op stays ~bare-`make` fast. `prune_stale_eln` must
  **keep the live verdir** (those preloaded elns), or the deployed app won't boot —
  stripping them was a bug. Full build (default) for anything shipped.
- **`DEBUG=1` fast/debug build**: implies `SKIP_AOT`; compiles C at `-O0 -g3` (no
  release optimization, full symbols) instead of the release `-O` (which Emacs's
  configure appends because the base `CFLAGS` carries no `-O`/`-g`); and passes
  `--without-compress-install` (uncompressed `.el`, no gzip pass — so the
  `.elc` mtime bump is skipped too, see below). It builds in its **own worktree**
  (`$EMACS_BUILD_DIR/emacs-debug`, vs release's `…/emacs`) — like an IDE's separate
  Debug/Release dirs — so each mode keeps its own incremental objects and switching
  never triggers a rebuild. `SRC` is derived from the mode. Both modes share the venv
  and currently deploy to the same `Emacs.app` target. Changing what configure args a
  mode passes needs `RECONFIGURE=1` once on an already-configured worktree.
- **`.elc` mtime bump** (`stage_package`): `gmake install` can leave a `.el.gz`
  newer than its `.elc`; with `load-prefer-newer`, Emacs then tries to load
  compressed source and recurses on `jka-compr`. Fixed by `sleep 1` (into a strictly
  later whole second — a same-second touch is racy) then `touch`ing every `.elc` so
  it wins, with natural timestamps. The deploy `cp -Rp` preserves the ordering —
  plain `cp -R` would flatten it. Skipped entirely when the bundle has no `.el.gz`
  (i.e. `DEBUG`/`--without-compress-install`) — `.elc` is already newer than plain `.el`.
- **`emacs` on PATH is a wrapper, not a symlink**: a self-contained `--with-ns`
  build locates its bundle from the launch path, which isn't canonicalized; a
  symlink outside the bundle breaks bundle detection ("loadup.el not found"). The
  wrapper `exec`s the absolute in-bundle binary. `emacsclient` is **also** a
  wrapper (it only talks to the daemon, so it doesn't need bundle paths) — but a
  wrapper rather than a symlink so it can `export TERM=xterm-emacs` before exec.
- **`xterm-emacs` terminfo + `emacsclient` `TERM`** (`install_terminfo`): the
  `emacsclient` wrapper exports `TERM=xterm-emacs`; emacsclient passes that TERM to
  the daemon as the new tty frame's terminal type (the daemon's own `TERM` is
  irrelevant), so `-t`/`-nw` frames get the `setf24`/`setb24` capabilities and emit
  unconditional 24-bit RGB, bypassing Emacs bug #70941's buggy 16-color ANSI
  fast-path (which distorts faces under palette-remapping themes like Catppuccin /
  Gruvbox / Nord). The entry is a loose source at
  `assets/terminfo/xterm-emacs.terminfo` (inherits `xterm-256color` via `use=`,
  adds only `setf24`/`setb24`); deploy compiles it into the per-user
  `$HOME/.terminfo` with `tic -x` (no root). Missing `tic` warns and skips.
- **`relocate_native_lisp`**: moves `native-lisp` out of `Contents/Frameworks`
  (where codesign treats each child as a nested bundle and fails) into
  `Contents/Resources`, leaving a relative symlink so `native-comp-eln-load-path`
  still resolves.

### emacs-plus compatibility surface

- `build.yml` keys consumed: `patches` (each `{name: {url, sha256}}`), `icon` (a
  name resolved to `assets/icons/<name>.icon`), `inject_path` (bool). This is a
  subset of the emacs-plus schema — the tap-backed forms (community-name patches,
  tap/external icons) are intentionally not supported.
- `write_site_lisp` emits a `site-start.el` that `(provide 'emacs-plus)` and honors
  `EMACS_PLUS_PATH`, so emacs-plus-aware configs treat this build as an emacs-plus build.
- `inject_lsenvironment` writes native-comp env (`CC`, `LIBRARY_PATH`) and optionally
  `EMACS_PLUS_PATH` into the bundle's `Info.plist` `LSEnvironment`.

## Conventions

- `set -euo pipefail` throughout; use `die()` for fatal errors, `log()`/`sub()` for
  the structured colored output. Match this style for any new code.
- Icons are loose `.icon` sources under `assets/icons/`, compiled at build time
  (see the architecture section). Never commit a generated `Assets.car`.
