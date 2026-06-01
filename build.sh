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
#   * builds Emacs Client.app from your no-frame emacsgui.applescript;
#   * installs into a private prefix and deploys the two .app bundles.
#
# Usage:
#   build.sh                 # full pipeline
#   build.sh prepare         # export master + apply patches only
#   build.sh configure       # ... through ./configure (validates the toolchain)
#   build.sh build           # ... through gmake (the long step)
#   build.sh package         # install + icon + client app + sign + deploy
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
PREFIX="${EMACS_PREFIX:-$HOME/.local/opt/emacs-plus}"
BUILD_DIR="${EMACS_BUILD_DIR:-$HOME/.cache/emacs-plus}"
APPS_DIR="${EMACS_APPS_DIR:-$HOME/Applications}"
CFG="${EMACS_PLUS_BUILD_CONFIG:-$HOME/.config/emacs-plus/build.yml}"
LAUNCHER_SRC="${EMACS_LAUNCHER_SRC:-$HOME/google-drive/dotfiles/.local/bin/emacsgui.applescript}"
BASELINE_PATCHES=(fix-ns-x-colors system-appearance)

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
  local args=(
    --disable-dependency-tracking
    --disable-silent-rules
    --enable-locallisppath="$PREFIX/share/emacs/site-lisp"
    --infodir="$PREFIX/share/info/emacs"
    --prefix="$PREFIX"
    --with-native-compilation=aot
    --with-xml2 --with-gnutls --with-modules --with-rsvg --with-webp
    --without-dbus --without-imagemagick
    --with-ns --disable-ns-self-contained
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
  log "Building with gmake -j$JOBS (this is the long one)"
  ( cd "$SRC" && gmake -j"$JOBS" )
}

stage_package() {
  log "Installing into $PREFIX"
  rm -rf "$PREFIX"
  ( cd "$SRC" && gmake install )

  # NS build drops the app under nextstep/; move it (and AOT eln) into the prefix.
  local app="$PREFIX/Emacs.app"
  rm -rf "$app"
  mv "$SRC/nextstep/Emacs.app" "$app"
  [ -d "$SRC/native-lisp" ] && cp -R "$SRC/native-lisp" "$app/Contents/native-lisp"
  local res="$app/Contents/Resources"

  apply_icon "$res" "$app/Contents/Info.plist"
  build_client_app "$res"
  write_site_lisp
  inject_lsenvironment "$app/Contents/Info.plist" "$app"

  log "Signing (ad-hoc, required on recent macOS)"
  codesign --force --deep --sign - "$app" >/dev/null 2>&1 || sub "warning: codesign Emacs.app failed"
  codesign --force --deep --sign - "$PREFIX/Emacs Client.app" >/dev/null 2>&1 || sub "warning: codesign client failed"

  log "Deploying to $APPS_DIR"
  mkdir -p "$APPS_DIR"
  rm -rf "$APPS_DIR/Emacs.app" "$APPS_DIR/Emacs Client.app"
  cp -R "$app" "$APPS_DIR/Emacs.app"
  cp -R "$PREFIX/Emacs Client.app" "$APPS_DIR/Emacs Client.app"

  log "Done."
  sub "Emacs.app        -> $APPS_DIR/Emacs.app"
  sub "Emacs Client.app -> $APPS_DIR/Emacs Client.app"
  sub "binaries         -> $PREFIX/bin (emacs, emacsclient)"
  sub "To make this the daemon, point your LaunchAgent at $PREFIX/bin/emacs --fg-daemon"
}

apply_icon() { # resources_dir info_plist
  local res="$1" plist="$2" line kind loc sha car name target="$1/Emacs.icns"
  line="$(resolve_icon || true)"
  [ -n "$line" ] || { sub "no icon configured"; return; }
  IFS=$'\t' read -r kind loc sha car name <<<"$line"
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

build_client_app() { # icons_dir (for the shared Emacs.icns)
  local res="$1"
  local ec="$PREFIX/bin/emacsclient"
  local app="$PREFIX/Emacs Client.app"
  local plist="$app/Contents/Info.plist"
  local nspath="$HB/bin:$HB/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
  log "Building Emacs Client.app from $LAUNCHER_SRC"
  [ -f "$LAUNCHER_SRC" ] || die "launcher source missing: $LAUNCHER_SRC"

  # Reuse the no-frame launcher logic verbatim; only repoint `property ec`.
  local tmpscript; tmpscript="$(mktemp -t emacs-client).applescript"
  sed -E "s#^property ec :.*#property ec : \"PATH='$nspath' $ec\"#" "$LAUNCHER_SRC" >"$tmpscript"

  rm -rf "$app"
  osacompile -o "$app" "$tmpscript"
  rm -f "$tmpscript"

  pb() { $PB -c "Set :$1 $3" "$plist" 2>/dev/null || $PB -c "Add :$1 $2 $3" "$plist"; }
  pb CFBundleName string "Emacs Client"
  pb CFBundleDisplayName string "Emacs Client"
  pb CFBundleIdentifier string "com.andrea.emacs-client"
  pb OSAAppletShowStartupScreen bool false

  $PB -c "Delete :CFBundleDocumentTypes" "$plist" 2>/dev/null || true
  $PB -c "Add :CFBundleDocumentTypes array" "$plist"
  $PB -c "Add :CFBundleDocumentTypes:0 dict" "$plist"
  $PB -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string Text Document" "$plist"
  $PB -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Editor" "$plist"
  $PB -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" "$plist"
  local i=0 uti
  for uti in public.text public.plain-text public.source-code public.script public.shell-script public.data; do
    $PB -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:$i string $uti" "$plist"; i=$((i+1))
  done
  $PB -c "Delete :CFBundleURLTypes" "$plist" 2>/dev/null || true
  $PB -c "Add :CFBundleURLTypes array" "$plist"
  $PB -c "Add :CFBundleURLTypes:0 dict" "$plist"
  $PB -c "Add :CFBundleURLTypes:0:CFBundleURLName string Org Protocol" "$plist"
  $PB -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$plist"
  $PB -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string org-protocol" "$plist"

  # Share the same icon as Emacs.app
  [ -f "$res/Emacs.icns" ] && cp -f "$res/Emacs.icns" "$app/Contents/Resources/applet.icns"
  if [ -f "$res/Assets.car" ]; then cp -f "$res/Assets.car" "$app/Contents/Resources/Assets.car"; fi
  pb CFBundleIconFile string applet
}

write_site_lisp() {
  local dir="$PREFIX/share/emacs/site-lisp"
  mkdir -p "$dir"
  log "Writing site-start.el (ns-emacs-plus-version = $MAJOR)"
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
