#!/usr/bin/env bash
#
# Standalone Emacs build pipeline that consumes ~/.config/emacs-plus/build.yml
# in the SAME schema as the d12frosted/emacs-plus formula, so the two stay
# interchangeable (icon / patches / inject_path).
#
# It reproduces what `brew install emacs-plus@32` would do, but:
#   * builds from a local git ref (this fork-emacs `master`) via an isolated,
#     detached worktree -- your working checkout is never touched;
#   * applies every patch listed in build.yml (local file or downloaded URL),
#     each sha256-verified;
#   * wires native-compilation (libgccjit) for both build and runtime;
#   * builds a SELF-CONTAINED Emacs.app (binaries, lisp, native-lisp all inside
#     the bundle -- no Unix prefix split);
#   * applies the app icon from a loose .icon under ./assets/icons named by
#     build.yml's `icon:` (compiled to Assets.car via actool);
#   * deploys Emacs.app to ~/Applications and writes emacs/emacsclient wrappers
#     (exec'ing into Emacs.app) onto PATH, and installs the xterm-emacs terminfo
#     so emacsclient -t/-nw frames get 24-bit color.
#
# Usage:
#   build.sh                 # full pipeline
#   build.sh prepare         # export master + apply patches only
#   build.sh configure       # ... through ./configure (validates the toolchain)
#   build.sh build           # ... through gmake (the long step)
#   build.sh package         # install + icon + sign + deploy
#   build.sh make            # resume: gmake on the worktree AS-IS, no reset/re-patch
#   build.sh repackage       # package the worktree AS-IS, no reset/re-patch/rebuild churn
#
# Stages are cumulative and ordered; each runs every stage up to and including
# the named one. The build worktree ($EMACS_BUILD_DIR/emacs, default
# ~/.cache/emacs-plus/emacs) PERSISTS across runs -- object files and .eln are
# kept, so builds are incremental. `prepare` reverts to clean master and
# re-applies patches (so the patched files always recompile); use `make`/
# `repackage`, or SKIP_PREPARE=1, to reuse the tree untouched when the patch
# set hasn't changed. RECONFIGURE=1 forces autogen+configure to re-run.
#
# SKIP_AOT=1 skips the BULK native compilation -- a fast loop for testing patches
# (seconds, vs ~20 min for full AOT). The bulk lisp runs as byte-code; only the few
# preloaded elns the dump requires are still built. Tightest iteration:
#   SKIP_AOT=1 build.sh make   &&   ~/.cache/emacs-plus/emacs/src/emacs -Q
# DEBUG=1 goes further: implies SKIP_AOT, compiles C at -O0 -g3 (no release
# optimization, full debug symbols), and installs uncompressed .el (no gzip pass).
# It uses its OWN worktree ($EMACS_BUILD_DIR/emacs-debug) -- like an IDE's separate
# Debug/Release dirs -- so switching modes never churns the other build's objects.
set -euo pipefail

# ---------------------------------------------------------------- configuration
REPO="${EMACS_SRC_REPO:-$HOME/Documents/Programming/Others/fork-emacs}"
REF="${EMACS_SRC_REF:-master}"
MAJOR="${EMACS_MAJOR:-32}"
BUILD_DIR="${EMACS_BUILD_DIR:-$HOME/.cache/emacs-plus}"   # internal build cache (worktree + objects)
APPS_DIR="${EMACS_APPS_DIR:-$HOME/Applications}"
BIN_DIR="${EMACS_BIN_DIR:-$HOME/.local/bin}"            # PATH bin dir for the emacs/emacsclient entry points
CFG="${EMACS_PLUS_BUILD_CONFIG:-$HOME/.config/emacs-plus/build.yml}"

# This script's own directory, so it can find its bundled ./assets (loose icon
# sources) regardless of where it's invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICONS_DIR="${EMACS_ICONS_DIR:-$SCRIPT_DIR/assets/icons}"   # loose <name>.icon sources compiled at build time
TERMINFO_SRC="${EMACS_TERMINFO_SRC:-$SCRIPT_DIR/assets/terminfo/xterm-emacs.terminfo}"  # custom terminfo installed for emacsclient
PY_VENV="${EMACS_PY_VENV:-$BUILD_DIR/venv}"                # venv (pinned PyYAML) for the build.yml reader

# Separate worktree per optimization mode (like an IDE's Debug/Release dirs), so
# switching modes never churns the other's object files. Release keeps the original
# path; DEBUG gets a sibling. (Both share the venv + the deployed app target.)
SRC="$BUILD_DIR/emacs"
[ "${DEBUG:-0}" = 1 ] && SRC="$BUILD_DIR/emacs-debug"
HB="$(brew --prefix)"
# Leave one core free so the machine stays responsive during the long build.
JOBS="$(( $(sysctl -n hw.ncpu) - 2 ))"
PB=/usr/libexec/PlistBuddy

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
sub()  { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$CFG" ] || die "build.yml not found: $CFG"
command -v python3 >/dev/null || die "python3 required (build.yml is read by scripts/build-config.py)"

# DEBUG=1 is the fast test build: -O0 + full symbols (stage_configure) and, since
# native compilation dwarfs everything, it implies SKIP_AOT (no eln) too.
[ "${DEBUG:-0}" = 1 ] && SKIP_AOT=1

# gcc / libgccjit discovery (the fiddly native-comp bits)
GCC_MAJOR="$(/bin/ls "$HB"/bin/gcc-* 2>/dev/null | sed -n 's#.*/gcc-\([0-9][0-9]*\)$#\1#p' | sort -n | tail -1)"
[ -n "$GCC_MAJOR" ] || die "no Homebrew gcc-N found under $HB/bin"
GCC_LIB="$HB/lib/gcc/$GCC_MAJOR"
SQLITE="$(brew --prefix sqlite)"
GCC_PREFIX="$(brew --prefix gcc)"
GCCJIT="$(brew --prefix libgccjit)"

# LIBRARY_PATH for native compilation: emutls dir + gcc libs (build & runtime)
emutls_file="$(/usr/bin/find "$HB/Cellar/gcc" -name libemutls_w.a 2>/dev/null | head -1 || true)"
LIBRARY_PATH_VALUE=""
[ -n "$emutls_file" ] && LIBRARY_PATH_VALUE="$(dirname "$emutls_file")"
LIBRARY_PATH_VALUE="${LIBRARY_PATH_VALUE:+$LIBRARY_PATH_VALUE:}$HB/lib/gcc/current:$HB/lib"

# ---------------------------------------------------- build.yml reader (Python)
# All build.yml parsing goes through scripts/build-config.py, run from a venv with
# pinned PyYAML created on first use under the build cache.
ensure_python() {
  [ -x "$PY_VENV/bin/python" ] && return
  command -v python3 >/dev/null || die "python3 required to create the build-helper venv"
  log "Creating Python venv for build helpers -> $PY_VENV"
  python3 -m venv "$PY_VENV" || die "python3 -m venv failed"
  "$PY_VENV/bin/pip" install --quiet --disable-pip-version-check -r "$SCRIPT_DIR/scripts/requirements.txt" \
    || die "pip install (build-helper deps) failed"
}

# build_config <subcommand> -> scripts/build-config.py against $CFG. Subcommands:
#   patches      TSV  kind<TAB>name<TAB>path_or_url<TAB>sha256 (url / ./ ../ ~ = local file, else downloaded)
#   icon         the icon name, or empty
#   inject-path  exits 1 iff build.yml sets inject_path: false, else 0
# ensure_python's chatter goes to stderr so it never pollutes captured stdout.
build_config() {
  ensure_python >&2
  "$PY_VENV/bin/python" "$SCRIPT_DIR/scripts/build-config.py" "$1" "$CFG"
}

verify_sha256() { # file expected
  local actual; actual="$(shasum -a 256 "$1" | awk '{print $1}')"
  [ "$actual" = "$2" ] || die "sha256 mismatch for $1
  expected: $2
  actual:   $actual"
}

apply_patch() { # file name
  # -N refuses a patch that is already applied instead of asking whether to
  # reverse it.  Without it `patch' prompts, the prompt is invisible because
  # this output is captured, and the default answer REVERSES the patch --
  # silently undoing a fix that has landed upstream.  Note --batch is not a
  # substitute: Apple's patch takes it as "answer yes", reverses, and exits 0.
  local out
  out="$(patch -p1 -d "$SRC" -N --no-backup-if-mismatch -i "$1" 2>&1)" \
    || die "patch failed: $2
$out"
}

# ----------------------------------------------------------------------- stages
stage_prepare() {
  log "Exporting $REF from $REPO into isolated worktree"
  mkdir -p "$BUILD_DIR"
  git -C "$REPO" worktree prune
  local rev; rev="$(git -C "$REPO" rev-parse "$REF")"
  if git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    sub "reset existing worktree to $REF ($rev) -- keeps build artifacts for incremental rebuilds"
    git -C "$SRC" reset --hard --quiet "$rev"
  else
    rm -rf "$SRC"
    git -C "$REPO" worktree add --detach --quiet "$SRC" "$rev"
  fi

  log "Applying build.yml patches"
  local kind name loc sha tmp
  while IFS=$'\t' read -r kind name loc sha; do
    [ -n "$kind" ] || continue
    sub "$name ($kind)"
    case "$kind" in
      local)
        [ -f "$loc" ] || die "local patch not found: $loc"
        verify_sha256 "$loc" "$sha"
        apply_patch "$loc" "$name" ;;
      external)
        tmp="$(mktemp -t emacs-patch).patch"
        curl -fsSL -o "$tmp" "$loc" || die "download failed: $name ($loc)"
        verify_sha256 "$tmp" "$sha"
        apply_patch "$tmp" "$name"
        rm -f "$tmp" ;;
    esac
  done < <(build_config patches)
}

stage_configure() {
  local opt_mode=release
  [ "${DEBUG:-0}" = 1 ] && opt_mode=debug
  log "Configuring (opt=$opt_mode, native-compilation=aot, gcc-$GCC_MAJOR)"
  export PKG_CONFIG_PATH="$HB/lib/pkgconfig:$HB/share/pkgconfig"
  local dep d
  for dep in gnutls librsvg little-cms2 tree-sitter webp sqlite zlib libxml2 jpeg gmp; do
    d="$(brew --prefix "$dep" 2>/dev/null)/lib/pkgconfig"
    [ -d "$d" ] && PKG_CONFIG_PATH="$d:$PKG_CONFIG_PATH"
  done
  export LDFLAGS="-L$SQLITE/lib -L$GCC_LIB -Wl,-rpath,$GCC_LIB -L$HB/lib"
  export LIBRARY_PATH="$LIBRARY_PATH_VALUE"

  local cflags="-DFD_SETSIZE=10000 -DDARWIN_UNLIMITED_SELECT -I$SQLITE/include -I$GCC_PREFIX/include -I$GCCJIT/include -I$HB/include"
  # Optimization: release uses -O2 to match emacs-plus (which gets it from Homebrew's
  # superenv; outside that env, Emacs's configure would otherwise only add -O = -O1).
  # DEBUG skips optimization and keeps full symbols for a fast, debuggable test build.
  if [ "$opt_mode" = debug ]; then
    cflags="$cflags -O0 -g3"
  else
    cflags="$cflags -O2"
  fi
  # Self-contained Emacs.app: everything (binaries, lisp, native-lisp, info) lands
  # INSIDE the bundle. No --prefix / Unix split / locallisppath -- that layout only
  # existed because emacs-plus is a Homebrew keg; this is a personal build.
  local args=(
    --disable-dependency-tracking
    --disable-silent-rules
    --with-native-compilation=aot
    --with-xml2 --with-gnutls --with-modules --with-rsvg --with-webp
    --without-dbus --without-imagemagick
    --with-xwidgets
    --with-ns
    "CFLAGS=$cflags"
  )
  # DEBUG: don't gzip the installed .el sources. Saves the gzip pass in 'gmake install'
  # and, with no .el.gz, the .elc-vs-.el.gz mtime dance in stage_package is moot. (The
  # release default keeps compression for a smaller bundle.)
  [ "$opt_mode" = debug ] && args+=(--without-compress-install)

  # Each mode has its own worktree, so a dir is only ever one optimization mode --
  # no flip detection needed; a fresh dir configures itself for its mode.
  ( cd "$SRC"
    [ -x ./configure ] || { log "autogen.sh"; ./autogen.sh; }
    if [ ! -f Makefile ] || [ "${RECONFIGURE:-0}" = 1 ]; then
      ./configure "${args[@]}"
    else
      sub "Makefile present -- skipping configure (RECONFIGURE=1 to force)"
    fi )
}

stage_build() {
  if [ "${SKIP_AOT:-0}" = 1 ]; then
    # Fast iteration build: skip the BULK native compilation for testing a patch in
    # ~seconds instead of the full AOT's ~20 min. NOT "byte-code only" -- an aot
    # binary's dump still bakes in (and dlopens at startup) a minimal PRELOADED eln
    # set, so those few ARE built; the bulk lisp just runs as byte-code (or lazily
    # JIT-compiles into the user eln-cache at runtime), which is fine for a quick test.
    #   * clear native-lisp first so no stale .eln from a prior build lingers, AND so
    #     the dir EXISTS: src/Makefile's '../native-lisp' recipe is guarded by
    #     'test ! -d', so an existing (even empty) dir skips the bulk preloaded build
    #     and its extra re-dump;
    #   * the base dump ($(pdmp): loadup --eln-dest) is what emits the few preloaded
    #     elns -- but its prereqs are the binary + loaddefs, NOT native-lisp, so after
    #     wiping native-lisp we must force the dump to rebuild or those elns won't come
    #     back (and the dump dlopens them at startup -> broken). rm the pdmp to force it;
    #   * skip the explicit bulk compile-eln-aot step entirely.
    # Fastest loop: SKIP_AOT=1 ./build.sh build  (or 'make' to reuse the tree)  then
    # run $SRC/src/emacs.  prune_stale_eln keeps the live verdir so the deploy boots.
    #
    # The wipe + forced dump rebuild above is only NEEDED on the FIRST skip-AOT build
    # of a worktree, or when switching from a full-AOT build (whose bulk elns would
    # shadow the patched sources). On a repeat skip-AOT build nothing stale exists, so
    # skip it (~5s saved) and let gmake do its normal incremental work -- a no-op then
    # stays ~as fast as bare `make`. The last mode is recorded in $SRC/.aot-mode.
    log "SKIP_AOT=1 -> fast build: skip bulk AOT (preloaded elns only)"
    mkdir -p "$SRC/native-lisp"   # ensure it exists so the bulk ../native-lisp recipe stays skipped
    if [ "$(cat "$SRC/.aot-mode" 2>/dev/null)" != skip ]; then
      sub "first skip-AOT build here -> clearing native-lisp + forcing a clean byte-code dump"
      rm -rf "$SRC/native-lisp"; mkdir -p "$SRC/native-lisp"
      rm -f "$SRC/src/emacs.pdmp"
    fi
    log "Building with gmake -j$JOBS"
    ( cd "$SRC" && gmake -j"$JOBS" )
    echo skip > "$SRC/.aot-mode"
    return
  fi

  # Remove the worktree's native-lisp so the build re-runs a full AOT compile:
  # 'all: ../native-lisp' (src/Makefile) only fires the AOT recipe when the
  # directory is ABSENT (the Makefile literally relies on that -- see its FIXME).
  # This regenerates the eln set for the CURRENT comp-native-version-dir; the C
  # objects stay incremental. NOTE: this does NOT clean the bundle -- the install
  # target ($SRC/nextstep/Emacs.app) persists and 'install-eln' is additive, so
  # stale version dirs are pruned later in stage_package (prune_stale_eln).
  log "Clearing native-lisp (forces a full AOT recompile)"
  rm -rf "$SRC/native-lisp"
  log "Building with gmake -j$JOBS (this is the long one)"
  ( cd "$SRC" && gmake -j"$JOBS" )

  # gmake's own AOT trigger is unreliable: the '../native-lisp' recipe only runs
  # compile-eln-aot when the directory is absent (test ! -d), but building the
  # dumped Emacs -- an order-only prerequisite, so it runs first -- already creates
  # native-lisp/<verdir> for the *preloaded* set. The guard then sees the dir and
  # silently skips the bulk AOT, leaving only a handful of elns. Drive the full AOT
  # explicitly so the eln set for the current comp-native-version-dir is complete.
  #
  # This recompiles the whole tree every build (paired with the rm above): clean
  # and predictable, no incremental-eln reuse. batch-native-compile has no skip-if-
  # up-to-date check anyway, so reuse would require a custom driver -- deliberately
  # not done, to keep each build's output deterministic.
  log "Native-compiling all lisp (AOT) -- gmake's built-in trigger is unreliable here"
  ( cd "$SRC/lisp" && gmake -j"$JOBS" compile-eln-aot EMACS="$SRC/src/emacs" ELNDONE="" )
  echo aot > "$SRC/.aot-mode"   # so a later SKIP_AOT build knows to clear this bulk
}

stage_package() {
  log "Installing self-contained Emacs.app (gmake install)"
  ( cd "$SRC" && gmake install )

  local app_src="$SRC/nextstep/Emacs.app"
  [ -d "$app_src" ] || die "expected self-contained app at $app_src after 'gmake install'"
  # 'gmake install' byte-compiles to .elc, THEN gzips the .el sources to .el.gz a
  # moment later -- so a bundled .el.gz can end up newer than its .elc. With
  # (setq load-prefer-newer t) in a user's config, Emacs then prefers the
  # compressed *source*; loading jka-compr.el.gz (the decompressor itself)
  # recurses ("Recursive load: .../jka-compr.el.gz").
  #
  # Make every .elc the newest of the trio. Bumping .elc to "now" in the SAME second
  # install wrote .el.gz is racy (touch truncates to whole seconds, so a sub-second-
  # later .el.gz can still win), so sleep into a strictly later second first -- then
  # the .elc are unambiguously newest, with natural timestamps (no epoch-pinned dates).
  # .eln native selection is keyed on the source hash, not mtime, so it's unaffected.
  # (cp -Rp at deploy preserves this ordering; plain cp -R would flatten it.)
  #
  # Only needed when compression is on: with --without-compress-install (DEBUG) there
  # are no .el.gz, install leaves .elc newer than the plain .el anyway, and we skip the
  # bump (and its sleep) entirely.
  if [ -n "$(find "$app_src/Contents/Resources" -name '*.el.gz' -print 2>/dev/null | head -1)" ]; then
    log "Bumping .elc mtimes so they win over .el.gz (load-prefer-newer)"
    sleep 1
    find "$app_src/Contents/Resources" -name '*.elc' -exec touch {} +
  else
    sub "no .el.gz in bundle (compress-install off) -- .elc already newer, skipping mtime bump"
  fi
  [ -x "$app_src/Contents/MacOS/Emacs" ] || die "Emacs binary missing in $app_src"
  local res="$app_src/Contents/Resources"

  # Discover the in-bundle emacsclient (Contents/MacOS/bin/emacsclient per
  # nextstep/Makefile.in; discovered, to stay version-proof).
  local client_rel
  client_rel="$(cd "$app_src" && find Contents -type f -name emacsclient -perm -u+x | head -1)"
  [ -n "$client_rel" ] || die "emacsclient not found inside $app_src"
  sub "emacsclient in bundle: $client_rel"

  prune_stale_eln "$app_src"

  apply_icon "$res" "$app_src/Contents/Info.plist"

  # site-start.el inside the bundle's site-lisp.
  local sitelisp
  sitelisp="$(find "$res" -type d -name site-lisp | head -1)"
  [ -n "$sitelisp" ] || sitelisp="$res/site-lisp"
  write_site_lisp "$sitelisp"

  inject_lsenvironment "$app_src/Contents/Info.plist" "$app_src"

  relocate_native_lisp "$app_src"

  log "Signing (ad-hoc, required on recent macOS)"
  # Sign + strict-verify; surface failure instead of swallowing it silently.
  if codesign --force --deep --sign - "$app_src" >/dev/null 2>&1 \
     && codesign --verify --strict "$app_src" >/dev/null 2>&1; then
    sub "ad-hoc signature OK (strict verify passed)"
  else
    sub "warning: codesign/verify failed -- run 'codesign --verify --strict' for detail"
  fi

  log "Deploying to $APPS_DIR/Emacs.app"
  mkdir -p "$APPS_DIR"
  rm -rf "$APPS_DIR/Emacs.app"        # bounded to the named app, never a shared dir
  # -p (preserve mtimes) is REQUIRED: plain 'cp -R' resets every file's mtime to
  # copy time, which flattens the .elc-newer-than-.el.gz ordering set above and
  # re-introduces the load-prefer-newer jka-compr recursion in the *deployed* app.
  cp -Rp "$app_src" "$APPS_DIR/Emacs.app"
  local app="$APPS_DIR/Emacs.app"

  # Put the executables on PATH, replacing any prior wrappers/symlinks.
  mkdir -p "$BIN_DIR"
  # emacs MUST be a wrapper, not a symlink: this is a self-contained --with-ns
  # build, so epaths are RELATIVE to the bundle and Emacs locates the .app from
  # its launch path (_NSGetExecutablePath, which is NOT canonicalized). Launched
  # via a symlink in $BIN_DIR, that path isn't inside the .app, bundle detection
  # fails, and lisp/libexec resolve to bogus relative dirs ("loadup.el not
  # found"). exec'ing the absolute in-bundle path makes detection work.
  rm -f "$BIN_DIR/emacs"
  cat >"$BIN_DIR/emacs" <<EOS
#!/bin/sh
exec "$app/Contents/MacOS/Emacs" "\$@"
EOS
  chmod +x "$BIN_DIR/emacs"
  # emacsclient is ALSO a wrapper (not a symlink), to export TERM=xterm-emacs:
  # emacsclient hands its TERM to the daemon as the new tty frame's terminal type
  # (the daemon's own TERM is irrelevant), so a -t/-nw frame picks up the
  # setf24/setb24 entry installed above and renders 24-bit RGB unconditionally.
  # No bundle paths are needed (it only talks to the daemon), so exec'ing the
  # in-bundle binary directly is fine.
  rm -f "$BIN_DIR/emacsclient"
  cat >"$BIN_DIR/emacsclient" <<EOS
#!/bin/sh
export TERM=xterm-emacs
exec "$app/$client_rel" "\$@"
EOS
  chmod +x "$BIN_DIR/emacsclient"
  sub "wrote   $BIN_DIR/emacs       -> exec Contents/MacOS/Emacs"
  sub "wrote   $BIN_DIR/emacsclient -> exec $client_rel (TERM=xterm-emacs)"

  install_terminfo

  log "Done."
  sub "Emacs.app    -> $app"
  sub "executables  -> $BIN_DIR/emacs, $BIN_DIR/emacsclient (both wrappers into the bundle)"
  sub "To make this the daemon, point your LaunchAgent at $BIN_DIR/emacs --fg-daemon"
}

# Compile a loose <name>.icon (Icon Composer source) into the bundle with actool:
# Assets.car for the macOS 26 "Tahoe" app icon, plus an .icns for older macOS.
# The .icon basename IS the icon name, which CFBundleIconName must point at. The
# .car is GENERATED here, never committed -- assets/icons holds only loose source.
compile_icon() { # icon_dir res plist
  local ic="$1" res="$2" plist="$3" name; name="$(basename "$ic" .icon)"
  # actool ships only with FULL Xcode, not the Command Line Tools.
  local actool; actool="$(xcrun --find actool 2>/dev/null || true)"
  [ -n "$actool" ] || die "actool not found -- full Xcode required to compile $ic (install Xcode, then 'sudo xcode-select -s /Applications/Xcode.app')"
  log "Applying icon (local $name via actool)"
  local tmp; tmp="$(mktemp -d)"
  "$actool" "$ic" \
    --compile "$tmp" \
    --platform macosx \
    --minimum-deployment-target 11.0 \
    --app-icon "$name" \
    --output-partial-info-plist "$tmp/partial.plist" \
    --enable-icon-stack-fallback-generation=disabled >/dev/null \
    || die "actool failed to compile $ic"
  [ -f "$tmp/Assets.car" ] || die "actool produced no Assets.car for $ic"
  cp -f "$tmp/Assets.car" "$res/Assets.car"
  [ -f "$tmp/$name.icns" ] && cp -f "$tmp/$name.icns" "$res/Emacs.icns"   # pre-Tahoe fallback
  $PB -c "Delete :CFBundleIconName" "$plist" 2>/dev/null || true
  $PB -c "Add :CFBundleIconName string $name" "$plist"
  rm -rf "$tmp"
}

apply_icon() { # resources_dir info_plist
  local res="$1" plist="$2"
  # build.yml's `icon:` names a loose .icon under $ICONS_DIR (e.g. dragon-plus ->
  # $ICONS_DIR/dragon-plus.icon). No icon configured -> skip; named but missing -> fail.
  local key; key="$(build_config icon)"
  [ -n "$key" ] || { sub "no icon configured"; return; }
  [ -d "$ICONS_DIR/$key.icon" ] || die "icon '$key' not found: $ICONS_DIR/$key.icon"
  compile_icon "$ICONS_DIR/$key.icon" "$res" "$plist"
}

write_site_lisp() { # site-lisp dir
  local dir="$1"
  mkdir -p "$dir"
  log "Writing site-start.el -> $dir"
  cat >"$dir/site-start.el" <<EOS
;;; site-start.el --- Emacs Plus site initialization -*- lexical-binding: t -*-
;; Auto-generated by build.sh. Marks this as an Emacs Plus-compatible build.

(defconst ns-emacs-plus-version $MAJOR
  "Major version of Emacs Plus that built this Emacs.")

(defconst ns-emacs-plus-injected-path
  (not (null (getenv "EMACS_PLUS_PATH")))
  "Non-nil if PATH was injected at install time.")

(when-let ((emacs-plus-path (getenv "EMACS_PLUS_PATH")))
  (setq exec-path (append (split-string emacs-plus-path ":" t) (list exec-directory)))
  (setenv "PATH" emacs-plus-path))

(provide 'emacs-plus)
;;; site-start.el ends here
EOS
}

inject_lsenvironment() { # info_plist app
  local plist="$1" app="$2"
  log "Injecting native-comp LSEnvironment into Emacs.app"
  $PB -c "Add :LSEnvironment dict" "$plist" 2>/dev/null || true
  if build_config inject-path; then
    local user_path="$PATH:$HB/bin:$HB/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
    sub "inject_path: true -> EMACS_PLUS_PATH"
    $PB -c "Add :LSEnvironment:EMACS_PLUS_PATH string $user_path" "$plist" 2>/dev/null || \
      $PB -c "Set :LSEnvironment:EMACS_PLUS_PATH $user_path" "$plist"
  else
    sub "inject_path: false -> native-comp env only"
  fi
  $PB -c "Add :LSEnvironment:CC string $HB/bin/gcc-$GCC_MAJOR" "$plist" 2>/dev/null || \
    $PB -c "Set :LSEnvironment:CC $HB/bin/gcc-$GCC_MAJOR" "$plist"
  $PB -c "Add :LSEnvironment:LIBRARY_PATH string $LIBRARY_PATH_VALUE" "$plist" 2>/dev/null || \
    $PB -c "Set :LSEnvironment:LIBRARY_PATH $LIBRARY_PATH_VALUE" "$plist"
  touch "$app"
}

relocate_native_lisp() { # app
  # The self-contained --with-ns build installs the native-comp eln store at
  # Contents/Frameworks/native-lisp (upstream's ns_applibdir). codesign treats
  # every child of Contents/Frameworks as nested code (a framework/dylib to sign),
  # but native-lisp is a plain directory tree of .eln dylibs -- so signing fails
  # with "bundle format unrecognized" on native-lisp/<version-dir>, and the whole
  # bundle ends up unsigned.
  #
  # Fix: move the store under Contents/Resources (sealed as ordinary hashed
  # resources, never as nested bundles) and leave a relative symlink at the
  # original path. native-comp-eln-load-path keeps pointing at
  # Contents/Frameworks/native-lisp and resolves through the symlink transparently,
  # so eln loading is unchanged -- but `codesign --deep` + `--verify --strict` now
  # both succeed.
  local app="$1" fw="$1/Contents/Frameworks/native-lisp"
  [ -d "$fw" ] && [ ! -L "$fw" ] || return 0
  log "Relocating native-lisp out of Frameworks (lets codesign seal the bundle)"
  rm -rf "$app/Contents/Resources/native-lisp"
  mv "$fw" "$app/Contents/Resources/native-lisp"
  ln -s "../Resources/native-lisp" "$fw"
}

install_terminfo() { # installs the xterm-emacs terminfo entry for the emacsclient wrapper
  # The emacsclient wrapper sets TERM=xterm-emacs so emacsclient -t/-nw frames get
  # unconditional 24-bit RGB (setf24/setb24), bypassing Emacs bug #70941's buggy
  # 16-color ANSI fast-path that distorts faces under palette-remapping terminal
  # themes (Catppuccin, Gruvbox, Nord, ...). That TERM is only useful if the entry
  # exists, so compile it into the per-user $HOME/.terminfo db (tic -x, no root).
  [ -f "$TERMINFO_SRC" ] || die "terminfo source not found: $TERMINFO_SRC"
  local tic; tic="$(command -v tic || true)"
  if [ -z "$tic" ]; then
    sub "warning: tic not found -- skipping xterm-emacs terminfo install (emacsclient 24-bit colors unavailable)"
    return 0
  fi
  log "Installing xterm-emacs terminfo (24-bit color for emacsclient -t/-nw)"
  if "$tic" -x -o "$HOME/.terminfo" "$TERMINFO_SRC" >/dev/null 2>&1; then
    sub "compiled xterm-emacs -> $HOME/.terminfo"
  else
    sub "warning: tic failed on $TERMINFO_SRC -- emacsclient 24-bit colors unavailable"
  fi
}

prune_stale_eln() { # app
  # 'gmake install' (install-eln) is purely ADDITIVE: it copies the worktree's
  # native-lisp into the bundle but never removes version dirs already there. The
  # install-target bundle ($SRC/nextstep/Emacs.app) PERSISTS across builds, so once
  # the eln version-dir name changes (e.g. a fork-emacs change to comp-native-
  # version-dir, like the NS_SELF_CONTAINED dot->underscore conversion), the old
  # dir lingers and ships forever as dead weight -- Emacs only loads from the dir
  # named by the *current* binary's comp-native-version-dir.
  #
  # Keep exactly that one dir; drop the rest. Also sanity-check it's populated: a
  # near-empty dir means the full AOT didn't run (it triggers only when 'make'
  # visits the absent ../native-lisp target -- see stage_build), and the user
  # should do a clean build.
  # NOTE: even a SKIP_AOT build keeps the live verdir -- an aot binary's dump always
  # bakes in a minimal PRELOADED eln set (e.g. ns-win.eln) that it dlopens at startup,
  # so the live verdir must ship intact or the app won't boot. We only drop OTHER
  # (stale) verdirs here; SKIP_AOT just means the live dir holds the preloaded handful
  # rather than the full set.
  local app="$1" nl="$1/Contents/Frameworks/native-lisp" verdir d n
  [ -d "$nl" ] || { sub "warning: no native-lisp in bundle -- native-comp AOT did not install"; return 0; }
  verdir="$("$app/Contents/MacOS/Emacs" --batch --eval '(princ comp-native-version-dir)' 2>/dev/null)"
  [ -n "$verdir" ] || { sub "warning: could not read comp-native-version-dir; leaving native-lisp as-is"; return 0; }
  log "Pruning native-lisp to the live version dir ($verdir)"
  for d in "$nl"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    if [ "$(basename "$d")" != "$verdir" ]; then
      sub "removing stale $(basename "$d")"
      rm -rf "$d"
    fi
  done
  [ -d "$nl/$verdir" ] || { sub "warning: live eln dir $verdir absent -- AOT produced none for this binary"; return 0; }
  n="$(find "$nl/$verdir" -name '*.eln' | wc -l | tr -d ' ')"
  sub "$verdir: $n .eln"
  if [ "${SKIP_AOT:-0}" = 1 ]; then
    sub "SKIP_AOT: preloaded elns only; the bulk lisp runs as byte-code"
  elif [ "$n" -lt 100 ]; then
    sub "warning: only $n .eln in the live dir -- AOT likely incomplete; do a clean rebuild (build.sh prepare && build.sh) to force a full AOT"
  fi
}

# Run prepare unless told to reuse the worktree as-is (SKIP_PREPARE=1). If the
# worktree doesn't exist yet, prepare always runs -- there's nothing to reuse.
run_prepare() {
  if [ "${SKIP_PREPARE:-0}" = 1 ] && git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "SKIP_PREPARE=1 -> reusing existing worktree (no reset, no re-patch)"
    return
  fi
  stage_prepare
}

# --------------------------------------------------------------------- dispatch
target="${1:-package}"
case "$target" in
  prepare)     run_prepare ;;
  configure)   run_prepare; stage_configure ;;
  build)       run_prepare; stage_configure; stage_build ;;
  package|all) run_prepare; stage_configure; stage_build; stage_package ;;
  make)        SKIP_PREPARE=1 run_prepare; stage_configure; stage_build ;;
  repackage)   SKIP_PREPARE=1 run_prepare; stage_configure; stage_build; stage_package ;;
  *) die "unknown stage: $target (use: prepare|configure|build|package|make|repackage)" ;;
esac
