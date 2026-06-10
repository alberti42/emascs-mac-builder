# NS Emacs on macOS: the daemon "can't reopen from the Dock" defect

**Status:** investigation complete (diagnosis); fix prototyped separately.
**Scope:** the GNU Emacs **NS port** (`--with-ns`, `NS_IMPL_COCOA`) running as a
**server/daemon** on macOS.
**Audience:** upstream maintainers — a precise, reproducible statement of the
defect and the minimal fix.

Code is cited by function/selector name (stable) with approximate line numbers
from the `master` worktree used here; names are authoritative, numbers may drift.

---

## 0. TL;DR

Run an Emacs daemon, open a GUI frame, then close it. The daemon **correctly**
drops its Dock presence (activation policy → `Prohibited`, Launch Services
reports `BackgroundOnly` — verified, §3). That part is fine.

The defect is the **way back**. To get a frame again, the macOS-native gesture is
to click the app (a pinned Dock icon, or `Emacs.app` in Finder). But the daemon is
now in **`Prohibited`**, which Apple defines as *"may not create windows **or be
activated**"*, **and the NS port implements no
`applicationShouldHandleReopen:hasVisibleWindows:`** — the standard Cocoa hook that
turns such a click into a new window. So the click yields an **inert app with no
frame**. The only way to recover a GUI frame is to open a **terminal** and run
`emacsclient -c`. Rescuing a GUI macOS app from the command line is exactly the
kind of thing macOS users never expect — a beginner reasonably concludes *"Emacs
is broken."*

**Root cause (two parts):** on losing its last frame the daemon parks in the one
activation policy that *cannot be reactivated* (`Prohibited`), and the port never
implemented the reopen contract that would let a click create a frame. The fix is
correspondingly two small, idiomatic changes (§5).

---

## 1. Background: the native macOS app lifecycle

A normal macOS GUI app (`Regular` policy) stays available with **no windows open**
(Mail, Notes, Preview). Clicking its Dock/Finder icon while it has none triggers
**`applicationShouldHandleReopen:hasVisibleWindows:`**, in which the app creates a
fresh window. Closing the last *window* does not quit the app; **`⌘Q`** does. This
window-vs-app distinction is fundamental to the platform.

The three activation policies (`NSApplicationActivationPolicy`):

| Policy | Dock tile | Menu bar | Can be activated / create windows? |
|---|---|---|---|
| `Regular` | yes | yes | yes |
| `Accessory` (`LSUIElement`) | no | no | **yes** — programmatically or by clicking a window |
| `Prohibited` | no | no | **no** — "may not create windows or be activated" |

The asymmetry that drives this bug: **`Accessory` is reactivatable; `Prohibited`
is not.**

---

## 2. The mechanics (code-evidenced)

### 2.1 Startup and the activation "upgrade"

- A bundled `Emacs.app` starts `Regular` (declared by `Info.plist`).
- `emacs --daemon` / `--fg-daemon` starts headless.
- `applicationDidFinishLaunching:` (`nsterm.m` ~6589) upgrades a `Prohibited`
  process to `Regular` and sets the Dock icon:
  ```objc
  if ([NSApp activationPolicy] == NSApplicationActivationPolicyProhibited) {
      [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
      [NSApp setApplicationIconImage: ...];
  }
  ```
  The `Prohibited → Regular` direction is reliable; it is how `emacsclient -c`
  against a headless daemon makes a Dock tile appear.

### 2.2 Frame creation — all paths reach `make-frame`

- Dock right-click **"New Frame"** (`nsterm.m` ~6168) → `newFrame:` (~6452) →
  `KEY_NS_NEW_FRAME` → event `[ns-new-frame]`, bound in `ns-win.el:200` to
  **`make-frame`**.
- `emacsclient -c` → `server-create-window-system-frame` → `make-frame-on-display`
  (`server.el`) — `make-frame` with a display arg.

There is no socket magic: the daemon and the Dock menu reach the *same*
`make-frame`. (Relevant in §5: a reopen handler can reuse this path directly.)

### 2.3 Frame deletion

**Non-daemon** — closing a window posts `DELETE_WINDOW_EVENT`
(`windowShouldClose:`, `nsterm.m` ~8313), handled by `handle-delete-frame`
(`frame.el:263`): if another visible frame exists, delete just this one;
**otherwise `save-buffers-kill-emacs`** — closing the last frame *quits the
process.* (C backstops in `frame.c`: ~2729 sole-frame error, ~2833 `Fkill_emacs`,
~2621 daemon-initial-frame guard.)

**Daemon** — the daemon's persistent initial frame means `handle-delete-frame`
treats it as "another frame" and deletes only the GUI frame, so the daemon
survives. Removing the last *NS* frame then invokes `ns_delete_terminal`
(`nsterm.m` ~5917):
```objc
#ifdef NS_IMPL_COCOA
  /* ... disable the app and leave it waiting for any new frames.  */
  [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
#endif
```
This **does run on frame close** and **does** take effect (§3) — the daemon enters
`Prohibited`.

### 2.4 Termination

`⌘Q` / "Quit Emacs" / `C-x C-c` → `terminate:` (`nsterm.m` ~6668) →
`KEY_NS_POWER_OFF` → `[ns-power-off]` → `save-buffers-kill-emacs` (`ns-win.el:195`).
`applicationShouldTerminate:` (~6765) consults **`ns-confirm-quit`** (a
"Save Buffers and Exit / Cancel" alert). Note the asymmetry: `ns-confirm-quit`
guards `⌘Q` but **not** the close-last-frame path, which calls
`save-buffers-kill-emacs` directly — so the *accidental* quit (closing what
happens to be the last frame) is the unguarded one.

### 2.5 What is missing

- **No `applicationShouldHandleReopen:hasVisibleWindows:`** in `nsterm.m`. The Dock
  *right-click* "New Frame" item exists; the standard *left-click / reopen* hook
  does not.
- **No `application:openURLs:`** (custom URL schemes like `org-protocol://` are
  unhandled; `application:openFile:` exists, so file opens work). Out of scope for
  this defect, noted for completeness.

---

## 3. The defect, with evidence

### 3.1 What was measured

An instrumented build (temporary `fprintf(stderr, …)` logging in
`ns_delete_terminal` around the `setActivationPolicy:` call, reading
`[NSApp activationPolicy]` before/after) was driven against an **isolated,
uniquely-named `--fg-daemon`** with the user's full init. Phase markers were
interleaved into the same stderr stream via
`(princ … #'external-debugging-output)`. Sequence: create one GUI frame
(`emacsclient -c`) → delete it → read the ordered log and `lsappinfo`.

**Ordered log (verbatim shape):**
```
RBMARK before-delete
[…] ns_delete_terminal ENTERED;     policy_before=0      ; 0 = Regular
[…] ns_delete_terminal set Prohibited; policy_now=2      ; 2 = Prohibited
RBMARK after-delete
```
`lsappinfo` for the daemon's pid, after the delete: **`type="BackgroundOnly"`.**

### 3.2 Conclusion

Closing the last GUI frame of a daemon **runs `ns_delete_terminal`**, which sets
the policy `Regular → Prohibited`, and **Launch Services honors it**
(`BackgroundOnly`). The Dock tile is correctly removed for an unpinned app. This is
*not* the bug — it is reasonable backgrounding for a server.

The bug is that the daemon is now `Prohibited` — **un-reactivatable** — and there
is **no reopen handler** (§2.5). So the native recovery gesture (click the pinned
icon / open from Finder) cannot produce a frame: the app surfaces but stays inert.
Recovery requires `emacsclient -c` from a terminal. *That* is the broken UX.

Two earlier hypotheses were tested and **refuted**, recorded here so they are not
revisited: (1) "the `Regular → Prohibited` downgrade is silently dropped by the
OS" — no, `lsappinfo` confirms `BackgroundOnly`; (2) "`ns_delete_terminal` never
runs on frame close" — no, the ordered log shows it runs exactly between the
before/after-delete markers.

---

## 4. The paths, and what works

| Path | Behavior today | Verdict |
|---|---|---|
| **Non-daemon `Emacs.app`** (no server) | Close last frame → `handle-delete-frame` → `save-buffers-kill-emacs` → process quits. | **Works** for users who don't need a server. *Caveat:* the quit-on-last-frame is **not** guarded by `ns-confirm-quit` (§2.4) → accidental close = accidental exit. |
| **Daemon, close last GUI frame** | `ns_delete_terminal` → `Prohibited` / `BackgroundOnly`; tile removed (if unpinned). | Correct *backgrounding*. |
| **Daemon, then click the app to reopen** | `Prohibited` can't be activated + no reopen handler → icon may surface but **no frame**; recover only via terminal `emacsclient -c`. | **Broken UX.** This is the defect. |
| **Two icons** (`emacs --daemon` *and* a separately-launched `Emacs.app`) | Two processes → two Dock tiles. | **By design / unavoidable** — two processes legitimately mean two tiles. |
| **`⌘Q` / "Quit Emacs" / `C-x C-c`** | `terminate:` → `save-buffers-kill-emacs`, guarded by `ns-confirm-quit`. | **Works; correct.** `⌘Q` is the expected "really quit" gesture. |

---

## 5. The fix

Two small, idiomatic changes — together they make the daemon a well-behaved macOS
app on the reopen path:

1. **Don't park in `Prohibited`.** On losing the last frame, use **`Accessory`**
   (hidden tile, *but still activatable* — so a click/`open` reopens it) or stay
   **`Regular`** (keep a live tile). Both are reactivatable; `Prohibited` is the
   one policy that is not, and is the direct cause of the inert-after-click state.
   The right choice is launch/preference dependent, so expose it as a **`defcustom`**
   (`Regular` vs `Accessory`); do **not** offer `Prohibited`.

2. **Implement `applicationShouldHandleReopen:hasVisibleWindows:`** → when
   `hasVisibleWindows == NO`, trigger the existing `newFrame:` / `make-frame` path
   (§2.2). This is the conventional Cocoa contract the port lacks, and it turns the
   click into a frame.

Either change alone is insufficient: a reopen handler can't fire while the app is
`Prohibited` (it can't be activated); and dropping `Prohibited` without a reopen
handler leaves a live tile that still does nothing on click.

**Optional, separate** (addresses the non-daemon caveat in §4): a `defcustom` to
make closing the last frame *not* quit a non-daemon Emacs — dropping to the
frameless-resident state instead of `save-buffers-kill-emacs`. `⌘Q` / "Quit Emacs"
still quit, so "really quit" stays available; only the *accidental* exit is
removed. (The `osx-pseudo-daemon` package approximates this from Lisp with a
hidden frame; doing it in the port removes the need for that workaround.)

---

## 6. How to reproduce (and measurement gotchas)

- Build with temporary `fprintf(stderr, …)` in `ns_delete_terminal` logging
  `[NSApp activationPolicy]` before/after the `setActivationPolicy:` call.
- Drive an **isolated** `--fg-daemon=<name>` (its own socket, separate from any
  real daemon): `emacsclient -s <name> -c` to create a frame, then delete it.
- Read the policy via `lsappinfo` (find the pid's entry; the `type=` field is the
  Launch Services view: `Foreground` / `BackgroundOnly`).

Two traps that produced false readings during this investigation:

- **`terminal-list` is unreliable for NS.** It keeps listing the `ns` terminal as
  "live" even after `ns_delete_terminal` has run — the in-process AppKit display
  lingers. Trust the activation policy / `lsappinfo`, not `terminal-list`.
- **A background `--daemon` detaches stderr**, so `fprintf`/`NSLog` instrumentation
  is *not* captured. Use **`--fg-daemon`** (stderr stays attached) for any
  stderr-based logging.

---

## 7. References

- `src/nsterm.m`: `ns_delete_terminal` (~5917, sets `Prohibited` on last NS frame),
  `applicationDidFinishLaunching:` (~6589, the `Regular` upgrade), Dock "New Frame"
  (~6168) / `newFrame:` (~6452), `terminate:` (~6668), `applicationShouldTerminate:`
  (~6765, `ns-confirm-quit`), `windowShouldClose:` (~8313). **Absent:**
  `applicationShouldHandleReopen:`, `application:openURLs:`.
- `lisp/frame.el`: `handle-delete-frame` (263).
- `lisp/term/ns-win.el`: `[ns-new-frame] → make-frame` (200),
  `[ns-power-off] → save-buffers-kill-emacs` (195).
- `lisp/server.el`: `server-create-window-system-frame` → `make-frame-on-display`.
- Apple: `NSApplicationActivationPolicy` (`Regular` / `Accessory` / `Prohibited`).
- Prior art: `osx-pseudo-daemon` (Lisp hidden-frame workaround; proposed for the NS
  port on emacs-devel, 2018-05); debbugs #79859 (native macOS dock integration,
  upstream-receptive).
