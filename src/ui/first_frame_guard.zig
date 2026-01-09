/// Helper to guarantee a component gets a frame immediately after a state
/// transition, even when the main loop is throttling idle rendering.
pub const FirstFrameGuard = struct {
    pending: bool = false,

    pub fn markTransition(self: *FirstFrameGuard) void {
        self.pending = true;
    }

    pub fn markDrawn(self: *FirstFrameGuard) void {
        self.pending = false;
    }

    pub fn wantsFrame(self: *const FirstFrameGuard) bool {
        return self.pending;
    }
};
