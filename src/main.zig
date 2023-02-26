const std = @import("std");
const lunatic = @import("lunatic-zig");
const s2s = @import("s2s");

const Proto1 = struct {
    x: u32,
};

pub export fn handle() void {
    std.debug.print("Child {}\n", .{lunatic.Process.process_id()});
    switch (lunatic.Message.receive_all(1000)) {
        .DataMessage => {
            const p1 = receive(Proto1) catch unreachable;
            std.debug.print("p1.x = {}\n", .{p1});
        },
        .SignalMessage => {
            std.debug.print("Signal Message\n", .{});
        },
        .Timeout => {
            std.debug.print("Timeout\n", .{});
        },
    }
}

pub fn send(process: lunatic.Process, comptime T: type, value: T) !void {
    const stream = lunatic.Message.create_message_stream(0, 128);
    try s2s.serialize(stream.writer(), T, value);
    try stream.send(process);
}

pub fn receive(comptime T: type) !T {
    const stream = lunatic.MessageReader{};
    return try s2s.deserialize(stream.reader(), T);
}

pub fn main() !void {
    const version = lunatic.Version;
    std.debug.print(
        "Lunatic version {}.{}.{}\n",
        .{ version.major(), version.minor(), version.patch() },
    );

    const handle1 = try lunatic.Process.spawn("handle", .{}, .{});
    try send(handle1, Proto1, .{ .x = 5 });
}
