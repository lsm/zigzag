const std = @import("std");
const testing = std.testing;
const zz = @import("zigzag");

const DummyModel = struct {
    update_count: usize = 0,
    last_text: []const u8 = "",

    pub const Msg = union(enum) {
        nop: void,
        text: []const u8,
        quit: void,
    };

    pub fn init(_: *DummyModel, _: *zz.Context) zz.Cmd(Msg) {
        return .none;
    }

    pub fn update(self: *DummyModel, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        self.update_count += 1;
        return switch (msg) {
            .nop => .none,
            .text => |text| blk: {
                self.last_text = text;
                break :blk .none;
            },
            .quit => .quit,
        };
    }

    pub fn view(_: *const DummyModel, _: *const zz.Context) []const u8 {
        return "";
    }
};

test "Program.init context allocator is stable before start and can be rebound to arena" {
    var env_map: std.process.Environ.Map = .init(testing.allocator);
    defer env_map.deinit();
    var program = zz.Program(DummyModel).init(
        testing.allocator,
        testing.io,
        &env_map,
    );
    defer program.deinit();

    const backing_ptr = @intFromPtr(testing.allocator.ptr);
    const init_context_allocator_ptr = @intFromPtr(program.context.allocator.ptr);
    try testing.expectEqual(backing_ptr, init_context_allocator_ptr);

    program.context.allocator = program.arena.allocator();
    const arena_ptr = @intFromPtr(&program.arena);
    const rebound_context_allocator_ptr = @intFromPtr(program.context.allocator.ptr);
    try testing.expectEqual(arena_ptr, rebound_context_allocator_ptr);
}

test "Program.send queues messages until main thread drains them" {
    var env_map: std.process.Environ.Map = .init(testing.allocator);
    defer env_map.deinit();

    var program = zz.Program(DummyModel).init(
        testing.allocator,
        testing.io,
        &env_map,
    );
    defer program.deinit();

    program.model = .{};
    program.context.allocator = program.arena.allocator();
    try program.send(.{ .nop = {} });
    try testing.expectEqual(@as(usize, 0), program.model.update_count);

    try program.drainMessageQueue();
    try testing.expectEqual(@as(usize, 1), program.model.update_count);
}

const ThreadArg = struct {
    program: *zz.Program(DummyModel),
};

fn pushMessages(arg: ThreadArg) void {
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        arg.program.send(.{ .nop = {} }) catch unreachable;
    }
}

test "Program.send accepts messages from background threads" {
    var env_map: std.process.Environ.Map = .init(testing.allocator);
    defer env_map.deinit();

    var program = zz.Program(DummyModel).init(
        testing.allocator,
        testing.io,
        &env_map,
    );
    defer program.deinit();

    program.model = .{};
    program.context.allocator = program.arena.allocator();

    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, pushMessages, .{ThreadArg{ .program = &program }});
    }
    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(usize, 0), program.model.update_count);
    try program.drainMessageQueue();
    try testing.expectEqual(@as(usize, 256), program.model.update_count);
}

test "Program.tick drains queued messages before resetting frame allocator" {
    var env_map: std.process.Environ.Map = .init(testing.allocator);
    defer env_map.deinit();

    var program = zz.Program(DummyModel).init(
        testing.allocator,
        testing.io,
        &env_map,
    );
    defer program.deinit();

    program.model = .{};
    program.context.allocator = program.arena.allocator();
    program.context.frame = 0;
    program.last_frame_time = 0;
    program.last_view_hash = std.hash.Wyhash.hash(0, "");
    program.terminal = null;

    const text = try std.fmt.allocPrint(program.context.allocator, "frame-text-{d}", .{42});
    try program.send(.{ .text = text });

    try program.drainMessageQueue();
    try testing.expectEqualSlices(u8, "frame-text-42", program.model.last_text);
}
