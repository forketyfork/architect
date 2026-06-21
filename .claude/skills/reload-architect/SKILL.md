---
name: reload-architect
description: Rebuild the Architect app from the current worktree (committed + uncommitted local changes) and relaunch it, so the running app reflects in-progress code. Use when the user wants to see/test their Architect changes in the actual app — e.g. "reload architect", "rebuild and restart architect", "run my changes", "relaunch with my edits", "I closed and reopened but don't see my changes".
---

# Reload Architect

Goal: get the running Architect to be the build of **this worktree's current code** (including uncommitted changes). Editing source and relaunching the *installed* app does nothing — the `.app` must be rebuilt. This skill does build → quit → relaunch in one step via `scripts/dev-reload.sh`.

## Steps

1. Find the repo root and confirm we're in the Architect repo:
   ```bash
   ROOT="$(git rev-parse --show-toplevel)" && test -f "$ROOT/scripts/dev-reload.sh" && echo "$ROOT"
   ```
   If that fails, tell the user to run the skill from inside the Architect repo (or a worktree of it) and stop.

2. Run the reload from the repo root:
   ```bash
   bash "$ROOT/scripts/dev-reload.sh"
   ```
   This builds (debug), packages the `.app`, quits the running Architect, swaps the fresh build into `/Applications`, and relaunches it. The relaunch is detached, so it completes on its own.

3. Report the outcome:
   - On success, tell the user Architect will close and reopen on the fresh build, and remind them what changed (branch + the local edits being tested).
   - If the build fails (`zig build` error), surface the compiler error and offer to fix it. Do **not** leave them thinking it reloaded.

## If the toolchain isn't reachable from your shell

The build needs the Nix dev shell (`zig`). If `scripts/dev-reload.sh` exits with **"neither 'zig' nor 'nix' is on PATH"**, then this agent's shell can't reach the build toolchain (it lives in the user's login/direnv shell, not necessarily yours). In that case, do **not** keep retrying — tell the user to run it in their own session instead, where the toolchain is loaded:

```
!just reload
```

(or `!./scripts/dev-reload.sh`). The `!` prefix runs it in the user's interactive session, and the output comes back into the conversation.

## Notes

- Works in any Architect worktree — it resolves the repo root from the current directory, so it reloads whichever branch/worktree you're in.
- Safe to run while Architect is the frontmost app or in the background; the quit+relaunch is detached and survives even if it was launched from inside the Architect being replaced.
- This replaces `/Applications/Architect.app`, so Spotlight/Dock launches afterward also get the fresh build — no "which version am I running?" ambiguity.
