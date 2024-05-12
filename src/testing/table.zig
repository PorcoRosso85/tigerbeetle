const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("../stdx.zig");

/// Parse a "table" of data with the specified schema.
/// See test cases for example usage.
pub fn parse(comptime Row: type, table_string: []const u8) stdx.BoundedArray(Row, 128) {
    var rows = stdx.BoundedArray(Row, 128){};
    var row_strings = std.mem.tokenizeAny(u8, table_string, "\n");
    while (row_strings.next()) |row_string| {
        // Ignore blank line.
        if (row_string.len == 0) continue;

        var columns = std.mem.tokenizeAny(u8, row_string, " ");
        const row = parse_data(Row, &columns);
        rows.append_assume_capacity(row);

        // Ignore trailing line comment.
        if (columns.next()) |last| assert(std.mem.eql(u8, last, "//"));
    }
    return rows;
}

fn parse_data(comptime Data: type, tokens: *std.mem.TokenIterator(u8, .any)) Data {
    return switch (@typeInfo(Data)) {
        .Optional => |info| parse_data(info.child, tokens),
        .Enum => field(Data, tokens.next().?),
        .Void => assert(tokens.next() == null),
        .Bool => {
            const token = tokens.next().?;
            inline for (.{ "0", "false", "F" }) |t| {
                if (std.mem.eql(u8, token, t)) return false;
            }
            inline for (.{ "1", "true", "T" }) |t| {
                if (std.mem.eql(u8, token, t)) return true;
            }
            std.debug.panic("Unknown boolean: {s}", .{token});
        },
        .Int => |info| {
            const max = std.math.maxInt(Data);
            const token = tokens.next().?;
            // If the first character is a letter ("a-zA-Z"), ignore it. (For example, "A1" → 1).
            // This serves as a comment, to help visually disambiguate sequential integer columns.
            const offset: usize = if (std.ascii.isAlphabetic(token[0])) 1 else 0;
            // Negative unsigned values are computed relative to the maxInt.
            if (info.signedness == .unsigned and token[offset] == '-') {
                return max - (std.fmt.parseInt(Data, token[offset + 1 ..], 10) catch unreachable);
            }
            return std.fmt.parseInt(Data, token[offset..], 10) catch unreachable;
        },
        .Struct => {
            var data: Data = undefined;
            inline for (std.meta.fields(Data)) |value_field| {
                const Field = value_field.type;
                const value: Field = value: {
                    if (comptime value_field.default_value) |ptr| {
                        if (eat(tokens, "_")) {
                            const value_ptr: *const Field = @ptrCast(@alignCast(ptr));
                            break :value value_ptr.*;
                        }
                    }

                    break :value parse_data(Field, tokens);
                };

                @field(data, value_field.name) = value;
            }
            return data;
        },
        .Array => |info| {
            var values: Data = undefined;
            for (values[0..]) |*value| {
                value.* = parse_data(info.child, tokens);
            }
            return values;
        },
        .Union => |info| {
            const variant_string = tokens.next().?;
            inline for (info.fields) |variant_field| {
                if (std.mem.eql(u8, variant_field.name, variant_string)) {
                    return @unionInit(
                        Data,
                        variant_field.name,
                        parse_data(variant_field.type, tokens),
                    );
                }
            }
            std.debug.panic("Unknown union variant: {s}", .{variant_string});
        },
        else => @compileError("Unimplemented column type: " ++ @typeName(Data)),
    };
}

fn eat(tokens: *std.mem.TokenIterator(u8, .any), token: []const u8) bool {
    const index_before = tokens.index;
    if (std.mem.eql(u8, tokens.next().?, token)) return true;
    tokens.index = index_before;
    return false;
}

/// TODO This function is a workaround for a comptime bug:
///   error: unable to evaluate constant expression
///   .Enum => @field(Column, column_string),
fn field(comptime Enum: type, name: []const u8) Enum {
    inline for (std.meta.fields(Enum)) |variant| {
        if (std.mem.eql(u8, variant.name, name)) {
            return @field(Enum, variant.name);
        }
    }
    std.debug.panic("Unknown field name={s} for type={}", .{ name, Enum });
}

fn test_parse(
    comptime Row: type,
    comptime rows_expect: []const Row,
    comptime string: []const u8,
) !void {
    const rows_actual = parse(Row, string).const_slice();
    try std.testing.expectEqual(rows_expect.len, rows_actual.len);

    for (rows_expect, 0..) |row, i| {
        try std.testing.expectEqual(row, rows_actual[i]);
    }
}

test "comment" {
    // このテストは、コメントが正しくパースされることを確認します。
    // 特に、コメントがコードの実行に影響を与えず、正しく無視されることを検証します。

    // テスト対象の構造体を定義します。この構造体には1つのフィールド`a`があります。
    try test_parse(struct {
        a: u8,
    }, &.{
        // 構造体のインスタンスを作成し、フィールド`a`に値`1`を設定します。
        .{ .a = 1 },
    },
    // コメントを含むコードブロックを定義します。このコードブロックはパースの対象となります。
    // コメントはパースの結果に影響を与えないことが期待されます。
        \\
        \\ 1 // Comment
        \\
    );
}

test "enum" {
    // このテストは、列挙型が正しくパースされることを確認します。
    // 特に、列挙型の各値が正しく解析され、期待される順序で出力されることを検証します。

    // テスト対象の列挙型を定義します。この列挙型には3つの値`a`、`b`、`c`があります。
    // 列挙型のインスタンスを作成し、値を`c`、`b`、`a`の順に設定します。
    try test_parse(enum { a, b, c }, &.{ .c, .b, .a },
    // 列挙型の値を表すコードブロックを定義します。このコードブロックはパースの対象となります。
    // 値は`c`、`b`、`a`の順に記述されています。
        \\ c
        \\ b
        \\ a
    );
}

test "bool" {
    // このテストは、bool型が正しくパースされることを確認します。
    // 特に、bool型の各値（trueとfalse）が正しく解析され、期待される順序で出力されることを検証します。

    // テスト対象の構造体を定義します。この構造体には1つのフィールド`i`があります。
    // 構造体のインスタンスを作成し、フィールド`i`に値を設定します。
    // 値は`false`、`true`の順に交互に設定されています。
    try test_parse(struct { i: bool }, &.{
        .{ .i = false },
        .{ .i = true },
        .{ .i = false },
        .{ .i = true },
        .{ .i = false },
        .{ .i = true },
    },
    // bool型の値を表すコードブロックを定義します。このコードブロックはパースの対象となります。
    // 値は`0`（false）、`1`（true）、`false`、`true`、`F`（false）、`T`（true）の順に記述されています。
        \\ 0
        \\ 1
        \\ false
        \\ true
        \\ F
        \\ T
    );
}

test "int" {
    // このテストは、整数型が正しくパースされることを確認します。
    // 特に、整数型の各値が正しく解析され、期待される順序で出力されることを検証します。

    // テスト対象の構造体を定義します。この構造体には1つのフィールド`i`があります。
    // 構造体のインスタンスを作成し、フィールド`i`に値を設定します。
    // 値は`1`、`2`、`3`、`4`、`std.math.maxInt(usize) - 5`、`std.math.maxInt(usize)`の順に設定されています。
    try test_parse(struct { i: usize }, &.{
        .{ .i = 1 },
        .{ .i = 2 },
        .{ .i = 3 },
        .{ .i = 4 },
        .{ .i = std.math.maxInt(usize) - 5 },
        .{ .i = std.math.maxInt(usize) },
    },
    // 整数型の値を表すコードブロックを定義します。このコードブロックはパースの対象となります。
    // 値は`1`、`2`、`A3`、`a4`、`-5`、`-0`の順に記述されています。
    // ここで、符号付き整数に対して、`-n`は`maxInt(Int) - n`と解釈されます。
        \\ 1
        \\ 2
        \\ A3
        \\ a4
        // For unsigned integers, `-n` is interpreted as `maxInt(Int) - n`.
        \\ -5
        \\ -0
    );
}

test "struct" {
    // このテストは、構造体が正しくパースされることを確認します。
    // 特に、構造体の各フィールドが正しく解析され、期待される順序で出力されることを検証します。

    // テスト対象の構造体を定義します。この構造体には5つのフィールド`c1`、`c2`、`c3`、`c4`、`c5`があります。
    // 構造体のインスタンスを作成し、各フィールドに値を設定します。
    // 値は各インスタンスごとに異なりますが、フィールド`c1`は列挙型の値、`c2`は8ビット整数、`c3`は16ビット整数、`c4`は32ビット整数のオプション型、`c5`はbool型の値を持ちます。
    try test_parse(struct {
        c1: enum { a, b, c, d },
        c2: u8,
        c3: u16 = 30,
        c4: ?u32 = null,
        c5: bool = false,
    }, &.{
        .{ .c1 = .a, .c2 = 1, .c3 = 10, .c4 = 1000, .c5 = true },
        .{ .c1 = .b, .c2 = 2, .c3 = 20, .c4 = null, .c5 = true },
        .{ .c1 = .c, .c2 = 3, .c3 = 30, .c4 = null, .c5 = false },
        .{ .c1 = .d, .c2 = 4, .c3 = 30, .c4 = null, .c5 = false },
    },
    // 構造体の値を表すコードブロックを定義します。このコードブロックはパースの対象となります。
    // 値は各インスタンスごとに異なりますが、フィールド`c1`は列挙型の値、`c2`は8ビット整数、`c3`は16ビット整数、`c4`は32ビット整数のオプション型、`c5`はbool型の値を持ちます。
        \\ a 1 10 1000 1
        \\ b 2 20    _ T
        \\ c 3  _    _ F
        \\ d 4  _    _ _
    );
}

test "struct (nested)" {
    // このテストは、ネストした構造体が正しくパースされることを確認します。
    // 特に、ネストした構造体の各フィールドが正しく解析され、期待される順序で出力されることを検証します。

    // テスト対象の構造体を定義します。この構造体には3つのフィールド`a`、`b`、`c`があります。
    // `b`はさらにネストした構造体で、`b1`と`b2`の2つのフィールドを持ちます。
    // 構造体のインスタンスを作成し、各フィールドに値を設定します。
    // 値は各インスタンスごとに異なりますが、フィールド`a`と`c`は32ビット整数、`b`はネストした構造体の値を持ちます。
    try test_parse(struct {
        a: u32,
        b: struct {
            b1: u8,
            b2: u8,
        },
        c: u32,
    }, &.{
        .{ .a = 1, .b = .{ .b1 = 2, .b2 = 3 }, .c = 4 },
        .{ .a = 5, .b = .{ .b1 = 6, .b2 = 7 }, .c = 8 },
    },
    // 構造体の値を表すコードブロックを定義します。このコードブロックはパースの対象となります。
    // 値は各インスタンスごとに異なりますが、フィールド`a`と`c`は32ビット整数、`b`はネストした構造体の値を持ちます。
        \\ 1 2 3 4
        \\ 5 6 7 8
    );
}

test "array" {
    // このテストは、配列が含まれる構造体が正しくパースされることを確認します。
    // 特に、構造体の各フィールドとその中の配列が正しく解析され、期待される順序で出力されることを検証します。

    // テスト対象の構造体を定義します。この構造体には3つのフィールド`a`、`b`、`c`があります。
    // `b`は2つの要素を持つ32ビット整数の配列です。
    // 構造体のインスタンスを作成し、各フィールドに値を設定します。
    // 値は各インスタンスごとに異なりますが、フィールド`a`と`c`は32ビット整数、`b`は2つの要素を持つ32ビット整数の配列の値を持ちます。
    try test_parse(struct {
        a: u32,
        b: [2]u32,
        c: u32,
    }, &.{
        .{ .a = 1, .b = .{ 2, 3 }, .c = 4 },
        .{ .a = 5, .b = .{ 6, 7 }, .c = 8 },
    },
    // 構造体の値を表すコードブロックを定義します。このコードブロックはパースの対象となります。
    // 値は各インスタンスごとに異なりますが、フィールド`a`と`c`は32ビット整数、`b`は2つの要素を持つ32ビット整数の配列の値を持ちます。
        \\ 1 2 3 4
        \\ 5 6 7 8
    );
}

test "union" {
    // このテストは、共用体(union)が正しくパースされることを確認します。
    // 特に、共用体の各フィールドが正しく解析され、期待される順序で出力されることを検証します。

    // テスト対象の共用体を定義します。この共用体には3つのフィールド`a`、`d`、`e`があります。
    // `a`は構造体で、`b`と`c`の2つのフィールドを持ちます。`d`は8ビット整数、`e`はvoid型です。
    // 共用体のインスタンスを作成し、各フィールドに値を設定します。
    // 値は各インスタンスごとに異なりますが、フィールド`a`は構造体の値、`d`は8ビット整数、`e`はvoid型の値を持ちます。
    try test_parse(union(enum) {
        a: struct { b: u8, c: i8 },
        d: u8,
        e: void,
    }, &.{
        .{ .a = .{ .b = 1, .c = -2 } },
        .{ .d = 3 },
        .{ .e = {} },
    },
    // 共用体の値を表すコードブロックを定義します。このコードブロックはパースの対象となります。
    // 値は各インスタンスごとに異なりますが、フィールド`a`は構造体の値、`d`は8ビット整数、`e`はvoid型の値を持ちます。
        \\a 1 -2
        \\d 3
        \\e
    );
}
