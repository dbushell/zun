const std = @import("std");
const builtin = @import("builtin");

const Zonfig = @import("./Zonfig.zig");
const Args = @import("./Args.zig");
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

    // Read config
    const parsed = Zonfig.init(allocator) catch |err| {
        std.debug.print("parse error: {s}\n", .{@errorName(err)});
        @panic("invalid zon config");
    };
    defer std.zon.parse.free(allocator, parsed);

    // Device store
    var lights: std.ArrayListUnmanaged(*Light) = .empty;
    defer {
        for (lights.items) |light| {
            light.deinit(allocator);
            allocator.destroy(light);
        }
        lights.deinit(allocator);
    }

    // Setup lights
    for (parsed.lights) |item| {
        const addr = Address.parseIp4(item.addr, 56700) catch continue;
        const light = try allocator.create(Light);
        light.* = Light.init(addr);
        try lights.append(allocator, light);
    }
    if (lights.items.len == 0) {
        @panic("no lights found in config");
    }

    // Setup UDP socket
    const socket = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );
    defer posix.close(socket);
    const addr = try Address.parseIp("0.0.0.0", 56700);
    try posix.bind(socket, &addr.any, addr.getOsSockLen());

    // Request states
    for (lights.items) |light| {
        try light.getState(allocator, socket);
    }

    while (true) {
        // Read buffer
        var buf: [Packet.max_packet_size]u8 = @splat(0);
        var src_addr: posix.sockaddr align(4) = undefined;
        var src_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const len = try posix.recvfrom(socket, &buf, 0, @ptrCast(&src_addr), &src_len);
        const src_ip = Address.initPosix(@ptrCast(&src_addr));

        // Handle ASCII commands
        var args: Args = .init(buf[0..len]);

        if (args.peeql("end")) break;

        // Preemptively find light by label
        const match: ?*Light = find: {
            if (args.at(1)) |label| {
                if (Light.find(&lights, label)) |light| break :find light;
            }
            break :find null;
        };

        if (args.peeql("on")) if (match) |light| {
            light.setPower(allocator, socket, true) catch |err| {
                std.debug.print("{s}\n", .{@errorName(err)});
            };
            continue;
        };

        if (args.peeql("off")) if (match) |light| {
            light.setPower(allocator, socket, false) catch |err| {
                std.debug.print("{s}\n", .{@errorName(err)});
            };
            continue;
        };

        if (args.peeql("reset")) if (match) |light| {
            try light.setHSBK(0, 0, 100, 3700);
            light.setColor(allocator, socket) catch |err| {
                std.debug.print("{s}\n", .{@errorName(err)});
            };
            continue;
        };

        // Find known device
        const device: ?*Light = find: {
            for (lights.items) |l| if (l.addr.eql(src_ip)) break :find l;
            break :find null;
        };

        // Handle device messages
        if (device) |light| {
            var packet = Packet.initBuffer(allocator, buf[0..len]) catch |err| switch (err) {
                error.OutOfMemory => break,
                else => {
                    std.debug.print("Packet error: {s}\n", .{@errorName(err)});
                    continue;
                },
            };
            defer packet.deinit(allocator);
            try light.callback(allocator, &packet);
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
