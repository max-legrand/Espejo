const std = @import("std");
const builtin = @import("builtin");
const zlog = @import("zlog");
const httpz = @import("httpz");
const utils = @import("utils.zig");
const ws = @import("ws.zig");
const app = @import("app.zig");
const App = app.App;
const FileCache = app.FileCache;
const StaticFileConfig = app.StaticFileConfig;
const routes = @import("routes.zig");

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_name = @tagName(scope);
    if (std.mem.eql(u8, scope_name, "websocket")) {
        return;
    }

    // We only recognize 4 log levels in this application.
    const level_txt = switch (level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
    const prefix1 = level_txt;
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    // Print the message to stderr, silently ignoring any errors
    std.debug.print(prefix1 ++ prefix2 ++ format ++ "\n", args);
}
pub const std_options = std.Options{
    .logFn = log,
};

var server_instance: ?*httpz.Server(*App) = null;
var gpa_instance: ?*std.heap.GeneralPurposeAllocator(.{}) = null;

// Signal handler function
fn handleSignal(sig: c_int) callconv(.C) void {
    if (sig == std.posix.SIG.INT) {
        zlog.info("Received SIGINT, shutting down...", .{});
        if (server_instance) |server| {
            server.stop();
        }
    }
}

fn createFile(file_path: []const u8, mime_type: ?httpz.ContentType, expiry: ?i64) StaticFileConfig {
    return .{
        .filepath = file_path,
        .path = null,
        .mime_type = mime_type,
        .cache_expiry_time = expiry,
    };
}

pub fn main() !void {
    const sigint = std.posix.SIG.INT;
    std.posix.sigaction(sigint, &std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .thread_safe = true,
    }).init;
    gpa_instance = &gpa;
    const allocator = gpa.allocator();

    try zlog.initGlobalLogger(
        .INFO,
        true,
        "scratchpad",
        null,
        null,
        allocator,
    );

    zlog.info("Tearing off a scratchpad 📄", .{});

    var arena = std.heap.ArenaAllocator.init(allocator);
    const alloc = arena.allocator();
    defer arena.deinit();
    {
        var state = App{
            .allocator = alloc,
            .file_cache = std.StringHashMap(FileCache).init(allocator),
            .current_upload = null,
            .clients = std.ArrayList(*ws.Client).init(allocator),
        };
        try state.init();

        const port: u16 = 3000;
        var server = try httpz.Server(*App).init(alloc, .{
            .port = port,
            .address = "0.0.0.0",
            .request = .{
                .max_form_count = 10,
                .buffer_size = 10 * 1024 * 1024,
                .max_body_size = 10 * 1024 * 1024,
                .max_multiform_count = 10,
            },
        }, &state);
        server_instance = &server;

        var router = try server.router(.{});

        // Index
        const idx = createFile("web/dist/index.html", null, 1 * std.time.ms_per_s);
        router.get("/", routes.serveFile, .{
            .data = &idx,
        });

        // Wasm
        const wasm = createFile("zig-out/bin/wasm.wasm", httpz.ContentType.WASM, 1 * std.time.ms_per_s);
        router.get("/wasm.wasm", routes.serveFile, .{
            .data = &wasm,
        });

        router.get("/getUpload", routes.getUpload, .{});
        router.get("/downloadFile", routes.downloadFile, .{});

        // ws
        router.get("/ws", routes.ws, .{});

        // Static files
        const static_file_config: StaticFileConfig = .{
            .filepath = "static",
            .path = "/static/",
            .mime_type = null,
            // Always cache static
            .cache_expiry_time = null,
        };
        router.get("/static/*", routes.serveFileFromWildcard, .{ .data = &static_file_config });

        // Web files
        const app_file_config: StaticFileConfig = .{
            .filepath = "web/dist/assets",
            .path = "/assets/",
            .mime_type = null,
            .cache_expiry_time = 1 * std.time.ms_per_s,
        };
        router.get("/assets/*", routes.serveFileFromWildcard, .{ .data = &app_file_config });

        router.post("/upload", routes.upload, .{});
        zlog.info("Listening at http://localhost:{d}", .{port});
        try server.listen();
    }

    // This will only be reached if server.listen() returns normally
    // (not via signal handler)
    zlog.deinitGlobalLogger();

    // Check for memory leaks
    const leak_check = gpa.deinit();
    if (leak_check == .leak) {
        std.debug.print("Memory leak detected!\n", .{});
        return error.MemoryLeak;
    }
}
