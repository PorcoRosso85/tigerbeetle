//! Checks for various non-functional properties of the code itself.

const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const mem = std.mem;
const math = std.math;

const stdx = @import("./stdx.zig");
const Shell = @import("./shell.zig");

test "tidy" {
    // このテストは、プロジェクトのソースコードが特定のコーディング規約に従っているかを確認します。
    // これには、禁止されたコードの存在、行の長さ、未使用のコードの検出などが含まれます。

    const allocator = std.testing.allocator;

    // 1MBのバッファを確保します。これは、ファイルの内容を一時的に保持するためのものです。
    const buffer_size = 1024 * 1024;
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    // 現在の作業ディレクトリの下の'src'ディレクトリを開きます。
    var src_dir = try fs.cwd().openIterableDir("./src", .{});
    defer src_dir.close();

    // ディレクトリのウォーカーを初期化します。これにより、ディレクトリ内のすべてのファイルを反復処理できます。
    var walker = try src_dir.walk(allocator);
    defer walker.deinit();

    // DeadDetectorを初期化します。これは、未使用のコードを検出するためのものです。
    var dead_detector = DeadDetector.init(allocator);
    defer dead_detector.deinit();

    // NB: all checks are intentionally implemented in a streaming fashion, such that we only need
    // to read the files once.
    // ディレクトリ内のすべてのファイルを反復処理します。
    while (try walker.next()) |entry| {
        // ファイルが'.zig'で終わる場合のみ、チェックを行います。
        if (entry.kind == .file and mem.endsWith(u8, entry.path, ".zig")) {
            // ファイルを開きます。
            const file = try entry.dir.openFile(entry.basename, .{});
            defer file.close();

            // ファイルの内容をバッファに読み込みます。
            const bytes_read = try file.readAll(buffer);
            // ファイルがバッファサイズより大きい場合はエラーを返します。
            if (bytes_read == buffer.len) return error.FileTooLong;

            // ファイルのパスと内容を持つSourceFileオブジェクトを作成します。
            const source_file = SourceFile{ .path = entry.path, .text = buffer[0..bytes_read] };
            // 禁止されたコードのチェックを行います。
            try tidy_banned(source_file);
            // 行の長さのチェックを行います。
            try tidy_long_line(source_file);
            // 未使用のコードのチェックを行います。
            try dead_detector.visit(source_file);
        }
    }

    // 未使用のコードのチェックを完了します。
    try dead_detector.finish();
}

const SourceFile = struct { path: []const u8, text: []const u8 };

fn tidy_banned(file: SourceFile) !void {
    if (banned(file.text)) |ban| {
        std.debug.print(
            "{s}: banned: {s}\n",
            .{ file.path, ban },
        );
        return error.Banned;
    }
}

fn tidy_long_line(file: SourceFile) !void {
    const long_line = try find_long_line(file.text);
    if (long_line) |line_index| {
        if (!is_naughty(file.path)) {
            std.debug.print(
                "{s}:{d} error: line exceeds 100 columns\n",
                .{ file.path, line_index + 1 },
            );
            return error.LineTooLong;
        }
    } else {
        if (is_naughty(file.path)) {
            std.debug.print(
                "{s}: error: no longer contains long lines, " ++
                    "remove from the `naughty_list`\n",
                .{file.path},
            );
            return error.OutdatedNaughtyList;
        }
    }
    assert((long_line != null) == is_naughty(file.path));
}

// Zig's lazy compilation model makes it too easy to forget to include a file into the build --- if
// nothing imports a file, compiler just doesn't see it and can't flag it as unused.
//
// DeadDetector implements heuristic detection of unused files, by "grepping" for import statements
// and flagging file which are never imported. This gives false negatives for unreachable cycles of
// files, as well as for identically-named files, but it should be good enough in practice.
const DeadDetector = struct {
    const FileName = [64]u8;
    const FileState = struct { import_count: u32, definition_count: u32 };
    const FileMap = std.AutoArrayHashMap(FileName, FileState);

    files: FileMap,

    fn init(allocator: std.mem.Allocator) DeadDetector {
        return .{ .files = FileMap.init(allocator) };
    }

    fn deinit(detector: *DeadDetector) void {
        assert(detector.files.count() == 0); // Sanity-check that `.finish` was called.
        detector.files.deinit();
    }

    fn visit(detector: *DeadDetector, file: SourceFile) !void {
        (try detector.file_state(file.path)).definition_count += 1;

        var text = file.text;
        for (0..1024) |_| {
            const cut = stdx.cut(text, "@import(\"") orelse break;
            text = cut.suffix;
            const import_path = stdx.cut(text, "\")").?.prefix;
            if (std.mem.endsWith(u8, import_path, ".zig")) {
                (try detector.file_state(import_path)).import_count += 1;
            }
        } else {
            std.debug.panic("file with more than 1024 imports: {s}", .{file.path});
        }
    }

    fn finish(detector: *DeadDetector) !void {
        defer detector.files.clearRetainingCapacity();

        for (detector.files.keys(), detector.files.values()) |name, state| {
            assert(state.definition_count > 0);
            if (state.import_count == 0 and !is_entry_point(name)) {
                std.debug.print("file never imported: {s}\n", .{name});
                return error.DeadFile;
            }
        }
    }

    fn file_state(detector: *DeadDetector, path: []const u8) !*FileState {
        var gop = try detector.files.getOrPut(path_to_name(path));
        if (!gop.found_existing) gop.value_ptr.* = .{ .import_count = 0, .definition_count = 0 };
        return gop.value_ptr;
    }

    fn path_to_name(path: []const u8) FileName {
        assert(std.mem.endsWith(u8, path, ".zig"));
        const basename = std.fs.path.basename(path);
        var file_name: FileName = .{0} ** 64;
        assert(basename.len <= file_name.len);
        stdx.copy_disjoint(.inexact, u8, &file_name, basename);
        return file_name;
    }

    fn is_entry_point(file: FileName) bool {
        const entry_points: []const []const u8 = &.{
            "benchmark.zig",
            "fuzz_tests.zig",
            "integration_tests.zig",
            "jni_tests.zig",
            "main.zig",
            "node.zig",
            "tb_client_header.zig",
            "unit_tests.zig",
            "vopr.zig",
        };
        for (entry_points) |entry_point| {
            if (std.mem.startsWith(u8, &file, entry_point)) return true;
        }
        return false;
    }
};

test "tidy changelog" {
    // このテストは、プロジェクトのCHANGELOG.mdファイルが特定のコーディング規約に従っているかを確認します。
    // これには、行末の空白の存在、行の長さのチェックなどが含まれます。

    const allocator = std.testing.allocator;

    // CHANGELOG.mdファイルの最大サイズを1MBと定義します。
    const changelog_size_max = 1024 * 1024;
    // CHANGELOG.mdファイルを読み込み、その内容をchangelogに格納します。
    const changelog = try fs.cwd().readFileAlloc(allocator, "CHANGELOG.md", changelog_size_max);
    defer allocator.free(changelog);

    // ファイルの内容を行ごとに分割します。
    var line_iterator = mem.split(u8, changelog, "\n");
    var line_index: usize = 0;
    // 各行に対して以下のチェックを行います。
    while (line_iterator.next()) |line| : (line_index += 1) {
        // 行末に空白が存在するかをチェックします。
        if (std.mem.endsWith(u8, line, " ")) {
            std.debug.print("CHANGELOG.md:{d} trailing whitespace", .{line_index + 1});
            return error.TrailingWhitespace;
        }
        // 行の長さ（文字数）を計算します。
        const line_length = try std.unicode.utf8CountCodepoints(line);
        // 行の長さが100文字を超えているか、または行にリンクが含まれていないかをチェックします。
        if (line_length > 100 and !has_link(line)) {
            std.debug.print("CHANGELOG.md:{d} line exceeds 100 columns\n", .{line_index + 1});
            return error.LineTooLong;
        }
    }
}

test "tidy naughty list" {
    // このテストは、プロジェクトのソースディレクトリ（"src"）内に、"naughty_list"に記載されたファイルが存在しないことを確認します。
    // "naughty_list"には、プロジェクト内に存在してはならないファイルのパスが記載されています。

    // 現在の作業ディレクトリの下の'src'ディレクトリを開きます。
    var src = try fs.cwd().openDir("src", .{});
    defer src.close();

    // "naughty_list"に記載された各ファイルについて、以下のチェックを行います。
    for (naughty_list) |naughty_path| {
        // ファイルが存在するかを確認します。
        _ = src.statFile(naughty_path) catch |err| {
            // ファイルが存在しない場合は、その旨を出力します。
            if (err == error.FileNotFound) {
                std.debug.print(
                    "path does not exist: src/{s}\n",
                    .{naughty_path},
                );
            }
            // ファイルが存在する場合は、エラーを返します。
            return err;
        };
    }
}

test "tidy no large blobs" {
    // このテストは、Gitリポジトリ内に大きなファイル（"blob"）が存在しないことを確認します。
    // これにより、リポジトリのサイズが不必要に大きくなるのを防ぎます。

    const allocator = std.testing.allocator;
    // Shellインスタンスを作成します。これを使用して、シェルコマンドを実行します。
    const shell = try Shell.create(allocator);
    defer shell.destroy();

    // Run `git rev-list | git cat-file` to find large blobs. This is better than looking at the
    // files in the working tree, because it catches the cases where a large file is "removed" by
    // reverting the commit.
    //
    // Zig's std doesn't provide a cross platform abstraction for piping two commands together, so
    // we begrudgingly pass the data through this intermediary process.
    // Gitリポジトリが浅い（shallow）かどうかを確認します。浅いリポジトリでは、全ての履歴を持っていないため、大きなファイルを検出できない可能性があります。
    const shallow = try shell.exec_stdout("git rev-parse --is-shallow-repository", .{});
    if (!std.mem.eql(u8, shallow, "false")) {
        return error.ShallowRepository;
    }

    // Gitリポジトリ内の全てのオブジェクト（ファイル）をリストアップします。
    const MiB = 1024 * 1024;
    const rev_list = try shell.exec_stdout_options(
        .{ .max_output_bytes = 50 * MiB },
        "git rev-list --objects HEAD",
        .{},
    );
    // 各オブジェクトのタイプ（blobなど）、サイズ、パスを取得します。
    const objects = try shell.exec_stdout_options(
        .{ .max_output_bytes = 50 * MiB, .stdin_slice = rev_list },
        "git cat-file --batch-check={format}",
        .{ .format = "%(objecttype) %(objectsize) %(rest)" },
    );

    // 大きなファイルが存在するかどうかを示すフラグを初期化します。
    var has_large_blobs = false;
    // 各オブジェクトについて、以下のチェックを行います。
    var lines = std.mem.split(u8, objects, "\n");
    while (lines.next()) |line| {
        // Parsing lines like
        //     blob 1032 client/package.json
        // オブジェクトがblob（ファイル）であるかを確認します。
        var blob = stdx.cut_prefix(line, "blob ") orelse continue;

        // blobのサイズとパスを取得します。
        var cut = stdx.cut(blob, " ").?;
        const size = try std.fmt.parseInt(u64, cut.prefix, 10);
        const path = cut.suffix;

        // 特定のファイルは大きくても許容します。
        if (std.mem.eql(u8, path, "src/vsr/replica.zig")) continue; // :-)
        if (std.mem.eql(u8, path, "src/docs_website/package-lock.json")) continue; // :-(

        // ファイルのサイズが1/4MiBを超えているかを確認します。
        if (size > @divExact(MiB, 4)) {
            has_large_blobs = true;
            std.debug.print("{s}\n", .{line});
        }
    }
    // 大きなファイルが存在する場合は、エラーを返します。
    if (has_large_blobs) return error.HasLargeBlobs;
}

// Sanity check for "unexpected" files in the repository.
test "tidy extensions" {
    // このテストは、Gitリポジトリ内の全てのファイルが許可された拡張子を持っているか、または例外リストに含まれているかを確認します。
    // これにより、不適切なファイル形式がリポジトリに含まれていないことを保証します。

    // 許可された拡張子のリストを定義します。
    const allowed_extensions = std.ComptimeStringMap(void, .{
        .{".bat"}, .{".c"},     .{".cs"},   .{".csproj"},  .{".css"},  .{".go"},
        .{".h"},   .{".hcl"},   .{".java"}, .{".js"},      .{".json"}, .{".md"},
        .{".mod"}, .{".props"}, .{".ps1"},  .{".service"}, .{".sh"},   .{".sln"},
        .{".sum"}, .{".ts"},    .{".txt"},  .{".xml"},     .{".yml"},  .{".zig"},
    });

    // 例外として許可されるファイルのリストを定義します。
    const exceptions = std.ComptimeStringMap(void, .{
        .{".editorconfig"},          .{".gitattributes"},   .{".gitignore"},
        .{".nojekyll"},              .{"CNAME"},            .{"Dockerfile"},
        .{"exclude-pmd.properties"}, .{"favicon.ico"},      .{"favicon.png"},
        .{"LICENSE"},                .{"module-info.test"}, .{"index.html"},
        .{"logo.svg"},               .{"logo-white.svg"},   .{"logo-with-text-white.svg"},
    });

    // Shellインスタンスを作成します。これを使用して、シェルコマンドを実行します。
    const allocator = std.testing.allocator;
    const shell = try Shell.create(allocator);
    defer shell.destroy();

    // Gitリポジトリ内の全てのファイルをリストアップします。
    const files = try shell.exec_stdout("git ls-files", .{});
    var lines = std.mem.split(u8, files, "\n");
    // 不適切な拡張子が存在するかどうかを示すフラグを初期化します。
    var bad_extension = false;
    // 各ファイルについて、以下のチェックを行います。
    while (lines.next()) |path| {
        if (path.len == 0) continue;
        // ファイルの拡張子を取得します。
        const extension = std.fs.path.extension(path);
        // 拡張子が許可されているかを確認します。
        if (!allowed_extensions.has(extension)) {
            // ファイル名を取得します。
            const basename = std.fs.path.basename(path);
            // ファイルが例外リストに含まれていないかを確認します。
            if (!exceptions.has(basename)) {
                std.debug.print("bad extension: {s}\n", .{path});
                bad_extension = true;
            }
        }
    }
    // 不適切な拡張子が存在する場合は、エラーを返します。
    if (bad_extension) return error.BadExtension;
}

fn banned(source: []const u8) ?[]const u8 {
    // Note: must avoid banning ourselves!
    if (std.mem.indexOf(u8, source, "std." ++ "BoundedArray") != null) {
        return "use stdx." ++ "BoundedArray instead of std version";
    }

    if (std.mem.indexOf(u8, source, "trait." ++ "hasUniqueRepresentation") != null) {
        return "use stdx." ++ "has_unique_representation instead of std version";
    }

    // Ban "fixme" comments. This allows using fixe as reminders with teeth --- when working on a
    // larger pull requests, it is often helpful to leave fixme comments as a reminder to oneself.
    // This tidy rule ensures that the reminder is acted upon before code gets into main. That is:
    // - use fixme for issues to be fixed in the same pull request,
    // - use todo as general-purpose long-term remainders without enforcement.
    if (std.mem.indexOf(u8, source, "FIX" ++ "ME") != null) {
        return "FIX" ++ "ME comments must be addressed before getting to main";
    }

    return null;
}

fn is_naughty(path: []const u8) bool {
    for (naughty_list) |naughty_path| {
        // Separator-agnostic path comparison.
        if (naughty_path.len == path.len) {
            var equal_paths = true;
            for (naughty_path, 0..) |c, i| {
                equal_paths = equal_paths and
                    (path[i] == c or (path[i] == fs.path.sep and c == fs.path.sep_posix));
            }
            if (equal_paths) return true;
        }
    }
    return false;
}

fn find_long_line(file_text: []const u8) !?usize {
    var line_iterator = mem.split(u8, file_text, "\n");
    var line_index: usize = 0;
    while (line_iterator.next()) |line| : (line_index += 1) {
        const line_length = try std.unicode.utf8CountCodepoints(line);
        if (line_length > 100) {
            if (has_link(line)) continue;
            // For multiline strings, we care that the _result_ fits 100 characters,
            // but we don't mind indentation in the source.
            if (parse_multiline_string(line)) |string_value| {
                const string_value_length = try std.unicode.utf8CountCodepoints(string_value);
                if (string_value_length <= 100) continue;
            }
            return line_index;
        }
    }
    return null;
}

/// Heuristically checks if a `line` contains an URL.
fn has_link(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "https://") != null;
}

/// If a line is a `\\` string literal, extract its value.
fn parse_multiline_string(line: []const u8) ?[]const u8 {
    const cut = stdx.cut(line, "\\\\") orelse return null;
    for (cut.prefix) |c| if (c != ' ') return null;
    return cut.suffix;
}

const naughty_list = [_][]const u8{
    "clients/c/tb_client_header_test.zig",
    "clients/c/tb_client.zig",
    "clients/c/tb_client/context.zig",
    "clients/c/tb_client/signal.zig",
    "clients/c/test.zig",
    "clients/dotnet/docs.zig",
    "clients/dotnet/dotnet_bindings.zig",
    "clients/go/go_bindings.zig",
    "clients/java/docs.zig",
    "clients/java/java_bindings.zig",
    "clients/java/src/client.zig",
    "clients/java/src/jni_tests.zig",
    "clients/node/node_bindings.zig",
    "clients/node/src/node.zig",
    "clients/node/src/translate.zig",
    "config.zig",
    "constants.zig",
    "io/benchmark.zig",
    "io/darwin.zig",
    "io/windows.zig",
    "lsm/binary_search.zig",
    "lsm/binary_search_benchmark.zig",
    "lsm/forest_fuzz.zig",
    "lsm/groove.zig",
    "lsm/level_data_iterator.zig",
    "lsm/manifest_level.zig",
    "lsm/segmented_array_benchmark.zig",
    "lsm/segmented_array.zig",
    "lsm/set_associative_cache.zig",
    "lsm/table_data_iterator.zig",
    "lsm/tree_fuzz.zig",
    "simulator.zig",
    "state_machine.zig",
    "state_machine/auditor.zig",
    "state_machine/workload.zig",
    "testing/cluster/network.zig",
    "testing/cluster/state_checker.zig",
    "testing/hash_log.zig",
    "testing/low_level_hash_vectors.zig",
    "testing/packet_simulator.zig",
    "testing/state_machine.zig",
    "testing/storage.zig",
    "testing/time.zig",
    "tigerbeetle/main.zig",
    "tracer.zig",
    "vsr.zig",
    "vsr/client_replies.zig",
    "vsr/client_sessions.zig",
    "vsr/client.zig",
    "vsr/clock.zig",
    "vsr/grid.zig",
    "vsr/journal.zig",
    "vsr/replica_test.zig",
    "vsr/replica.zig",
    "vsr/free_set.zig",
    "vsr/superblock_quorums.zig",
    "vsr/superblock.zig",
};
