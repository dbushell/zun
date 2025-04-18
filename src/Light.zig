const std = @import("std");
const Packet = @import("./Packet.zig");

const Address = std.net.Address;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const print = std.debug.print;

const Self = @This();

pub const default_target = .{0} ** 6;

addr: Address,
target: [6]u8 = .{0} ** 6,
label_buffer: [32:0]u8 = .{0} ** 32,
store: [256]?*Packet = .{null} ** 256,
sequence: u8 = 0,

/// Returned by `get` (101)
pub const State = packed struct {
    // 0 to 65535 scaled between 0° and 360°
    hue: u16 = 0,
    // 0 to 65535 scaled between 0% and 100%
    saturation: u16 = 0,
    // 0 to 65535 scaled between 0% and 100%
    brightness: u16 = 0,
    /// Range 2500 (warm) to 9000 (cool)
    kelvin: u16 = 0,
    _r1: u16 = 0,
    power: u16 = 0,
    // label: [32]u8 = undefined,
    // _r2: u64 = 0,
};

/// Returned by `get_power` (116)
// pub const StatePower = packed struct {
//     level: u16 = 0,
// };

pub const SetColor = packed struct {
    _r1: u8 = 0,
    // 0 to 65535 scaled between 0° and 360°
    hue: u16 = 0,
    // 0 to 65535 scaled between 0% and 100%
    saturation: u16 = 0,
    // 0 to 65535 scaled between 0% and 100%
    brightness: u16 = 0,
    /// Range 2500 (warm) to 9000 (cool)
    kelvin: u16 = 0,
    // Color transition time in milliseconds
    duration: u32 = 0,
};

pub const SetPower = packed struct {
    /// Must be either 0 or 65535
    level: u16 = 0,
    /// Power level transition time in milliseconds
    duration: u32 = 0,
};

pub fn init(addr: Address) Self {
    return .{ .addr = addr };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    for (0..self.store.len) |i| if (self.store[i]) |p| {
        p.deinit(allocator);
        allocator.destroy(p);
        self.store[i] = null;
    };
    self.* = undefined;
}

/// Derive unique client ID from device IP
pub fn source(self: *Self) *align(4) [4]u8 {
    return std.mem.asBytes(&self.addr.in.sa.addr);
}

/// Device name
pub fn label(self: *Self) []const u8 {
    return std.mem.span(@as([*:0]const u8, self.label_buffer[0.. :0]));
}

// Compare case-insensitive label
pub fn compareLabel(self: *Self, compare_label: []const u8) bool {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    return std.mem.eql(
        u8,
        std.ascii.lowerString(&a, self.label()),
        std.ascii.lowerString(&b, compare_label),
    );
}

/// Clear packet memory at index if set
pub fn freeSequence(self: *Self, allocator: Allocator, index: u8) void {
    if (self.store[index]) |p| {
        p.deinit(allocator);
        allocator.destroy(p);
        self.store[index] = null;
    }
}

/// Increment message number (clears previous store)
pub fn nextSequence(self: *Self, allocator: Allocator) u8 {
    self.sequence +%= 1;
    if (self.sequence == 0) self.sequence = 1;
    self.freeSequence(allocator, self.sequence);
    return self.sequence;
}

/// Handle packets recieved from this device
pub fn callback(self: *Self, allocator: Allocator, packet: *Packet) void {
    // Aquire MAC address from initial state
    if (std.mem.eql(u8, &self.target, &default_target)) {
        assert(packet.getType() == .light_state);
        @memcpy(&self.target, packet.target());
    } else {
        assert(std.mem.eql(u8, &self.target, packet.target()));
    }
    self.freeSequence(allocator, packet.sequence());

    switch (packet.getType()) {
        .light_state => {
            assert(packet.size() == packet.payload().len + Packet.min_packet_size);
            // var state_buf: [12]u8 = .{0} ** 12;
            // @memcpy(&state_buf, packet.payload()[0..12]);
            // const state: *State = @ptrCast(@alignCast(&state_buf));
            @memcpy(&self.label_buffer, packet.payload()[12..44]);
            // print("{any}\n'{s}' '{d}'\n", .{state});
        },
        else => {
            print("Unknown packet:\n{any}\n", .{packet});
        },
    }
    // if (packet.getType() == .light_state_power) {
    //     assert(packet.size() == packet.payload().len + Packet.min_packet_size);
    //     const payload = packet.payload();
    //     const state: *StatePower = @constCast(@ptrCast(@alignCast(payload)));
    //     // state = @constCast(@ptrCast(@alignCast(packet.payload())));
    //     print("{any}\n", .{state});
    // }
    print("from: {any} (mac: {x}), type: '{s}'', label: '{s}'\n", .{
        self.addr,
        self.target,
        @tagName(packet.getType()),
        self.label(),
    });
}

pub fn create(self: *Self, allocator: Allocator, packet_type: Packet.Type) !*Packet {
    const sequence = self.nextSequence(allocator);
    var packet = try allocator.create(Packet);
    packet.* = try .init(allocator);
    packet.setType(packet_type);
    packet.setSequence(sequence);
    packet.setSource(self.source());
    // Add device MAC address target if defined
    if (!std.mem.eql(u8, &self.target, &default_target)) {
        packet.setTarget(&self.target);
    }
    self.store[sequence] = packet;
    std.debug.print("CREATE: {x}\n", .{packet.buf});
    return packet;
}

pub fn getState(self: *Self, allocator: Allocator, sockfd: std.posix.socket_t) !void {
    const packet = try self.create(allocator, .light_get);
    _ = try std.posix.sendto(
        sockfd,
        packet.buf,
        0,
        &self.addr.any,
        self.addr.getOsSockLen(),
    );
}

pub fn setPower(self: *Self, allocator: Allocator, sockfd: std.posix.socket_t, power: bool) !void {
    const packet = try self.create(allocator, .light_set_power);
    const payload = SetPower{
        .level = if (power) std.math.maxInt(u16) else 0,
    };
    const payload_buf = std.mem.asBytes(&payload);
    const buf = try std.mem.concat(allocator, u8, &.{ packet.buf, payload_buf });
    defer allocator.free(buf);
    _ = try std.posix.sendto(
        sockfd,
        buf,
        0,
        &self.addr.any,
        self.addr.getOsSockLen(),
    );
}
