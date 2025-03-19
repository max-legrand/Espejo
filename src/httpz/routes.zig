const std = @import("std");
const httpz = @import("httpz");
const zlog = @import("zlog");
const utils = @import("utils.zig");
const app_module = @import("app.zig");
const App = app_module.App;
const StaticFileConfig = app_module.StaticFileConfig;
const Client = @import("ws.zig").Client;

pub fn serveFileFromPath(
    app: *App,
    res: *httpz.Response,
    config: *const StaticFileConfig,
) !void {
    // Set content type based on the provided config.
    if (config.mime_type) |mt| {
        res.content_type = mt;
    } else {
        res.content_type = utils.getMimeType(config.filepath);
    }

    // First check if we can serve from cache
    var serve_from_cache = false;
    var cached_content: []const u8 = undefined;

    app.rwlock.lockShared();
    if (app.file_cache.get(config.filepath)) |cached| {
        if (config.cache_expiry_time) |refresh_time| {
            // refresh_time == 0 means "always read from disk"
            if (refresh_time != 0 and cached.last_fetched + refresh_time > std.time.milliTimestamp()) {
                serve_from_cache = true;
                cached_content = cached.content;
            }
        } else {
            // Cache forever.
            serve_from_cache = true;
            cached_content = cached.content;
        }
    }
    app.rwlock.unlockShared();

    if (serve_from_cache) {
        res.body = cached_content;
        try res.write();
        return;
    }

    // File not cached or expired, so serve from disk.
    const cwd = std.fs.cwd();
    cwd.access(config.filepath, .{}) catch {
        res.status = 404;
        res.content_type = .TEXT;
        res.body = "Not Found";
        return;
    };

    const file = try cwd.openFile(config.filepath, .{});
    defer file.close();

    const metadata = try file.stat();
    const size = metadata.size;
    const data = try file.readToEndAlloc(app.allocator, size);

    // Update cache if caching is enabled
    if (config.cache_expiry_time == null or (config.cache_expiry_time.? != 0)) {
        // We need to cache this file
        const cache_data = try app.allocator.dupe(u8, data);
        const dup_key = try app.allocator.dupe(u8, config.filepath);

        // Get exclusive lock for cache update
        app.rwlock.lock();
        // Remove any existing entry
        if (app.file_cache.getEntry(config.filepath)) |entry| {
            const old_content = entry.value_ptr.content;
            const old_key = entry.value_ptr.key;
            _ = app.file_cache.remove(config.filepath);

            app.allocator.free(old_content);
            app.allocator.free(old_key);
        }

        // Add new entry
        try app.file_cache.put(dup_key, .{
            .last_fetched = std.time.milliTimestamp(),
            .content = cache_data,
            .key = dup_key,
        });
        app.rwlock.unlock();
    }

    // Serve the file and free the data after sending
    res.body = data;
    try res.write();

    // Always free the original data after sending
    app.allocator.free(data);
}

pub fn serveFile(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const config_ptr: *const StaticFileConfig = @ptrCast(@alignCast(req.route_data));
    zlog.debug("Serving file {s}", .{config_ptr.filepath});
    try serveFileFromPath(app, res, config_ptr);
}

pub fn serveFileFromWildcard(
    app: *App,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const base_config: *const StaticFileConfig = @ptrCast(@alignCast(req.route_data));
    const path = req.url.path;
    const base_path_len: usize = if (base_config.path) |p| p.len else 0;
    const filename = path[base_path_len..path.len];

    // Create a new composed filepath from the base and the wildcard part.
    const filepath = std.fs.path.join(
        app.allocator,
        &[_][]const u8{ base_config.filepath, filename },
    ) catch unreachable;
    defer app.allocator.free(filepath);

    zlog.debug("Wildcard serving file {s}", .{filepath});

    // Create a temporary updated config structure with the new filepath.
    var tmp_config = base_config.*;
    tmp_config.filepath = filepath;

    try serveFileFromPath(app, res, &tmp_config);
}

fn redirect(res: *httpz.Response) !void {
    res.status = 302;
    res.headers.add("Location", "/");
    try res.write();
}

pub fn upload(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    // Make sure the content type is multipart/form-data.
    const content_type = req.headers.get("Content-Type") orelse
        req.headers.get("content-type") orelse
        req.headers.get("CONTENT-TYPE") orelse "";
    if (std.mem.indexOf(u8, content_type, "multipart/form-data") == null) {
        return redirect(res);
    }
    const data: *httpz.key_value.MultiFormKeyValue = req.multiFormData() catch {
        return redirect(res);
    };
    var iter = data.iterator();
    var file_data: ?[]const u8 = null;
    var file_name: ?[]const u8 = null;
    var file_size: usize = 0;

    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key, "file")) {
            zlog.info("Uploading file {s}", .{entry.value.filename.?});
            file_data = entry.value.value;
            file_name = entry.value.filename;
            file_size = entry.value.value.len;
            break;
        }
    }

    if (file_data) |fdata| {
        // Write the data to the metadata file and write the contents to the file.
        const content_file = try std.fs.cwd().createFile("upload/content", .{});
        defer content_file.close();
        try content_file.writeAll(fdata);

        const metadata = .{
            .filename = file_name.?,
            .size = file_size,
            .upload_time = std.time.milliTimestamp(),
        };
        const metadata_file = try std.fs.cwd().createFile("upload/metadata.json", .{});
        defer metadata_file.close();

        const json_string = std.json.stringifyAlloc(app.allocator, metadata, .{}) catch unreachable;
        defer app.allocator.free(json_string);

        try metadata_file.writeAll(json_string);

        if (app.current_upload) |cu| {
            cu.deinit();
        }
        app.current_upload = try std.json.parseFromSlice(std.json.Value, app.allocator, json_string, .{});
    }
    return redirect(res);
}

pub fn getUpload(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    if (app.current_upload) |current| {
        try res.json(current.value, .{});
    } else {
        try res.json("{}", .{});
    }
}

pub fn downloadFile(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    if (app.current_upload) |current| {
        const obj = current.value.object;
        const filename = obj.get("filename").?.string;
        const file_size: usize = @intCast(obj.get("size").?.integer);
        // Read the file content
        const file_content = try std.fs.cwd().readFileAlloc(
            app.allocator,
            "upload/content",
            file_size,
        );
        defer app.allocator.free(file_content);

        res.headers.add("Content-Type", "application/octet-stream");
        const content_disposition = try std.fmt.allocPrint(
            app.allocator,
            "attachment; filename=\"{s}\"",
            .{filename},
        );
        defer app.allocator.free(content_disposition);
        res.headers.add("Content-Disposition", content_disposition);
        const content_length = try std.fmt.allocPrint(app.allocator, "{d}", .{file_size});
        defer app.allocator.free(content_length);
        res.headers.add("Content-Length", content_length);

        res.body = file_content;
        try res.write();
    }

    return redirect(res);
}

pub fn ws(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    // Could do authentication or anything else before upgrading the connection
    // The context is any arbitrary data you want to pass to Client.init.
    const ctx = Client.Context{
        .user_id = std.time.milliTimestamp(),
        .app = app,
    };

    // The first parameter, Client, ***MUST*** be the same as Handler.WebSocketHandler
    // I'm sorry about the awkwardness of that.
    // It's undefined behavior if they don't match, and it _will_ behave weirdly/crash.
    if (try httpz.upgradeWebsocket(Client, req, res, &ctx) == false) {
        res.status = 500;
        res.body = "invalid websocket";
    }
    // unsafe to use req or res at this point!
}
