const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;

pub const UnreachableCodeRule = struct {
    pub const rule: Rule = .{
        .name = "unreachable-code",
        .checkFn = check,
    };

    fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);

        for (tags, 0..) |tag, i| {
            if (tag == .fn_decl) {
                const fn_node: u32 = @intCast(i);
                try checkFunctionForUnreachable(src, allocator, diagnostics, fn_node);
            }
        }
    }

    fn checkFunctionForUnreachable(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        fn_node: u32,
    ) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        var body_node: ?u32 = null;

        if (tags[fn_node] == .fn_decl) {
            const node_data = data[fn_node];
            const fn_body = @intFromEnum(node_data.node_and_node[1]);
            if (fn_body == 0) return;
            body_node = fn_body;
        }

        if (body_node) |body| {
            try checkBlockForUnreachable(src, allocator, diagnostics, body);
        }
    }

    fn checkBlockForUnreachable(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        block_node: u32,
    ) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        const block_tag = tags[block_node];
        var statements: []const u32 = &.{};
        var scratch_buf: [2]u32 = undefined;

        switch (block_tag) {
            .block, .block_semicolon => {
                const extra_range = data[block_node].extra_range;
                const start = @intFromEnum(extra_range.start);
                const end = @intFromEnum(extra_range.end);
                statements = tree.extra_data[start..end];
            },
            .block_two, .block_two_semicolon => {
                const opt_nodes = data[block_node].opt_node_and_opt_node;
                var count: usize = 0;
                if (opt_nodes[0].unwrap()) |n| {
                    scratch_buf[count] = @intFromEnum(n);
                    count += 1;
                }
                if (opt_nodes[1].unwrap()) |n| {
                    scratch_buf[count] = @intFromEnum(n);
                    count += 1;
                }
                statements = scratch_buf[0..count];
            },
            else => return,
        }

        var found_terminator = false;
        for (statements) |stmt| {
            if (found_terminator) {
                const main_tokens = tree.nodes.items(.main_token);
                const token_starts = tree.tokens.items(.start);
                const main_token = main_tokens[stmt];
                const byte_offset = token_starts[main_token];
                const loc = try src.byteToLocation(byte_offset);
                const diag = try Diagnostic.initAtLocation(
                    allocator,
                    src.getFilePath(),
                    rule.name,
                    .warning,
                    "unreachable code detected",
                    loc.line,
                    loc.column,
                );
                try diagnostics.append(allocator, diag);
            }

            const stmt_tag = tags[stmt];
            if (stmt_tag == .@"return" or stmt_tag == .unreachable_literal) {
                found_terminator = true;
            } else if (stmt_tag == .@"if" or stmt_tag == .if_simple) {
                if (try isIfFullyTerminating(src, stmt)) {
                    found_terminator = true;
                }
            } else if (stmt_tag == .@"switch" or stmt_tag == .switch_comma) {
                if (try isSwitchFullyTerminating(src, stmt)) {
                    found_terminator = true;
                }
            } else if (stmt_tag == .while_simple or stmt_tag == .while_cont or stmt_tag == .@"while") {
                if (try isWhileFullyTerminating(src, allocator, stmt)) {
                    found_terminator = true;
                }
            }

            try checkStatementRecursively(src, allocator, diagnostics, stmt);
        }
    }

    fn isIfFullyTerminating(src: *Source, if_node: u32) RuleError!bool {
        const tree = try src.ast();
        const full_if = tree.fullIf(@enumFromInt(if_node)) orelse return false;

        const then_expr = @intFromEnum(full_if.ast.then_expr);
        if (then_expr == 0) return false;

        const else_expr_opt = full_if.ast.else_expr.unwrap();
        if (else_expr_opt == null) return false;

        const else_expr = @intFromEnum(else_expr_opt.?);
        if (else_expr == 0) return false;

        const then_terminates = try doesBlockTerminate(src, then_expr);
        const else_terminates = try doesBlockTerminate(src, else_expr);

        return then_terminates and else_terminates;
    }

    fn isSwitchFullyTerminating(src: *Source, switch_node: u32) RuleError!bool {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        const switch_tag = tags[switch_node];
        if (switch_tag != .@"switch" and switch_tag != .switch_comma) {
            return false;
        }

        const extra_idx = @intFromEnum(data[switch_node].node_and_extra[1]);
        const cases_start = tree.extra_data[extra_idx];
        const cases_end = tree.extra_data[extra_idx + 1];

        if (cases_start >= cases_end) {
            return false;
        }

        var has_else = false;
        for (tree.extra_data[cases_start..cases_end]) |case_node| {
            const case_tag = tags[case_node];
            if (case_tag != .switch_case_one and case_tag != .switch_case and
                case_tag != .switch_case_inline_one and case_tag != .switch_case_inline)
            {
                continue;
            }

            const full_case = tree.fullSwitchCase(@enumFromInt(case_node)) orelse continue;

            // Check if this is an else branch (no values)
            if (full_case.ast.values.len == 0) {
                has_else = true;
            }

            // Check if this case terminates
            const target_expr = @intFromEnum(full_case.ast.target_expr);
            if (target_expr == 0) return false;

            if (!try doesBlockTerminate(src, target_expr)) {
                return false;
            }
        }

        // Switch must have an else branch to be exhaustive (for our purposes)
        return has_else;
    }

    fn isWhileFullyTerminating(src: *Source, _: std.mem.Allocator, while_node: u32) RuleError!bool {
        // Use CFG-based analysis to determine if while loop always terminates
        // This handles while(true) { return; } and similar patterns

        const tree = try src.ast();
        const full_while = tree.fullWhile(@enumFromInt(while_node)) orelse return false;

        // Check if this is while(true) - condition must be a true literal
        const cond = @intFromEnum(full_while.ast.cond_expr);
        if (cond == 0) return false;

        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);

        // Check if condition is literal 'true'
        if (tags[cond] != .identifier) return false;
        const cond_token = main_tokens[cond];
        if (token_tags[cond_token] != .identifier) return false;

        const token_starts = tree.tokens.items(.start);
        const start = token_starts[cond_token];
        const source_bytes = tree.source;

        // Check if the identifier is "true"
        if (start + 4 > source_bytes.len) return false;
        if (!std.mem.eql(u8, source_bytes[start .. start + 4], "true")) return false;

        // It's while(true), now check if the body always terminates
        const body_expr = @intFromEnum(full_while.ast.then_expr);
        if (body_expr == 0) return false;

        // Check if there's any break statement in the loop body
        if (hasBreakStatement(tree, body_expr)) {
            return false;
        }

        // Build a mini-CFG just for the loop body to check if it terminates
        // For simplicity, we'll use our existing doesBlockTerminate which handles
        // returns and nested if/else/switch
        return try doesBlockTerminate(src, body_expr);
    }

    fn hasBreakStatement(tree: *const std.zig.Ast, node: u32) bool {
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        if (node >= tags.len) return false;

        const tag = tags[node];

        // Check if this node is a break
        if (tag == .@"break") return true;

        // Recursively check children based on node type
        switch (tag) {
            .block, .block_semicolon => {
                const extra_range = data[node].extra_range;
                const start = @intFromEnum(extra_range.start);
                const end = @intFromEnum(extra_range.end);
                for (tree.extra_data[start..end]) |stmt| {
                    if (hasBreakStatement(tree, stmt)) return true;
                }
            },
            .block_two, .block_two_semicolon => {
                const opt_nodes = data[node].opt_node_and_opt_node;
                if (opt_nodes[0].unwrap()) |n| {
                    if (hasBreakStatement(tree, @intFromEnum(n))) return true;
                }
                if (opt_nodes[1].unwrap()) |n| {
                    if (hasBreakStatement(tree, @intFromEnum(n))) return true;
                }
            },
            .@"if", .if_simple => {
                const full_if = tree.fullIf(@enumFromInt(node)) orelse return false;
                if (hasBreakStatement(tree, @intFromEnum(full_if.ast.then_expr))) return true;
                if (full_if.ast.else_expr.unwrap()) |else_node| {
                    if (hasBreakStatement(tree, @intFromEnum(else_node))) return true;
                }
            },
            .@"switch", .switch_comma => {
                const extra_idx = @intFromEnum(data[node].node_and_extra[1]);
                const cases_start = tree.extra_data[extra_idx];
                const cases_end = tree.extra_data[extra_idx + 1];
                for (tree.extra_data[cases_start..cases_end]) |case_node| {
                    const full_case = tree.fullSwitchCase(@enumFromInt(case_node)) orelse continue;
                    if (hasBreakStatement(tree, @intFromEnum(full_case.ast.target_expr))) return true;
                }
            },
            else => {},
        }

        return false;
    }

    fn doesBlockTerminate(src: *Source, node: u32) RuleError!bool {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        const node_tag = tags[node];

        if (node_tag == .@"return" or node_tag == .unreachable_literal) {
            return true;
        }

        var statements: []const u32 = &.{};
        var scratch_buf: [2]u32 = undefined;

        switch (node_tag) {
            .block, .block_semicolon => {
                const extra_range = data[node].extra_range;
                const start = @intFromEnum(extra_range.start);
                const end = @intFromEnum(extra_range.end);
                statements = tree.extra_data[start..end];
            },
            .block_two, .block_two_semicolon => {
                const opt_nodes = data[node].opt_node_and_opt_node;
                var count: usize = 0;
                if (opt_nodes[0].unwrap()) |n| {
                    scratch_buf[count] = @intFromEnum(n);
                    count += 1;
                }
                if (opt_nodes[1].unwrap()) |n| {
                    scratch_buf[count] = @intFromEnum(n);
                    count += 1;
                }
                statements = scratch_buf[0..count];
            },
            else => return false,
        }

        if (statements.len == 0) {
            return false;
        }

        const last_stmt = statements[statements.len - 1];
        const last_tag = tags[last_stmt];

        if (last_tag == .@"return" or last_tag == .unreachable_literal) {
            return true;
        }

        if (last_tag == .@"if" or last_tag == .if_simple) {
            return try isIfFullyTerminating(src, last_stmt);
        }

        if (last_tag == .@"switch" or last_tag == .switch_comma) {
            return try isSwitchFullyTerminating(src, last_stmt);
        }

        return false;
    }

    fn checkStatementRecursively(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        stmt_node: u32,
    ) RuleError!void {
        const tree = try src.ast();

        const stmt_tag = tree.nodes.items(.tag)[stmt_node];

        switch (stmt_tag) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                try checkBlockForUnreachable(src, allocator, diagnostics, stmt_node);
            },
            .@"if", .if_simple => {
                const full_if = tree.fullIf(@enumFromInt(stmt_node)) orelse return;
                const then_node = @intFromEnum(full_if.ast.then_expr);
                if (then_node != 0) {
                    try checkStatementRecursively(src, allocator, diagnostics, then_node);
                }
                if (full_if.ast.else_expr.unwrap()) |else_node| {
                    const else_idx = @intFromEnum(else_node);
                    if (else_idx != 0) {
                        try checkStatementRecursively(src, allocator, diagnostics, else_idx);
                    }
                }
            },
            .@"switch", .switch_comma => {
                const tree2 = try src.ast();
                const data = tree2.nodes.items(.data);
                const extra_idx = @intFromEnum(data[stmt_node].node_and_extra[1]);
                const cases_start = tree2.extra_data[extra_idx];
                const cases_end = tree2.extra_data[extra_idx + 1];
                for (tree2.extra_data[cases_start..cases_end]) |case_node| {
                    const full_case = tree2.fullSwitchCase(@enumFromInt(case_node)) orelse continue;
                    const target = @intFromEnum(full_case.ast.target_expr);
                    if (target != 0) {
                        try checkStatementRecursively(src, allocator, diagnostics, target);
                    }
                }
            },
            .while_simple, .while_cont, .@"while" => {
                const full_while = tree.fullWhile(@enumFromInt(stmt_node)) orelse return;
                const body = @intFromEnum(full_while.ast.then_expr);
                if (body != 0) {
                    try checkStatementRecursively(src, allocator, diagnostics, body);
                }
            },
            else => {},
        }
    }
};
