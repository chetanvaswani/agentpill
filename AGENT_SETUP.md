# AgentPill: setup guide for a coding agent

You are helping someone install **AgentPill** on their Mac. Read this whole file before running anything.
It tells you what the app does, what it changes on the machine, which steps you may run yourself, and
which steps the person must do by hand.

## What AgentPill is

A small always-on-top status pill for macOS (it sits at the top of the screen like a notch, and can be dragged
anywhere). It shows what each running Claude agent is doing:

- **Blue spinner**: working (e.g. "Running tests · 4m", with time spent on the current step).
- **Amber dot**: needs the person (a permission prompt, a question, an error). The pill bounces and plays a soft
  chime.
- **Green dot**: finished. Click the tick to clear it.

Hovering expands the pill to show every session. Clicking a row takes the person to that session:

- **Claude desktop, Code tab**: opens that exact session (via a `claude://code/continue?session=local_…` link).
- **Claude desktop chats**: opens that exact chat (via `claude://claude.ai/chat/<id>`, when the id was seen).
- **Terminal, iTerm, VS Code, Cursor, etc.**: brings that app forward, and the window whose title matches the
  session.

Right-click the pill, or use the capsule icon in the menu bar, for recent sessions, chime toggles, Reset Position
and Quit.

It uses **no model tokens**. Information comes from two places:

1. **Claude Code hooks.** A tiny C program, `pill-hook`, gets each hook's JSON on stdin and forwards it over a
   Unix socket (`~/.agentpill/pill.sock`) to the app, with a few header lines (parent process ids, the launching
   app's bundle id, and the Claude desktop session id if there is one) used to route clicks. It prints nothing,
   always exits 0, and runs as an `async` hook, so it can never block or slow down an agent.
2. **Accessibility (optional).** Claude desktop *chats* have no hooks, so with Accessibility permission the app
   reads the Claude window's text to spot "needs your input" prompts, and reads the chat's address so a click can
   reopen it.

## What it changes on the machine

Tell the person about these **before** installing:

| Change | Where | How to undo |
|---|---|---|
| App bundle | `~/Applications/AgentPill.app` | delete it |
| Claude Code hooks for 11 events, all pointing at `pill-hook` | `~/.claude/settings.json` (merged in; every other setting and hook is left alone; the original is backed up once to `~/.claude/settings.json.agentpill-backup`) | `~/Applications/AgentPill.app/Contents/MacOS/AgentPill --uninstall` |
| Socket and support files | `~/.agentpill/` | delete the folder |
| Optional: a self-signed code-signing certificate, "AgentPill Local Signing" | login keychain | Keychain Access → login → My Certificates → delete it |
| Optional: Accessibility permission | System Settings | toggle it off / remove it |

The app adds the hooks itself on first launch, and repairs them on later launches.

## Requirements

- macOS 12 or later (Apple Silicon or Intel).
- Xcode Command Line Tools, for `swiftc`, `clang` and `codesign`. Check with `xcode-select -p`. If they're
  missing, ask the person to run `xcode-select --install` (it opens a system installer dialog).
- Claude Code installed, so `~/.claude` exists. Without it, the app still runs and can watch Claude desktop
  chats, but it shows "Claude Code not found".

## Install steps

### 1. Get the code

```bash
git clone https://github.com/chetanvaswani/agentpill.git
cd agentpill
```

### 2. One-time signing certificate (recommended; **the person runs this**)

```bash
./make-cert.sh
```

Without it, builds are signed ad-hoc and macOS **forgets the Accessibility permission on every rebuild**. The
script makes a self-signed certificate that's only used to sign this app, and asks for the login (keychain)
password once so `codesign` can use the key without a dialog on every build. It does **not** add a trusted
root. macOS matches the app by the certificate's fingerprint.

**Do not run this for the person and do not handle their password.** Ask them to run it in their own terminal.
If they skip it, everything still works except that Accessibility has to be granted again after each rebuild.

### 3. Build and install

```bash
./build.sh install
```

This builds `build/AgentPill.app`, signs it (with the certificate if it exists, otherwise ad-hoc), copies it to
`~/Applications`, and starts it. On first launch it adds the hooks to `~/.claude/settings.json`, and the pill
briefly shows "Connected to Claude Code".

`./build.sh` without `install` only builds.

### 4. Accessibility permission (optional; **the person does this**)

Needed only for watching Claude desktop chats, reopening the exact chat on a click, and raising the exact
terminal window. Clicking a Claude desktop Code session does not need it. On first launch macOS shows a
prompt. If it doesn't, the person opens **System Settings → Privacy & Security → Accessibility**, clicks **+**,
picks `~/Applications/AgentPill.app`, and switches it on.

Don't change security settings yourself. Tell the person exactly what to click.

### 5. Start at login (optional)

There's no menu toggle yet. To start AgentPill at login, the person can add it under **System Settings →
General → Login Items**.

## Verify

1. A test message. A row should appear in the pill reading "Hello from setup":
   ```bash
   ~/Applications/AgentPill.app/Contents/MacOS/pill-hook say "Hello from setup"
   ```
2. Hooks: `grep -c pill-hook ~/.claude/settings.json` should print a number above 0.
3. Start a **new** `claude` session (terminal or Claude desktop Code tab) and give it a small task. A row should
   show what it's doing. Sessions that were already running load hooks at startup, so they need a restart to be
   tracked.
4. Accessibility, if granted. Ask the app for a snapshot and read `trusted=` from it:
   ```bash
   echo '{"hook_event_name":"_Snapshot","path":"/tmp/agentpill-check.png"}' \
     | ~/Applications/AgentPill.app/Contents/MacOS/pill-hook hook
   sleep 1; head -1 /tmp/agentpill-check.png.txt
   ```
   The first line should contain `trusted=true`. The following `row …` lines show each session with the app it
   resolved to (`app=` pid, `bundle=`, and `host=` for Claude desktop sessions).

## Troubleshooting

- **Nothing shows for a Claude Code session.** Check that the app is running (`pgrep -x AgentPill`), that the
  hooks are in `~/.claude/settings.json`, and that the session was started *after* install. Relaunching the app
  repairs the hooks.
- **Clicking a row only brings the app forward.** For terminals that's expected (tabs aren't supported yet). For
  a Claude desktop chat it means the chat's id was never seen. The watcher only reads the chat that's currently
  open, so the row has to have been on screen at least once. Without Accessibility, chats aren't tracked at all.
- **`trusted=false` even though the switch is on in Settings.** The entry belongs to an older signature, which
  happens after switching from ad-hoc signing to the certificate. Have the person run
  `tccutil reset Accessibility com.local.agentpill`, then run
  `defaults delete com.local.agentpill askedAccessibility` and relaunch with
  `pkill -x AgentPill; open ~/Applications/AgentPill.app`. The system prompt reappears; they switch it on.
- **Chat rows say "Claude chat" or chat states aren't detected.** The Claude desktop app's interface text may
  differ by version or language. The markers can be overridden without rebuilding in
  `~/.agentpill/chat-markers.json`, with keys `waitingPrefix`, `waitingExact`, `workingExact`, `skip` and
  `codeSuffix` (each an array of strings). To see what the app can read, run:
  ```bash
  echo '{"hook_event_name":"_ChatDump","path":"/tmp/agentpill-chat.txt"}' \
    | ~/Applications/AgentPill.app/Contents/MacOS/pill-hook hook
  ```
  If the Claude window is on another Space or in full screen, macOS hides it from Accessibility, and the dump
  lists no windows.
- **Pill is off-screen or in a strange place.** Use Reset Position in the menu bar icon's menu.
- **Nothing happens on launch.** Only one copy runs at a time. `pkill -x AgentPill` and open it again.

## Uninstall

```bash
~/Applications/AgentPill.app/Contents/MacOS/AgentPill --uninstall   # removes only AgentPill's hooks
pkill -x AgentPill
rm -rf ~/Applications/AgentPill.app ~/.agentpill
```

Optionally the person deletes the "AgentPill Local Signing" certificate in Keychain Access and removes AgentPill
from the Accessibility list.

## Code map (for changes)

- `Sources/main.swift` is the whole app (AppKit, no dependencies). Sections, in order:
  - Model and `Store`: turns hook events into per-session state.
  - Socket `Server`: parses the header lines `pill-hook` sends ahead of the JSON (`#pids`, `#bundle`, `#host`).
  - Accessibility helpers and `ChatWatcher`: read Claude desktop windows.
  - Hook `Installer`.
  - `PillView`: drawing, animation, mouse handling.
  - `AppDelegate`: layout, click-to-open (`focus`), chimes and bounce, menu.
- `Sources/hook.c` is `pill-hook`.
- `build.sh` and `make-cert.sh` are described above.
- Debug events sent through `pill-hook hook`: `_Snapshot`, `_ChatDump`, `_AXProbe`, `_Open`, `_Click`.

## Rules for you, the agent

- Explain the `~/.claude/settings.json` change before running `./build.sh install`.
- Never type, ask for, or handle the person's password. `make-cert.sh` and any password prompt are theirs.
- Never change System Settings or security permissions yourself. Give the exact clicks instead.
- If a step fails, show the actual error output rather than guessing.
