const std = @import("std");
const zap = @import("zap");
const zlog = @import("zlog");

const State = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) State {
        return .{
            .alloc = alloc,
        };
    }

    pub fn getIndex(_: *State, req: zap.Request) void {
        if (req.methodAsEnum() != .GET) return;
        req.sendBody("<html><body><h1>Hello, world!</h1></body></html>") catch return;
    }

    pub fn getJson(self: *State, req: zap.Request) void {
        if (req.methodAsEnum() != .GET) return;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        const alloc = arena.allocator();
        defer arena.deinit();

        const data = .{
            .hello = "world",
        };
        const jsonData = std.json.stringifyAlloc(
            alloc,
            data,
            .{},
        ) catch return;

        req.sendJson(jsonData) catch return;
    }
};

const Context = struct {
    log: ?LogMiddleware = null,
};
const Handler = zap.Middleware.Handler(Context);
const LogMiddleware = struct {
    handler: Handler,

    pub fn getHandler(self: *LogMiddleware) *Handler {
        return &self.handler;
    }

    pub fn onRequest(self: *LogMiddleware, req: zap.Request, ctx: *Context) bool {}
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .thread_safe = true,
    }).init;
    const allocator = gpa.allocator();

    defer {
        switch (gpa.deinit()) {
            .ok => std.process.exit(0),
            .leak => std.process.exit(1),
        }
    }

    try zlog.initGlobalLogger(
        .INFO,
        true,
        "scratchpad",
        null,
        null,
        allocator,
    );
    defer zlog.deinitGlobalLogger();
    zlog.info("Tearing off a scratchpad 📄", .{});

    {
        var router = zap.Router.init(allocator, .{});
        defer router.deinit();
        var state = State.init(allocator);

        try router.handle_func("/", &state, &State.getIndex);
        try router.handle_func("/json", &state, &State.getJson);

        var listener = try zap.Middleware.Listener(void).init(.{
            .port = 3000,
            .on_request = router.on_request_handler(),
            .log = false,
            .max_clients = 100000,
            .interface = "0.0.0.0",
        }, Handler);
        try listener.listen();

        zlog.info("Listening on 0.0.0.0:3000", .{});

        // start worker threads
        zap.start(.{
            .threads = 2,
            .workers = 2,
        });
    }
}
