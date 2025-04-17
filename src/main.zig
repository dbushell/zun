const std = @import("std");
const builtin = @import("builtin");
const lib = @import("zun_lib");

const Packet = @import("./Packet.zig");
const Allocator = std.mem.Allocator;
const posix = std.posix;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator, const is_debug = alloc: {
        break :alloc switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    std.debug.print("Zun!\n", .{});

    const socket = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );
    defer posix.close(socket);

    const addr = try std.net.Address.parseIp("0.0.0.0", 56700);
    try posix.bind(socket, &addr.any, addr.getOsSockLen());

    var buf: [Packet.max_packet_size]u8 = undefined;

    while (true) {
        // const len = try posix.recvfrom(socket, &buf, 0, null, null);
        const len = try posix.recv(socket, &buf, 0);
        if (std.mem.eql(u8, buf[0..3], "end")) {
            break;
        }
        const packet = Packet.initBuffer(arena, buf[0..len]) catch |err| switch (err) {
            error.OutOfMemory => break,
            else => {
                std.debug.print("Packet error: {s}\n", .{@errorName(err)});
                continue;
            },
        };
        std.debug.print("`{s}`\n", .{packet.buf});
    }
}

test {
    std.testing.refAllDecls(@This());
}

// test "simple test" {
//     var list = std.ArrayList(i32).init(std.testing.allocator);
//     defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
//     try list.append(42);
//     try std.testing.expectEqual(@as(i32, 42), list.pop());
// }

// test "use other module" {
//     try std.testing.expectEqual(@as(i32, 150), lib.add(100, 50));
// }

// test "fuzz example" {
//     const Context = struct {
//         fn testOne(context: @This(), input: []const u8) anyerror!void {
//             _ = context;
//             // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
//             try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
//         }
//     };
//     try std.testing.fuzz(Context{}, Context.testOne, .{});
// }
