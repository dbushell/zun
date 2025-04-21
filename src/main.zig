const std = @import("std");
const builtin = @import("builtin");

const Zonfig = @import("./Zonfig.zig");
const Args = @import("./Args.zig");
const Packet = @import("./Packet.zig");
const Light = @import("./Light.zig");

const Address = std.net.Address;
const Allocator = std.mem.Allocator;
const Socket = std.posix.socket_t;
const posix = std.posix;

var run = std.atomic.Value(bool).init(true);

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

    // Setup threads
    const poll_thread = try std.Thread.spawn(.{}, poll, .{ &lights, allocator, socket });
    defer poll_thread.join();
    const listen_thread = try std.Thread.spawn(.{}, listen, .{ &lights, allocator, socket });
    defer listen_thread.join();
}

pub fn listen(lights: *std.ArrayListUnmanaged(*Light), allocator: Allocator, socket: Socket) !void {
    while (run.load(.monotonic)) {
        // Read buffer
        var buf: [Packet.max_packet_size]u8 = @splat(0);
        var src_addr: posix.sockaddr align(4) = undefined;
        var src_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const len = try posix.recvfrom(socket, &buf, 0, @ptrCast(&src_addr), &src_len);
        const src_ip = Address.initPosix(@ptrCast(&src_addr));

        // Handle ASCII commands
        var args: Args = .init(buf[0..len]);
        if (args.len > 0) {
            if (args.peeql("quit")) {
                run.store(false, .monotonic);
                return;
            }
            // Light name must be second argument
            const light: *Light = find: {
                if (args.at(1)) |label| if (Light.find(lights, label)) |l| break :find l;
                continue;
            };
            var hsbk = false;
            if (args.peeql("reset")) {
                try light.setHSBK(0, 0, 100, 3700);
                hsbk = true;
            }
            if (args.peeql("power")) if (args.at(2)) |arg| {
                const level = std.fmt.parseInt(u1, arg, 10) catch continue;
                light.setPower(level == 1);
                light.sendPower(allocator, socket) catch |err| {
                    std.debug.print("{s}\n", .{@errorName(err)});
                };
            };
            if (args.peeql("brightness")) if (args.at(2)) |arg| {
                const value = std.fmt.parseInt(u8, arg, 10) catch continue;
                light.setBrightness(value) catch continue;
                hsbk = true;
            };
            if (hsbk) light.sendHSBK(allocator, socket) catch |err| {
                std.debug.print("{s}\n", .{@errorName(err)});
            };
            // Always return JSON state
            var json_buf: [1024]u8 = .{0} ** 1024;
            const json = light.toJson(&json_buf) catch continue;
            _ = try posix.sendto(socket, json, 0, &src_addr, src_len);
            continue;
        }

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
        } else {
            std.debug.print("Unknown: {x}\n", .{buf[0..len]});
        }
    }
}

/// Update light states on a timer
pub fn poll(lights: *std.ArrayListUnmanaged(*Light), allocator: Allocator, socket: Socket) !void {
    const sleep_min_ms: usize = 100;
    const sleep_max_ms: usize = 5000;
    while (run.load(.monotonic)) {
        for (lights.items) |light| {
            try light.requestState(allocator, socket);
        }
        var sleep_ms: usize = 0;
        while (sleep_ms < sleep_max_ms) : (sleep_ms += sleep_min_ms) {
            if (!run.load(.monotonic)) return;
            std.time.sleep(std.time.ns_per_ms * sleep_min_ms);
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
