const std = @import("std");

const isPrint = std.ascii.isPrint;
const isWhitespace = std.ascii.isWhitespace;

const Self = @This();

buf: [1024]u8 = .{0} ** 1024,
idx: [256]u8 = .{0} ** 256,
len: usize = 0,
index: usize = 0,

pub fn init(input: []const u8) Self {
    var args = Self{};
    for (input) |c| if (!isPrint(c)) return args;
    const trim = std.mem.trim(u8, input, " \t\n");
    @memcpy(args.buf[0..trim.len], input[0..trim.len]);
    var start: u8 = 0;
    for (trim, 0..) |c, i| {
        const last = i == trim.len - 1;
        if (!isWhitespace(c) and !last) continue;
        if (last or start != i) {
            const end: u8 = @intCast(if (last) i + 1 else i);
            args.idx[args.len * 2] = start;
            args.idx[args.len * 2 + 1] = end;
            args.len += 1;
        }
        start = @intCast(i + 1);
    }
    return args;
}

pub fn reset(self: *Self) void {
    self.index = 0;
}

pub fn at(self: *Self, i: usize) ?[]const u8 {
    if (i >= self.len) return null;
    return self.buf[self.idx[i * 2]..self.idx[i * 2 + 1]];
}

pub fn next(self: *Self) ?[]const u8 {
    const result = self.peek() orelse return null;
    self.index += 1;
    return result;
}

pub fn nexteql(self: *Self, arg: []const u8) bool {
    if (self.peeql(arg)) {
        _ = self.next();
        return true;
    }
    return false;
}

pub fn peek(self: *Self) ?[]const u8 {
    return self.at(self.index);
}

pub fn peeql(self: *Self, arg: []const u8) bool {
    if (self.peek()) |a| return std.mem.eql(u8, a, arg);
    return false;
}

test "empty" {
    var cmd = Self{};
    try std.testing.expectEqual(0, cmd.len);
    try std.testing.expectEqual(null, cmd.next());
}

test "parse" {
    var cmd: Self = .init("command one");
    try std.testing.expectEqual(2, cmd.len);
    try std.testing.expectEqualSlices(u8, cmd.idx[0..4], &.{ 0, 7, 8, 11 });
    try std.testing.expectEqualSlices(u8, cmd.peek().?, "command");
    try std.testing.expectEqualSlices(u8, cmd.next().?, "command");
    try std.testing.expectEqualSlices(u8, cmd.peek().?, "one");
    try std.testing.expectEqualSlices(u8, cmd.next().?, "one");
    try std.testing.expectEqual(null, cmd.peek());
    try std.testing.expectEqual(null, cmd.next());
    cmd.reset();
    try std.testing.expectEqualSlices(u8, cmd.next().?, "command");
}

test "parse more" {
    var cmd: Self = .init("command 1 2  3  ");
    try std.testing.expectEqual(4, cmd.len);
    try std.testing.expectEqualSlices(u8, cmd.idx[0..8], &.{ 0, 7, 8, 9, 10, 11, 13, 14 });
}

test "iterate" {
    var cmd: Self = .init("one two three");
    try std.testing.expectEqualSlices(u8, cmd.peek().?, "one");
    try std.testing.expectEqualSlices(u8, cmd.next().?, "one");
    try std.testing.expectEqualSlices(u8, cmd.peek().?, "two");
    try std.testing.expectEqualSlices(u8, cmd.next().?, "two");
    try std.testing.expectEqualSlices(u8, cmd.next().?, "three");
    try std.testing.expectEqual(null, cmd.peek());
    try std.testing.expectEqual(null, cmd.next());
    cmd.reset();
    try std.testing.expectEqualSlices(u8, cmd.next().?, "one");
}
