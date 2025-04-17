const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();

buf: []const u8 = undefined,
header: *Header = undefined,

pub const packet_protocol = 1024;

pub const min_packet_size = 36;
pub const max_packet_size = 1024;

pub const Error = error{
    OutOfMemory,
    BadPacketSize,
    InvalidHeader,
};

pub const Header = packed struct {
    size: u16,
    origin: u2 = 0,
    tagged: bool = false,
    addressable: bool = true,
    protocol: u12 = 1024,
    source: u32,
    target: u64 = 0,
    _r1: u48 = 0,
    _r2: u6 = 0,
    ack_required: bool = false,
    res_required: bool = false,
    sequence: u8 = 0,
    _r3: u64 = 0,
    type: u8 = 0,
    _r4: u16 = 0,
};

pub const Type = enum(u8) {
    invalid = 0,
    get_service = 2,
    state_service = 3,
    get_host_info = 12,
    state_host_info = 13,
    get_host_firmware = 14,
    state_host_firmware = 15,
    get_wifi_info = 16,
    state_wifi_info = 17,
    get_wifi_firmware = 18,
    state_wifi_firmware = 19,
    get_power = 20,
    set_power = 21,
    state_power = 22,
    get_label = 23,
    set_label = 24,
    state_label = 25,
    get_version = 32,
    state_version = 33,
    get_info = 34,
    state_info = 35,
    acknowledgement = 45,
    get_location = 48,
    state_location = 50,
    get_group = 51,
    state_group = 53,
    echo_request = 58,
    echo_response = 59,
    light_get = 101,
    light_set_color = 102,
    light_state = 107,
    light_get_power = 116,
    light_set_power = 117,
    light_state_power = 118,
};

/// Parse from UDP packet and validate
pub fn initBuffer(allocator: Allocator, src: []const u8) Error!Self {
    if (src.len < min_packet_size or src.len > max_packet_size) {
        return error.BadPacketSize;
    }
    const buf = try allocator.alloc(u8, src.len);
    errdefer allocator.free(buf);
    @memcpy(buf[0..], src);
    const packet: Self = .{
        .buf = buf,
        .header = @ptrCast(@alignCast(buf[0..min_packet_size])),
    };
    if (packet.protocol() != packet_protocol) {
        return error.InvalidHeader;
    }
    if (packet.type() == .invalid) {
        return error.InvalidHeader;
    }
    if (packet.size() < min_packet_size or packet.size() > max_packet_size) {
        return error.BadPacketSize;
    }
    return packet;
}

/// Free the internal buffer
pub fn deinit(self: Self, allocator: Allocator) void {
    allocator.free(self.buf);
}

/// Packet byte length (header + payload)
pub fn size(self: Self) u16 {
    return self.header.size;
}

/// Protocol number: must be 1024 (decimal)
pub fn protocol(self: Self) u16 {
    return self.header.protocol << 4;
}

/// Unique identifier set by client
pub fn source(self: Self) *const [4]u8 {
    return std.mem.asBytes(&self.header.source);
}

/// Device MAC address
pub fn target(self: Self) *const [6]u8 {
    return std.mem.asBytes(&self.header.target)[0..6];
}

/// Message type of payload
pub fn @"type"(self: Self) Type {
    return std.meta.intToEnum(Type, self.header.type) catch return .invalid;
}

/// Return packet bytes after header
pub fn payload(self: Self) []const u8 {
    return self.buf[36..self.size()];
}

test "parse packet header" {
    var buf: [1024]u8 = .{0} ** 1024;
    const test_packet = .{ 68, 0, 0, 20, 235, 185, 233, 241, 208, 115, 213, 38, 132, 206, 0, 0, 76, 73, 70, 88, 86, 50, 0, 0, 0, 157, 63, 208, 246, 233, 173, 0, 25, 0, 0, 0, 75, 105, 116, 99, 104, 101, 110 };
    std.mem.copyForwards(u8, &buf, &test_packet);
    const packet: Self = try .initBuffer(std.testing.allocator, &buf);
    defer packet.deinit(std.testing.allocator);
    const state_label: []const u8 = std.mem.span(@as(
        [*:0]const u8,
        @ptrCast(packet.payload()),
    ));
    try std.testing.expectEqual(1024, packet.protocol());
    try std.testing.expectEqual(68, packet.size());
    try std.testing.expectEqual(Type.state_label, packet.type());
    try std.testing.expectEqualSlices(u8, "\xEB\xB9\xE9\xF1", packet.source());
    try std.testing.expectEqualSlices(u8, "\xD0\x73\xD5\x26\x84\xCE", packet.target());
    try std.testing.expectEqualSlices(u8, "Kitchen", state_label);
}
