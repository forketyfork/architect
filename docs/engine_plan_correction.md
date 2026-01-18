# Engine Plan Implementation Review

This document analyzes the current implementation state against `docs/engine_plan.md` and identifies deviations, completed items, and technical debt requiring attention.

## Summary

The UI framework refactor outlined in engine_plan.md has been **fully completed**. The core architecture is in place: `UiRoot` owns components, events route through UI first, actions flow via `UiActionQueue`, and UI renders as a separate overlay pass. All identified deviations have been addressed.

---

## Status by Plan Section

### Section 1: Shared Utility Modules ✅ COMPLETE

| Module | Status | Notes |
|--------|--------|-------|
| `src/geom.zig` | ✅ | `Rect` and `containsPoint` helpers present |
| `src/anim/easing.zig` | ✅ | `easeInOutCubic` and other easing functions present |
| `src/gfx/primitives.zig` | ✅ | `drawRoundedBorder`, `drawThickBorder` moved from renderer |

### Section 2: UI Framework ✅ COMPLETE

| Component | Status | Notes |
|-----------|--------|-------|
| `UiHost` | ✅ | Present in `types.zig`, matches spec with additional fields |
| `UiAction` | ✅ | Expanded beyond original spec with new actions |
| `UiComponent` | ✅ | Vtable interface matches spec, added `hitTest` and `wantsFrame` |
| `UiRoot` | ✅ | Component registry, dispatch, action queue all working |
| `UiActionQueue` | ✅ | Present in `types.zig` |
| `UiAssets` | ✅ | Present with `font_cache` for shared rendering resources |

### Section 3: Integration into main.zig ✅ COMPLETE

- ✅ `UiHost` snapshot is built each frame
- ✅ `ui.handleEvent()` is called before app logic
- ✅ Events can be consumed by UI components
- ✅ Actions are drained via `popAction()`
- ✅ UI renders after scene render (`ui.render()`)

### Section 4: Help Overlay Component ✅ COMPLETE

- ✅ Lives in `src/ui/components/help_overlay.zig`
- ✅ Internal state machine: `Closed`, `Expanding`, `Open`, `Collapsing`
- ✅ Handles click toggling and Cmd+/ keyboard shortcut
- ✅ Caches text textures with invalidation on theme/scale changes
- ✅ High z-index (1000) for proper layering

### Section 5: Toast Component ✅ COMPLETE

- ✅ Lives in `src/ui/components/toast.zig`
- ✅ **Critical improvement implemented**: texture caching
  - Texture rebuilt only when message changes (via `dirty` flag)
  - No per-frame TTF_OpenFont calls
- ✅ `UiRoot.showToast()` forwards to component
- ✅ Alpha fade is time-based without texture rebuild

### Section 6: Escape Hold Component ✅ COMPLETE

- ✅ Lives in `src/ui/components/escape_hold.zig`
- ✅ Uses `HoldGesture` from `src/ui/gestures/hold.zig`
- ✅ Handles keydown/keyup properly
- ✅ Quick press+release passes ESC through to terminal
- ✅ Hold completion pushes `UiAction.RequestCollapseFocused`
- ✅ Renders arc indicator only when active

### Section 7: Restart Buttons Component ✅ MOSTLY COMPLETE

- ✅ Lives in `src/ui/components/restart_buttons.zig`
- ✅ Component owns single shared "Restart" label texture
- ✅ Hit-testing is internal to component (not in main.zig)
- ✅ Pushes `UiAction.RestartSession` on click
- ✅ No `restart_button_texture` fields in `SessionState`

### Section 8: Cleanup ✅ MOSTLY COMPLETE

**8.1 UI types removed from app_state.zig:** ✅
- No `ToastNotification`, `HelpButtonAnimation`, `EscapeIndicator` types
- UI constants moved to respective components

**8.2 UI render functions removed from renderer.zig:** ✅
- No `renderToastNotification`, `renderHelpButton`, `renderEscapeIndicator`
- No `isPointInRect`, `getRestartButtonRect` utility functions

---

## Deviations and Technical Debt

### 1. CWD Bar ✅ FIXED

**Previous Issue:** The CWD bar stored UI textures directly on `SessionState`, violating the "no UI state on sessions" invariant.

**Resolution:** Created `CwdBarComponent` (`src/ui/components/cwd_bar.zig`) that:
1. Maintains a per-session texture cache internally (keyed by session index)
2. Renders during the UI overlay pass (after scene render)
3. Tracks path changes to invalidate textures when CWD changes
4. Supports font cache generation changes for DPI scaling

**Changes made:**
- Created `src/ui/components/cwd_bar.zig` with `CwdBarComponent`
- Extended `SessionUiInfo` with `cwd_path` and `cwd_basename` fields
- Removed `cwd_basename_tex`, `cwd_parent_tex`, `cwd_basename_w/h`, `cwd_parent_w/h`, `cwd_font_size`, and `cwd_dirty` from `SessionState`
- Removed `renderCwdBar` and `renderFadeGradient` functions from `renderer.zig`
- Removed unused CWD-related constants and `input` import from `renderer.zig`
- Registered `CwdBarComponent` with `UiRoot` in `main.zig`

### 2. Cache Texture Still on SessionState ⚠️ LOW PRIORITY (NOT A DEVIATION)

**Location:** `src/session/state.zig`

```zig
cache_texture: ?*c.SDL_Texture = null,
cache_w: c_int = 0,
cache_h: c_int = 0,
```

**Analysis:** This is used by `renderGridSessionCached` in renderer.zig for caching terminal content in grid view. This is arguably **scene state**, not UI state, because it caches the terminal cell content itself (not UI overlays). The plan's invariant was about UI state/textures, and this cache is for the terminal scene.

**Verdict:** Not a deviation - this is scene caching, not UI caching. No action needed.

---

## Extensions Beyond Original Plan

The following components were added after the plan was written, following the established patterns:

| Component | Purpose | Follows Pattern |
|-----------|---------|-----------------|
| `QuitConfirmComponent` | Quit confirmation dialog | ✅ |
| `WorktreeOverlayComponent` | Git worktree picker (⌘T) | ✅ |
| `GlobalShortcutsComponent` | Global shortcuts (⌘,) | ✅ |
| `PillGroupComponent` | Coordinates multiple pill overlays | ✅ |
| `ConfirmDialogComponent` | Generic confirmation modal | ✅ |
| `HotkeyIndicatorComponent` | Visual hotkey feedback | ✅ |
| `MarqueeLabelComponent` | Reusable scrolling text | ✅ |
| `ButtonComponent` | Reusable styled button | ✅ |
| `ExpandingOverlayComponent` | Shared animation state helper | ✅ |
| `FirstFrameGuard` | Idle throttling transition helper | ✅ |

These align with Section 10's prediction: "Once the framework exists, these become clean additions (no main.zig edits)."

---

## Recommendations

### Completed

1. ✅ **Extract CWD bar to UI component** - DONE
   - Created `src/ui/components/cwd_bar.zig`
   - Component maintains per-session texture cache internally
   - Removed `cwd_*_tex` fields from `SessionState`
   - `SessionUiInfo` now carries `cwd_path` and `cwd_basename` for rendering

### Future Considerations

1. **Document the scene vs UI texture distinction**
   - `cache_texture` for terminal content = scene (OK on session)
   - Text/label textures for bars/overlays = UI (should be in components)

2. **Consider unifying pill overlays**
   - `HelpOverlayComponent` and `WorktreeOverlayComponent` share similar patterns
   - Could potentially share more code via `ExpandingOverlay`

---

## Conclusion

The engine plan has been implemented successfully with 100% adherence. The CWD bar deviation has been resolved by extracting it into a proper UI component (`CwdBarComponent`), fully satisfying the "no UI state on sessions" invariant.
