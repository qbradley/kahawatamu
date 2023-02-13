const std = @import("std");
const zap = @import("zap");
const sqlite = @import("sqlite/sqlite.zig");

fn arrayListWrite(list: *std.ArrayList(u8), value: []const u8) std.mem.Allocator.Error!usize {
    try list.appendSlice(value);
    return value.len;
}
const StringWriter = std.io.Writer(*std.ArrayList(u8), std.mem.Allocator.Error, arrayListWrite);

fn on_request_fallible(r: zap.SimpleRequest) !void {
    if (r.path) |the_path| {
        std.debug.print("PATH: {s}\n", .{the_path});
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    if (r.query) |the_query| {
        std.debug.print("QUERY: {s}\n", .{the_query});
    }

    var database: sqlite.Database = try sqlite.open("/tmp/test.db");
    defer database.close() catch unreachable;

    var body = r.body orelse return error.NoBody;
    var statement: sqlite.Statement = try database.prepare(body);
    defer statement.finalize() catch unreachable;

    const columns = statement.column_count();
    std.debug.print("column count: {}\n", .{columns});

    var buf = std.ArrayList(u8).init(gpa.allocator());
    defer buf.deinit();
    var stream = StringWriter{ .context = &buf };
    var w = std.json.writeStream(stream, 10);

    try w.beginObject();
    try w.objectField("columns");
    try w.beginArray();
    var index: usize = 0;
    while (index < columns) : (index += 1) {
        try w.arrayElem();
        try w.emitString(statement.column_name(index));
    }
    try w.endArray();
    try w.objectField("rows");
    try w.beginArray();

    while (try statement.step()) |row| {
        try w.arrayElem();
        try w.beginArray();
        var column_iter = row.get_columns();
        while (column_iter.next(row)) |column| {
            try w.arrayElem();
            try w.emitString(column.get_text(row));
        }
        try w.endArray();
    }

    try w.endArray();
    try w.endObject();

    _ = r.sendBody(buf.items);
}

fn on_request_verbose(r: zap.SimpleRequest) void {
    on_request_fallible(r) catch |e| {
        switch (e) {
            error.NoBody => {
                r.setStatus(.bad_request);
                _ = r.sendBody("No body was specified. The query should be specified as a body.");
            },
            else => {
                r.setStatus(.internal_server_error);
                _ = r.sendBody("Something went wrong");
            },
        }
    };
}

fn on_request_minimal(r: zap.SimpleRequest) void {
    _ = r.sendBody("<html><body><h1>Hello from ZAP!!!</h1></body></html>");
}

pub fn main() !void {
    var database: sqlite.Database = try sqlite.open("/tmp/test.db");
    defer database.close() catch unreachable;

    try database.exec_no_callback(
        \\PRAGMA journal_mode=WAL;
        \\CREATE TABLE IF NOT EXISTS properties (
        \\  key TEXT,
        \\  value TEXT
        \\);
    );

    var listener = zap.SimpleHttpListener.init(.{
        .port = 3000,
        .on_request = on_request_verbose,
        .log = true,
        .max_clients = 100000,
    });
    try listener.listen();

    std.debug.print("Listening on 0.0.0.0:3000\n", .{});

    // start worker threads
    zap.start(.{
        .threads = -1,
        .workers = 1,
    });
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
