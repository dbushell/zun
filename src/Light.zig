const std = @import("std");
const Allocator = std.mem.Allocator;
const Packet = @import("./Packet.zig");

const Self = @This();

sequence: u8 = 0,
source: [4]u8 = undefined,
target: [6]u8 = undefined,

var prng = std.Random.DefaultPrng.init(0);
var rng = prng.random();

pub fn init() Self {
    var light = Self{};
    rng.bytes(&light.source);
    return light;
}

pub fn create(self: *Self, allocator: Allocator, packet_type: Packet.Type) !Packet {
    self.sequence +%= 1;
    if (self.sequence == 0) self.sequence += 1;
    var packet: Packet = try .init(allocator);
    packet.setType(packet_type);
    packet.setSource(&self.source);
    packet.setSequence(self.sequence);
    return packet;
}

test "init light" {
    const light_1 = Self.init();
    const light_2 = Self.init();
    try std.testing.expect(std.mem.eql(
        u8,
        &light_1.source,
        &light_2.source,
    ) == false);
}

test "create packet" {
    var light = Self.init();
    var packet_1 = try light.create(std.testing.allocator, .get_label);
    defer packet_1.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &light.source, packet_1.source());
    try std.testing.expectEqual(1, packet_1.sequence());
    try std.testing.expectEqual(Packet.Type.get_label, packet_1.getType());
    // Test sequence increment
    var packet_2 = try light.create(std.testing.allocator, .get_power);
    defer packet_2.deinit(std.testing.allocator);
    try std.testing.expectEqual(2, packet_2.sequence());
    try std.testing.expectEqual(Packet.Type.get_power, packet_2.getType());
    // Test sequence wrapping
    light.sequence = 255;
    var packet_3 = try light.create(std.testing.allocator, .get_info);
    defer packet_3.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, packet_3.sequence());
}
