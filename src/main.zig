const std = @import("std");
const lunatic = @import("lunatic-zig");
const s2s = @import("s2s");
const Socket = lunatic.Networking.Socket;

fn handleImpl() !void {
    const socket = try receiveSocket();
    std.debug.print("Child {} got socket {}\n", .{
        lunatic.Process.process_id(),
        socket.socket_id,
    });
    defer socket.deinit();

    while (true) {
        var buf: [1024]u8 = undefined;
        var amount = try socket.read(buf[0..]);
        std.debug.print("Received '{s}'\n", .{buf[0..amount]});
        amount = try socket.write(buf[0..amount]);
        std.debug.print("Sent {} bytes\n", .{amount});
        try socket.flush();

        if (std.mem.eql(u8, "bye\r\n", buf[0..amount])) {
            return;
        }
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
    const child = try lunatic.Process.spawn("handle", .{}, .{});
    const stream = lunatic.Message.create_message_stream(0, 128);
    try stream.writeTcpStream(socket);
    try stream.send(child);
}

pub fn main() !void {
    const version = lunatic.Version;
    std.debug.print(
        "Lunatic version {}.{}.{}\n",
        .{ version.major(), version.minor(), version.patch() },
    );

    const listener = try lunatic.Networking.Tcp.bind4(.{ 127, 0, 0, 1 }, 0);
    defer listener.deinit();

    const port = (try listener.local_address()).port;
    std.debug.print("Listening on port {}\n", .{port});

    while (true) {
        const socket = try listener.accept();
        try spawnChild(socket);
    }

    std.debug.print("Goodbye\n", .{});
}
