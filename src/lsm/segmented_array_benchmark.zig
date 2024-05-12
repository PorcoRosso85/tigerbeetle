const std = @import("std");
const assert = std.debug.assert;

const constants = @import("../constants.zig");
const NodePoolType = @import("node_pool.zig").NodePool;
const table_count_max_for_level = @import("tree.zig").table_count_max_for_level;
const table_count_max_for_tree = @import("tree.zig").table_count_max_for_tree;
const SortedSegmentedArray = @import("segmented_array.zig").SortedSegmentedArray;

const log = std.log;

// Bump this up if you want to use this as a real benchmark rather than as a test.
const samples = 5_000;

const Options = struct {
    Key: type,
    value_size: u32,
    value_count: u32,
    node_size: u32,
};

// Benchmark 112B values to match `@sizeOf(TableInfo)`, which is either 112B or 80B depending on
// the Key type.
const configs = [_]Options{
    Options{ .Key = u64, .value_size = 112, .value_count = 33, .node_size = 256 },
    Options{ .Key = u64, .value_size = 112, .value_count = 34, .node_size = 256 },
    Options{ .Key = u64, .value_size = 112, .value_count = 1024, .node_size = 256 },
    Options{ .Key = u64, .value_size = 112, .value_count = 1024, .node_size = 512 },

    Options{
        .Key = u64,
        .value_size = 112,
        .value_count = table_count_max_for_level(constants.lsm_growth_factor, 1),
        .node_size = constants.lsm_manifest_node_size,
    },
    Options{
        .Key = u64,
        .value_size = 112,
        .value_count = table_count_max_for_level(constants.lsm_growth_factor, 2),
        .node_size = constants.lsm_manifest_node_size,
    },
    Options{
        .Key = u64,
        .value_size = 112,
        .value_count = table_count_max_for_level(constants.lsm_growth_factor, 3),
        .node_size = constants.lsm_manifest_node_size,
    },
    Options{
        .Key = u64,
        .value_size = 112,
        .value_count = table_count_max_for_level(constants.lsm_growth_factor, 4),
        .node_size = constants.lsm_manifest_node_size,
    },
    Options{
        .Key = u64,
        .value_size = 112,
        .value_count = table_count_max_for_level(constants.lsm_growth_factor, 5),
        .node_size = constants.lsm_manifest_node_size,
    },
    Options{
        .Key = u64,
        .value_size = 112,
        .value_count = table_count_max_for_level(constants.lsm_growth_factor, 6),
        .node_size = constants.lsm_manifest_node_size,
    },
};

test "benchmark: segmented array" {
    // このテストは、セグメンテッド配列のベンチマークを行います。
    // セグメンテッド配列は、データを一定のサイズのセグメントに分割して格納するデータ構造です。
    // このテストでは、異なる設定でセグメンテッド配列を作成し、そのパフォーマンスを測定します。
    //
    // 乱数生成器の初期化
    var prng = std.rand.DefaultPrng.init(42);

    // 設定の配列をループして、各設定でテストを実行
    inline for (configs) |options| {
        // キーと値の型を設定
        const Key = options.Key;
        const Value = struct {
            key: Key,
            padding: [options.value_size - @sizeOf(Key)]u8,
        };

        // ノードプールとセグメンテッド配列の型を設定
        const NodePool = NodePoolType(options.node_size, @alignOf(Value));
        const SegmentedArray = SortedSegmentedArray(
            Value,
            NodePool,
            // Must be max of both to avoid hitting SegmentedArray's assertion:
            //   assert(element_count_max > node_capacity);
            comptime @max(
                options.value_count,
                @divFloor(options.node_size, @sizeOf(Key)) + 1,
            ),
            Key,
            struct {
                inline fn key_from_value(value: *const Value) Key {
                    return value.key;
                }
            }.key_from_value,
            .{ .verify = false },
        );

        // メモリアロケータの初期化
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // ノードプールとセグメンテッド配列の初期化
        var node_pool = try NodePool.init(allocator, SegmentedArray.node_count_max);
        defer node_pool.deinit(allocator);
        var array = try SegmentedArray.init(allocator);
        defer array.deinit(allocator, &node_pool);

        // セグメンテッド配列にランダムな値を挿入
        var i: usize = 0;
        while (i < options.value_count) : (i += 1) {
            _ = array.insert_element(&node_pool, .{
                .key = prng.random().uintLessThanBiased(u64, options.value_count),
                .padding = [_]u8{0} ** (options.value_size - @sizeOf(Key)),
            });
        }

        // クエリの配列をシャッフルして生成
        const queries = try alloc_shuffled_index(allocator, options.value_count, prng.random());
        defer allocator.free(queries);

        // タイマーの開始と繰り返し回数の設定
        var timer = try std.time.Timer.start();
        const repetitions = @max(1, @divFloor(samples, queries.len));

        // 各クエリに対して検索を行い、結果を最適化から保護
        var j: usize = 0;
        while (j < repetitions) : (j += 1) {
            for (queries) |query| {
                std.mem.doNotOptimizeAway(array.absolute_index_for_cursor(array.search(query)));
            }
        }

        // 経過時間の計測とログ出力
        const time = timer.read() / repetitions / queries.len;
        log.info("KeyType={} ValueCount={:_>7} ValueSize={:_>2}B NodeSize={:_>6}B LookupTime={:_>6}ns", .{
            options.Key,
            options.value_count,
            options.value_size,
            options.node_size,
            time,
        });
    }
}

// shuffle([0,1,…,n-1])
fn alloc_shuffled_index(allocator: std.mem.Allocator, n: usize, rand: std.rand.Random) ![]usize {
    // Allocate on the heap; the array may be too large to fit on the stack.
    var indices = try allocator.alloc(usize, n);
    for (indices, 0..) |*i, j| i.* = j;
    rand.shuffle(usize, indices[0..]);
    return indices;
}
