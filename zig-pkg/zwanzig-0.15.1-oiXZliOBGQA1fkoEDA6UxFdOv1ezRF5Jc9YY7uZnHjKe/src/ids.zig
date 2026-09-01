pub const AstNodeId = enum(u32) { _ };
pub const CfgNodeId = enum(u32) { _ };
pub const VarId = enum(u32) { _ };

pub fn astId(value: u32) AstNodeId {
    return @enumFromInt(value);
}

pub fn cfgId(value: u32) CfgNodeId {
    return @enumFromInt(value);
}

pub fn varId(value: u32) VarId {
    return @enumFromInt(value);
}

pub fn astIndex(id: AstNodeId) u32 {
    return @intFromEnum(id);
}

pub fn cfgIndex(id: CfgNodeId) u32 {
    return @intFromEnum(id);
}

pub fn varIndex(id: VarId) u32 {
    return @intFromEnum(id);
}
