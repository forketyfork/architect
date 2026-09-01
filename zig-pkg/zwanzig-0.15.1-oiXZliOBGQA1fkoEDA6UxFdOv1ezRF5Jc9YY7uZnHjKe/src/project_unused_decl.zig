const std = @import("std");
const compat = @import("compat.zig");
const ast_walk = @import("ast_walk.zig");
const call_resolver = @import("analysis/call_resolver.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const import_resolver = @import("analysis/import_resolver.zig");
const Source = @import("source.zig").Source;
const suppression = @import("suppression.zig");

const rule_id = "unused-decl";
const fieldAccessName = import_resolver.fieldAccessName;
const identifierName = import_resolver.identifierName;
const importPathFromBuiltinCall = import_resolver.importPathFromBuiltinCall;
const isVarDeclTag = import_resolver.isVarDeclTag;
const normalizeIdentifier = import_resolver.normalizeIdentifier;
const pathsEquivalent = import_resolver.pathsEquivalent;

const DeclKind = enum {
    function,
    type_decl,
    constant,
    variable,
    declaration,

    fn description(self: DeclKind) []const u8 {
        return switch (self) {
            .function => "Function",
            .type_decl => "Type",
            .constant => "Constant",
            .variable => "Variable",
            .declaration => "Declaration",
        };
    }
};

const FileInfo = struct {
    path: []const u8,
    content: [:0]const u8,
    tree: std.zig.Ast,
    suppressions: suppression.SuppressionMap,

    fn deinit(self: *FileInfo, allocator: std.mem.Allocator) void {
        self.suppressions.deinit();
        self.tree.deinit(allocator);
        allocator.free(self.content.ptr[0 .. self.content.len + 1]);
    }
};

const DeclInfo = struct {
    file_index: usize,
    node_index: u32,
    name: []const u8,
    normalized_name: []const u8,
    byte_offset: usize,
    kind: DeclKind,

    fn deinit(self: *DeclInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.normalized_name);
    }
};

const ProjectContext = struct {
    io_context: *compat.Context,
    allocator: std.mem.Allocator,
    files: []const import_resolver.File,
    api_roots: std.ArrayList(usize) = .empty,

    fn init(io_context: *compat.Context, allocator: std.mem.Allocator, files: []const import_resolver.File) ProjectContext {
        return .{
            .io_context = io_context,
            .allocator = allocator,
            .files = files,
        };
    }

    fn deinit(self: *ProjectContext) void {
        self.api_roots.deinit(self.allocator);
    }

    fn collectApiRoots(self: *ProjectContext) !void {
        for (self.files, 0..) |*file, file_index| {
            if (!std.mem.eql(u8, std.fs.path.basename(file.path), "build.zig")) continue;
            try self.collectBuildRootSourceFiles(file_index);
        }
        try self.collectExternalBuildRootSourceFiles("build.zig");
    }

    fn isPublicApiFile(self: *const ProjectContext, file_index: usize) bool {
        if (self.containsApiRoot(file_index)) return true;

        const target_path = self.files[file_index].path;
        for (self.api_roots.items) |root_index| {
            if (import_resolver.filePubliclyImportsPath(self.files, root_index, target_path)) return true;
        }
        return false;
    }

    fn containsApiRoot(self: *const ProjectContext, file_index: usize) bool {
        for (self.api_roots.items) |root_index| {
            if (root_index == file_index) return true;
        }
        return false;
    }

    fn appendApiRoot(self: *ProjectContext, file_index: usize) !void {
        if (self.containsApiRoot(file_index)) return;
        try self.api_roots.append(self.allocator, file_index);
    }

    fn collectBuildRootSourceFiles(self: *ProjectContext, build_file_index: usize) !void {
        try self.collectBuildRootSourceFilesFromTree(self.files[build_file_index].tree, self.files[build_file_index].path);
    }

    fn collectExternalBuildRootSourceFiles(self: *ProjectContext, build_path: []const u8) !void {
        if (import_resolver.findFileIndexByPath(self.files, build_path) != null) return;

        const max_size = 10 * 1024 * 1024;
        // Sentinel needed for std.zig.Ast.parse; free accounts for sentinel byte below.
        // zwanzig-disable-next-line: sentinel-alloc
        const content = compat.readFileAlloc(self.io_context, self.allocator, build_path, max_size) catch return;
        defer self.allocator.free(content.ptr[0 .. content.len + 1]);

        var tree = try std.zig.Ast.parse(self.allocator, content, .zig);
        defer tree.deinit(self.allocator);

        try self.collectBuildRootSourceFilesFromTree(&tree, build_path);
    }

    fn collectBuildRootSourceFilesFromTree(self: *ProjectContext, tree: *const std.zig.Ast, build_path: []const u8) !void {
        const token_tags = tree.tokens.items(.tag);
        for (token_tags, 0..) |_, token_index| {
            if (!std.mem.eql(u8, tree.tokenSlice(@intCast(token_index)), "root_source_file")) continue;

            var scan_token = token_index + 1;
            var remaining: usize = 24;
            while (scan_token < token_tags.len and remaining > 0) : ({
                scan_token += 1;
                remaining -= 1;
            }) {
                if (token_tags[scan_token] != .string_literal) continue;
                const literal = tree.tokenSlice(@intCast(scan_token));
                if (literal.len < 2) continue;
                const root_path = literal[1 .. literal.len - 1];
                if (import_resolver.resolveImportToFileIndex(self.files, build_path, root_path)) |root_index| {
                    try self.appendApiRoot(root_index);
                }
                break;
            }
        }
    }
};

pub fn analyze(
    io_context: *compat.Context,
    allocator: std.mem.Allocator,
    file_paths: []const []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (file_paths.len < 2) return;

    var files: std.ArrayList(FileInfo) = .empty;
    defer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }

    for (file_paths) |path| {
        if (containsPath(files.items, path)) continue;

        const max_size = 10 * 1024 * 1024;
        // Sentinel needed for std.zig.Ast.parse; free accounts for sentinel byte below.
        // zwanzig-disable-next-line: sentinel-alloc
        const content = try compat.readFileAlloc(io_context, allocator, path, max_size);
        errdefer allocator.free(content.ptr[0 .. content.len + 1]);

        var tree = try std.zig.Ast.parse(allocator, content, .zig);
        errdefer tree.deinit(allocator);

        var suppressions = try suppression.parseSuppressions(allocator, content);
        errdefer suppressions.deinit();

        try files.append(allocator, .{
            .path = path,
            .content = content,
            .tree = tree,
            .suppressions = suppressions,
        });
    }

    if (files.items.len < 2) return;

    const resolver_files = try makeResolverFiles(allocator, files.items);
    defer allocator.free(resolver_files);

    var project = ProjectContext.init(io_context, allocator, resolver_files);
    defer project.deinit();
    try project.collectApiRoots();

    var decls: std.ArrayList(DeclInfo) = .empty;
    defer {
        for (decls.items) |*decl| decl.deinit(allocator);
        decls.deinit(allocator);
    }

    for (files.items, 0..) |*file, file_index| {
        if (project.isPublicApiFile(file_index)) continue;
        try collectPublicRootDecls(allocator, &file.tree, file.path, file_index, &decls);
    }

    const used = try collectProjectUsedDecls(allocator, files.items, resolver_files, decls.items);
    defer allocator.free(used);

    for (decls.items, 0..) |decl, decl_index| {
        if (used[decl_index]) continue;
        var source = Source.init(allocator, files.items[decl.file_index].path, files.items[decl.file_index].content);
        defer source.deinit();
        const range = try source.byteRangeToSourceRange(decl.byte_offset, decl.byte_offset + decl.name.len);

        if (files.items[decl.file_index].suppressions.isSuppressed(range.start.line, rule_id)) continue;

        const message = try std.fmt.allocPrint(
            allocator,
            "{s} '{s}' is never used by another analyzed file",
            .{ decl.kind.description(), decl.name },
        );
        defer allocator.free(message);

        var diag = try Diagnostic.init(
            allocator,
            files.items[decl.file_index].path,
            rule_id,
            .warning,
            message,
            range,
        );
        errdefer diag.deinit(allocator);
        try diagnostics.append(allocator, diag);
    }
}

fn containsPath(files: []const FileInfo, path: []const u8) bool {
    return findFileIndexByPath(files, path) != null;
}

fn findFileIndexByPath(files: []const FileInfo, path: []const u8) ?usize {
    for (files, 0..) |file, file_index| {
        if (std.mem.eql(u8, file.path, path) or pathsEquivalent(file.path, path)) return file_index;
    }
    return null;
}

fn makeResolverFiles(allocator: std.mem.Allocator, files: []FileInfo) ![]import_resolver.File {
    const resolver_files = try allocator.alloc(import_resolver.File, files.len);
    for (files, 0..) |*file, index| {
        resolver_files[index] = .{
            .path = file.path,
            .tree = &file.tree,
        };
    }
    return resolver_files;
}

fn collectPublicRootDecls(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    path: []const u8,
    file_index: usize,
    decls: *std.ArrayList(DeclInfo),
) !void {
    const tags = tree.nodes.items(.tag);
    const token_starts = tree.tokens.items(.start);

    for (tree.rootDecls()) |decl_idx| {
        const idx = @intFromEnum(decl_idx);
        const info = switch (tags[idx]) {
            .simple_var_decl,
            .aligned_var_decl,
            .global_var_decl,
            => try extractPublicVarDecl(allocator, tree, @intCast(idx), token_starts, file_index),
            .fn_decl,
            .fn_proto,
            .fn_proto_simple,
            .fn_proto_one,
            .fn_proto_multi,
            => try extractPublicFnDecl(allocator, tree, @intCast(idx), token_starts, file_index),
            else => null,
        };

        if (info) |decl| {
            if (isIgnoredPublicDecl(path, decl.name)) {
                var mutable_decl = decl;
                mutable_decl.deinit(allocator);
                continue;
            }
            var mutable_decl = decl;
            errdefer mutable_decl.deinit(allocator);
            try decls.append(allocator, mutable_decl);
        }
    }
}

fn extractPublicVarDecl(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node_idx: u32,
    token_starts: []const u32,
    file_index: usize,
) !?DeclInfo {
    const full = tree.fullVarDecl(@enumFromInt(node_idx)) orelse return null;
    if (!isPubToken(tree, full.visib_token)) return null;
    if (full.extern_export_token != null) return null;
    if (isPublicAliasDecl(tree, full)) return null;

    const token_tags = tree.tokens.items(.tag);
    const name_token = full.ast.mut_token + 1;
    if (name_token >= token_tags.len) return null;
    if (token_tags[name_token] != .identifier) return null;

    const name = tree.tokenSlice(name_token);
    return try makeDeclInfo(
        allocator,
        file_index,
        node_idx,
        name,
        token_starts[name_token],
        classifyVarDecl(tree, full),
    );
}

fn extractPublicFnDecl(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node_idx: u32,
    token_starts: []const u32,
    file_index: usize,
) !?DeclInfo {
    const tags = tree.nodes.items(.tag);
    const tag = tags[node_idx];
    var buffer: [1]std.zig.Ast.Node.Index = undefined;

    return switch (tag) {
        .fn_decl => blk: {
            const data = tree.nodes.items(.data)[node_idx];
            const proto_node = @intFromEnum(data.node_and_node[0]);
            break :blk extractPublicFnDecl(allocator, tree, proto_node, token_starts, file_index);
        },
        .fn_proto => extractPublicFnProto(
            allocator,
            tree,
            node_idx,
            tree.fnProto(@enumFromInt(node_idx)),
            token_starts,
            file_index,
        ),
        .fn_proto_simple => extractPublicFnProto(
            allocator,
            tree,
            node_idx,
            tree.fnProtoSimple(&buffer, @enumFromInt(node_idx)),
            token_starts,
            file_index,
        ),
        .fn_proto_one => extractPublicFnProto(
            allocator,
            tree,
            node_idx,
            tree.fnProtoOne(&buffer, @enumFromInt(node_idx)),
            token_starts,
            file_index,
        ),
        .fn_proto_multi => extractPublicFnProto(
            allocator,
            tree,
            node_idx,
            tree.fnProtoMulti(@enumFromInt(node_idx)),
            token_starts,
            file_index,
        ),
        else => null,
    };
}

fn extractPublicFnProto(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node_idx: u32,
    proto: std.zig.Ast.full.FnProto,
    token_starts: []const u32,
    file_index: usize,
) !?DeclInfo {
    if (!isPubToken(tree, proto.visib_token)) return null;
    if (proto.extern_export_inline_token) |tok| {
        const tag = tree.tokenTag(tok);
        if (tag == .keyword_extern or tag == .keyword_export) return null;
    }

    const name_token = proto.name_token orelse return null;
    if (tree.tokenTag(name_token) != .identifier) return null;

    return try makeDeclInfo(
        allocator,
        file_index,
        node_idx,
        tree.tokenSlice(name_token),
        token_starts[name_token],
        .function,
    );
}

fn makeDeclInfo(
    allocator: std.mem.Allocator,
    file_index: usize,
    node_index: u32,
    name: []const u8,
    byte_offset: usize,
    kind: DeclKind,
) !DeclInfo {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const normalized_copy = try allocator.dupe(u8, normalizeIdentifier(name));
    return .{
        .file_index = file_index,
        .node_index = node_index,
        .name = name_copy,
        .normalized_name = normalized_copy,
        .byte_offset = byte_offset,
        .kind = kind,
    };
}

fn isPubToken(tree: *const std.zig.Ast, token: ?std.zig.Ast.TokenIndex) bool {
    const tok = token orelse return false;
    return tree.tokenTag(tok) == .keyword_pub;
}

fn isPublicAliasDecl(tree: *const std.zig.Ast, full: std.zig.Ast.full.VarDecl) bool {
    if (tree.tokenTag(full.ast.mut_token) != .keyword_const) return false;

    const init_node = full.ast.init_node.unwrap() orelse return false;
    const init_idx = @intFromEnum(init_node);
    const tags = tree.nodes.items(.tag);
    if (init_idx >= tags.len) return false;

    const name_token = full.ast.mut_token + 1;
    if (name_token >= tree.tokens.len or tree.tokenTag(name_token) != .identifier) return false;
    const public_name = tree.tokenSlice(name_token);

    return switch (tags[init_idx]) {
        .identifier => isReexportAlias(public_name, identifierName(tree, init_idx) orelse return false),
        .field_access => isReexportAlias(public_name, fieldAccessName(tree, init_idx) orelse return false),
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => isImportBuiltinCall(tree, init_idx),
        else => false,
    };
}

fn isImportBuiltinCall(tree: *const std.zig.Ast, node_idx: usize) bool {
    return importPathFromBuiltinCall(tree, node_idx) != null;
}

fn classifyVarDecl(tree: *const std.zig.Ast, full: std.zig.Ast.full.VarDecl) DeclKind {
    if (full.ast.init_node.unwrap()) |init_node| {
        const tag = tree.nodes.items(.tag)[@intFromEnum(init_node)];
        if (isContainerTag(tag) or tag == .error_set_decl) return .type_decl;
    }
    const mut_tag = tree.tokenTag(full.ast.mut_token);
    if (mut_tag == .keyword_const) return .constant;
    if (mut_tag == .keyword_var) return .variable;
    return .declaration;
}

fn collectProjectUsedDecls(
    allocator: std.mem.Allocator,
    files: []const FileInfo,
    resolver_files: []const import_resolver.File,
    decls: []const DeclInfo,
) ![]bool {
    const used = try allocator.alloc(bool, decls.len);
    @memset(used, false);

    for (decls, 0..) |decl, decl_index| {
        if (isReferencedWithinDeclFile(files, resolver_files, decl) or isReferencedFromAnotherFile(files, resolver_files, decl)) {
            used[decl_index] = true;
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (decls, 0..) |decl, decl_index| {
            if (!used[decl_index]) continue;
            if (try markPublicSurfaceReferences(files, decls, used, decl)) changed = true;
        }
    }

    return used;
}

fn isReferencedWithinDeclFile(files: []const FileInfo, resolver_files: []const import_resolver.File, decl: DeclInfo) bool {
    const file = files[decl.file_index];
    const tags = file.tree.nodes.items(.tag);
    const main_tokens = file.tree.nodes.items(.main_token);

    for (tags, 0..) |tag, node_index| {
        if (node_index == decl.node_index) continue;
        if (tag != .identifier) continue;
        if (node_index >= main_tokens.len) continue;

        const name = normalizeIdentifier(file.tree.tokenSlice(main_tokens[node_index]));
        if (std.mem.eql(u8, name, decl.normalized_name)) return true;
    }

    if (fileReferencesDeclByTypedReceiver(resolver_files, decl.file_index, decl.file_index, decl.normalized_name)) return true;

    return false;
}

fn isReferencedFromAnotherFile(files: []const FileInfo, resolver_files: []const import_resolver.File, decl: DeclInfo) bool {
    const decl_file = files[decl.file_index];
    for (files, 0..) |*file, file_index| {
        if (file_index == decl.file_index) continue;
        if (std.mem.eql(u8, file.path, decl_file.path)) continue;
        if (fileReferencesDecl(resolver_files, file_index, decl.file_index, decl_file.path, decl.normalized_name)) return true;
    }
    return false;
}

fn markPublicSurfaceReferences(
    files: []const FileInfo,
    decls: []const DeclInfo,
    used: []bool,
    decl: DeclInfo,
) !bool {
    const file = &files[decl.file_index];
    var scanner = PublicSurfaceScanner{
        .tree = &file.tree,
        .decls = decls,
        .used = used,
        .file_index = decl.file_index,
    };
    try scanner.scanDecl(decl.node_index);
    return scanner.changed;
}

const PublicSurfaceScanner = struct {
    tree: *const std.zig.Ast,
    decls: []const DeclInfo,
    used: []bool,
    file_index: usize,
    changed: bool = false,
    stop: bool = false,

    fn scanDecl(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        const tags = self.tree.nodes.items(.tag);
        if (node >= tags.len) return;

        switch (tags[node]) {
            .simple_var_decl,
            .aligned_var_decl,
            .global_var_decl,
            => try self.scanVarDeclSurface(node),
            .fn_decl => {
                const data = self.tree.nodes.items(.data)[node];
                try self.scanFnProto(@intFromEnum(data.node_and_node[0]));
            },
            .fn_proto,
            .fn_proto_simple,
            .fn_proto_one,
            .fn_proto_multi,
            => try self.scanFnProto(node),
            else => {},
        }
    }

    fn scanVarDeclSurface(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        const full = self.tree.fullVarDecl(@enumFromInt(node)) orelse return;
        try self.scanOptionalNode(full.ast.type_node);

        const init_node = full.ast.init_node.unwrap() orelse return;
        const init_idx = @intFromEnum(init_node);
        const tags = self.tree.nodes.items(.tag);
        if (init_idx < tags.len and isContainerTag(tags[init_idx])) {
            try self.scanContainerSurface(init_idx);
        } else {
            try self.scanNode(init_idx);
        }
    }

    fn scanFnProto(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        const tags = self.tree.nodes.items(.tag);
        if (node >= tags.len) return;

        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const proto = switch (tags[node]) {
            .fn_proto => self.tree.fnProto(@enumFromInt(node)),
            .fn_proto_simple => self.tree.fnProtoSimple(&buffer, @enumFromInt(node)),
            .fn_proto_one => self.tree.fnProtoOne(&buffer, @enumFromInt(node)),
            .fn_proto_multi => self.tree.fnProtoMulti(@enumFromInt(node)),
            else => return,
        };

        for (proto.ast.params) |param| try self.scanParam(@intFromEnum(param));
        try self.scanOptionalNode(proto.ast.return_type);
        try self.scanOptionalNode(proto.ast.align_expr);
        try self.scanOptionalNode(proto.ast.addrspace_expr);
        try self.scanOptionalNode(proto.ast.section_expr);
        try self.scanOptionalNode(proto.ast.callconv_expr);
    }

    fn scanParam(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        const tags = self.tree.nodes.items(.tag);
        if (node >= tags.len) return;

        if (isVarDeclTag(tags[node])) {
            const full = self.tree.fullVarDecl(@enumFromInt(node)) orelse return;
            try self.scanOptionalNode(full.ast.type_node);
            return;
        }

        try self.scanNode(node);
    }

    fn scanContainerSurface(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        const tags = self.tree.nodes.items(.tag);
        if (node >= tags.len) return;

        switch (tags[node]) {
            .container_decl,
            .container_decl_trailing,
            => try self.scanContainerDeclComponents(self.tree.containerDecl(@enumFromInt(node))),
            .container_decl_two,
            .container_decl_two_trailing,
            => {
                var buffer: [2]std.zig.Ast.Node.Index = undefined;
                try self.scanContainerDeclComponents(self.tree.containerDeclTwo(&buffer, @enumFromInt(node)));
            },
            .container_decl_arg,
            .container_decl_arg_trailing,
            => try self.scanContainerDeclComponents(self.tree.containerDeclArg(@enumFromInt(node))),
            .tagged_union,
            .tagged_union_trailing,
            => try self.scanContainerDeclComponents(self.tree.taggedUnion(@enumFromInt(node))),
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => try self.scanContainerDeclComponents(self.tree.taggedUnionEnumTag(@enumFromInt(node))),
            .tagged_union_two,
            .tagged_union_two_trailing,
            => {
                var buffer: [2]std.zig.Ast.Node.Index = undefined;
                try self.scanContainerDeclComponents(self.tree.taggedUnionTwo(&buffer, @enumFromInt(node)));
            },
            else => {},
        }
    }

    fn scanContainerDeclComponents(
        self: *PublicSurfaceScanner,
        container: std.zig.Ast.full.ContainerDecl,
    ) anyerror!void {
        if (container.ast.arg.unwrap()) |arg_node| try self.scanNode(@intFromEnum(arg_node));

        const tags = self.tree.nodes.items(.tag);
        for (container.ast.members) |member_node| {
            const member = @intFromEnum(member_node);
            if (member >= tags.len) continue;

            switch (tags[member]) {
                .container_field,
                .container_field_init,
                .container_field_align,
                => try self.scanContainerField(member),
                .simple_var_decl,
                .aligned_var_decl,
                .global_var_decl,
                => {
                    const full = self.tree.fullVarDecl(@enumFromInt(member)) orelse continue;
                    if (isPubToken(self.tree, full.visib_token)) try self.scanVarDeclSurface(member);
                },
                .fn_decl,
                .fn_proto,
                .fn_proto_simple,
                .fn_proto_one,
                .fn_proto_multi,
                => if (isPublicFnDecl(self.tree, member)) try self.scanDecl(member),
                else => {},
            }
        }
    }

    fn scanContainerField(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        const field = self.tree.fullContainerField(@enumFromInt(node)) orelse return;
        try self.scanOptionalNode(field.ast.type_expr);
        try self.scanOptionalNode(field.ast.value_expr);
        try self.scanOptionalNode(field.ast.align_expr);
    }

    fn scanOptionalNode(self: *PublicSurfaceScanner, node_opt: std.zig.Ast.Node.OptionalIndex) anyerror!void {
        if (node_opt.unwrap()) |node| try self.scanNode(@intFromEnum(node));
    }

    fn scanNode(self: *PublicSurfaceScanner, node: u32) anyerror!void {
        try ast_walk.walk(PublicSurfaceScanner, self.tree, node, self);
    }

    pub fn visit(
        self: *PublicSurfaceScanner,
        tree: *const std.zig.Ast,
        node: u32,
        tag: std.zig.Ast.Node.Tag,
    ) anyerror!void {
        if (tag != .identifier) return;

        const main_tokens = tree.nodes.items(.main_token);
        if (node >= main_tokens.len) return;
        self.markIdentifier(tree.tokenSlice(main_tokens[node]));
    }

    fn markIdentifier(self: *PublicSurfaceScanner, identifier: []const u8) void {
        const normalized = normalizeIdentifier(identifier);
        for (self.decls, 0..) |candidate, candidate_index| {
            if (candidate.file_index != self.file_index) continue;
            if (self.used[candidate_index]) continue;
            if (!std.mem.eql(u8, candidate.normalized_name, normalized)) continue;

            self.used[candidate_index] = true;
            self.changed = true;
        }
    }
};

fn fileReferencesDecl(
    files: []const import_resolver.File,
    file_index: usize,
    decl_file_index: usize,
    decl_path: []const u8,
    normalized_name: []const u8,
) bool {
    const file = files[file_index];
    if (fileReferencesDeclByFieldAccess(files, file.tree, file.path, decl_path, normalized_name)) return true;
    if (fileReferencesDeclByTypedReceiver(files, file_index, decl_file_index, normalized_name)) return true;
    if (import_resolver.fileUsingnamespaceImportsPath(files, file.tree, file.path, decl_path) and fileReferencesBareName(file.tree, normalized_name)) return true;
    return false;
}

fn fileReferencesDeclByFieldAccess(
    files: []const import_resolver.File,
    tree: *const std.zig.Ast,
    importer_path: []const u8,
    decl_path: []const u8,
    normalized_name: []const u8,
) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    for (tags, 0..) |tag, node_index| {
        if (tag != .field_access) continue;
        const field_token = datas[node_index].node_and_token[1];
        const slice = normalizeIdentifier(tree.tokenSlice(field_token));
        if (!std.mem.eql(u8, slice, normalized_name)) continue;

        const lhs = @intFromEnum(datas[node_index].node_and_token[0]);
        if (import_resolver.nodeImportsPath(files, tree, lhs, importer_path, decl_path)) return true;
    }
    return false;
}

fn fileReferencesDeclByTypedReceiver(
    files: []const import_resolver.File,
    file_index: usize,
    decl_file_index: usize,
    normalized_name: []const u8,
) bool {
    const file = files[file_index];
    const tree = file.tree;
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    const resolver = call_resolver.ProjectTypeResolver{
        .files = files,
        .file_index = file_index,
    };

    for (tags, 0..) |tag, node_index| {
        switch (tag) {
            .field_access => {
                const field_access = datas[node_index].node_and_token;
                const field_name = normalizeIdentifier(tree.tokenSlice(field_access[1]));
                if (!std.mem.eql(u8, field_name, normalized_name)) continue;

                const receiver = @intFromEnum(field_access[0]);
                if (resolver.resolveExprType(receiver)) |receiver_type| {
                    if (receiver_type.file_index == decl_file_index) return true;
                }
            },
            .simple_var_decl,
            .aligned_var_decl,
            .global_var_decl,
            .local_var_decl,
            => {
                const full = tree.fullVarDecl(@enumFromInt(node_index)) orelse continue;
                if (resolver.varDeclInitializerReferencesExpectedTypeMethod(full, decl_file_index, normalized_name)) return true;
            },
            else => {},
        }
    }

    return false;
}

fn fileReferencesBareName(tree: *const std.zig.Ast, normalized_name: []const u8) bool {
    const tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);

    for (tags, 0..) |tag, node_index| {
        if (tag != .identifier) continue;
        if (node_index >= main_tokens.len) continue;
        const name = normalizeIdentifier(tree.tokenSlice(main_tokens[node_index]));
        if (std.mem.eql(u8, name, normalized_name)) return true;
    }
    return false;
}

fn isReexportAlias(public_name: []const u8, referenced_name: []const u8) bool {
    const normalized_public = normalizeIdentifier(public_name);
    const normalized_referenced = normalizeIdentifier(referenced_name);
    if (std.mem.eql(u8, normalized_public, normalized_referenced)) return true;
    return isTypeLikeName(normalized_public) and isTypeLikeName(normalized_referenced);
}

fn isTypeLikeName(name: []const u8) bool {
    if (name.len == 0) return false;
    return std.ascii.isUpper(name[0]);
}

fn isIgnoredPublicDecl(path: []const u8, name: []const u8) bool {
    if (isSpecialName(name)) return true;
    return std.mem.eql(u8, std.fs.path.basename(path), "build.zig") and std.mem.eql(u8, name, "build");
}

fn isSpecialName(name: []const u8) bool {
    if (name.len > 0 and name[0] == '_') return true;
    if (std.mem.eql(u8, name, "main")) return true;
    if (std.mem.eql(u8, name, "panic")) return true;
    if (std.mem.eql(u8, name, "std_options")) return true;
    return false;
}

fn isPublicFnDecl(tree: *const std.zig.Ast, node: u32) bool {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len) return false;

    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const proto = switch (tags[node]) {
        .fn_decl => blk: {
            const data = tree.nodes.items(.data)[node];
            const proto_node = @intFromEnum(data.node_and_node[0]);
            break :blk switch (tags[proto_node]) {
                .fn_proto => tree.fnProto(@enumFromInt(proto_node)),
                .fn_proto_simple => tree.fnProtoSimple(&buffer, @enumFromInt(proto_node)),
                .fn_proto_one => tree.fnProtoOne(&buffer, @enumFromInt(proto_node)),
                .fn_proto_multi => tree.fnProtoMulti(@enumFromInt(proto_node)),
                else => return false,
            };
        },
        .fn_proto => tree.fnProto(@enumFromInt(node)),
        .fn_proto_simple => tree.fnProtoSimple(&buffer, @enumFromInt(node)),
        .fn_proto_one => tree.fnProtoOne(&buffer, @enumFromInt(node)),
        .fn_proto_multi => tree.fnProtoMulti(@enumFromInt(node)),
        else => return false,
    };

    return isPubToken(tree, proto.visib_token);
}

fn isContainerTag(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        => true,
        else => false,
    };
}

test "project unused declarations ignore Zig build entrypoint" {
    try std.testing.expect(isIgnoredPublicDecl("build.zig", "build"));
    try std.testing.expect(isIgnoredPublicDecl("workspace/build.zig", "build"));
    try std.testing.expect(!isIgnoredPublicDecl("src/lib.zig", "build"));
    try std.testing.expect(!isIgnoredPublicDecl("build.zig", "helper"));
}
