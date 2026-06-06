#!/usr/bin/env bash
#
# Standalone Emacs build pipeline that consumes ~/.config/emacs-plus/build.yml
# in the SAME schema as the d12frosted/emacs-plus formula, so the two stay
# interchangeable (icon / patches / inject_path).
#
# It reproduces what `brew install emacs-plus@32` would do, but:
#   * builds from a local git ref (this fork-emacs `master`) via an isolated,
#     detached worktree -- your working checkout is never touched;
#   * applies a fixed baseline (fix-ns-x-colors + system-appearance) plus every
#     patch listed in build.yml (local / external / community), sha256-verified;
#   * wires native-compilation (libgccjit) for both build and runtime;
#   * builds a SELF-CONTAINED Emacs.app (binaries, lisp, native-lisp all inside
#     the bundle -- no Unix prefix split);
#   * applies the app icon from a loose .icon under ./assets/icons when build.yml
#     names a locally-bundled icon (compiled to Assets.car via actool), else falls
#     back to the emacs-plus tap;
#   * deploys Emacs.app to ~/Applications and symlinks emacs/emacsclient
#     (from inside Emacs.app) onto PATH.
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
set -euo pipefail

# ---------------------------------------------------------------- configuration
REPO="${EMACS_SRC_REPO:-/Users/andrea/Documents/Programming/Others/fork-emacs}"
REF="${EMACS_SRC_REF:-master}"
MAJOR="${EMACS_MAJOR:-32}"
BUILD_DIR="${EMACS_BUILD_DIR:-$HOME/.cache/emacs-plus}"   # internal build cache (worktree + objects)
APPS_DIR="${EMACS_APPS_DIR:-$HOME/Applications}"
BIN_DIR="${EMACS_BIN_DIR:-$HOME/.local/bin}"            # PATH bin dir for the emacs/emacsclient entry points
CFG="${EMACS_PLUS_BUILD_CONFIG:-$HOME/.config/emacs-plus/build.yml}"
BASELINE_PATCHES=(round-undecorated-frame fix-ns-x-colors system-appearance)

# This script's own directory, so it can find its bundled ./assets (loose icon
# sources) regardless of where it's invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICONS_DIR="${EMACS_ICONS_DIR:-$SCRIPT_DIR/assets/icons}"   # loose <name>.icon sources compiled at build time

SRC="$BUILD_DIR/emacs"
HB="$(brew --prefix)"
TAP="$(brew --repository)/Library/Taps/d12frosted/homebrew-emacs-plus"
JOBS="$(sysctl -n hw.ncpu)"
PB=/usr/libexec/PlistBuddy

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
sub()  { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$CFG" ] || die "build.yml not found: $CFG"
[ -d "$TAP" ] || die "emacs-plus tap not found (needed for baseline + registry): $TAP"
command -v ruby >/dev/null || die "ruby required for YAML parsing"

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

# ------------------------------------------------------- build.yml: patch resolver
# Emits TSV: kind<TAB>name<TAB>path_or_url<TAB>sha256   (mirrors EmacsBase#resolve_patches)
resolve_patches() {
  CFG="$CFG" TAP="$TAP" MAJOR="$MAJOR" ruby -ryaml -rjson -e '
    cfg = YAML.safe_load(File.read(ENV["CFG"]), permitted_classes: [Symbol]) || {}
    home = Dir.home; cfgdir = File.dirname(ENV["CFG"])
    local = ->(u){ %w[/ ./ ../ ~].any? { |p| u.start_with?(p) } }
    (cfg["patches"] || []).each do |p|
      if p.is_a?(String)
        reg = (JSON.parse(File.read("#{ENV["TAP"]}/community/registry.json")) rescue {"patches"=>{}})
        info = reg.dig("patches", p) or abort "Unknown community patch: #{p}"
        puts ["community", p, "#{ENV["TAP"]}/community/#{info["directory"]}/emacs-#{ENV["MAJOR"]}.patch", ""].join("\t")
      elsif p.is_a?(Hash)
        name = p.keys.first; spec = p[name] || {}
        abort "patch #{name}: url+sha256 required" unless spec["url"] && spec["sha256"]
        url = spec["url"]
        if local.call(url)
          exp = url.sub(/\A~/, home)
          exp = exp.start_with?("/") ? exp : File.expand_path(exp, cfgdir)
          puts ["local", name, exp, spec["sha256"]].join("\t")
        else
          puts ["external", name, url, spec["sha256"]].join("\t")
        end
      end
    end'
}

# Emits TSV: kind<TAB>path_or_url<TAB>sha256<TAB>tahoe_path<TAB>tahoe_name  (or nothing)
resolve_icon() {
  CFG="$CFG" TAP="$TAP" ruby -ryaml -rjson -e '
    cfg = YAML.safe_load(File.read(ENV["CFG"]), permitted_classes: [Symbol]) || {}
    icon = cfg["icon"]; exit unless icon
    if icon.is_a?(String)
      reg = (JSON.parse(File.read("#{ENV["TAP"]}/community/registry.json")) rescue {"icons"=>{}})
      info = reg.dig("icons", icon) or abort "Unknown icon: #{icon}"
      dir = "#{ENV["TAP"]}/community/#{info["directory"]}"
      icns = "#{dir}/icon.icns"; abort "missing #{icns}" unless File.exist?(icns)
      car = File.exist?("#{dir}/Assets.car") ? "#{dir}/Assets.car" : ""
      name = (JSON.parse(File.read("#{dir}/metadata.json"))["tahoe_icon_name"] rescue nil) || "Emacs"
      puts ["community", icns, "", car, name].join("\t")
    elsif icon.is_a?(Hash) && icon["url"] && icon["sha256"]
      puts ["external", icon["url"], icon["sha256"], "", "Emacs"].join("\t")
    end'
}

inject_user_path() {  # true unless build.yml sets inject_path: false
  CFG="$CFG" ruby -ryaml -e '
    c = YAML.safe_load(File.read(ENV["CFG"]), permitted_classes: [Symbol]) || {}
    exit(c.key?("inject_path") && c["inject_path"] == false ? 1 : 0)'
}

verify_sha256() { # file expected
  local actual; actual="$(shasum -a 256 "$1" | awk '{print $1}')"
  [ "$actual" = "$2" ] || die "sha256 mismatch for $1
  expected: $2
  actual:   $actual"
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

  log "Applying baseline patches: ${BASELINE_PATCHES[*]}"
  local p
  for p in "${BASELINE_PATCHES[@]}"; do
    local f="$TAP/patches/emacs-$MAJOR/$p.patch"
    [ -f "$f" ] || die "baseline patch missing: $f"
    sub "$p"
    patch -p1 -d "$SRC" --no-backup-if-mismatch -i "$f" >/dev/null || die "baseline patch failed: $p"
  done

  log "Applying build.yml patches"
  local kind name loc sha tmp
  while IFS=$'\t' read -r kind name loc sha; do
    [ -n "$kind" ] || continue
    sub "$name ($kind)"
    case "$kind" in
      community)
        patch -p1 -d "$SRC" --no-backup-if-mismatch -i "$loc" >/dev/null || die "patch failed: $name" ;;
      local)
        [ -f "$loc" ] || die "local patch not found: $loc"
        verify_sha256 "$loc" "$sha"
        patch -p1 -d "$SRC" --no-backup-if-mismatch -i "$loc" >/dev/null || die "patch failed: $name" ;;
      external)
        tmp="$(mktemp -t emacs-patch).patch"
        curl -fsSL -o "$tmp" "$loc" || die "download failed: $name ($loc)"
        verify_sha256 "$tmp" "$sha"
        patch -p1 -d "$SRC" --no-backup-if-mismatch -i "$tmp" >/dev/null || die "patch failed: $name"
        rm -f "$tmp" ;;
    esac
  done < <(resolve_patches)
}

stage_configure() {
  log "Configuring (native-compilation=aot, gcc-$GCC_MAJOR)"
  export PKG_CONFIG_PATH="$HB/lib/pkgconfig:$HB/share/pkgconfig"
  local dep d
  for dep in gnutls librsvg little-cms2 tree-sitter webp sqlite zlib libxml2 jpeg gmp; do
    d="$(brew --prefix "$dep" 2>/dev/null)/lib/pkgconfig"
    [ -d "$d" ] && PKG_CONFIG_PATH="$d:$PKG_CONFIG_PATH"
  done
  export LDFLAGS="-L$SQLITE/lib -L$GCC_LIB -Wl,-rpath,$GCC_LIB -L$HB/lib"
  export LIBRARY_PATH="$LIBRARY_PATH_VALUE"

  local cflags="-DFD_SETSIZE=10000 -DDARWIN_UNLIMITED_SELECT -I$SQLITE/include -I$GCC_PREFIX/include -I$GCCJIT/include -I$HB/include"
  # Self-contained Emacs.app: everything (binaries, lisp, native-lisp, info) lands
  # INSIDE the bundle. No --prefix / Unix split / locallisppath -- that layout only
  # existed because emacs-plus is a Homebrew keg; this is a personal build.
  local args=(
    --disable-dependency-tracking
    --disable-silent-rules
    --with-native-compilation=aot
    --with-xml2 --with-gnutls --with-modules --with-rsvg --with-webp
    --without-dbus --without-imagemagick
    --with-ns
    "CFLAGS=$cflags"
  )

  ( cd "$SRC"
    [ -x ./configure ] || { log "autogen.sh"; ./autogen.sh; }
    if [ ! -f Makefile ] || [ "${RECONFIGURE:-0}" = 1 ]; then
      ./configure "${args[@]}"
    else
      sub "Makefile present -- skipping configure (RECONFIGURE=1 to force)"
    fi )
}

stage_build() {
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
  # Pin the .el/.el.gz SOURCES into the past so every .elc is unambiguously newer.
  # (Bumping .elc to "now" instead is racy: install writes .elc and .el.gz within
  # the same wall-clock second, and at APFS sub-second resolution the touch
  # intermittently still leaves a .el.gz ahead of its .elc.) .eln native selection
  # is keyed on the source hash, not mtime, so native-comp is unaffected.
  log "Pinning .el/.el.gz sources to epoch so .elc always wins (load-prefer-newer)"
  find "$app_src/Contents/Resources" \( -name '*.el.gz' -o -name '*.el' \) \
    -exec touch -t 197001020000 {} +
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
  # copy time, which clobbers the epoch-pin on .el/.el.gz above and re-introduces
  # the load-prefer-newer jka-compr recursion in the *deployed* app.
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
  # emacsclient only talks to the daemon -- no bundle paths needed, symlink is fine.
  ln -sfn "$app/$client_rel"          "$BIN_DIR/emacsclient"
  sub "wrote   $BIN_DIR/emacs       -> exec Contents/MacOS/Emacs"
  sub "linked  $BIN_DIR/emacsclient -> $client_rel"

  log "Done."
  sub "Emacs.app    -> $app"
  sub "executables  -> $BIN_DIR/emacs (wrapper), $BIN_DIR/emacsclient (symlink into the bundle)"
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
  local res="$1" plist="$2" line kind loc sha car name target="$1/Emacs.icns"
  # Prefer a locally-bundled loose .icon matching build.yml's `icon:` (fully
  # contained, compiled via actool); otherwise fall back to the emacs-plus tap.
  local key; key="$(CFG="$CFG" ruby -ryaml -e 'c=YAML.safe_load(File.read(ENV["CFG"]))||{}; i=c["icon"]; print(i.is_a?(String) ? i : "")')"
  if [ -n "$key" ] && [ -d "$ICONS_DIR/$key.icon" ]; then
    compile_icon "$ICONS_DIR/$key.icon" "$res" "$plist"
    return
  fi
  line="$(resolve_icon || true)"
  [ -n "$line" ] || { sub "no icon configured"; return; }
  # Split the TSV one field per line (tab->newline) instead of `IFS=$'\t' read`:
  # tab is an IFS-whitespace char, so read would COLLAPSE the empty sha field
  # that community icons emit, shifting car/name left and skipping the Assets.car
  # copy below. One read per field preserves empty fields.
  { read -r kind; read -r loc; read -r sha; read -r car; read -r name; } \
    < <(printf '%s\n' "$line" | tr '\t' '\n')
  log "Applying icon ($kind)"
  if [ "$kind" = external ]; then
    local tmp; tmp="$(mktemp -t icon).icns"
    curl -fsSL -o "$tmp" "$loc" || die "icon download failed"
    verify_sha256 "$tmp" "$sha"; loc="$tmp"
  fi
  cp -f "$loc" "$target"
  if [ -n "${car:-}" ] && [ -f "$car" ]; then
    cp -f "$car" "$res/Assets.car"
    $PB -c "Delete :CFBundleIconName" "$plist" 2>/dev/null || true
    $PB -c "Add :CFBundleIconName string ${name:-Emacs}" "$plist"
  fi
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
  if inject_user_path; then
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
  [ "$n" -ge 100 ] || sub "warning: only $n .eln in the live dir -- AOT likely incomplete; do a clean rebuild (build.sh prepare && build.sh) to force a full AOT"
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
