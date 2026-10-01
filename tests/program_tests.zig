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

/// The same model written with fallible callbacks: no `catch "Error"` needed.
const FallibleModel = struct {
    count: i32 = 0,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
    };

    pub fn init(self: *FallibleModel, _: *zz.Context) !zz.Cmd(Msg) {
        self.* = .{};
        return .none;
    }

    pub fn update(self: *FallibleModel, _: Msg, _: *zz.Context) !zz.Cmd(Msg) {
        self.count += 1;
        return .none;
    }

    pub fn view(self: *const FallibleModel, ctx: *const zz.Context) ![]const u8 {
        return std.fmt.allocPrint(ctx.allocator, "Count: {d}", .{self.count});
    }
};

test "Program accepts models whose callbacks return error unions" {
    // Forces the runtime's tick/render/dispatch paths to be analysed against a
    // fallible model, which is where the `try` has to line up.
    testing.refAllDecls(zz.Program(FallibleModel));
    testing.refAllDecls(zz.Program(DummyModel));

    try testing.expect(zz.model.returnsError(@TypeOf(FallibleModel.view)));
    try testing.expect(!zz.model.returnsError(@TypeOf(DummyModel.view)));
}

test "SubProgram mirrors the fallibility of its child" {
    const Fallible = zz.SubProgram(FallibleModel, FallibleModel.Msg);
    const Plain = zz.SubProgram(DummyModel, DummyModel.Msg);
    testing.refAllDecls(Fallible);
    testing.refAllDecls(Plain);

    try testing.expect(zz.model.returnsError(@TypeOf(Fallible.view)));
    try testing.expect(!zz.model.returnsError(@TypeOf(Plain.view)));
}

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

test "Program.send dispatches same-thread messages immediately" {
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
    try testing.expectEqual(@as(usize, 1), program.model.update_count);

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

/// Rejects one kind of message, so a queued batch fails part-way through.
const RejectingModel = struct {
    accepted: usize = 0,

    pub const Msg = union(enum) {
        nop: void,
        reject: void,
    };

    pub fn init(_: *RejectingModel, _: *zz.Context) zz.Cmd(Msg) {
        return .none;
    }

    pub fn update(self: *RejectingModel, msg: Msg, _: *zz.Context) !zz.Cmd(Msg) {
        switch (msg) {
            .nop => self.accepted += 1,
            .reject => return error.Rejected,
        }
        return .none;
    }

    pub fn view(_: *const RejectingModel, _: *const zz.Context) []const u8 {
        return "";
    }
};

fn pushRejectingBatch(program: *zz.Program(RejectingModel)) void {
    program.send(.{ .nop = {} }) catch unreachable;
    program.send(.{ .reject = {} }) catch unreachable;
    program.send(.{ .nop = {} }) catch unreachable;
    program.send(.{ .nop = {} }) catch unreachable;
}

test "a failing update leaves the rest of the queued batch for the next drain" {
    var env_map: std.process.Environ.Map = .init(testing.allocator);
    defer env_map.deinit();

    var program = zz.Program(RejectingModel).init(
        testing.allocator,
        testing.io,
        &env_map,
    );
    defer program.deinit();

    program.model = .{};
    program.context.allocator = program.arena.allocator();

    const thread = try std.Thread.spawn(.{}, pushRejectingBatch, .{&program});
    thread.join();

    try testing.expectError(error.Rejected, program.drainMessageQueue());
    try testing.expectEqual(@as(usize, 1), program.model.accepted);

    try program.drainMessageQueue();
    try testing.expectEqual(@as(usize, 3), program.model.accepted);
}

test "Program.send dispatches same-thread frame-backed payloads immediately" {
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

    const text = try std.fmt.allocPrint(program.context.allocator, "frame-text-{d}", .{42});
    try program.send(.{ .text = text });
    try testing.expectEqualSlices(u8, "frame-text-42", program.model.last_text);
}
