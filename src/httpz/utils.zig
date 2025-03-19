const std = @import("std");
const httpz = @import("httpz");

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
