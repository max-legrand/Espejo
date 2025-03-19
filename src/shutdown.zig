const std = @import("std");
const httpz = @import("httpz");
const main = @import("main.zig");

fn shutdown(_: c_int) callconv(.C) void {
    if (main.server_instance) |server| {
        main.server_instance = null;
        main.state_instance.?.stopWS();
        server.stop();
    }
}

pub fn init_sig_handler() void {
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);
    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);
}
