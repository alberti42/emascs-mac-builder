# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`build.sh` is a single self-contained Bash pipeline that builds a self-contained,
natively-compiled `Emacs.app` (and `Emacs Client.app`) for macOS from a local
Emacs git checkout. It is independent of, but deliberately interchangeable with,
[d12frosted/emacs-plus](https://github.com/d12frosted/homebrew-emacs-plus): it
reads the **same `build.yml` schema** and reuses the emacs-plus Homebrew tap as a
registry for baseline patches, community patches, and icons.

There are no tests, no lint config, and no build system — the repo *is* the script.

## Running it

```sh
./build.sh            # full pipeline (== ./build.sh package)
./build.sh prepare    # export ref into worktree + apply patches
./build.sh configure  # ... + ./configure (validates the toolchain)
./build.sh build      # ... + gmake + explicit AOT native-compile (the long step)
./build.sh package    # ... + install, icon, sign, deploy, build client app
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
  self-contained bundle is located from its launch path; `emacsclient` is a symlink.
- `SKIP_PREPARE=1` — reuse the worktree untouched (no reset, no re-patch).
- `RECONFIGURE=1` — force `autogen.sh` + `./configure` to re-run.

### Build host prerequisites

Homebrew `gcc-N` + `libgccjit` (native-comp), `ruby` (YAML/JSON parsing of
`build.yml`), and the `d12frosted/homebrew-emacs-plus` tap checked out locally
(used for baseline patches and the community patch/icon registry). The script
`die()`s early if `build.yml` or the tap is missing.

## Architecture

The script is organized as **resolvers → stages → dispatch**:

- **Resolvers** (`resolve_patches`, `resolve_icon`, `inject_user_path`) are inline
  Ruby snippets that parse `build.yml` and emit TSV. They intentionally mirror
  emacs-plus's `EmacsBase#resolve_patches`, classifying each patch as
  `community` (looked up in the tap's `community/registry.json`), `local`
  (path on disk, sha256-verified), or `external` (URL, downloaded + sha256-verified).
- **Stages** (`stage_prepare`, `stage_configure`, `stage_build`, `stage_package`)
  are the pipeline. `stage_package` calls a series of helpers
  (`apply_icon`, `write_site_lisp`, `inject_lsenvironment`, `relocate_native_lisp`,
  `prune_stale_eln`).
- **Dispatch** maps the CLI target to the cumulative chain of stages; `run_prepare`
  wraps `stage_prepare` to honor `SKIP_PREPARE`.

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
- **Epoch-pinning `.el`/`.el.gz`** (`stage_package`): `gmake install` can leave a
  `.el.gz` newer than its `.elc`; with `load-prefer-newer`, Emacs then tries to
  load compressed source and recurses on `jka-compr`. Sources are touched to
  1970 so `.elc` always wins. The deploy `cp -Rp` preserves these mtimes — plain
  `cp -R` would re-break it.
- **`emacs` on PATH is a wrapper, not a symlink**: a self-contained `--with-ns`
  build locates its bundle from the launch path, which isn't canonicalized; a
  symlink outside the bundle breaks bundle detection ("loadup.el not found"). The
  wrapper `exec`s the absolute in-bundle binary. `emacsclient` *is* a symlink
  (it only talks to the daemon).
- **`relocate_native_lisp`**: moves `native-lisp` out of `Contents/Frameworks`
  (where codesign treats each child as a nested bundle and fails) into
  `Contents/Resources`, leaving a relative symlink so `native-comp-eln-load-path`
  still resolves.

### emacs-plus compatibility surface

- `build.yml` keys consumed: `patches` (strings = community, or `{name: {url, sha256}}`),
  `icon` (string = community, or `{url, sha256}`), `inject_path` (bool).
- `write_site_lisp` emits a `site-start.el` that `(provide 'emacs-plus)` and honors
  `EMACS_PLUS_PATH`, so emacs-plus-aware configs treat this build as an emacs-plus build.
- `inject_lsenvironment` writes native-comp env (`CC`, `LIBRARY_PATH`) and optionally
  `EMACS_PLUS_PATH` into the bundle's `Info.plist` `LSEnvironment`.

## Conventions

- `set -euo pipefail` throughout; use `die()` for fatal errors, `log()`/`sub()` for
  the structured colored output. Match this style for any new code.
- `Emacs Client.app` is built by delegating to an external `emacsgui-build.sh`
  (`EMACS_CLIENT_BUILD`), which lives outside this repo.
