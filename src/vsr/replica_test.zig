const std = @import("std");
const assert = std.debug.assert;
const maybe = stdx.maybe;
const log = std.log.scoped(.test_replica);
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expectEqual;
const allocator = std.testing.allocator;

const stdx = @import("../stdx.zig");
const constants = @import("../constants.zig");
const vsr = @import("../vsr.zig");
const Process = @import("../testing/cluster/message_bus.zig").Process;
const Message = @import("../message_pool.zig").MessagePool.Message;
const parse_table = @import("../testing/table.zig").parse;
const marks = @import("../testing/marks.zig");
const StateMachineType = @import("../testing/state_machine.zig").StateMachineType;
const Cluster = @import("../testing/cluster.zig").ClusterType(StateMachineType);
const ReplicaHealth = @import("../testing/cluster.zig").ReplicaHealth;
const LinkFilter = @import("../testing/cluster/network.zig").LinkFilter;
const Network = @import("../testing/cluster/network.zig").Network;
const Storage = @import("../testing/storage.zig").Storage;

const slot_count = constants.journal_slot_count;
const checkpoint_1 = vsr.Checkpoint.checkpoint_after(0);
const checkpoint_2 = vsr.Checkpoint.checkpoint_after(checkpoint_1);
const checkpoint_3 = vsr.Checkpoint.checkpoint_after(checkpoint_2);
const checkpoint_1_trigger = vsr.Checkpoint.trigger_for_checkpoint(checkpoint_1).?;
const checkpoint_2_trigger = vsr.Checkpoint.trigger_for_checkpoint(checkpoint_2).?;
const checkpoint_3_trigger = vsr.Checkpoint.trigger_for_checkpoint(checkpoint_3).?;
const checkpoint_1_prepare_max = vsr.Checkpoint.prepare_max_for_checkpoint(checkpoint_1).?;
const checkpoint_2_prepare_max = vsr.Checkpoint.prepare_max_for_checkpoint(checkpoint_2).?;
const checkpoint_3_prepare_max = vsr.Checkpoint.prepare_max_for_checkpoint(checkpoint_3).?;
const log_level = std.log.Level.err;

const releases = .{
    .{
        .release = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 1 }),
        .release_client_min = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 1 }),
    },
    .{
        .release = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 2 }),
        .release_client_min = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 1 }),
    },
    .{
        .release = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 3 }),
        .release_client_min = vsr.Release.from(.{ .major = 0, .minor = 0, .patch = 1 }),
    },
};

// TODO Test client eviction once it no longer triggers a client panic.
// TODO Detect when cluster has stabilized and stop run() early, rather than just running for a
//      fixed number of ticks.
// TODO (Maybe:) Lazy-enable (begin ticks) for clients, so that clients don't register via ping,
//      causing unexpected/unaccounted-for commits. Maybe also don't tick clients at all during
//      run(), so that new requests cannot be added "unexpectedly". (This will remove the need for
//      the boilerplate c.request(20) == 20 at the beginning of most tests).

comptime {
    // The tests are written for these configuration values in particular.
    assert(constants.journal_slot_count == 32);
    assert(constants.lsm_batch_multiple == 4);
}

test "Cluster: recovery: WAL prepare corruption (R=3, corrupt right of head)" {
    // Write-Ahead Logging (WAL) の準備段階でのデータ破損が発生した場合に、クラスタが正しくリカバリできることを確認しています。
    // 具体的には、3つのレプリカ（R=3）があり、ヘッドの右側が破損している状況をシミュレートしています。
    //
    // テストコンテキストを初期化します。このテストでは、レプリカの数を3に設定しています。
    // クラスタのすべてのクライアントに対してリクエストを行います。このリクエストは、20バイトのデータを20回送信します。
    // レプリカを停止し、WALの準備段階でデータ破損をシミュレートします。このテストでは、レプリカ0のWAL準備段階で22バイトのデータが破損しているとします。
    // レプリカ0を開き、そのステータスがrecovering_head（ヘッドのリカバリ中）であることを確認します。これは、データ破損が発生したためにレプリカ0がリカバリモードに入っていることを示しています。
    // レプリカ1を開き、再度リクエストを行います。このリクエストは、24バイトのデータを20回送信します。
    // 最後のレプリカ（レプリカ2）を開き、再度リクエストを行います。このリクエストは、24バイトのデータを24回送信します。
    // 最後に、すべてのレプリカが24バイトのデータをコミット（永続化）していることを確認します。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    t.replica(.R_).stop();
    t.replica(.R0).corrupt(.{ .wal_prepare = 22 });

    // 2/3 can't commit when 1/2 is status=recovering_head.
    try t.replica(.R0).open();
    try expectEqual(t.replica(.R0).status(), .recovering_head);
    try t.replica(.R1).open();
    try c.request(24, 20);
    // With the aid of the last replica, the cluster can recover.
    try t.replica(.R2).open();
    try c.request(24, 24);
    try expectEqual(t.replica(.R_).commit(), 24);
}

test "Cluster: recovery: WAL prepare corruption (R=3, corrupt left of head, 3/3 corrupt)" {
    // Write-Ahead Logging (WAL) の準備段階でのデータ破損が発生した場合に、クラスタが正しくリカバリできることを確認しています。
    // ただし、すべてのWALが同じ準備を失った場合、クラスタは回復できないことも示しています。
    // 具体的には、3つのレプリカ（R=3）があり、ヘッドの左側が破損している状況をシミュレートしています。
    //
    // テストコンテキストを初期化します。このテストでは、レプリカの数を3に設定しています。
    // クラスタのすべてのクライアントに対してリクエストを行います。このリクエストは、20バイトのデータを20回送信します。
    // レプリカを停止し、WALの準備段階でデータ破損をシミュレートします。このテストでは、レプリカのWAL準備段階で10バイトのデータが破損しているとします。
    // レプリカを開き、そのステータスがview_change（ビューの変更）であることを確認します。これは、データ破損が発生したためにレプリカがビューの変更モードに入っていることを示しています。
    // 最後に、レプリカがデータをコミット（永続化）していないことを確認します。これは、すべてのWALが同じ準備を失っているため、クラスタは回復できないことを示しています。

    // The replicas recognize that the corrupt entry is outside of the pipeline and
    // must be committed.
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    t.replica(.R_).stop();
    t.replica(.R_).corrupt(.{ .wal_prepare = 10 });
    try t.replica(.R_).open();
    t.run();

    // The same prepare is lost by all WALs, so the cluster can never recover.
    // Each replica stalls trying to repair the header break.
    try expectEqual(t.replica(.R_).status(), .view_change);
    try expectEqual(t.replica(.R_).commit(), 0);
}

test "Cluster: recovery: WAL prepare corruption (R=3, corrupt root)" {
    // Write-Ahead Logging (WAL) の準備段階でルートが破損した場合に、レプリカが正しくリカバリできることを確認しています。
    // ルートとは最初のないし基準となるWALのエントリのこと
    // 具体的には、3つのレプリカ（R=3）があり、ルートが破損している状況をシミュレートしています。

    // テストコンテキストを初期化します。このテストでは、レプリカの数を3に設定しています。
    // クラスタのすべてのクライアントに対してリクエストを行います。このリクエストは、20バイトのデータを20回送信します。
    // レプリカ0を停止し、WALの準備段階でルートを破損させます。このテストでは、レプリカ0のWAL準備段階でルートが破損しているとします。
    // レプリカ0を開きます。
    // 再度リクエストを行います。このリクエストは、21バイトのデータを21回送信します。
    // 最後に、レプリカが21バイトのデータをコミット（永続化）していることを確認します。

    // A replica can recover from a corrupt root prepare.
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    t.replica(.R0).stop();
    t.replica(.R0).corrupt(.{ .wal_prepare = 0 });
    try t.replica(.R0).open();

    try c.request(21, 21);
    try expectEqual(t.replica(.R_).commit(), 21);
}

test "Cluster: recovery: WAL prepare corruption (R=3, corrupt checkpoint…head)" {
    // Write-Ahead Logging (WAL) の準備段階でチェックポイントとそれに続くすべての操作が破損した場合に、クラスタが正しくリカバリできることを確認しています。
    // 具体的には、3つのレプリカ（R=3）があり、チェックポイントとそれに続くヘッドが破損している状況をシミュレートしています。

    // テストコンテキストを初期化します。このテストでは、レプリカの数を3に設定しています。
    // クラスタのすべてのクライアントに対してリクエストを行います。このリクエストは、最初のチェックポイントをトリガーします。
    // レプリカ0を停止し、WALの準備段階でチェックポイントとそれに続くすべての操作を破損させます。
    // レプリカ0を開き、そのステータスがrecovering_head（ヘッドのリカバリ中）であることを確認します。これは、データ破損が発生したためにレプリカ0がリカバリモードに入っていることを示しています。
    // 再度リクエストを行い、レプリカ0のステータスがnormal（正常）に戻ったことを確認します。
    // レプリカ1を停止し、再度リクエストを行います。

    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(0, t.cluster.clients.len);
    // Trigger the first checkpoint.
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    t.replica(.R0).stop();

    // Corrupt op_checkpoint (27) and all ops that follow.
    var slot: usize = slot_count - constants.lsm_batch_multiple - 1;
    while (slot < slot_count) : (slot += 1) {
        t.replica(.R0).corrupt(.{ .wal_prepare = slot });
    }
    try t.replica(.R0).open();
    try expectEqual(t.replica(.R0).status(), .recovering_head);

    try c.request(slot_count, slot_count);
    try expectEqual(t.replica(.R0).status(), .normal);
    t.replica(.R1).stop();
    try c.request(slot_count + 1, slot_count + 1);
}

test "Cluster: recovery: WAL prepare corruption (R=1, corrupt between checkpoint and head)" {
    // Write-Ahead Logging (WAL) の準備段階でチェックポイントとヘッドの間が破損した場合に、レプリカが正しくリカバリできることを確認しています。
    // 具体的には、1つのレプリカ（R=1）があり、チェックポイントとヘッドの間が破損している状況をシミュレートしています。
    // ただし、このテストではレプリカの数が1つだけなので、WALが破損するとリカバリは不可能となります。

    // テストコンテキストを初期化します。このテストでは、レプリカの数を1に設定しています。
    // クラスタのすべてのクライアントに対してリクエストを行います。このリクエストは、20バイトのデータを20回送信します。
    // レプリカ0を停止し、WALの準備段階でチェックポイントとヘッドの間を破損させます。このテストでは、レプリカ0のWAL準備段階で15バイトのデータが破損しているとします。
    // レプリカ0を開きます。しかし、WALが破損しているため、開くことはできません。そのため、エラーWALCorruptが発生します。

    //
    // R=1 can never recover if a WAL-prepare is corrupt.
    const t = try TestContext.init(.{ .replica_count = 1 });
    defer t.deinit();

    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    t.replica(.R0).stop();
    t.replica(.R0).corrupt(.{ .wal_prepare = 15 });
    if (t.replica(.R0).open()) {
        unreachable;
    } else |err| switch (err) {
        error.WALCorrupt => {},
        else => unreachable,
    }
}

test "Cluster: recovery: WAL header corruption (R=1)" {
    // Write-Ahead Logging (WAL) のヘッダーが破損した場合に、レプリカが正しくリカバリできることを確認しています。
    // 具体的には、1つのレプリカ（R=1）があり、WALヘッダーが破損している状況をシミュレートしています。
    // ただし、このテストではレプリカの数が1つだけなので、WALヘッダーが破損してもレプリカは自己修復できます。

    // テストコンテキストを初期化します。このテストでは、レプリカの数を1に設定しています。
    // クラスタのすべてのクライアントに対してリクエストを行います。このリクエストは、20バイトのデータを20回送信します。
    // レプリカ0を停止し、WALのヘッダーを破損させます。このテストでは、レプリカ0のWALヘッダーの15バイトを破損させています。
    // レプリカ0を開きます。WALヘッダーが破損していても、レプリカは開くことができます。
    // 再度リクエストを行います。このリクエストは、30バイトのデータを30回送信します。
    //
    // R=1 locally repairs WAL-header corruption.
    const t = try TestContext.init(.{ .replica_count = 1 });
    defer t.deinit();

    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    t.replica(.R0).stop();
    t.replica(.R0).corrupt(.{ .wal_header = 15 });
    try t.replica(.R0).open();
    try c.request(30, 30);
}

test "Cluster: recovery: WAL torn prepare, standby with intact prepare (R=1 S=1)" {
    // このテストは、 レプリカが最後の準備段階で不完全な書き込み（torn write）を見つけ、それが切り捨てられる場合のリカバリを確認しています。
    // スタンバイはその準備を受け取っています。
    // レプリカが最後の準備段階で不完全な書き込みを見つけた場合でも、適切にリカバリできることを確認しています。
    // また、スタンバイが切り捨てられた準備を破棄できることも確認しています。

    // テストコンテキストを初期化します。このテストでは、レプリカの数を1に、スタンバイの数も1に設定しています。
    // クラスタのすべてのクライアントに対してリクエストを行います。このリクエストは、20バイトのデータを20回送信します。
    // レプリカ0を停止し、WALのヘッダーを破損させます。このテストでは、レプリカ0のWALヘッダーの20バイトを破損させています。
    // レプリカ0を開きます。WALヘッダーが破損していても、レプリカは開くことができます。
    // 再度リクエストを行います。このリクエストは、30バイトのデータを30回送信します。
    // レプリカ0とスタンバイ0のコミット数が30であることを確認します。

    // R=1 recovers to find that its last prepare was a torn write, so it is truncated.
    // The standby received the prepare, though.
    //
    // R=1 handles this by incrementing its view during recovery, so that the standby can truncate
    // discard the truncated prepare.
    const t = try TestContext.init(.{
        .replica_count = 1,
        .standby_count = 1,
    });
    defer t.deinit();

    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    t.replica(.R0).stop();
    t.replica(.R0).corrupt(.{ .wal_header = 20 });
    try t.replica(.R0).open();
    try c.request(30, 30);
    try expectEqual(t.replica(.R0).commit(), 30);
    try expectEqual(t.replica(.S0).commit(), 30);
}

test "Cluster: recovery: grid corruption (disjoint)" {
    // このテストは、グリッドが破損した場合でも、レプリカが正しくリカバリできることを確認しています。
    // グリッドが破損した場合に、レプリカが正しくリカバリできることを確認しています。
    // 具体的には、3つのレプリカ（R=3）があり、グリッドが破損している状況をシミュレートしています。

    // テストコンテキストを初期化します。このテストでは、レプリカの数を3に設定しています。
    // クラスタのすべてのクライアントに対してリクエストを行います。
    // チェックポイントを設定します。これにより、レプリカは実際にグリッドを使用してリカバリを行うようになります。すべてのレプリカが同じコミットになるようにすることで、グリッド修復が失敗して状態同期にフォールバックすることがないようにします。
    // レプリカを停止します。
    // グリッド全体を破損させます。マニフェストブロックは、各レプリカがそのフォレストを開くときに修復されます。テーブルインデックス/フィルタ/データブロックは、レプリカがコミット/コンパクトするときに修復されます。
    // レプリカを開きます。
    // レプリカの状態が正常であること、コミットがチェックポイント1トリガーと一致すること、操作チェックポイントがチェックポイント1と一致することを確認します。
    // 再度リクエストを行います。
    // 操作チェックポイントがチェックポイント2と一致し、コミットがチェックポイント2トリガーと一致することを確認します。

    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(0, t.cluster.clients.len);

    // Checkpoint to ensure that the replicas will actually use the grid to recover.
    // All replicas must be at the same commit to ensure grid repair won't fail and
    // fall back to state sync.
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);

    t.replica(.R_).stop();

    // Corrupt the whole grid.
    // Manifest blocks will be repaired as each replica opens its forest.
    // Table index/filter/data blocks will be repaired as the replica commits/compacts.
    for ([_]TestReplicas{
        t.replica(.R0),
        t.replica(.R1),
        t.replica(.R2),
    }, 0..) |replica, i| {
        var address: u64 = 1 + i; // Addresses start at 1.
        while (address <= Storage.grid_blocks_max) : (address += 3) {
            // Leave every third address un-corrupt.
            // Each block exists intact on exactly one replica.
            replica.corrupt(.{ .grid_block = address + 1 });
            replica.corrupt(.{ .grid_block = address + 2 });
        }
    }

    try t.replica(.R_).open();
    t.run();

    try expectEqual(t.replica(.R_).status(), .normal);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);

    try c.request(checkpoint_2_trigger, checkpoint_2_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_2);
    try expectEqual(t.replica(.R_).commit(), checkpoint_2_trigger);
}

test "Cluster: recovery: recovering_head, outdated start view" {
    // このテストは、レプリカがリカバリモードにあるときに古いスタートビューが送信された場合でも、適切にリカバリできることを確認しています。
    // レプリカがリカバリモードにあるときに古いスタートビューが送信された場合の挙動を確認しています。

    // テストコンテキストを初期化します。このテストでは、レプリカの数を3に設定しています。
    // クラスタのすべてのクライアントに対してリクエストを行います。このリクエストは、20バイトのデータを20回送信します。
    // レプリカB1を停止し、WALのヘッダーを破損させます。このテストでは、レプリカB1のWALヘッダーの20バイトを破損させています。
    // レプリカB1を開きます。WALヘッダーが破損していても、レプリカは開くことができます。この時点で、レプリカB1はリカバリモードになります。
    // レプリカB1に対して、古いスタートビューを送信します。このスタートビューは、オペレーション20を指しています。
    // レプリカB1が正常モードに戻り、オペレーションヘッドが20であることを確認します。
    // レプリカB2からのすべてのメッセージをドロップします。
    // 再度リクエストを行います。このリクエストは、21バイトのデータを21回送信します。
    // レプリカB1を再度停止し、WALのヘッダーを再度破損させます。このテストでは、レプリカB1のWALヘッダーの21バイトを破損させています。
    // レプリカB1を再度開き、リカバリモードになっていること、およびオペレーションヘッドが20であることを確認します。
    // レプリカAを停止し、レプリカB1に対して記録されたメッセージを再生します。
    // レプリカB1が依然としてリカバリモードにあり、オペレーションヘッドが20であることを確認します。
    // レプリカB2からのすべてのメッセージを再度受け入れ、レプリカAを開き、新たなリクエストを行います。

    // 1. Wait for B1 to ok op=21.
    // 2. Restart B1 while corrupting op=21, so that it gets into a .recovering_head with op=20.
    // 3. Try make B1 forget about op=21 by delivering it an outdated .start_view with op=20.
    const t = try TestContext.init(.{
        .replica_count = 3,
    });
    defer t.deinit();

    var c = t.clients(0, t.cluster.clients.len);
    var a = t.replica(.A0);
    var b1 = t.replica(.B1);
    var b2 = t.replica(.B2);

    try c.request(20, 20);

    b1.stop();
    b1.corrupt(.{ .wal_prepare = 20 });

    try b1.open();
    try expectEqual(b1.status(), .recovering_head);
    try expectEqual(b1.op_head(), 19);

    b1.record(.A0, .incoming, .start_view);
    t.run();
    try expectEqual(b1.status(), .normal);
    try expectEqual(b1.op_head(), 20);

    b2.drop_all(.R_, .bidirectional);

    try c.request(21, 21);

    b1.stop();
    b1.corrupt(.{ .wal_prepare = 21 });

    try b1.open();
    try expectEqual(b1.status(), .recovering_head);
    try expectEqual(b1.op_head(), 20);

    const mark = marks.check("ignoring (recovering_head, nonce mismatch)");
    a.stop();
    b1.replay_recorded();
    t.run();

    try expectEqual(b1.status(), .recovering_head);
    try expectEqual(b1.op_head(), 20);

    // Should B1 erroneously accept op=20 as head, unpartitioning B2 here would lead to a data loss.
    b2.pass_all(.R_, .bidirectional);
    t.run();
    try a.open();
    try c.request(22, 22);
    try mark.expect_hit();
}

test "Cluster: recovery: recovering head: idle cluster" {
    // このテストは、クラスタがアイドル状態であるときにレプリカがリカバリモードに入った場合でも、適切にリカバリできることを確認しています。
    // クラスタがアイドル状態（つまり、新しい操作がない状態）であるときにレプリカがリカバリモードに入る場合の挙動を確認しています。

    // テストコンテキストを初期化します。このテストでは、レプリカの数を3に設定しています。
    // クラスタのすべてのクライアントに対してリクエストを行います。このリクエストは、20バイトのデータを20回送信します。
    // レプリカB1を停止します。
    // レプリカB1のWAL（Write-Ahead Log）の準備段階とヘッダーを破損させます。このテストでは、WALの準備段階とヘッダーの21バイトを破損させています。
    // レプリカB1を開きます。WALが破損していても、レプリカは開くことができます。この時点で、レプリカB1はリカバリモードになります。
    // レプリカB1の状態がリカバリモードであること、およびオペレーションヘッド（最後に完了した操作の番号）が20であることを確認します。
    // テストを実行します。これにより、クラスタがアイドル状態になります。
    // レプリカB1の状態が正常モードに戻り、オペレーションヘッドが依然として20であることを確認します。

    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(0, t.cluster.clients.len);
    var b = t.replica(.B1);

    try c.request(20, 20);

    b.stop();
    b.corrupt(.{ .wal_prepare = 21 });
    b.corrupt(.{ .wal_header = 21 });

    try b.open();
    try expectEqual(b.status(), .recovering_head);
    try expectEqual(b.op_head(), 20);

    t.run();

    try expectEqual(b.status(), .normal);
    try expectEqual(b.op_head(), 20);
}

test "Cluster: network: partition 2-1 (isolate backup, symmetric)" {
    // このテストは、バックアップ（B2）を分離した状態で、クラスタが正常に動作することを確認します。
    // B2が分離されているにもかかわらず、他のレプリカ（A0とB1）がコミットを正常に進めることが期待されます。

    // テストコンテキストを初期化します。レプリカ数は3とします。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化します。
    var c = t.clients(0, t.cluster.clients.len);
    // クライアントにリクエストを送信します。この時点では全てのレプリカが接続されています。
    try c.request(20, 20);
    // レプリカB2を分離します。これにより、B2は他のレプリカから分離され、新たなコミットを受け取ることができません。
    t.replica(.B2).drop_all(.__, .bidirectional);
    // 新たなリクエストを送信します。このリクエストは、B2が分離されているため、A0とB1のみが受け取ります。
    try c.request(30, 30);
    // A0とB1が新たなリクエストを正常にコミットしたことを確認します。
    try expectEqual(t.replica(.A0).commit(), 30);
    try expectEqual(t.replica(.B1).commit(), 30);
    // B2は分離されていたため、新たなリクエストを受け取っていないことを確認します。
    try expectEqual(t.replica(.B2).commit(), 20);
}

test "Cluster: network: partition 2-1 (isolate backup, asymmetric, send-only)" {
    // このテストは、ネットワークパーティションが発生した場合でも、分離されていないレプリカが正しく動作し、分離されたレプリカが新しい操作を処理しないことを確認しています。
    // ネットワークパーティションが発生した場合のクラスタの挙動を確認しています。
    // 具体的には、3つのレプリカ（R=3）があり、レプリカB2が他のレプリカから分離（パーティション）される状況をシミュレートしています。

    // テストコンテキストを初期化します。このテストでは、レプリカの数を3に設定しています。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを作成します。
    var c = t.clients(0, t.cluster.clients.len);

    // クライアントにリクエストを送信します。このリクエストは、20バイトのデータを20回送信します。
    try c.request(20, 20);

    // レプリカB2から他のすべてのレプリカへの通信をドロップします。これにより、レプリカB2は他のレプリカから分離されます。
    t.replica(.B2).drop_all(.__, .incoming);

    // 再度リクエストを行います。このリクエストは、30バイトのデータを30回送信します。
    try c.request(30, 30);

    // レプリカA0とレプリカB1のコミット（完了した操作の数）が30であることを確認します。これは、これらのレプリカが新しいリクエストを処理したことを示しています。
    try expectEqual(t.replica(.A0).commit(), 30);
    try expectEqual(t.replica(.B1).commit(), 30);

    // レプリカB2のコミットが20であることを確認します。これは、レプリカB2が新しいリクエストを処理していないことを示しています。
    try expectEqual(t.replica(.B2).commit(), 20);
}

test "Cluster: network: partition 2-1 (isolate backup, asymmetric, receive-only)" {
    // このテストは、ネットワークパーティションが発生した場合でも、分離されていないレプリカが正しく動作し、分離されたレプリカが新しい操作を処理しないことを確認しています。

    // テストコンテキストを初期化します。このテストでは、レプリカの数を3に設定しています。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを作成します。
    var c = t.clients(0, t.cluster.clients.len);

    // クライアントにリクエストを送信します。このリクエストは、20バイトのデータを20回送信します。
    try c.request(20, 20);

    // レプリカB2から他のすべてのレプリカへの通信をドロップします。これにより、レプリカB2は他のレプリカから分離されます。
    t.replica(.B2).drop_all(.__, .outgoing);

    // 再度リクエストを行います。このリクエストは、30バイトのデータを30回送信します。
    try c.request(30, 30);

    // レプリカA0とレプリカB1のコミット（完了した操作の数）が30であることを確認します。これは、これらのレプリカが新しいリクエストを処理したことを示しています。
    try expectEqual(t.replica(.A0).commit(), 30);
    try expectEqual(t.replica(.B1).commit(), 30);
    // B2 may commit some ops, but at some point is will likely fall behind.
    // Prepares may be reordered by the network, and if B1 receives X+1 then X,
    // it will not forward X on, as it is a "repair".
    // And B2 is partitioned, so it cannot repair its hash chain.
    // レプリカB2のコミットが20以上であることを確認します。これは、レプリカB2が新しいリクエストを処理していないことを示しています。
    try std.testing.expect(t.replica(.B2).commit() >= 20);
}

test "Cluster: network: partition 1-2 (isolate primary, symmetric)" {
    // The primary cannot communicate with either backup, but the backups can communicate with one
    // another. The backups will perform a view-change since they don't receive heartbeats.
    // プライマリはバックアップと通信できませんが、バックアップ同士は通信できます。
    // バックアップはハートビートを受信しないため、ビューチェンジを実行します。

    // テストコンテキストを初期化します。このテストでは、レプリカの数を3に設定しています。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを作成します。
    var c = t.clients(0, t.cluster.clients.len);
    // クライアントにリクエストを送信します。このリクエストは、20バイトのデータを20回送信します。
    try c.request(20, 20);

    // レプリカA0からレプリカB1への通信と、レプリカA0からレプリカB2への通信をドロップします。
    // これにより、プライマリはバックアップと通信できなくなります。
    const p = t.replica(.A0);
    p.drop_all(.B1, .bidirectional);
    p.drop_all(.B2, .bidirectional);

    // 再度リクエストを行います。このリクエストは、30バイトのデータを30回送信します。
    try c.request(30, 30);
    // プライマリのコミット（完了した操作の数）が20であることを確認します。
    try expectEqual(p.commit(), 20);
}

test "Cluster: network: partition 1-2 (isolate primary, asymmetric, send-only)" {
    // The primary can send to the backups, but not receive.
    // After a short interval of not receiving messages (specifically prepare_ok's) it will abdicate
    // by pausing heartbeats, allowing the next replica to take over as primary.
    //
    // プライマリはバックアップに送信できますが、受信はできません。
    // メッセージ（具体的には prepare_ok）を受信しない短い間隔があると、ハートビートを一時停止し、次のレプリカがプライマリとして引き継ぐことができるようにします。
    //
    // このテストは、クラスタのネットワークのパーティションをシミュレートするものです。具体的には、プライマリノードがバックアップノードにメッセージを送信できるが、受信はできない状況を再現します。一定の時間が経過すると、プライマリノードはハートビートを一時停止し、次のレプリカがプライマリとして引き継ぐことができるようになります。
    // TestContextを初期化し、テストの前準備を行います。
    // t.clientsを使用して、クラスタ内のすべてのクライアントを取得します。
    // c.request(20, 20)を呼び出して、レプリカ間でメッセージを送信します。
    // t.replica(.A0).drop_all(.B1, .incoming)とt.replica(.A0).drop_all(.B2, .incoming)を使用して、レプリカA0からレプリカB1への通信と、レプリカA0からレプリカB2への通信をドロップします。これにより、プライマリノードはバックアップノードからのメッセージを受信できなくなります。
    // c.request(30, 30)を呼び出して、再びメッセージを送信します。この時、プライマリノードはバックアップノードからのメッセージを受信できないため、一定の時間が経過するとハートビートを一時停止し、次のレプリカがプライマリとして引き継ぐことができるようになります。
    // mark.expect_hit()を使用して、"send_commit: primary abdicating"というマークがヒットすることを確認します。これにより、プライマリノードが正常に引き継がれたことを検証します。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    // レプリカA0からレプリカB1への通信と、レプリカA0からレプリカB2への通信をドロップします。
    // これにより、プライマリはバックアップからメッセージを受信できなくなります。
    t.replica(.A0).drop_all(.B1, .incoming);
    t.replica(.A0).drop_all(.B2, .incoming);
    // prepare_ok メッセージを受信しない短い間隔があると、プライマリはハートビートを一時停止し、次のレプリカがプライマリとして引き継ぐことができるようになります。
    const mark = marks.check("send_commit: primary abdicating");
    try c.request(30, 30);
    try mark.expect_hit();
    // プライマリがバックアップからメッセージを受信できない状況を再現し、prepare_ok メッセージを受信しないことを確認します。
    // この状況が一定時間続くと、プライマリはハートビートを一時停止し、次のレプリカがプライマリとして引き継ぐことができるようになります。
}

test "Cluster: network: partition 1-2 (isolate primary, asymmetric, receive-only)" {
    // The primary can receive from the backups, but not send to them.
    // The backups will perform a view-change since they don't receive heartbeats.
    //
    // プライマリはバックアップから受信できますが、送信はできません。
    // バックアップはハートビートを受信しないため、ビューチェンジを実行します。
    //
    // このテストは、クラスタのネットワークのパーティションをシミュレートするものです。具体的には、プライマリノードがバックアップノードにメッセージを送信できないが、バックアップノードはプライマリノードからメッセージを受信できる状況を再現します。プライマリノードがバックアップノードからのメッセージを受信できないため、一定の時間が経過するとハートビートを一時停止し、次のレプリカがプライマリとして引き継ぐことができるようになります。
    // このテストは、クラスタのネットワークのパーティションをシミュレートし、プライマリノードがバックアップノードにメッセージを送信できない状況を再現します。具体的には、プライマリノードがバックアップノードにメッセージを送信できないが、バックアップノードはプライマリノードからメッセージを受信できる状況を再現します。このテストでは、プライマリノードがバックアップノードからのメッセージを受信できないため、一定の時間が経過するとハートビートを一時停止し、次のレプリカがプライマリとして引き継ぐことができるようになります。

    // テストの各ステップの意義:
    // 1. TestContextを初期化し、テストの前準備を行います。
    // 2. t.clientsを使用して、クラスタ内のすべてのクライアントを取得します。
    // 3. c.request(20, 20)を呼び出して、レプリカ間でメッセージを送信します。
    // 4. t.replica(.A0).drop_all(.B1, .outgoing)とt.replica(.A0).drop_all(.B2, .outgoing)を使用して、プライマリノードからバックアップノードへのメッセージ送信をドロップします。これにより、プライマリノードはバックアップノードにメッセージを送信できなくなります。
    // 5. c.request(30, 30)を呼び出して、再びメッセージを送信します。この時、プライマリノードはバックアップノードにメッセージを送信できないため、一定の時間が経過するとハートビートを一時停止し、次のレプリカがプライマリとして引き継ぐことができるようになります。

    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    // プライマリノードからバックアップノードへのメッセージ送信をドロップします。
    t.replica(.A0).drop_all(.B1, .outgoing);
    t.replica(.A0).drop_all(.B2, .outgoing);
    // プライマリノードがバックアップノードにメッセージを送信できない状況を再現し、一定の時間が経過するとハートビートを一時停止し、次のレプリカがプライマリとして引き継ぐことができるようになることを確認します。
    try c.request(30, 30);
}

test "Cluster: network: partition client-primary (symmetric)" {
    // Clients cannot communicate with the primary, but they still request/reply via a backup.
    // このテストは、クライアントがプライマリと通信できない場合でも、バックアップ経由でリクエスト/応答が行えることを確認します。
    // レプリカ数は3とし、クライアントはプライマリとの通信が断たれた状況をシミュレートします。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);

    t.replica(.A0).drop_all(.C_, .bidirectional);
    // TODO: https://github.com/tigerbeetle/tigerbeetle/issues/444
    // try c.request(30, 30); // この行は現在コメントアウトされていますが、本来は30バイトのデータを30回リクエストすることを意図しています。
    try c.request(30, 20);
}

test "Cluster: network: partition client-primary (asymmetric, drop requests)" {
    // Primary cannot receive messages from the clients.
    // このテストは、クライアントからプライマリへのリクエストがドロップされる場合（非対称的な通信障害）でも、
    // クライアントがバックアップ経由でリクエスト/応答を行えることを確認します。
    // レプリカ数は3とし、クライアントからプライマリへのリクエストがドロップされる状況をシミュレートします。

    // プライマリはクライアントからのメッセージを受信できません。
    // レプリカ数3のテストコンテキストを初期化します。
    const t = try TestContext.init(.{ .replica_count = 3 });
    // テスト終了時にテストコンテキストを解放します。
    defer t.deinit();

    // クライアントを取得します。
    var c = t.clients(0, t.cluster.clients.len);
    // 20バイトのデータを20回リクエストします。
    try c.request(20, 20);
    // プライマリレプリカへのすべての入力通信（クライアントからのリクエスト）をドロップします。
    t.replica(.A0).drop_all(.C_, .incoming);

    // TODO: https://github.com/tigerbeetle/tigerbeetle/issues/444
    // この行は現在コメントアウトされていますが、本来は30バイトのデータを40回リクエストすることを意図しています。
    // try c.request(30, 40);
    // 代わりに、30バイトのデータを20回リクエストします。
    try c.request(30, 20);
}

test "Cluster: network: partition client-primary (asymmetric, drop replies)" {
    // Clients cannot receive replies from the primary, but they receive replies from a backup.
    //
    // このテストは、クライアントがプライマリからの応答を受け取れないが、バックアップからの応答は受け取れる状況をシミュレートします。
    // これは、ネットワークパーティションが発生した場合のシステムの挙動を確認するためのものです。

    // TestContextを初期化します。ここではレプリカ数を3としています。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを取得します。ここでは全クライアントを対象としています。
    var c = t.clients(0, t.cluster.clients.len);
    // クライアントからリクエストを送信します。ここでは20という値を送信しています。
    try c.request(20, 20);

    // レプリカA0からの全ての出力をドロップします。これにより、クライアントはプライマリからの応答を受け取れなくなります。
    t.replica(.A0).drop_all(.C_, .outgoing);
    // TODO: https://github.com/tigerbeetle/tigerbeetle/issues/444
    // try c.request(30, 30);
    // クライアントから再度リクエストを送信します。ここでは30という値を送信しています。
    try c.request(30, 20);
}

test "Cluster: repair: partition 2-1, then backup fast-forward 1 checkpoint" {
    // このテストは、2つのチェックポイントで遅れたバックアップが、ステート同期を使用せずに追いつくことができるかを確認します。

    // A backup that has fallen behind by two checkpoints can catch up, without using state sync.
    // TestContextを初期化します。ここではレプリカ数を3としています。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを取得します。ここでは全クライアントを対象としています。
    var c = t.clients(0, t.cluster.clients.len);
    // クライアントからリクエストを送信します。ここでは20という値を送信しています。
    try c.request(20, 20);
    // コミットの状態を確認します。ここでは20という値を期待しています。
    try expectEqual(t.replica(.R_).commit(), 20);

    // レプリカB2を取得します。このレプリカは後続の操作で遅延させます。
    var r_lag = t.replica(.B2);
    // レプリカB2からの全ての出力をドロップします。これにより、レプリカB2は他のレプリカとの同期を失います。
    r_lag.drop_all(.__, .bidirectional);

    // Commit enough ops to checkpoint once, and then nearly wrap around, leaving enough slack
    // that the lagging backup can repair (without state sync).
    // クライアントから再度リクエストを送信します。ここでは特定の値を送信して、チェックポイントを一度通過し、ほぼラップアラウンドするようにします。
    const commit = 20 + slot_count - constants.pipeline_prepare_queue_max;
    try c.request(commit, commit);
    // チェックポイントの状態を確認します。ここではcheckpoint_1という値を期待しています。
    try expectEqual(t.replica(.A0).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.B1).op_checkpoint(), checkpoint_1);

    // レプリカB2の状態を確認します。ここでは.normalという状態を期待しています。
    try expectEqual(r_lag.status(), .normal);
    // レプリカB2のチェックポイントの状態を確認します。ここでは0という値を期待しています。
    try expectEqual(r_lag.op_checkpoint(), 0);

    // Allow repair, but ensure that state sync doesn't run.
    // レプリカB2に対して修復を許可しますが、ステート同期が実行されないようにします。
    r_lag.pass_all(.__, .bidirectional);
    r_lag.drop(.__, .bidirectional, .sync_checkpoint);
    // テストを実行します。
    t.run();

    // レプリカの状態を確認します。ここでは.normalという状態を期待しています。
    try expectEqual(t.replica(.R_).status(), .normal);
    // レプリカのチェックポイントの状態を確認します。ここではcheckpoint_1という値を期待しています。
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);
    // コミットの状態を確認します。ここではcommitという値を期待しています。
    try expectEqual(t.replica(.R_).commit(), commit);
}

test "Cluster: repair: view-change, new-primary lagging behind checkpoint, forfeit" {
    // このテストは、新しいプライマリがチェックポイントよりも遅れている場合のビューチェンジを検証します。
    // また、遅れているバックアップが新しいプライマリのおかげで最新のチェックポイント/コミットに追いつくことも確認します。

    // TestContextを初期化します。ここではレプリカ数を3としています。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを取得します。ここでは全クライアントを対象としています。
    var c = t.clients(0, t.cluster.clients.len);
    // クライアントからリクエストを送信します。ここでは20という値を送信しています。
    try c.request(20, 20);
    // コミットの状態を確認します。ここでは20という値を期待しています。
    try expectEqual(t.replica(.R_).commit(), 20);

    // レプリカを取得します。
    var a0 = t.replica(.A0);
    var b1 = t.replica(.B1);
    var b2 = t.replica(.B2);

    // レプリカB1からの全ての出力をドロップします。これにより、レプリカB1は他のレプリカとの同期を失います。
    b1.drop_all(.__, .bidirectional);

    // クライアントから再度リクエストを送信します。ここでは特定の値を送信して、チェックポイントを一度通過するようにします。
    try c.request(checkpoint_1_prepare_max + 1, checkpoint_1_prepare_max + 1);
    // 各レプリカのチェックポイントの状態を確認します。
    try expectEqual(a0.op_checkpoint(), checkpoint_1);
    try expectEqual(b1.op_checkpoint(), 0);
    try expectEqual(b2.op_checkpoint(), checkpoint_1);
    // 各レプリカのコミットの状態を確認します。
    try expectEqual(a0.commit(), checkpoint_1_prepare_max + 1);
    try expectEqual(b1.commit(), 20);
    try expectEqual(b2.commit(), checkpoint_1_prepare_max + 1);
    // 各レプリカのop_headの状態を確認します。
    try expectEqual(a0.op_head(), checkpoint_1_prepare_max + 1);
    try expectEqual(b1.op_head(), 20);
    try expectEqual(b2.op_head(), checkpoint_1_prepare_max + 1);

    // Partition the primary, but restore B1. B1 will attempt to become the primary next,
    // but it is too far behind, so B2 becomes the new primary instead.
    // プライマリをパーティション化し、B1を復元します。B1は次にプライマリになることを試みますが、
    // 遅れているため、代わりにB2が新しいプライマリになります。
    b2.pass_all(.__, .bidirectional);
    b1.pass_all(.__, .bidirectional);
    a0.drop_all(.__, .bidirectional);

    // Block state sync to prove that B1 recovers via WAL repair.
    // Thanks to the new primary, the lagging backup is able to catch up to the latest
    // checkpoint/commit.
    // ステート同期をブロックして、B1がWAL修復を介して回復することを証明します。
    b1.drop(.__, .bidirectional, .sync_checkpoint);
    const mark = marks.check("on_do_view_change: lagging primary; forfeiting");
    // テストを実行します。
    t.run();
    // マークがヒットしたことを確認します。
    try mark.expect_hit();

    // 新しいプライマリがB2であることを確認します。
    try expectEqual(b2.role(), .primary);
    // 新しいプライマリのインデックスがA0のインデックスと一致することを確認します。
    try expectEqual(b2.index(), t.replica(.A0).index());
    // 新しいプライマリのビューがB1のビューと一致することを確認します。
    try expectEqual(b2.view(), b1.view());
    // 新しいプライマリのログビューがB1のログビューと一致することを確認します。
    try expectEqual(b2.log_view(), b1.log_view());

    // Thanks to the new primary, the lagging backup is able to catch up to the latest
    // checkpoint/commit.
    // 新しいプライマリのおかげで、遅れていたバックアップが最新のチェックポイント/コミットに追いつくことを確認します。
    try expectEqual(b1.role(), .backup);
    try expectEqual(b1.commit(), checkpoint_1_prepare_max + 1);
    try expectEqual(b1.op_checkpoint(), checkpoint_1);

    // 最終的なコミットの状態を確認します。
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_prepare_max + 1);
}

test "Cluster: repair: crash, corrupt committed pipeline op, repair it, view-change; dont nack" {
    // This scenario is also applicable when any op within the pipeline suffix is corrupted.
    // But we test by corrupting the last op to take advantage of recovering_head to learn the last
    // op's header without its prepare.
    //
    // Also, a corrupt last op maximizes uncertainty — there are no higher ops which
    // can definitively show that the last op is committed (via `header.commit`).
    // このテストは、クラスタがクラッシュし、パイプライン操作が破損し、それを修復し、ビューを変更し、nackを送らないというシナリオをテストします。
    // このシナリオは、パイプラインサフィックス内の任意の操作が破損した場合にも適用可能です。
    // しかし、最後の操作を破損させてテストすることで、その準備なしに最後の操作のヘッダーを学習するrecovering_headの利点を活用します。
    // また、最後の操作が破損すると、不確実性が最大化されます - 最後の操作がコミットされたことを明確に示すより高い操作がありません（`header.commit`を介して）。

    const t = try TestContext.init(.{
        .replica_count = 3,
        .client_count = constants.pipeline_prepare_queue_max,
    });
    defer t.deinit();

    // クライアントを初期化します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);

    // レプリカを初期化します。
    var a0 = t.replica(.A0);
    var b1 = t.replica(.B1);
    var b2 = t.replica(.B2);

    // すべての通信をドロップします。
    b2.drop_all(.R_, .bidirectional);

    // 新たなリクエストを送信します。
    try c.request(30, 30);

    // レプリカを停止し、操作を破損させます。
    b1.stop();
    b1.corrupt(.{ .wal_prepare = 30 });

    // We can't learn op=30's prepare, only its header (via start_view).
    // op=30の準備を学習できません、ヘッダーのみを学習できます（start_viewを介して）。
    b1.drop(.R_, .bidirectional, .prepare);
    try b1.open();
    try expectEqual(b1.status(), .recovering_head);
    t.run();

    // すべての通信を許可します。
    b1.pass_all(.R_, .bidirectional);
    b2.pass_all(.R_, .bidirectional);
    a0.stop();
    a0.drop_all(.R_, .outgoing);
    t.run();

    // The cluster is stuck trying to repair op=30 (requesting the prepare).
    // B2 can nack op=30, but B1 *must not*.
    // クラスタはop=30の修復を試みています（準備をリクエストしています）。
    // B2はop=30をnackできますが、B1は*絶対に*できません。
    try expectEqual(b1.status(), .view_change);
    try expectEqual(b1.commit(), 29);
    try expectEqual(b1.op_head(), 30);

    // A0 provides prepare=30.
    // A0はprepare=30を提供します。
    a0.pass_all(.R_, .outgoing);
    try a0.open();
    t.run();
    try expectEqual(t.replica(.R_).status(), .normal);
    try expectEqual(t.replica(.R_).commit(), 30);
    try expectEqual(t.replica(.R_).op_head(), 30);
}

test "Cluster: repair: corrupt reply" {
    // このテストは、クラスタが破損した応答を修復するシナリオをテストします。
    // 主要なレプリカが保存したすべての応答が破損した場合、クライアントは応答を受け取るまでリクエストを再試行し続けます。
    // 主要なレプリカは、そのバックアップの1つから応答をリクエストします。

    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    try expectEqual(t.replica(.R_).commit(), 20);

    // Prevent any view changes, to ensure A0 repairs its corrupt prepare.
    // ビューの変更を防ぎ、A0が破損した準備を修復することを確認します。
    t.replica(.R_).drop(.R_, .bidirectional, .do_view_change);

    // Block the client from seeing the reply from the cluster.
    // クライアントがクラスタからの応答を見るのをブロックします。
    t.replica(.R_).drop(.C_, .outgoing, .reply);
    try c.request(21, 20);

    // Corrupt all of the primary's saved replies.
    // (This is easier than figuring out the reply's actual slot.)
    // 主要なレプリカの保存されたすべての応答を破損させます。
    // （これは、応答の実際のスロットを把握するよりも簡単です。）
    var slot: usize = 0;
    while (slot < constants.clients_max) : (slot += 1) {
        t.replica(.A0).corrupt(.{ .client_reply = slot });
    }

    // The client will keep retrying request 21 until it receives a reply.
    // The primary requests the reply from one of its backups.
    // (Pass A0 only to ensure that no other client forwards the reply.)
    // クライアントは、応答を受け取るまでリクエスト21を再試行し続けます。
    // 主要なレプリカは、そのバックアップの1つから応答をリクエストします。
    // （他のクライアントが応答を転送しないように、A0のみを通過させます。）
    t.replica(.A0).pass(.C_, .outgoing, .reply);
    t.run();

    try expectEqual(c.replies(), 21);
}

test "Cluster: repair: ack committed prepare" {
    // このテストは、クラスタの修復機能を検証します。特に、すでにコミットされた操作に対するackをテストします。

    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    try expectEqual(t.replica(.R_).commit(), 20);

    const p = t.replica(.A0);
    const b1 = t.replica(.B1);
    const b2 = t.replica(.B2);

    // A0 commits 21.
    // B1 prepares 21, but does not commit.
    // A0は21をコミットします。B1は21を準備しますが、コミットはしません。
    t.replica(.R_).drop(.R_, .bidirectional, .start_view_change);
    t.replica(.R_).drop(.R_, .bidirectional, .do_view_change);
    p.drop(.__, .outgoing, .commit);
    b2.drop(.__, .incoming, .prepare);
    try c.request(21, 21);
    try expectEqual(p.commit(), 21);
    try expectEqual(b1.commit(), 20);
    try expectEqual(b2.commit(), 20);

    // 各レプリカの操作ヘッドとステータスを確認します。
    try expectEqual(p.op_head(), 21);
    try expectEqual(b1.op_head(), 21);
    try expectEqual(b2.op_head(), 20);

    try expectEqual(p.status(), .normal);
    try expectEqual(b1.status(), .normal);
    try expectEqual(b2.status(), .normal);

    // Change views. B1/B2 participate. Don't allow B2 to repair op=21.
    // ビューを変更します。B1/B2が参加します。ただし、op=21の修復はB2に許可しません。
    t.replica(.R_).pass(.R_, .bidirectional, .start_view_change);
    t.replica(.R_).pass(.R_, .bidirectional, .do_view_change);
    p.drop(.__, .bidirectional, .prepare);
    p.drop(.__, .bidirectional, .do_view_change);
    p.drop(.__, .bidirectional, .start_view_change);
    t.run();
    try expectEqual(b1.commit(), 20);
    try expectEqual(b2.commit(), 20);

    // 各レプリカのステータスを再度確認します。
    try expectEqual(p.status(), .normal);
    try expectEqual(b1.status(), .normal);
    try expectEqual(b2.status(), .normal);

    // But other than that, heal A0/B1, but partition B2 completely.
    // (Prevent another view change.)
    // その他の修復を行います。A0/B1を修復しますが、B2は完全にパーティションします。
    // （別のビュー変更を防ぎます。）
    p.pass_all(.__, .bidirectional);
    b1.pass_all(.__, .bidirectional);
    b2.drop_all(.__, .bidirectional);
    t.replica(.R_).drop(.R_, .bidirectional, .start_view_change);
    t.replica(.R_).drop(.R_, .bidirectional, .do_view_change);
    t.run();

    // 各レプリカのステータスを再度確認します。
    try expectEqual(p.status(), .normal);
    try expectEqual(b1.status(), .normal);
    try expectEqual(b2.status(), .normal);

    // A0 acks op=21 even though it already committed it.
    // A0は、すでにコミットしたop=21に対してackを送信します。
    try expectEqual(p.commit(), 21);
    try expectEqual(b1.commit(), 21);
    try expectEqual(b2.commit(), 20);
}

test "Cluster: repair: primary checkpoint, backup crash before checkpoint, primary prepare" {
    // 1. Given 3 replica: A0, B1, B2.
    // 2. B2 is partitioned (for the entire scenario).
    // 3. A0 and B1 prepare and commit many messages...
    // 4. A0 commits a checkpoint trigger and checkpoints.
    // 5. B1 crashes before it can commit the trigger or checkpoint.
    // 6. A0 prepares a message.
    // 7. B1 restarts. The very first entry in its WAL is corrupt.
    // A0 has *not* already overwritten the corresponding entry in its own WAL, thanks to the
    // pipeline component of the vsr_checkpoint_interval.
    // このテストは、プライマリチェックポイントとバックアップクラッシュのシナリオを検証します。
    // プライマリがメッセージを準備した後、バックアップがチェックポイント前にクラッシュします。
    // バックアップが再起動したとき、そのWALの最初のエントリは破損しています。
    // プライマリはまだ自身のWALの対応するエントリを上書きしていません。

    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    try expectEqual(t.replica(.R_).commit(), 20);

    var p = t.replica(.A0);
    var b1 = t.replica(.B1);
    var b2 = t.replica(.B2);

    // B2 does not participate in this scenario.
    // B2はこのシナリオには参加しません。
    b2.stop();
    try c.request(checkpoint_1_trigger - 1, checkpoint_1_trigger - 1);

    // B1はコミットを受け取らず、A0はチェックポイントトリガをコミットします。
    b1.drop(.R_, .incoming, .commit);
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(p.op_checkpoint(), checkpoint_1);
    try expectEqual(b1.op_checkpoint(), 0);
    try expectEqual(p.commit(), checkpoint_1_trigger);
    try expectEqual(b1.commit(), checkpoint_1_trigger - 1);

    // B1はコミットを再開し、その後停止します。そのWALは破損します。
    b1.pass(.R_, .incoming, .commit);
    b1.stop();
    b1.corrupt(.{ .wal_prepare = 1 });
    try c.request(checkpoint_1_trigger + constants.pipeline_prepare_queue_max, checkpoint_1_trigger);
    try b1.open();
    t.run();

    // 最終的なチェックポイントとコミットの状態を確認します。
    try expectEqual(p.op_checkpoint(), checkpoint_1);
    try expectEqual(b1.op_checkpoint(), checkpoint_1);
    try expectEqual(p.commit(), checkpoint_1_trigger + constants.pipeline_prepare_queue_max);
    try expectEqual(b1.commit(), checkpoint_1_trigger + constants.pipeline_prepare_queue_max);
}

test "Cluster: view-change: DVC, 1+1/2 faulty header stall, 2+1/3 faulty header succeed" {
    // このテストは、クラスタのビューチェンジ（リーダーの変更）の挙動を検証します。
    // 特に、異常なヘッダーを持つレプリカが存在する状況を想定し、そのような状況でのビューチェンジが正常に行われることを確認します。

    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    try expectEqual(t.replica(.R_).commit(), 20);

    // レプリカR0を停止します。
    t.replica(.R0).stop();
    // 新たなリクエストを送信します。
    try c.request(24, 24);
    // レプリカR1とR2を停止します。
    t.replica(.R1).stop();
    t.replica(.R2).stop();

    // レプリカR1のWALを破損させます。
    t.replica(.R1).corrupt(.{ .wal_prepare = 22 });

    // The nack quorum size is 2.
    // The new view must determine whether op=22 is possibly committed.
    // - R0 never received op=22 (it had already crashed), so it nacks.
    // - R1 did receive op=22, but upon recovering its WAL, it was corrupt, so it cannot nack.
    // The cluster must wait form R2 before recovering.
    // レプリカR0とR1を再開します。
    try t.replica(.R0).open();
    try t.replica(.R1).open();
    // クォーラムが受け取られるのを待ちます。
    const mark = marks.check("quorum received, awaiting repair");
    t.run();
    // レプリカR0とR1の状態がビューチェンジ中であることを確認します。
    try expectEqual(t.replica(.R0).status(), .view_change);
    try expectEqual(t.replica(.R1).status(), .view_change);
    try mark.expect_hit();

    // R2 provides the missing header, allowing the view-change to succeed.
    // レプリカR2を再開し、ビューチェンジが成功するようにします。
    try t.replica(.R2).open();
    t.run();
    // レプリカの状態が正常であること、そしてコミットが正しく行われていることを確認します。
    try expectEqual(t.replica(.R_).status(), .normal);
    try expectEqual(t.replica(.R_).commit(), 24);
}

test "Cluster: view-change: DVC, 2/3 faulty header stall" {
    // このテストは、クラスタのビューチェンジ（リーダーの変更）の挙動を検証します。
    // 特に、2/3のレプリカが異常なヘッダーを持つ状況を想定し、そのような状況でのビューチェンジが正常に行われることを確認します。

    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    try expectEqual(t.replica(.R_).commit(), 20);

    // レプリカR0を停止します。
    t.replica(.R0).stop();
    // 新たなリクエストを送信します。
    try c.request(24, 24);
    // レプリカR1とR2を停止します。
    t.replica(.R1).stop();
    t.replica(.R2).stop();

    // レプリカR1とR2のWALを破損させます。
    t.replica(.R1).corrupt(.{ .wal_prepare = 22 });
    t.replica(.R2).corrupt(.{ .wal_prepare = 22 });

    // レプリカを再開します。
    try t.replica(.R_).open();
    // クォーラムが受け取られるのを待ちます。
    const mark = marks.check("quorum received, deadlocked");
    t.run();
    // レプリカの状態がビューチェンジ中であることを確認します。
    try expectEqual(t.replica(.R_).status(), .view_change);
    try mark.expect_hit();
}

test "Cluster: view-change: duel of the primaries" {
    // In a cluster of 3, one replica gets partitioned away, and the remaining two _both_ become
    // primaries (for different views). Additionally, the primary from the  higher view is
    // abdicating. The primaries should figure out that they need to view-change to a higher view.
    //
    // このテストは、クラスタ内で2つのプライマリ（リーダー）が存在する状況をシミュレートし、
    // それらがどのように高いビューへのビューチェンジを行うかを検証します。

    // クラスタを初期化します。このクラスタには3つのレプリカが含まれます。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    try expectEqual(t.replica(.R_).commit(), 20);

    // レプリカのビューと役割を確認します。
    try expectEqual(t.replica(.R_).view(), 1);
    try expectEqual(t.replica(.R1).role(), .primary);

    // レプリカR2から他のすべてのレプリカへの通信を遮断します。
    t.replica(.R2).drop_all(.R_, .bidirectional);
    // レプリカR1から他のすべてのレプリカへのcommitメッセージを遮断します。
    t.replica(.R1).drop(.R_, .outgoing, .commit);
    // 新たなリクエストを送信します。
    try c.request(21, 21);

    // 各レプリカのcommit_maxを確認します。
    try expectEqual(t.replica(.R0).commit_max(), 20);
    try expectEqual(t.replica(.R1).commit_max(), 21);
    try expectEqual(t.replica(.R2).commit_max(), 20);

    // 通信の遮断を解除し、新たに通信を遮断します。
    t.replica(.R0).pass_all(.R_, .bidirectional);
    t.replica(.R2).pass_all(.R_, .bidirectional);
    t.replica(.R1).drop_all(.R_, .bidirectional);
    t.replica(.R2).drop(.R0, .bidirectional, .prepare_ok);
    t.replica(.R2).drop(.R0, .outgoing, .do_view_change);
    t.run();

    // The stage is set: we have two primaries in different views, R2 is about to abdicate.
    // ここで、異なるビューにいる2つのプライマリが存在し、R2が退位しようとしています。
    try expectEqual(t.replica(.R1).view(), 1);
    try expectEqual(t.replica(.R1).status(), .normal);
    try expectEqual(t.replica(.R1).role(), .primary);
    try expectEqual(t.replica(.R1).commit(), 21);
    try expectEqual(t.replica(.R2).op_head(), 21);

    try expectEqual(t.replica(.R2).view(), 2);
    try expectEqual(t.replica(.R2).status(), .normal);
    try expectEqual(t.replica(.R2).role(), .primary);
    try expectEqual(t.replica(.R2).commit(), 20);
    try expectEqual(t.replica(.R2).op_head(), 21);

    // 通信の遮断を解除し、新たに通信を遮断します。
    t.replica(.R1).pass_all(.R_, .bidirectional);
    t.replica(.R2).pass_all(.R_, .bidirectional);
    t.replica(.R0).drop_all(.R_, .bidirectional);
    t.run();

    // 最終的なcommitの値を確認します。
    try expectEqual(t.replica(.R1).commit(), 21);
    try expectEqual(t.replica(.R2).commit(), 21);
}

test "Cluster: view-change: primary with dirty log" {
    // このテストは、クラスタ内のプライマリレプリカが「汚れた」ログ（つまり、破損または不完全なログエントリ）を持っている場合のビューチェンジ（リーダーシップの変更）を検証します。

    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(16, 16);
    try expectEqual(t.replica(.R_).commit(), 16);

    var a0 = t.replica(.A0);
    var b1 = t.replica(.B1);
    var b2 = t.replica(.B2);

    // Commit past the checkpoint_2_trigger to ensure that the op we will corrupt won't be found in
    // B1's pipeline cache.
    // チェックポイント_2_triggerを超えてコミットし、破損させる操作がB1のパイプラインキャッシュに存在しないことを確認します。
    const commit_max = checkpoint_2_trigger +
        constants.pipeline_prepare_queue_max +
        constants.pipeline_request_queue_max;

    // Partition B2 so that it falls behind the cluster.
    // B2を分割してクラスタから遅れさせます。
    b2.drop_all(.R_, .bidirectional);
    try c.request(commit_max, commit_max);

    // Allow B2 to join the cluster and complete state sync.
    // B2をクラスタに参加させ、状態同期を完了させます。
    b2.pass_all(.R_, .bidirectional);
    t.run();

    try expectEqual(t.replica(.R_).commit(), commit_max);
    try TestReplicas.expect_sync_done(t.replica(.R_));

    // Crash A0, and force B2 to become the primary.
    // A0をクラッシュさせ、B2をプライマリに強制します。
    a0.stop();
    b1.drop(.__, .incoming, .do_view_change);

    // B2 tries to become primary. (Don't let B1 become primary – it would not realize its
    // checkpoint entry is corrupt, which would defeat the purpose of this test).
    // B2 tries to repair (request_prepare) this corrupt op, even though it is before its
    // checkpoint. B1 discovers that this op is corrupt, and marks it as faulty.
    // B2がプライマリになろうとします。B1がプライマリにならないようにします - それはチェックポイントエントリが破損していることに気づかないでしょう、これはこのテストの目的を打ち消します。
    // B2は、この破損した操作を修復（request_prepare）しようとします、それはそのチェックポイントの前です。B1は、この操作が破損していることを発見し、それを故障とマークします。
    b1.corrupt(.{ .wal_prepare = checkpoint_2 % slot_count });
    t.run();

    // B1とB2のステータスが正常であることを確認します。
    try expectEqual(b1.status(), .normal);
    try expectEqual(b2.status(), .normal);
}

test "Cluster: view-change: nack older view" {
    // a0 prepares (but does not commit) three ops (`x`, `x + 1`, `x + 2`) at view `v`.
    // b1 prepares (but does not commit) the same ops at view `v + 1`.
    // b2 receives only `x + 2` op prepared at b1.
    // b1 gets permanently partitioned from the cluster, and a0 and b2 form a core.
    //
    // a0 and b2 and should be able to truncate all the prepared, but uncommitted ops.
    //
    // このテストは、古いビューからのnack（否定応答）を検証します。
    // 具体的には、a0がビューvで3つの操作（`x`、`x + 1`、`x + 2`）を準備（しかしコミットはしない）し、b1も同じ操作をビューv + 1で準備します。b2はb1で準備された`x + 2`操作のみを受け取ります。
    // b1がクラスタから永久に分割され、a0とb2がコアを形成します。
    // この状況下で、a0とb2は準備されたが未コミットのすべての操作を切り捨てることができるべきです。

    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger);

    var a0 = t.replica(.A0);
    var b1 = t.replica(.B1);
    var b2 = t.replica(.B2);

    // a0がプライマリであることを確認します。
    try expectEqual(a0.role(), .primary);
    // R_レプリカからすべてのメッセージをドロップします。
    t.replica(.R_).drop_all(.R_, .bidirectional);
    // 新たなリクエストを送信します。
    try c.request(checkpoint_1_trigger + 3, checkpoint_1_trigger);
    // a0の操作ヘッドが正しいことを確認します。
    try expectEqual(a0.op_head(), checkpoint_1_trigger + 3);

    // 以下の操作を通過させます：ping、pong、start_view_change、do_view_change、start_view。
    t.replica(.R_).pass(.R_, .bidirectional, .ping);
    t.replica(.R_).pass(.R_, .bidirectional, .pong);
    b1.pass(.R_, .bidirectional, .start_view_change);
    b1.pass(.R_, .incoming, .do_view_change);
    b1.pass(.R_, .outgoing, .start_view);
    // a0からすべてのメッセージをドロップします。
    a0.drop_all(.R_, .bidirectional);
    // b2にprepareメッセージを通過させます。
    b2.pass(.R_, .incoming, .prepare);
    // b2からのメッセージをフィルタリングします。
    b2.filter(.R_, .incoming, struct {
        fn drop_message(message: *Message) bool {
            const prepare = message.into(.prepare) orelse return false;
            return prepare.header.op < checkpoint_1_trigger + 3;
        }
    }.drop_message);

    // テストを実行します。
    t.run();
    // b1がプライマリであり、そのステータスが正常であることを確認します。
    try expectEqual(b1.role(), .primary);
    try expectEqual(b1.status(), .normal);

    // R_レプリカの操作ヘッドとcommit_maxが正しいことを確認します。
    try expectEqual(t.replica(.R_).op_head(), checkpoint_1_trigger + 3);
    try expectEqual(t.replica(.R_).commit_max(), checkpoint_1_trigger);

    // a0とb2からのすべてのメッセージを通過させます。
    a0.pass_all(.R_, .bidirectional);
    b2.pass_all(.R_, .bidirectional);
    // b2からのメッセージフィルタリングを解除します。
    b2.filter(.R_, .incoming, null);
    // b1からすべてのメッセージをドロップします。
    b1.drop_all(.R_, .bidirectional);

    // 新たなリクエストを送信します。
    try c.request(checkpoint_1_trigger + 3, checkpoint_1_trigger + 3);
    // b2、a0、b1のcommit_maxが正しいことを確認します。
    try expectEqual(b2.commit_max(), checkpoint_1_trigger + 3);
    try expectEqual(a0.commit_max(), checkpoint_1_trigger + 3);
    try expectEqual(b1.commit_max(), checkpoint_1_trigger);
}

test "Cluster: sync: partition, lag, sync (transition from idle)" {
    // このテストは、クラスタの同期に関連するシナリオを検証します。具体的には、クラスタが分割され、一部のレプリカが遅延し、その後同期するというシナリオです。このテストは、アイドル状態からの遷移を特に検証します。
    for ([_]u64{
        // Normal case: the cluster has committed atop the checkpoint trigger.
        // The lagging replica can learn the latest checkpoint from a commit message.
        checkpoint_2_trigger + 1,
        // Idle case: the idle cluster has not committed atop the checkpoint trigger.
        // The lagging replica is far enough behind the cluster that it can sync to the latest
        // checkpoint anyway, since it cannot possibly recover via WAL repair.
        // 通常のケース：クラスタはチェックポイントトリガの上にコミットしています。
        // 遅延しているレプリカは、コミットメッセージから最新のチェックポイントを学習することができます。
        // アイドルケース：アイドルクラスタはチェックポイントトリガの上にコミットしていません。
        // 遅延しているレプリカは、クラスタから十分に遅れているため、WAL修復を介して回復することは不可能であるため、最新のチェックポイントに同期することができます。
        checkpoint_2_trigger,
    }) |cluster_commit_max| {
        // テストの各ステップでクラスタのコミットマックスをログに記録します。
        log.info("test cluster_commit_max={}", .{cluster_commit_max});

        // テストコンテキストを初期化します。
        const t = try TestContext.init(.{ .replica_count = 3 });
        defer t.deinit();

        // クライアントを初期化し、リクエストを送信します。
        var c = t.clients(0, t.cluster.clients.len);
        try c.request(20, 20);
        // R_レプリカのコミットが正しいことを確認します。
        try expectEqual(t.replica(.R_).commit(), 20);

        // R2レプリカからすべてのメッセージをドロップします。
        t.replica(.R2).drop_all(.R_, .bidirectional);
        // 新たなリクエストを送信します。
        try c.request(cluster_commit_max, cluster_commit_max);

        // R2レプリカからのすべてのメッセージを通過させます。
        t.replica(.R2).pass_all(.R_, .bidirectional);
        // テストを実行します。
        t.run();

        // R2 catches up via state sync.
        // R2がステート同期を介して追いつくことを確認します。
        try expectEqual(t.replica(.R_).status(), .normal);
        try expectEqual(t.replica(.R_).commit(), cluster_commit_max);
        try expectEqual(t.replica(.R_).sync_status(), .idle);

        // The entire cluster is healthy and able to commit more.
        // クラスタ全体が健康で、さらにコミットできることを確認します。
        try c.request(checkpoint_3_trigger, checkpoint_3_trigger);
        try expectEqual(t.replica(.R_).status(), .normal);
        try expectEqual(t.replica(.R_).commit(), checkpoint_3_trigger);

        // グリッド同期が完了するまで待ちます。
        t.run(); // (Wait for grid sync to finish.)
        try TestReplicas.expect_sync_done(t.replica(.R_));
    }
}

test "Cluster: sync: sync, bump target, sync" {
    // このテストは、クラスタの同期に関連するシナリオを検証します。具体的には、クラスタが同期し、その後ターゲットが上がり、再度同期するというシナリオです。

    // テストコンテキストを初期化します。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(16, 16);
    // R_レプリカのコミットが正しいことを確認します。
    try expectEqual(t.replica(.R_).commit(), 16);

    // R2レプリカからすべてのメッセージをドロップします。
    t.replica(.R2).drop_all(.R_, .bidirectional);
    // 新たなリクエストを送信します。
    try c.request(checkpoint_2_trigger, checkpoint_2_trigger);

    // Allow R2 to complete SyncStage.requesting_target, but get stuck
    // during SyncStage.requesting_checkpoint.
    // R2がSyncStage.requesting_targetを完了し、SyncStage.requesting_checkpointで立ち止まることを許可します。
    t.replica(.R2).pass_all(.R_, .bidirectional);
    t.replica(.R2).drop(.R_, .outgoing, .request_sync_checkpoint);
    t.run();
    try expectEqual(t.replica(.R2).sync_status(), .requesting_checkpoint);
    try expectEqual(t.replica(.R2).sync_target_checkpoint_op(), checkpoint_2);

    // R2 discovers the newer sync target and restarts sync.
    // R2が新しい同期ターゲットを発見し、同期を再開します。
    try c.request(checkpoint_3_trigger, checkpoint_3_trigger);
    try expectEqual(t.replica(.R2).sync_status(), .requesting_checkpoint);
    try expectEqual(t.replica(.R2).sync_target_checkpoint_op(), checkpoint_3);

    // R2からの.request_sync_checkpointメッセージを通過させます。
    t.replica(.R2).pass(.R_, .bidirectional, .request_sync_checkpoint);
    t.run();

    // R_レプリカが正常であること、そしてコミットが正しく行われていることを確認します。
    try expectEqual(t.replica(.R_).status(), .normal);
    try expectEqual(t.replica(.R_).commit(), checkpoint_3_trigger);
    try expectEqual(t.replica(.R_).sync_status(), .idle);

    t.run(); // (Wait for grid sync to finish.)
    // グリッド同期が完了するまで待ちます。
    t.run();
    try TestReplicas.expect_sync_done(t.replica(.R_));
}

test "Cluster: repair: R=2 (primary checkpoints, but backup lags behind)" {
    // このテストは、クラスタの修復に関連するシナリオを検証します。具体的には、プライマリがチェックポイントを作成するが、バックアップが遅れているというシナリオです。

    // テストコンテキストを初期化します。
    const t = try TestContext.init(.{ .replica_count = 2 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(checkpoint_1_trigger - 1, checkpoint_1_trigger - 1);

    var a0 = t.replica(.A0);
    var b1 = t.replica(.B1);

    // A0 prepares the trigger op, commits it, and checkpoints.
    // B1 prepares the trigger op, but does not commit/checkpoint.
    // A0はトリガーオペレーションを準備し、それをコミットし、チェックポイントを作成します。
    // B1はトリガーオペレーションを準備しますが、コミット/チェックポイントは作成しません。
    b1.drop(.R_, .incoming, .commit); // Prevent last commit.
    try c.request(checkpoint_1_trigger, checkpoint_1_trigger);
    try expectEqual(a0.commit(), checkpoint_1_trigger);
    try expectEqual(b1.commit(), checkpoint_1_trigger - 1);
    try expectEqual(a0.op_head(), checkpoint_1_trigger);
    try expectEqual(b1.op_head(), checkpoint_1_trigger);
    try expectEqual(a0.op_checkpoint(), checkpoint_1);
    try expectEqual(b1.op_checkpoint(), 0);

    // On B1, corrupt the same slot that A0 is about to overwrite with a new prepare.
    // (B1 doesn't have any prepare in this slot, thanks to the vsr_checkpoint_interval.)
    // B1で、A0が新しい準備で上書きしようとしている同じスロットを破壊します。
    // (vsr_checkpoint_intervalのおかげで、B1にはこのスロットに準備がありません。)
    b1.stop();
    b1.pass(.R_, .incoming, .commit);
    b1.corrupt(.{ .wal_prepare = (checkpoint_1_trigger + 2) % slot_count });

    // Prepare a full pipeline of ops. Since B1 is still lagging behind, this doesn't actually
    // overwrite any entries from the previous wrap.
    // 完全なパイプラインのオペレーションを準備します。B1がまだ遅れているため、これは実際には
    // 前回のラップからのエントリを上書きしません。
    const pipeline_prepare_queue_max = constants.pipeline_prepare_queue_max;
    try c.request(checkpoint_1_trigger + pipeline_prepare_queue_max, checkpoint_1_trigger);

    try b1.open();
    t.run();

    // コミットが正しく行われていることを確認します。
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger + pipeline_prepare_queue_max);
    try expectEqual(c.replies(), checkpoint_1_trigger + pipeline_prepare_queue_max);

    // Neither replica used state sync, but it is "done" since all content is present.
    // どちらのレプリカもステート同期を使用していませんが、すべての内容が存在するため、同期は"done"となります。
    try TestReplicas.expect_sync_done(t.replica(.R_));
}

test "Cluster: sync: R=4, 2/4 ahead + idle, 2/4 lagging, sync" {
    // このテストは、クラスタの同期に関連するシナリオを検証します。具体的には、4つのレプリカのうち2つが先行しており、2つが遅れているというシナリオです。

    // テストコンテキストを初期化します。
    const t = try TestContext.init(.{ .replica_count = 4 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);
    // R_レプリカのコミットが正しいことを確認します。
    try expectEqual(t.replica(.R_).commit(), 20);

    var a0 = t.replica(.A0);
    var b1 = t.replica(.B1);
    var b2 = t.replica(.B2);
    var b3 = t.replica(.B3);

    // B2とB3を停止します。
    b2.stop();
    b3.stop();

    // 新たなリクエストを送信します。
    try c.request(checkpoint_2_trigger, checkpoint_2_trigger);
    // A0とB1のステータスが正常であることを確認します。
    try expectEqual(a0.status(), .normal);
    try expectEqual(b1.status(), .normal);

    // B2とB3を再開します。
    try b2.open();
    try b3.open();
    t.run();
    t.run();

    // R_レプリカのステータスが正常であること、そしてコミットが正しく行われていることを確認します。
    try expectEqual(t.replica(.R_).status(), .normal);
    try expectEqual(t.replica(.R_).sync_status(), .idle);
    try expectEqual(t.replica(.R_).commit(), checkpoint_2_trigger);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_2);

    // グリッド同期が完了するまで待ちます。
    try TestReplicas.expect_sync_done(t.replica(.R_));
}

// TODO: Replicas in recovering_head cannot (currently) participate in view-change, even when
// they arrived at recovering_head via state sync, not corruption+crash. As a result, it is possible
// for a 2/3 cluster to get stuck without any corruptions or crashes.
// See: https://github.com/tigerbeetle/tigerbeetle/pull/933#discussion_r1245440623,
// https://github.com/tigerbeetle/tigerbeetle/issues/1376, and `Simulator.core_missing_quorum()`.
test "Cluster: sync: view-change with lagging replica in recovering_head" {
    // このテストは、ビュー変更と遅延レプリカがrecovering_head状態にあるときのクラスタ同期を検証します。

    // テストコンテキストを初期化します。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(16, 16);
    // R_レプリカのコミットが正しいことを確認します。
    try expectEqual(t.replica(.R_).commit(), 16);

    var a0 = t.replica(.A0);
    var b1 = t.replica(.B1);
    var b2 = t.replica(.B2);

    // B2からすべての通信をドロップします。
    b2.drop_all(.R_, .bidirectional);
    // 新たなリクエストを送信します。
    try c.request(checkpoint_2_trigger, checkpoint_2_trigger);

    // Allow B2 to join, but partition A0 to force a view change.
    // B2 is lagging far enough behind that it must state sync – it will transition to
    // recovering_head. Despite this, the cluster of B1/B2 should recover to normal status.
    // B2を参加させ、A0をパーティション化してビュー変更を強制します。
    // B2は十分に遅れているため、ステート同期が必要となり、recovering_head状態に遷移します。
    // それにもかかわらず、B1/B2のクラスタは正常な状態に回復するはずです。
    b2.pass_all(.R_, .bidirectional);
    a0.drop_all(.R_, .bidirectional);

    // When B2 rejoins, it will race between:
    // - Discovering that it is lagging, and requesting a sync_checkpoint (which transitions B2 to
    //   recovering_head).
    // - Participating in a view-change with B1 (while we are still in status=normal in the original
    //   view).
    // For this test, we want the former to occur before the latter (since the latter would always
    // work).
    // B2が再参加するとき、以下の2つの状況が競合します：
    // - 遅延を発見し、sync_checkpointを要求する（これによりB2はrecovering_headに遷移します）。
    // - B1とのビュー変更に参加する（まだ元のビューでstatus=normalの状態）。
    // このテストでは、前者が後者よりも先に発生することを期待しています（後者は常に動作します）。
    b2.drop(.R_, .bidirectional, .start_view_change);
    t.run();
    b2.pass(.R_, .bidirectional, .start_view_change);
    t.run();

    // try expectEqual(b1.role(), .primary);
    // B1のステータスが正常であること、B2がrecovering_head状態であることを確認します。
    try expectEqual(b1.status(), .normal);
    try expectEqual(b2.status(), .recovering_head);
    // try expectEqual(t.replica(.R_).status(), .normal);
    // R_レプリカの同期ステータスがidleであること、B2のコミットが正しいことを確認します。
    try expectEqual(t.replica(.R_).sync_status(), .idle);
    try expectEqual(b2.commit(), checkpoint_2);
    // try expectEqual(t.replica(.R_).commit(), checkpoint_2_trigger);
    // R_レプリカのチェックポイントが正しいことを確認します。
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_2);

    // グリッド同期が完了するまで待ちます。
    // try TestReplicas.expect_sync_done(t.replica(.R_));
}

test "Cluster: sync: slightly lagging replica" {
    // Sometimes a replica must switch to state sync even if it is within journal_slot_count
    // ops from commit_max. Checkpointed ops are not repaired and might become unavailable.
    // このテストは、わずかに遅延しているレプリカが状態同期を行う必要があるシナリオを検証します。
    // ときどき、レプリカはcommit_maxからjournal_slot_count ops以内であっても状態同期に切り替える必要があります。
    // チェックポイント化されたopは修復されず、利用できなくなる可能性があります。

    // テストコンテキストを初期化します。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(checkpoint_1 - 1, checkpoint_1 - 1);

    var a0 = t.replica(.A0);
    var b1 = t.replica(.B1);
    var b2 = t.replica(.B2);

    // B2からすべての通信をドロップします。
    b2.drop_all(.R_, .bidirectional);
    // 新たなリクエストを送信します。
    try c.request(checkpoint_1_trigger + 1, checkpoint_1_trigger + 1);

    // Corrupt all copies of a checkpointed prepare.
    // チェックポイント化されたprepareのすべてのコピーを破壊します。
    a0.corrupt(.{ .wal_prepare = checkpoint_1 });
    b1.corrupt(.{ .wal_prepare = checkpoint_1 });
    // 新たなリクエストを送信します。
    try c.request(checkpoint_1_trigger + 2, checkpoint_1_trigger + 2);

    // At this point, b2 won't be able to repair WAL and must state sync.
    // この時点で、b2はWALを修復できず、状態同期を行う必要があります。
    b2.pass_all(.R_, .bidirectional);
    // 新たなリクエストを送信します。
    try c.request(checkpoint_1_trigger + 3, checkpoint_1_trigger + 3);
    // R_レプリカのコミットが正しいことを確認します。
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger + 3);
}

test "Cluster: sync: checkpoint from a newer view" {
    // B1 appends (but does not commit) prepares across a checkpoint boundary.
    // Then the cluster truncates those prepares and commits past the checkpoint trigger.
    // When B1 subsequently joins, it should state sync and truncate the log. Immediately
    // after state sync, the log doesn't connect to B1's new checkpoint.
    // このテストは、新しいビューからのチェックポイントを検証します。
    // B1はチェックポイント境界を越えて準備を追加しますが、コミットはしません。
    // その後、クラスタはこれらの準備を切り捨て、チェックポイントトリガーを超えてコミットします。
    // B1がその後参加すると、状態同期を行い、ログを切り捨てるべきです。
    // 状態同期の直後、ログはB1の新しいチェックポイントに接続しません。

    // テストコンテキストを初期化します。
    const t = try TestContext.init(.{ .replica_count = 6 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(checkpoint_1 - 1, checkpoint_1 - 1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1 - 1);

    var a0 = t.replica(.A0);
    var b1 = t.replica(.B1);

    {
        // Prevent A0 from committing, prevent any other replica from becoming a primary, and
        // only allow B1 to learn about A0 prepares.
        // A0のコミットを防ぎ、他のレプリカがプライマリになるのを防ぎ、
        // B1がA0の準備について学ぶことだけを許可します。
        // ここでは、B1が同期するように強制します。
        t.replica(.R_).drop(.R_, .incoming, .prepare);
        t.replica(.R_).drop(.R_, .incoming, .prepare_ok);
        t.replica(.R_).drop(.R_, .incoming, .start_view_change);
        b1.pass(.A0, .incoming, .prepare);
        b1.filter(.A0, .incoming, struct {
            // Force b1 to sync, rather than repair.
            fn drop_message(message: *Message) bool {
                const prepare = message.into(.prepare) orelse return false;
                return prepare.header.op == checkpoint_1;
            }
        }.drop_message);
        try c.request(checkpoint_1 + 1, checkpoint_1 - 1);
        try expectEqual(a0.op_head(), checkpoint_1 + 1);
        try expectEqual(b1.op_head(), checkpoint_1 + 1);
        try expectEqual(a0.commit(), checkpoint_1 - 1);
        try expectEqual(b1.commit(), checkpoint_1 - 1);
    }

    {
        // Make the rest of cluster prepare and commit a different sequence of prepares.
        // クラスタの残りの部分が異なるシーケンスの準備とコミットを行うようにします。
        // ここでは、A0とB1からすべての通信をドロップします。
        t.replica(.R_).pass(.R_, .incoming, .prepare);
        t.replica(.R_).pass(.R_, .incoming, .prepare_ok);
        t.replica(.R_).pass(.R_, .incoming, .start_view_change);

        a0.drop_all(.R_, .bidirectional);
        b1.drop_all(.R_, .bidirectional);
        try c.request(checkpoint_2, checkpoint_2);
    }

    {
        // Let B1 rejoin, but prevent it from jumping into view change.
        // B1を再参加させますが、ビューチェンジに飛び込むのを防ぎます。
        // ここでは、B1のビューが変更されていないことを確認します。
        b1.pass_all(.R_, .bidirectional);
        b1.drop(.R_, .bidirectional, .start_view);
        b1.drop(.R_, .incoming, .ping);
        b1.drop(.R_, .incoming, .pong);

        const b1_view_before = b1.view();
        try c.request(checkpoint_2_trigger - 1, checkpoint_2_trigger - 1);
        try expectEqual(b1_view_before, b1.view());
        try expectEqual(b1.op_checkpoint(), checkpoint_1);
        try expectEqual(b1.status(), .recovering_head);

        b1.stop();
        try b1.open();
        t.run();
        try expectEqual(b1_view_before, b1.view());
        try expectEqual(b1.op_checkpoint(), checkpoint_1);
        try expectEqual(b1.status(), .recovering_head);
    }

    // すべてのレプリカが双方向に通信を行うことを許可します。
    t.replica(.R_).pass_all(.R_, .bidirectional);
    t.run();
    try expectEqual(t.replica(.R_).commit(), checkpoint_2_trigger - 1);
}

test "Cluster: prepare beyond checkpoint trigger" {
    // このテストは、チェックポイントトリガーを超えて準備するシナリオを検証します。
    // 一時的にackをドロップすることで、リクエストは準備できますがコミットはできません。
    // また、クラスタの状態を確認する機会があるまで、チェックポイントを開始しないことを確認します。

    // テストコンテキストを初期化します。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);

    // チェックポイントトリガーの直前までリクエストを送信します。
    try c.request(checkpoint_1_trigger - 1, checkpoint_1_trigger - 1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger - 1);

    // Temporarily drop acks so that requests may prepare but not commit.
    // (And to make sure we don't start checkpointing until we have had a chance to assert the
    // cluster's state.)
    // 一時的にackをドロップして、リクエストが準備できるようにしますが、コミットはできません。
    t.replica(.R_).drop(.__, .bidirectional, .prepare_ok);

    // Prepare ops beyond the checkpoint.
    // チェックポイントを超えてopsを準備します。
    try c.request(checkpoint_1_prepare_max - 1, checkpoint_1_trigger - 1);
    try expectEqual(t.replica(.R_).op_checkpoint(), 0);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_trigger - 1);
    try expectEqual(t.replica(.R_).op_head(), checkpoint_1_prepare_max - 1);

    // ackを再度許可し、クラスタを実行します。
    t.replica(.R_).pass(.__, .bidirectional, .prepare_ok);
    t.run();
    try expectEqual(c.replies(), checkpoint_1_prepare_max - 1);
    try expectEqual(t.replica(.R_).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.R_).commit(), checkpoint_1_prepare_max - 1);
    try expectEqual(t.replica(.R_).op_head(), checkpoint_1_prepare_max - 1);
}

test "Cluster: upgrade: operation=upgrade near trigger-minus-bar" {
    // このテストは、チェックポイントトリガーの近くでのアップグレード操作を検証します。
    // チェックポイントトリガーに達したときにクラスタを即座にアップグレードできるか、
    // 最後のバーに非アップグレードリクエストがあるためにレプリカがチェックポイント1でアップグレードできず、
    // 次のチェックポイントまでパッドを進める必要があるかを確認します。
    // バーとは、バッチ処理の単位であり、バッチ処理は、データベースの操作をまとめて処理することで、 データベースのパフォーマンスを向上させるための手法です。

    const trigger_for_checkpoint = vsr.Checkpoint.trigger_for_checkpoint;
    for ([_]struct {
        request: u64,
        checkpoint: u64,
    }{
        .{
            // The entire last bar before the operation is free for operation=upgrade's, so when we
            // hit the checkpoint trigger we can immediately upgrade the cluster.
            // チェックポイントトリガーに達したときにクラスタを即座にアップグレードできるシナリオを設定します。
            .request = checkpoint_1_trigger - constants.lsm_batch_multiple,
            .checkpoint = checkpoint_1,
        },
        .{
            // Since there is a non-upgrade request in the last bar, the replica cannot upgrade
            // during checkpoint_1 and must pad ahead to the next checkpoint.
            // レプリカがチェックポイント1でアップグレードできず、次のチェックポイントまでパッドを進める必要があるシナリオを設定します。
            .request = checkpoint_1_trigger - constants.lsm_batch_multiple + 1,
            .checkpoint = checkpoint_2,
        },
    }) |data| {
        // テストコンテキストを初期化します。
        const t = try TestContext.init(.{ .replica_count = 3 });
        defer t.deinit();

        // クライアントを初期化し、リクエストを送信します。
        var c = t.clients(0, t.cluster.clients.len);
        try c.request(data.request, data.request);

        // レプリカを停止し、アップグレードを開始します。
        t.replica(.R_).stop();
        try t.replica(.R_).open_upgrade(&[_]u8{ 1, 2 });

        // Prevent the upgrade from committing so that we can verify that the replica is still
        // running version 1.
        // アップグレードがコミットされるのを防ぎ、レプリカがまだバージョン1を実行していることを確認します。
        t.replica(.R_).drop(.__, .bidirectional, .prepare_ok);
        t.run();
        try expectEqual(t.replica(.R_).op_checkpoint(), 0);
        try expectEqual(t.replica(.R_).release(), 1);

        // アップグレードを許可し、クラスタを実行します。
        t.replica(.R_).pass(.__, .bidirectional, .prepare_ok);
        t.run();
        try expectEqual(t.replica(.R_).release(), 2);
        try expectEqual(t.replica(.R_).op_checkpoint(), data.checkpoint);
        try expectEqual(t.replica(.R_).commit(), trigger_for_checkpoint(data.checkpoint).?);
        try expectEqual(t.replica(.R_).op_head(), trigger_for_checkpoint(data.checkpoint).?);

        // Verify that the upgraded cluster is healthy; i.e. that it can commit.
        // アップグレードされたクラスタが健康であることを確認します。つまり、コミットできることを確認します。
        try c.request(data.request + 1, data.request + 1);
    }
}

test "Cluster: upgrade: R=1" {
    // R=1 clusters upgrade even though they don't build a quorum of upgrade targets.
    // このテストは、アップグレードターゲットのクォーラムを構築しない場合でもR=1クラスタがアップグレードできることを検証します。
    // クォーラムとは、分散システムにおいて、データの整合性を保つために必要な最小限のノード数のことです。
    // R=1クラスタは、単一のレプリカを持つクラスタで、アップグレードプロセスが正常に機能することを確認します。

    // テストコンテキストを初期化します。レプリカ数は1です。
    const t = try TestContext.init(.{ .replica_count = 1 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);

    // レプリカを停止し、アップグレードを開始します。
    t.replica(.R_).stop();
    try t.replica(.R0).open_upgrade(&[_]u8{ 1, 2 });
    t.run();

    // レプリカの健康状態、リリースバージョン、チェックポイント、コミットを確認します。
    try expectEqual(t.replica(.R0).health(), .up);
    try expectEqual(t.replica(.R0).release(), 2);
    try expectEqual(t.replica(.R0).op_checkpoint(), checkpoint_1);
    try expectEqual(t.replica(.R0).commit(), checkpoint_1_trigger);
}

test "Cluster: upgrade: state-sync to new release" {
    // このテストは、新しいリリースへの状態同期を検証します。
    // 3つのレプリカを持つクラスタで、2つのレプリカがアップグレードされ、残りの1つが新しいリリースに状態同期するシナリオをテストします。

    // テストコンテキストを初期化します。レプリカ数は3です。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化し、リクエストを送信します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(20, 20);

    // レプリカを停止し、2つのレプリカに対してアップグレードを開始します。
    t.replica(.R_).stop();
    try t.replica(.R0).open_upgrade(&[_]u8{ 1, 2 });
    try t.replica(.R1).open_upgrade(&[_]u8{ 1, 2 });
    try c.request(checkpoint_2_trigger, checkpoint_2_trigger);

    // R2 state-syncs from R0/R1, updating its release from v1 to v2 via CheckpointState...
    // R2はR0/R1から状態同期を行い、リリースをv1からv2に更新します。
    try t.replica(.R2).open();
    try expectEqual(t.replica(.R2).health(), .up);
    try expectEqual(t.replica(.R2).release(), 1);
    try expectEqual(t.replica(.R2).commit(), 0);
    t.run();

    // ...But R2 doesn't have v2 available, so it shuts down.
    // しかし、R2はv2を利用できないため、シャットダウンします。
    try expectEqual(t.replica(.R2).health(), .down);
    try expectEqual(t.replica(.R2).release(), 1);
    try expectEqual(t.replica(.R2).commit(), checkpoint_2);

    // Start R2 up with v2 available, and it recovers.
    // R2をv2で利用可能な状態で起動し、リカバリーします。
    try t.replica(.R2).open_upgrade(&[_]u8{ 1, 2 });
    try expectEqual(t.replica(.R2).health(), .up);
    try expectEqual(t.replica(.R2).release(), 2);
    try expectEqual(t.replica(.R2).commit(), checkpoint_2);

    t.run();
    try expectEqual(t.replica(.R2).commit(), t.replica(.R_).commit());
}

test "Cluster: scrub: background scrubber, fully corrupt grid" {
    // このテストは、完全に破損したグリッドを持つレプリカ（B2）が、バックグラウンドスクラバーによって修復されることを確認します。
    // スクラバーとは、データの整合性を保つために使用されるプロセスのことで、データの破損を検出し、修復する役割を担います。
    const t = try TestContext.init(.{ .replica_count = 3 });
    defer t.deinit();

    // クライアントを初期化します。
    var c = t.clients(0, t.cluster.clients.len);
    try c.request(checkpoint_2_trigger, checkpoint_2_trigger);
    // レプリカのコミットを確認します。
    try expectEqual(t.replica(.R_).commit(), checkpoint_2_trigger);

    // レプリカを取得します。
    var a0 = t.replica(.A0);
    var b1 = t.replica(.B1);
    var b2 = t.replica(.B2);

    // レプリカのフリーセットとストレージを取得します。
    const a0_free_set = &t.cluster.replicas[a0.replicas.get(0)].grid.free_set;
    const b2_free_set = &t.cluster.replicas[b2.replicas.get(0)].grid.free_set;
    const b2_storage = &t.cluster.storages[b2.replicas.get(0)];

    // Corrupt B2's entire grid.
    // Note that we intentionally do *not* shut down B2 for this – the intent is to test the
    // scrubber, without leaning on Grid.read_block()'s `from_local_or_global_storage`.
    // B2の全グリッドを破壊します。
    // ここでは意図的にB2をシャットダウンせず、スクラバーのテストを行います。
    {
        var address: u64 = 1;
        while (address <= Storage.grid_blocks_max) : (address += 1) {
            b2.corrupt(.{ .grid_block = address });
        }
    }

    // Disable new read/write faults so that we can use `storage.faults` to track repairs.
    // (That is, as the scrubber runs, the number of faults will monotonically decrease.)
    // 新たな読み書きのエラーを無効にし、`storage.faults`を修復の追跡に使用します。
    b2_storage.options.read_fault_probability = 0;
    b2_storage.options.write_fault_probability = 0;

    // Tick until B2's grid repair stops making progress.
    // B2のグリッド修復が進行を停止するまでTickします。
    {
        var faults_before = b2_storage.faults.count();
        while (true) {
            t.run();

            var faults_after = b2_storage.faults.count();
            assert(faults_after <= faults_before);
            if (faults_after == faults_before) break;

            faults_before = faults_after;
        }
    }

    // Verify that B2 repaired all blocks.
    // B2がすべてのブロックを修復したことを確認します。
    var address: u64 = 1;
    while (address <= Storage.grid_blocks_max) : (address += 1) {
        if (a0_free_set.is_free(address)) {
            assert(b2_free_set.is_free(address));
            assert(b2_storage.area_faulty(.{ .grid = .{ .address = address } }));
        } else {
            assert(!b2_free_set.is_free(address));
            assert(!b2_storage.area_faulty(.{ .grid = .{ .address = address } }));
        }
    }

    // レプリカ間でグリッドが等しいことを確認します。
    try TestReplicas.expect_equal_grid(a0, b2);
    try TestReplicas.expect_equal_grid(b1, b2);
}

const ProcessSelector = enum {
    __, // all replicas, standbys, and clients
    R_, // all (non-standby) replicas
    R0,
    R1,
    R2,
    R3,
    R4,
    R5,
    S_, // all standbys
    S0,
    S1,
    S2,
    S3,
    S4,
    S5,
    A0, // current primary
    B1, // backup immediately following current primary
    B2,
    B3,
    B4,
    B5,
    C_, // all clients
};

const TestContext = struct {
    cluster: *Cluster,
    log_level: std.log.Level,
    client_requests: [constants.clients_max]usize = [_]usize{0} ** constants.clients_max,
    client_replies: [constants.clients_max]usize = [_]usize{0} ** constants.clients_max,

    pub fn init(options: struct {
        replica_count: u8,
        standby_count: u8 = 0,
        client_count: u8 = constants.clients_max,
    }) !*TestContext {
        var log_level_original = std.testing.log_level;
        std.testing.log_level = log_level;

        var prng = std.rand.DefaultPrng.init(123);
        const random = prng.random();

        const cluster = try Cluster.init(allocator, TestContext.on_client_reply, .{
            .cluster_id = 0,
            .replica_count = options.replica_count,
            .standby_count = options.standby_count,
            .client_count = options.client_count,
            .storage_size_limit = vsr.sector_floor(constants.storage_size_limit_max),
            .seed = random.int(u64),
            .releases = &releases,
            .network = .{
                .node_count = options.replica_count + options.standby_count,
                .client_count = options.client_count,
                .seed = random.int(u64),
                .one_way_delay_mean = 3 + random.uintLessThan(u16, 10),
                .one_way_delay_min = random.uintLessThan(u16, 3),

                .path_maximum_capacity = 128,
                .path_clog_duration_mean = 0,
                .path_clog_probability = 0,
                .recorded_count_max = 16,
            },
            .storage = .{
                .read_latency_min = 1,
                .read_latency_mean = 5,
                .write_latency_min = 1,
                .write_latency_mean = 5,
            },
            .storage_fault_atlas = .{
                .faulty_superblock = false,
                .faulty_wal_headers = false,
                .faulty_wal_prepares = false,
                .faulty_client_replies = false,
                .faulty_grid = false,
            },
            .state_machine = .{ .lsm_forest_node_count = 4096 },
        });
        errdefer cluster.deinit();

        for (cluster.storages) |*storage| storage.faulty = true;

        var context = try allocator.create(TestContext);
        errdefer allocator.destroy(context);

        context.* = .{
            .cluster = cluster,
            .log_level = log_level_original,
        };
        cluster.context = context;

        return context;
    }

    pub fn deinit(t: *TestContext) void {
        std.testing.log_level = t.log_level;
        t.cluster.deinit();
        allocator.destroy(t);
    }

    pub fn replica(t: *TestContext, selector: ProcessSelector) TestReplicas {
        const replica_processes = t.processes(selector);
        var replica_indexes = stdx.BoundedArray(u8, constants.members_max){};
        for (replica_processes.const_slice()) |p| replica_indexes.append_assume_capacity(p.replica);
        return TestReplicas{
            .context = t,
            .cluster = t.cluster,
            .replicas = replica_indexes,
        };
    }

    pub fn clients(t: *TestContext, index: usize, count: usize) TestClients {
        var client_indexes = stdx.BoundedArray(usize, constants.clients_max){};
        for (index..index + count) |i| client_indexes.append_assume_capacity(i);
        return TestClients{
            .context = t,
            .cluster = t.cluster,
            .clients = client_indexes,
        };
    }

    pub fn run(t: *TestContext) void {
        const tick_max = 4_100;
        var tick_count: usize = 0;
        while (tick_count < tick_max) : (tick_count += 1) {
            if (t.tick()) tick_count = 0;
        }
    }

    /// Returns whether the cluster state advanced.
    fn tick(t: *TestContext) bool {
        const commits_before = t.cluster.state_checker.commits.items.len;
        t.cluster.tick();
        return commits_before != t.cluster.state_checker.commits.items.len;
    }

    fn on_client_reply(
        cluster: *Cluster,
        client: usize,
        request: *Message.Request,
        reply: *Message.Reply,
    ) void {
        _ = request;
        _ = reply;
        const t: *TestContext = @ptrCast(@alignCast(cluster.context.?));
        t.client_replies[client] += 1;
    }

    const ProcessList = stdx.BoundedArray(Process, constants.members_max + constants.clients_max);

    fn processes(t: *const TestContext, selector: ProcessSelector) ProcessList {
        const replica_count = t.cluster.options.replica_count;

        var view: u32 = 0;
        for (t.cluster.replicas) |*r| view = @max(view, r.view);

        var array = ProcessList{};
        switch (selector) {
            .R0 => array.append_assume_capacity(.{ .replica = 0 }),
            .R1 => array.append_assume_capacity(.{ .replica = 1 }),
            .R2 => array.append_assume_capacity(.{ .replica = 2 }),
            .R3 => array.append_assume_capacity(.{ .replica = 3 }),
            .R4 => array.append_assume_capacity(.{ .replica = 4 }),
            .R5 => array.append_assume_capacity(.{ .replica = 5 }),
            .S0 => array.append_assume_capacity(.{ .replica = replica_count + 0 }),
            .S1 => array.append_assume_capacity(.{ .replica = replica_count + 1 }),
            .S2 => array.append_assume_capacity(.{ .replica = replica_count + 2 }),
            .S3 => array.append_assume_capacity(.{ .replica = replica_count + 3 }),
            .S4 => array.append_assume_capacity(.{ .replica = replica_count + 4 }),
            .S5 => array.append_assume_capacity(.{ .replica = replica_count + 5 }),
            .A0 => array.append_assume_capacity(.{ .replica = @intCast((view + 0) % replica_count) }),
            .B1 => array.append_assume_capacity(.{ .replica = @intCast((view + 1) % replica_count) }),
            .B2 => array.append_assume_capacity(.{ .replica = @intCast((view + 2) % replica_count) }),
            .B3 => array.append_assume_capacity(.{ .replica = @intCast((view + 3) % replica_count) }),
            .B4 => array.append_assume_capacity(.{ .replica = @intCast((view + 4) % replica_count) }),
            .B5 => array.append_assume_capacity(.{ .replica = @intCast((view + 5) % replica_count) }),
            .__, .R_, .S_, .C_ => {
                if (selector == .__ or selector == .R_) {
                    for (t.cluster.replicas[0..replica_count], 0..) |_, i| {
                        array.append_assume_capacity(.{ .replica = @intCast(i) });
                    }
                }
                if (selector == .__ or selector == .S_) {
                    for (t.cluster.replicas[replica_count..], 0..) |_, i| {
                        array.append_assume_capacity(.{ .replica = @intCast(replica_count + i) });
                    }
                }
                if (selector == .__ or selector == .C_) {
                    for (t.cluster.clients) |*client| {
                        array.append_assume_capacity(.{ .client = client.id });
                    }
                }
            },
        }
        assert(array.count() > 0);
        return array;
    }
};

const TestReplicas = struct {
    context: *TestContext,
    cluster: *Cluster,
    replicas: stdx.BoundedArray(u8, constants.members_max),

    pub fn stop(t: *const TestReplicas) void {
        for (t.replicas.const_slice()) |r| {
            log.info("{}: crash replica", .{r});
            t.cluster.crash_replica(r);
        }
    }

    pub fn open(t: *const TestReplicas) !void {
        for (t.replicas.const_slice()) |r| {
            log.info("{}: restart replica", .{r});
            t.cluster.restart_replica(
                r,
                t.cluster.replicas[r].releases_bundled.const_slice(),
            ) catch |err| {
                assert(t.replicas.count() == 1);
                return switch (err) {
                    error.WALCorrupt => return error.WALCorrupt,
                    error.WALInvalid => return error.WALInvalid,
                    else => @panic("unexpected error"),
                };
            };
        }
    }

    pub fn open_upgrade(t: *const TestReplicas, releases_bundled_patch: []const u8) !void {
        var releases_bundled = vsr.ReleaseList{};
        for (releases_bundled_patch) |patch| {
            releases_bundled.append_assume_capacity(vsr.Release.from(.{
                .major = 0,
                .minor = 0,
                .patch = patch,
            }));
        }

        for (t.replicas.const_slice()) |r| {
            log.info("{}: restart replica", .{r});
            t.cluster.restart_replica(r, releases_bundled.const_slice()) catch |err| {
                assert(t.replicas.count() == 1);
                return switch (err) {
                    error.WALCorrupt => return error.WALCorrupt,
                    error.WALInvalid => return error.WALInvalid,
                    else => @panic("unexpected error"),
                };
            };
        }
    }

    pub fn index(t: *const TestReplicas) u8 {
        assert(t.replicas.count() == 1);
        return t.replicas.get(0);
    }

    pub fn health(t: *const TestReplicas) ReplicaHealth {
        var value_all: ?ReplicaHealth = null;
        for (t.replicas.const_slice()) |r| {
            const value = t.cluster.replica_health[r];
            if (value_all) |all| {
                assert(all == value);
            } else {
                value_all = value;
            }
        }
        return value_all.?;
    }

    fn get(
        t: *const TestReplicas,
        comptime field: std.meta.FieldEnum(Cluster.Replica),
    ) std.meta.fieldInfo(Cluster.Replica, field).type {
        var value_all: ?std.meta.fieldInfo(Cluster.Replica, field).type = null;
        for (t.replicas.const_slice()) |r| {
            const replica = &t.cluster.replicas[r];
            const value = @field(replica, @tagName(field));
            if (value_all) |all| {
                if (all != value) {
                    for (t.replicas.const_slice()) |replica_index| {
                        log.err("replica={} field={s} value={}", .{
                            replica_index,
                            @tagName(field),
                            @field(&t.cluster.replicas[replica_index], @tagName(field)),
                        });
                    }
                    @panic("test failed: value mismatch");
                }
            } else {
                value_all = value;
            }
        }
        return value_all.?;
    }

    pub fn release(t: *const TestReplicas) u16 {
        var value_all: ?u16 = null;
        for (t.replicas.const_slice()) |r| {
            const value = t.cluster.replicas[r].release.triple().patch;
            if (value_all) |all| {
                assert(all == value);
            } else {
                value_all = value;
            }
        }
        return value_all.?;
    }

    pub fn status(t: *const TestReplicas) vsr.Status {
        return t.get(.status);
    }

    pub fn view(t: *const TestReplicas) u32 {
        return t.get(.view);
    }

    pub fn log_view(t: *const TestReplicas) u32 {
        return t.get(.log_view);
    }

    pub fn op_head(t: *const TestReplicas) u64 {
        return t.get(.op);
    }

    pub fn commit(t: *const TestReplicas) u64 {
        return t.get(.commit_min);
    }

    pub fn commit_max(t: *const TestReplicas) u64 {
        return t.get(.commit_max);
    }

    pub fn state_machine_opened(t: *const TestReplicas) bool {
        return t.get(.state_machine_opened);
    }

    fn sync_stage(t: *const TestReplicas) vsr.SyncStage {
        assert(t.replicas.count() > 0);

        var sync_stage_all: ?vsr.SyncStage = null;
        for (t.replicas.const_slice()) |r| {
            const replica = &t.cluster.replicas[r];
            if (sync_stage_all) |all| {
                assert(std.meta.eql(all, replica.syncing));
            } else {
                sync_stage_all = replica.syncing;
            }
        }
        return sync_stage_all.?;
    }

    pub fn sync_status(t: *const TestReplicas) std.meta.Tag(vsr.SyncStage) {
        return @as(std.meta.Tag(vsr.SyncStage), t.sync_stage());
    }

    fn sync_target(t: *const TestReplicas) ?vsr.SyncTarget {
        return t.sync_stage().target();
    }

    pub fn sync_target_checkpoint_op(t: *const TestReplicas) ?u64 {
        if (t.sync_target()) |target| {
            return target.checkpoint_op;
        } else {
            return null;
        }
    }

    pub fn sync_target_checkpoint_id(t: *const TestReplicas) ?u128 {
        if (t.sync_target()) |target| {
            return target.checkpoint_id;
        } else {
            return null;
        }
    }

    const Role = enum { primary, backup, standby };

    pub fn role(t: *const TestReplicas) Role {
        var role_all: ?Role = null;
        for (t.replicas.const_slice()) |r| {
            const replica = &t.cluster.replicas[r];
            const replica_role: Role = role: {
                if (replica.standby()) {
                    break :role .standby;
                } else if (replica.replica == replica.primary_index(replica.view)) {
                    break :role .primary;
                } else {
                    break :role .backup;
                }
            };
            assert(role_all == null or role_all.? == replica_role);
            role_all = replica_role;
        }
        return role_all.?;
    }

    pub fn op_checkpoint_id(t: *const TestReplicas) u128 {
        var checkpoint_id_all: ?u128 = null;
        for (t.replicas.const_slice()) |r| {
            const replica = &t.cluster.replicas[r];
            const replica_checkpoint_id = replica.superblock.working.checkpoint_id();
            assert(checkpoint_id_all == null or checkpoint_id_all.? == replica_checkpoint_id);
            checkpoint_id_all = replica_checkpoint_id;
        }
        return checkpoint_id_all.?;
    }

    pub fn op_checkpoint(t: *const TestReplicas) u64 {
        var checkpoint_all: ?u64 = null;
        for (t.replicas.const_slice()) |r| {
            const replica = &t.cluster.replicas[r];
            assert(checkpoint_all == null or checkpoint_all.? == replica.op_checkpoint());
            checkpoint_all = replica.op_checkpoint();
        }
        return checkpoint_all.?;
    }

    pub fn corrupt(
        t: *const TestReplicas,
        target: union(enum) {
            wal_header: usize, // slot
            wal_prepare: usize, // slot
            client_reply: usize, // slot
            grid_block: u64, // address
        },
    ) void {
        switch (target) {
            .wal_header => |slot| {
                const fault_offset = vsr.Zone.wal_headers.offset(slot * @sizeOf(vsr.Header));
                for (t.replicas.const_slice()) |r| {
                    t.cluster.storages[r].memory[fault_offset] +%= 1;
                }
            },
            .wal_prepare => |slot| {
                const fault_offset = vsr.Zone.wal_prepares.offset(slot * constants.message_size_max);
                const fault_sector = @divExact(fault_offset, constants.sector_size);
                for (t.replicas.const_slice()) |r| {
                    t.cluster.storages[r].faults.set(fault_sector);
                }
            },
            .client_reply => |slot| {
                const fault_offset = vsr.Zone.client_replies.offset(slot * constants.message_size_max);
                const fault_sector = @divExact(fault_offset, constants.sector_size);
                for (t.replicas.const_slice()) |r| {
                    t.cluster.storages[r].faults.set(fault_sector);
                }
            },
            .grid_block => |address| {
                const fault_offset = vsr.Zone.grid.offset((address - 1) * constants.block_size);
                const fault_sector = @divExact(fault_offset, constants.sector_size);
                for (t.replicas.const_slice()) |r| {
                    t.cluster.storages[r].faults.set(fault_sector);
                }
            },
        }
    }

    pub const LinkDirection = enum { bidirectional, incoming, outgoing };

    pub fn pass_all(t: *const TestReplicas, peer: ProcessSelector, direction: LinkDirection) void {
        const paths = t.peer_paths(peer, direction);
        for (paths.const_slice()) |path| {
            t.cluster.network.link_filter(path).* = LinkFilter.initFull();
        }
    }

    pub fn drop_all(t: *const TestReplicas, peer: ProcessSelector, direction: LinkDirection) void {
        const paths = t.peer_paths(peer, direction);
        for (paths.const_slice()) |path| t.cluster.network.link_filter(path).* = LinkFilter{};
    }

    pub fn pass(
        t: *const TestReplicas,
        peer: ProcessSelector,
        direction: LinkDirection,
        command: vsr.Command,
    ) void {
        const paths = t.peer_paths(peer, direction);
        for (paths.const_slice()) |path| t.cluster.network.link_filter(path).insert(command);
    }

    pub fn drop(
        t: *const TestReplicas,
        peer: ProcessSelector,
        direction: LinkDirection,
        command: vsr.Command,
    ) void {
        const paths = t.peer_paths(peer, direction);
        for (paths.const_slice()) |path| t.cluster.network.link_filter(path).remove(command);
    }

    pub fn filter(
        t: *const TestReplicas,
        peer: ProcessSelector,
        direction: LinkDirection,
        comptime drop_message_fn: ?fn (message: *Message) bool,
    ) void {
        const paths = t.peer_paths(peer, direction);
        for (paths.const_slice()) |path| {
            t.cluster.network.link_drop_packet_fn(path).* = if (drop_message_fn) |f|
                &struct {
                    fn drop_packet(packet: *const Network.Packet) bool {
                        return f(packet.message);
                    }
                }.drop_packet
            else
                null;
        }
    }

    pub fn record(
        t: *const TestReplicas,
        peer: ProcessSelector,
        direction: LinkDirection,
        command: vsr.Command,
    ) void {
        const paths = t.peer_paths(peer, direction);
        for (paths.const_slice()) |path| t.cluster.network.link_record(path).insert(command);
    }

    pub fn replay_recorded(
        t: *const TestReplicas,
    ) void {
        t.cluster.network.replay_recorded();
    }

    // -1: no route to self.
    const paths_max = constants.members_max * (constants.members_max - 1 + constants.clients_max);

    fn peer_paths(
        t: *const TestReplicas,
        peer: ProcessSelector,
        direction: LinkDirection,
    ) stdx.BoundedArray(Network.Path, paths_max) {
        var paths = stdx.BoundedArray(Network.Path, paths_max){};
        const peers = t.context.processes(peer);
        for (t.replicas.const_slice()) |a| {
            const process_a = Process{ .replica = a };
            for (peers.const_slice()) |process_b| {
                if (direction == .bidirectional or direction == .outgoing) {
                    paths.append_assume_capacity(.{ .source = process_a, .target = process_b });
                }
                if (direction == .bidirectional or direction == .incoming) {
                    paths.append_assume_capacity(.{ .source = process_b, .target = process_a });
                }
            }
        }
        return paths;
    }

    fn expect_sync_done(t: TestReplicas) !void {
        assert(t.replicas.count() > 0);

        for (t.replicas.const_slice()) |replica_index| {
            const replica: *const Cluster.Replica = &t.cluster.replicas[replica_index];
            assert(replica.sync_content_done());

            // If the replica has finished syncing, but not yet checkpointed, then it might not have
            // updated its sync_op_max.
            maybe(replica.superblock.staging.vsr_state.sync_op_max > 0);

            try t.cluster.storage_checker.replica_sync(&replica.superblock);
        }
    }

    fn expect_equal_grid(want: TestReplicas, got: TestReplicas) !void {
        assert(want.replicas.count() == 1);
        assert(got.replicas.count() > 0);

        const want_replica: *const Cluster.Replica = &want.cluster.replicas[want.replicas.get(0)];

        for (got.replicas.const_slice()) |replica_index| {
            const got_replica: *const Cluster.Replica = &got.cluster.replicas[replica_index];

            var address: u64 = 1;
            while (address <= Storage.grid_blocks_max) : (address += 1) {
                const address_free = want_replica.grid.free_set.is_free(address);
                assert(address_free == got_replica.grid.free_set.is_free(address));
                if (address_free) continue;

                const block_want = want_replica.superblock.storage.grid_block(address).?;
                const block_got = got_replica.superblock.storage.grid_block(address).?;

                try expectEqual(
                    std.mem.bytesToValue(vsr.Header, block_want[0..@sizeOf(vsr.Header)]),
                    std.mem.bytesToValue(vsr.Header, block_got[0..@sizeOf(vsr.Header)]),
                );
            }
        }
    }
};

const TestClients = struct {
    context: *TestContext,
    cluster: *Cluster,
    clients: stdx.BoundedArray(usize, constants.clients_max),
    requests: usize = 0,

    pub fn request(t: *TestClients, requests: usize, expect_replies: usize) !void {
        assert(t.requests <= requests);
        defer assert(t.requests == requests);

        outer: while (true) {
            for (t.clients.const_slice()) |c| {
                if (t.requests == requests) break :outer;
                t.context.client_requests[c] += 1;
                t.requests += 1;
            }
        }

        const tick_max = 3_000;
        var tick: usize = 0;
        while (tick < tick_max) : (tick += 1) {
            if (t.context.tick()) tick = 0;

            for (t.clients.const_slice()) |c| {
                const client = &t.cluster.clients[c];
                if (client.request_inflight == null and
                    t.context.client_requests[c] > client.request_number)
                {
                    const message = client.get_message();
                    errdefer client.release_message(message);

                    const body_size = 123;
                    @memset(message.buffer[@sizeOf(vsr.Header)..][0..body_size], 42);
                    t.cluster.request(c, .echo, message, body_size);
                }
            }
        }
        try std.testing.expectEqual(t.replies(), expect_replies);
    }

    pub fn replies(t: *const TestClients) usize {
        var replies_total: usize = 0;
        for (t.clients.const_slice()) |c| replies_total += t.context.client_replies[c];
        return replies_total;
    }
};
