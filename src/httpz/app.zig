const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");
const zlog = @import("zlog");
const ws = @import("ws.zig");

pub const FileCache = struct {
    last_fetched: i64,
    content: []const u8,
    key: []const u8,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    file_cache: std.StringHashMap(FileCache),
    rwlock: std.Thread.RwLock = .{},
    current_upload: ?std.json.Parsed(std.json.Value),

    clients: std.ArrayList(*ws.Client),
    clients_mutex: std.Thread.Mutex = .{},

    pub fn dispatch(
        self: *App,
        action: httpz.Action(*App),
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        var timer = try std.time.Timer.start();
        try action(self, req, res);
        const elapsed = timer.lap() / 1000;
        if (res.status == 404) {
            zlog.warn(
                "[{d}] {} {s} - {d}μs",
                .{ res.status, req.method, req.url.path, elapsed },
            );
        } else {
            zlog.info(
                "[{d}] {} {s} - {d}μs",
                .{ res.status, req.method, req.url.path, elapsed },
            );
        }
    }

    pub fn stopWS(self: *App) void {
        self.clients_mutex.lock();
        for (self.clients.items, 0..) |client, i| {
            zlog.info("Closing websocket connection {d}", .{i});
            client.conn.close(.{}) catch |err| {
                zlog.err("Failed to close websocket connection: {any}", .{err});
            };
        }
        self.clients_mutex.unlock();
    }

    pub fn notFound(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
        zlog.warn("[404] {} {s}", .{ req.method, req.url.path });
        res.status = 404;
        res.content_type = .TEXT;
        res.body = "Not Found";
    }

    pub fn uncaughtError(
        _: *App,
        req: *httpz.Request,
        res: *httpz.Response,
        err: anyerror,
    ) void {
        zlog.err("[500] {} {s} {}", .{ req.method, req.url.path, err });
        res.status = 500;
        res.content_type = .TEXT;
        res.body = "Internal Server Error";
    }

    pub fn deinit(self: *App) void {
        self.clients_mutex.lock();
        self.clients.deinit();
        self.clients_mutex.unlock();

        self.rwlock.lock();
        var iter = self.file_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.content);
            self.allocator.free(entry.value_ptr.key);
        }
        self.file_cache.deinit();
        if (self.current_upload) |cu| {
            cu.deinit();
        }
        self.rwlock.unlock();
    }

    pub fn init(self: *App) !void {
        self.clients = std.ArrayList(*ws.Client).init(self.allocator);
        const cwd = std.fs.cwd();
        const upload_dir = try cwd.openDir("upload", .{});

        // Check if the metadata file exists
        upload_dir.access("metadata.json", .{}) catch {
            return;
        };
        const metadata_file = try upload_dir.openFile("metadata.json", .{});
        const data = try metadata_file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(data);
        const json = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        self.current_upload = json;
    }

    pub const WebsocketHandler = ws.Client;

    pub fn registerWebsocket(self: *App, client: *ws.Client) !void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        try self.clients.append(client);
    }

    pub fn unregisterWebsocket(self: *App, client: *ws.Client) void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();

        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.orderedRemove(i);
                break;
            }
        }
    }
};

fn seedCache(app: *App, base_dir: []const u8) !void {
    const cwd = std.fs.cwd();
    var dir = try cwd.openDir(base_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(app.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            const owned_path = try std.fs.path.join(
                app.allocator,
                &[_][]const u8{ base_dir, entry.path },
            );
            zlog.info("path={s}", .{owned_path});
            const file = try cwd.openFile(owned_path, .{});
            defer file.close();

            const metadata = try file.stat();
            const size = metadata.size;
            const data = try file.readToEndAlloc(app.allocator, size);

            app.rwlock.writeLock();
            const dup_key = try app.allocator.dupe(u8, owned_path);
            try app.file_cache.put(dup_key, .{
                .last_fetched = std.time.milliTimestamp(),
                .content = data,
                .key = dup_key,
            });
            app.rwlock.unlock();
        }
    }
}

pub const StaticFileConfig = struct {
    filepath: []const u8,
    path: ?[]const u8,
    mime_type: ?httpz.ContentType,
    // cache_expiry_time:
    // null  => Cache forever.
    // 0     => Always serve from disk.
    // > 0   => Cache for that many milliseconds.
    cache_expiry_time: ?i64,
};
