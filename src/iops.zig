const std = @import("std");
const assert = std.debug.assert;

/// Take a u6 to limit to 64 items max (2^6 = 64)
pub fn IOPS(comptime T: type, comptime size: u6) type {
    const Map = std.StaticBitSet(size);
    return struct {
        const Self = @This();

        items: [size]T = undefined,
        /// 1 bits are free items.
        free: Map = Map.initFull(),

        pub fn acquire(self: *Self) ?*T {
            const i = self.free.findFirstSet() orelse return null;
            self.free.unset(i);
            return &self.items[i];
        }

        pub fn release(self: *Self, item: *T) void {
            item.* = undefined;
            const i = self.index(item);
            assert(!self.free.isSet(i));
            self.free.set(i);
        }

        pub fn index(self: *Self, item: *T) usize {
            const i = (@intFromPtr(item) - @intFromPtr(&self.items)) / @sizeOf(T);
            assert(i < size);
            return i;
        }

        /// Returns the count of IOPs available.
        pub fn available(self: *const Self) usize {
            return self.free.count();
        }

        /// Returns the count of IOPs in use.
        pub fn executing(self: *const Self) usize {
            return size - self.available();
        }

        pub const Iterator = struct {
            iops: *Self,
            bitset_iterator: Map.Iterator(.{ .kind = .unset }),

            pub fn next(iterator: *@This()) ?*T {
                const i = iterator.bitset_iterator.next() orelse return null;
                return &iterator.iops.items[i];
            }
        };

        pub fn iterate(self: *Self) Iterator {
            return .{
                .iops = self,
                .bitset_iterator = self.free.iterator(.{ .kind = .unset }),
            };
        }
    };
}

test "IOPS" {
    // このテストは、IOPS (Input/Output Operations Per Second) の動作を検証します。
    // IOPSは、一定時間内に行われる入出力操作の数を表します。

    const testing = std.testing;
    var iops = IOPS(u32, 4){};

    // 初期状態では、利用可能なIOPSは4で、実行中のIOPSは0であることを確認します。
    try testing.expectEqual(@as(usize, 4), iops.available());
    try testing.expectEqual(@as(usize, 0), iops.executing());

    var one = iops.acquire().?;

    // 1つのIOPSを取得した後、利用可能なIOPSは3で、実行中のIOPSは1であることを確認します。
    try testing.expectEqual(@as(usize, 3), iops.available());
    try testing.expectEqual(@as(usize, 1), iops.executing());

    var two = iops.acquire().?;
    var three = iops.acquire().?;

    // さらに2つのIOPSを取得した後、利用可能なIOPSは1で、実行中のIOPSは3であることを確認します。
    try testing.expectEqual(@as(usize, 1), iops.available());
    try testing.expectEqual(@as(usize, 3), iops.executing());

    var four = iops.acquire().?;
    // 全てのIOPSを取得した後、利用可能なIOPSは0で、実行中のIOPSは4であることを確認します。
    try testing.expectEqual(@as(?*u32, null), iops.acquire());

    try testing.expectEqual(@as(usize, 0), iops.available());
    try testing.expectEqual(@as(usize, 4), iops.executing());

    iops.release(two);

    // 1つのIOPSを解放した後、利用可能なIOPSは1で、実行中のIOPSは3であることを確認します。
    try testing.expectEqual(@as(usize, 1), iops.available());
    try testing.expectEqual(@as(usize, 3), iops.executing());

    // there is only one slot free, so we will get the same pointer back.
    // 利用可能なスロットが1つだけなので、同じポインタが返されることを確認します。
    try testing.expectEqual(@as(?*u32, two), iops.acquire());

    iops.release(four);
    iops.release(two);
    iops.release(one);
    iops.release(three);

    try testing.expectEqual(@as(usize, 4), iops.available());
    try testing.expectEqual(@as(usize, 0), iops.executing());

    one = iops.acquire().?;
    two = iops.acquire().?;
    three = iops.acquire().?;
    four = iops.acquire().?;
    try testing.expectEqual(@as(?*u32, null), iops.acquire());
}
