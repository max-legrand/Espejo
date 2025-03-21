const std = @import("std");
const httpz = @import("httpz");
const state = @import("state.zig");
const websocket = httpz.websocket;
const zlog = @import("zlog");

pub const Client = struct {
    conn: *websocket.Conn,
    appState: *state.State,

    pub const Context = struct {
        appState: *state.State,
    };

    pub fn init(conn: *websocket.Conn, ctx: *const Context) !Client {
        const client_ptr = try ctx.appState.allocator.create(Client);
        try ctx.appState.ws_connections.append(client_ptr);
        client_ptr.* = Client{
            .conn = conn,
            .appState = ctx.appState,
        };
        return client_ptr.*;
    }

    pub fn afterInit(client: *Client) !void {
        zlog.info("WebSocket client connected", .{});
        _ = client;
    }

    const Message = struct {
        action: []const u8,
        data: ?[]const u8,
    };

    pub fn clientMessage(self: *Client, data: []const u8) !void {
        const msg = data;
        var arena = std.heap.ArenaAllocator.init(self.appState.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const messageJson = try std.json.parseFromSlice(Message, allocator, msg, .{});
        const message = messageJson.value;
        zlog.info("Message: {s}", .{data});

        if (std.mem.eql(u8, message.action, "setClipboard")) {
            self.appState.allocator.free(self.appState.clipboard);
            self.appState.clipboard = try self.appState.allocator.dupe(u8, message.data.?);
            try broadcast(self.appState, msg);
        }

        if (std.mem.eql(u8, message.action, "clearUpload")) {
            try state.clearUploadDir(allocator);
            const response = Message{
                .action = "clearUpload",
                .data = null,
            };
            const resonse_string = try std.json.stringifyAlloc(allocator, response, .{});
            try broadcast(
                self.appState,
                resonse_string,
            );
        }

        if (std.mem.eql(u8, message.action, "uploadFile")) {
            if (self.appState.current_upload) |cu| {
                const response = Message{
                    .action = "uploadFile",
                    .data = cu.filename,
                };
                const response_string = try std.json.stringifyAlloc(allocator, response, .{});
                try broadcast(self.appState, response_string);
            } else {
                zlog.warn("No current upload", .{});
                return error.NoUpload;
            }
        }
    }

    pub fn close(self: *Client) void {
        for (self.appState.ws_connections.items, 0..) |client, i| {
            if (client == self) {
                _ = self.appState.ws_connections.swapRemove(i);
                break;
            }
        }
    }
};

fn broadcast(appState: *state.State, message: []const u8) !void {
    for (appState.ws_connections.items) |client| {
        client.conn.writeText(message) catch {};
    }
}
