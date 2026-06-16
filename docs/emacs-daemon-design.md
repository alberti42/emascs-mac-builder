# Emacs daemon vs. server: a design analysis

**What this is:** a conceptual analysis of how the Emacs "daemon" is put together,
what it actually buys over `(server-start)`, which parts of it *genuinely* require
early intervention in C, and why on a modern OS you should run `--fg-daemon` under a
service manager rather than `--daemon`. It is opinionated where noted — the factual
mechanics are separated from the design critique.

Companion docs: [`macos-app-lifecycle-investigation.md`](./macos-app-lifecycle-investigation.md)
and [`nsterm-reopen-fix-plan.md`](./nsterm-reopen-fix-plan.md).

---

## 1. Two orthogonal axes: *server* and *daemon*

The single most clarifying idea: **"server" and "daemon" are independent.**

| | what it controls | sets `daemonp`? | survives closing the last GUI frame? |
|---|---|---|---|
| **server** (`server-start` / `server-mode`) | IPC: can `emacsclient` reach this Emacs? | no | no |
| **daemon** (`emacs --daemon` / `--fg-daemon`) | is this a resident, headless process? | yes | yes |

They meet at exactly one point: **a daemon automatically starts the server** (it has
no GUI of its own, so the socket is the only way in). The converse is false — a
`(server-start)` in an ordinary GUI Emacs is *not* a daemon.

- **`(server-start)`** answers *"how do other programs talk to this Emacs?"* — it
  opens a Unix socket and a process filter so `emacsclient file`, `emacsclient -c`,
  `EDITOR=emacsclient`, etc. reach the running process. That's all. It's a normal
  runtime resource you can add or remove at any time.
- **`--daemon`** answers *"is this a resident process that stays alive with no
  windows?"* — and then adds the server on top.

Practical consequence: a plain GUI Emacs + `(server-start)` still **quits** when you
close its last frame (`handle-delete-frame` → `save-buffers-kill-emacs`). The socket
does nothing to keep it alive. So `(server-start)` is *not* a substitute for a
daemon.

---

## 2. What `--daemon` does *more* than `(server-start)`

| | `emacs --daemon` | `emacs` + `(server-start)` |
|---|---|---|
| Starts the server (socket/IPC) | yes | yes |
| `(daemonp)` | non-nil | **nil** |
| Initial GUI frame at startup | **none** (headless) | yes (the one you launched) |
| **Persistent initial *terminal* frame** | **yes** — liveness anchor with no windows | **no** |
| Survives closing the last GUI frame | **yes** | **no — quits** |
| Window-system (NS/X) connection | **deferred** until first GUI frame | opened at startup |
| Frame-dependent init | **deferred** to first frame | runs at startup |
| Detach from controlling tty / fork | yes (`--daemon`/`--bg-daemon`); **no** for `--fg-daemon` | no |

The load-bearing item is the **persistent initial terminal frame** — a frame on the
internal, device-less `initial_terminal` (`term.c`). It is what keeps `frame-list`
non-empty so the process can sit there windowless. (You can see it in a daemon:
`frame-list` shows a `(t . t)` terminal frame alongside any GUI frames.) A
`(server-start)` GUI Emacs has no such anchor, so its last-frame close is fatal.

---

## 3. What *actually* requires early C — and what doesn't

It's tempting to conclude "the daemon must be set up in `main()` because Lisp runs too
late." That's **mostly historical accident, not necessity.** Separating the two:

**Genuinely early-C-only:**
- The **`fork()` / `setsid()` / detach** of `--bg-daemon`. You can only safely fork a
  *simple* process — before threads, signal handlers, a Lisp heap, and an open
  display connection exist. Forking a fully-initialized Emacs yields a broken child.
  There's also a parent→child readiness handshake so the launching shell returns at
  the right moment. None of that is expressible from Lisp in the already-booted child.
- …and that's the whole list. Note it is **only for `--bg-daemon`** — `--fg-daemon`
  does no fork at all (see §6).

**Contingent — could be Lisp-driven given small primitives:**
- **`daemonp`** — trivially just state. It lives in C only because that's where the
  command-line flag is parsed.
- **"Boot headless"** — this is a *non-action*: don't create a GUI frame at startup.
  The display is already opened lazily.
- **Deferred window-system init** — already how it works (lazy on first frame).
- **The initial terminal frame** — the only interesting one, and it's a **missing
  Lisp primitive, not a barrier.** A frame on the device-less `initial_terminal` is
  an ordinary internal object, and **the daemon lives in exactly that state every
  day — which proves the state is viable at runtime.** A non-daemon can't reach it
  only because (a) startup *deletes* the initial frame once a GUI frame appears, and
  (b) `delete_frame` (`src/frame.c`) refuses to leave you with no frame ("Attempt to
  delete the only frame"), and there's no Lisp API to retain/recreate a liveness
  frame. Expose that and a normal Emacs could drop to frameless and survive.

**The clincher is `--fg-daemon` itself:** it forks *nothing*, yet is a full daemon. So
even the one "irreducible" early-C action isn't intrinsic to *being* a daemon — it's
intrinsic to *backgrounding yourself from a shell*. Under launchd/systemd (no fork),
everything `--fg-daemon` does early is, in principle, a Lisp-expressible sequence
given the right primitives. Its placement in `main()` is structural, not essential.

---

## 4. The missing primitive (and why "non-daemon stay-alive" looked infeasible)

This connects directly to a feature that was descoped from the
[reopen fix plan](./nsterm-reopen-fix-plan.md) as "infeasible": making a *non-daemon*
Emacs stay alive (frameless) when its last frame closes, without the
`osx-pseudo-daemon` hidden-frame hack.

It is infeasible **today** — `delete_frame` errors on the last frame, and a non-daemon
has no liveness anchor. But it is *not* infeasible **in principle**: the daemon
demonstrates the exact target state (alive, windowless, anchored on an
initial-terminal frame) continuously. The gap is purely a **missing, unexposed
capability** — "retain/create a liveness frame on the initial terminal" — not a law of
the architecture.

`osx-pseudo-daemon` is the proof from the other direction: it *does* fake the
frame-level keep-alive entirely in Lisp, by holding a hidden GUI frame so `frame-list`
never empties. That's the only piece it can fake; it cannot fake a detached headless
boot. So the line between "Lisp-doable" and "must be C" runs through **the fork**, not
through the liveness state.

---

## 5. A more uniform design (analysis)

Given the above, a cleaner factoring is conceivable:

> *Any* Emacs can drop to a **frameless-liveness state** (anchored on an
> initial-terminal frame). A "daemon" is simply one that **boots** into that state,
> sets `daemonp`, and — for the background variant only — **detaches** via fork. The
> fork is the sole irreducibly-early piece.

In that model, `--fg-daemon`, `(server-start)`, `osx-pseudo-daemon`'s hidden frame,
and "GUI Emacs that survives closing its last window" all become points on **one
axis** (boot-time vs. runtime entry into the same liveness state) instead of separate,
specially-cased mechanisms.

Why it isn't like this: **historical accretion.** The daemon was bolted onto Emacs in
23 (2009) atop a startup/terminal model that long predates it; a dedicated early-
`main()` path was the pragmatic choice over refactoring the bootstrap to make
frameless-liveness a first-class, Lisp-reachable state. The `initial_terminal` carries
invariants the frame/redisplay/command-loop code quietly assumes, and startup code is
high-risk to touch — so nobody has. "It would be a big, risky patch" is a real
obstacle, but it is a very different statement from "Lisp can't do it."

---

## 6. Modern deployment: prefer `--fg-daemon` under a service manager

The `fork`/`setsid`/detach of `--bg-daemon` is the **SysV "old-style daemon"** pattern,
and the people who build service managers now tell you *not* to do it:

- **systemd `daemon(7)`** distinguishes "old-style (SysV)" from **"new-style
  daemons,"** which should: stay in the **foreground** (no fork), **not** detach, log
  to **stdout/stderr** (the manager routes them to the journal), **not** write PID
  files (the manager owns the PID), and report readiness via `sd_notify`
  (`Type=notify`). Double-forking actively fights the supervisor — it loses the real
  PID and forces `Type=forking` + PID-file gymnastics.
- **launchd** is the same philosophy: don't daemonize; let launchd background,
  supervise (`KeepAlive`), restart, order, and capture `StandardOutPath` /
  `StandardErrorPath`.

**Emacs already endorses this:** `--fg-daemon` was added in 26.1 for exactly this, and
upstream ships an `etc/emacs.service` unit that is essentially `Type=notify` +
`ExecStart=emacs --fg-daemon` (Emacs calls `sd_notify` to report readiness when built
with libsystemd). The project's recommended deployment *is* the foreground daemon
under a service manager; `--bg-daemon` is the legacy path.

A concrete, lived-through payoff: **`--bg-daemon` detaches stderr**, so
`fprintf`/`NSLog` instrumentation is lost — which is exactly why the lifecycle
investigation had to use `--fg-daemon` to capture traces. The same property is what a
service manager wants: foreground keeps stdout/stderr attached so journald/launchd can
capture real logs. "Daemon writes its own logfile and detaches" is strictly worse than
"the manager owns the streams."

What a service manager gives you that `--bg-daemon` does not: supervised restart on
crash, start-at-boot/login, ordered readiness (`Type=notify`), centralized logging,
resource limits, and a clean process tree (no orphaned double-forked child).

**The only honest niche left for `--bg-daemon`:** ad-hoc shell convenience
(`emacs --daemon` to background it *right now* without writing a unit/agent), or a box
with no per-user service manager. For a managed, always-on, restart-on-crash,
properly-logged daemon, `--fg-daemon` under launchd/systemd is simply correct.

---

## 7. Takeaway

- **`(server-start)` ≠ daemon.** Server = IPC front door; daemon = resident headless
  process (which also starts the server). The keep-alive comes from the daemon's
  initial-terminal frame, not the socket.
- **Most of `--daemon` need not be early C.** `daemonp` is state; headless boot is a
  non-action; deferred display is already lazy; the liveness frame is a missing Lisp
  primitive, not a barrier (the daemon proves the state is viable). Only the
  `--bg-daemon` fork is irreducibly early — and `--fg-daemon` shows even that isn't
  intrinsic to being a daemon.
- **On a modern OS, run `--fg-daemon` under launchd/systemd.** The fork is a vestige
  of early-Unix daemonization; foreground + a supervisor gives you restart, logging,
  ordering, and a clean process tree. Upstream Emacs already ships its systemd unit
  this way.
