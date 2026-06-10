# Fix the NS daemon "can't reopen from the Dock" defect

**Read first:** [`macos-app-lifecycle-investigation.md`](./macos-app-lifecycle-investigation.md)
— the validated diagnosis this implements.

## Status: IMPLEMENTED (`fork-emacs`, branch `fix-macos-lifecycle`)

Two commits, deliberately split for upstream review:

- **Patch A — `f8d8ce7` "ns: make a frameless daemon reopenable from the Dock"**
  (`src/nsterm.m`, `lisp/term/ns-win.el`). The headline fix: never park in
  `Prohibited`, implement `applicationShouldHandleReopen:`, handle the
  `ns-new-frame` event while frameless, and dispatch `[ns-new-frame]` as a
  **special event** so the *first* Dock click creates the frame (§3.3.1). NS-local,
  conventional Cocoa.
- **Patch B — `54ed7bf` "Don't let closing a clientless frame kill a daemon"**
  (`lisp/files.el`, `lisp/server.el`). Closing a *non-client* frame in a daemon
  (e.g. a Dock/reopen frame) used to fall through to `save-buffers-kill-emacs` and
  kill the daemon. Generalizes the protection Emacs already gives *client* frames.
  Touches generic core → expect more review; stands alone.

Also delivered as a single `build.yml` local patch (`ns-daemon-reopen.patch`,
regenerated from `d0653..fix-macos-lifecycle`) for this repo's master-based builds.

This doc records the **as-built** design (which diverged from the original plan in
a few deliberate ways — see "Design notes / deviations" below) plus the build/test
loop, acceptance criteria, open questions for upstream, and cleanup.

---

## 1. Goal (one paragraph)

When an Emacs **daemon** loses its last GUI frame it parks in
`NSApplicationActivationPolicyProhibited`. `Prohibited` "may not create windows or
be activated," and the NS port implements **no
`applicationShouldHandleReopen:hasVisibleWindows:`**, so the native macOS gesture —
click the pinned Dock icon / open `Emacs.app` from Finder — produces an **inert app
with no frame**; the user must rescue it with `emacsclient -c` from a terminal.
Patch A stops parking in `Prohibited` and implements the reopen contract so a click
yields a frame; Patch B ensures that frame, once closed again, drops cleanly back
to a frameless daemon instead of killing it.

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
6. **Non-daemon "stay alive frameless" — DESCOPED (infeasible).** The original
   plan floated a `defcustom` to keep a *non-daemon* Emacs alive (frameless, no
   hidden frame) when its last frame closes, to retire osx-pseudo-daemon for
   non-daemon users too. **This cannot be done without a hidden frame.**
   `src/frame.c`'s `delete_frame` errors `"Attempt to delete the only frame"` when
   no *other* frame exists — even with `force` (only the internal `Qnoelisp` force
   bypasses it, and that path calls `Fkill_emacs`). A non-daemon Emacs has no
   always-present initial terminal frame (that is exactly what `--daemon` provides),
   so it **fundamentally cannot run frameless**. osx-pseudo-daemon keeps a hidden
   frame for precisely this reason. The honest answer for non-daemon users is "run
   a daemon" (Patches A+B serve that fully) or "keep osx-pseudo-daemon." For a
   **daemon**, A+B already retire osx-pseudo-daemon (reopen half → A; keep-alive is
   intrinsic to the daemon, with B making frame-close non-fatal).
7. **Scope:** this defect only (Patches A+B). Out of scope (explicitly deferred):
   the non-daemon stay-alive feature (#6, infeasible), URL-scheme handling
   (`application:openURLs:` / `org-protocol://`), and any separate launcher app.

---

## Design notes / deviations (as-built, Patch B)

These choices were settled with the user and differ from the first-draft plan:

1. **Window-system-agnostic.** Patch B gates on `(daemonp)`, **not** on
   `(eq (framep …) 'ns)`. The rule — *a daemon is killed only by explicit
   `kill-emacs` / `server-stop-automatically`, never by a frame-close gesture* — is
   true for any daemon (X/pgtk/w32 too); only the *Dock trigger* is NS-specific.
   Framing it as "generalize the protection client frames already get to all of a
   daemon's frames" is the upstream-defensible story.
2. **One shared helper, no duplicated logic.** `server-save-buffers-kill-terminal-noclient`
   (in `server.el`) holds the whole "last frame? honor `server-stop-automatically`?
   else `delete-frame`" decision. Both the `'nowait` emacsclient branch *and* the
   non-client daemon case (`files.el`) call it, so a Dock/reopen frame and a
   `nowait` emacsclient frame behave **identically in every config**. Key enabling
   fact: `emacs --daemon` always starts the server, so `(daemonp) ⟹ server running`
   — deferring this to server.el is legitimate reuse, not improper coupling.
3. **Reopen frames stay non-client.** The C reopen handler creates a plain
   `make-frame` frame (`client = nil`), *not* a dummy `'nowait` client. The C side
   stays uniform (it can't know about daemons/clients); all kill-vs-delete policy
   lives in Lisp. Tagging reopen frames `'nowait` was rejected: it would be a lie
   (no emacsclient involved) and would couple the reopen path to server.el even in
   the non-daemon case.
4. **Save-on-close is retained (data safety).** Closing the last frame still offers
   to save modified buffers (`save-some-buffers`), exactly as a fileless
   `emacsclient -c` does. A daemon silently accumulating unsaved buffers that vanish
   on reboot is both un-macOS-like and dangerous; closing the last frame is the
   right moment to flush. Deleting a frame loses no buffer data, but the *prompt* is
   a deliberate safety reminder.

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

#### 3.3.1 REQUIRED companion: dispatch `[ns-new-frame]` as a *special event*

**Empirically validated (instrumented build, single-click trace).** The handler
above is necessary but **not sufficient**: with `[ns-new-frame]` bound in
`global-map` (the stock binding), the **first** Dock click on a frameless daemon
produced *no frame* — a second click was needed. The instrumentation showed the
reopen *does* fire on click 1 (`flag=0`), `newFrame:` *does* run and queue the
`ns-new-frame` event (`emacs_event` non-null, no early return) — but the event
just **sits in the keyboard buffer**. An idle, frameless daemon's command loop
won't dispatch a `global-map` key event until the *next* input arrives: it has no
focused-frame / current-keyboard context to run `read-key-sequence` against (the
event is tagged to the NS keyboard; the daemon's loop is reading the initial
terminal). Click 2 supplies that context and flushes it.

**Fix:** bind `[ns-new-frame]` in **`special-event-map`** instead of `global-map`
(`lisp/term/ns-win.el`). Special events are run by `read-char` the instant the
buffer is read — regardless of focus/current-keyboard — so `ns_send_appdefined`
waking the loop is enough, and the **first** click creates the frame. This is
folded into Patch A. (`make-frame` from a special-event context proved fine for
the idle-daemon case in testing; watch for reentrancy only if it's ever triggered
mid-redisplay, which the reopen path is not.)

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

### 3.5 Patch B — daemon survives closing a clientless frame (`files.el`, `server.el`)

This is the **as-built** companion to Patch A; it replaces the original plan's
NS-gated clause and the (infeasible) non-daemon stay-alive idea.

`save-buffers-kill-terminal` (`C-x C-c`) dispatches on `(frame-parameter nil
'client)`. A non-client frame fell to `(save-buffers-kill-emacs)` and killed the
daemon. Change:

- `lisp/server.el`: new shared helper **`server-save-buffers-kill-terminal-noclient`**
  — `(save-some-buffers arg) (delete-frame)` unless this is the last frame standing
  (honoring `server-stop-automatically`, discounting the daemon's initial frame),
  in which case `save-buffers-kill-emacs`. The `'nowait` branch of
  `server-save-buffers-kill-terminal` now calls it.
- `lisp/files.el`: `save-buffers-kill-terminal` gains a middle `cond` clause — in a
  daemon, route a **clientless** frame through that helper instead of killing Emacs.

See "Design notes / deviations" above for *why* it's WS-agnostic, why one shared
helper, why reopen frames stay non-client, and why save-on-close is retained.

> **Note on the window-close (red-button) gesture vs `C-x C-c`.** Patch B covers the
> `C-x C-c` / `save-buffers-kill-terminal` path. The red-button close goes through
> `handle-delete-frame` (`lisp/frame.el:263`) — but in a **daemon** that already
> finds the always-present initial frame as an "other" frame and just deletes,
> so the daemon survives a red-button close with no change needed. (A *non-daemon*
> would quit there; making it stay alive is the descoped, infeasible §2.6.)

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

### Development iteration loop (do NOT recompile release each time)

Iterate **only in the DEBUG worktree** — release stays untouched:

1. Edit `~/.cache/emacs-plus/emacs-debug/src/nsterm.m` (and `lisp/term/ns-win.el`)
   directly — this is your fast scratch copy.
2. `DEBUG=1 ./build.sh make` (incremental: recompiles just the changed file +
   relink + redump, seconds) then `DEBUG=1 ./build.sh repackage` to deploy.
3. Repeat. **Use only `make`/`repackage`** (they imply `SKIP_PREPARE`, so the
   worktree is not reset and your edits + incremental objects survive). Never run
   `prepare` / bare `./build.sh` mid-iteration — it resets the worktree to the ref
   and re-applies `build.yml` patches, wiping your edits.

Notes:
- DEBUG and release have **separate object dirs**, so iterating in DEBUG never
  churns the release build. The release worktree (`…/emacs`) is only needed for a
  final shippable build.
- Both modes deploy to the **same** `~/Applications/Emacs.app`, so while iterating
  the deployed app is the DEBUG build (fine for testing); restore release at the
  end (`./build.sh repackage`, no DEBUG).
- **Capturing a clean patch:** the debug worktree already carries `build.yml`
  patches as uncommitted changes, so a plain `git diff` mixes them with your work.
  Snapshot the patched baseline first — e.g. `git -C <debug-worktree> stash` is not
  safe (resets); instead `git -C <debug-worktree> commit -am wip-baseline` *before*
  editing, then `git diff` after gives only your change. Transcribe that into
  `fork-emacs` / a `build.yml` patch as the deliverable.

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
4. **Daemon survives `C-x C-c` on a clientless frame (Patch B).** In a Dock/reopen
   frame, `C-x C-c` offers to save, deletes the frame, and the **daemon keeps
   running** (it does not exit). Without server-stop-automatically this holds for
   any number of frames; the same applies to a `nowait` (`emacsclient -n -c`) frame
   — verify the two are indistinguishable.
5. **`server-stop-automatically` still honored.** With it set to
   `kill-terminal`/`delete-frame`, closing the last real frame *does* shut the
   daemon down — identically whether that frame is a Dock/reopen (non-client) frame
   or a `nowait` frame.
6. **Non-daemon unchanged:** a plain `Emacs.app` still quits on `C-x C-c` /
   last-frame close (the non-daemon stay-alive feature is descoped — §2.6).
7. **`⌘Q` / "Quit Emacs" still quits**, and `ns-confirm-quit` behavior is
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
