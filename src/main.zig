const std = @import("std");
const builtin = @import("builtin");
const lib = @import("zun_lib");

const Packet = @import("./Packet.zig");
const Light = @import("./Light.zig");

const Address = std.net.Address;
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
    // var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    // defer arena_allocator.deinit();
    // const arena = arena_allocator.allocator();

    std.debug.print("Zun!\n", .{});

    var lights: std.ArrayListUnmanaged(*Light) = .empty;
    defer {
        lights.deinit(allocator);
    }

    // Read config file from home directory
    const home_path = posix.getenv("HOME") orelse @panic("no HOME env");
    const home = try std.fs.openDirAbsolute(home_path, .{});
    const file = try home.openFile(".zun", .{});
    defer file.close();
    const reader = file.reader();
    var conf: [1024 * 10]u8 = undefined;
    const read = try reader.readAll(&conf);

    // Iterate lines and parse IP addresses
    var conf_lines = std.mem.tokenizeScalar(u8, conf[0..read], '\n');
    while (conf_lines.next()) |line| {
        const addr = Address.parseIp4(line, 56700) catch continue;
        const light = try allocator.create(Light);
        light.* = .{ .addr = addr };
        try lights.append(allocator, light);
    }

    const socket = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );
    defer posix.close(socket);

    const addr = try Address.parseIp("0.0.0.0", 56700);
    try posix.bind(socket, &addr.any, addr.getOsSockLen());

    var buf: [Packet.max_packet_size]u8 = undefined;

    for (lights.items) |light| {
        std.debug.print("Light: {any}\n", .{light.addr});
        const packet = try light.create(allocator, .get_label);
        std.debug.print("{x}\n", .{packet.buf});
        _ = try posix.sendto(
            socket,
            packet.buf,
            0,
            &light.addr.any,
            light.addr.getOsSockLen(),
        );
    }

    while (true) {
        var src_addr: std.posix.sockaddr.in align(4) = undefined;
        var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);

        const len = try posix.recvfrom(socket, &buf, 0, @ptrCast(&src_addr), &addrlen);
        if (std.mem.eql(u8, buf[0..3], "end")) {
            break;
        }
        const from = Address.initPosix(@ptrCast(&src_addr));

        const maybe: ?*Light = blk: {
            for (lights.items) |l| if (l.addr.eql(from)) break :blk l;
            break :blk null;
        };

        if (maybe) |light| {
            const packet = Packet.initBuffer(allocator, buf[0..len]) catch |err| switch (err) {
                error.OutOfMemory => break,
                else => {
                    std.debug.print("Packet error: {s}\n", .{@errorName(err)});
                    continue;
                },
            };
            defer packet.deinit(allocator);
            if (std.mem.eql(u8, &light.target, &Light.default_target)) {
                @memcpy(&light.target, packet.target());
                const p2 = try light.create(allocator, .get_label);
                defer p2.deinit(allocator);
                std.debug.print("{x}\n", .{p2.buf});
                _ = try posix.sendto(
                    socket,
                    p2.buf,
                    0,
                    &light.addr.any,
                    light.addr.getOsSockLen(),
                );
            }
            std.debug.print("Light: {any}\nfrom: \"{x}\" \nlength: {d}\n{x}\n\n", .{
                light.addr,
                light.target,
                packet.size(),
                packet.buf,
            });
        }
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
