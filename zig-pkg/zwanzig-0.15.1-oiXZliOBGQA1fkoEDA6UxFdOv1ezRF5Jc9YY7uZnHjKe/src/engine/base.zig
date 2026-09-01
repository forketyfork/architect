const std = @import("std");

pub const EngineError = std.mem.Allocator.Error || error{AnalysisLimitExceeded};

/// Default maximum inlining depth for interprocedural analysis.
/// Functions are inlined up to this depth; deeper calls are treated as unknown effects.
pub const default_max_inline_depth: u32 = 3;
pub const default_max_worklist_steps: usize = 200_000;
