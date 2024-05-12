const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const testing = std.testing;
const assert = std.debug.assert;

const Time = @import("../time.zig").Time;
const IO = @import("../io.zig").IO;

test "write/read/close" {
    // このテストは、ファイルへの書き込み、読み込み、閉じる操作が正しく機能することを確認します。
    // 各操作は非同期I/Oを使用して行われ、各操作が完了したときにはコールバック関数が呼び出されます。

    try struct {
        const Context = @This();

        io: IO,
        done: bool = false,
        fd: os.fd_t,

        // 書き込みと読み込みのためのバッファを準備します。
        write_buf: [20]u8 = [_]u8{97} ** 20,
        read_buf: [20]u8 = [_]u8{98} ** 20,

        written: usize = 0,
        read: usize = 0,

        fn run_test() !void {
            // テスト用のファイルを作成します。
            const path = "test_io_write_read_close";
            const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
            defer std.fs.cwd().deleteFile(path) catch {};

            var self: Context = .{
                .io = try IO.init(32, 0),
                .fd = file.handle,
            };
            defer self.io.deinit();

            var completion: IO.Completion = undefined;

            // ファイルへの書き込みを開始します。
            self.io.write(
                *Context,
                &self,
                write_callback,
                &completion,
                self.fd,
                &self.write_buf,
                10,
            );
            // 全ての操作が完了するまで待機します。
            while (!self.done) try self.io.tick();

            // 書き込みと読み込みの結果を確認します。
            try testing.expectEqual(self.write_buf.len, self.written);
            try testing.expectEqual(self.read_buf.len, self.read);
            try testing.expectEqualSlices(u8, &self.write_buf, &self.read_buf);
        }

        // 書き込みが完了したときに呼び出されるコールバック関数です。
        // ここで非同期I/O操作を使用していることがわかります。
        fn write_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.WriteError!usize,
        ) void {
            self.written = result catch @panic("write error");
            // ファイルからの読み込みを開始します。
            self.io.read(*Context, self, read_callback, completion, self.fd, &self.read_buf, 10);
        }

        // 読み込みが完了したときに呼び出されるコールバック関数です。
        // ここで非同期I/O操作を使用していることがわかります。
        fn read_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.ReadError!usize,
        ) void {
            self.read = result catch @panic("read error");
            // ファイルを閉じます。
            self.io.close(*Context, self, close_callback, completion, self.fd);
        }

        // ファイルが閉じられたときに呼び出されるコールバック関数です。
        // ここで非同期I/O操作を使用していることがわかります。
        fn close_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.CloseError!void,
        ) void {
            _ = completion;
            _ = result catch @panic("close error");

            // 全ての操作が完了したことを示します。
            self.done = true;
        }
    }.run_test();
}

test "accept/connect/send/receive" {
    // このテストは、ソケットの接続、送信、受信が正しく機能することを確認します。
    // 各操作は非同期I/Oを使用して行われ、各操作が完了したときにはコールバック関数が呼び出されます。
    // ソケットとは、通信のためのエンドポイントを表す抽象化のことで、通信のためのインターフェースを提供します。

    try struct {
        const Context = @This();

        io: *IO,
        done: bool = false,
        server: os.socket_t,
        client: os.socket_t,

        accepted_sock: os.socket_t = undefined,

        // 送信と受信のためのバッファを準備します。
        // バッファとは、データを一時的に格納するためのメモリ領域のことです。
        send_buf: [10]u8 = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0, 1, 0 },
        recv_buf: [5]u8 = [_]u8{ 0, 1, 0, 1, 0 },

        sent: usize = 0,
        received: usize = 0,

        fn run_test() !void {
            // IOインスタンスを初期化します。
            var io = try IO.init(32, 0);
            defer io.deinit();

            // テスト用のアドレスを設定します。
            const address = try std.net.Address.parseIp4("127.0.0.1", 0);
            const kernel_backlog = 1;
            // サーバーソケットを開きます。
            const server = try io.open_socket(address.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);
            defer os.closeSocket(server);

            // クライアントソケットを開きます。
            const client = try io.open_socket(address.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);
            defer os.closeSocket(client);

            // ソケットオプションを設定します。
            try os.setsockopt(
                server,
                os.SOL.SOCKET,
                os.SO.REUSEADDR,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            // サーバーソケットをバインドします。
            // バインドとは、ソケットにアドレスを割り当てることです。
            try os.bind(server, &address.any, address.getOsSockLen());
            // サーバーソケットをリッスン状態にします。
            try os.listen(server, kernel_backlog);

            // クライアントアドレスを取得します。
            var client_address = std.net.Address.initIp4(undefined, undefined);
            var client_address_len = client_address.getOsSockLen();
            try os.getsockname(server, &client_address.any, &client_address_len);

            var self: Context = .{
                .io = &io,
                .server = server,
                .client = client,
            };

            var client_completion: IO.Completion = undefined;
            // クライアントソケットを接続します。
            self.io.connect(
                *Context,
                &self,
                connect_callback,
                &client_completion,
                client,
                client_address,
            );

            var server_completion: IO.Completion = undefined;
            // サーバーソケットで接続を受け入れます。
            self.io.accept(*Context, &self, accept_callback, &server_completion, server);

            // 全ての操作が完了するまで待機します。
            while (!self.done) try self.io.tick();

            // 送信と受信の結果を確認します。
            try testing.expectEqual(self.send_buf.len, self.sent);
            try testing.expectEqual(self.recv_buf.len, self.received);

            try testing.expectEqualSlices(u8, self.send_buf[0..self.received], &self.recv_buf);
        }

        // 接続が完了したときに呼び出されるコールバック関数です。
        fn connect_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.ConnectError!void,
        ) void {
            _ = result catch @panic("connect error");

            // データの送信を開始します。
            self.io.send(
                *Context,
                self,
                send_callback,
                completion,
                self.client,
                &self.send_buf,
            );
        }

        // 送信が完了したときに呼び出されるコールバック関数です。
        fn send_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.SendError!usize,
        ) void {
            _ = completion;

            self.sent = result catch @panic("send error");
        }

        // 接続が受け入れられたときに呼び出されるコールバック関数です。
        fn accept_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.AcceptError!os.socket_t,
        ) void {
            self.accepted_sock = result catch @panic("accept error");
            // データの受信を開始します。
            self.io.recv(
                *Context,
                self,
                recv_callback,
                completion,
                self.accepted_sock,
                &self.recv_buf,
            );
        }

        // 受信が完了したときに呼び出されるコールバック関数です。
        fn recv_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.RecvError!usize,
        ) void {
            _ = completion;

            self.received = result catch @panic("recv error");
            // 全ての操作が完了したことを示します。
            self.done = true;
        }
    }.run_test();
}

test "timeout" {
    // このテストは、IO.timeout関数が指定した時間後に正しくコールバックを呼び出すことを確認します。
    // また、全てのタイムアウトが期待通りの時間内に完了することも確認します。

    const ms = 20;
    const margin = 5;
    const count = 10;

    try struct {
        const Context = @This();

        io: IO,
        timer: *Time,
        count: u32 = 0,
        stop_time: u64 = 0,

        fn run_test() !void {
            // タイマーを初期化します。
            var timer = Time{};
            // 開始時間を記録します。
            const start_time = timer.monotonic();
            var self: Context = .{
                .timer = &timer,
                // IOインスタンスを初期化します。
                .io = try IO.init(32, 0),
            };
            defer self.io.deinit();

            var completions: [count]IO.Completion = undefined;
            for (&completions) |*completion| {
                // タイムアウトを設定します。指定した時間が経過すると、コールバック関数が呼び出されます。
                self.io.timeout(
                    *Context,
                    &self,
                    timeout_callback,
                    completion,
                    ms * std.time.ns_per_ms,
                );
            }
            // 全てのタイムアウトが完了するまで待機します。
            while (self.count < count) try self.io.tick();

            try self.io.tick();
            // タイムアウトが期待通りの回数呼び出されたことを確認します。
            try testing.expectEqual(@as(u32, count), self.count);

            // 全てのタイムアウトが期待通りの時間内に完了したことを確認します。
            try testing.expectApproxEqAbs(
                @as(f64, ms),
                @as(f64, @floatFromInt((self.stop_time - start_time) / std.time.ns_per_ms)),
                margin,
            );
        }

        fn timeout_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.TimeoutError!void,
        ) void {
            _ = completion;
            _ = result catch @panic("timeout error");

            // タイムアウトが完了した時間を記録します。
            if (self.stop_time == 0) self.stop_time = self.timer.monotonic();
            // タイムアウトが完了した回数をカウントします。
            self.count += 1;
        }
    }.run_test();
}

test "submission queue full" {
    // このテストは、提出キューが満杯の場合のIO.timeout関数の動作を確認します。
    // 提出キューが満杯の場合でも、全てのタイムアウトが期待通りに完了することを確認します。

    const ms = 20;
    const count = 10;

    try struct {
        const Context = @This();

        io: IO,
        count: u32 = 0,

        fn run_test() !void {
            // IOインスタンスを初期化します。提出キューのサイズは1に設定します。
            var self: Context = .{ .io = try IO.init(1, 0) };
            defer self.io.deinit();

            var completions: [count]IO.Completion = undefined;
            for (&completions) |*completion| {
                // タイムアウトを設定します。提出キューが満杯の場合でも、タイムアウトは正しく設定されます。
                self.io.timeout(
                    *Context,
                    &self,
                    timeout_callback,
                    completion,
                    ms * std.time.ns_per_ms,
                );
            }
            // 全てのタイムアウトが完了するまで待機します。
            while (self.count < count) try self.io.tick();

            try self.io.tick();
            // タイムアウトが期待通りの回数呼び出されたことを確認します。
            try testing.expectEqual(@as(u32, count), self.count);
        }

        fn timeout_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.TimeoutError!void,
        ) void {
            _ = completion;
            _ = result catch @panic("timeout error");

            // タイムアウトが完了した回数をカウントします。
            self.count += 1;
        }
    }.run_test();
}

test "tick to wait" {
    // Use only IO.tick() to see if pending IO is actually processed
    // このテストは、IO.tick()関数が実際に保留中のIOを処理するかどうかを確認します。
    // IO.tick()関数が正しく動作していれば、保留中のIO操作が完了し、結果が返されます。

    try struct {
        const Context = @This();

        io: IO,
        accepted: os.socket_t = IO.INVALID_SOCKET,
        connected: bool = false,
        received: bool = false,

        fn run_test() !void {
            // IOインスタンスを初期化します。
            var self: Context = .{ .io = try IO.init(1, 0) };
            defer self.io.deinit();

            // テスト用のサーバーソケットを開きます。
            const address = try std.net.Address.parseIp4("127.0.0.1", 0);
            const kernel_backlog = 1;

            const server =
                try self.io.open_socket(address.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);
            defer os.closeSocket(server);

            // サーバーソケットのオプションを設定し、アドレスにバインドします。
            try os.setsockopt(
                server,
                os.SOL.SOCKET,
                os.SO.REUSEADDR,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            try os.bind(server, &address.any, address.getOsSockLen());
            try os.listen(server, kernel_backlog);

            // クライアントソケットを開きます。
            var client_address = std.net.Address.initIp4(undefined, undefined);
            var client_address_len = client_address.getOsSockLen();
            try os.getsockname(server, &client_address.any, &client_address_len);

            const client =
                try self.io.open_socket(client_address.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);
            defer os.closeSocket(client);

            // Start the accept
            // サーバーソケットで接続を受け入れる操作を開始します。
            var server_completion: IO.Completion = undefined;
            self.io.accept(*Context, &self, accept_callback, &server_completion, server);

            // Start the connect
            // クライアントソケットで接続操作を開始します。
            var client_completion: IO.Completion = undefined;
            self.io.connect(
                *Context,
                &self,
                connect_callback,
                &client_completion,
                client,
                client_address,
            );

            // Tick the IO to drain the accept & connect completions
            // IO.tick()を使用して、接続と受け入れの操作を完了させます。
            assert(!self.connected);
            assert(self.accepted == IO.INVALID_SOCKET);

            while (self.accepted == IO.INVALID_SOCKET or !self.connected)
                try self.io.tick();

            assert(self.connected);
            assert(self.accepted != IO.INVALID_SOCKET);
            defer os.closeSocket(self.accepted);

            // Start receiving on the client
            // クライアントソケットで受信操作を開始します。
            var recv_completion: IO.Completion = undefined;
            var recv_buffer: [64]u8 = undefined;
            @memset(&recv_buffer, 0xaa);
            self.io.recv(
                *Context,
                &self,
                recv_callback,
                &recv_completion,
                client,
                &recv_buffer,
            );

            // Drain out the recv completion from any internal IO queues
            // 内部のIOキューから受信操作を排出します。
            try self.io.tick();
            try self.io.tick();
            try self.io.tick();

            // Complete the recv() *outside* of the IO instance.
            // Other tests already check .tick() with IO based completions.
            // This simulates IO being completed by an external system
            // IOインスタンスの外部でrecv()を完了させます。
            // これは外部システムによってIOが完了することをシミュレートします。
            var send_buf = std.mem.zeroes([64]u8);
            const wrote = try os_send(self.accepted, &send_buf, 0);
            try testing.expectEqual(wrote, send_buf.len);

            // Wait for the recv() to complete using only IO.tick().
            // If tick is broken, then this will deadlock
            // IO.tick()を使用してrecv()が完了するのを待ちます。
            // tickが壊れている場合、この部分でデッドロックします。
            assert(!self.received);
            while (!self.received) {
                try self.io.tick();
            }

            // Make sure the receive actually happened
            // 受信が実際に行われたことを確認します。
            assert(self.received);
            try testing.expect(std.mem.eql(u8, &recv_buffer, &send_buf));
        }

        fn accept_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.AcceptError!os.socket_t,
        ) void {
            _ = completion;

            // 接続が受け入れられたことを確認します。
            assert(self.accepted == IO.INVALID_SOCKET);
            self.accepted = result catch @panic("accept error");
        }

        fn connect_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.ConnectError!void,
        ) void {
            _ = completion;
            _ = result catch @panic("connect error");

            // 接続が完了したことを確認します。
            assert(!self.connected);
            self.connected = true;
        }

        fn recv_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.RecvError!usize,
        ) void {
            _ = completion;
            _ = result catch |err| std.debug.panic("recv error: {}", .{err});

            // 受信が完了したことを確認します。
            assert(!self.received);
            self.received = true;
        }

        // TODO: use os.send() instead when it gets fixed for windows
        fn os_send(sock: os.socket_t, buf: []const u8, flags: u32) !usize {
            if (builtin.target.os.tag != .windows) {
                return os.send(sock, buf, flags);
            }

            const rc = os.windows.sendto(sock, buf.ptr, buf.len, flags, null, 0);
            if (rc == os.windows.ws2_32.SOCKET_ERROR) {
                switch (os.windows.ws2_32.WSAGetLastError()) {
                    .WSAEACCES => return error.AccessDenied,
                    .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                    .WSAECONNRESET => return error.ConnectionResetByPeer,
                    .WSAEMSGSIZE => return error.MessageTooBig,
                    .WSAENOBUFS => return error.SystemResources,
                    .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                    .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                    .WSAEDESTADDRREQ => unreachable, // A destination address is required.
                    // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent,
                    // or lpCompletionRoutine parameters are not part of the user address space,
                    // or the lpTo parameter is too small.
                    .WSAEFAULT => unreachable,
                    .WSAEHOSTUNREACH => return error.NetworkUnreachable,
                    // TODO: WSAEINPROGRESS, WSAEINTR
                    .WSAEINVAL => unreachable,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENETRESET => return error.ConnectionResetByPeer,
                    .WSAENETUNREACH => return error.NetworkUnreachable,
                    .WSAENOTCONN => return error.SocketNotConnected,
                    // The socket has been shut down; it is not possible to WSASendTo on a socket
                    // after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                    .WSAESHUTDOWN => unreachable,
                    .WSAEWOULDBLOCK => return error.WouldBlock,
                    // A successful WSAStartup call must occur before using this function.
                    .WSANOTINITIALISED => unreachable,
                    else => |err| return os.windows.unexpectedWSAError(err),
                }
            } else {
                return @intCast(rc);
            }
        }
    }.run_test();
}

test "pipe data over socket" {
    // このテストは、ソケットを介してデータをパイプする機能を検証します。
    // それは、送信側と受信側の両方でソケットを開き、データを送受信します。
    // 送信側と受信側のバッファが一致することを確認することで、データの整合性を検証します。

    try struct {
        io: IO,
        tx: Pipe,
        rx: Pipe,
        server: Socket = .{},

        const buffer_size = 1 * 1024 * 1024;

        const Context = @This();
        const Socket = struct {
            fd: os.socket_t = IO.INVALID_SOCKET,
            completion: IO.Completion = undefined,
        };
        const Pipe = struct {
            socket: Socket = .{},
            buffer: []u8,
            transferred: usize = 0,
        };

        // run関数は、テストの主要なステップを実行します。
        fn run() !void {
            // 送信と受信のためのバッファを確保します。
            const tx_buf = try testing.allocator.alloc(u8, buffer_size);
            defer testing.allocator.free(tx_buf);
            const rx_buf = try testing.allocator.alloc(u8, buffer_size);
            defer testing.allocator.free(rx_buf);

            // バッファを初期化します。
            @memset(tx_buf, 1);
            @memset(rx_buf, 0);

            // コンテキストを初期化します。
            var self = Context{
                .io = try IO.init(32, 0),
                .tx = .{ .buffer = tx_buf },
                .rx = .{ .buffer = rx_buf },
            };
            defer self.io.deinit();

            // サーバーソケットを開きます。
            self.server.fd = try self.io.open_socket(os.AF.INET, os.SOCK.STREAM, os.IPPROTO.TCP);
            defer os.closeSocket(self.server.fd);

            // サーバーソケットにアドレスをバインドします。
            const address = try std.net.Address.parseIp4("127.0.0.1", 0);
            try os.setsockopt(
                self.server.fd,
                os.SOL.SOCKET,
                os.SO.REUSEADDR,
                &std.mem.toBytes(@as(c_int, 1)),
            );

            try os.bind(self.server.fd, &address.any, address.getOsSockLen());
            try os.listen(self.server.fd, 1);

            // クライアントアドレスを取得します。
            var client_address = std.net.Address.initIp4(undefined, undefined);
            var client_address_len = client_address.getOsSockLen();
            try os.getsockname(self.server.fd, &client_address.any, &client_address_len);

            // サーバーソケットで接続を受け入れます。
            self.io.accept(
                *Context,
                &self,
                on_accept,
                &self.server.completion,
                self.server.fd,
            );

            // クライアントソケットを開きます。
            self.tx.socket.fd = try self.io.open_socket(os.AF.INET, os.SOCK.STREAM, os.IPPROTO.TCP);
            defer os.closeSocket(self.tx.socket.fd);

            // クライアントソケットで接続します。
            self.io.connect(
                *Context,
                &self,
                on_connect,
                &self.tx.socket.completion,
                self.tx.socket.fd,
                client_address,
            );

            // データを送受信します。
            var tick: usize = 0xdeadbeef;
            while (self.rx.transferred != self.rx.buffer.len) : (tick +%= 1) {
                if (tick % 61 == 0) {
                    const timeout_ns = tick % (10 * std.time.ns_per_ms);
                    try self.io.run_for_ns(@as(u63, @intCast(timeout_ns)));
                } else {
                    try self.io.tick();
                }
            }

            // ソケットが正しく開かれていることを確認します。
            try testing.expect(self.server.fd != IO.INVALID_SOCKET);
            try testing.expect(self.tx.socket.fd != IO.INVALID_SOCKET);
            try testing.expect(self.rx.socket.fd != IO.INVALID_SOCKET);
            os.closeSocket(self.rx.socket.fd);

            // 送受信したデータのサイズが一致することを確認します。
            try testing.expectEqual(self.tx.transferred, buffer_size);
            try testing.expectEqual(self.rx.transferred, buffer_size);

            // 送受信したデータが一致することを確認します。
            try testing.expect(std.mem.eql(u8, self.tx.buffer, self.rx.buffer));
        }

        // on_accept関数は、接続が受け入れられたときに呼び出されます。
        // この関数は、受信側のソケットを設定し、データの受信を開始します。
        fn on_accept(
            self: *Context,
            completion: *IO.Completion,
            result: IO.AcceptError!os.socket_t,
        ) void {
            assert(self.rx.socket.fd == IO.INVALID_SOCKET);
            assert(&self.server.completion == completion);
            self.rx.socket.fd = result catch |err| std.debug.panic("accept error {}", .{err});

            assert(self.rx.transferred == 0);
            self.do_receiver(0);
        }

        // on_connect関数は、接続が確立したときに呼び出されます。
        // この関数は、送信側のデータを送信します。
        fn on_connect(
            self: *Context,
            completion: *IO.Completion,
            result: IO.ConnectError!void,
        ) void {
            _ = result catch unreachable;

            assert(self.tx.socket.fd != IO.INVALID_SOCKET);
            assert(&self.tx.socket.completion == completion);

            assert(self.tx.transferred == 0);
            self.do_sender(0);
        }

        // do_sender関数は、データを送信します。
        fn do_sender(self: *Context, bytes: usize) void {
            self.tx.transferred += bytes;
            assert(self.tx.transferred <= self.tx.buffer.len);

            if (self.tx.transferred < self.tx.buffer.len) {
                self.io.send(
                    *Context,
                    self,
                    on_send,
                    &self.tx.socket.completion,
                    self.tx.socket.fd,
                    self.tx.buffer[self.tx.transferred..],
                );
            }
        }

        // on_send関数は、データが送信されたときに呼び出されます。
        fn on_send(
            self: *Context,
            completion: *IO.Completion,
            result: IO.SendError!usize,
        ) void {
            const bytes = result catch |err| std.debug.panic("send error: {}", .{err});
            assert(&self.tx.socket.completion == completion);
            self.do_sender(bytes);
        }

        // do_receiver関数は、データを受信します。
        fn do_receiver(self: *Context, bytes: usize) void {
            self.rx.transferred += bytes;
            assert(self.rx.transferred <= self.rx.buffer.len);

            if (self.rx.transferred < self.rx.buffer.len) {
                self.io.recv(
                    *Context,
                    self,
                    on_recv,
                    &self.rx.socket.completion,
                    self.rx.socket.fd,
                    self.rx.buffer[self.rx.transferred..],
                );
            }
        }

        // on_recv関数は、データが受信されたときに呼び出されます。
        fn on_recv(
            self: *Context,
            completion: *IO.Completion,
            result: IO.RecvError!usize,
        ) void {
            const bytes = result catch |err| std.debug.panic("recv error: {}", .{err});
            assert(&self.rx.socket.completion == completion);
            self.do_receiver(bytes);
        }
    }.run();
}
