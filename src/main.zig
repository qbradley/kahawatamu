const std = @import("std");
const lunatic = @import("lunatic-zig");
const s2s = @import("s2s");
const Socket = lunatic.Networking.Socket;
const SocketError = lunatic.Networking.Error;

pub const SocketReader = std.io.Reader(Socket, SocketError, Socket.read);

pub fn HttpRequestReader(comptime Context: type, comptime ContextErrors: type) type {
    return struct {
        context: Context,
        filled: usize,
        header_bytes: usize,
        buffer: [8192]u8,

        pub const Error = error{
            ConnectionBroken,
            InvalidRequestLine,
            InvalidHeaderLine,
            TooBig, //413
        } || ContextErrors;

        pub fn init(context: Context) Error!@This() {
            var request = @This(){
                .context = context,
                .filled = 0,
                .header_bytes = 0,
                .buffer = undefined,
            };
            try request.readHeaders();
            return request;
        }

        fn readHeaders(self: *@This()) Error!void {
            while (true) {
                const amount = try self.context.read(self.buffer[self.filled..]);
                if (amount == 0) {
                    return error.ConnectionBroken;
                }
                self.filled += amount;
                if (std.mem.indexOf(u8, self.buffer[0..self.filled], "\r\n\r\n")) |position| {
                    self.header_bytes = position;
                    return;
                }
                if (self.filled == self.buffer.len) {
                    return error.TooBig;
                }
            }
        }

        pub fn requestLine(self: *@This()) Error![]const u8 {
            var _lines = self.lines();
            if (_lines.next()) |line| {
                return line;
            } else {
                return error.InvalidRequestLine;
            }
        }

        pub fn headers(self: *@This()) HeaderIterator {
            var iterator = HeaderIterator{
                .lines = self.lines(),
            };
            _ = iterator.lines.next();
            return iterator;
        }

        pub const Header = struct {
            key: []const u8,
            value: []const u8,
        };

        pub const HeaderIterator = struct {
            lines: std.mem.TokenIterator(u8),

            pub fn next(self: *HeaderIterator) Error!?Header {
                if (self.lines.next()) |line| {
                    if (std.mem.indexOf(u8, line, ": ")) |divider| {
                        return .{
                            .key = line[0..divider],
                            .value = line[divider + 2 ..],
                        };
                    } else {
                        return error.InvalidHeaderLine;
                    }
                } else {
                    return null;
                }
            }
        };

        fn lines(self: *@This()) std.mem.TokenIterator(u8) {
            return std.mem.tokenize(u8, self.buffer[0..self.header_bytes], "\r\n");
        }
    };
}

fn handleImpl() !void {
    const socket = try receiveSocket();
    std.debug.print("Child {} got socket {}\n", .{
        lunatic.Process.process_id(),
        socket.socket_id,
    });
    defer socket.deinit();

    var reader = try HttpRequestReader(Socket, SocketError).init(socket);
    var request = try reader.requestLine();
    std.debug.print(">> {s} <<\n", .{request});
    var headers = reader.headers();
    while (try headers.next()) |header| {
        std.debug.print(" '{s}': '{s}'\n", .{ header.key, header.value });
    }

    try sqlite();

    _ = try socket.write("HTTP/1.1 200 OK\r\n" ++
        "\r\n" ++
        "Response!\r\n");
}

pub export fn handle() void {
    const process_id = lunatic.Process.process_id();
    std.debug.print("Child {} started\n", .{process_id});
    handleImpl() catch unreachable;
    std.debug.print("Child {} stopped\n", .{process_id});
}

pub fn send(process: lunatic.Process, comptime T: type, value: T) !void {
    const stream = lunatic.Message.create_message_stream(0, 128);
    try s2s.serialize(stream.writer(), T, value);
    try stream.send(process);
}

pub fn receive(comptime T: type) !T {
    while (true) {
        switch (lunatic.Message.receive_all(0)) {
            .DataMessage => {
                const stream = lunatic.MessageReader{};
                return try s2s.deserialize(stream.reader(), T);
            },
            .SignalMessage => {
                std.debug.print("Signal Message\n", .{});
            },
            .Timeout => {
                std.debug.print("Timeout\n", .{});
            },
        }
    }
}

pub fn receiveSocket() !Socket {
    while (true) {
        switch (lunatic.Message.receive_all(0)) {
            .DataMessage => {
                const stream = lunatic.MessageReader{};
                return stream.readTcpStream();
            },
            .SignalMessage => {
                std.debug.print("Signal Message\n", .{});
            },
            .Timeout => {
                std.debug.print("Timeout\n", .{});
            },
        }
    }
}

fn spawnChild(socket: Socket) !void {
    errdefer socket.deinit();
    var config = try lunatic.Process.create_config();
    config.preopen_dir("/tmp");
    const child = try lunatic.Process.spawn("handle", .{}, .{ .config = config });
    const stream = lunatic.Message.create_message_stream(0, 128);
    try stream.writeTcpStream(socket);
    try stream.send(child);
}

fn dump() !void {
    const socket = try lunatic.Networking.Tls.connect("google.com", 443, 5000, &.{});
    defer socket.deinit();

    var amount: usize = try socket.write("GET / HTTP/1.1\r\n\r\n");
    std.debug.print("Wrote {}\n", .{amount});
    try socket.flush();

    amount = 1;
    while (amount != 0) {
        var buf: [1024]u8 = undefined;
        amount = try socket.read(buf[0..]);
        std.debug.print("{}\n", .{amount});
        std.debug.print("{s}", .{buf[0..amount]});
    }
}

fn sqlite() !void {
    std.debug.print("open\n", .{});
    var db = try lunatic.Sqlite.open("/tmp/test.db");
    std.debug.print("execute\n", .{});
    try db.execute("CREATE TABLE IF NOT EXISTS test(key TEXT PRIMARY KEY, value TEXT)");
    var create = false;
    if (create) {
        std.debug.print("query_prepare\n", .{});
        var statement = db.query_prepare("INSERT INTO test (key, value) VALUES (?,?)");
        std.debug.print("bind_value\n", .{});
        try statement.bind_value(&.{
            .{ .key = .{ .Numeric = 1 }, .value = .{ .Text = "a" } },
            .{ .key = .{ .Numeric = 2 }, .value = .{ .Text = "b" } },
        });
        const more = statement.step();
        std.debug.print("more: {}\n", .{more});
    } else {
        var statement = db.query_prepare("SELECT * FROM test WHERE key <> ?");
        defer statement.deinit();

        var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
        defer arena.deinit();

        const keys: []const []const u8 = &.{ "a", "x", "q" };

        for (keys) |key| {
            std.debug.print("\nreset\n", .{});
            statement.reset();

            try statement.bind_values_by_position(.{key});
            while (statement.step()) {
                const columns = statement.column_count();
                std.debug.print("Stepped! {} columns\n", .{columns});
                for (0..columns) |column| {
                    var col = try statement.read_column(column, arena.allocator());
                    var name = try statement.column_name(column, arena.allocator());
                    var names = (try statement.column_names(arena.allocator())).result;

                    switch (col.result) {
                        .Text => |txt| std.debug.print("{} {s} {s}: '{s}'\n", .{ column, names[column], name, txt }),
                        .Integer => |num| std.debug.print("{} {s} {s}: {}\n", .{ column, names[column], name, num }),
                        else => std.debug.print("{} {s} {s}: {}\n", .{ column, names[column], name, col }),
                    }
                }
            }
        }
    }
}

pub fn main() !void {
    const version = lunatic.Version;
    std.debug.print(
        "Lunatic version {}.{}.{}\n",
        .{ version.major(), version.minor(), version.patch() },
    );

    //ery dump();

    const listener = try lunatic.Networking.Tcp.bind4(.{ 127, 0, 0, 1 }, 3001);
    defer listener.deinit();

    const port = (try listener.local_address()).port;
    std.debug.print("Listening on port {}\n", .{port});

    while (true) {
        const socket = try listener.accept();
        try spawnChild(socket);
    }

    std.debug.print("Goodbye\n", .{});
}
