const std = @import("std");
const Packet = @import("./Packet.zig");

const Address = std.net.Address;
const Allocator = std.mem.Allocator;
const Socket = std.posix.socket_t;
const assert = std.debug.assert;
const print = std.debug.print;

const Self = @This();

pub const max_u16 = std.math.maxInt(u16);
pub const min_kelvin = 2500;
pub const max_kelvin = 9000;
pub const default_target = .{0} ** 6;

pub const Error = error{
    InvalidDegrees,
    InvalidPercentage,
    InvalidKelvin,
};

addr: Address,
target: [6]u8 = default_target,
store: [256]?*Packet = .{null} ** 256,
sequence: u8 = 0,

hue: u16 = 0,
saturation: u16 = 0,
brightness: u16 = 0,
kelvin: u16 = 0,
power: bool = false,
label_buffer: [32:0]u8 = .{0} ** 32,

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

pub fn init(addr: Address) Self {
    return .{ .addr = addr };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    for (0..self.store.len) |i| self.freeSequence(allocator, @truncate(i));
    self.* = undefined;
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

/// Derive unique client ID from device IP
pub fn getSource(self: *Self) *align(4) [4]u8 {
    return std.mem.asBytes(&self.addr.in.sa.addr);
}

/// Device name
pub fn getLabel(self: *Self) []const u8 {
    return std.mem.span(@as([*:0]const u8, self.label_buffer[0.. :0]));
}

// Compare case-insensitive label
pub fn compareLabel(self: *Self, compare_label: []const u8) bool {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    return std.mem.eql(
        u8,
        std.ascii.lowerString(&a, self.getLabel()),
        std.ascii.lowerString(&b, compare_label),
    );
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
            assert(state.power == 0 or state.power == max_u16);
            self.hue = state.hue;
            self.saturation = state.saturation;
            self.brightness = state.brightness;
            self.power = state.power == max_u16;
            @memcpy(&self.label_buffer, std.mem.asBytes(&state.label));
        },
        .light_state_power => {
            var state_buf = try allocator.alloc(u8, 2);
            defer allocator.free(state_buf);
            @memcpy(state_buf, packet.payload()[0..2]);
            const state: *GetPower = @ptrCast(@alignCast(state_buf[0..2]));
            self.power = state.level == max_u16;
        },
        else => {
            print("Unknown packet:\n{any}\n", .{packet});
        },
    }
    print("from: {any} (mac: {x}), type: {s}, label: '{s}'\n", .{
        self.addr,
        self.target,
        @tagName(packet.getType()),
        self.getLabel(),
    });
}

pub fn create(self: *Self, allocator: Allocator, packet_type: Packet.Type) !*Packet {
    const sequence = self.nextSequence(allocator);
    var packet = try allocator.create(Packet);
    packet.* = try .init(allocator);
    packet.setType(packet_type);
    packet.setSequence(sequence);
    packet.setSource(self.getSource());
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
    var payload = SetPower{
        .level = if (power) max_u16 else 0,
    };
    const buf = try std.mem.concat(allocator, u8, &.{ packet.buf, std.mem.asBytes(&payload) });
    defer allocator.free(buf);
    try self.send(socket, buf);
}

/// Hue rotate between 0° and 360°
pub fn setHue(self: *Self, degrees: u16) Error!void {
    if (degrees > 360) return error.InvalidDegrees;
    self.hue = @truncate(@divFloor(@as(usize, degrees) * max_u16, 360));
}

/// Saturation between 0% and 100%
pub fn setSaturation(self: *Self, percent: u8) Error!void {
    if (percent > 100) return error.InvalidPercentage;
    self.saturation = @truncate(@divFloor(@as(usize, percent) * max_u16, 100));
}

/// Brightness between 0% and 100%
pub fn setBrightness(self: *Self, percent: u8) Error!void {
    if (percent > 100) return error.InvalidPercentage;
    self.brightness = @truncate(@divFloor(@as(usize, percent) * max_u16, 100));
}

/// Kelvin range 2500 (warm) to 9000 (cool)
pub fn setKelvin(self: *Self, value: u16) Error!void {
    if (value < min_kelvin or value > max_kelvin) return error.InvalidKelvin;
    self.kelvin = value;
}

/// Adjust hue, saturation, brightness, and kelvin
pub fn setHSBK(self: *Self, h: u16, s: u8, b: u8, k: u16) Error!void {
    try self.setHue(h);
    try self.setSaturation(s);
    try self.setBrightness(b);
    try self.setKelvin(k);
}

/// Change colour profile
pub fn setColor(self: *Self, allocator: Allocator, socket: Socket) !void {
    const packet = try self.create(allocator, .light_set_color);
    var payload = SetColor{
        .hue = self.hue,
        .saturation = self.saturation,
        .brightness = self.brightness,
        .kelvin = self.kelvin,
    };
    const buf = try std.mem.concat(allocator, u8, &.{ packet.buf, std.mem.asBytes(&payload) });
    defer allocator.free(buf);
    try self.send(socket, buf);
}

test "set hue" {
    var light = Self{ .addr = undefined };
    try light.setHue(0);
    try std.testing.expectEqual(0, light.hue);
    try light.setHue(360);
    try std.testing.expectEqual(max_u16, light.hue);
    try light.setHue(123);
    try std.testing.expectEqual(22391, light.hue);
    try std.testing.expectError(error.InvalidDegrees, light.setHue(361));
}

test "set saturation" {
    var light = Self{ .addr = undefined };
    try light.setSaturation(0);
    try std.testing.expectEqual(0, light.saturation);
    try light.setSaturation(100);
    try std.testing.expectEqual(max_u16, light.saturation);
    try light.setSaturation(42);
    try std.testing.expectEqual(27524, light.saturation);
    try std.testing.expectError(error.InvalidPercentage, light.setSaturation(101));
}

test "set brightness" {
    var light = Self{ .addr = undefined };
    try light.setBrightness(0);
    try std.testing.expectEqual(0, light.brightness);
    try light.setBrightness(100);
    try std.testing.expectEqual(max_u16, light.brightness);
    try light.setBrightness(42);
    try std.testing.expectEqual(27524, light.brightness);
    try std.testing.expectError(error.InvalidPercentage, light.setBrightness(101));
}

test "set kelvin" {
    var light = Self{ .addr = undefined };
    try light.setKelvin(min_kelvin);
    try std.testing.expectEqual(min_kelvin, light.kelvin);
    try light.setKelvin(max_kelvin);
    try std.testing.expectEqual(max_kelvin, light.kelvin);
    try light.setKelvin(max_kelvin - min_kelvin);
    try std.testing.expectEqual(max_kelvin - min_kelvin, light.kelvin);
    try std.testing.expectError(error.InvalidKelvin, light.setKelvin(min_kelvin - 1));
    try std.testing.expectError(error.InvalidKelvin, light.setKelvin(max_kelvin + 1));
}
