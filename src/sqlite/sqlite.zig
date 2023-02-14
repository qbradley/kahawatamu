const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Database = @This();
pub const Error = error{
    Failed,
    NotImplemented,
};

db: *c.sqlite3,

pub fn open(filename: [:0]const u8) Error!Database {
    var db: ?*c.sqlite3 = undefined;
    const rc: c_int = c.sqlite3_open(filename.ptr, &db);
    if (rc != 0) {
        return error.Failed;
    }
    return .{
        .db = db orelse unreachable,
    };
}

pub fn close(self: *Database) Error!void {
    const rc = c.sqlite3_close(self.db);
    if (rc != 0) {
        return error.Failed;
    }
}

pub fn exec_no_callback(self: *Database, script: [:0]const u8) Error!void {
    const rc: c_int = c.sqlite3_exec(self.db, script.ptr, null, null, null);
    if (rc != 0) {
        return error.Failed;
    }
}

pub fn errmsg(self: Database) [:0]const u8 {
    const text = c.sqlite3_errmsg(self.db);
    return std.mem.sliceTo(text, 0);
}

pub const Column = struct {
    index: usize,

    pub fn get_text(column: Column, row: Row) [:0]const u8 {
        const index = @intCast(c_int, column.index);
        const text = c.sqlite3_column_text(row.stmt, index);
        const len = @intCast(usize, c.sqlite3_column_bytes(row.stmt, index));
        return text[0..len :0];
    }
};

pub const ColumnIterator = struct {
    index: usize,

    pub fn next(iterator: *ColumnIterator, row: Row) ?Column {
        const index = iterator.index;
        if (index < row.column_count()) {
            const result = Column{
                .index = index,
            };
            iterator.index = index + 1;
            return result;
        } else {
            return null;
        }
    }
};

pub const Row = struct {
    stmt: *c.sqlite3_stmt,

    pub fn get_columns(self: Row) ColumnIterator {
        _ = self;
        return .{
            .index = 0,
        };
    }

    pub fn column_count(self: Row) usize {
        return @intCast(usize, c.sqlite3_column_count(self.stmt));
    }
};

pub const Statement = struct {
    stmt: *c.sqlite3_stmt,

    pub fn step(self: *Statement) Error!?Row {
        const rc: c_int = c.sqlite3_step(self.stmt);
        return switch (rc) {
            c.SQLITE_DONE => null,
            c.SQLITE_ROW => .{ .stmt = self.stmt },
            else => error.Failed,
        };
    }

    pub fn column_name(self: Statement, index: usize) [:0]const u8 {
        const text = c.sqlite3_column_name(self.stmt, @intCast(c_int, index));
        return std.mem.sliceTo(text, 0);
    }

    pub fn column_count(self: Statement) usize {
        return @intCast(usize, c.sqlite3_column_count(self.stmt));
    }

    pub fn finalize(self: *Statement) Error!void {
        const rc: c_int = c.sqlite3_finalize(self.stmt);
        if (rc != 0) {
            return error.Failed;
        }
    }
};

pub fn prepare(self: *Database, sql: []const u8) Error!Statement {
    var stmt: ?*c.sqlite3_stmt = undefined;
    const rc: c_int = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(c_int, sql.len), &stmt, null);
    if (rc != 0) {
        return error.Failed;
    }
    return .{
        .stmt = stmt orelse unreachable,
    };
}
