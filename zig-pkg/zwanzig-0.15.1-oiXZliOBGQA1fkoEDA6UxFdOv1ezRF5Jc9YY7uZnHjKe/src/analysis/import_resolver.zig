const std = @import("std");
const ast_walk = @import("../ast_walk.zig");

pub const File = struct {
    path: []const u8,
    tree: *const std.zig.Ast,
};

pub fn findFileIndexByPath(files: []const File, path: []const u8) ?usize {
    for (files, 0..) |file, file_index| {
        if (std.mem.eql(u8, file.path, path) or pathsEquivalent(file.path, path)) return file_index;
    }
    return null;
}

pub fn filePubliclyImportsPath(files: []const File, file_index: usize, target_path: []const u8) bool {
    if (file_index >= files.len) return false;

    const file = files[file_index];
    const tags = file.tree.nodes.items(.tag);

    for (file.tree.rootDecls()) |decl_idx| {
        const idx = @intFromEnum(decl_idx);
        if (idx >= tags.len) continue;
        if (!isVarDeclTag(tags[idx])) continue;
        if (publicVarDeclImportsPath(file.tree, @intCast(idx), file.path, target_path)) return true;
    }
    return publicUsingnamespaceImportsPath(files, file.tree, file.path, target_path);
}

pub fn nodeImportsPath(
    files: []const File,
    tree: *const std.zig.Ast,
    node: usize,
    importer_path: []const u8,
    target_path: []const u8,
) bool {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len) return false;

    switch (tags[node]) {
        .identifier => {
            const name = identifierName(tree, node) orelse return false;
            return importAliasResolvesToPath(tree, importer_path, name, target_path);
        },
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const import_path = importPathFromBuiltinCall(tree, node) orelse return false;
            return importMayResolveToPath(importer_path, import_path, target_path);
        },
        .field_access => {
            const datas = tree.nodes.items(.data);
            const lhs = @intFromEnum(datas[node].node_and_token[0]);
            const field_name = normalizeIdentifier(tree.tokenSlice(datas[node].node_and_token[1]));

            for (files, 0..) |candidate, candidate_index| {
                if (!nodeImportsPath(files, tree, lhs, importer_path, candidate.path)) continue;
                if (filePublicMemberImportsPath(files, candidate_index, field_name, target_path)) return true;
            }
            return false;
        },
        else => return false,
    }
}

pub fn fileUsingnamespaceImportsPath(
    files: []const File,
    tree: *const std.zig.Ast,
    importer_path: []const u8,
    target_path: []const u8,
) bool {
    const token_tags = tree.tokens.items(.tag);

    for (token_tags, 0..) |_, token_index| {
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(token_index)), "usingnamespace")) continue;

        const import_token = nextNonCommentToken(token_tags, token_index + 1) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(import_token)), "@import")) continue;

        const import_path = importPathFromBuiltinToken(tree, import_token) orelse continue;
        if (importMayResolveToPath(importer_path, import_path, target_path)) return true;
        if (resolveImportToFileIndex(files, importer_path, import_path)) |file_index| {
            if (filePubliclyImportsPath(files, file_index, target_path)) return true;
        }
    }

    return false;
}

pub fn publicUsingnamespaceImportsPath(
    files: []const File,
    tree: *const std.zig.Ast,
    importer_path: []const u8,
    target_path: []const u8,
) bool {
    const token_tags = tree.tokens.items(.tag);

    for (token_tags, 0..) |_, token_index| {
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(token_index)), "usingnamespace")) continue;

        const pub_token = prevNonCommentToken(token_tags, token_index) orelse continue;
        if (tree.tokenTag(@intCast(pub_token)) != .keyword_pub) continue;

        const import_token = nextNonCommentToken(token_tags, token_index + 1) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(import_token)), "@import")) continue;

        const import_path = importPathFromBuiltinToken(tree, import_token) orelse continue;
        if (importMayResolveToPath(importer_path, import_path, target_path)) return true;
        if (resolveImportToFileIndex(files, importer_path, import_path)) |file_index| {
            if (filePubliclyImportsPath(files, file_index, target_path)) return true;
        }
    }

    return false;
}

pub fn initNodeImportsPath(
    tree: *const std.zig.Ast,
    node: usize,
    importer_path: []const u8,
    target_path: []const u8,
) bool {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len) return false;

    switch (tags[node]) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const import_path = importPathFromBuiltinCall(tree, node) orelse return false;
            return importMayResolveToPath(importer_path, import_path, target_path);
        },
        else => {
            var scanner = ImportPathScanner{
                .importer_path = importer_path,
                .target_path = target_path,
            };
            ast_walk.walk(ImportPathScanner, tree, @intCast(node), &scanner) catch return false;
            return scanner.found;
        },
    }
}

pub fn importPathFromBuiltinCall(tree: *const std.zig.Ast, node_idx: usize) ?[]const u8 {
    const main_tokens = tree.nodes.items(.main_token);
    if (node_idx >= main_tokens.len) return null;
    const token = main_tokens[node_idx];
    if (token >= tree.tokens.len) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(token), "@import")) return null;

    const token_tags = tree.tokens.items(.tag);
    var scan_token = token + 1;
    const end_token = @min(token_tags.len, token + 6);
    while (scan_token < end_token) : (scan_token += 1) {
        if (token_tags[scan_token] != .string_literal) continue;
        const literal = tree.tokenSlice(scan_token);
        if (literal.len < 2) return null;
        return literal[1 .. literal.len - 1];
    }
    return null;
}

pub fn importPathFromBuiltinToken(tree: *const std.zig.Ast, token: usize) ?[]const u8 {
    const token_tags = tree.tokens.items(.tag);
    const l_paren = nextNonCommentToken(token_tags, token + 1) orelse return null;
    if (token_tags[l_paren] != .l_paren) return null;

    const string_token = nextNonCommentToken(token_tags, l_paren + 1) orelse return null;
    if (token_tags[string_token] != .string_literal) return null;

    const literal = tree.tokenSlice(@intCast(string_token));
    if (literal.len < 2) return null;
    return literal[1 .. literal.len - 1];
}

pub fn importResolvesToPath(importer_path: []const u8, import_path: []const u8, target_path: []const u8) bool {
    if (std.mem.eql(u8, import_path, target_path)) return true;

    const importer_dir = std.fs.path.dirname(importer_path) orelse "";
    if (importer_dir.len == 0) return pathsEquivalent(import_path, target_path);

    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = std.fmt.bufPrint(&resolved_buf, "{s}/{s}", .{ importer_dir, import_path }) catch return false;
    return pathsEquivalent(resolved, target_path);
}

pub fn importMayResolveToPath(importer_path: []const u8, import_path: []const u8, target_path: []const u8) bool {
    if (importResolvesToPath(importer_path, import_path, target_path)) return true;
    return packageImportMayResolveToPath(import_path, target_path);
}

pub fn resolveImportToFileIndex(files: []const File, importer_path: []const u8, import_path: []const u8) ?usize {
    for (files, 0..) |file, file_index| {
        if (importMayResolveToPath(importer_path, import_path, file.path)) return file_index;
    }
    return null;
}

pub fn packageImportMayResolveToPath(import_path: []const u8, target_path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, import_path, '/') != null) return false;
    if (std.mem.endsWith(u8, import_path, ".zig")) return false;

    const basename = std.fs.path.basename(target_path);
    if (!std.mem.endsWith(u8, basename, ".zig")) return false;
    const stem = basename[0 .. basename.len - ".zig".len];
    return std.mem.eql(u8, stem, import_path);
}

pub fn pathsEquivalent(a: []const u8, b: []const u8) bool {
    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    var b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const normalized_a = normalizePath(&a_buf, a) catch return false;
    const normalized_b = normalizePath(&b_buf, b) catch return false;
    return std.mem.eql(u8, normalized_a, normalized_b);
}

pub fn normalizePath(buffer: []u8, path: []const u8) ![]const u8 {
    var segments: [128][]const u8 = undefined;
    var segment_count: usize = 0;

    var rest = path;
    while (rest.len > 0) {
        const slash_index = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const segment = rest[0..slash_index];
        if (segment.len != 0 and !std.mem.eql(u8, segment, ".")) {
            if (std.mem.eql(u8, segment, "..") and segment_count > 0) {
                segment_count -= 1;
            } else {
                if (segment_count >= segments.len) return error.PathTooManySegments;
                segments[segment_count] = segment;
                segment_count += 1;
            }
        }
        if (slash_index == rest.len) break;
        rest = rest[slash_index + 1 ..];
    }

    var len: usize = 0;
    for (segments[0..segment_count]) |segment| {
        if (len != 0) {
            if (len >= buffer.len) return error.PathTooLong;
            buffer[len] = '/';
            len += 1;
        }
        if (len + segment.len > buffer.len) return error.PathTooLong;
        @memcpy(buffer[len..][0..segment.len], segment);
        len += segment.len;
    }

    return buffer[0..len];
}

pub fn normalizeIdentifier(ident: []const u8) []const u8 {
    if (ident.len >= 3 and std.mem.startsWith(u8, ident, "@\"") and ident[ident.len - 1] == '"') {
        return ident[2 .. ident.len - 1];
    }
    return ident;
}

pub fn fileStem(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, basename, ".zig")) return basename[0 .. basename.len - ".zig".len];
    return basename;
}

pub fn nodeStart(tree: *const std.zig.Ast, node: usize) ?usize {
    const main_tokens = tree.nodes.items(.main_token);
    if (node >= main_tokens.len) return null;
    const token = main_tokens[node];
    if (token >= tree.tokens.len) return null;
    return tree.tokens.items(.start)[token];
}

pub fn isVarDeclTag(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .simple_var_decl,
        .aligned_var_decl,
        .global_var_decl,
        .local_var_decl,
        => true,
        else => false,
    };
}

pub fn isBuiltinCallTag(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => true,
        else => false,
    };
}

pub fn nextNonCommentToken(token_tags: []const std.zig.Token.Tag, start: usize) ?usize {
    var index = start;
    while (index < token_tags.len) : (index += 1) {
        switch (token_tags[index]) {
            .container_doc_comment, .doc_comment => continue,
            else => return index,
        }
    }
    return null;
}

pub fn prevNonCommentToken(token_tags: []const std.zig.Token.Tag, start: usize) ?usize {
    if (start == 0) return null;
    var index = start - 1;
    while (true) {
        switch (token_tags[index]) {
            .container_doc_comment, .doc_comment => {},
            else => return index,
        }
        if (index == 0) return null;
        index -= 1;
    }
}

pub fn paramNameTokenBeforeType(tree: *const std.zig.Ast, type_node: usize) ?usize {
    const main_tokens = tree.nodes.items(.main_token);
    if (type_node >= main_tokens.len) return null;
    const token_tags = tree.tokens.items(.tag);
    const type_token = main_tokens[type_node];
    const colon_token = prevNonCommentToken(token_tags, type_token) orelse return null;
    if (token_tags[colon_token] != .colon) return null;
    const name_token = prevNonCommentToken(token_tags, colon_token) orelse return null;
    if (token_tags[name_token] != .identifier) return null;
    return name_token;
}

pub fn identifierName(tree: *const std.zig.Ast, node: usize) ?[]const u8 {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len or tags[node] != .identifier) return null;
    const main_tokens = tree.nodes.items(.main_token);
    if (node >= main_tokens.len) return null;
    return normalizeIdentifier(tree.tokenSlice(main_tokens[node]));
}

pub fn fieldAccessName(tree: *const std.zig.Ast, node: usize) ?[]const u8 {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len or tags[node] != .field_access) return null;
    const datas = tree.nodes.items(.data);
    return normalizeIdentifier(tree.tokenSlice(datas[node].node_and_token[1]));
}

fn publicVarDeclImportsPath(
    tree: *const std.zig.Ast,
    node_idx: u32,
    importer_path: []const u8,
    target_path: []const u8,
) bool {
    const full = tree.fullVarDecl(@enumFromInt(node_idx)) orelse return false;
    if (!isPubToken(tree, full.visib_token)) return false;

    const init_node = full.ast.init_node.unwrap() orelse return false;
    const init_idx = @intFromEnum(init_node);
    const tags = tree.nodes.items(.tag);
    if (init_idx >= tags.len) return false;

    switch (tags[init_idx]) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const import_path = importPathFromBuiltinCall(tree, init_idx) orelse return false;
            return importMayResolveToPath(importer_path, import_path, target_path);
        },
        else => return false,
    }
}

fn importAliasResolvesToPath(
    tree: *const std.zig.Ast,
    importer_path: []const u8,
    alias_name: []const u8,
    target_path: []const u8,
) bool {
    const tags = tree.nodes.items(.tag);

    for (tags, 0..) |tag, node_index| {
        if (!isVarDeclTag(tag)) continue;
        const full = tree.fullVarDecl(@enumFromInt(node_index)) orelse continue;
        const name_token = full.ast.mut_token + 1;
        if (name_token >= tree.tokens.len) continue;
        if (tree.tokenTag(name_token) != .identifier) continue;

        const name = normalizeIdentifier(tree.tokenSlice(name_token));
        if (!std.mem.eql(u8, name, alias_name)) continue;

        const init_node = full.ast.init_node.unwrap() orelse continue;
        if (initNodeImportsPath(tree, @intFromEnum(init_node), importer_path, target_path)) return true;
    }

    return false;
}

fn filePublicMemberImportsPath(files: []const File, file_index: usize, member_name: []const u8, target_path: []const u8) bool {
    if (file_index >= files.len) return false;
    const file = files[file_index];
    const tags = file.tree.nodes.items(.tag);

    for (file.tree.rootDecls()) |decl_idx| {
        const idx = @intFromEnum(decl_idx);
        if (idx >= tags.len) continue;
        if (!isVarDeclTag(tags[idx])) continue;
        if (publicVarDeclNamedImportsPath(file.tree, @intCast(idx), file.path, member_name, target_path)) return true;
    }
    return false;
}

fn publicVarDeclNamedImportsPath(
    tree: *const std.zig.Ast,
    node_idx: u32,
    importer_path: []const u8,
    expected_name: []const u8,
    target_path: []const u8,
) bool {
    const full = tree.fullVarDecl(@enumFromInt(node_idx)) orelse return false;
    if (!isPubToken(tree, full.visib_token)) return false;

    const name_token = full.ast.mut_token + 1;
    if (name_token >= tree.tokens.len) return false;
    if (tree.tokenTag(name_token) != .identifier) return false;
    const name = normalizeIdentifier(tree.tokenSlice(name_token));
    if (!std.mem.eql(u8, name, expected_name)) return false;

    const init_node = full.ast.init_node.unwrap() orelse return false;
    const import_path = importPathFromBuiltinCall(tree, @intFromEnum(init_node)) orelse return false;
    return importMayResolveToPath(importer_path, import_path, target_path);
}

fn isPubToken(tree: *const std.zig.Ast, token: ?std.zig.Ast.TokenIndex) bool {
    const tok = token orelse return false;
    return tree.tokenTag(tok) == .keyword_pub;
}

const ImportPathScanner = struct {
    importer_path: []const u8,
    target_path: []const u8,
    found: bool = false,
    stop: bool = false,

    pub fn visit(
        self: *ImportPathScanner,
        tree: *const std.zig.Ast,
        node: u32,
        tag: std.zig.Ast.Node.Tag,
    ) anyerror!void {
        switch (tag) {
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => {
                const import_path = importPathFromBuiltinCall(tree, node) orelse return;
                if (importMayResolveToPath(self.importer_path, import_path, self.target_path)) {
                    self.found = true;
                    self.stop = true;
                }
            },
            else => {},
        }
    }
};
