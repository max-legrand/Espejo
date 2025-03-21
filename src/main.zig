const std = @import("std");
const httpz = @import("httpz");
const zlog = @import("zlog");
const shutdown = @import("shutdown.zig");
const state = @import("state.zig");
const ws = @import("ws.zig");
const wslog = @import("wslog.zig");

const State = state.State;
const PORT = 3000;

pub const std_options = std.Options{ .logFn = wslog.log };

pub var server_instance: ?*httpz.Server(*State) = null;
pub var state_instance: ?*State = null;

pub fn main() !void {
    if (comptime @import("builtin").os.tag == .windows) {
        zlog.warn("While this code should work fine on Windows, the signal handler is untested! Use at your own discretion!", .{});
    }
    shutdown.init_sig_handler();

    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .thread_safe = true,
    }).init;
    const gpa_alloc = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa_alloc);
    const allocator = arena.allocator();

    try zlog.initGlobalLogger(
        .DEBUG,
        true,
        "espejo",
        null,
        null,
        allocator,
    );
    var appState = State.init(allocator);
    state_instance = &appState;
    try appState.preloadFile("web/dist/index.html", .HTML);
    try appState.preloadDirectoryRecursive("web/dist/assets");

    {
        var server = try httpz.Server(*State).init(
            allocator,
            .{
                .address = "0.0.0.0",
                .port = PORT,
                .request = .{
                    .max_form_count = 10,
                    .max_param_count = 10,
                    .max_multiform_count = 10,
                    .max_body_size = 1024 * 1024 * 10, // 10MB
                },
            },
            &appState,
        );
        defer server.deinit();

        var router = try server.router(.{});
        router.get("/", index, .{});
        // router.get("/wasm", wasm, .{});
        router.get("/assets/:file", assets, .{});
        router.get("/getUpload", getUpload, .{});
        router.get("/download/:file", downloadFile, .{});
        router.post("/upload", uploadFile, .{});
        router.get("/clearUpload", clearUpload, .{});
        router.get("/ws", wsFn, .{});
        router.get("/getContent", getContent, .{});

        server_instance = &server;
        zlog.info("Colocación un espejo en http://localhost:3000", .{});
        try server.listen();
    }
    appState.deinit();
    zlog.deinitGlobalLogger();
    arena.deinit();
    _ = gpa.deinit();
}

fn index(appState: *State, _: *httpz.Request, res: *httpz.Response) !void {
    const cached_file = try appState.getOrLoadFile("web/dist/index.html", .HTML);
    res.content_type = cached_file.content_type;
    res.body = cached_file.data;
    try state.setCacheHeaders(res, 1);
    try res.write();
}

fn wasm(appState: *State, _: *httpz.Request, res: *httpz.Response) !void {
    const cached_file = try appState.getOrLoadFile("zig-out/bin/wasm.wasm", .WASM);
    res.header("Content-Encoding", "gzip");
    res.content_type = cached_file.content_type;
    res.body = if (cached_file.compressed_data) |compressed_data| compressed_data else cached_file.data;
    try state.setCacheHeaders(res, 10);
    try res.write();
}

fn assets(appState: *State, req: *httpz.Request, res: *httpz.Response) !void {
    const path = req.param("file").?;
    const filepath = try std.fmt.allocPrint(
        res.arena,
        "web/dist/assets/{s}",
        .{path},
    );
    res.content_type = state.getMimeType(path) orelse httpz.ContentType.BINARY;

    const cached_file = try appState.getOrLoadFile(filepath, res.content_type);
    res.body = cached_file.data;
    try res.write();
}

fn getUpload(appState: *State, _: *httpz.Request, res: *httpz.Response) !void {
    if (appState.current_upload) |cu| {
        try res.json(cu.*, .{});
    } else {
        zlog.warn("No current upload", .{});
        return error.NoUpload;
    }
}

fn redirect(res: *httpz.Response) !void {
    res.status = 302;
    res.headers.add("Location", "/");
    try res.write();
}

fn downloadFile(appState: *State, req: *httpz.Request, res: *httpz.Response) !void {
    const path = req.param("file").?;
    const filepath = try std.fmt.allocPrint(
        res.arena,
        "upload/{s}",
        .{path},
    );
    res.content_type = state.getMimeType(path) orelse httpz.ContentType.BINARY;
    if (appState.current_upload) |cu| {
        const cwd = std.fs.cwd();
        const file = try cwd.openFile(filepath, .{});
        defer file.close();

        const data = try file.readToEndAlloc(res.arena, std.math.maxInt(usize));
        res.body = data;
        res.content_type = state.getMimeType(cu.filename) orelse .BINARY;

        const content_disposition = try std.fmt.allocPrint(
            res.arena,
            "attachment; filename=\"{s}\"; filename*=UTF-8''{s}",
            .{ cu.filename, cu.filename },
        );
        res.headers.add("Content-Disposition", content_disposition);
    } else {
        try redirect(res);
    }
}

fn uploadFile(appState: *State, req: *httpz.Request, res: *httpz.Response) !void {
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
            file_data = entry.value.value;
            file_name = entry.value.filename;
            file_size = entry.value.value.len;
            break;
        }
    }

    if (file_data) |fdata| {
        try state.clearUploadDir(res.arena);
        // Write the data to the metadata file and write the contents to the file.
        const owned_file_name = appState.allocator.dupe(u8, file_name.?) catch return redirect(res);
        const filepath = try std.fmt.allocPrint(res.arena, "upload/{s}", .{owned_file_name});
        const content_file = try std.fs.cwd().createFile(filepath, .{});
        defer content_file.close();
        try content_file.writeAll(fdata);

        // Create a heap-allocated Upload struct
        const upload_ptr = try appState.allocator.create(state.Upload);
        upload_ptr.* = state.Upload{
            .filename = owned_file_name,
            .size = file_size,
            .upload_time = std.time.milliTimestamp(),
        };

        const metadata_file = try std.fs.cwd().createFile("upload/metadata.json", .{});
        defer metadata_file.close();

        const json_string = std.json.stringifyAlloc(res.arena, upload_ptr.*, .{}) catch unreachable;

        try metadata_file.writeAll(json_string);

        if (appState.current_upload) |cu| {
            cu.deinit(appState.allocator);
        }
        appState.current_upload = upload_ptr;
        try res.json(.{ .status = "success" }, .{});
    } else {
        try res.json(.{ .status = "error" }, .{});
    }
}

fn getContent(appState: *State, _: *httpz.Request, res: *httpz.Response) !void {
    res.body = appState.clipboard;
}

fn clearUpload(appState: *State, _: *httpz.Request, res: *httpz.Response) !void {
    if (appState.current_upload) |cu| {

        // Remove the files
        try state.clearUploadDir(res.arena);

        cu.deinit(appState.allocator);
        appState.current_upload = null;
        try res.json(.{ .status = "success" }, .{});
    } else {
        try res.json(.{ .status = "error" }, .{});
    }
}

fn wsFn(appState: *state.State, req: *httpz.Request, res: *httpz.Response) !void {
    const ctx = ws.Client.Context{ .appState = appState };

    if (try httpz.upgradeWebsocket(ws.Client, req, res, &ctx) == false) {
        res.status = 500;
        res.body = "Invalid WebSocket";
    }
    const ws_worker: *httpz.websocket.server.Worker(ws.Client) = @ptrCast(@alignCast(res.conn.ws_worker));
    ws_worker.worker.allocator = res.arena;
    // Do not use `res` from this point on
}
