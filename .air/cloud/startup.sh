#!/usr/bin/env bash
# AIR Cloud workspace provisioning script (see FLEET_WORKSPACE_SETUP_SCRIPT).
# Runs once per fresh sandbox, before the coding agent session starts.
# Prepares Nix (with flakes) so `nix develop` / `just build|test|lint` work
# for Architect without every task re-installing the toolchain from scratch.
set -uo pipefail

log() { printf '[air-startup] %s\n' "$*"; }

log "id: $(id)"
log "sudo -l (permitted commands, if any):"
sudo -n -l 2>&1 | tail -20 || true

if command -v nix >/dev/null 2>&1 && nix --version >/dev/null 2>&1; then
  log "nix already present on PATH: $(nix --version)"
else
  log "installing Nix (Determinate installer, no-daemon single-user mode)"
  if curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
      | sh -s -- install linux --init none --no-confirm; then
    log "nix-installer completed"
  else
    log "nix-installer exited non-zero; continuing to check whether nix is usable anyway"
  fi
fi

NIX_BIN="$(command -v nix || true)"
if [ -z "$NIX_BIN" ]; then
  NIX_BIN=$(find /nix/store -maxdepth 4 -type f -path '*/bin/nix' 2>/dev/null | head -1)
fi

if [ -z "$NIX_BIN" ]; then
  log "ERROR: no nix binary found after install attempt"
else
  # /nix may already exist root-owned (pre-baked into the base image, or a
  # prior partial install), which blocks an unprivileged workspace user from
  # running builds regardless of whether THIS script had to install nix
  # itself. Always attempt the ownership fix, not just after a fresh install.
  if [ -d /nix ]; then
    target_user="${SUDO_USER:-${USER:-$(id -un)}}"
    current_owner="$(stat -c '%U' /nix/var/nix 2>/dev/null || stat -f '%Su' /nix/var/nix 2>/dev/null || echo unknown)"
    log "/nix/var/nix currently owned by: $current_owner; target user: $target_user"
    if [ "$current_owner" = "$target_user" ]; then
      log "/nix/var/nix already owned by $target_user; no chown needed"
    elif [ "$(id -u)" -eq 0 ]; then
      log "running as root; chowning /nix to $target_user"
      chown -R "$target_user" /nix 2>&1 | tail -5 || true
    elif sudo -n chown -R "$target_user" /nix 2>&1 | tail -5; then
      log "sudo chown succeeded"
    else
      log "not root and sudo chown failed/unavailable; leaving /nix ownership as-is (build will likely fail with a permission error)"
    fi
  fi

  NIX_CONF_DIR="${HOME:-/root}/.config/nix"
  mkdir -p "$NIX_CONF_DIR"
  grep -q '^experimental-features' "$NIX_CONF_DIR/nix.conf" 2>/dev/null \
    || printf 'experimental-features = nix-command flakes\n' >> "$NIX_CONF_DIR/nix.conf"

  log "verifying dev shell entry"
  if [ -f "${FLEET_WORKSPACE_PROJECT_DIR:-.}/flake.nix" ]; then
    ( cd "${FLEET_WORKSPACE_PROJECT_DIR:-.}" && "$NIX_BIN" develop --command zig version ) \
      && log "dev shell OK" || log "dev shell entry failed (see above)"
  fi
fi

# Best-effort: raise this repo's Codex sessions to the highest reasoning
# effort. Only takes effect if config.toml is written before the Codex CLI
# process starts, and only if no config.toml already exists (never clobber
# an existing one, e.g. auth-related content).
if [ -n "${CODEX_HOME:-}" ]; then
  mkdir -p "$CODEX_HOME"
  if [ ! -f "$CODEX_HOME/config.toml" ]; then
    printf 'model_reasoning_effort = "xhigh"\n' > "$CODEX_HOME/config.toml"
    log "wrote $CODEX_HOME/config.toml with model_reasoning_effort = xhigh"
  elif ! grep -q 'model_reasoning_effort' "$CODEX_HOME/config.toml"; then
    printf 'model_reasoning_effort = "xhigh"\n' >> "$CODEX_HOME/config.toml"
    log "appended model_reasoning_effort = xhigh to existing $CODEX_HOME/config.toml"
  else
    log "$CODEX_HOME/config.toml already sets model_reasoning_effort; leaving it alone"
  fi
fi

log "startup script finished"
