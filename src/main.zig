const std = @import("std");
const lunatic = @import("lunatic-zig");
const s2s = @import("s2s");
const Socket = lunatic.Networking.Socket;
const SocketError = lunatic.Networking.Error;

pub const SocketReader = std.io.Reader(Socket, SocketError, Socket.read);
fn arrayListWrite(list: *std.ArrayList(u8), value: []const u8) std.mem.Allocator.Error!usize {
    try list.appendSlice(value);
    return value.len;
}
const StringWriter = std.io.Writer(*std.ArrayList(u8), std.mem.Allocator.Error, arrayListWrite);

const HttpRequestReader = @import("http.zig").HttpRequestReader;

fn handleImpl() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();

    const socket = try receiveSocket();
    std.debug.print("Child {} got socket {}\n", .{
        lunatic.Process.process_id(),
        socket.socket_id,
    });
    defer socket.deinit();

    var content_length: usize = 0;
    var reader = try HttpRequestReader(Socket, SocketError).init(socket);
    var request = try reader.requestLine();
    std.debug.print(">> {s} <<\n", .{request});
    var headers = reader.headers();
    while (try headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.key, "content-length")) {
            content_length = try std.fmt.parseUnsigned(usize, header.value, 10);
        }
        std.debug.print(" '{s}': '{s}'\n", .{ header.key, header.value });
    }

    if (content_length > 0) {
        const buffer = try std.heap.wasm_allocator.alloc(u8, content_length);
        defer std.heap.wasm_allocator.free(buffer);

        try reader.readBody(buffer);
        var result = try sqlite(buffer, std.heap.wasm_allocator);

        var response = try std.fmt.allocPrint(
            std.heap.wasm_allocator,
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Content-Length: {}\r\n" ++
                "\r\n" ++
                "{s}",
            .{
                result.items.len,
                result.items,
            },
        );
        defer std.heap.wasm_allocator.free(response);

        _ = try socket.write(response);
    } else {
        _ = try socket.write("HTTP/1.1 400 Bad Request\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 31\r\n" ++
            "\r\n" ++
            "Expected a query in the body.\r\n");
    }
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

fn sqlite(query: []const u8, allocator: std.mem.Allocator) !std.ArrayList(u8) {
    var db = try lunatic.Sqlite.open("/tmp/test.db");

    var statement = db.query_prepare(query);
    defer statement.deinit();

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var stream = StringWriter{ .context = &buf };
    var w = std.json.writeStream(stream, 10);

    const columns = statement.column_count();
    try w.beginObject();
    try w.objectField("columns");
    try w.beginArray();
    for (0..columns) |index| {
        var name = try statement.column_name(index, allocator);
        try w.arrayElem();
        try w.emitString(name);
    }
    try w.endArray();
    try w.objectField("rows");
    try w.beginArray();

    while (statement.step()) {
        try w.arrayElem();
        try w.beginArray();
        for (0..columns) |column| {
            var col = try statement.read_column(column, allocator);

            try w.arrayElem();
            switch (col.result) {
                .Text => |txt| try w.emitString(txt),
                .Integer => |num| try w.emitNumber(num),
                else => try w.emitNull(),
            }
        }
        try w.endArray();
    }
    try w.endArray();
    try w.endObject();

    return buf;
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
