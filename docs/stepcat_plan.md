# Architect Reactive State Management Refactor

## Step 1: Harden Reactive Runtime
### Status Quo
- `src/state` primitives exist, but registry lifecycle is easy to forget and not wired by default.
- Tests cover basic get/set, but dependency-driven updates and rollback semantics are not fully validated or documented.
- Docs mention batching but do not explain lifecycle, rollback behavior, or threading assumptions.

### Objectives
- Make the reactive runtime safe to use as a standalone module.
- Document lifecycle requirements and limitations.
- Add tests for dependency updates and rollback semantics.

### Tech Notes
- Keep `state.init(allocator)` / `state.deinit()` as explicit calls.
- Add test coverage:
  - `Computed` updates when dependencies change.
  - `Effect` re-runs when dependencies change.
  - `Transaction.rollback` discards pending notifications (does not restore values).
- Document threading assumptions (thread-local tracking) and rollback limitations.

### Acceptance Criteria
- `state.init`/`state.deinit` documented and referenced in docs.
- Tests include dependency-driven recomputation and rollback notification discard.
- `zig build` and `zig build test` pass.

## Step 2: Integrate AppStore (First Wiring Phase)
### Status Quo
- App state lives in `app_state.zig` with direct field access.
- UI and renderer rely on manual change propagation and `UiHost` snapshots.

### Objectives
- Introduce `AppStore` with signals for view mode, focused session, animation state.
- Wire `state.init(...)` and `state.deinit()` into app startup/shutdown.
- Keep `UiHost` as compatibility layer while shifting reads to signals.

### Tech Notes
- Create `src/app/app_store.zig` (or similar) with `Signal` fields.
- Replace direct reads in `main.zig` / app logic with signal accessors.
- Populate `UiHost` from AppStore signals without breaking existing UI flow.
- Add an `Effect` or subscription to set redraw flags when app signals change.

### Acceptance Criteria
- `state.init`/`state.deinit` called exactly once in app lifecycle.
- `AppStore` exists and is the source of truth for view mode/focus/animation.
- No regressions in navigation or animation behavior.
- `UiHost` still functions but is populated from signals.

## Step 3: Migrate Session State to SessionStore
### Status Quo
- Session state uses manual `dirty` flags and direct field access.
- Cache invalidation and render updates are manual.

### Objectives
- Introduce `SessionStore` with signals for scroll, CWD, status, and any UI-facing fields.
- Remove reliance on `dirty` flag for invalidation.

### Tech Notes
- Create a per-session store struct and keep it owned with session lifecycle.
- Replace `dirty` checks with signal subscriptions or computed invalidation.
- Ensure platform-specific CWD persistence logic remains intact.

### Acceptance Criteria
- Session fields are signal-backed and invalidation is automatic.
- Manual `dirty` invalidation paths removed or narrowed to non-reactive data.
- No regressions in scroll behavior, focus switching, or status UI.

## Step 4: Migrate UI Components to Reactive Access
### Status Quo
- UI components read from `UiHost` snapshots and manual flags.
- Frame requests use explicit `needsFrame()` logic.

### Objectives
- Convert at least one UI component to read directly from signals/computeds.
- Use reactive effects to request frames when needed.

### Tech Notes
- Pick a small component (toast, help overlay, or ESC indicator).
- Replace `UiHost` reads with signal accessors and/or computed values.
- Use `first_frame_guard` when visibility toggles to ensure immediate render.

### Acceptance Criteria
- At least one component is fully reactive (no `UiHost` dependency).
- Frame requests are triggered by reactive effects where applicable.
- Component behavior matches previous UI.

## Step 5: Cleanup and Optimization
### Status Quo
- Compatibility layers and sync logic will still exist after partial migration.
- Derived state is computed ad-hoc in multiple places.

### Objectives
- Remove obsolete synchronization code and redundant snapshots.
- Consolidate common derived state into `Computed` values.
- Update documentation to match final architecture.

### Tech Notes
- Remove now-unused `UiHost` fields once all components migrate.
- Add `Computed` helpers for common UI/renderer checks (e.g., `isAnimating`).
- Update `docs/architecture.md` and `docs/state_management_refactor.md`.

### Acceptance Criteria
- No unused sync paths remain.
- Derived state has single source of truth via computeds.
- Docs accurately describe the reactive pipeline.
