const std = @import("std");
const Packet = @import("./Packet.zig");

const Address = std.net.Address;
const Allocator = std.mem.Allocator;

const Self = @This();

pub const default_target = .{0} ** 6;

addr: Address,
target: [6]u8 = .{0} ** 6,
sequence: u8 = 0,

pub fn create(self: *Self, allocator: Allocator, packet_type: Packet.Type) !Packet {
    self.sequence +%= 1;
    if (self.sequence == 0) self.sequence += 1;
    var packet: Packet = try .init(allocator);
    packet.setType(packet_type);
    packet.setSequence(self.sequence);
    // Use device IP as unique client ID
    packet.setSource(std.mem.asBytes(&self.addr.in.sa.addr));
    // Add device MAC address target if defined
    if (!std.mem.eql(u8, &self.target, &default_target)) {
        packet.setTarget(&self.target);
    }
    return packet;
}

// test "init light" {
//     var light_1: Self = .{ .addr = undefined };
//     var light_2: Self = .{ .addr = undefined };
//     try std.testing.expect(std.mem.eql(
//         u8,
//         &light_1.source,
//         &light_2.source,
//     ) == false);
// }

test "create packet" {
    var light: Self = .{ .addr = undefined };
    var packet_1 = try light.create(std.testing.allocator, .get_label);
    defer packet_1.deinit(std.testing.allocator);
    // try std.testing.expectEqualSlices(u8, &light.source, packet_1.source());
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
