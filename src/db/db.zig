const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("libc");

pub const User = struct {
    id: u64,
    handle: []const u8,
    pwd_hash: []const u8,
};

pub const Database = struct {
    allocator: Allocator,
    connection: *c.sqlite3,

    /// Opens a database connection and runs setup SQL
    pub fn init(io: std.Io, allocator: Allocator, db_path: []const u8, schema_path: []const u8) !Database {
        const db = try open(allocator, db_path);

        // read schema setup file into mem, and convert to null terminated string
        const schema_file = try std.Io.Dir.cwd().openFile(io, schema_path, .{});

        var buf: [1024]u8 = undefined;
        var sql_str: [1024]u8 = undefined;
        var file_reader = schema_file.reader(io, &buf);
        const bytes_read = try file_reader.interface.readSliceShort(&sql_str);
        if (bytes_read == 1024) return error.SchemaBufferFull;

        sql_str[bytes_read] = 0;

        var err_ptr: [*c]u8 = undefined;
        const rc = c.sqlite3_exec(db.connection, sql_str[0..bytes_read :0], null, null, &err_ptr);

        if (err_ptr) |ptr| {
            std.debug.print("Setup Schema Error: {s}\n", .{ptr});
        }

        if (rc == c.SQLITE_ABORT) return error.SetupError;

        return db;
    }

    /// Opens a database connection
    pub fn open(allocator: Allocator, db_path: []const u8) !Database {
        var db: Database = .{
            .connection = undefined,
            .allocator = allocator,
        };

        const c_db_path: [:0]u8 = try allocator.dupeSentinel(u8, db_path, 0);
        defer allocator.free(c_db_path);

        var db_ptr: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(c_db_path.ptr, &db_ptr);

        if (rc != 0) {
            const rc2 = c.sqlite3_close(db_ptr);
            switch (rc2) {
                c.SQLITE_OK => return error.DBConnectionError,
                c.SQLITE_BUSY => return error.Busy,
                else => return error.DbError,
            }
        }

        if (db_ptr) |raw_ptr| {
            db.connection = raw_ptr;
        } else {
            return error.DBConnectionError;
        }

        return db;
    }

    pub fn deinit(self: Database) !void {
        const rc = c.sqlite3_close(self.connection);
        switch (rc) {
            c.SQLITE_OK => return,
            c.SQLITE_BUSY => return error.Busy,
            else => return error.DbError,
        }
    }

    // idea: prepare this statement and then hold on to it and just reset
    pub fn addUser(self: *Database, handle: []const u8, pwd_hash: []const u8) !void {
        const sql: [:0]const u8 = "INSERT INTO User (handle, pwd_hash) VALUES (?, ?);";

        var stmt: *c.sqlite3_stmt = undefined;
        const rc = c.sqlite3_prepare_v2(self.connection, sql.ptr, @intCast(sql.len), @ptrCast(&stmt), null);
        if (rc != c.SQLITE_OK) return error.PrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, handle.ptr, @intCast(handle.len), null) != c.SQLITE_OK) return error.BindError;

        if (c.sqlite3_bind_blob(stmt, 2, pwd_hash.ptr, @intCast(pwd_hash.len), null) != c.SQLITE_OK) return error.BindError;

        // TODO: refactor this ugly switch
        // TODO: add error for SQLITE_CONSTRAINT error when duplicate usernames & other bad
        //          inserts happen
        switch (c.sqlite3_step(stmt)) {
            c.SQLITE_DONE => return,
            c.SQLITE_BUSY => return error.Busy,
            c.SQLITE_ROW => return error.Row, // maybe shouldn't be an error, but shouldn't return a row
            c.SQLITE_ERROR, c.SQLITE_INTERRUPT, c.SQLITE_SCHEMA, c.SQLITE_CORRUPT => return error.StepError,
            c.SQLITE_MISUSE => return error.Misuse,
            else => return error.StepError,
        }
    }

    /// Gets user, caller must free handle and blob returned
    pub fn getUser(self: *Database, handle: []const u8) !User {
        const sql: [:0]const u8 = "SELECT * FROM User WHERE handle = ?;";

        // prepare statement
        var stmt: *c.sqlite3_stmt = undefined;
        const rc = c.sqlite3_prepare_v2(self.connection, sql.ptr, @intCast(sql.len), @ptrCast(&stmt), null);
        if (rc != c.SQLITE_OK) return error.PrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, handle.ptr, @intCast(handle.len), null) != c.SQLITE_OK) return error.BindError;

        // get row's id, handle, & pwd_hash
        const result = c.sqlite3_step(stmt);
        if (result != c.SQLITE_ROW) return error.StepError;

        const id = c.sqlite3_column_int64(stmt, 0);

        const str_ptr = c.sqlite3_column_text(stmt, 1);
        const str_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        const str: []const u8 = str_ptr[0..str_len];

        const blob_ptr = c.sqlite3_column_blob(stmt, 1);
        const blob_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));

        if (blob_ptr) |valid_ptr| {
            const typed_ptr: [*]const u8 = @ptrCast(valid_ptr);
            const blob: []const u8 = typed_ptr[0..blob_len];

            const new_str = try self.allocator.dupe(u8, str);
            const new_blob = try self.allocator.dupe(u8, blob);

            const user: User = .{
                .id = @intCast(id),
                .handle = new_str,
                .pwd_hash = new_blob,
            };

            return user;
        }
        return error.ColumnError;
    }

    /// Checks password hash of a handle. Returns User if true.
    /// Caller is responsible for User's memory
    pub fn compareHash(self: *Database, handle: []const u8, hash: []const u8) !?User {
        const sql: [:0]const u8 = "SELECT * FROM User WHERE handle = ?;";

        // prepare statement
        var stmt: *c.sqlite3_stmt = undefined;
        const rc = c.sqlite3_prepare_v2(self.connection, sql.ptr, @intCast(sql.len), @ptrCast(&stmt), null);
        if (rc != c.SQLITE_OK) return error.PrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, handle.ptr, @intCast(handle.len), null) != c.SQLITE_OK) return error.BindError;

        // get row's id, handle, & pwd_hash
        const result = c.sqlite3_step(stmt);
        if (result != c.SQLITE_ROW) return error.StepError;

        const id = c.sqlite3_column_int64(stmt, 0);

        const str_ptr = c.sqlite3_column_text(stmt, 1);
        const str_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        const str: []const u8 = str_ptr[0..str_len];

        const blob_ptr = c.sqlite3_column_blob(stmt, 1);
        const blob_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));

        if (blob_ptr) |valid_ptr| {
            const typed_ptr: [*]const u8 = @ptrCast(valid_ptr);
            const blob: []const u8 = typed_ptr[0..blob_len];

            // return user if hashes match
            if (!std.mem.eql(u8, hash, blob)) return null;

            const new_str = try self.allocator.dupe(u8, str);
            const new_blob = try self.allocator.dupe(u8, blob);

            const user: User = .{
                .id = @intCast(id),
                .handle = new_str,
                .pwd_hash = new_blob,
            };

            return user;
        }

        return error.ColumnError;
    }
};
