const std = @import("std");
const log = std.log.scoped(.stack_escape_engine);
const checker_mod = @import("../checker.zig");
const Checker = checker_mod.Checker;
const CheckerError = checker_mod.CheckerError;
const Diagnostic = checker_mod.Diagnostic;
const Source = @import("../source.zig").Source;
const TypeContext = @import("../type_context.zig").TypeContext;
const Config = @import("../config.zig").Config;
const EscapeCapture = @import("../config.zig").EscapeCapture;
const ids = @import("../ids.zig");
const VarResolver = @import("../engine/var_resolver.zig").VarResolver;
const Cfg = @import("../cfg.zig").Cfg;
const EdgeKind = @import("../cfg.zig").EdgeKind;
const call_utils = @import("../analysis/call_utils.zig");
const allocator_utils = @import("../analysis/allocator_utils.zig");

const default_helper_depth: u32 = 3;

pub const StackEscapeEngineChecker = struct {
    pub const checker: Checker = .{
        .name = "stack-escape-engine",
        .default_severity = .err,
        .checkAstFn = checkAst,
    };

    const OriginKind = enum {
        unknown,
        stack,
        static,
        heap,
    };

    const Origin = struct {
        kind: OriginKind,
        token: ?u32,

        fn unknown() Origin {
            return .{ .kind = .unknown, .token = null };
        }
    };

    const OriginState = struct {
        allocator: std.mem.Allocator,
        origins: std.AutoHashMap(ids.VarId, Origin),

        fn init(allocator: std.mem.Allocator) OriginState {
            return .{
                .allocator = allocator,
                .origins = std.AutoHashMap(ids.VarId, Origin).init(allocator),
            };
        }

        fn deinit(self: *OriginState) void {
            self.origins.deinit();
        }

        fn clone(self: *const OriginState) !OriginState {
            var copy = OriginState.init(self.allocator);
            var iter = self.origins.iterator();
            while (iter.next()) |entry| {
                try copy.origins.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            return copy;
        }

        fn eql(self: *const OriginState, other: *const OriginState) bool {
            if (self.origins.count() != other.origins.count()) return false;
            var iter = self.origins.iterator();
            while (iter.next()) |entry| {
                const other_origin = other.origins.get(entry.key_ptr.*) orelse return false;
                if (!originEqual(entry.value_ptr.*, other_origin)) return false;
            }
            return true;
        }

        fn get(self: *const OriginState, var_id: ids.VarId) ?Origin {
            return self.origins.get(var_id);
        }

        fn set(self: *OriginState, var_id: ids.VarId, origin: Origin) !void {
            if (origin.kind == .unknown) {
                _ = self.origins.remove(var_id);
                return;
            }
            try self.origins.put(var_id, origin);
        }

        fn mergeWith(self: *OriginState, other: *const OriginState) !void {
            var to_remove: std.ArrayList(ids.VarId) = .empty;
            defer to_remove.deinit(self.allocator);

            var iter = self.origins.iterator();
            while (iter.next()) |entry| {
                const other_origin = other.origins.get(entry.key_ptr.*) orelse Origin.unknown();
                const merged = mergeOrigin(entry.value_ptr.*, other_origin);
                if (merged.kind == .unknown) {
                    try to_remove.append(self.allocator, entry.key_ptr.*);
                } else {
                    entry.value_ptr.* = merged;
                }
            }

            for (to_remove.items) |var_id| {
                _ = self.origins.remove(var_id);
            }

            var other_iter = other.origins.iterator();
            while (other_iter.next()) |entry| {
                if (self.origins.get(entry.key_ptr.*) != null) continue;
                const merged = mergeOrigin(Origin.unknown(), entry.value_ptr.*);
                if (merged.kind != .unknown) {
                    try self.origins.put(entry.key_ptr.*, merged);
                }
            }
        }
    };

    const CallInfo = call_utils.CallInfo;

    const EscapeMatch = struct {
        param_indices: []const u32,
        captures_into: EscapeCapture,
        is_thread_spawn: bool,
    };

    const AnalysisContext = struct {
        src: *Source,
        tree: *const std.zig.Ast,
        resolver: *VarResolver,
        type_ctx: ?*TypeContext,
        config: ?*const Config,
        helper_depth: u32,
        fqn_buffer: *[256]u8,
        comptime_params: ?*const std.AutoHashMap(ids.VarId, void),
    };

    fn checkAst(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        context: checker_mod.CheckerContext,
    ) CheckerError!void {
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);

        for (0..tags.len) |i| {
            if (tags[i] == .fn_decl) {
                try analyzeFunction(src, allocator, ids.astId(@intCast(i)), diagnostics, context);
            }
        }
    }

    fn analyzeFunction(
        src: *Source,
        allocator: std.mem.Allocator,
        fn_node: ids.AstNodeId,
        diagnostics: *std.ArrayList(Diagnostic),
        context: checker_mod.CheckerContext,
    ) CheckerError!void {
        var cfg_handle = (context.getOrBuildCfg(allocator, src, fn_node) catch return) orelse return;
        defer cfg_handle.deinit();

        const tree = src.ast() catch return;
        var resolver = VarResolver.init(allocator, tree, fn_node) catch return;
        defer resolver.deinit();

        var fqn_buffer: [256]u8 = undefined;
        var comptime_params = std.AutoHashMap(ids.VarId, void).init(allocator);
        defer comptime_params.deinit();
        try collectComptimeParams(tree, fn_node, &comptime_params);
        const helper_depth = if (context.config) |config|
            config.escape_max_depth orelse default_helper_depth
        else
            default_helper_depth;

        var analysis_ctx = AnalysisContext{
            .src = src,
            .tree = tree,
            .resolver = &resolver,
            .type_ctx = context.type_context,
            .config = context.config,
            .helper_depth = helper_depth,
            .fqn_buffer = &fqn_buffer,
            .comptime_params = &comptime_params,
        };

        var call_cfg_map = std.AutoHashMap(u32, ids.CfgNodeId).init(allocator);
        defer call_cfg_map.deinit();
        try buildCallCfgMap(cfg_handle.cfg, &call_cfg_map);

        var spawn_sites: std.ArrayList(SpawnSite) = .empty;
        defer spawn_sites.deinit(allocator);

        var spawn_seen = std.AutoHashMap(u32, usize).init(allocator);
        defer spawn_seen.deinit();

        var join_nodes = std.AutoHashMap(ids.VarId, std.ArrayList(ids.CfgNodeId)).init(allocator);
        defer deinitVarNodeMap(allocator, &join_nodes);

        var detach_nodes = std.AutoHashMap(ids.VarId, std.ArrayList(ids.CfgNodeId)).init(allocator);
        defer deinitVarNodeMap(allocator, &detach_nodes);

        var direct_join_spawns = std.AutoHashMap(u32, void).init(allocator);
        defer direct_join_spawns.deinit();

        var direct_detach_spawns = std.AutoHashMap(u32, void).init(allocator);
        defer direct_detach_spawns.deinit();

        try collectThreadCalls(
            &analysis_ctx,
            cfg_handle.cfg,
            &call_cfg_map,
            &spawn_sites,
            &spawn_seen,
            &join_nodes,
            &detach_nodes,
            &direct_join_spawns,
            &direct_detach_spawns,
        );

        var spawn_join_guaranteed = std.AutoHashMap(u32, bool).init(allocator);
        defer spawn_join_guaranteed.deinit();
        try computeJoinGuarantees(
            allocator,
            cfg_handle.cfg,
            spawn_sites.items,
            &join_nodes,
            &detach_nodes,
            &direct_join_spawns,
            &direct_detach_spawns,
            &spawn_join_guaranteed,
        );

        try runDataflow(
            allocator,
            &analysis_ctx,
            cfg_handle.cfg,
            &spawn_join_guaranteed,
            diagnostics,
        );
    }

    const SpawnSite = struct {
        call_node: u32,
        cfg_node: ids.CfgNodeId,
        thread_var: ?ids.VarId,
        has_try_error_edge: bool,
    };

    fn buildCallCfgMap(
        cfg: *const Cfg,
        map: *std.AutoHashMap(u32, ids.CfgNodeId),
    ) !void {
        for (cfg.nodes.items) |node| {
            if (node.ir_node.tag != .call) continue;
            if (node.ir_node.ast_node) |ast_node| {
                try map.put(ast_node, node.index);
            }
        }
    }

    fn deinitVarNodeMap(allocator: std.mem.Allocator, map: *std.AutoHashMap(ids.VarId, std.ArrayList(ids.CfgNodeId))) void {
        var iter = map.valueIterator();
        while (iter.next()) |list| {
            list.deinit(allocator);
        }
        map.deinit();
    }

    fn collectThreadCalls(
        ctx: *AnalysisContext,
        cfg: *const Cfg,
        call_cfg_map: *const std.AutoHashMap(u32, ids.CfgNodeId),
        spawn_sites: *std.ArrayList(SpawnSite),
        spawn_seen: *std.AutoHashMap(u32, usize),
        join_nodes: *std.AutoHashMap(ids.VarId, std.ArrayList(ids.CfgNodeId)),
        detach_nodes: *std.AutoHashMap(ids.VarId, std.ArrayList(ids.CfgNodeId)),
        direct_join_spawns: *std.AutoHashMap(u32, void),
        direct_detach_spawns: *std.AutoHashMap(u32, void),
    ) !void {
        for (cfg.nodes.items) |node| {
            const ast_node = node.ir_node.ast_node orelse continue;

            switch (node.ir_node.tag) {
                .var_decl => try handleVarDeclSpawn(ctx, ast_node, node.index, call_cfg_map, spawn_sites, spawn_seen),
                .assign => try handleAssignSpawn(ctx, node.ir_node, node.index, call_cfg_map, spawn_sites, spawn_seen),
                .call => {
                    if (isThreadSpawnCall(ctx, ast_node)) {
                        try appendSpawnSite(spawn_sites, spawn_seen, ast_node, node.index, null, false, ctx.resolver.allocator);
                    }
                    try handleThreadMethodCall(
                        ctx,
                        ast_node,
                        node.index,
                        join_nodes,
                        detach_nodes,
                        direct_join_spawns,
                        direct_detach_spawns,
                    );
                },
                .try_expr, .catch_expr => {
                    const call_node = unwrapCallNode(ctx.tree, ast_node) orelse continue;
                    if (isThreadSpawnCall(ctx, call_node)) {
                        const has_try_error_edge = node.ir_node.tag == .try_expr;
                        try appendSpawnSite(spawn_sites, spawn_seen, call_node, node.index, null, has_try_error_edge, ctx.resolver.allocator);
                    }
                    try handleThreadMethodCall(
                        ctx,
                        call_node,
                        node.index,
                        join_nodes,
                        detach_nodes,
                        direct_join_spawns,
                        direct_detach_spawns,
                    );
                },
                else => {},
            }
        }
    }

    fn handleVarDeclSpawn(
        ctx: *AnalysisContext,
        var_decl_node: u32,
        cfg_node: ids.CfgNodeId,
        call_cfg_map: *const std.AutoHashMap(u32, ids.CfgNodeId),
        spawn_sites: *std.ArrayList(SpawnSite),
        spawn_seen: *std.AutoHashMap(u32, usize),
    ) !void {
        const tree = ctx.tree;
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);

        if (var_decl_node >= tags.len) return;
        const full = tree.fullVarDecl(@enumFromInt(var_decl_node)) orelse return;
        const name_token = full.ast.mut_token + 1;
        if (name_token >= token_tags.len or token_tags[name_token] != .identifier) return;
        const var_id = ids.varId(name_token);

        const init_node = full.ast.init_node.unwrap() orelse return;
        const init_idx = @intFromEnum(init_node);
        const call_node = unwrapCallNode(tree, init_idx) orelse return;

        if (!isThreadSpawnCall(ctx, call_node)) return;
        const spawn_cfg = call_cfg_map.get(call_node) orelse cfg_node;

        const init_tag = tags[init_idx];
        const has_try_error_edge = init_tag == .@"try";
        try appendSpawnSite(spawn_sites, spawn_seen, call_node, spawn_cfg, var_id, has_try_error_edge, ctx.resolver.allocator);
    }

    fn handleAssignSpawn(
        ctx: *AnalysisContext,
        ir_node: @import("../ir.zig").IrNode,
        cfg_node: ids.CfgNodeId,
        call_cfg_map: *const std.AutoHashMap(u32, ids.CfgNodeId),
        spawn_sites: *std.ArrayList(SpawnSite),
        spawn_seen: *std.AutoHashMap(u32, usize),
    ) !void {
        const tree = ctx.tree;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        const ast_node = ir_node.ast_node orelse return;
        if (ast_node >= tags.len) return;
        if (tags[ast_node] != .assign) return;

        const pair = datas[ast_node].node_and_node;
        const lhs_node = @intFromEnum(pair[0]);
        const rhs_node = @intFromEnum(pair[1]);

        const call_node = unwrapCallNode(tree, rhs_node) orelse return;
        if (!isThreadSpawnCall(ctx, call_node)) return;

        const var_id = ctx.resolver.resolve(lhs_node) orelse return;
        const spawn_cfg = call_cfg_map.get(call_node) orelse cfg_node;

        const rhs_tag = tags[rhs_node];
        const has_try_error_edge = rhs_tag == .@"try";
        try appendSpawnSite(spawn_sites, spawn_seen, call_node, spawn_cfg, var_id, has_try_error_edge, ctx.resolver.allocator);
    }

    fn appendSpawnSite(
        spawn_sites: *std.ArrayList(SpawnSite),
        spawn_seen: *std.AutoHashMap(u32, usize),
        call_node: u32,
        cfg_node: ids.CfgNodeId,
        thread_var: ?ids.VarId,
        has_try_error_edge: bool,
        allocator: std.mem.Allocator,
    ) !void {
        if (spawn_seen.get(call_node)) |idx| {
            var site = &spawn_sites.items[idx];
            if (site.thread_var == null and thread_var != null) {
                site.thread_var = thread_var;
            }
            if (!site.has_try_error_edge and has_try_error_edge) {
                site.has_try_error_edge = true;
            }
            return;
        }
        const idx = spawn_sites.items.len;
        try spawn_seen.put(call_node, idx);
        try spawn_sites.append(allocator, .{
            .call_node = call_node,
            .cfg_node = cfg_node,
            .thread_var = thread_var,
            .has_try_error_edge = has_try_error_edge,
        });
    }

    fn handleThreadMethodCall(
        ctx: *AnalysisContext,
        call_node: u32,
        cfg_node: ids.CfgNodeId,
        join_nodes: *std.AutoHashMap(ids.VarId, std.ArrayList(ids.CfgNodeId)),
        detach_nodes: *std.AutoHashMap(ids.VarId, std.ArrayList(ids.CfgNodeId)),
        direct_join_spawns: *std.AutoHashMap(u32, void),
        direct_detach_spawns: *std.AutoHashMap(u32, void),
    ) !void {
        const tree = ctx.tree;
        const tags = tree.nodes.items(.tag);
        const method = threadMethod(tree, call_node) orelse return;
        const base_node = method.base_node;

        if (base_node < tags.len and tags[base_node] == .identifier) {
            const var_id = ctx.resolver.resolve(base_node) orelse return;
            if (method.kind == .join) {
                try appendVarNode(join_nodes, var_id, cfg_node, ctx.resolver.allocator);
            } else {
                try appendVarNode(detach_nodes, var_id, cfg_node, ctx.resolver.allocator);
            }
            return;
        }

        const base_call = unwrapCallNode(tree, base_node) orelse return;
        if (!isThreadSpawnCall(ctx, base_call)) return;
        if (method.kind == .join) {
            try direct_join_spawns.put(base_call, {});
        } else {
            try direct_detach_spawns.put(base_call, {});
        }
    }

    const ThreadMethod = struct {
        kind: enum { join, detach },
        base_node: u32,
    };

    fn threadMethod(tree: *const std.zig.Ast, call_node: u32) ?ThreadMethod {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const token_tags = tree.tokens.items(.tag);

        if (call_node >= tags.len) return null;
        if (!call_utils.isCallNode(tags[call_node])) return null;

        var call_buf: [1]std.zig.Ast.Node.Index = undefined;
        const full_call = tree.fullCall(&call_buf, @enumFromInt(call_node)) orelse return null;
        const callee_node: u32 = @intFromEnum(full_call.ast.fn_expr);
        if (callee_node >= tags.len) return null;
        if (tags[callee_node] != .field_access) return null;

        const field_access_data = datas[callee_node].node_and_token;
        const base_node = @intFromEnum(field_access_data[0]);
        const field_token = field_access_data[1];
        if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return null;
        const field_name = tree.tokenSlice(field_token);

        if (std.mem.eql(u8, field_name, "join")) {
            return .{ .kind = .join, .base_node = base_node };
        }
        if (std.mem.eql(u8, field_name, "detach")) {
            return .{ .kind = .detach, .base_node = base_node };
        }
        return null;
    }

    fn spawnCallFromThreadMethod(ctx: *AnalysisContext, call_node: u32) ?u32 {
        const method = threadMethod(ctx.tree, call_node) orelse return null;
        const base_call = unwrapCallNode(ctx.tree, method.base_node) orelse return null;
        if (!isThreadSpawnCall(ctx, base_call)) return null;
        return base_call;
    }

    fn appendVarNode(
        map: *std.AutoHashMap(ids.VarId, std.ArrayList(ids.CfgNodeId)),
        var_id: ids.VarId,
        node: ids.CfgNodeId,
        allocator: std.mem.Allocator,
    ) !void {
        if (map.getPtr(var_id)) |list| {
            try list.append(allocator, node);
            return;
        }
        var list: std.ArrayList(ids.CfgNodeId) = .empty;
        try list.append(allocator, node);
        try map.put(var_id, list);
    }

    fn computeJoinGuarantees(
        allocator: std.mem.Allocator,
        cfg: *const Cfg,
        spawn_sites: []const SpawnSite,
        join_nodes: *std.AutoHashMap(ids.VarId, std.ArrayList(ids.CfgNodeId)),
        detach_nodes: *std.AutoHashMap(ids.VarId, std.ArrayList(ids.CfgNodeId)),
        direct_join_spawns: *std.AutoHashMap(u32, void),
        direct_detach_spawns: *std.AutoHashMap(u32, void),
        results: *std.AutoHashMap(u32, bool),
    ) !void {
        var succs = try buildSuccessorLists(allocator, cfg);
        defer deinitEdgeLists(allocator, &succs);

        for (spawn_sites) |site| {
            var guaranteed = false;
            if (direct_detach_spawns.get(site.call_node) != null) {
                guaranteed = false;
            } else if (direct_join_spawns.get(site.call_node) != null) {
                guaranteed = true;
            } else if (site.thread_var) |var_id| {
                if (detach_nodes.get(var_id) == null) {
                    if (join_nodes.get(var_id)) |list| {
                        guaranteed = isJoinGuaranteed(
                            allocator,
                            cfg,
                            succs.items,
                            site.cfg_node,
                            list.items,
                            site.has_try_error_edge,
                        );
                    }
                }
            }
            try results.put(site.call_node, guaranteed);
        }

        var join_iter = direct_join_spawns.keyIterator();
        while (join_iter.next()) |call_node| {
            if (results.get(call_node.*) == null) {
                try results.put(call_node.*, true);
            }
        }

        var detach_iter = direct_detach_spawns.keyIterator();
        while (detach_iter.next()) |call_node| {
            try results.put(call_node.*, false);
        }
    }

    fn runDataflow(
        allocator: std.mem.Allocator,
        ctx: *AnalysisContext,
        cfg: *const Cfg,
        spawn_join_guaranteed: *const std.AutoHashMap(u32, bool),
        diagnostics: *std.ArrayList(Diagnostic),
    ) CheckerError!void {
        const node_count = cfg.nodeCount();
        var out_states = try allocator.alloc(OriginState, node_count);
        defer {
            for (out_states) |*state| {
                state.deinit();
            }
            allocator.free(out_states);
        }

        for (out_states) |*state| {
            state.* = OriginState.init(allocator);
        }

        var succs = try buildSuccessorLists(allocator, cfg);
        defer deinitEdgeLists(allocator, &succs);

        var preds = try buildPredecessorLists(allocator, cfg);
        defer deinitNodeLists(allocator, &preds);

        var worklist: std.ArrayList(ids.CfgNodeId) = .empty;
        defer worklist.deinit(allocator);
        for (cfg.nodes.items) |node| {
            try worklist.append(allocator, node.index);
        }

        var reported: std.AutoHashMap(u64, void) = std.AutoHashMap(u64, void).init(allocator);
        defer reported.deinit();

        while (worklist.items.len > 0) {
            const node_id = worklist.pop() orelse break;
            const idx: usize = @intCast(ids.cfgIndex(node_id));

            var in_state = try mergePredStates(allocator, preds.items[idx].items, out_states);
            defer in_state.deinit();

            var new_out = try in_state.clone();
            defer new_out.deinit();

            const node = cfg.getNode(node_id) orelse continue;
            try applyTransfer(
                allocator,
                ctx,
                node,
                &in_state,
                &new_out,
                spawn_join_guaranteed,
                diagnostics,
                &reported,
            );

            if (!new_out.eql(&out_states[idx])) {
                out_states[idx].deinit();
                out_states[idx] = try new_out.clone();
                for (succs.items[idx].items) |succ| {
                    try worklist.append(allocator, succ.to);
                }
            }
        }
    }

    fn mergePredStates(
        allocator: std.mem.Allocator,
        pred_nodes: []const ids.CfgNodeId,
        out_states: []OriginState,
    ) !OriginState {
        if (pred_nodes.len == 0) {
            return OriginState.init(allocator);
        }
        const first_idx: usize = @intCast(ids.cfgIndex(pred_nodes[0]));
        var merged = try out_states[first_idx].clone();
        for (pred_nodes[1..]) |pred| {
            const idx: usize = @intCast(ids.cfgIndex(pred));
            try merged.mergeWith(&out_states[idx]);
        }
        return merged;
    }

    fn applyTransfer(
        allocator: std.mem.Allocator,
        ctx: *AnalysisContext,
        node: *const @import("../cfg.zig").CfgNode,
        in_state: *const OriginState,
        out_state: *OriginState,
        spawn_join_guaranteed: *const std.AutoHashMap(u32, bool),
        diagnostics: *std.ArrayList(Diagnostic),
        reported: *std.AutoHashMap(u64, void),
    ) CheckerError!void {
        const ir_node = node.ir_node;
        const ast_node = ir_node.ast_node orelse return;
        const tree = ctx.tree;
        const datas = tree.nodes.items(.data);

        switch (ir_node.tag) {
            .var_decl => {
                const full = tree.fullVarDecl(@enumFromInt(ast_node)) orelse return;
                const init_node = full.ast.init_node.unwrap() orelse return;
                const init_idx = @intFromEnum(init_node);
                const name_token = full.ast.mut_token + 1;
                const token_tags = tree.tokens.items(.tag);
                if (name_token >= token_tags.len or token_tags[name_token] != .identifier) return;
                const var_id = ids.varId(name_token);
                const origin = originOfExpr(ctx, in_state, init_idx, ctx.helper_depth);
                try out_state.set(var_id, origin);
            },
            .assign => {
                const pair = datas[ast_node].node_and_node;
                const lhs_node = @intFromEnum(pair[0]);
                const rhs_node = @intFromEnum(pair[1]);
                const var_id = ctx.resolver.resolve(lhs_node) orelse return;
                const origin = originOfExpr(ctx, in_state, rhs_node, ctx.helper_depth);
                try out_state.set(var_id, origin);
            },
            .call => {
                try checkCallEscapes(
                    allocator,
                    ctx,
                    ast_node,
                    in_state,
                    spawn_join_guaranteed,
                    diagnostics,
                    reported,
                );
                if (spawnCallFromThreadMethod(ctx, ast_node)) |spawn_call| {
                    try checkCallEscapes(
                        allocator,
                        ctx,
                        spawn_call,
                        in_state,
                        spawn_join_guaranteed,
                        diagnostics,
                        reported,
                    );
                }
            },
            .try_expr, .catch_expr => {
                if (unwrapCallNode(tree, ast_node)) |call_node| {
                    try checkCallEscapes(
                        allocator,
                        ctx,
                        call_node,
                        in_state,
                        spawn_join_guaranteed,
                        diagnostics,
                        reported,
                    );
                    if (spawnCallFromThreadMethod(ctx, call_node)) |spawn_call| {
                        try checkCallEscapes(
                            allocator,
                            ctx,
                            spawn_call,
                            in_state,
                            spawn_join_guaranteed,
                            diagnostics,
                            reported,
                        );
                    }
                }
            },
            .ret => {
                try checkReturnEscape(
                    allocator,
                    ctx,
                    ast_node,
                    in_state,
                    diagnostics,
                    reported,
                );
            },
            else => {},
        }
    }

    fn checkCallEscapes(
        allocator: std.mem.Allocator,
        ctx: *AnalysisContext,
        call_node: u32,
        state: *const OriginState,
        spawn_join_guaranteed: *const std.AutoHashMap(u32, bool),
        diagnostics: *std.ArrayList(Diagnostic),
        reported: *std.AutoHashMap(u64, void),
    ) CheckerError!void {
        const call_info = resolveCallInfo(ctx, call_node) orelse return;
        const match = resolveEscapeMatch(ctx, call_info) orelse return;

        if (match.captures_into == .@"return") {
            return;
        }

        for (match.param_indices) |param_index| {
            const param_node = call_utils.callParam(ctx.tree, call_info.call_node, @intCast(param_index)) orelse continue;
            const origin = originOfExpr(ctx, state, param_node, ctx.helper_depth);
            if (origin.kind != .stack) continue;

            if (match.captures_into == .thread and match.is_thread_spawn) {
                if (spawn_join_guaranteed.get(call_node)) |guaranteed| {
                    if (guaranteed) continue;
                }
            }

            const origin_token = origin.token orelse treeMainToken(ctx.tree, param_node);
            const report_key = reportKey(call_node, origin_token);
            if (reported.get(report_key) != null) continue;
            try reported.put(report_key, {});

            try emitStackEscapeDiagnostic(
                allocator,
                ctx,
                call_node,
                origin_token,
                match.captures_into,
                diagnostics,
            );
        }
    }

    fn checkReturnEscape(
        allocator: std.mem.Allocator,
        ctx: *AnalysisContext,
        ret_node: u32,
        state: *const OriginState,
        diagnostics: *std.ArrayList(Diagnostic),
        reported: *std.AutoHashMap(u64, void),
    ) CheckerError!void {
        const tree = ctx.tree;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (ret_node >= tags.len) return;
        if (tags[ret_node] != .@"return") return;

        const expr_opt = datas[ret_node].opt_node.unwrap() orelse return;
        const expr_node = @intFromEnum(expr_opt);
        const origin = originOfExpr(ctx, state, expr_node, ctx.helper_depth);
        if (origin.kind != .stack) return;

        const origin_token = origin.token orelse treeMainToken(tree, expr_node);
        const report_key = reportKey(ret_node, origin_token);
        if (reported.get(report_key) != null) return;
        try reported.put(report_key, {});

        try emitStackEscapeDiagnostic(
            allocator,
            ctx,
            ret_node,
            origin_token,
            .@"return",
            diagnostics,
        );
    }

    fn emitStackEscapeDiagnostic(
        allocator: std.mem.Allocator,
        ctx: *AnalysisContext,
        capture_node: u32,
        origin_token: u32,
        capture_kind: EscapeCapture,
        diagnostics: *std.ArrayList(Diagnostic),
    ) CheckerError!void {
        const tree = ctx.tree;
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);
        if (capture_node >= main_tokens.len) return;
        const capture_token = main_tokens[capture_node];
        if (capture_token >= token_tags.len) return;

        const capture_loc = ctx.src.tokenLocation(capture_token) catch |err| {
            log.warn("failed to map capture location: {}", .{err});
            return;
        };

        var related_range: ?checker_mod.SourceRange = null;
        var origin_line: usize = 1;
        var origin_col: usize = 1;
        const origin_loc = ctx.src.tokenLocation(origin_token) catch |err| {
            log.warn("failed to map origin location: {}", .{err});
            return;
        };
        origin_line = origin_loc.line;
        origin_col = origin_loc.column;
        related_range = checker_mod.SourceRange.fromSingleLocation(origin_loc);

        const capture_desc = captureDescription(capture_kind);
        const message = try std.fmt.allocPrint(
            allocator,
            "Stack-backed value escapes via {s}, origin at {d}:{d}.",
            .{ capture_desc, origin_line, origin_col },
        );
        defer allocator.free(message);

        const diag = try Diagnostic.initAtLocationWithRelated(
            allocator,
            ctx.src.getFilePath(),
            "stack-escape-engine",
            .err,
            message,
            capture_loc.line,
            capture_loc.column,
            related_range,
        );
        try diagnostics.append(allocator, diag);
    }

    fn captureDescription(kind: EscapeCapture) []const u8 {
        return switch (kind) {
            .@"return" => "return value",
            .receiver => "receiver",
            .global => "global",
            .thread => "thread",
        };
    }

    fn resolveEscapeMatch(ctx: *AnalysisContext, call_info: CallInfo) ?EscapeMatch {
        const is_thread_spawn = isThreadSpawnFqn(call_info.fqn);
        if (ctx.config) |config| {
            if (config.matchEscapeModel(call_info.method_name, call_info.receiver_type, call_info.fqn)) |model| {
                return .{
                    .param_indices = model.param_indices,
                    .captures_into = model.captures_into,
                    .is_thread_spawn = is_thread_spawn,
                };
            }
        }

        if (call_info.fqn) |fqn| {
            if (std.mem.eql(u8, fqn, "std.process.Child.init")) {
                return .{ .param_indices = &.{0}, .captures_into = .@"return", .is_thread_spawn = false };
            }
            if (is_thread_spawn) {
                return .{ .param_indices = &.{2}, .captures_into = .thread, .is_thread_spawn = true };
            }
        }

        return null;
    }

    fn resolveCallInfo(ctx: *AnalysisContext, call_node: u32) ?CallInfo {
        return call_utils.resolveCall(ctx.tree, ctx.type_ctx, call_node, ctx.fqn_buffer);
    }

    fn isThreadSpawnCall(ctx: *AnalysisContext, call_node: u32) bool {
        const call_info = resolveCallInfo(ctx, call_node) orelse return false;
        return isThreadSpawnFqn(call_info.fqn);
    }

    fn isThreadSpawnFqn(fqn: ?[]const u8) bool {
        if (fqn) |name| {
            return std.mem.eql(u8, name, "std.Thread.spawn");
        }
        return false;
    }

    fn unwrapCallNode(tree: *const std.zig.Ast, expr_node: u32) ?u32 {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (expr_node >= tags.len) return null;
        return switch (tags[expr_node]) {
            .call, .call_comma, .call_one, .call_one_comma => expr_node,
            .@"try" => unwrapCallNode(tree, @intFromEnum(datas[expr_node].node)),
            .@"catch" => blk: {
                const pair = datas[expr_node].node_and_node;
                if (unwrapCallNode(tree, @intFromEnum(pair[0]))) |call_node| {
                    break :blk call_node;
                }
                break :blk unwrapCallNode(tree, @intFromEnum(pair[1]));
            },
            .grouped_expression, .unwrap_optional => unwrapCallNode(tree, @intFromEnum(datas[expr_node].node_and_token[0])),
            else => null,
        };
    }

    fn originOfExpr(ctx: *AnalysisContext, state: *const OriginState, expr_node: u32, depth: u32) Origin {
        const tree = ctx.tree;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (expr_node >= tags.len) return Origin.unknown();

        switch (tags[expr_node]) {
            .identifier => return originFromIdentifier(ctx, state, expr_node),
            .number_literal,
            .char_literal,
            .string_literal,
            .multiline_string_literal,
            .enum_literal,
            .error_value,
            => return .{ .kind = .static, .token = treeMainToken(tree, expr_node) },
            .address_of => {
                const child = @intFromEnum(datas[expr_node].node);
                return originFromAddressOf(ctx, state, expr_node, child, depth);
            },
            .array_init,
            .array_init_comma,
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            .struct_init,
            .struct_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            => return originFromAggregate(ctx, state, expr_node, depth),
            .grouped_expression, .unwrap_optional => {
                const child = @intFromEnum(datas[expr_node].node_and_token[0]);
                return originOfExpr(ctx, state, child, depth);
            },
            .slice, .slice_open, .slice_sentinel => {
                const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse return Origin.unknown();
                return originOfExpr(ctx, state, @intFromEnum(slice.ast.sliced), depth);
            },
            .array_access => {
                const pair = datas[expr_node].node_and_node;
                return originOfExpr(ctx, state, @intFromEnum(pair[0]), depth);
            },
            .field_access => return originFromFieldAccess(ctx, state, expr_node, depth),
            .@"try" => return originOfExpr(ctx, state, @intFromEnum(datas[expr_node].node), depth),
            .@"catch" => {
                const pair = datas[expr_node].node_and_node;
                const left = originOfExpr(ctx, state, @intFromEnum(pair[0]), depth);
                const right = originOfExpr(ctx, state, @intFromEnum(pair[1]), depth);
                return mergeOrigin(left, right);
            },
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                if (builtinCallName(tree, tags, expr_node)) |name| {
                    if (std.mem.eql(u8, name, "@as")) {
                        var buf: [2]std.zig.Ast.Node.Index = undefined;
                        const params = tree.builtinCallParams(&buf, @enumFromInt(expr_node)) orelse return Origin.unknown();
                        if (params.len < 2) return Origin.unknown();
                        return originOfExpr(ctx, state, @intFromEnum(params[1]), depth);
                    }
                    if (std.mem.eql(u8, name, "@ptrCast")) {
                        var buf: [2]std.zig.Ast.Node.Index = undefined;
                        const params = tree.builtinCallParams(&buf, @enumFromInt(expr_node)) orelse return Origin.unknown();
                        if (params.len < 1) return Origin.unknown();
                        return originOfExpr(ctx, state, @intFromEnum(params[0]), depth);
                    }
                }
                return Origin.unknown();
            },
            .call, .call_comma, .call_one, .call_one_comma => return originFromCall(ctx, state, expr_node, depth),
            .@"switch", .switch_comma => return originFromSwitch(ctx, state, expr_node, depth),
            else => return Origin.unknown(),
        }
    }

    fn originFromIdentifier(ctx: *AnalysisContext, state: *const OriginState, ident_node: u32) Origin {
        // Local array values live on the stack even when initialized from comptime literals.
        if (localArrayOriginToken(ctx, ident_node)) |origin_token| {
            return .{ .kind = .stack, .token = origin_token };
        }

        if (ctx.resolver.resolve(ident_node)) |var_id| {
            if (state.get(var_id)) |origin| return origin;
        }

        if (isComptimeIdentifier(ctx, ident_node)) {
            return .{ .kind = .static, .token = treeMainToken(ctx.tree, ident_node) };
        }

        return Origin.unknown();
    }

    fn originFromAddressOf(
        ctx: *AnalysisContext,
        state: *const OriginState,
        address_node: u32,
        child_node: u32,
        depth: u32,
    ) Origin {
        const tree = ctx.tree;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (child_node >= tags.len) return Origin.unknown();
        switch (tags[child_node]) {
            .array_init,
            .array_init_comma,
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            => {
                if (isComptimeArrayLiteral(ctx, child_node)) {
                    return .{ .kind = .static, .token = treeMainToken(tree, address_node) };
                }
                return .{ .kind = .stack, .token = treeMainToken(tree, address_node) };
            },
            .struct_init,
            .struct_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            => {
                if (isComptimeStructLiteral(ctx, child_node)) {
                    return .{ .kind = .static, .token = treeMainToken(tree, address_node) };
                }
                return .{ .kind = .stack, .token = treeMainToken(tree, address_node) };
            },
            .identifier => {
                if (isTopLevelConst(ctx, child_node)) {
                    return .{ .kind = .static, .token = treeMainToken(tree, address_node) };
                }
                if (isLocalDecl(ctx, child_node)) {
                    return .{ .kind = .stack, .token = treeMainToken(tree, address_node) };
                }
                return Origin.unknown();
            },
            .field_access => {
                const base_node = @intFromEnum(datas[child_node].node_and_token[0]);
                if (isTopLevelConst(ctx, base_node)) {
                    return .{ .kind = .static, .token = treeMainToken(tree, address_node) };
                }
                if (isLocalDecl(ctx, base_node)) {
                    return .{ .kind = .stack, .token = treeMainToken(tree, address_node) };
                }
                const base_origin = originOfExpr(ctx, state, base_node, depth);
                return switch (base_origin.kind) {
                    .stack => .{ .kind = .stack, .token = treeMainToken(tree, address_node) },
                    .static => .{ .kind = .static, .token = treeMainToken(tree, address_node) },
                    else => Origin.unknown(),
                };
            },
            .array_access => {
                const pair = datas[child_node].node_and_node;
                const base_node = @intFromEnum(pair[0]);
                if (isTopLevelConst(ctx, base_node)) {
                    return .{ .kind = .static, .token = treeMainToken(tree, address_node) };
                }
                if (isLocalDecl(ctx, base_node)) {
                    return .{ .kind = .stack, .token = treeMainToken(tree, address_node) };
                }
                const base_origin = originOfExpr(ctx, state, base_node, depth);
                return switch (base_origin.kind) {
                    .stack => .{ .kind = .stack, .token = treeMainToken(tree, address_node) },
                    .static => .{ .kind = .static, .token = treeMainToken(tree, address_node) },
                    else => Origin.unknown(),
                };
            },
            else => {
                const inner_origin = originOfExpr(ctx, state, child_node, depth);
                return switch (inner_origin.kind) {
                    .static => .{ .kind = .static, .token = treeMainToken(tree, address_node) },
                    .stack => .{ .kind = .stack, .token = treeMainToken(tree, address_node) },
                    else => Origin.unknown(),
                };
            },
        }
    }

    fn originFromAggregate(ctx: *AnalysisContext, state: *const OriginState, expr_node: u32, depth: u32) Origin {
        const tree = ctx.tree;
        const tags = tree.nodes.items(.tag);

        if (expr_node >= tags.len) return Origin.unknown();
        switch (tags[expr_node]) {
            .struct_init,
            .struct_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            => return originFromStructInit(ctx, state, expr_node, depth),
            .array_init,
            .array_init_comma,
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            => return originFromArrayInit(ctx, state, expr_node, depth),
            else => return Origin.unknown(),
        }
    }

    fn originFromStructInit(ctx: *AnalysisContext, state: *const OriginState, expr_node: u32, depth: u32) Origin {
        const tree = ctx.tree;
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = tree.fullStructInit(&buf, @enumFromInt(expr_node)) orelse return Origin.unknown();

        var combined = Origin.unknown();
        var has_any = false;
        for (struct_init.ast.fields) |field_node| {
            const field = tree.fullContainerField(field_node) orelse continue;
            if (field.ast.value_expr.unwrap()) |value_expr| {
                const origin = originOfExpr(ctx, state, @intFromEnum(value_expr), depth);
                combined = if (!has_any) origin else mergeOrigin(combined, origin);
                has_any = true;
            } else if (field.ast.tuple_like) {
                if (field.ast.type_expr.unwrap()) |value_expr| {
                    const origin = originOfExpr(ctx, state, @intFromEnum(value_expr), depth);
                    combined = if (!has_any) origin else mergeOrigin(combined, origin);
                    has_any = true;
                }
            }
        }

        return if (has_any) combined else Origin.unknown();
    }

    fn originFromArrayInit(ctx: *AnalysisContext, state: *const OriginState, expr_node: u32, depth: u32) Origin {
        const tree = ctx.tree;
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const array_init = tree.fullArrayInit(&buf, @enumFromInt(expr_node)) orelse return Origin.unknown();

        var combined = Origin.unknown();
        var has_any = false;
        for (array_init.ast.elements) |elem| {
            const origin = originOfExpr(ctx, state, @intFromEnum(elem), depth);
            combined = if (!has_any) origin else mergeOrigin(combined, origin);
            has_any = true;
        }

        return if (has_any) combined else Origin.unknown();
    }

    fn originFromSwitch(ctx: *AnalysisContext, state: *const OriginState, expr_node: u32, depth: u32) Origin {
        const tree = ctx.tree;
        const full_switch = tree.switchFull(@enumFromInt(expr_node));

        var combined = Origin.unknown();
        var has_any = false;
        for (full_switch.ast.cases) |case_node| {
            const full_case = tree.fullSwitchCase(case_node) orelse continue;
            const origin = originOfExpr(ctx, state, @intFromEnum(full_case.ast.target_expr), depth);
            combined = if (!has_any) origin else mergeOrigin(combined, origin);
            has_any = true;
        }

        return if (has_any) combined else Origin.unknown();
    }

    fn originFromCall(ctx: *AnalysisContext, state: *const OriginState, call_node: u32, depth: u32) Origin {
        const call_info = resolveCallInfo(ctx, call_node) orelse return Origin.unknown();
        const match = resolveEscapeMatch(ctx, call_info);
        if (match) |escape| {
            if (escape.captures_into == .@"return") {
                return originFromCapturedArgs(ctx, state, call_info, escape.param_indices, depth);
            }
        }

        if (isHeapAllocCall(ctx, call_info)) {
            return .{ .kind = .heap, .token = treeMainToken(ctx.tree, call_node) };
        }

        if (depth > 0) {
            if (resolveHelperReturnParamIndex(ctx, call_info)) |param_index| {
                if (call_utils.callParam(ctx.tree, call_info.call_node, @intCast(param_index))) |arg_node| {
                    return originOfExpr(ctx, state, arg_node, depth - 1);
                }
            }
        }

        return Origin.unknown();
    }

    fn originFromCapturedArgs(
        ctx: *AnalysisContext,
        state: *const OriginState,
        call_info: CallInfo,
        param_indices: []const u32,
        depth: u32,
    ) Origin {
        var combined = Origin.unknown();
        var has_any = false;
        for (param_indices) |param_index| {
            const arg_node = call_utils.callParam(ctx.tree, call_info.call_node, @intCast(param_index)) orelse continue;
            const origin = originOfExpr(ctx, state, arg_node, depth);
            combined = if (!has_any) origin else mergeOrigin(combined, origin);
            has_any = true;
        }
        return if (has_any) combined else Origin.unknown();
    }

    fn originFromFieldAccess(ctx: *AnalysisContext, state: *const OriginState, expr_node: u32, depth: u32) Origin {
        const tree = ctx.tree;
        const datas = tree.nodes.items(.data);
        const token_tags = tree.tokens.items(.tag);
        const base_node = @intFromEnum(datas[expr_node].node_and_token[0]);
        const field_token = datas[expr_node].node_and_token[1];

        // Local struct fields storing arrays still live on the stack.
        if (isLocalDecl(ctx, base_node)) {
            if (ctx.type_ctx) |type_ctx| {
                if (type_ctx.getExpressionType(expr_node)) |info| {
                    if (info.kind == .array) {
                        return .{ .kind = .stack, .token = treeMainToken(tree, expr_node) };
                    }
                    if (info.type_str) |type_str| {
                        if (isArrayValueTypeName(type_str)) {
                            return .{ .kind = .stack, .token = treeMainToken(tree, expr_node) };
                        }
                    }
                }
            }
        }

        if (field_token < token_tags.len and token_tags[field_token] == .identifier) {
            const field_name = tree.tokenSlice(field_token);
            if (localStructFieldArrayOrigin(ctx, base_node, field_name)) |origin| {
                return origin;
            }
        }

        return originOfExpr(ctx, state, base_node, depth);
    }

    fn resolveHelperReturnParamIndex(ctx: *AnalysisContext, call_info: CallInfo) ?u32 {
        const tree = ctx.tree;
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);

        const callee = getCallCalleeNode(ctx.tree, call_info.call_node) orelse return null;
        if (tags[callee] != .identifier) return null;
        const token = tree.nodes.items(.main_token)[callee];
        if (token >= token_tags.len or token_tags[token] != .identifier) return null;
        const name = tree.tokenSlice(token);

        const decl = ctx.src.findDecl(name) orelse return null;
        if (!decl.is_fn) return null;
        const fn_ast = decl.ast_node orelse return null;

        const return_expr = getSingleReturnExpr(tree, fn_ast) orelse return null;
        const param_name = resolveParamNameFromExpr(tree, return_expr) orelse return null;
        return findParamIndex(tree, fn_ast, param_name);
    }

    fn getCallCalleeNode(tree: *const std.zig.Ast, call_node: u32) ?u32 {
        const tags = tree.nodes.items(.tag);
        if (call_node >= tags.len) return null;
        if (!call_utils.isCallNode(tags[call_node])) return null;
        var call_buf: [1]std.zig.Ast.Node.Index = undefined;
        const full_call = tree.fullCall(&call_buf, @enumFromInt(call_node)) orelse return null;
        return @intFromEnum(full_call.ast.fn_expr);
    }

    fn getSingleReturnExpr(tree: *const std.zig.Ast, fn_node: u32) ?u32 {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (fn_node >= tags.len) return null;
        if (tags[fn_node] != .fn_decl) return null;
        const body_node = @intFromEnum(datas[fn_node].node_and_node[1]);
        if (body_node == 0 or body_node >= tags.len) return null;

        switch (tags[body_node]) {
            .block, .block_semicolon => {
                const extra = datas[body_node].extra_range;
                const start = @intFromEnum(extra.start);
                const end = @intFromEnum(extra.end);
                const statements = tree.extra_data[start..end];
                if (statements.len != 1) return null;
                return returnExprFromNode(tree, statements[0]);
            },
            .block_two, .block_two_semicolon => {
                const pair = datas[body_node].opt_node_and_opt_node;
                const first = pair[0].unwrap();
                const second = pair[1].unwrap();
                if (first != null and second != null) return null;
                if (first) |node| return returnExprFromNode(tree, @intFromEnum(node));
                if (second) |node| return returnExprFromNode(tree, @intFromEnum(node));
                return null;
            },
            .@"return" => return returnExprFromNode(tree, body_node),
            else => return null,
        }
    }

    fn returnExprFromNode(tree: *const std.zig.Ast, node: u32) ?u32 {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        if (node >= tags.len) return null;
        if (tags[node] != .@"return") return null;
        if (datas[node].opt_node.unwrap()) |expr| {
            return @intFromEnum(expr);
        }
        return null;
    }

    fn resolveParamNameFromExpr(tree: *const std.zig.Ast, expr_node: u32) ?[]const u8 {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const token_tags = tree.tokens.items(.tag);

        if (expr_node >= tags.len) return null;
        switch (tags[expr_node]) {
            .identifier => {
                const token = tree.nodes.items(.main_token)[expr_node];
                if (token >= token_tags.len or token_tags[token] != .identifier) return null;
                return tree.tokenSlice(token);
            },
            .field_access => {
                const base = @intFromEnum(datas[expr_node].node_and_token[0]);
                return resolveParamNameFromExpr(tree, base);
            },
            .slice, .slice_open, .slice_sentinel => {
                const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse return null;
                return resolveParamNameFromExpr(tree, @intFromEnum(slice.ast.sliced));
            },
            .grouped_expression, .unwrap_optional => {
                const child = @intFromEnum(datas[expr_node].node_and_token[0]);
                return resolveParamNameFromExpr(tree, child);
            },
            .@"try" => return resolveParamNameFromExpr(tree, @intFromEnum(datas[expr_node].node)),
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                const name = builtinCallName(tree, tags, expr_node) orelse return null;
                if (!std.mem.eql(u8, name, "@as") and !std.mem.eql(u8, name, "@ptrCast")) return null;
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const params = tree.builtinCallParams(&buf, @enumFromInt(expr_node)) orelse return null;
                if (params.len == 0) return null;
                // @ptrCast is a single-argument builtin in Zig 0.15.2; the type comes from context.
                const value_index: usize = if (std.mem.eql(u8, name, "@as")) 1 else 0;
                if (value_index >= params.len) return null;
                return resolveParamNameFromExpr(tree, @intFromEnum(params[value_index]));
            },
            else => return null,
        }
    }

    fn findParamIndex(tree: *const std.zig.Ast, fn_node: u32, name: []const u8) ?u32 {
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);

        if (fn_node >= tags.len) return null;
        if (tags[fn_node] != .fn_decl) return null;
        const proto_node = @intFromEnum(datas[fn_node].node_and_node[0]);
        if (proto_node == 0 or proto_node >= tags.len) return null;

        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const proto = switch (tags[proto_node]) {
            .fn_proto => tree.fnProto(@enumFromInt(proto_node)),
            .fn_proto_simple => tree.fnProtoSimple(&buffer, @enumFromInt(proto_node)),
            .fn_proto_one => tree.fnProtoOne(&buffer, @enumFromInt(proto_node)),
            .fn_proto_multi => tree.fnProtoMulti(@enumFromInt(proto_node)),
            else => return null,
        };

        var it = proto.iterate(tree);
        var index: u32 = 0;
        while (it.next()) |param| : (index += 1) {
            const name_token = param.name_token orelse continue;
            const token_tags = tree.tokens.items(.tag);
            if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
            const param_name = tree.tokenSlice(name_token);
            if (std.mem.eql(u8, param_name, name)) return index;
        }

        return null;
    }

    fn isComptimeIdentifier(ctx: *AnalysisContext, ident_node: u32) bool {
        const tree = ctx.tree;
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);
        if (ident_node >= tags.len) return false;
        if (tags[ident_node] != .identifier) return false;
        const token = tree.nodes.items(.main_token)[ident_node];
        if (token >= token_tags.len or token_tags[token] != .identifier) return false;
        const name = tree.tokenSlice(token);

        if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false") or std.mem.eql(u8, name, "null") or std.mem.eql(u8, name, "undefined")) {
            return true;
        }

        if (ctx.resolver.resolveDeclInfo(ident_node)) |decl_info| {
            if (decl_info.is_top_level and isConstDeclNode(tree, decl_info.decl_node)) {
                return true;
            }
        }

        if (ctx.comptime_params) |params| {
            if (ctx.resolver.resolve(ident_node)) |var_id| {
                if (params.get(var_id) != null) {
                    return true;
                }
            }
        }

        if (ctx.type_ctx) |type_ctx| {
            if (type_ctx.isDeclConst(name)) {
                return true;
            }
        }

        return false;
    }

    fn isTopLevelConst(ctx: *AnalysisContext, ident_node: u32) bool {
        if (ctx.resolver.resolveDeclInfo(ident_node)) |decl_info| {
            if (decl_info.is_top_level and isConstDeclNode(ctx.tree, decl_info.decl_node)) {
                return true;
            }
        }
        return false;
    }

    fn isLocalDecl(ctx: *AnalysisContext, ident_node: u32) bool {
        if (ctx.resolver.resolveDeclInfo(ident_node)) |decl_info| {
            return !decl_info.is_top_level;
        }
        return false;
    }

    fn localArrayOriginToken(ctx: *AnalysisContext, ident_node: u32) ?u32 {
        const tree = ctx.tree;
        const tags = tree.nodes.items(.tag);
        if (ident_node >= tags.len or tags[ident_node] != .identifier) return null;
        if (!isLocalDecl(ctx, ident_node)) return null;
        if (ctx.resolver.resolveDeclNode(ident_node)) |decl_node| {
            if (isArrayDeclNode(tree, decl_node)) {
                return declNameToken(ctx, ident_node) orelse treeMainToken(tree, ident_node);
            }
        }

        if (ctx.type_ctx) |type_ctx| {
            const type_info = type_ctx.getExpressionType(ident_node) orelse return null;
            if (type_info.kind == .array) {
                return declNameToken(ctx, ident_node) orelse treeMainToken(tree, ident_node);
            }
            if (type_info.type_str) |type_str| {
                if (isArrayValueTypeName(type_str)) {
                    return declNameToken(ctx, ident_node) orelse treeMainToken(tree, ident_node);
                }
            }
        }

        return null;
    }

    fn declNameToken(ctx: *AnalysisContext, ident_node: u32) ?u32 {
        const decl_node = ctx.resolver.resolveDeclNode(ident_node) orelse return null;
        const full = ctx.tree.fullVarDecl(@enumFromInt(decl_node)) orelse return null;
        const name_token = full.ast.mut_token + 1;
        if (name_token >= ctx.tree.tokens.items(.tag).len) return null;
        if (ctx.tree.tokenTag(name_token) == .identifier) {
            return name_token;
        }
        return treeMainToken(ctx.tree, decl_node);
    }

    fn isArrayValueTypeName(type_str: []const u8) bool {
        var slice = type_str;
        if (slice.len > 0 and slice[0] == '?') {
            slice = slice[1..];
        }
        if (std.mem.startsWith(u8, slice, "const ")) {
            slice = slice["const ".len..];
        }
        if (std.mem.startsWith(u8, slice, "volatile ")) {
            slice = slice["volatile ".len..];
        }
        if (slice.len < 2 or slice[0] != '[') return false;
        const second = slice[1];
        if (second == ']' or second == '*') return false;
        return true;
    }

    fn isArrayDeclNode(tree: *const std.zig.Ast, decl_node: u32) bool {
        const tags = tree.nodes.items(.tag);
        if (decl_node >= tags.len) return false;
        switch (tags[decl_node]) {
            .simple_var_decl,
            .aligned_var_decl,
            .local_var_decl,
            .global_var_decl,
            => {},
            else => return false,
        }

        const full = tree.fullVarDecl(@enumFromInt(decl_node)) orelse return false;
        if (full.ast.type_node.unwrap()) |type_node| {
            if (isArrayTypeNode(tree, @intFromEnum(type_node))) {
                return true;
            }
        }
        if (full.ast.init_node.unwrap()) |init_node| {
            if (isArrayLiteralNode(tree, @intFromEnum(init_node))) {
                return true;
            }
        }
        return false;
    }

    fn isArrayTypeNode(tree: *const std.zig.Ast, type_node: u32) bool {
        const tags = tree.nodes.items(.tag);
        if (type_node >= tags.len) return false;
        return tags[type_node] == .array_type or tags[type_node] == .array_type_sentinel;
    }

    fn isArrayLiteralNode(tree: *const std.zig.Ast, node: u32) bool {
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return false;
        return switch (tags[node]) {
            .array_init,
            .array_init_comma,
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            => true,
            else => false,
        };
    }

    fn localStructFieldArrayOrigin(ctx: *AnalysisContext, base_node: u32, field_name: []const u8) ?Origin {
        const tree = ctx.tree;
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);

        if (base_node >= tags.len or tags[base_node] != .identifier) return null;
        if (!isLocalDecl(ctx, base_node)) return null;
        const decl_node = ctx.resolver.resolveDeclNode(base_node) orelse return null;
        const full = tree.fullVarDecl(@enumFromInt(decl_node)) orelse return null;
        const init_node = full.ast.init_node.unwrap() orelse return null;
        const init_idx = @intFromEnum(init_node);

        switch (tags[init_idx]) {
            .struct_init,
            .struct_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            => {},
            else => return null,
        }

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = tree.fullStructInit(&buf, @enumFromInt(init_idx)) orelse return null;
        for (struct_init.ast.fields) |field_node| {
            const field = tree.fullContainerField(field_node) orelse continue;
            var name_token = field.ast.main_token;
            if (name_token >= token_tags.len) continue;
            if (token_tags[name_token] != .identifier) {
                if (token_tags[name_token] == .period and name_token + 1 < token_tags.len and token_tags[name_token + 1] == .identifier) {
                    name_token += 1;
                } else {
                    continue;
                }
            }
            const name = tree.tokenSlice(name_token);
            if (!std.mem.eql(u8, name, field_name)) continue;

            if (field.ast.value_expr.unwrap()) |value_expr| {
                return arrayValueOrigin(ctx, @intFromEnum(value_expr));
            }
            if (field.ast.tuple_like) {
                if (field.ast.type_expr.unwrap()) |value_expr| {
                    return arrayValueOrigin(ctx, @intFromEnum(value_expr));
                }
            }
        }

        return null;
    }

    fn arrayValueOrigin(ctx: *AnalysisContext, value_node: u32) ?Origin {
        const tree = ctx.tree;
        const tags = tree.nodes.items(.tag);
        if (value_node >= tags.len) return null;

        if (isArrayLiteralNode(tree, value_node)) {
            return .{ .kind = .stack, .token = treeMainToken(tree, value_node) };
        }

        if (tags[value_node] == .identifier) {
            if (localArrayOriginToken(ctx, value_node)) |token| {
                return .{ .kind = .stack, .token = token };
            }
        }

        if (ctx.type_ctx) |type_ctx| {
            if (type_ctx.getExpressionType(value_node)) |info| {
                if (info.kind == .array) {
                    return .{ .kind = .stack, .token = treeMainToken(tree, value_node) };
                }
                if (info.type_str) |type_str| {
                    if (isArrayValueTypeName(type_str)) {
                        return .{ .kind = .stack, .token = treeMainToken(tree, value_node) };
                    }
                }
            }
        }

        return null;
    }

    fn isConstDeclNode(tree: *const std.zig.Ast, decl_node: u32) bool {
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);
        if (decl_node >= tags.len) return false;
        switch (tags[decl_node]) {
            .simple_var_decl,
            .aligned_var_decl,
            .local_var_decl,
            .global_var_decl,
            => {
                const main_token = tree.nodes.items(.main_token)[decl_node];
                return main_token < token_tags.len and token_tags[main_token] == .keyword_const;
            },
            else => return false,
        }
    }

    fn isComptimeArrayLiteral(ctx: *AnalysisContext, array_node: u32) bool {
        const tree = ctx.tree;
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const array_init = tree.fullArrayInit(&buf, @enumFromInt(array_node)) orelse return false;
        for (array_init.ast.elements) |elem| {
            if (!isComptimeExpr(ctx, @intFromEnum(elem))) return false;
        }
        return true;
    }

    fn isComptimeStructLiteral(ctx: *AnalysisContext, struct_node: u32) bool {
        const tree = ctx.tree;
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = tree.fullStructInit(&buf, @enumFromInt(struct_node)) orelse return false;
        for (struct_init.ast.fields) |field_node| {
            const field = tree.fullContainerField(field_node) orelse continue;
            if (field.ast.value_expr.unwrap()) |value_expr| {
                if (!isComptimeExpr(ctx, @intFromEnum(value_expr))) return false;
            } else if (field.ast.tuple_like) {
                if (field.ast.type_expr.unwrap()) |value_expr| {
                    if (!isComptimeExpr(ctx, @intFromEnum(value_expr))) return false;
                }
            } else {
                return false;
            }
        }
        return true;
    }

    fn isComptimeExpr(ctx: *AnalysisContext, expr_node: u32) bool {
        const tree = ctx.tree;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        if (expr_node >= tags.len) return false;

        switch (tags[expr_node]) {
            .number_literal,
            .char_literal,
            .string_literal,
            .multiline_string_literal,
            .enum_literal,
            .error_value,
            => return true,
            .identifier => return isComptimeIdentifier(ctx, expr_node),
            .grouped_expression, .unwrap_optional => {
                const child = @intFromEnum(datas[expr_node].node_and_token[0]);
                return isComptimeExpr(ctx, child);
            },
            .@"comptime" => return isComptimeExpr(ctx, @intFromEnum(datas[expr_node].node)),
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                const name = builtinCallName(tree, tags, expr_node) orelse return false;
                if (std.mem.eql(u8, name, "@as")) {
                    var buf: [2]std.zig.Ast.Node.Index = undefined;
                    const params = tree.builtinCallParams(&buf, @enumFromInt(expr_node)) orelse return false;
                    if (params.len < 2) return false;
                    return isComptimeExpr(ctx, @intFromEnum(params[1]));
                }
                return false;
            },
            else => return false,
        }
    }

    fn builtinCallName(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        node_idx: u32,
    ) ?[]const u8 {
        const token_tags = tree.tokens.items(.tag);
        switch (tags[node_idx]) {
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {},
            else => return null,
        }

        const builtin_token = tree.nodes.items(.main_token)[node_idx];
        if (builtin_token >= token_tags.len) return null;
        if (token_tags[builtin_token] != .builtin) return null;
        return tree.tokenSlice(builtin_token);
    }

    fn treeMainToken(tree: *const std.zig.Ast, node: u32) u32 {
        const main_tokens = tree.nodes.items(.main_token);
        if (node >= main_tokens.len) return 0;
        return main_tokens[node];
    }

    fn originEqual(a: Origin, b: Origin) bool {
        return a.kind == b.kind and a.token == b.token;
    }

    fn mergeOrigin(a: Origin, b: Origin) Origin {
        // May-escape merge: keep any proven stack origin, otherwise preserve known safe origins.
        if (a.kind == .stack or b.kind == .stack) {
            var token: ?u32 = null;
            if (a.kind == .stack) token = a.token;
            if (token == null and b.kind == .stack) token = b.token;
            return .{ .kind = .stack, .token = token };
        }
        if (a.kind == .unknown) return b;
        if (b.kind == .unknown) return a;
        if (a.kind == b.kind) return a;
        return Origin.unknown();
    }

    fn reportKey(call_node: u32, origin_token: u32) u64 {
        const origin = origin_token;
        return (@as(u64, call_node) << 32) | @as(u64, origin);
    }

    const EdgeRef = struct {
        to: ids.CfgNodeId,
        kind: EdgeKind,
    };

    const EdgeLists = struct {
        items: []std.ArrayList(EdgeRef),
    };

    fn buildSuccessorLists(allocator: std.mem.Allocator, cfg: *const Cfg) !EdgeLists {
        var lists = try allocator.alloc(std.ArrayList(EdgeRef), cfg.nodeCount());
        for (lists) |*list| {
            list.* = .empty;
        }
        for (cfg.edges.items) |edge| {
            const idx: usize = @intCast(ids.cfgIndex(edge.from));
            try lists[idx].append(allocator, .{ .to = edge.to, .kind = edge.kind });
        }
        return .{ .items = lists };
    }

    fn buildPredecessorLists(allocator: std.mem.Allocator, cfg: *const Cfg) !NodeLists {
        var lists = try allocator.alloc(std.ArrayList(ids.CfgNodeId), cfg.nodeCount());
        for (lists) |*list| {
            list.* = .empty;
        }
        for (cfg.edges.items) |edge| {
            const idx: usize = @intCast(ids.cfgIndex(edge.to));
            try lists[idx].append(allocator, edge.from);
        }
        return .{ .items = lists };
    }

    const NodeLists = struct {
        items: []std.ArrayList(ids.CfgNodeId),
    };

    fn deinitEdgeLists(allocator: std.mem.Allocator, lists: *EdgeLists) void {
        for (lists.items) |*list| {
            list.deinit(allocator);
        }
        allocator.free(lists.items);
    }

    fn deinitNodeLists(allocator: std.mem.Allocator, lists: *NodeLists) void {
        for (lists.items) |*list| {
            list.deinit(allocator);
        }
        allocator.free(lists.items);
    }

    fn isJoinGuaranteed(
        allocator: std.mem.Allocator,
        cfg: *const Cfg,
        succs: []std.ArrayList(EdgeRef),
        spawn_node: ids.CfgNodeId,
        join_nodes: []const ids.CfgNodeId,
        has_try_error_edge: bool,
    ) bool {
        if (join_nodes.len == 0) return false;
        // For `try spawn`, ignore the try_error edge from the spawn site:
        // no thread is created on that error path, so join isn't required there.
        const skip_try_error_from = if (has_try_error_edge) spawn_node else null;
        // Join is guaranteed only if no path reaches exit while avoiding all join nodes.
        return !isExitReachableWithoutAnyNode(allocator, cfg, succs, spawn_node, join_nodes, skip_try_error_from);
    }

    fn isExitReachableWithoutAnyNode(
        allocator: std.mem.Allocator,
        cfg: *const Cfg,
        succs: []std.ArrayList(EdgeRef),
        start: ids.CfgNodeId,
        blocked_nodes: []const ids.CfgNodeId,
        skip_try_error_from: ?ids.CfgNodeId,
    ) bool {
        const node_count = cfg.nodeCount();
        var blocked = allocator.alloc(bool, node_count) catch return true;
        defer allocator.free(blocked);
        @memset(blocked, false);
        for (blocked_nodes) |node| {
            const idx: usize = @intCast(ids.cfgIndex(node));
            if (idx < blocked.len) {
                blocked[idx] = true;
            }
        }

        if (blocked[@intCast(ids.cfgIndex(start))]) return false;

        var visited = allocator.alloc(bool, node_count) catch return true;
        defer allocator.free(visited);
        @memset(visited, false);

        var queue: std.ArrayList(ids.CfgNodeId) = .empty;
        defer queue.deinit(allocator);
        queue.append(allocator, start) catch return true;
        visited[@intCast(ids.cfgIndex(start))] = true;

        while (queue.items.len > 0) {
            const current = queue.pop() orelse break;
            if (blocked[@intCast(ids.cfgIndex(current))]) continue;
            if (current == cfg.exit) return true;
            const idx: usize = @intCast(ids.cfgIndex(current));
            for (succs[idx].items) |succ| {
                const succ_idx: usize = @intCast(ids.cfgIndex(succ.to));
                if (blocked[succ_idx]) continue;
                if (skip_try_error_from) |skip_node| {
                    if (current == skip_node and succ.kind == .try_error) continue;
                }
                if (visited[succ_idx]) continue;
                visited[succ_idx] = true;
                queue.append(allocator, succ.to) catch return true;
            }
        }

        return false;
    }

    fn collectComptimeParams(
        tree: *const std.zig.Ast,
        fn_node: ids.AstNodeId,
        out: *std.AutoHashMap(ids.VarId, void),
    ) !void {
        const fn_index = ids.astIndex(fn_node);
        const tags = tree.nodes.items(.tag);
        if (fn_index >= tags.len) return;
        if (tags[fn_index] != .fn_decl) return;

        const data = tree.nodes.items(.data)[fn_index];
        const proto_node = @intFromEnum(data.node_and_node[0]);
        if (proto_node == 0 or proto_node >= tags.len) return;

        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const proto = switch (tags[proto_node]) {
            .fn_proto => tree.fnProto(@enumFromInt(proto_node)),
            .fn_proto_simple => tree.fnProtoSimple(&buffer, @enumFromInt(proto_node)),
            .fn_proto_one => tree.fnProtoOne(&buffer, @enumFromInt(proto_node)),
            .fn_proto_multi => tree.fnProtoMulti(@enumFromInt(proto_node)),
            else => return,
        };

        var it = proto.iterate(tree);
        while (it.next()) |param| {
            const comptime_token = param.comptime_noalias orelse continue;
            if (tree.tokenTag(comptime_token) != .keyword_comptime) continue;
            const name_token = param.name_token orelse continue;
            if (tree.tokenTag(name_token) != .identifier) continue;
            try out.put(ids.varId(name_token), {});
        }
    }

    fn isHeapAllocCall(ctx: *AnalysisContext, call_info: CallInfo) bool {
        // Treat allocator-backed values as heap to avoid misclassifying them as stack origins.
        if (ctx.config) |config| {
            var return_type_str: ?[]const u8 = null;
            if (ctx.type_ctx) |type_ctx| {
                if (type_ctx.getExpressionType(call_info.call_node)) |ti| {
                    return_type_str = ti.type_str;
                }
            }
            if (config.matchResourceModel(call_info.method_name, call_info.receiver_type, return_type_str, call_info.fqn)) |kind| {
                if (kind == .alloc) return true;
            }
        }

        if (isAllocatorMethodCall(ctx, call_info)) return true;
        if (isAllocPrintCall(ctx, call_info)) return true;

        return false;
    }

    fn isAllocatorMethodCall(ctx: *AnalysisContext, call_info: CallInfo) bool {
        const base_node = call_info.base_node orelse return false;
        if (!allocator_utils.isAllocatorExpr(ctx.tree, ctx.type_ctx, base_node)) return false;

        return std.mem.eql(u8, call_info.method_name, "alloc") or
            std.mem.eql(u8, call_info.method_name, "allocWithOptions") or
            std.mem.eql(u8, call_info.method_name, "allocAdvanced") or
            std.mem.eql(u8, call_info.method_name, "allocSentinel") or
            std.mem.eql(u8, call_info.method_name, "allocSentinelAdvanced") or
            std.mem.eql(u8, call_info.method_name, "create") or
            std.mem.eql(u8, call_info.method_name, "dupe") or
            std.mem.eql(u8, call_info.method_name, "dupeZ") or
            std.mem.eql(u8, call_info.method_name, "dupeSentinel");
    }

    fn isAllocPrintCall(ctx: *AnalysisContext, call_info: CallInfo) bool {
        if (!std.mem.eql(u8, call_info.method_name, "allocPrint")) return false;
        const allocator_arg = call_utils.callParam(ctx.tree, call_info.call_node, 0) orelse return false;
        return allocator_utils.isAllocatorExpr(ctx.tree, ctx.type_ctx, allocator_arg);
    }
};
