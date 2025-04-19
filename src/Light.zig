const std = @import("std");
const Packet = @import("./Packet.zig");

const Address = std.net.Address;
const Allocator = std.mem.Allocator;
const Socket = std.posix.socket_t;
const assert = std.debug.assert;
const print = std.debug.print;

const Self = @This();

pub const default_target = .{0} ** 6;

pub const min_kelvin = 3200;
pub const max_kelvin = 9000;

addr: Address,
target: [6]u8 = .{0} ** 6,
store: [256]?*Packet = .{null} ** 256,
sequence: u8 = 0,

hue: u16 = 0,
saturation: u16 = 0,
brightness: u16 = 0,
kelvin: u16 = 0,
power: bool = false,
label_buffer: [32:0]u8 = .{0} ** 32,

pub const GetState = packed struct {
    // 0 to 65535 scaled between 0° and 360°
    hue: u16 = 0,
    // 0 to 65535 scaled between 0% and 100%
    saturation: u16 = 0,
    // 0 to 65535 scaled between 0% and 100%
    brightness: u16 = 0,
    /// Range 2500 (warm) to 9000 (cool)
    kelvin: u16 = 0,
    // Reserved
    _r1: u16 = 0,
    /// Should be 0 or 65535
    power: u16 = 0,
    /// 32 byte null terminated string
    label: u256 = undefined,
    // Reserved
    _r2: u64 = 0,
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

pub const GetPower = packed struct {
    /// Should be 0 or 65535
    level: u16 = 0,
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
pub fn callback(self: *Self, allocator: Allocator, packet: *Packet) !void {
    // Aquire MAC address from initial state
    if (std.mem.eql(u8, &self.target, &default_target)) {
        assert(packet.getType() == .light_state);
        @memcpy(&self.target, packet.target());
    } else {
        assert(std.mem.eql(u8, &self.target, packet.target()));
    }
    self.freeSequence(allocator, packet.sequence());
    assert(packet.size() == packet.payload().len + Packet.min_packet_size);
    switch (packet.getType()) {
        .light_state => {
            var state_buf = try allocator.alloc(u8, 52);
            defer allocator.free(state_buf);
            @memcpy(state_buf, packet.payload()[0..52]);
            const state: *GetState = @ptrCast(@alignCast(state_buf[0..52]));
            assert(state.kelvin >= min_kelvin);
            assert(state.kelvin <= max_kelvin);
            assert(state.power == 0 or state.power == std.math.maxInt(u16));
            self.hue = state.hue;
            self.saturation = state.saturation;
            self.brightness = state.brightness;
            self.power = state.power == std.math.maxInt(u16);
            @memcpy(&self.label_buffer, std.mem.asBytes(&state.label));
        },
        .light_state_power => {
            var state_buf = try allocator.alloc(u8, 2);
            defer allocator.free(state_buf);
            @memcpy(state_buf, packet.payload()[0..2]);
            const state: *GetPower = @ptrCast(@alignCast(state_buf[0..2]));
            print("{any}\n", .{state});
        },
        else => {
            print("Unknown packet:\n{any}\n", .{packet});
        },
    }
    print("from: {any} (mac: {x}), type: {s}, label: '{s}'\n", .{
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

/// Send UDP packet to device
pub fn send(self: *Self, socket: Socket, buf: []const u8) !void {
    const sent = try std.posix.sendto(socket, buf, 0, &self.addr.any, self.addr.getOsSockLen());
    assert(sent == buf.len);
}

/// Request state update
pub fn getState(self: *Self, allocator: Allocator, socket: Socket) !void {
    const packet = try self.create(allocator, .light_get);
    try self.send(socket, packet.buf);
}

/// Request power update
pub fn getPower(self: *Self, allocator: Allocator, socket: Socket) !void {
    const packet = try self.create(allocator, .light_get_power);
    try self.send(socket, packet.buf);
}

/// Toggle power on or off
pub fn setPower(self: *Self, allocator: Allocator, socket: Socket, power: bool) !void {
    const packet = try self.create(allocator, .light_set_power);
    var payload = SetPower{};
    payload.level = if (power) std.math.maxInt(u16) else 0;
    const buf = try std.mem.concat(allocator, u8, &.{ packet.buf, std.mem.asBytes(&payload) });
    defer allocator.free(buf);
    try self.send(socket, buf);
}
