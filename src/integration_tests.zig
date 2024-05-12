//! Integration tests for TigerBeetle. Although the term is not particularly well-defined, here
//! it means a specific thing:
//!
//!   * the test binary itself doesn't contain any code from TigerBeetle,
//!   * but it has access to a pre-build `./tigerbeetle` binary.
//!
//! All the testing is done through interacting with a separate tigerbeetle process.

const std = @import("std");
const builtin = @import("builtin");

const Shell = @import("./shell.zig");
const Snap = @import("./testing/snaptest.zig").Snap;
const snap = Snap.snap;
const TmpTigerBeetle = @import("./testing/tmp_tigerbeetle.zig");

// TODO(Zig): inject executable name via build.zig:
//    <https://ziggit.dev/t/how-to-write-integration-tests-for-cli-utilities/2806>
fn tigerbeetle_exe(shell: *Shell) ![]const u8 {
    const exe = comptime "tigerbeetle" ++ builtin.target.exeFileExt();
    _ = try shell.project_root.statFile(exe);
    return try shell.project_root.realpathAlloc(shell.arena.allocator(), exe);
}

test "repl integration" {
    // Context構造体を定義します。これは、シェル、TigerBeetleの実行可能ファイルへのパス、一時的なTigerBeetleインスタンスを保持します。
    const Context = struct {
        const Context = @This();

        shell: *Shell,
        tigerbeetle_exe: []const u8,
        tmp_beetle: TmpTigerBeetle,

        // Contextを初期化する関数です。
        fn init() !Context {
            const shell = try Shell.create(std.testing.allocator);
            errdefer shell.destroy();

            const tigerbeetle = try tigerbeetle_exe(shell);

            var tmp_beetle = try TmpTigerBeetle.init(std.testing.allocator, .{
                .prebuilt = tigerbeetle,
            });
            errdefer tmp_beetle.deinit(std.testing.allocator);

            return Context{
                .shell = shell,
                .tigerbeetle_exe = tigerbeetle,
                .tmp_beetle = tmp_beetle,
            };
        }

        // Contextを解放する関数です。
        fn deinit(context: *Context) void {
            context.tmp_beetle.deinit(std.testing.allocator);
            context.shell.destroy();
            context.* = undefined;
        }

        // REPLコマンドを実行し、その結果を返す関数です。
        fn repl_command(context: *Context, command: []const u8) ![]const u8 {
            return try context.shell.exec_stdout(
                \\{tigerbeetle} repl --cluster=0 --addresses={addresses} --command={command}
            , .{
                .tigerbeetle = context.tigerbeetle_exe,
                .addresses = context.tmp_beetle.port_str.slice(),
                .command = command,
            });
        }

        // コマンドの結果が期待通りであることを確認する関数です。
        fn check(context: *Context, command: []const u8, want: Snap) !void {
            const got = try context.repl_command(command);
            try want.diff(got);
        }
    };

    // Contextを初期化します。
    var context = try Context.init();
    defer context.deinit();

    // アカウントを作成し、その結果を確認します。
    try context.check(
        \\create_accounts id=1 flags=linked code=10 ledger=700, id=2 code=10 ledger=700
    , snap(@src(), ""));

    // 転送を作成し、その結果を確認します。
    try context.check(
        \\create_transfers id=1 debit_account_id=1
        \\  credit_account_id=2 amount=10 ledger=700 code=10
    , snap(@src(), ""));

    // アカウントを検索し、その結果を確認します。
    try context.check(
        \\lookup_accounts id=1
    , snap(@src(),
        \\{
        \\  "id": "1",
        \\  "debits_pending": "0",
        \\  "debits_posted": "10",
        \\  "credits_pending": "0",
        \\  "credits_posted": "0",
        \\  "user_data_128": "0",
        \\  "user_data_64": "0",
        \\  "user_data_32": "0",
        \\  "ledger": "700",
        \\  "code": "10",
        \\  "flags": ["linked"],
        \\  "timestamp": "<snap:ignore>"
        \\}
        \\
    ));

    // 別のアカウントを検索し、その結果を確認します。
    try context.check(
        \\lookup_accounts id=2
    , snap(@src(),
        \\{
        \\  "id": "2",
        \\  "debits_pending": "0",
        \\  "debits_posted": "0",
        \\  "credits_pending": "0",
        \\  "credits_posted": "10",
        \\  "user_data_128": "0",
        \\  "user_data_64": "0",
        \\  "user_data_32": "0",
        \\  "ledger": "700",
        \\  "code": "10",
        \\  "flags": [],
        \\  "timestamp": "<snap:ignore>"
        \\}
        \\
    ));

    // 転送を検索し、その結果を確認します。
    try context.check(
        \\lookup_transfers id=1
    , snap(@src(),
        \\{
        \\  "id": "1",
        \\  "debit_account_id": "1",
        \\  "credit_account_id": "2",
        \\  "amount": "10",
        \\  "pending_id": "0",
        \\  "user_data_128": "0",
        \\  "user_data_64": "0",
        \\  "user_data_32": "0",
        \\  "timeout": "0",
        \\  "ledger": "700",
        \\  "code": "10",
        \\  "flags": [],
        \\  "timestamp": "<snap:ignore>"
        \\}
        \\
    ));
}

test "benchmark smoke" {
    // このテストは、TigerBeetleのベンチマーク機能を検証します。
    // 4000回の転送を行うベンチマークを実行し、その結果が成功（ステータスOK）であることを確認します。

    // Shellを作成します。これは、システムコマンドを実行するためのツールです。
    const shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    // TigerBeetleの実行可能ファイルへのパスを取得します。
    const tigerbeetle = try tigerbeetle_exe(shell);

    // ベンチマークを実行します。ここでは、4000回の転送を行います。
    const status_ok = try shell.exec_status_ok(
        "{tigerbeetle} benchmark --transfer-count=4000",
        .{ .tigerbeetle = tigerbeetle },
    );

    // ベンチマークの結果が成功（ステータスOK）であることを確認します。
    try std.testing.expect(status_ok);
}
