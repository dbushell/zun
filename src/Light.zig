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
    label: [32]u8 = undefined,
    _r2: u64 = 0,
};

/// Returned by `get_power` (116)
pub const StatePower = packed struct {
    level: u16 = 0,
};

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
        std.debug.print("{any}\n", .{p});
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
pub fn callback(self: *Self, allocator: Allocator, packet: Packet) void {
    // Aquire MAC address from initial state
    if (std.mem.eql(u8, &self.target, &default_target)) {
        assert(packet.getType() == .light_state);
        @memcpy(&self.target, packet.target());
    } else {
        assert(std.mem.eql(u8, &self.target, packet.target()));
    }
    self.freeSequence(allocator, packet.sequence());
    print("{any}: [{s}]\n", .{ self.addr, @tagName(packet.getType()) });
    print("{any}\n", .{packet.payload()});
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
