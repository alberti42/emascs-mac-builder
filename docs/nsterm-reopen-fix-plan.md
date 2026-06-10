# Implementation handoff: fix the NS daemon "can't reopen from the Dock" defect

**For:** a fresh agent implementing the `nsterm.m` patch.
**Read first:** [`macos-app-lifecycle-investigation.md`](./macos-app-lifecycle-investigation.md)
— the validated diagnosis this plan implements. Don't re-investigate the root
cause; it's settled and evidence-backed.

This document is self-contained: goal, settled decisions, exact changes, where the
code lives, the build/test loop, acceptance criteria, known risks, and cleanup.

---

## 1. Goal (one paragraph)

When an Emacs **daemon** loses its last GUI frame it parks in
`NSApplicationActivationPolicyProhibited` (verified: `ns_delete_terminal`,
`nsterm.m` ~5917). `Prohibited` "may not create windows or be activated," and the
NS port implements **no `applicationShouldHandleReopen:hasVisibleWindows:`**, so
the native macOS gesture — click the pinned Dock icon / open `Emacs.app` from
Finder — produces an **inert app with no frame**; the user must rescue it with
`emacsclient -c` from a terminal. Fix: stop parking in `Prohibited`, and implement
the reopen contract so a click yields a frame.

---

## 2. Settled design decisions (do NOT relitigate)

These were decided with the user; treat as fixed requirements:

1. **Drop `Prohibited` entirely** as the frameless state. It is the specific
   policy that cannot be reactivated, and is the direct cause of the bug.
2. **Frameless policy is a `defcustom`: `Regular` vs `Accessory`** (never
   `Prohibited`). `Regular` keeps a live, clickable tile (Mail/Notes model);
   `Accessory` hides the tile but is *still activatable*, so a pinned-icon/`open`
   click can still reopen it.
3. **Implement `applicationShouldHandleReopen:hasVisibleWindows:`** → on no visible
   window, create a frame via the existing `newFrame:` / `make-frame` path
   (`nsterm.m` ~6452; `[ns-new-frame]` → `make-frame`, `ns-win.el:200`).
4. **Both changes are required together.** A reopen handler can't fire while
   `Prohibited` (not activatable); dropping `Prohibited` without a handler leaves a
   live tile that does nothing on click.
5. **Opt-in via the user's `init.el`** (not `early-init.el` — the decision points
   fire at runtime, after init loads). **Orthogonal to the server**: do not touch
   `server-start`; the in-process reopen path needs no server.
6. **Scope:** this defect only. Out of scope (explicitly deferred): URL-scheme
   handling (`application:openURLs:` / `org-protocol://`), and any separate
   launcher app.

---

## 3. The changes

### 3.1 New customizable variable (template: `ns-confirm-quit`)

`ns-confirm-quit` is the model to copy: a Lisp-settable variable `DEFVAR`'d in C
and read at the decision point (used in `applicationShouldTerminate:`,
`nsterm.m` ~6765). Mirror it.

- Add a variable, suggested name **`ns-frameless-activation-policy`**, values the
  symbols `regular` (default) or `accessory`. `DEFVAR_LISP` it in the
  `syms_of_nsterm`/`syms_of_nsfns` area with a clear docstring, like
  `ns_confirm_quit`. (A `defcustom` wrapper in `lisp/term/ns-win.el` is optional
  polish; the `DEFVAR` is what C reads.)
- Optionally a second flag `ns-reopen-creates-frame` (default `t`) to let purists
  disable the reopen behavior. Keep it simple; default-on.

### 3.2 `ns_delete_terminal` — stop using `Prohibited` (`nsterm.m` ~5930)

Replace the unconditional `Prohibited` set:
```objc
#ifdef NS_IMPL_COCOA
  [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
#endif
```
with a read of `ns-frameless-activation-policy`: `accessory` →
`NSApplicationActivationPolicyAccessory`; `regular` → leave the app `Regular`
(keep the tile). **Never `Prohibited`.**

### 3.3 Implement the reopen handler (`nsterm.m`, EmacsApp delegate)

Add to the `EmacsApp` delegate (near `applicationDidBecomeActive:`, ~6848):
```objc
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender
                   hasVisibleWindows:(BOOL)flag
{
  if (!flag /* && ns-reopen-creates-frame non-nil */)
    [self newFrame:sender];
  return YES;
}
```
A throwaway prototype of exactly this (plus `fprintf` tracing) already exists in
the **DEBUG worktree** `~/.cache/emacs-plus/emacs-debug/src/nsterm.m` from the
investigation — read it for reference, but implement cleanly in the canonical
source (§4) and delete the tracing.

### 3.4 Restore `Regular` when a frame is (re)created — REQUIRED, locate this

When the app is `Accessory` (or `Prohibited` today) and a frame is created, the
policy must return to `Regular` so the new frame gets a normal menu bar and tile.
Empirically this already happens for `Prohibited → Regular` via `emacsclient -c`
(a backgrounded daemon goes Foreground when a frame appears), so **a code path
that restores `Regular` on ns-frame creation already exists — find it** (start
from `applicationDidFinishLaunching:` ~6589's upgrade block, and the ns frame
creation path) and ensure it triggers for the `Accessory` case too (and for the
reopen handler's `make-frame`). If the reopen handler ends up `Accessory` with a
visible frame and no menu bar, this step is missing.

---

## 4. Where the code lives & how to build

- **Canonical source:** `~/Documents/Programming/Others/fork-emacs` (the user's
  fork; `build.sh`'s `EMACS_SRC_REPO` default). **Implement here**, on a feature
  branch — not in the build worktrees (those are disposable `git worktree`
  checkouts under `~/.cache/emacs-plus/` that `stage_prepare` resets).
- **Build system:** `build.sh` in this repo (`emacs-mac-builder`). Relevant:
  - `DEBUG=1` → builds in its own worktree `~/.cache/emacs-plus/emacs-debug`,
    `-O0 -g3`, implies `SKIP_AOT` (skips bulk native-comp → fast). Use this for
    iteration.
  - Targets: `make` = gmake on the worktree as-is (no reset/re-patch);
    `repackage` = build + deploy as-is. Both imply `SKIP_PREPARE=1`, so local
    edits survive. Full `./build.sh` (or `prepare`) **resets** the worktree to the
    ref + re-applies `build.yml` patches.
  - To build your fork branch: point `EMACS_SRC_REF` at it (this triggers a
    `prepare`/reset to that ref), then `DEBUG=1 ./build.sh repackage`.
  - Deploys to `~/Applications/Emacs.app`; `emacs`/`emacsclient` wrappers in
    `~/.local/bin`.

### Delivery options (pick with the user)

1. **fork-emacs branch** consumed by setting `EMACS_SRC_REF` (simplest for the
   user's own builds).
2. **`build.yml` patch** — produce a `.patch`, reference it as a `local` entry
   (`{name: {url: <path>, sha256: ...}}`); `stage_prepare` applies it. Matches the
   repo's emacs-plus-compatible model and keeps the fork pristine.
3. **Upstream** — submit to debbugs. The reopen handler is conventional Cocoa;
   debbugs #79859 shows upstream is receptive to native-macOS dock work. Gate
   behind the `defcustom` (default = current behavior or `regular`) for
   acceptability.

---

## 5. Test plan & acceptance criteria

Use the **validated methodology** (see investigation doc §6) — and heed the two
gotchas, which cost real time:

- **`terminal-list` is unreliable for NS** (lists the `ns` terminal "live" even
  after teardown). Use **`lsappinfo`** (the `type=` field: `Foreground` /
  `BackgroundOnly`) and, while iterating, `fprintf(stderr,…)` tracing.
- **A background `--daemon` detaches stderr** (tracing not captured). Use
  **`--fg-daemon`** for any stderr logging. Interleave phase markers with
  `(princ "MARK …\n" #'external-debugging-output)`.

Always test on an **isolated, uniquely-named daemon** (`--fg-daemon=<name>`, its
own socket) so you never disturb the user's real daemon.

**Acceptance criteria:**

1. **Daemon, `regular` mode:** start daemon → `emacsclient -c` → close the frame →
   tile stays; **click the tile (or `open -a` the bundle) → a new frame appears.**
   Policy stays `Foreground` throughout.
2. **Daemon, `accessory` mode:** same, but after closing the frame the tile is gone
   (`lsappinfo` `BackgroundOnly`) yet **clicking a pinned `Emacs.app` / `open -a`
   still creates a frame**, and that frame has a normal menu bar (i.e. §3.4 fired,
   policy back to `Regular`). *Verify the open question below.*
3. **No `Prohibited`** appears in any post-close state (`lsappinfo` never shows the
   un-reactivatable state).
4. **Non-daemon unaffected:** a plain `Emacs.app` still quits on closing its last
   frame (`handle-delete-frame` → `save-buffers-kill-emacs`).
5. **`⌘Q` / "Quit Emacs" still quits**, and `ns-confirm-quit` behavior is
   unchanged.

---

## 6. Known risks / open questions to verify during implementation

- **Does `applicationShouldHandleReopen:` fire for an `Accessory` app** clicked via
  a *pinned Dock icon* / `open -a`? `Accessory` is documented as activatable, but
  confirm the reopen Apple event is actually delivered in this path. If not,
  `regular` mode is the reliable default and `accessory` may need a different
  reactivation hook.
- **§3.4 (Accessory→Regular on frame creation)** is the most likely place to get a
  half-broken result (frame with no menu bar). Test menu bar presence explicitly.
- **Bundle-id collision** when testing `open -a`: the user's real daemon and your
  test daemon share `org.gnu.Emacs`, so `open -a` is ambiguous and may hit the
  wrong one. Prefer a guided test where the user clicks the *pinned tile* of the
  test daemon, or temporarily test with the user's daemon stopped (ask first).
- **Multiple displays / spaces:** `ns_delete_terminal` is per-display; confirm
  behavior with a single display first.

---

## 7. Cleanup owed from the investigation (do this when done)

- `~/Applications/Emacs.app` is currently the **instrumented DEBUG build**. Restore
  the clean release build: `./build.sh repackage` (no `DEBUG`).
- Revert the throwaway `fprintf` tracing + prototype handler in the DEBUG worktree
  `~/.cache/emacs-plus/emacs-debug/src/nsterm.m` (or just let a `prepare` reset
  it).

---

## 8. Anchors (current `master` worktree; names authoritative)

- `src/nsterm.m`: `ns_delete_terminal` (~5917 → §3.2), `applicationDidFinishLaunching:`
  (~6589, the Regular upgrade → §3.4), `newFrame:` (~6452 → §3.3),
  `applicationDidBecomeActive:` (~6848, insert handler near here),
  `applicationShouldTerminate:` / `ns_confirm_quit` (~6765 → §3.1 template).
- `lisp/term/ns-win.el`: `[ns-new-frame] → make-frame` (200).
- `lisp/frame.el`: `handle-delete-frame` (263, the non-daemon quit path).
