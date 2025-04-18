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

    // Store devices
    var lights: std.ArrayListUnmanaged(*Light) = .empty;
    defer {
        for (lights.items) |light| {
            light.deinit(allocator);
            allocator.destroy(light);
        }
        lights.deinit(allocator);
    }

    // Read config file from home directory
    const home_path = posix.getenv("HOME") orelse @panic("no HOME env");
    const home = try std.fs.openDirAbsolute(home_path, .{});
    const file = try home.openFile(".zun", .{});
    const reader = file.reader();
    var conf: [1024 * 10]u8 = undefined;
    const read = try reader.readAll(&conf);
    file.close();

    // Iterate lines and parse IP addresses
    var conf_lines = std.mem.tokenizeScalar(u8, conf[0..read], '\n');
    while (conf_lines.next()) |line| {
        const addr = Address.parseIp4(line, 56700) catch continue;
        const light = try allocator.create(Light);
        light.* = Light.init(addr);
        try lights.append(allocator, light);
    }
    if (lights.items.len == 0) {
        @panic("no device IP addresses found");
    }

    // Setup UDP socket
    const sockfd = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );
    defer posix.close(sockfd);
    const addr = try Address.parseIp("0.0.0.0", 56700);
    try posix.bind(sockfd, &addr.any, addr.getOsSockLen());

    // Request initial states
    for (lights.items) |light| {
        std.debug.print("Light: {any}\n", .{light.addr});
        try light.getState(allocator, sockfd);
    }

    while (true) {
        // Read buffer
        var buf: [Packet.max_packet_size]u8 = undefined;
        var src_addr: std.posix.sockaddr.in align(4) = undefined;
        var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        const len = try posix.recvfrom(sockfd, &buf, 0, @ptrCast(&src_addr), &addrlen);

        // Handle commands
        var iter = std.mem.tokenizeScalar(u8, std.mem.trim(u8, buf[0..len], " \n"), ' ');
        if (iter.next()) |command| {
            if (std.mem.eql(u8, command, "end")) {
                break;
            }
            const command_on = std.mem.eql(u8, command, "on");
            const command_off = std.mem.eql(u8, command, "off");
            if (command_on or command_off) {
                if (iter.next()) |label| {
                    const maybe: ?*Light = blk: {
                        for (lights.items) |l| if (l.compareLabel(label)) break :blk l;
                        break :blk null;
                    };
                    if (maybe) |light| {
                        light.setPower(allocator, sockfd, command_on) catch |err| {
                            std.debug.print("{s}\n", .{@errorName(err)});
                        };
                    }
                }
                continue;
            }
        }

        // Find known device
        const from = Address.initPosix(@ptrCast(&src_addr));
        const maybe: ?*Light = blk: {
            for (lights.items) |l| if (l.addr.eql(from)) break :blk l;
            break :blk null;
        };

        // Handle device messages
        if (maybe) |light| {
            var packet = Packet.initBuffer(allocator, buf[0..len]) catch |err| switch (err) {
                error.OutOfMemory => break,
                else => {
                    std.debug.print("Packet error: {s}\n", .{@errorName(err)});
                    continue;
                },
            };
            defer packet.deinit(allocator);
            light.callback(allocator, &packet);
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
