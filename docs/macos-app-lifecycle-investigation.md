# NS Emacs macOS app-lifecycle: an investigation of the Dock / activation design

**Status:** investigation / bug-report draft
**Scope:** the GNU Emacs **NS port** (`--with-ns`, `NS_IMPL_COCOA`) on macOS.
**Goal:** move past "macOS Emacs is messy" to a *precise* statement of what the
current design does, where it is internally inconsistent, and why — so the
defect can be argued to upstream and fixed deliberately.

Code citations are by function/selector name (stable) with approximate line
numbers from the `master` worktree used for this build; the names are what
matter, line numbers may drift.

---

## 0. TL;DR

The NS port has **no implementation of the conventional macOS app lifecycle**
for the case of a *running process with no visible frame*. Concretely:

1. **There is no `applicationShouldHandleReopen:hasVisibleWindows:`** — the
   standard Cocoa hook every well-behaved Mac app uses to recreate a window when
   its Dock tile is clicked while it has none. Emacs simply does not implement it.
2. When the last frame on a display closes, `ns_delete_terminal` tries to
   **downgrade the live process from `Regular` to `Prohibited`** activation
   policy at runtime. macOS does **not reliably honor a downgrade out of
   `Regular`** once an app has shown windows. The result is a **ghost Dock tile**:
   the process is still shown as running, the code believes it is `Prohibited`,
   and — with no reopen handler — clicking the tile does nothing.

So a server/daemon Emacs, after you close its last GUI frame, becomes
**"running but unreachable from the Dock."** That is the bug. The root design
error is twofold: (a) relying on an activation-policy transition the OS does not
perform, and (b) never implementing the reopen contract that would make the Dock
tile meaningful in the first place. A secondary smell: **one activation policy is
applied regardless of how the process was launched**, conflating "headless server
that occasionally shows a GUI frame" with "GUI app that is momentarily frameless."

---

## 1. Background: what a native macOS app does

A normal macOS GUI app (`Regular` activation policy) **stays in the Dock with no
windows open** (Mail, Notes, Preview). Clicking its Dock tile while it has no
window triggers `applicationShouldHandleReopen:hasVisibleWindows:`, where the app
creates a fresh window. Closing the last *window* does **not** quit the app;
**`Cmd-Q`** quits it. This window-vs-app distinction is fundamental to the
platform.

The three activation policies (`NSApplicationActivationPolicy`):

| Policy | Dock tile | Menu bar | Can be activated / create windows? |
|---|---|---|---|
| `Regular` | yes | yes | yes |
| `Accessory` (`LSUIElement`) | no | no | **yes** — programmatically or by clicking a window |
| `Prohibited` | no | no | **no** — "may not create windows or be activated" |

Note the asymmetry that matters below: `Prohibited` apps *cannot be activated or
create windows*; `Accessory` apps *can*.

---

## 2. The mechanics (code-evidenced)

### 2.1 Startup & the activation-policy "upgrade"

- A bundled `Emacs.app` starts `Regular` (declared by `Info.plist`).
- `emacs --daemon` starts headless (no Dock tile).
- `applicationDidFinishLaunching:` (`nsterm.m` ~6589) contains the **upgrade**:
  ```objc
  if ([NSApp activationPolicy] == NSApplicationActivationPolicyProhibited) {
      [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
      [NSApp setApplicationIconImage: ...];
  }
  ```
  This `Prohibited → Regular` direction is **reliable**, and is why
  `emacsclient -c` against a headless daemon makes a Dock tile appear.

### 2.2 Frame creation

All GUI-frame creation bottoms out at Lisp `make-frame`:
- The Dock menu **"New Frame"** item (`nsterm.m` ~6168) → `newFrame:`
  (`nsterm.m` ~6452) → injects `KEY_NS_NEW_FRAME` → event `[ns-new-frame]`,
  which `ns-win.el:200` binds to **`make-frame`**.
- `emacsclient -c` → `server-create-window-system-frame` → `make-frame-on-display`
  (`server.el`) — i.e. `make-frame` with a display arg.

There is no socket magic here: the daemon and the Dock menu reach the *same*
`make-frame`. (Relevant when reasoning about whether a separate client/launcher
is required — for in-process frame creation it is not.)

### 2.3 Frame deletion

Two distinct paths:

**(a) Closing a window (red button / `Cmd-W`-style):**
`windowShouldClose:` (`nsterm.m` ~8313) posts a `DELETE_WINDOW_EVENT`, handled in
Lisp by `handle-delete-frame` (`frame.el:263`):
```elisp
(if (catch 'other-frame
      (dolist (frame-1 (frame-list))
        (when (and (not (eq frame-1 frame))
                   (frame-visible-p frame-1)
                   (not (frame-parent frame-1))
                   (not (frame-parameter frame-1 'delete-before)))
          (throw 'other-frame t))))
    (delete-frame frame t)          ; other visible frame exists -> close just this one
  (save-buffers-kill-emacs)))       ; THIS IS THE LAST VISIBLE FRAME -> QUIT EMACS
```
So **closing the last visible frame of a non-daemon Emacs quits the whole
process.** (Backstops in C: `Fdelete_frame`/`delete_frame` in `frame.c` errors
"Attempt to delete the sole visible or iconified frame" (~2729) on a plain
delete, calls `Fkill_emacs (70)` (~2833) on a *forced* last-frame delete, and
errors "Attempt to delete daemon's initial frame" (~2621) — the daemon's initial
frame is what keeps a daemon alive past this point.)

**(b) Last frame on a display removed:** `ns_delete_terminal` (`nsterm.m` ~5915):
```objc
/* Rather than try to clean up the NS environment we can just
   disable the app and leave it waiting for any new frames.  */
[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
```
This is the **downgrade** that the OS does not reliably honor (see §3).

### 2.4 Termination

In-source comment block (`nsterm.m` ~6637) documents the quit sequences:
```
C-x C-c / Cmd-Q / MenuBar|File|Exit / Quit from App menubar:
    -terminate  ->  KEY_NS_POWER_OFF, (save-buffers-kill-emacs)  ->  ns_term_shutdown()
Quit from Dock menu / Logout:
    -appShouldTerminate (Cancel -> nothing; Accept -> -terminate -> ... )
```
- App-menu **"Quit Emacs"** (`nsterm.m` ~6158, key equivalent `q` → `Cmd-Q`) →
  `terminate:` (~6668) → `KEY_NS_POWER_OFF` → event `[ns-power-off]`, bound by
  `ns-win.el:195` to **`save-buffers-kill-emacs`**.
- `applicationShouldTerminate:` (~6765) consults **`ns-confirm-quit`**: if
  non-nil it shows a "Save Buffers and Exit / Cancel" alert; otherwise
  `NSTerminateNow`.

**Important asymmetry:** `ns-confirm-quit` guards the **`terminate:` path
(`Cmd-Q`)** but **not** the **close-last-frame path** — `handle-delete-frame`
calls `save-buffers-kill-emacs` directly, never passing through
`applicationShouldTerminate:`. So the *accidental* exit (closing the last window
without realizing it is the last) is the **unguarded** one.

### 2.5 What is missing

- **No `applicationShouldHandleReopen:hasVisibleWindows:`** anywhere in `nsterm.m`.
  (The Dock right-click "New Frame" item exists, but the standard *left-click /
  reopen* hook does not.)
- **No `application:openURLs:`** / Apple-Event URL handler. `application:openFile:`
  exists (file opens work), but custom URL schemes (`org-protocol://`, `emacs://`)
  are unhandled by the NS port.

---

## 3. The defect, precisely

The user-observable failure: start `emacs --daemon`; create a GUI frame with
`emacsclient -c`; the daemon flips `Prohibited → Regular` and a Dock tile appears
(§2.1). Close that frame. **The tile remains** (running-indicator dot) but
**clicking it produces no frame, ever.**

Two compounding causes:

1. **The runtime downgrade is not honored.** `ns_delete_terminal` sets
   `Prohibited` (§2.3b), but macOS does not reliably transform a *running*
   process *out of* `Regular` once it has displayed windows
   (`setActivationPolicy:` / `TransformProcessType` is dependable upward, flaky
   downward). The Dock therefore keeps showing the tile, while the app's internal
   state believes it is `Prohibited`. The two disagree → **ghost tile.**

2. **Even if the downgrade *did* take, it would be wrong.** `Prohibited` means
   "may not create windows or be activated" (§1). A truly-`Prohibited` app cannot
   respond to a Dock click at all; recovery is possible only via the external
   `emacsclient` path that re-runs the §2.1 upgrade. And because there is **no
   reopen handler** (§2.5), there is no in-app route to a new frame regardless of
   policy.

So the design is internally inconsistent: it parks the app in a state intended to
mean "invisible, waiting for new frames," but (a) the OS leaves it visible, and
(b) the app never implemented the mechanism by which a click could ask for a new
frame. **Running but unreachable.**

A secondary design smell: **a single activation policy is applied regardless of
launch identity.** Parking a `--daemon`-launched *server* is at least arguable (it
is conceptually headless and also serves `emacsclient -t` tty frames). Applying
the same parking to a *GUI-launched `Emacs.app`* — a process that presented itself
as a windowed Mac app — is simply un-Mac-like.

---

## 4. The paths, and what works

| # | Path | Behavior today | Verdict |
|---|---|---|---|
| A | **Non-server GUI `Emacs.app`** (no daemon) | One process, one tile. Closing the last frame runs `handle-delete-frame` → `save-buffers-kill-emacs` → **process quits.** | **Works; feels correct** for users who do not need a server. *Caveat:* closing the last frame quits Emacs, and (§2.4) this path is **not** guarded by `ns-confirm-quit`, so an accidental close = accidental exit. |
| B | **`emacs --daemon` + `emacsclient -c`, then close the frame** | Daemon survives; tile appears on first frame, then becomes the **ghost tile** of §3. | **Broken UX.** This is the bug. |
| C | **Standalone `Emacs.app` *and* a separate `emacs --daemon`** | Two processes → **two Dock tiles.** | **By design / unavoidable.** Two processes legitimately mean two tiles; not a bug. (Tile B among them is still broken per row B.) |
| D | **`Cmd-Q` / "Quit Emacs" / `C-x C-c`** | `terminate:` → `save-buffers-kill-emacs`, guarded by `ns-confirm-quit`. | **Works; correct.** `Cmd-Q` is the expected "really quit" gesture on macOS and is rarely hit by accident. |

---

## 5. What a correct design looks like

Two changes restore native behavior; both are small and idiomatic:

1. **Implement `applicationShouldHandleReopen:hasVisibleWindows:`** → when
   `hasVisibleWindows == NO`, trigger the existing `newFrame:` / `make-frame`
   path (§2.2). This is the conventional Cocoa contract the port is missing.

2. **Stop relying on the `Regular → Prohibited` downgrade.** Either keep the app
   `Regular` when frameless (live, clickable tile + menu bar — the Mail/Notes
   model), or, for users who want it hidden when idle, use **`Accessory`** (no
   tile, no menu bar, *but still activatable* via Launch Services, so it can be
   reopened) — never `Prohibited`, which is both un-revivable and the state the OS
   fails to enter cleanly.

   This naturally becomes a **`defcustom`** (`Regular` vs `Accessory`), since the
   right answer depends on launch identity/preference. A sensible default: a
   GUI-launched `Emacs.app` → `Regular`; a `--daemon` server → whatever the user
   prefers. The point is: **drop `Prohibited`.**

3. **(Optional, addresses path A's caveat)** A `defcustom` to make closing the
   last frame *not* quit — i.e. drop to the frameless-resident state instead of
   `save-buffers-kill-emacs` — mirroring what the `osx-pseudo-daemon` package
   achieves with its hidden-frame workaround, but done properly. `Cmd-Q` /
   "Quit Emacs" still calls `save-buffers-kill-emacs` and exits, as expected — so
   "really quit" remains available and unambiguous; only the *accidental* exit on
   last-frame-close is removed.

The relationship to existing workarounds: **`osx-pseudo-daemon`** sidesteps all of
this from Lisp by spawning a hidden frame the instant the last visible one closes,
so the frame count never reaches zero, `ns_delete_terminal` never fires, the app
stays `Regular`, and reactivation reveals the hidden frame. That it exists at all
is evidence the lifecycle is missing upstream; the fixes above remove the need for
the hidden-frame hack.

---

## 6. References

- `src/nsterm.m`: `ns_delete_terminal` (~5915, the `Prohibited` park),
  `applicationDidFinishLaunching:` (~6589, the `Regular` upgrade),
  Dock "New Frame" (~6168) / `newFrame:` (~6452), App-menu "Quit Emacs" (~6158),
  `terminate:` (~6668), termination-sequence comment (~6637),
  `applicationShouldTerminate:` (~6765, `ns-confirm-quit`),
  `windowShouldClose:` (~8313). **Absent:** `applicationShouldHandleReopen:`,
  `application:openURLs:`.
- `lisp/frame.el`: `handle-delete-frame` (263).
- `lisp/term/ns-win.el`: `[ns-new-frame] → make-frame` (200),
  `[ns-power-off] → save-buffers-kill-emacs` (195).
- `src/frame.c`: `Fdelete_frame`/`delete_frame` (~2621 daemon initial frame,
  ~2729 sole-frame error, ~2833 `Fkill_emacs`).
- `lisp/server.el`: `server-create-window-system-frame` → `make-frame-on-display`.
- Apple: `NSApplicationActivationPolicy` (`Regular`/`Accessory`/`Prohibited`
  semantics).
- Prior art: `osx-pseudo-daemon` (hidden-frame workaround; proposed for the NS
  port on emacs-devel, 2018-05); debbugs #79859 (native macOS dock integration,
  upstream-receptive); Mitsuharu Yamamoto's `emacs-mac` port (different but
  related frameless-daemon failure mode).
