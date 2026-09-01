const ir_mod = @import("ir.zig");
const source_mod = @import("source.zig");
const bridge = @import("zir/bridge.zig");

pub const Source = source_mod.Source;
pub const IrNode = ir_mod.IrNode;
pub const IrTag = ir_mod.IrTag;
pub const SourceRange = ir_mod.SourceRange;

pub const TypeInfo = bridge.TypeInfo;
pub const DeclInfo = bridge.DeclInfo;
pub const ParamInfo = bridge.ParamInfo;
pub const FnInfo = bridge.FnInfo;
pub const CallExprTypeInfo = bridge.CallExprTypeInfo;
pub const ZirBridgeError = bridge.ZirBridgeError;
pub const ZirBridge = bridge.ZirBridge;
