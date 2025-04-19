const std = @import("std");

const Allocator = std.mem.Allocator;

const Self = @This();

lights: []struct {
    label: []const u8,
    addr: []const u8,
    mac: []const u8,
},

/// Read zon config file from home directory
pub fn init(allocator: Allocator) !Self {
    const path = std.posix.getenv("HOME") orelse @panic("no HOME env");
    var dir = try std.fs.openDirAbsolute(path, .{});
    dir = try dir.openDir(".config/zun", .{});
    const file = try dir.openFile("zun.zon", .{});
    defer file.close();
    const reader = file.reader();
    var conf: [1024 * 10]u8 = @splat(0);
    const read = try reader.readAll(&conf);
    return std.zon.parse.fromSlice(
        Self,
        allocator,
        conf[0..read :0],
        null,
        .{ .free_on_error = true },
    );
}
