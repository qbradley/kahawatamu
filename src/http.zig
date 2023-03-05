const std = @import("std");

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

        pub fn readBody(self: *@This(), body: []u8) !void {
            const body_start = self.header_bytes + 4; //skip past two blank lines
            var complete: usize = 0;
            if (body_start < self.filled) {
                complete = self.filled - body_start;
                if (complete > body.len) {
                    return error.TooManyBytes;
                }
                std.mem.copy(u8, body[0..complete], self.buffer[body_start .. body_start + complete]);
            }
            while (complete < body.len) {
                const amount = try self.context.read(body[complete..]);
                if (amount == 0) {
                    return error.ConnectionBroken;
                }
                complete += amount;
            }
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
