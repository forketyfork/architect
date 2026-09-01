const std = @import("std");
const compat = @import("compat.zig");
const RuleFilter = @import("rule_filter.zig").RuleFilter;

/// Resource model kind matching store.zig ResourceKind
pub const ResourceModelKind = enum {
    alloc,
    free,
    free_owned,
    open,
    close,
};

pub const EscapeCapture = enum {
    @"return",
    receiver,
    global,
    thread,
};

pub const EscapeModel = struct {
    /// Fully qualified function name (e.g., "std.process.Child.init")
    fqn: ?[]const u8 = null,
    /// Method/function name to match (e.g., "append")
    method_name: ?[]const u8 = null,
    /// Receiver type to match (e.g., "std.ArrayList")
    receiver_type: ?[]const u8 = null,
    /// Indices of arguments that are captured
    param_indices: []const u32 = &.{},
    /// Where the captured value escapes to
    captures_into: EscapeCapture,
};

/// A resource model defines how to match resource acquisition/release patterns.
pub const ResourceModel = struct {
    /// The kind of resource operation
    kind: ResourceModelKind,
    /// Method name to match (e.g., "open", "MyPool.open")
    method_name: ?[]const u8 = null,
    /// Receiver type to match (e.g., "MyResource")
    receiver_type: ?[]const u8 = null,
    /// Return type to match (e.g., "std.fs.File")
    return_type: ?[]const u8 = null,
    /// Fully qualified function name (e.g., "mymodule.openResource")
    fqn: ?[]const u8 = null,
};

pub const Config = struct {
    rule_filter: RuleFilter,
    max_worklist_steps: ?usize = null,
    max_states_per_point: ?u32 = null,
    /// Enable widening for convergence (loop headers and join points)
    use_widening: ?bool = null,
    /// Max helper-call depth for stack escape tracking
    escape_max_depth: ?u32 = null,
    /// Custom resource models for resource tracking
    resource_models: []const ResourceModel = &.{},
    /// Custom escape models for stack escape detection
    escape_models: []const EscapeModel = &.{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        switch (self.rule_filter) {
            .allowlist => |list| {
                for (list) |rule_name| {
                    allocator.free(rule_name);
                }
                allocator.free(list);
            },
            .blocklist => |list| {
                for (list) |rule_name| {
                    allocator.free(rule_name);
                }
                allocator.free(list);
            },
            .none => {},
        }

        // Free resource model strings
        for (self.resource_models) |model| {
            if (model.method_name) |name| allocator.free(name);
            if (model.receiver_type) |ty| allocator.free(ty);
            if (model.return_type) |ty| allocator.free(ty);
            if (model.fqn) |name| allocator.free(name);
        }
        if (self.resource_models.len > 0) {
            allocator.free(self.resource_models);
        }

        for (self.escape_models) |model| {
            if (model.fqn) |name| allocator.free(name);
            if (model.method_name) |name| allocator.free(name);
            if (model.receiver_type) |ty| allocator.free(ty);
            if (model.param_indices.len > 0) {
                allocator.free(model.param_indices);
            }
        }
        if (self.escape_models.len > 0) {
            allocator.free(self.escape_models);
        }
    }

    /// Match a call against resource models.
    /// Returns the matching resource kind if found.
    /// Parameters:
    /// - method_name: The method/function name being called
    /// - receiver_type: The type of the receiver (e.g., "MyPool" for MyPool.open())
    /// - return_type: The return type of the call
    /// - fqn: Optional fully qualified name (e.g., "mymodule.createResource")
    pub fn matchResourceModel(self: *const Config, method_name: []const u8, receiver_type: ?[]const u8, return_type: ?[]const u8, fqn: ?[]const u8) ?ResourceModelKind {
        for (self.resource_models) |model| {
            const has_match = model.fqn != null or
                model.method_name != null or
                model.receiver_type != null or
                model.return_type != null;
            if (!has_match) continue;

            // Check FQN match first (if model has fqn, it takes precedence)
            if (model.fqn) |expected_fqn| {
                if (fqn) |actual_fqn| {
                    if (std.mem.eql(u8, actual_fqn, expected_fqn)) {
                        return model.kind;
                    }
                }
                // FQN is specified but doesn't match - skip this model
                continue;
            }

            // Check method name match
            if (model.method_name) |expected_method| {
                if (!std.mem.eql(u8, method_name, expected_method)) continue;
            }

            // Check receiver type match (if specified)
            if (model.receiver_type) |expected_receiver| {
                if (receiver_type) |actual| {
                    if (!std.mem.eql(u8, actual, expected_receiver)) continue;
                } else {
                    continue;
                }
            }

            // Check return type match (if specified)
            if (model.return_type) |expected_return| {
                if (return_type) |actual| {
                    if (!std.mem.eql(u8, actual, expected_return)) continue;
                } else {
                    continue;
                }
            }

            // All specified criteria matched
            return model.kind;
        }
        return null;
    }

    pub fn matchEscapeModel(self: *const Config, method_name: []const u8, receiver_type: ?[]const u8, fqn: ?[]const u8) ?*const EscapeModel {
        for (self.escape_models) |*model| {
            const has_match = model.fqn != null or
                model.method_name != null or
                model.receiver_type != null;
            if (!has_match) continue;

            if (model.fqn) |expected_fqn| {
                if (fqn) |actual_fqn| {
                    if (std.mem.eql(u8, actual_fqn, expected_fqn)) {
                        return model;
                    }
                }
                continue;
            }

            if (model.method_name) |expected_method| {
                if (!std.mem.eql(u8, method_name, expected_method)) continue;
            }

            if (model.receiver_type) |expected_receiver| {
                if (receiver_type) |actual| {
                    if (!std.mem.eql(u8, actual, expected_receiver)) continue;
                } else {
                    continue;
                }
            }

            return model;
        }
        return null;
    }
};

pub const ConfigError = error{
    FileNotFound,
    InvalidJson,
    InvalidConfigFormat,
    OutOfMemory,
    MutuallyExclusiveFields,
};

pub fn loadConfig(io_context: *compat.Context, allocator: std.mem.Allocator, path: []const u8) ConfigError!Config {
    const content = compat.readFileAlloc(io_context, allocator, path, 1024 * 1024) catch |err| {
        return switch (err) {
            error.FileNotFound => ConfigError.FileNotFound,
            error.OutOfMemory => ConfigError.OutOfMemory,
            else => ConfigError.InvalidJson,
        };
    };
    defer allocator.free(content.ptr[0 .. content.len + 1]);

    return parseConfig(allocator, content);
}

pub fn parseConfig(allocator: std.mem.Allocator, content: []const u8) ConfigError!Config {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        content,
        .{},
    ) catch |err| {
        return switch (err) {
            error.OutOfMemory => ConfigError.OutOfMemory,
            else => ConfigError.InvalidJson,
        };
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        return ConfigError.InvalidConfigFormat;
    }

    const obj = root.object;

    const enabled_rules = obj.get("enabled_rules");
    const disabled_rules = obj.get("disabled_rules");
    const max_worklist_steps_value = obj.get("max_worklist_steps");
    const max_states_per_point_value = obj.get("max_states_per_point");
    const use_widening_value = obj.get("use_widening");
    const escape_max_depth_value = obj.get("escape_max_depth");

    if (enabled_rules != null and disabled_rules != null) {
        return ConfigError.MutuallyExclusiveFields;
    }

    var max_worklist_steps: ?usize = null;
    if (max_worklist_steps_value) |value| {
        if (value != .integer) {
            return ConfigError.InvalidConfigFormat;
        }
        if (value.integer <= 0) {
            return ConfigError.InvalidConfigFormat;
        }
        max_worklist_steps = std.math.cast(usize, value.integer) orelse return ConfigError.InvalidConfigFormat;
    }

    var max_states_per_point: ?u32 = null;
    if (max_states_per_point_value) |value| {
        if (value != .integer) {
            return ConfigError.InvalidConfigFormat;
        }
        if (value.integer <= 0) {
            return ConfigError.InvalidConfigFormat;
        }
        max_states_per_point = std.math.cast(u32, value.integer) orelse return ConfigError.InvalidConfigFormat;
    }

    var use_widening: ?bool = null;
    if (use_widening_value) |value| {
        if (value != .bool) {
            return ConfigError.InvalidConfigFormat;
        }
        use_widening = value.bool;
    }

    var escape_max_depth: ?u32 = null;
    if (escape_max_depth_value) |value| {
        if (value != .integer) {
            return ConfigError.InvalidConfigFormat;
        }
        if (value.integer <= 0) {
            return ConfigError.InvalidConfigFormat;
        }
        escape_max_depth = std.math.cast(u32, value.integer) orelse return ConfigError.InvalidConfigFormat;
    }

    // Parse resource_models first so all return paths can include it
    const resource_models_value = obj.get("resource_models");
    var resource_models: []ResourceModel = &.{};
    if (resource_models_value) |rm_value| {
        resource_models = try parseResourceModels(allocator, rm_value);
    }
    errdefer {
        for (resource_models) |model| {
            if (model.method_name) |name| allocator.free(name);
            if (model.receiver_type) |ty| allocator.free(ty);
            if (model.return_type) |ty| allocator.free(ty);
            if (model.fqn) |name| allocator.free(name);
        }
        if (resource_models.len > 0) {
            allocator.free(resource_models);
        }
    }

    const escape_models_value = obj.get("escape_models");
    var escape_models: []EscapeModel = &.{};
    if (escape_models_value) |em_value| {
        escape_models = try parseEscapeModels(allocator, em_value);
    }
    errdefer {
        for (escape_models) |model| {
            if (model.fqn) |name| allocator.free(name);
            if (model.method_name) |name| allocator.free(name);
            if (model.receiver_type) |ty| allocator.free(ty);
            if (model.param_indices.len > 0) {
                allocator.free(model.param_indices);
            }
        }
        if (escape_models.len > 0) {
            allocator.free(escape_models);
        }
    }

    if (enabled_rules) |rules_value| {
        if (rules_value != .array) {
            return ConfigError.InvalidConfigFormat;
        }
        const rules_array = rules_value.array;

        var rule_names = try allocator.alloc([]const u8, rules_array.items.len);

        for (rules_array.items, 0..) |item, i| {
            if (item != .string) {
                for (rule_names[0..i]) |name| {
                    allocator.free(name);
                }
                allocator.free(rule_names);
                return ConfigError.InvalidConfigFormat;
            }
            rule_names[i] = try allocator.dupe(u8, item.string);
        }

        return Config{
            .rule_filter = .{ .allowlist = rule_names },
            .max_worklist_steps = max_worklist_steps,
            .max_states_per_point = max_states_per_point,
            .use_widening = use_widening,
            .escape_max_depth = escape_max_depth,
            .resource_models = resource_models,
            .escape_models = escape_models,
        };
    }

    if (disabled_rules) |rules_value| {
        if (rules_value != .array) {
            return ConfigError.InvalidConfigFormat;
        }
        const rules_array = rules_value.array;

        var rule_names = try allocator.alloc([]const u8, rules_array.items.len);

        for (rules_array.items, 0..) |item, i| {
            if (item != .string) {
                for (rule_names[0..i]) |name| {
                    allocator.free(name);
                }
                allocator.free(rule_names);
                return ConfigError.InvalidConfigFormat;
            }
            rule_names[i] = try allocator.dupe(u8, item.string);
        }

        return Config{
            .rule_filter = .{ .blocklist = rule_names },
            .max_worklist_steps = max_worklist_steps,
            .max_states_per_point = max_states_per_point,
            .use_widening = use_widening,
            .escape_max_depth = escape_max_depth,
            .resource_models = resource_models,
            .escape_models = escape_models,
        };
    }

    return Config{
        .rule_filter = .none,
        .max_worklist_steps = max_worklist_steps,
        .max_states_per_point = max_states_per_point,
        .use_widening = use_widening,
        .escape_max_depth = escape_max_depth,
        .resource_models = resource_models,
        .escape_models = escape_models,
    };
}

fn parseEscapeModels(allocator: std.mem.Allocator, value: std.json.Value) ConfigError![]EscapeModel {
    if (value != .array) {
        return ConfigError.InvalidConfigFormat;
    }
    const array = value.array;

    if (array.items.len == 0) {
        return &.{};
    }

    var models = try allocator.alloc(EscapeModel, array.items.len);
    var valid_count: usize = 0;

    errdefer {
        for (models[0..valid_count]) |model| {
            if (model.fqn) |name| allocator.free(name);
            if (model.method_name) |name| allocator.free(name);
            if (model.receiver_type) |ty| allocator.free(ty);
            if (model.param_indices.len > 0) {
                allocator.free(model.param_indices);
            }
        }
        allocator.free(models);
    }

    for (array.items) |item| {
        if (item != .object) {
            return ConfigError.InvalidConfigFormat;
        }

        const model_obj = item.object;

        const captures_value = model_obj.get("captures_into") orelse return ConfigError.InvalidConfigFormat;
        if (captures_value != .string) return ConfigError.InvalidConfigFormat;
        const captures_str = captures_value.string;
        const captures_into: EscapeCapture = if (std.mem.eql(u8, captures_str, "return"))
            .@"return"
        else if (std.mem.eql(u8, captures_str, "receiver"))
            .receiver
        else if (std.mem.eql(u8, captures_str, "global"))
            .global
        else if (std.mem.eql(u8, captures_str, "thread"))
            .thread
        else
            return ConfigError.InvalidConfigFormat;

        const param_value = model_obj.get("param_indices") orelse return ConfigError.InvalidConfigFormat;
        if (param_value != .array) return ConfigError.InvalidConfigFormat;
        const param_array = param_value.array;
        if (param_array.items.len == 0) return ConfigError.InvalidConfigFormat;

        var indices = try allocator.alloc(u32, param_array.items.len);
        errdefer allocator.free(indices);
        for (param_array.items, 0..) |param_item, i| {
            if (param_item != .integer) {
                allocator.free(indices);
                return ConfigError.InvalidConfigFormat;
            }
            if (param_item.integer < 0) {
                allocator.free(indices);
                return ConfigError.InvalidConfigFormat;
            }
            indices[i] = std.math.cast(u32, param_item.integer) orelse {
                allocator.free(indices);
                return ConfigError.InvalidConfigFormat;
            };
        }

        var model = EscapeModel{
            .param_indices = indices,
            .captures_into = captures_into,
        };

        if (model_obj.get("fqn")) |v| {
            if (v != .string) {
                allocator.free(indices);
                return ConfigError.InvalidConfigFormat;
            }
            model.fqn = try allocator.dupe(u8, v.string);
        }

        if (model_obj.get("method_name")) |v| {
            if (v != .string) {
                if (model.fqn) |name| allocator.free(name);
                allocator.free(indices);
                return ConfigError.InvalidConfigFormat;
            }
            model.method_name = try allocator.dupe(u8, v.string);
        }

        if (model_obj.get("receiver_type")) |v| {
            if (v != .string) {
                if (model.fqn) |name| allocator.free(name);
                if (model.method_name) |name| allocator.free(name);
                allocator.free(indices);
                return ConfigError.InvalidConfigFormat;
            }
            model.receiver_type = try allocator.dupe(u8, v.string);
        }

        const has_match = model.fqn != null or model.method_name != null or model.receiver_type != null;
        if (!has_match) {
            if (model.fqn) |name| allocator.free(name);
            if (model.method_name) |name| allocator.free(name);
            if (model.receiver_type) |ty| allocator.free(ty);
            allocator.free(indices);
            return ConfigError.InvalidConfigFormat;
        }

        models[valid_count] = model;
        valid_count += 1;
    }

    return models;
}

fn parseResourceModels(allocator: std.mem.Allocator, value: std.json.Value) ConfigError![]ResourceModel {
    if (value != .array) {
        return ConfigError.InvalidConfigFormat;
    }
    const array = value.array;

    if (array.items.len == 0) {
        return &.{};
    }

    var models = try allocator.alloc(ResourceModel, array.items.len);
    var valid_count: usize = 0;

    errdefer {
        // Free any successfully parsed models on error
        for (models[0..valid_count]) |model| {
            if (model.method_name) |name| allocator.free(name);
            if (model.receiver_type) |ty| allocator.free(ty);
            if (model.return_type) |ty| allocator.free(ty);
            if (model.fqn) |name| allocator.free(name);
        }
        allocator.free(models);
    }

    for (array.items) |item| {
        if (item != .object) {
            return ConfigError.InvalidConfigFormat;
        }

        const model_obj = item.object;
        const kind_value = model_obj.get("kind") orelse return ConfigError.InvalidConfigFormat;
        if (kind_value != .string) return ConfigError.InvalidConfigFormat;

        const kind_str = kind_value.string;
        const kind: ResourceModelKind = if (std.mem.eql(u8, kind_str, "alloc"))
            .alloc
        else if (std.mem.eql(u8, kind_str, "free"))
            .free
        else if (std.mem.eql(u8, kind_str, "free_owned"))
            .free_owned
        else if (std.mem.eql(u8, kind_str, "open"))
            .open
        else if (std.mem.eql(u8, kind_str, "close"))
            .close
        else
            return ConfigError.InvalidConfigFormat;

        var model = ResourceModel{ .kind = kind };

        if (model_obj.get("method_name")) |v| {
            if (v != .string) return ConfigError.InvalidConfigFormat;
            model.method_name = try allocator.dupe(u8, v.string);
        }

        if (model_obj.get("receiver_type")) |v| {
            if (v != .string) {
                if (model.method_name) |name| allocator.free(name);
                return ConfigError.InvalidConfigFormat;
            }
            model.receiver_type = try allocator.dupe(u8, v.string);
        }

        if (model_obj.get("return_type")) |v| {
            if (v != .string) {
                if (model.method_name) |name| allocator.free(name);
                if (model.receiver_type) |ty| allocator.free(ty);
                return ConfigError.InvalidConfigFormat;
            }
            model.return_type = try allocator.dupe(u8, v.string);
        }

        if (model_obj.get("fqn")) |v| {
            if (v != .string) {
                if (model.method_name) |name| allocator.free(name);
                if (model.receiver_type) |ty| allocator.free(ty);
                if (model.return_type) |ty| allocator.free(ty);
                return ConfigError.InvalidConfigFormat;
            }
            model.fqn = try allocator.dupe(u8, v.string);
        }

        models[valid_count] = model;
        valid_count += 1;
    }

    return models;
}

test "parseConfig: empty config" {
    const allocator = std.testing.allocator;
    const content = "{}";
    var config = try parseConfig(allocator, content);
    defer config.deinit(allocator);

    try std.testing.expectEqual(RuleFilter.none, config.rule_filter);
}

test "parseConfig: enabled_rules" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "enabled_rules": ["empty-catch", "dupe-import"]
        \\}
    ;
    var config = try parseConfig(allocator, content);
    defer config.deinit(allocator);

    switch (config.rule_filter) {
        .allowlist => |list| {
            try std.testing.expectEqual(@as(usize, 2), list.len);
            try std.testing.expectEqualStrings("empty-catch", list[0]);
            try std.testing.expectEqualStrings("dupe-import", list[1]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "parseConfig: disabled_rules" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "disabled_rules": ["todo", "unused-decl"]
        \\}
    ;
    var config = try parseConfig(allocator, content);
    defer config.deinit(allocator);

    switch (config.rule_filter) {
        .blocklist => |list| {
            try std.testing.expectEqual(@as(usize, 2), list.len);
            try std.testing.expectEqualStrings("todo", list[0]);
            try std.testing.expectEqualStrings("unused-decl", list[1]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "parseConfig: mutual exclusion" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "enabled_rules": ["empty-catch"],
        \\  "disabled_rules": ["todo"]
        \\}
    ;
    const result = parseConfig(allocator, content);
    try std.testing.expectError(ConfigError.MutuallyExclusiveFields, result);
}

test "parseConfig: invalid JSON" {
    const allocator = std.testing.allocator;
    const content = "{invalid json}";
    const result = parseConfig(allocator, content);
    try std.testing.expectError(ConfigError.InvalidJson, result);
}

test "parseConfig: not an object" {
    const allocator = std.testing.allocator;
    const content = "[]";
    const result = parseConfig(allocator, content);
    try std.testing.expectError(ConfigError.InvalidConfigFormat, result);
}

test "parseConfig: enabled_rules not an array" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "enabled_rules": "empty-catch"
        \\}
    ;
    const result = parseConfig(allocator, content);
    try std.testing.expectError(ConfigError.InvalidConfigFormat, result);
}

test "parseConfig: enabled_rules contains non-string" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "enabled_rules": ["empty-catch", 42]
        \\}
    ;
    const result = parseConfig(allocator, content);
    try std.testing.expectError(ConfigError.InvalidConfigFormat, result);
}

test "loadConfig: file not found" {
    const allocator = std.testing.allocator;
    const result = loadConfig(compat.defaultContext(), allocator, "nonexistent.json");
    try std.testing.expectError(ConfigError.FileNotFound, result);
}

test "parseConfig: resource_models" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "resource_models": [
        \\    {"kind": "open", "method_name": "MyPool.open", "return_type": "MyResource"},
        \\    {"kind": "close", "method_name": "close", "receiver_type": "MyResource"}
        \\  ]
        \\}
    ;
    var config = try parseConfig(allocator, content);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), config.resource_models.len);

    const open_model = config.resource_models[0];
    try std.testing.expectEqual(ResourceModelKind.open, open_model.kind);
    try std.testing.expectEqualStrings("MyPool.open", open_model.method_name.?);
    try std.testing.expectEqualStrings("MyResource", open_model.return_type.?);
    try std.testing.expect(open_model.receiver_type == null);

    const close_model = config.resource_models[1];
    try std.testing.expectEqual(ResourceModelKind.close, close_model.kind);
    try std.testing.expectEqualStrings("close", close_model.method_name.?);
    try std.testing.expectEqualStrings("MyResource", close_model.receiver_type.?);
    try std.testing.expect(close_model.return_type == null);
}

test "parseConfig: resource_models with fqn" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "resource_models": [
        \\    {"kind": "alloc", "fqn": "mymodule.createResource"}
        \\  ]
        \\}
    ;
    var config = try parseConfig(allocator, content);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), config.resource_models.len);
    try std.testing.expectEqual(ResourceModelKind.alloc, config.resource_models[0].kind);
    try std.testing.expectEqualStrings("mymodule.createResource", config.resource_models[0].fqn.?);
}

test "parseConfig: resource_models free_owned" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "resource_models": [
        \\    {"kind": "free_owned", "method_name": "deinit", "receiver_type": "*MyType"}
        \\  ]
        \\}
    ;
    var config = try parseConfig(allocator, content);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), config.resource_models.len);
    try std.testing.expectEqual(ResourceModelKind.free_owned, config.resource_models[0].kind);
    try std.testing.expectEqualStrings("deinit", config.resource_models[0].method_name.?);
    try std.testing.expectEqualStrings("*MyType", config.resource_models[0].receiver_type.?);
}

test "parseConfig: escape_models" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "escape_models": [
        \\    {"fqn": "std.process.Child.init", "param_indices": [0], "captures_into": "return"},
        \\    {"method_name": "append", "receiver_type": "std.ArrayList", "param_indices": [0], "captures_into": "receiver"}
        \\  ]
        \\}
    ;
    var config = try parseConfig(allocator, content);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), config.escape_models.len);
    const first = config.escape_models[0];
    try std.testing.expectEqualStrings("std.process.Child.init", first.fqn.?);
    try std.testing.expectEqual(@as(usize, 1), first.param_indices.len);
    try std.testing.expectEqual(@as(u32, 0), first.param_indices[0]);
    try std.testing.expectEqual(EscapeCapture.@"return", first.captures_into);

    const second = config.escape_models[1];
    try std.testing.expectEqualStrings("append", second.method_name.?);
    try std.testing.expectEqualStrings("std.ArrayList", second.receiver_type.?);
    try std.testing.expectEqual(EscapeCapture.receiver, second.captures_into);
}

test "parseConfig: resource_models invalid kind" {
    const allocator = std.testing.allocator;
    const content =
        \\{
        \\  "resource_models": [
        \\    {"kind": "invalid_kind"}
        \\  ]
        \\}
    ;
    const result = parseConfig(allocator, content);
    try std.testing.expectError(ConfigError.InvalidConfigFormat, result);
}

test "Config.matchResourceModel" {
    var cfg = Config{
        .rule_filter = .none,
        .resource_models = &.{
            ResourceModel{ .kind = .open, .method_name = "acquire" },
            ResourceModel{ .kind = .close, .method_name = "release", .receiver_type = "MyHandle" },
            ResourceModel{ .kind = .alloc, .fqn = "mymodule.createResource" },
            ResourceModel{ .kind = .free_owned, .method_name = "deinit", .receiver_type = "*MyType" },
        },
    };

    // Match by method name only
    const open_match = cfg.matchResourceModel("acquire", null, null, null);
    try std.testing.expectEqual(ResourceModelKind.open, open_match.?);

    // Match by method name + receiver type
    const close_match = cfg.matchResourceModel("release", "MyHandle", null, null);
    try std.testing.expectEqual(ResourceModelKind.close, close_match.?);

    // No match - wrong receiver type
    const no_match = cfg.matchResourceModel("release", "OtherHandle", null, null);
    try std.testing.expect(no_match == null);

    // No match - unknown method
    const unknown_match = cfg.matchResourceModel("unknown", null, null, null);
    try std.testing.expect(unknown_match == null);

    // Match by FQN
    const fqn_match = cfg.matchResourceModel("createResource", null, null, "mymodule.createResource");
    try std.testing.expectEqual(ResourceModelKind.alloc, fqn_match.?);

    // Match by receiver type + method name
    const free_owned_match = cfg.matchResourceModel("deinit", "*MyType", null, null);
    try std.testing.expectEqual(ResourceModelKind.free_owned, free_owned_match.?);

    // No FQN match - wrong FQN
    const no_fqn_match = cfg.matchResourceModel("createResource", null, null, "othermodule.createResource");
    try std.testing.expect(no_fqn_match == null);

    // FQN match takes precedence - even if method name alone would match
    // (the model with fqn should only match when fqn is provided and matches)
}

test "Config.matchResourceModel with return_type" {
    var cfg = Config{
        .rule_filter = .none,
        .resource_models = &.{
            ResourceModel{ .kind = .open, .return_type = "MyResource" },
        },
    };

    // Match by return type
    const rt_match = cfg.matchResourceModel("customAcquire", null, "MyResource", null);
    try std.testing.expectEqual(ResourceModelKind.open, rt_match.?);

    // No match - different return type
    const no_rt_match = cfg.matchResourceModel("customAcquire", null, "OtherType", null);
    try std.testing.expect(no_rt_match == null);
}
