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
        try client.conn.writeText("Hello, from the server!");
    }

    pub fn clientMessage(self: *Client, data: []const u8) !void {
        const msg = data;
        // If the data is a string, strip the quotes
        // if (data[0] == '"' and data[data.len - 1] == '"') {
        //     msg = data[1 .. data.len - 1];
        // }
        zlog.info("WebSocket client message: {s}", .{msg});
        return self.conn.writeText(msg);
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
