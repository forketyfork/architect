const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Diagnostic = @import("../rule.zig").Diagnostic;
const Source = @import("../source.zig").Source;

/// Rule that enforces file naming conventions based on whether the file
/// contains top-level fields (i.e., acts as a struct).
///
/// In Zig, a file can act as an implicit struct by having top-level fields.
/// This rule enforces the convention that:
/// - Files with top-level fields should have a capitalized file name (e.g., `MyType.zig`)
/// - Files without top-level fields should have a lowercase file name (e.g., `utils.zig`)
pub const FileAsStructRule = struct {
    pub const rule: Rule = Rule{
        .name = "file-as-struct",
        .default_severity = .warning,
        .checkFn = check,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const tree = try src.ast();
        const file_path = src.getFilePath();

        const has_fields = hasTopLevelFields(tree);
        const filename = getFilename(file_path);

        if (filename.len == 0) return;

        const first_char = filename[0];
        const is_capitalized = std.ascii.isUpper(first_char);

        if (has_fields and !is_capitalized) {
            const diag = try Diagnostic.initAtLocation(
                allocator,
                file_path,
                "file-as-struct",
                .warning,
                "File contains top-level fields but has a lowercase name. " ++
                    "Consider using a capitalized name (e.g., 'MyType.zig') for struct-like files.",
                1,
                1,
            );
            try diagnostics.append(allocator, diag);
        } else if (!has_fields and is_capitalized) {
            const diag = try Diagnostic.initAtLocation(
                allocator,
                file_path,
                "file-as-struct",
                .warning,
                "File has a capitalized name but contains no top-level fields. " ++
                    "Consider using a lowercase name (e.g., 'utils.zig') for module files.",
                1,
                1,
            );
            try diagnostics.append(allocator, diag);
        }
    }

    fn hasTopLevelFields(tree: *const std.zig.Ast) bool {
        const tags = tree.nodes.items(.tag);
        const root_decls = tree.rootDecls();

        for (root_decls) |decl_idx| {
            const tag = tags[@intFromEnum(decl_idx)];
            if (isContainerField(tag)) {
                return true;
            }
        }

        return false;
    }

    fn isContainerField(tag: std.zig.Ast.Node.Tag) bool {
        return switch (tag) {
            .container_field_init,
            .container_field,
            => true,
            else => false,
        };
    }

    fn getFilename(file_path: []const u8) []const u8 {
        const basename = std.fs.path.basename(file_path);
        if (std.mem.endsWith(u8, basename, ".zig")) {
            return basename[0 .. basename.len - 4];
        }
        return basename;
    }
};
