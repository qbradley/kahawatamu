const std = @import("std");
const lunatic = @import("lunatic-zig");
const s2s = @import("s2s");

const Proto1 = struct {
    x: u32,
};

pub export fn handle() void {
    std.debug.print("Child {}\n", .{lunatic.Process.process_id()});
    const p1 = receive(Proto1) catch unreachable;
    std.debug.print("p1.x = {}\n", .{p1});
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

pub fn main() !void {
    const version = lunatic.Version;
    std.debug.print(
        "Lunatic version {}.{}.{}\n",
        .{ version.major(), version.minor(), version.patch() },
    );

    const handle1 = try lunatic.Process.spawn("handle", .{}, .{});
    try send(handle1, Proto1, .{ .x = 5 });

    const listener = try lunatic.Networking.Tcp.bind4(.{ 127, 0, 0, 1 }, 3001);
    defer listener.deinit();

    while (true) {
        const socket = try listener.accept();
        defer socket.deinit();
        var buf: [1024]u8 = undefined;
        var amount = try socket.read(buf[0..]);
        std.debug.print("Received '{s}'\n", .{buf[0..amount]});
        amount = try socket.write(buf[0..amount]);
        std.debug.print("Sent {} bytes\n", .{amount});
    }

    //    const server = std.net.StreamServer.init(.{
    //        .reuse_address = true,
    //    });
    //    defer server.deinit();
    //
    //    const address = std.net.Address.initIp4("127.0.0.1", 3000);
    //    try server.listen(address);
    //
    //    while (true) {
    //        var connection = try server.accept();
    //        connection.stream.write("TEST\r\n");
    //        connection.stream.close();
    //    }
    std.debug.print("Goodbye\n", .{});
}
