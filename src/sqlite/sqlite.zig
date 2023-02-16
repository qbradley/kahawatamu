const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Database = @This();
pub const Error = error{
    Unknown,
    Abort,
    Auth,
    Busy,
    CantOpen,
    Constraint,
    Corrupt,
    Empty,
    Error,
    Format,
    Full,
    Internal,
    Interrupt,
    IoErr,
    Locked,
    Mismatch,
    Misuse,
    NoLfs,
    NoMem,
    NotADb,
    NotFound,
    Notice,
    Perm,
    Protocol,
    Range,
    ReadOnly,
    Schema,
    TooBig,
    Warning,
    // Ok, Done, and Row are not errors.
};

db: *c.sqlite3,

pub fn open(filename: [:0]const u8) Error!Database {
    var db: ?*c.sqlite3 = undefined;
    try check(c.sqlite3_open(filename.ptr, &db));
    return .{
        .db = db orelse unreachable,
    };
}

pub fn close(self: *Database) Error!void {
    try check(c.sqlite3_close(self.db));
}

pub fn exec_no_callback(self: *Database, script: [:0]const u8) Error!void {
    try check(c.sqlite3_exec(self.db, script.ptr, null, null, null));
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
            else => to_error(rc),
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
        try check(c.sqlite3_finalize(self.stmt));
    }
};

pub fn prepare(self: *Database, sql: []const u8) Error!Statement {
    var stmt: ?*c.sqlite3_stmt = undefined;
    try check(c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(c_int, sql.len), &stmt, null));
    return .{
        .stmt = stmt orelse unreachable,
    };
}

fn check(rc: c_int) Error!void {
    if (rc == c.SQLITE_OK) {
        return;
    }
    const text = c.sqlite3_errstr(rc);
    std.debug.print("SQLITE ERROR: {} {s}\n", .{ rc, std.mem.sliceTo(text, 0) });
    return to_error(rc);
}

fn to_error(rc: c_int) Error {
    const primary_result_code = rc & 0xff;
    return switch (primary_result_code) {
        c.SQLITE_ABORT => error.Abort,
        c.SQLITE_AUTH => error.Auth,
        c.SQLITE_BUSY => error.Busy,
        c.SQLITE_CANTOPEN => error.CantOpen,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CORRUPT => error.Corrupt,
        c.SQLITE_EMPTY => error.Empty,
        c.SQLITE_ERROR => error.Error,
        c.SQLITE_FORMAT => error.Format,
        c.SQLITE_FULL => error.Full,
        c.SQLITE_INTERNAL => error.Internal,
        c.SQLITE_INTERRUPT => error.Interrupt,
        c.SQLITE_IOERR => error.IoErr,
        c.SQLITE_LOCKED => error.Locked,
        c.SQLITE_MISMATCH => error.Mismatch,
        c.SQLITE_MISUSE => error.Misuse,
        c.SQLITE_NOLFS => error.NoLfs,
        c.SQLITE_NOMEM => error.NoMem,
        c.SQLITE_NOTADB => error.NotADb,
        c.SQLITE_NOTFOUND => error.NotFound,
        c.SQLITE_NOTICE => error.Notice,
        c.SQLITE_PERM => error.Perm,
        c.SQLITE_PROTOCOL => error.Protocol,
        c.SQLITE_RANGE => error.Range,
        c.SQLITE_READONLY => error.ReadOnly,
        c.SQLITE_SCHEMA => error.Schema,
        c.SQLITE_TOOBIG => error.TooBig,
        c.SQLITE_WARNING => error.Warning,
        else => error.Unknown,
    };
}
