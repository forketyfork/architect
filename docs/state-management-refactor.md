# State Management Refactoring Plan

This document outlines the plan to migrate Architect's state management to a MobX-inspired reactive system using the new `src/state/` module.

## Status Quo

### Current Architecture

The application currently uses manual state management scattered across several layers:

1. **Application State (`src/app/app_state.zig`)**
   - `ViewMode` enum (Grid, Expanding, Full, Collapsing, Panning*)
   - `SessionStatus` enum (idle, running, awaiting_approval, done)
   - `AnimationState` struct with interpolation logic
   - No automatic dependency tracking or change notifications

2. **Session State (`src/session/state.zig`)**
   - Per-session data: PTY, terminal buffer, scroll position, CWD
   - `dirty` flag for manual cache invalidation
   - Direct field access without reactivity

3. **UI Host Snapshot (`src/ui/types.zig`)**
   - `UiHost`: read-only snapshot rebuilt every frame
   - Manual synchronization between app state and UI
   - `UiAction` queue for UI-to-app mutations

4. **Main Loop (`src/main.zig`)**
   - Central orchestration of state reads/writes
   - Manual propagation of state changes
   - Explicit dirty checking and cache invalidation

### Current Pain Points

- **Manual propagation**: State changes must be explicitly propagated through the call chain
- **Snapshot overhead**: `UiHost` is rebuilt every frame regardless of changes
- **Scattered mutations**: State modifications happen in multiple locations
- **No derived state**: Computed values (e.g., `isAnimating`, `canScroll`) are recalculated ad-hoc
- **Implicit dependencies**: Hard to trace which state a component depends on
- **Testing difficulty**: State interactions are hard to test in isolation

## Objectives

### Primary Goals

1. **Introduce reactive primitives** without disrupting existing functionality
2. **Enable automatic dependency tracking** for UI components
3. **Reduce boilerplate** for state synchronization
4. **Improve testability** with isolated, observable state units
5. **Prepare foundation** for future features (undo/redo, persistence, debugging)

### Non-Goals (This Phase)

- Complete rewrite of existing state management
- Breaking changes to the public API
- Performance optimization (focus on correctness first)
- Persistence/serialization of reactive state

## Technical Notes

### New Module: `src/state/`

The prototype introduces a MobX-inspired reactive state engine:

```
src/state/
├── mod.zig           # Public exports
├── tracker.zig       # Dependency tracking context
├── signal.zig        # Observable state primitive
├── computed.zig      # Derived reactive values
├── effect.zig        # Side effect reactions
└── store.zig         # Collections and transactions
```

### Core Primitives

#### Signal(T)
Observable state container that notifies subscribers on change:
```zig
var count = Signal(i32).init(allocator, 0);
defer count.deinit();

const value = count.get();  // Tracks dependency if in reactive context
count.set(42);              // Notifies all subscribers
```

#### Computed(T)
Derived values that auto-update when dependencies change:
```zig
var doubled = Computed(i32).init(allocator, struct {
    fn compute(_: *Computed(i32)) i32 {
        return count.get() * 2;  // Automatically tracks `count`
    }
}.compute, null);
```

#### Effect
Side effects that re-run when dependencies change:
```zig
var logger = try Effect.init(allocator, struct {
    fn run(_: ?*anyopaque) void {
        std.debug.print("Count: {}\n", .{count.get()});
    }
}.run, null);
```

#### Batching
Group updates to minimize cascading reactions:
```zig
state.beginBatch(allocator);
count.set(1);
count.set(2);
count.set(3);
state.endBatch();  // Effects run once, not three times
```

### Migration Strategy

The refactoring will proceed in phases to minimize risk:

#### Phase 1: Parallel Introduction (Current)
- [x] Implement reactive primitives in `src/state/`
- [x] Add comprehensive tests for core functionality
- [ ] Document API and patterns

#### Phase 2: App State Migration
- [ ] Create `AppStore` wrapping `ViewMode`, `focused_session`, animation state
- [ ] Replace direct field access with signal reads
- [ ] Keep existing `UiHost` as a compatibility layer

#### Phase 3: Session State Migration
- [ ] Create `SessionStore` for per-session reactive state
- [ ] Replace `dirty` flag with automatic invalidation
- [ ] Migrate scroll position, CWD, status to signals

#### Phase 4: UI Component Migration
- [ ] Convert UI components to use reactive state
- [ ] Replace `UiHost` snapshot with direct signal access
- [ ] Remove manual `needsFrame()` checks where possible

#### Phase 5: Cleanup and Optimization
- [ ] Remove obsolete synchronization code
- [ ] Profile and optimize hot paths
- [ ] Add derived state (computeds) for common patterns

### Design Decisions

1. **Explicit `.get()`/`.set()` API**: Unlike JavaScript's proxies, Zig requires explicit method calls. This is actually beneficial for clarity.

2. **Thread-local tracking**: The tracker uses thread-local storage for the current context, enabling nested computations.

3. **Allocator-aware**: All primitives accept an allocator, following Zig conventions for memory management.

4. **No global state in primitives**: Each signal/computed manages its own subscribers without a central registry.

5. **Batch semantics**: Batching defers notifications until the outermost batch ends, similar to MobX's `runInAction`.

### Integration Points

| Current Code | Reactive Equivalent |
|--------------|---------------------|
| `view_mode` variable | `Signal(ViewMode)` |
| `focused_session` variable | `Signal(usize)` |
| `session.dirty` flag | Automatic via signal subscription |
| `UiHost` snapshot | Computed or direct signal access |
| `UiAction` queue | Can coexist; actions trigger signal updates |
| `needsFrame()` | Effect that sets a frame-needed flag |

### Compatibility Considerations

- **Existing UI components**: Continue using `UiHost` initially; migrate incrementally
- **Renderer**: Can observe app state signals for automatic redraw triggers
- **Configuration**: Signals can wrap config values for reactive updates
- **Persistence**: Transaction API enables atomic save/restore

## Acceptance Criteria

### Phase 1 (Prototype) - Current
- [x] `Signal(T)` supports get/set with change detection
- [x] `Signal(T)` notifies subscribers on change
- [x] `Computed(T)` tracks dependencies automatically
- [x] `Computed(T)` recomputes only when dependencies change
- [x] `Effect` runs immediately and on dependency changes
- [x] Batching defers notifications until batch ends
- [x] All primitives pass unit tests
- [ ] Build succeeds with `zig build`
- [ ] Tests pass with `zig build test`

### Phase 2 (App State)
- [ ] `AppStore` encapsulates view mode, focus, animation
- [ ] State changes trigger appropriate reactions
- [ ] No regression in existing functionality
- [ ] `UiHost` can be populated from signals

### Phase 3 (Session State)
- [ ] `SessionStore` manages per-session reactive state
- [ ] Cache invalidation happens automatically
- [ ] Scroll, CWD, status are reactive
- [ ] Memory usage remains stable

### Phase 4 (UI Components)
- [ ] At least one UI component uses direct signal access
- [ ] Frame requests driven by reactivity where appropriate
- [ ] Component tests verify reactive behavior

### Phase 5 (Cleanup)
- [ ] Unused synchronization code removed
- [ ] Performance benchmarks show no regression
- [ ] Documentation updated for reactive patterns

## Example: Migrating ViewMode

### Before (Manual)
```zig
// main.zig
var view_mode: ViewMode = .Grid;

// Later...
view_mode = .Expanding;
// Must manually trigger dependent updates
renderer.setNeedsRedraw();
ui.invalidate();
```

### After (Reactive)
```zig
// app_store.zig
pub const AppStore = struct {
    view_mode: Signal(ViewMode),

    pub fn init(allocator: std.mem.Allocator) AppStore {
        return .{
            .view_mode = Signal(ViewMode).init(allocator, .Grid),
        };
    }
};

// main.zig
var app = AppStore.init(allocator);

// Renderer subscribes to view_mode
try app.view_mode.subscribe(struct {
    fn onViewModeChange(_: ?*anyopaque) void {
        renderer.setNeedsRedraw();
    }
}.onViewModeChange, null);

// Later... just set the value
app.view_mode.set(.Expanding);
// Renderer automatically notified
```

## References

- [MobX Documentation](https://mobx.js.org/README.html)
- [Solid.js Reactivity](https://www.solidjs.com/guides/reactivity)
- [Vue 3 Reactivity in Depth](https://vuejs.org/guide/extras/reactivity-in-depth.html)
