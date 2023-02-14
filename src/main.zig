const std = @import("std");
const zap = @import("zap");
const sqlite = @import("sqlite/sqlite.zig");
const ArrayList = std.ArrayList;

var gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined;

fn arrayListWrite(list: *ArrayList(u8), value: []const u8) std.mem.Allocator.Error!usize {
    try list.appendSlice(value);
    return value.len;
}
const StringWriter = std.io.Writer(*ArrayList(u8), std.mem.Allocator.Error, arrayListWrite);

const Response = struct {
    status_code: zap.StatusCode,
    content_type: zap.ContentType,
    body: ArrayList(u8),

    pub fn deinit(self: Response) void {
        self.body.deinit();
    }
};

fn print_response(content_type: zap.ContentType, status_code: zap.StatusCode, comptime format: []const u8, args: anytype) !Response {
    var body = ArrayList(u8).init(gpa.allocator());
    errdefer body.deinit();

    var stream = StringWriter{ .context = &body };
    try stream.print(format, args);

    return Response{
        .status_code = status_code,
        .content_type = content_type,
        .body = body,
    };
}

fn internal_server_error(comptime format: []const u8, args: anytype) !Response {
    return print_response(.TEXT, .internal_server_error, format, args);
}

fn bad_request(comptime format: []const u8, args: anytype) !Response {
    return print_response(.TEXT, .bad_request, format, args);
}

fn sqlite_error(database: sqlite.Database, error_code: sqlite.Error) !Response {
    error_code catch {};
    const error_text = database.errmsg();
    return print_response(.TEXT, .bad_request, "{s}", .{error_text});
}

fn on_request_fallible(r: zap.SimpleRequest) !Response {
    if (r.path) |the_path| {
        std.debug.print("PATH: {s}\n", .{the_path});
    }

    if (r.query) |the_query| {
        std.debug.print("QUERY: {s}\n", .{the_query});
    }

    var database: sqlite.Database = try sqlite.open("/tmp/test.db");
    defer database.close() catch unreachable;

    var body = r.body orelse return internal_server_error("Invalid query. No body was specified.", .{});
    var statement: sqlite.Statement = database.prepare(body) catch |e| return sqlite_error(database, e);
    defer statement.finalize() catch unreachable;

    const columns = statement.column_count();
    std.debug.print("column count: {}\n", .{columns});

    var buf: ?ArrayList(u8) = ArrayList(u8).init(gpa.allocator());
    defer if (buf) |b| b.deinit();

    var stream = StringWriter{ .context = &buf.? };
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

    while (statement.step() catch |e| return sqlite_error(database, e)) |row| {
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

    const response = .{
        .status_code = .ok,
        .content_type = .JSON,
        .body = buf.?,
    };
    buf = null;
    return response;
}

fn on_request_verbose(r: zap.SimpleRequest) void {
    const response = on_request_fallible(r) catch |e| internal_server_error("Internal Server Error: {s}", .{@errorName(e)}) catch {
        r.setStatus(.internal_server_error);
        r.setContentType(.TEXT);
        _ = r.sendBody("Internal Server Error: Out Of Memory");
        return;
    };
    defer response.deinit();

    r.setStatus(response.status_code);
    r.setContentType(response.content_type);
    _ = r.sendBody(response.body.items);
}

fn on_request_minimal(r: zap.SimpleRequest) void {
    _ = r.sendBody("<html><body><h1>Hello from ZAP!!!</h1></body></html>");
}

pub fn main() !void {
    gpa = .{};
    defer _ = gpa.deinit();

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
    var list = ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
