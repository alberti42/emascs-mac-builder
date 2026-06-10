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

**There is no `applicationShouldHandleReopen:hasVisibleWindows:`** — the standard
Cocoa hook every well-behaved Mac app uses to recreate a window when its Dock tile
is clicked while it has none. Emacs simply does not implement it.

So a server/daemon Emacs, after you close its last GUI frame, stays a perfectly
normal `Regular`/foreground app **with a live Dock tile and no window** — and
clicking that tile does **nothing**, because the reopen hook was never
implemented. The tile isn't a "ghost"; it is correctly present. It is just
**dead**: there is no in-app route from a Dock click to a new frame.

This was verified empirically (see §3): when the last GUI frame of a daemon
closes, the activation policy stays `Foreground` and the NS display/terminal
**persists** — so the `Prohibited`-park code in `ns_delete_terminal` (§2.3b)
**does not run on frame close at all.** An earlier draft of this document blamed a
failed `Regular → Prohibited` activation-policy downgrade; that hypothesis was
tested and **refuted**. The single defect is the missing reopen contract.

A secondary smell, separate from the bug: `ns_delete_terminal` applies one
activation policy (`Prohibited`) on terminal teardown regardless of launch
identity, and its comment ("called when the last frame on a display is deleted")
is misleading — closing the last frame does **not** delete the display.

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

**(b) Terminal/display teardown:** `ns_delete_terminal` (`nsterm.m` ~5915):
```objc
/* Rather than try to clean up the NS environment we can just
   disable the app and leave it waiting for any new frames.  */
[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
```
Its comment says it is "called when the last frame on a display is deleted," but
**that is not what happens in practice** (verified in §3): closing the last GUI
frame does *not* delete the NS display/terminal — the display connection persists
with zero frames — so this function (and its `Prohibited` set) **does not run on
frame close.** It runs only on real terminal teardown (display-connection close,
or process exit). On the frame-close path this code is effectively dormant.

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

### 3.1 What actually causes it (empirically verified)

This was tested on an isolated, uniquely-named daemon (`--daemon=ghosttile`, its
own socket, separate from any real daemon). Sequence: start headless → create one
GUI frame via `emacsclient -c` → delete that frame → measure.

| Measurement (after the GUI frame is deleted) | Result |
|---|---|
| `ns` terminal still in `(terminal-list)`? | **Yes** — `"…fritz.box"` persists |
| ns frames remaining (`(mapcar #'framep (frame-list))`) | **none** — `(t)`, only the initial daemon frame |
| activation policy via `lsappinfo info -app <pid>` | **`type="Foreground"`** |

So: zero GUI frames, yet the **NS display/terminal is still alive** and the
process is still **`Foreground`/`Regular`**. Therefore `ns_delete_terminal`
**never ran** — closing frames does not tear down the display — and consequently
**nothing ever attempted a `Regular → Prohibited` downgrade.**

### 3.2 Conclusion

The defect is **one thing**: the app correctly remains a normal `Regular`
foreground app with a live Dock tile and no window, but there is **no
`applicationShouldHandleReopen:hasVisibleWindows:`** (§2.5), so a click on the
tile has no path to a new frame. The tile is not a "ghost" produced by a botched
policy change — it is a *legitimately present* tile that is simply **dead**.

A hypothesis in an earlier draft — that the failure was a runtime
`Regular → Prohibited` downgrade the OS fails to honor — was tested and
**refuted** by the measurements above (`ns_delete_terminal` is not even reached on
frame close). It is retained here only as a recorded dead end.

A secondary design smell, *separate from this bug*: `ns_delete_terminal` applies
`Prohibited` on genuine terminal teardown regardless of launch identity, and its
comment misdescribes when it runs. Worth tidying, but not the cause of the dead
tile.

---

## 4. The paths, and what works

| # | Path | Behavior today | Verdict |
|---|---|---|---|
| A | **Non-server GUI `Emacs.app`** (no daemon) | One process, one tile. Closing the last frame runs `handle-delete-frame` → `save-buffers-kill-emacs` → **process quits.** | **Works; feels correct** for users who do not need a server. *Caveat:* closing the last frame quits Emacs, and (§2.4) this path is **not** guarded by `ns-confirm-quit`, so an accidental close = accidental exit. |
| B | **`emacs --daemon` + `emacsclient -c`, then close the frame** | Daemon survives; tile appears on first frame and **stays live** (`Foreground`), but with no window and no reopen handler, clicking it does nothing (§3). | **Broken UX.** This is the bug — a live but **dead** tile. |
| C | **Standalone `Emacs.app` *and* a separate `emacs --daemon`** | Two processes → **two Dock tiles.** | **By design / unavoidable.** Two processes legitimately mean two tiles; not a bug. (Tile B among them is still broken per row B.) |
| D | **`Cmd-Q` / "Quit Emacs" / `C-x C-c`** | `terminate:` → `save-buffers-kill-emacs`, guarded by `ns-confirm-quit`. | **Works; correct.** `Cmd-Q` is the expected "really quit" gesture on macOS and is rarely hit by accident. |

---

## 5. What a correct design looks like

**The fix for the bug (path B) is a single, idiomatic change:**

1. **Implement `applicationShouldHandleReopen:hasVisibleWindows:`** → when
   `hasVisibleWindows == NO`, trigger the existing `newFrame:` / `make-frame`
   path (§2.2). This is the conventional Cocoa contract the port is missing, and
   — because the daemon already stays `Regular` with a live tile (§3) — **it
   requires no activation-policy change at all.** Add the handler and the dead
   tile becomes a working one.

The remaining items are *optional enhancements*, not part of the bug fix:

2. **(Optional) "hide when idle."** Some users may want the tile to *disappear*
   when the app is frameless rather than linger. That means *actively* setting
   **`Accessory`** on frame-close (new behavior — recall §3 shows nothing
   currently downgrades the policy). `Accessory` is the right target because it is
   still activatable via Launch Services, so reopen still works — unlike
   `Prohibited`, which "may not be activated." This is a **`defcustom`**
   (`Regular` keep-tile vs `Accessory` hide-when-idle); `Prohibited` should not be
   offered. (Note: setting `Accessory` here is a *fresh* policy transition on
   frame-close, distinct from the dormant `ns_delete_terminal` path.)

3. **(Optional, addresses path A's caveat)** A `defcustom` to make closing the
   last frame *not* quit — i.e. drop to the frameless-resident state instead of
   `save-buffers-kill-emacs` — mirroring what the `osx-pseudo-daemon` package
   achieves with its hidden-frame workaround, but done properly. `Cmd-Q` /
   "Quit Emacs" still calls `save-buffers-kill-emacs` and exits, as expected — so
   "really quit" remains available and unambiguous; only the *accidental* exit on
   last-frame-close is removed.

The relationship to existing workarounds: **`osx-pseudo-daemon`** works around the
missing reopen contract from Lisp — it spawns a hidden frame the instant the last
visible one closes and reveals it on reactivation, so there is always a frame to
bring back even though no `applicationShouldHandleReopen:` exists. (The app stays
`Regular` either way, per §3; the package's value is supplying the
reveal-on-activation behavior the port lacks.) That such a package is needed at
all is evidence the lifecycle is missing upstream; fix #1 removes the need for the
hidden-frame hack.

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
