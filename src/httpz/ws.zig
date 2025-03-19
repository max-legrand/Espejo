const std = @import("std");
const httpz = @import("httpz");
const app_module = @import("app.zig");
const App = app_module.App;

pub const Client = struct {
    user_id: i64,
    conn: *httpz.websocket.Conn,
    app: *App,
    is_registered: bool = false,

    pub const Context = struct { user_id: i64, app: *App };

    pub fn init(conn: *httpz.websocket.Conn, ctx: *const Context) !Client {
        const client = Client{
            .conn = conn,
            .user_id = ctx.user_id,
            .app = ctx.app,
        };
        return client;
    }

    pub fn afterInit(self: *Client) !void {
        try self.app.registerWebsocket(self);
        self.is_registered = true;

        const msg = .{ .action = "none", .data = "Welcome!" };
        const data = try std.json.stringifyAlloc(self.app.allocator, msg, .{});
        defer self.app.allocator.free(data);
        try self.conn.write(data);
    }

    pub fn clientMessage(self: *Client, data: []const u8) !void {
        return self.conn.write(data);
    }

    pub fn close(self: *Client) void {
        if (self.is_registered) {
            self.app.unregisterWebsocket(self);
            self.is_registered = false;
        }
    }
};
