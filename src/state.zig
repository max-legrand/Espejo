const std = @import("std");
const httpz = @import("httpz");
const zlog = @import("zlog");
const websocket = httpz.websocket;
const ws = @import("ws.zig");

const CachedFile = struct {
    data: []u8,
    compressed_data: ?[]u8 = null,
    content_type: httpz.ContentType,
    last_modified: i128,
};

pub const Upload = struct {
    filename: []const u8,
    size: u64,
    upload_time: i64,

    pub fn deinit(self: *Upload, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        allocator.destroy(self);
    }

    pub fn initFromValue(data: std.json.Parsed(Upload), allocator: std.mem.Allocator) !*Upload {
        const upload_ptr = try allocator.create(Upload);
        upload_ptr.* = Upload{
            .filename = allocator.dupe(u8, data.value.filename) catch {
                allocator.destroy(upload_ptr);
                return error.OutOfMemory;
            },
            .size = data.value.size,
            .upload_time = data.value.upload_time,
        };
        return upload_ptr;
    }
};

pub const State = struct {
    const Self = @This();
    file_cache: std.StringHashMap(CachedFile),
    allocator: std.mem.Allocator,
    current_upload: ?*Upload = null,
    ws_connections: std.ArrayList(*ws.Client),
    use_auth: bool,

    pub const WebsocketHandler = ws.Client;

    fn shouldUseAuth(allocator: std.mem.Allocator) bool {
        var envMap = std.process.getEnvMap(allocator) catch {
            return false;
        };
        defer envMap.deinit();

        return envMap.get("USE_AUTH") != null;
    }

    pub fn init(allocator: std.mem.Allocator) Self {
        var value = Self{
            .file_cache = std.StringHashMap(CachedFile).init(allocator),
            .allocator = allocator,
            .ws_connections = std.ArrayList(*ws.Client).init(allocator),
            .use_auth = shouldUseAuth(allocator),
        };
        const cwd = std.fs.cwd();
        const metadata = cwd.openFile("upload/metadata.json", .{}) catch {
            return value;
        };
        defer metadata.close();
        const content = metadata.readToEndAlloc(allocator, std.math.maxInt(usize)) catch {
            return value;
        };
        defer allocator.free(content);

        var data = std.json.parseFromSlice(Upload, allocator, content, .{}) catch {
            return value;
        };
        defer data.deinit();

        const upload_ptr = Upload.initFromValue(data, allocator) catch {
            return value;
        };

        value.current_upload = upload_ptr;
        return value;
    }

    pub fn deinit(self: *Self) void {
        var iter = self.file_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.compressed_data) |compressed_data| {
                self.allocator.free(compressed_data);
            }
            self.allocator.free(entry.value_ptr.data);
        }
        self.file_cache.deinit();
        if (self.current_upload) |cu| {
            cu.deinit(self.allocator);
        }

        self.ws_connections.deinit();
    }

    pub fn stopWS(self: *Self) void {
        for (self.ws_connections.items) |client| {
            // client.shutdown();
            // client.deinit();
            self.allocator.destroy(client);
        }
    }

    pub fn dispatch(
        self: *Self,
        action: httpz.Action(*Self),
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        if (self.use_auth) {
            var envMap = try std.process.getEnvMap(self.allocator);
            defer envMap.deinit();
            const user = envMap.get("SP_USER") orelse return error.NoUser;
            const password = envMap.get("SP_PASSWORD") orelse return error.NoPassword;

            if (req.headers.get("authorization")) |auth| {
                const data = auth[6..];
                const expected = try std.fmt.allocPrint(res.arena, "{s}:{s}", .{ user, password });
                const dest: []u8 = try res.arena.alloc(u8, expected.len);
                try std.base64.standard.Decoder.decode(dest, data);
                if (!std.mem.eql(u8, dest, expected)) {
                    res.status = 403;
                    try res.write();
                    return;
                }
            } else {
                res.status = 401;
                res.headers.add("WWW-Authenticate", "Basic realm=\"Scratchpad\"");
                try res.write();
                return;
            }
        }

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

    pub fn preloadFile(self: *Self, path: []const u8, content_type: ?httpz.ContentType) !void {
        _ = try self.getOrLoadFile(path, content_type);
        zlog.info("Preloaded file: {s}", .{path});
    }
    pub fn preloadDirectory(self: *Self, dir_path: []const u8) !void {
        const cwd = std.fs.cwd();
        var dir = try cwd.openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .File) continue;

            const full_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ dir_path, entry.name },
            );
            defer self.allocator.free(full_path);

            const content_type = getMimeType(entry.name);
            try self.preloadFile(full_path, content_type);
        }
        zlog.info("Preloaded directory: {s}", .{dir_path});
    }
    pub fn preloadDirectoryRecursive(self: *Self, dir_path: []const u8) !void {
        try self.preloadDirectoryRecursiveInternal(dir_path, dir_path);
        zlog.info("Recursively preloaded directory: {s}", .{dir_path});
    }

    fn preloadDirectoryRecursiveInternal(self: *Self, base_path: []const u8, current_path: []const u8) !void {
        const cwd = std.fs.cwd();
        var dir = try cwd.openDir(current_path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            const full_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ current_path, entry.name },
            );
            defer self.allocator.free(full_path);

            if (entry.kind == .directory) {
                try self.preloadDirectoryRecursiveInternal(base_path, full_path);
            } else if (entry.kind == .file) {
                const content_type = getMimeType(entry.name);
                try self.preloadFile(full_path, content_type);
            }
        }
    }

    fn shouldCompress(path: []const u8, content_type: httpz.ContentType) bool {
        // Don't compress already compressed formats
        if (std.mem.eql(u8, std.fs.path.extension(path), ".gz")) return false;
        if (std.mem.eql(u8, std.fs.path.extension(path), ".zip")) return false;
        if (std.mem.eql(u8, std.fs.path.extension(path), ".jpg")) return false;
        if (std.mem.eql(u8, std.fs.path.extension(path), ".jpeg")) return false;
        if (std.mem.eql(u8, std.fs.path.extension(path), ".png")) return false;
        if (std.mem.eql(u8, std.fs.path.extension(path), ".webp")) return false;
        if (std.mem.eql(u8, std.fs.path.extension(path), ".mp3")) return false;
        if (std.mem.eql(u8, std.fs.path.extension(path), ".mp4")) return false;

        // Compress text-based formats and WASM
        return content_type == .HTML or
            content_type == .CSS or
            content_type == .JS or
            content_type == .JSON or
            content_type == .XML or
            content_type == .TEXT or
            content_type == .WASM;
    }

    fn compressData(self: *Self, data: []const u8) ![]u8 {
        var compressed_buffer = std.ArrayList(u8).init(self.allocator);
        defer compressed_buffer.deinit();
        var in_stream = std.io.fixedBufferStream(data);
        const out_stream = compressed_buffer.writer();

        try std.compress.gzip.compress(in_stream.reader(), out_stream, .{ .level = .default });

        if (compressed_buffer.items.len >= data.len) {
            return error.CompressionNotEfficient;
        }

        return self.allocator.dupe(u8, compressed_buffer.items);
    }

    pub fn getOrLoadFile(self: *Self, path: []const u8, content_type: ?httpz.ContentType) !CachedFile {
        const current_mod_time = try getFileModTime(path);

        // Check if file is already cached and up to date
        if (self.file_cache.get(path)) |cached| {
            if (cached.last_modified == current_mod_time) {
                // File hasn't changed, use cached version
                return cached;
            }
            // File has changed, remove old cached version
            const old_path = self.file_cache.fetchRemove(path).?.key;
            self.allocator.free(old_path);
            self.allocator.free(cached.data);
            if (cached.compressed_data != null) {
                self.allocator.free(cached.compressed_data.?);
            }
        }

        // File not in cache or has changed, load it
        const cwd = std.fs.cwd();
        const file = try cwd.openFile(path, .{});
        defer file.close();

        // Get file size for better allocation
        const stat = try file.stat();
        const file_size = stat.size;

        // Allocate memory and read file
        const data = try self.allocator.alloc(u8, file_size);
        const bytes_read = try file.readAll(data);
        if (bytes_read != file_size) {
            self.allocator.free(data);
            return error.IncompleteRead;
        }
        const actual_content_type = content_type orelse .BINARY;
        // Compress the data
        var compressed_data: ?[]u8 = null;
        if (file_size > 1024 and shouldCompress(path, actual_content_type)) { // Only compress files > 1KB
            compressed_data = self.compressData(data) catch null;
            // if (compressed_data) |compressed| {
            //     const compression_ratio = @as(f32, @floatFromInt(data.len)) / @as(f32, @floatFromInt(compressed.len));
            //     zlog.info("Compressed {s}: {d} -> {d} bytes (ratio: {d:.2}x)", .{ path, data.len, compressed.len, compression_ratio });
            // }
        }

        // Create cache entry
        const path_copy = try self.allocator.dupe(u8, path);
        const cached_file = CachedFile{
            .data = data,
            .content_type = content_type orelse .BINARY,
            .last_modified = current_mod_time,
            .compressed_data = compressed_data,
        };

        // Store in cache
        try self.file_cache.put(path_copy, cached_file);

        return cached_file;
    }

    fn getFileModTime(path: []const u8) !i128 {
        const cwd = std.fs.cwd();
        const file = try cwd.openFile(path, .{});
        defer file.close();
        const stat = try file.stat();
        return stat.mtime;
    }
};

pub fn getMimeType(filename: []const u8) ?httpz.ContentType {
    const ext = std.fs.path.extension(filename);
    if (std.mem.eql(u8, ext, ".wasm")) return httpz.ContentType.WASM;
    if (std.mem.eql(u8, ext, ".js")) return httpz.ContentType.JS;
    if (std.mem.eql(u8, ext, ".json")) return httpz.ContentType.JSON;
    if (std.mem.eql(u8, ext, ".css")) return httpz.ContentType.CSS;
    if (std.mem.eql(u8, ext, ".html")) return httpz.ContentType.HTML;
    if (std.mem.eql(u8, ext, ".txt")) return httpz.ContentType.TEXT;
    if (std.mem.eql(u8, ext, ".svg")) return httpz.ContentType.SVG;
    if (std.mem.eql(u8, ext, ".png")) return httpz.ContentType.PNG;
    if (std.mem.eql(u8, ext, ".jpg")) return httpz.ContentType.JPG;
    if (std.mem.eql(u8, ext, ".jpeg")) return httpz.ContentType.JPG;
    if (std.mem.eql(u8, ext, ".gif")) return httpz.ContentType.GIF;
    if (std.mem.eql(u8, ext, ".ico")) return httpz.ContentType.ICO;
    if (std.mem.eql(u8, ext, ".xml")) return httpz.ContentType.XML;
    if (std.mem.eql(u8, ext, ".ttf")) return httpz.ContentType.TTF;
    if (std.mem.eql(u8, ext, ".woff")) return httpz.ContentType.WOFF;
    if (std.mem.eql(u8, ext, ".woff2")) return httpz.ContentType.WOFF2;
    return null;
}

pub fn setCacheHeaders(res: *httpz.Response, max_age_seconds: u32) !void {
    const cache_control = try std.fmt.allocPrint(
        res.arena,
        "public, max-age={d}",
        .{max_age_seconds},
    );
    res.header("Cache-Control", cache_control);
}
