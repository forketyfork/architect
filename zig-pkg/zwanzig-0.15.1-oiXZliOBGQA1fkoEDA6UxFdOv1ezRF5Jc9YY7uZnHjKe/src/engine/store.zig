const std = @import("std");
const ast_walk = @import("../ast_walk.zig");
const ids = @import("../ids.zig");

const VarId = ids.VarId;

pub const ResourceState = enum {
    unknown,
    allocated,
    freed,
    non_allocated,
    open,
    closed,
};

pub const StoreViolationKind = enum {
    double_free,
    free_without_alloc,
    double_close,
    close_without_open,
    use_after_free,
    use_after_close,
    resource_leak,
    /// A resource with a queued deferred free was passed into a container
    /// declared in a scope that outlives the defer. When the defer fires
    /// at block exit the container is left holding a freed slice.
    defer_frees_escapee,
};

const DeferredAction = enum {
    free,
    close,
    free_owned,
};

const DeferredEntry = struct {
    action: DeferredAction,
    /// AST node of the lexical block that owns the defer. When that block
    /// exits the action fires; this is what makes "container outlives defer"
    /// decidable at the moment of escape.
    scope_node: ?u32,
};

fn deferredEntryEql(lhs: DeferredEntry, rhs: DeferredEntry) bool {
    return lhs.action == rhs.action and lhs.scope_node == rhs.scope_node;
}

const ErrdeferAction = struct {
    action: DeferredAction,
    call_token: ?u32,
    scope_node: ?u32,
};

fn errdeferActionEql(lhs: ErrdeferAction, rhs: ErrdeferAction) bool {
    return lhs.action == rhs.action and
        lhs.call_token == rhs.call_token and
        lhs.scope_node == rhs.scope_node;
}

pub const StoreViolation = struct {
    region: VarId,
    kind: StoreViolationKind,
    call_token: ?u32,

    pub fn eql(self: StoreViolation, other: StoreViolation) bool {
        return self.region == other.region and self.kind == other.kind and self.call_token == other.call_token;
    }

    pub fn hash(self: StoreViolation) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const region_index = ids.varIndex(self.region);
        hasher.update(std.mem.asBytes(&region_index));
        hasher.update(std.mem.asBytes(&self.kind));
        const has_token: u8 = if (self.call_token) |_| 1 else 0;
        hasher.update(std.mem.asBytes(&has_token));
        if (self.call_token) |token| {
            hasher.update(std.mem.asBytes(&token));
        }
        return hasher.final();
    }
};

pub const Store = struct {
    resources: std.AutoHashMap(VarId, ResourceState),
    violations: std.ArrayList(StoreViolation),
    aliases: std.AutoHashMap(VarId, VarId),
    deferred: std.AutoHashMap(VarId, DeferredEntry),
    errdeferred: std.AutoHashMap(VarId, ErrdeferAction),
    owners: std.AutoHashMap(VarId, VarId),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .resources = std.AutoHashMap(VarId, ResourceState).init(allocator),
            .violations = .empty,
            .aliases = std.AutoHashMap(VarId, VarId).init(allocator),
            .deferred = std.AutoHashMap(VarId, DeferredEntry).init(allocator),
            .errdeferred = std.AutoHashMap(VarId, ErrdeferAction).init(allocator),
            .owners = std.AutoHashMap(VarId, VarId).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Store) void {
        self.resources.deinit();
        self.violations.deinit(self.allocator);
        self.aliases.deinit();
        self.deferred.deinit();
        self.errdeferred.deinit();
        self.owners.deinit();
    }

    pub fn clone(self: *const Store, allocator: std.mem.Allocator) !Store {
        var new_store = Store.init(allocator);
        errdefer new_store.deinit();

        var iter = self.resources.iterator();
        while (iter.next()) |entry| {
            try new_store.resources.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        for (self.violations.items) |violation| {
            try new_store.violations.append(allocator, violation);
        }

        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            try new_store.aliases.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var deferred_iter = self.deferred.iterator();
        while (deferred_iter.next()) |entry| {
            try new_store.deferred.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var errdeferred_iter = self.errdeferred.iterator();
        while (errdeferred_iter.next()) |entry| {
            try new_store.errdeferred.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var owners_iter = self.owners.iterator();
        while (owners_iter.next()) |entry| {
            try new_store.owners.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return new_store;
    }

    pub fn eql(self: *const Store, other: *const Store) bool {
        if (self.resources.count() != other.resources.count()) return false;
        var iter = self.resources.iterator();
        while (iter.next()) |entry| {
            if (other.resources.get(entry.key_ptr.*)) |other_state| {
                if (entry.value_ptr.* != other_state) return false;
            } else {
                return false;
            }
        }

        if (self.violations.items.len != other.violations.items.len) return false;
        for (self.violations.items) |lhs| {
            var found = false;
            for (other.violations.items) |rhs| {
                if (lhs.eql(rhs)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        if (self.aliases.count() != other.aliases.count()) return false;
        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            if (other.aliases.get(entry.key_ptr.*)) |other_target| {
                if (entry.value_ptr.* != other_target) return false;
            } else {
                return false;
            }
        }

        if (self.deferred.count() != other.deferred.count()) return false;
        var deferred_iter = self.deferred.iterator();
        while (deferred_iter.next()) |entry| {
            if (other.deferred.get(entry.key_ptr.*)) |other_entry| {
                if (!deferredEntryEql(entry.value_ptr.*, other_entry)) return false;
            } else {
                return false;
            }
        }

        if (self.errdeferred.count() != other.errdeferred.count()) return false;
        var errdeferred_iter = self.errdeferred.iterator();
        while (errdeferred_iter.next()) |entry| {
            if (other.errdeferred.get(entry.key_ptr.*)) |other_action| {
                if (!errdeferActionEql(entry.value_ptr.*, other_action)) return false;
            } else {
                return false;
            }
        }

        if (self.owners.count() != other.owners.count()) return false;
        var owners_iter = self.owners.iterator();
        while (owners_iter.next()) |entry| {
            if (other.owners.get(entry.key_ptr.*)) |other_owner| {
                if (entry.value_ptr.* != other_owner) return false;
            } else {
                return false;
            }
        }

        return true;
    }

    pub fn computeHash(self: *const Store) u64 {
        var resources_hash: u64 = 0;

        var iter = self.resources.iterator();
        while (iter.next()) |entry| {
            var hasher = std.hash.Wyhash.init(0);
            const key = ids.varIndex(entry.key_ptr.*);
            hasher.update(std.mem.asBytes(&key));
            hasher.update(std.mem.asBytes(&entry.value_ptr.*));
            resources_hash ^= hasher.final();
        }

        var violations_hash: u64 = 0;
        for (self.violations.items) |violation| {
            violations_hash ^= violation.hash();
        }

        var aliases_hash: u64 = 0;
        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            var hasher = std.hash.Wyhash.init(0);
            const key = ids.varIndex(entry.key_ptr.*);
            const value = ids.varIndex(entry.value_ptr.*);
            hasher.update(std.mem.asBytes(&key));
            hasher.update(std.mem.asBytes(&value));
            aliases_hash ^= hasher.final();
        }

        var deferred_hash: u64 = 0;
        var deferred_iter = self.deferred.iterator();
        while (deferred_iter.next()) |entry| {
            var hasher = std.hash.Wyhash.init(0);
            const key = ids.varIndex(entry.key_ptr.*);
            hasher.update(std.mem.asBytes(&key));
            const action = entry.value_ptr.*.action;
            hasher.update(std.mem.asBytes(&action));
            const has_scope: u8 = if (entry.value_ptr.*.scope_node) |_| 1 else 0;
            hasher.update(std.mem.asBytes(&has_scope));
            if (entry.value_ptr.*.scope_node) |scope| {
                hasher.update(std.mem.asBytes(&scope));
            }
            deferred_hash ^= hasher.final();
        }

        var errdeferred_hash: u64 = 0;
        var errdeferred_iter = self.errdeferred.iterator();
        while (errdeferred_iter.next()) |entry| {
            var hasher = std.hash.Wyhash.init(0);
            const key = ids.varIndex(entry.key_ptr.*);
            const action = entry.value_ptr.*.action;
            const call_token = entry.value_ptr.*.call_token;
            const scope_node = entry.value_ptr.*.scope_node;
            const has_call_token: u8 = if (call_token) |_| 1 else 0;
            const has_scope_node: u8 = if (scope_node) |_| 1 else 0;
            hasher.update(std.mem.asBytes(&key));
            hasher.update(std.mem.asBytes(&action));
            hasher.update(std.mem.asBytes(&has_call_token));
            if (call_token) |token| {
                hasher.update(std.mem.asBytes(&token));
            }
            hasher.update(std.mem.asBytes(&has_scope_node));
            if (scope_node) |scope| {
                hasher.update(std.mem.asBytes(&scope));
            }
            errdeferred_hash ^= hasher.final();
        }

        var owners_hash: u64 = 0;
        var owners_iter = self.owners.iterator();
        while (owners_iter.next()) |entry| {
            var hasher = std.hash.Wyhash.init(0);
            const key = ids.varIndex(entry.key_ptr.*);
            const value = ids.varIndex(entry.value_ptr.*);
            hasher.update(std.mem.asBytes(&key));
            hasher.update(std.mem.asBytes(&value));
            owners_hash ^= hasher.final();
        }

        var hasher = std.hash.Wyhash.init(0);
        const resources_count = self.resources.count();
        const violations_len = self.violations.items.len;
        hasher.update(std.mem.asBytes(&resources_hash));
        hasher.update(std.mem.asBytes(&violations_hash));
        hasher.update(std.mem.asBytes(&aliases_hash));
        hasher.update(std.mem.asBytes(&deferred_hash));
        hasher.update(std.mem.asBytes(&errdeferred_hash));
        hasher.update(std.mem.asBytes(&owners_hash));
        hasher.update(std.mem.asBytes(&resources_count));
        hasher.update(std.mem.asBytes(&violations_len));
        const aliases_count = self.aliases.count();
        const deferred_count = self.deferred.count();
        const errdeferred_count = self.errdeferred.count();
        const owners_count = self.owners.count();
        hasher.update(std.mem.asBytes(&aliases_count));
        hasher.update(std.mem.asBytes(&deferred_count));
        hasher.update(std.mem.asBytes(&errdeferred_count));
        hasher.update(std.mem.asBytes(&owners_count));

        return hasher.final();
    }

    pub fn getState(self: *const Store, region: VarId) ?ResourceState {
        const root = self.canonical(region);
        return self.resources.get(root);
    }

    pub fn recordOwnership(self: *Store, resource: VarId, container: VarId) !void {
        const resource_root = self.canonical(resource);
        const container_root = self.canonical(container);
        if (resource_root == container_root) return;
        try self.owners.put(resource_root, container_root);
    }

    fn removeOwnershipFor(self: *Store, region: VarId) void {
        const root = self.canonical(region);
        _ = self.owners.remove(root);

        var iter = self.owners.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == root) {
                self.owners.removeByPtr(entry.key_ptr);
            }
        }
    }

    pub fn escapeOwned(self: *Store, container: VarId) std.mem.Allocator.Error!void {
        const container_root = self.canonical(container);
        var to_escape: std.ArrayList(VarId) = .empty;
        defer to_escape.deinit(self.allocator);

        var iter = self.owners.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == container_root) {
                try to_escape.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (to_escape.items) |resource| {
            self.escapeRegion(resource);
        }
    }

    pub fn markAllocated(self: *Store, region: VarId) !void {
        _ = self.aliases.remove(region);
        _ = self.deferred.remove(region);
        _ = self.errdeferred.remove(region);
        self.removeOwnershipFor(region);
        try self.resources.put(region, .allocated);
    }

    pub fn markOpened(self: *Store, region: VarId) !void {
        _ = self.aliases.remove(region);
        _ = self.deferred.remove(region);
        _ = self.errdeferred.remove(region);
        self.removeOwnershipFor(region);
        try self.resources.put(region, .open);
    }

    pub fn markNonAllocated(self: *Store, region: VarId) !void {
        _ = self.aliases.remove(region);
        _ = self.deferred.remove(region);
        _ = self.errdeferred.remove(region);
        self.removeOwnershipFor(region);
        try self.resources.put(region, .non_allocated);
    }

    pub fn resetRegion(self: *Store, region: VarId) void {
        if (self.aliases.get(region)) |_| {
            _ = self.aliases.remove(region);
            return;
        }
        self.removeOwnershipFor(region);
        const root = self.canonical(region);
        var has_alias = false;
        var new_root: VarId = root;
        var iter = self.aliases.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == root) {
                if (!has_alias) {
                    has_alias = true;
                    new_root = entry.key_ptr.*;
                } else if (ids.varIndex(entry.key_ptr.*) < ids.varIndex(new_root)) {
                    new_root = entry.key_ptr.*;
                }
            }
        }

        if (!has_alias) {
            _ = self.resources.remove(root);
            _ = self.deferred.remove(root);
            _ = self.errdeferred.remove(root);
            return;
        }

        if (self.resources.get(root)) |state| {
            _ = self.resources.remove(root);
            _ = self.resources.remove(new_root);
            self.resources.put(new_root, state) catch {
                _ = self.resources.remove(new_root);
            };
        } else {
            _ = self.resources.remove(new_root);
        }

        if (self.deferred.get(root)) |action| {
            _ = self.deferred.remove(root);
            _ = self.deferred.remove(new_root);
            self.deferred.put(new_root, action) catch {
                _ = self.deferred.remove(new_root);
            };
        } else {
            _ = self.deferred.remove(new_root);
        }

        if (self.errdeferred.get(root)) |action| {
            _ = self.errdeferred.remove(root);
            _ = self.errdeferred.remove(new_root);
            self.errdeferred.put(new_root, action) catch {
                _ = self.errdeferred.remove(new_root);
            };
        } else {
            _ = self.errdeferred.remove(new_root);
        }

        var update_iter = self.aliases.iterator();
        while (update_iter.next()) |entry| {
            if (entry.value_ptr.* == root) {
                entry.value_ptr.* = new_root;
            }
        }
        _ = self.aliases.remove(new_root);
    }

    pub fn escapeRegion(self: *Store, region: VarId) void {
        const root = self.canonical(region);
        self.removeOwnershipFor(root);
        _ = self.resources.remove(root);
        _ = self.deferred.remove(root);
        _ = self.errdeferred.remove(root);
        _ = self.aliases.remove(region);
    }

    pub fn escapeByName(self: *Store, tree: *const std.zig.Ast, name: []const u8) std.mem.Allocator.Error!void {
        var to_remove: std.ArrayList(VarId) = .empty;
        defer to_remove.deinit(self.allocator);

        const token_tags = tree.tokens.items(.tag);
        var iter = self.resources.iterator();
        while (iter.next()) |entry| {
            const token = ids.varIndex(entry.key_ptr.*);
            if (token >= token_tags.len or token_tags[token] != .identifier) continue;
            if (std.mem.eql(u8, tree.tokenSlice(token), name)) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (to_remove.items) |key| {
            _ = self.resources.remove(key);
            _ = self.deferred.remove(key);
            _ = self.errdeferred.remove(key);
            _ = self.aliases.remove(key);
            self.removeOwnershipFor(key);
        }
    }

    pub fn markFreed(self: *Store, region: VarId, call_token: ?u32) !void {
        const root = self.canonical(region);
        if (self.deferred.get(root)) |entry| {
            if (entry.action == .free) {
                try self.recordViolation(root, .double_free, call_token);
            }
        }
        if (self.resources.get(root)) |state| {
            switch (state) {
                .freed => try self.recordViolation(root, .double_free, call_token),
                .non_allocated => try self.recordViolation(root, .free_without_alloc, call_token),
                .open, .closed => try self.recordViolation(root, .free_without_alloc, call_token),
                .allocated => {},
                else => {},
            }
            try self.resources.put(root, .freed);
        } else {
            try self.resources.put(root, .freed);
        }
        _ = self.deferred.remove(root);
        self.removeOwnershipFor(root);
    }

    pub fn markClosed(self: *Store, region: VarId, call_token: ?u32) !void {
        const root = self.canonical(region);
        if (self.deferred.get(root)) |entry| {
            if (entry.action == .close) {
                try self.recordViolation(root, .double_close, call_token);
            }
        }
        if (self.resources.get(root)) |state| {
            switch (state) {
                .closed => try self.recordViolation(root, .double_close, call_token),
                .open => {},
                .non_allocated, .allocated, .freed => try self.recordViolation(root, .close_without_open, call_token),
                else => {},
            }
            try self.resources.put(root, .closed);
        } else {
            try self.resources.put(root, .closed);
        }
        _ = self.deferred.remove(root);
        self.removeOwnershipFor(root);
    }

    pub fn markUsed(self: *Store, region: VarId, call_token: ?u32) !void {
        const root = self.canonical(region);
        if (self.resources.get(root)) |state| {
            switch (state) {
                .freed => try self.recordViolation(root, .use_after_free, call_token),
                .closed => try self.recordViolation(root, .use_after_close, call_token),
                else => {},
            }
        }
    }

    pub fn markFreeOwned(self: *Store, container: VarId, call_token: ?u32) !void {
        const container_root = self.canonical(container);
        var owned: std.ArrayList(VarId) = .empty;
        defer owned.deinit(self.allocator);

        var iter = self.owners.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == container_root) {
                try owned.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (owned.items) |resource| {
            try self.markFreed(resource, call_token);
        }
    }

    pub fn markDeferredFree(self: *Store, region: VarId, call_token: ?u32, scope_node: ?u32) !void {
        const root = self.canonical(region);
        if (self.deferred.get(root)) |entry| {
            if (entry.action == .free) {
                try self.recordViolation(root, .double_free, call_token);
            }
        }
        if (self.resources.get(root)) |state| {
            if (state == .non_allocated) {
                try self.recordViolation(root, .free_without_alloc, call_token);
            }
        }
        try self.deferred.put(root, .{ .action = .free, .scope_node = scope_node });
    }

    pub fn markDeferredFreeOwned(self: *Store, region: VarId, call_token: ?u32, scope_node: ?u32) !void {
        const root = self.canonical(region);
        if (self.deferred.get(root)) |entry| {
            if (entry.action == .free_owned) {
                try self.recordViolation(root, .double_free, call_token);
            }
        }
        try self.deferred.put(root, .{ .action = .free_owned, .scope_node = scope_node });
    }

    pub fn markDeferredClose(self: *Store, region: VarId, call_token: ?u32, scope_node: ?u32) !void {
        const root = self.canonical(region);
        if (self.deferred.get(root)) |entry| {
            if (entry.action == .close) {
                try self.recordViolation(root, .double_close, call_token);
            }
        }
        if (self.resources.get(root)) |state| {
            if (state != .open) {
                try self.recordViolation(root, .close_without_open, call_token);
            }
        }
        try self.deferred.put(root, .{ .action = .close, .scope_node = scope_node });
    }

    pub fn markErrdeferredFree(self: *Store, region: VarId, call_token: ?u32, scope_node: ?u32) !void {
        const root = self.canonical(region);
        if (self.errdeferred.get(root)) |action| {
            if (action.action == .free) {
                try self.recordViolation(root, .double_free, call_token);
            }
        }
        try self.errdeferred.put(root, .{ .action = .free, .call_token = call_token, .scope_node = scope_node });
    }

    pub fn markErrdeferredFreeOwned(self: *Store, region: VarId, call_token: ?u32, scope_node: ?u32) !void {
        const root = self.canonical(region);
        if (self.errdeferred.get(root)) |action| {
            if (action.action == .free_owned) {
                try self.recordViolation(root, .double_free, call_token);
            }
        }
        try self.errdeferred.put(root, .{ .action = .free_owned, .call_token = call_token, .scope_node = scope_node });
    }

    pub fn markErrdeferredClose(self: *Store, region: VarId, call_token: ?u32, scope_node: ?u32) !void {
        const root = self.canonical(region);
        if (self.errdeferred.get(root)) |action| {
            if (action.action == .close) {
                try self.recordViolation(root, .double_close, call_token);
            }
        }
        try self.errdeferred.put(root, .{ .action = .close, .call_token = call_token, .scope_node = scope_node });
    }

    pub fn applyErrdeferredReleases(self: *Store, return_node: u32, parent_map: []const u32) !void {
        var pending: std.ArrayList(struct {
            region: VarId,
            action: ErrdeferAction,
        }) = .empty;
        defer pending.deinit(self.allocator);

        var iter = self.errdeferred.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.scope_node) |scope_node| {
                if (!ast_walk.isAncestor(scope_node, return_node, parent_map)) {
                    continue;
                }
            }
            try pending.append(self.allocator, .{
                .region = entry.key_ptr.*,
                .action = entry.value_ptr.*,
            });
        }

        for (pending.items) |entry| {
            switch (entry.action.action) {
                .free => try self.markFreed(entry.region, entry.action.call_token),
                .free_owned => try self.markFreeOwned(entry.region, entry.action.call_token),
                .close => try self.markClosed(entry.region, entry.action.call_token),
            }
            _ = self.errdeferred.remove(entry.region);
        }
    }

    pub fn recordLeaks(self: *Store, error_path: bool) !void {
        var iter = self.resources.iterator();
        while (iter.next()) |entry| {
            switch (entry.value_ptr.*) {
                .allocated => {
                    if (self.deferred.get(entry.key_ptr.*)) |deferred_entry| {
                        if (deferred_entry.action == .free) continue;
                    }
                    if (self.ownerHasDeferredFreeOwned(entry.key_ptr.*, error_path)) {
                        continue;
                    }
                    if (error_path) {
                        if (self.errdeferred.get(entry.key_ptr.*)) |action| {
                            if (action.action == .free) continue;
                        }
                    }
                    try self.recordViolation(entry.key_ptr.*, .resource_leak, ids.varIndex(entry.key_ptr.*));
                },
                .open => {
                    if (self.deferred.get(entry.key_ptr.*)) |deferred_entry| {
                        if (deferred_entry.action == .close) continue;
                    }
                    if (self.ownerHasDeferredFreeOwned(entry.key_ptr.*, error_path)) {
                        continue;
                    }
                    if (error_path) {
                        if (self.errdeferred.get(entry.key_ptr.*)) |action| {
                            if (action.action == .close) continue;
                        }
                    }
                    try self.recordViolation(entry.key_ptr.*, .resource_leak, ids.varIndex(entry.key_ptr.*));
                },
                else => {},
            }
        }
    }

    fn ownerHasDeferredFreeOwned(self: *const Store, region: VarId, error_path: bool) bool {
        const root = self.canonical(region);
        const owner = self.owners.get(root) orelse return false;
        if (self.deferred.get(owner)) |entry| {
            if (entry.action == .free_owned) return true;
        }
        if (error_path) {
            if (self.errdeferred.get(owner)) |action| {
                if (action.action == .free_owned) return true;
            }
        }
        return false;
    }

    pub fn violationCount(self: *const Store) usize {
        return self.violations.items.len;
    }

    pub fn getViolations(self: *const Store) []const StoreViolation {
        return self.violations.items;
    }

    /// Return the AST node of the lexical scope owning the pending defer-free
    /// for `region`, if any is queued and the scope was recorded.
    pub fn pendingDeferredFreeScope(self: *const Store, region: VarId) ?u32 {
        const root = self.canonical(region);
        const entry = self.deferred.get(root) orelse return null;
        if (entry.action != .free and entry.action != .free_owned) return null;
        return entry.scope_node;
    }

    /// Record that `resource` was just appended into a container declared in a
    /// scope that outlives the defer-free queued on `resource`. The defer will
    /// fire at block exit, leaving the container holding a dangling slice.
    pub fn recordDeferFreesEscapee(self: *Store, resource: VarId, call_token: ?u32) !void {
        const root = self.canonical(resource);
        try self.recordViolation(root, .defer_frees_escapee, call_token);
    }

    fn recordViolation(self: *Store, region: VarId, kind: StoreViolationKind, call_token: ?u32) !void {
        const violation = StoreViolation{
            .region = region,
            .kind = kind,
            .call_token = call_token,
        };
        for (self.violations.items) |existing| {
            if (existing.eql(violation)) return;
        }
        try self.violations.append(self.allocator, violation);
    }

    fn canonical(self: *const Store, region: VarId) VarId {
        var current = region;
        var next_opt = self.aliases.get(current);
        while (next_opt) |next| : (next_opt = self.aliases.get(current)) {
            if (next == current) break;
            current = next;
        }
        return current;
    }

    pub fn aliasRegion(self: *Store, alias: VarId, target: VarId) !void {
        const root = self.canonical(target);
        try self.aliases.put(alias, root);
        _ = self.resources.remove(alias);
        _ = self.deferred.remove(alias);
        _ = self.errdeferred.remove(alias);
        _ = self.owners.remove(alias);
    }

    /// Widening operator for stores.
    /// Used at widening points to ensure convergence.
    /// - Resources: keep only if both agree, else set to `unknown`.
    /// - Aliases/owners/deferred/errdeferred: keep only if both agree, else drop.
    /// - Violations: union with dedup (never lose observed violations).
    pub fn widen(self: *const Store, other: *const Store, allocator: std.mem.Allocator) !Store {
        var result = Store.init(allocator);
        errdefer result.deinit();

        // Resources: keep if both agree, else set to unknown
        var self_res_iter = self.resources.iterator();
        while (self_res_iter.next()) |entry| {
            const region = entry.key_ptr.*;
            const self_state = entry.value_ptr.*;

            if (other.resources.get(region)) |other_state| {
                if (self_state == other_state) {
                    try result.resources.put(region, self_state);
                } else {
                    try result.resources.put(region, .unknown);
                }
            } else {
                // Region only in self: set to unknown
                try result.resources.put(region, .unknown);
            }
        }

        // Add resources only in other as unknown
        var other_res_iter = other.resources.iterator();
        while (other_res_iter.next()) |entry| {
            const region = entry.key_ptr.*;
            if (!self.resources.contains(region)) {
                try result.resources.put(region, .unknown);
            }
        }

        // Aliases: keep only if both agree
        var self_alias_iter = self.aliases.iterator();
        while (self_alias_iter.next()) |entry| {
            const alias = entry.key_ptr.*;
            const self_target = entry.value_ptr.*;

            if (other.aliases.get(alias)) |other_target| {
                if (self_target == other_target) {
                    try result.aliases.put(alias, self_target);
                }
            }
        }

        // Deferred: keep only if both agree
        var self_def_iter = self.deferred.iterator();
        while (self_def_iter.next()) |entry| {
            const region = entry.key_ptr.*;
            const self_entry = entry.value_ptr.*;

            if (other.deferred.get(region)) |other_entry| {
                if (deferredEntryEql(self_entry, other_entry)) {
                    try result.deferred.put(region, self_entry);
                }
            }
        }

        // Errdeferred: keep only if both agree
        var self_errdef_iter = self.errdeferred.iterator();
        while (self_errdef_iter.next()) |entry| {
            const region = entry.key_ptr.*;
            const self_action = entry.value_ptr.*;

            if (other.errdeferred.get(region)) |other_action| {
                if (errdeferActionEql(self_action, other_action)) {
                    try result.errdeferred.put(region, self_action);
                }
            }
        }

        // Owners: keep only if both agree
        var self_owners_iter = self.owners.iterator();
        while (self_owners_iter.next()) |entry| {
            const resource = entry.key_ptr.*;
            const self_owner = entry.value_ptr.*;

            if (other.owners.get(resource)) |other_owner| {
                if (self_owner == other_owner) {
                    try result.owners.put(resource, self_owner);
                }
            }
        }

        // Violations: union with dedup (never lose observed violations)
        for (self.violations.items) |violation| {
            var found = false;
            for (result.violations.items) |existing| {
                if (existing.eql(violation)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try result.violations.append(allocator, violation);
            }
        }

        for (other.violations.items) |violation| {
            var found = false;
            for (result.violations.items) |existing| {
                if (existing.eql(violation)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try result.violations.append(allocator, violation);
            }
        }

        return result;
    }

    /// Returns true if `self` is at least as general as `other`.
    /// Missing entries in `self` are treated as unknown/no-info.
    pub fn subsumes(self: *const Store, other: *const Store) bool {
        var res_iter = self.resources.iterator();
        while (res_iter.next()) |entry| {
            const region = entry.key_ptr.*;
            const self_state = entry.value_ptr.*;
            const other_state = other.resources.get(region) orelse .unknown;
            if (self_state != .unknown and self_state != other_state) return false;
        }

        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            const alias = entry.key_ptr.*;
            const self_target = entry.value_ptr.*;
            const other_target = other.aliases.get(alias) orelse return false;
            if (self_target != other_target) return false;
        }

        var deferred_iter = self.deferred.iterator();
        while (deferred_iter.next()) |entry| {
            const region = entry.key_ptr.*;
            const self_entry = entry.value_ptr.*;
            const other_entry = other.deferred.get(region) orelse return false;
            if (!deferredEntryEql(self_entry, other_entry)) return false;
        }

        var errdeferred_iter = self.errdeferred.iterator();
        while (errdeferred_iter.next()) |entry| {
            const region = entry.key_ptr.*;
            const self_action = entry.value_ptr.*;
            const other_action = other.errdeferred.get(region) orelse return false;
            if (!errdeferActionEql(self_action, other_action)) return false;
        }

        var owners_iter = self.owners.iterator();
        while (owners_iter.next()) |entry| {
            const resource = entry.key_ptr.*;
            const self_owner = entry.value_ptr.*;
            const other_owner = other.owners.get(resource) orelse return false;
            if (self_owner != other_owner) return false;
        }

        for (other.violations.items) |violation| {
            var found = false;
            for (self.violations.items) |existing| {
                if (existing.eql(violation)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        return true;
    }
};

test "Store tracks allocation/free transitions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(10);

    try store.markAllocated(region);
    try testing.expectEqual(ResourceState.allocated, store.getState(region).?);

    try store.markFreed(region, 1);
    try testing.expectEqual(ResourceState.freed, store.getState(region).?);
    try testing.expectEqual(@as(usize, 0), store.violationCount());
}

test "Store records double free violations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(11);

    try store.markAllocated(region);
    try store.markFreed(region, 1);
    try store.markFreed(region, 2);

    try testing.expectEqual(ResourceState.freed, store.getState(region).?);
    try testing.expectEqual(@as(usize, 1), store.violationCount());
    try testing.expectEqual(StoreViolationKind.double_free, store.getViolations()[0].kind);
}

test "Store records free without alloc violations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(13);

    try store.markNonAllocated(region);
    try store.markFreed(region, 1);

    try testing.expectEqual(ResourceState.freed, store.getState(region).?);
    try testing.expectEqual(@as(usize, 1), store.violationCount());
    try testing.expectEqual(StoreViolationKind.free_without_alloc, store.getViolations()[0].kind);
}

test "Store records close without open violations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(14);

    try store.markNonAllocated(region);
    try store.markClosed(region, 1);

    try testing.expectEqual(ResourceState.closed, store.getState(region).?);
    try testing.expectEqual(@as(usize, 1), store.violationCount());
    try testing.expectEqual(StoreViolationKind.close_without_open, store.getViolations()[0].kind);
}

test "Store records use after free violations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(15);

    try store.markAllocated(region);
    try store.markFreed(region, 1);
    try store.markUsed(region, 2);

    try testing.expectEqual(@as(usize, 1), store.violationCount());
    try testing.expectEqual(StoreViolationKind.use_after_free, store.getViolations()[0].kind);
}

test "Store preserves alias state when resetting root" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const root = ids.varId(21);
    const alias_a = ids.varId(22);
    const alias_b = ids.varId(23);

    try store.markAllocated(root);
    try store.aliasRegion(alias_a, root);
    try store.aliasRegion(alias_b, root);

    store.resetRegion(root);

    try testing.expectEqual(ResourceState.allocated, store.getState(alias_a).?);
    try testing.expectEqual(ResourceState.allocated, store.getState(alias_b).?);
    try testing.expect(store.getState(root) == null);
}

test "Store records leaks for allocated resources" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(16);

    try store.markAllocated(region);
    try store.recordLeaks(false);

    try testing.expectEqual(@as(usize, 1), store.violationCount());
    try testing.expectEqual(StoreViolationKind.resource_leak, store.getViolations()[0].kind);
}

test "Store hash accounts for repeated violations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    const region = ids.varId(12);

    try store.markAllocated(region);
    try store.markFreed(region, 1);
    try store.markFreed(region, 2);
    const hash_after_double = store.computeHash();

    try store.markFreed(region, 3);
    const hash_after_triple = store.computeHash();

    try testing.expect(hash_after_double != hash_after_triple);
}

test "Store widen resources agreement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store1 = Store.init(allocator);
    defer store1.deinit();

    var store2 = Store.init(allocator);
    defer store2.deinit();

    const region1 = ids.varId(30);
    const region2 = ids.varId(31);
    const region3 = ids.varId(32);

    // Same state in both
    try store1.markAllocated(region1);
    try store2.markAllocated(region1);

    // Different states
    try store1.markAllocated(region2);
    try store2.markFreed(region2, 1);

    // Only in store1
    try store1.markOpened(region3);

    var widened = try store1.widen(&store2, allocator);
    defer widened.deinit();

    // region1: both agree -> allocated
    try testing.expectEqual(ResourceState.allocated, widened.getState(region1).?);

    // region2: disagree -> unknown
    try testing.expectEqual(ResourceState.unknown, widened.getState(region2).?);

    // region3: only in store1 -> unknown
    try testing.expectEqual(ResourceState.unknown, widened.getState(region3).?);
}

test "Store widen violations union" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store1 = Store.init(allocator);
    defer store1.deinit();

    var store2 = Store.init(allocator);
    defer store2.deinit();

    const region1 = ids.varId(40);
    const region2 = ids.varId(41);

    // Violation in store1
    try store1.markAllocated(region1);
    try store1.markFreed(region1, 1);
    try store1.markFreed(region1, 2); // double_free

    // Different violation in store2
    try store2.markAllocated(region2);
    try store2.markFreed(region2, 3);
    try store2.markUsed(region2, 4); // use_after_free

    try testing.expectEqual(@as(usize, 1), store1.violationCount());
    try testing.expectEqual(@as(usize, 1), store2.violationCount());

    var widened = try store1.widen(&store2, allocator);
    defer widened.deinit();

    // Both violations should be present
    try testing.expectEqual(@as(usize, 2), widened.violationCount());
}

test "Store widen aliases keep only agreement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store1 = Store.init(allocator);
    defer store1.deinit();

    var store2 = Store.init(allocator);
    defer store2.deinit();

    const root1 = ids.varId(50);
    const root2 = ids.varId(51);
    const alias1 = ids.varId(52);
    const alias2 = ids.varId(53);

    // Same alias in both
    try store1.markAllocated(root1);
    try store2.markAllocated(root1);
    try store1.aliasRegion(alias1, root1);
    try store2.aliasRegion(alias1, root1);

    // Different alias targets
    try store1.markAllocated(root2);
    try store2.markAllocated(root2);
    try store1.aliasRegion(alias2, root1);
    try store2.aliasRegion(alias2, root2);

    var widened = try store1.widen(&store2, allocator);
    defer widened.deinit();

    // alias1 should be preserved (same target)
    try testing.expectEqual(root1, widened.aliases.get(alias1).?);

    // alias2 should be dropped (different targets)
    try testing.expect(widened.aliases.get(alias2) == null);
}

test "Store widen empty stores" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store1 = Store.init(allocator);
    defer store1.deinit();

    var store2 = Store.init(allocator);
    defer store2.deinit();

    var widened = try store1.widen(&store2, allocator);
    defer widened.deinit();

    try testing.expectEqual(@as(usize, 0), widened.resources.count());
    try testing.expectEqual(@as(usize, 0), widened.aliases.count());
    try testing.expectEqual(@as(usize, 0), widened.violationCount());
}

test "Store subsumes preserves violations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var general = Store.init(allocator);
    defer general.deinit();

    var specific = Store.init(allocator);
    defer specific.deinit();

    const region = ids.varId(99);
    try specific.markAllocated(region);

    try testing.expect(general.subsumes(&specific));

    try specific.markFreed(region, 1);
    try specific.markFreed(region, 2);

    try testing.expect(!general.subsumes(&specific));

    try general.markAllocated(region);
    try general.markFreed(region, 1);
    try general.markFreed(region, 2);

    try testing.expect(general.subsumes(&specific));
}
