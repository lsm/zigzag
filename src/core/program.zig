//! Program runtime for the ZigZag TUI framework.
//! Implements the Model-Update-View pattern with an event loop.
const std = @import("std");
const builtin = @import("builtin");
const Terminal = @import("../terminal/terminal.zig").Terminal;
const ansi = @import("../terminal/ansi.zig");
const keyboard = @import("../input/keyboard.zig");
const Context = @import("context.zig").Context;
const Options = @import("context.zig").Options;
const message = @import("message.zig");
const command = @import("command.zig");
const Logger = @import("log.zig").Logger;
const unicode = @import("../unicode.zig");
const Environment = @import("environment.zig").Environment;

pub const Cmd = command.Cmd;
pub const Msg = message;

const PendingImage = union(enum) {
    auto: command.ImageFile,
    kitty: command.KittyImageFile,
    data: command.ImageData,
    place_cached: command.PlaceCachedImage,
};

/// Program runtime that manages the application lifecycle
pub fn Program(comptime Model: type) type {
    // Ensure Model has required declarations
    comptime {
        if (!@hasDecl(Model, "Msg")) {
            @compileError("Model must have a 'Msg' type declaration");
        }
        if (!@hasDecl(Model, "init")) {
            @compileError("Model must have an 'init' function");
        }
        if (!@hasDecl(Model, "update")) {
            @compileError("Model must have an 'update' function");
        }
        if (!@hasDecl(Model, "view")) {
            @compileError("Model must have a 'view' function");
        }
    }

    const UserMsg = Model.Msg;
    const UserCmd = Cmd(UserMsg);

    return struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        environment: Environment,
        arena: std.heap.ArenaAllocator,
        model: Model,
        terminal: ?Terminal,
        context: Context,
        options: Options,
        running: std.atomic.Value(bool),
        message_queue: MessageQueue,
        main_thread_id: std.Thread.Id,
        /// Boot-clock epoch from which `last_frame_time` and `context.elapsed` are measured.
        /// `.boot` includes time the system was suspended, giving a monotonic reading
        /// without gaps on resume.
        clock_epoch: std.Io.Clock.Timestamp,
        last_frame_time: u64,
        /// Anchor for absolute frame pacing. Separate from `clock_epoch` so we can
        /// rebase after suspend/resume or a long-overrun frame without disturbing
        /// user-visible `context.elapsed` / `context.frame` (which `pending_tick`
        /// and `every` depend on).
        pacing_epoch: std.Io.Clock.Timestamp,
        pacing_frame_offset: u64,
        pending_tick: ?u64,
        every_interval: ?u64,
        last_every_tick: u64,
        last_view_hash: u64,
        last_line_count: usize,
        needs_repaint: bool,
        resize_deadline: ?u64,
        bottom_anchor: bool,
        last_line_widths: std.ArrayList(usize),
        last_frame: std.ArrayList(u8),
        relayout_above_split: ?usize,
        pending_image: ?PendingImage,
        logger: ?Logger,
        paste_buffer: std.array_list.Managed(u8),
        paste_pending_prefix: std.array_list.Managed(u8),
        paste_pending_end_prefix: std.array_list.Managed(u8),
        paste_active: bool,

        /// Message filter function
        filter: ?*const fn (UserMsg) ?UserMsg,

        const Self = @This();

        const MessageQueue = struct {
            mutex: std.atomic.Mutex = .unlocked,
            items: std.array_list.Managed(UserMsg),
            head: usize = 0,

            const max_drain_per_frame = 512;

            fn init(allocator: std.mem.Allocator) MessageQueue {
                return .{ .items = std.array_list.Managed(UserMsg).init(allocator) };
            }

            fn deinit(self: *MessageQueue) void {
                self.items.deinit();
                self.* = undefined;
            }

            fn push(self: *MessageQueue, m: UserMsg) !void {
                while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
                defer self.mutex.unlock();

                try self.items.append(m);
            }

            fn popBatch(self: *MessageQueue, batch: *std.array_list.Managed(UserMsg)) !void {
                while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
                defer self.mutex.unlock();

                const available = self.items.items.len - self.head;
                const count = @min(available, max_drain_per_frame);
                try batch.appendSlice(self.items.items[self.head .. self.head + count]);
                self.head += count;

                if (self.head > 0 and (self.head == self.items.items.len or self.head >= max_drain_per_frame)) {
                    self.items.replaceRangeAssumeCapacity(0, self.head, &.{});
                    self.head = 0;
                }
            }

            fn requeueFront(self: *MessageQueue, messages: []const UserMsg) !void {
                if (messages.len == 0) return;

                while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
                defer self.mutex.unlock();

                try self.items.insertSlice(self.head, messages);
            }
        };

        /// Initialize the program.
        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            environ_map: *const std.process.Environ.Map,
        ) Self {
            return initWithOptions(allocator, io, environ_map, .{});
        }

        /// Initialize with custom options.
        pub fn initWithOptions(
            allocator: std.mem.Allocator,
            io: std.Io,
            environ_map: *const std.process.Environ.Map,
            options: Options,
        ) Self {
            const arena = std.heap.ArenaAllocator.init(allocator);
            const clock_epoch = std.Io.Clock.Timestamp.now(io, .boot);
            var self = Self{
                .allocator = allocator,
                .io = io,
                .environment = .fromEnvMap(environ_map),
                .arena = arena,
                .model = undefined,
                .terminal = null,
                .context = undefined,
                .options = options,
                .running = std.atomic.Value(bool).init(false),
                .message_queue = MessageQueue.init(allocator),
                .main_thread_id = std.Thread.getCurrentId(),
                .clock_epoch = clock_epoch,
                .last_frame_time = 0,
                .pacing_epoch = clock_epoch,
                .pacing_frame_offset = 0,
                .pending_tick = null,
                .every_interval = null,
                .last_every_tick = 0,
                .last_view_hash = 0,
                .last_line_count = 0,
                .needs_repaint = false,
                .resize_deadline = null,
                .bottom_anchor = false,
                .last_line_widths = .empty,
                .last_frame = .empty,
                .relayout_above_split = null,
                .pending_image = null,
                .logger = null,
                .paste_buffer = std.array_list.Managed(u8).init(allocator),
                .paste_pending_prefix = std.array_list.Managed(u8).init(allocator),
                .paste_pending_end_prefix = std.array_list.Managed(u8).init(allocator),
                .paste_active = false,
                .filter = null,
            };

            // `self` is returned by value, so don't capture an arena allocator here.
            // It would point at this function's stack copy and dangle after return.
            self.context = Context.init(allocator, allocator, io, &self.environment);

            return self;
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            if (self.terminal) |*term| {
                term.deinit();
            }
            if (self.logger) |*l| {
                l.deinit();
            }
            self.context.deinit();
            self.last_line_widths.deinit(self.allocator);
            self.last_frame.deinit(self.allocator);
            self.message_queue.deinit();
            self.paste_buffer.deinit();
            self.paste_pending_prefix.deinit();
            self.paste_pending_end_prefix.deinit();
            self.arena.deinit();

            // Call model's deinit if it exists
            if (@hasDecl(Model, "deinit")) {
                self.model.deinit();
            }
        }

        /// Set a message filter function
        pub fn setFilter(self: *Self, f: ?*const fn (UserMsg) ?UserMsg) void {
            self.filter = f;
        }

        /// Run the program with the built-in event loop.
        /// For custom event loops, use `start()` + `tick()` instead.
        pub fn run(self: *Self) !void {
            try self.start();

            // Main event loop
            while (self.running.load(.acquire)) {
                try self.tick();
            }

            if (self.options.inline_bottom_viewport) self.finishInline();
        }

        /// Initialize the terminal and model without entering the event loop.
        /// After calling this, drive the program manually by calling `tick()`
        /// in your own loop. Check `isRunning()` to know when to stop.
        ///
        /// Example:
        /// ```
        /// try program.start();
        /// while (program.isRunning()) {
        ///     try program.tick();
        ///     // ... do other work between frames ...
        /// }
        /// ```
        pub fn start(self: *Self) !void {
            // Initialize logger if configured
            if (self.options.log_file) |log_path| {
                self.logger = Logger.init(self.io, log_path) catch null;
                if (self.logger != null) {
                    self.context._logger = &self.logger.?;
                }
            }

            // Initialize terminal
            self.terminal = try Terminal.init(self.io, &self.environment, .{
                .alt_screen = self.options.alt_screen,
                .hide_cursor = !self.options.cursor,
                .mouse = self.options.mouse,
                .alternate_scroll = self.options.alternate_scroll,
                .clear_on_setup = !self.options.inline_bottom_viewport,
                .bracketed_paste = self.options.bracketed_paste,
                .input = self.options.input,
                .output = self.options.output,
                .kitty_keyboard = self.options.kitty_keyboard,
                .osc52 = self.options.osc52,
            });

            // Set title if provided
            if (self.options.title) |title| {
                try self.terminal.?.setTitle(title);
            }

            // Get initial size
            const size = try self.terminal.?.getSize();
            self.context.width = size.cols;
            self.context.height = size.rows;
            self.context._terminal = &self.terminal.?;

            const width_caps = self.terminal.?.getUnicodeWidthCapabilities();
            const effective_width_strategy = self.resolveUnicodeWidthStrategy(width_caps.strategy);
            self.context.unicode_width_strategy = effective_width_strategy;
            self.context.terminal_mode_2027 = width_caps.mode_2027;
            self.context.kitty_text_sizing = width_caps.kitty_text_sizing;
            unicode.setWidthStrategy(effective_width_strategy);

            self.clock_epoch = std.Io.Clock.Timestamp.now(self.io, .boot);
            self.last_frame_time = self.elapsedNs();
            self.pacing_epoch = self.clock_epoch;
            self.pacing_frame_offset = 0;
            self.context.elapsed = 0;
            self.context.delta = 0;
            self.context.frame = 0;

            self.resetFrameAllocator();

            // Initialize the model
            const init_cmd = self.model.init(&self.context);
            try self.processCommand(init_cmd);

            self.running.store(true, .release);
        }

        /// Returns true if the program is still running.
        pub fn isRunning(self: *const Self) bool {
            return self.running.load(.acquire);
        }

        /// Execute a single frame: poll input, process events, render.
        pub fn tick(self: *Self) !void {
            const tick_start = self.elapsedNs();
            const actual_delta: u64 = if (self.context.frame == 0) 0 else tick_start - self.last_frame_time;
            self.last_frame_time = tick_start;

            self.context.delta = actual_delta;
            self.context.elapsed = tick_start;
            self.context.frame += 1;

            // Drain queued messages before resetting the frame arena. This preserves
            // payloads created from the previous frame allocator until delivery.
            try self.drainMessageQueue();
            if (!self.isRunning()) return;

            self.resetFrameAllocator();

            // Check for resize
            if (self.terminal.?.checkResize()) {
                const size = try self.terminal.?.getSize();
                self.context.width = size.cols;
                self.context.height = size.rows;
                self.resize_deadline = self.context.elapsed + resize_debounce_ns;
            }
            if (self.resize_deadline) |deadline| {
                if (self.context.elapsed >= deadline) {
                    self.resize_deadline = null;
                    self.needs_repaint = true;
                    if (self.options.inline_bottom_viewport) self.relayout_above_split = self.context.above_buffer.items.len;
                    if (@hasField(UserMsg, "window_size")) {
                        const cmd = self.dispatchToModel(.{ .window_size = .{
                            .width = self.context.width,
                            .height = self.context.height,
                        } });
                        try self.processCommand(cmd);
                        if (!self.isRunning()) return;
                    }
                }
            }

            // Non-blocking drain; input typed during pacing sits in the TTY buffer.
            var input_buf: [256]u8 = undefined;
            const bytes_read = try self.terminal.?.readInput(&input_buf, 0);

            if (bytes_read > 0) {
                const events = try self.parseInputEvents(input_buf[0..bytes_read]);
                for (events) |event| {
                    const user_cmd = switch (event) {
                        .key => |k| self.processKeyEvent(k),
                        .mouse => |m| self.processMouseEvent(m),
                        .none => null,
                    };
                    if (user_cmd) |cmd| {
                        try self.processCommand(cmd);
                        if (!self.isRunning()) return;
                    }
                }
            }

            // Handle pending tick
            if (self.pending_tick) |tick_ns| {
                if (self.context.elapsed >= tick_ns) {
                    self.pending_tick = null;
                    // Deliver tick to user's update if Model.Msg has a tick variant
                    if (@hasField(UserMsg, "tick")) {
                        const user_msg = UserMsg{ .tick = .{
                            .timestamp = @intCast(tick_start),
                            .delta = actual_delta,
                        } };
                        const cmd = self.dispatchToModel(user_msg);
                        try self.processCommand(cmd);
                        if (!self.isRunning()) return;
                    }
                }
            }

            // Handle repeating tick
            if (self.every_interval) |interval| {
                if (self.context.elapsed - self.last_every_tick >= interval) {
                    self.last_every_tick = self.context.elapsed;
                    if (@hasField(UserMsg, "tick")) {
                        const user_msg = UserMsg{ .tick = .{
                            .timestamp = @intCast(tick_start),
                            .delta = actual_delta,
                        } };
                        const cmd = self.dispatchToModel(user_msg);
                        try self.processCommand(cmd);
                        if (!self.isRunning()) return;
                    }
                }
            }

            // Render
            try self.render();
            try self.flushPendingImage();

            // Pace at end of tick; first tick skips so initial paint is immediate.
            const min_frame_time_ns: u64 = if (self.options.fps > 0)
                @divFloor(std.time.ns_per_s, self.options.fps)
            else
                16_666_666; // ~60fps default
            const frames_since_anchor = self.context.frame - self.pacing_frame_offset;
            if (frames_since_anchor > 1) {
                const deadline_offset_ns: u64 = frames_since_anchor * min_frame_time_ns;
                // If we've fallen far behind the schedule (long-overrun frame, or
                // boot-clock advanced past the anchor while suspended), rebase the
                // anchor instead of burst-rendering frames to "catch up."
                const elapsed_since_anchor = self.pacingElapsedNs();
                if (elapsed_since_anchor > deadline_offset_ns + 4 * min_frame_time_ns) {
                    self.pacing_epoch = std.Io.Clock.Timestamp.now(self.io, .boot);
                    self.pacing_frame_offset = self.context.frame;
                } else {
                    // Absolute deadline so sleep overshoot doesn't compound.
                    const deadline: std.Io.Clock.Timestamp = self.pacing_epoch.addDuration(.{
                        .raw = .{ .nanoseconds = @intCast(deadline_offset_ns) },
                        .clock = .boot,
                    });
                    deadline.wait(self.io) catch unreachable;
                }
            }
        }

        pub fn drainMessageQueue(self: *Self) !void {
            var batch = std.array_list.Managed(UserMsg).init(self.allocator);
            defer batch.deinit();

            try self.message_queue.popBatch(&batch);
            for (batch.items, 0..) |m, i| {
                const cmd = self.dispatchToModel(m);
                self.processCommand(cmd) catch |err| {
                    try self.message_queue.requeueFront(batch.items[i + 1 ..]);
                    return err;
                };
            }
        }

        fn appendParsedInputEvents(
            self: *Self,
            results: *std.array_list.Managed(keyboard.ParseResult),
            data: []const u8,
        ) !void {
            if (data.len == 0) return;
            const parsed = try keyboard.parseAll(self.context.allocator, data);
            try results.appendSlice(parsed);
        }

        fn appendParsedInputEventsPreservingPastePrefix(
            self: *Self,
            results: *std.array_list.Managed(keyboard.ParseResult),
            data: []const u8,
            paste_start: []const u8,
        ) !void {
            if (data.len == 0) return;
            const keep = pasteDelimiterPrefixSuffixLen(data, paste_start);
            if (keep > 1 and keep < paste_start.len) {
                const parse_len = data.len - keep;
                try self.appendParsedInputEvents(results, data[0..parse_len]);
                self.paste_pending_prefix.clearRetainingCapacity();
                try self.paste_pending_prefix.appendSlice(data[parse_len..]);
                return;
            }
            try self.appendParsedInputEvents(results, data);
        }

        fn appendPasteEvent(
            self: *Self,
            results: *std.array_list.Managed(keyboard.ParseResult),
        ) !void {
            const text = try self.context.allocator.dupe(u8, self.paste_buffer.items);
            try results.append(.{ .key = .{ .key = .{ .paste = text } } });
            self.paste_buffer.clearRetainingCapacity();
        }

        fn parseInputEvents(self: *Self, data: []const u8) ![]keyboard.ParseResult {
            const paste_start = "\x1b[200~";
            const paste_end = "\x1b[201~";
            var results = std.array_list.Managed(keyboard.ParseResult).init(self.context.allocator);
            errdefer results.deinit();

            var owned_data: ?[]u8 = null;
            defer if (owned_data) |buf| self.context.allocator.free(buf);
            var input = data;
            const pending_prefix = if (self.paste_active) &self.paste_pending_end_prefix else &self.paste_pending_prefix;
            if (pending_prefix.items.len > 0) {
                const combined = try self.context.allocator.alloc(u8, pending_prefix.items.len + data.len);
                @memcpy(combined[0..pending_prefix.items.len], pending_prefix.items);
                @memcpy(combined[pending_prefix.items.len..], data);
                pending_prefix.clearRetainingCapacity();
                owned_data = combined;
                input = combined;
            }

            var offset: usize = 0;
            while (offset < input.len) {
                if (self.paste_active) {
                    const rest = input[offset..];
                    if (std.mem.indexOf(u8, rest, paste_end)) |end_offset| {
                        try self.paste_buffer.appendSlice(rest[0..end_offset]);
                        try self.appendPasteEvent(&results);
                        self.paste_active = false;
                        self.paste_pending_end_prefix.clearRetainingCapacity();
                        offset += end_offset + paste_end.len;
                    } else {
                        const keep = pasteDelimiterPrefixSuffixLen(rest, paste_end);
                        const append_len = rest.len - keep;
                        try self.paste_buffer.appendSlice(rest[0..append_len]);
                        self.paste_pending_end_prefix.clearRetainingCapacity();
                        if (keep > 0) try self.paste_pending_end_prefix.appendSlice(rest[append_len..]);
                        offset = input.len;
                    }
                    continue;
                }

                const rest = input[offset..];
                if (std.mem.indexOf(u8, rest, paste_start)) |start_offset| {
                    try self.appendParsedInputEventsPreservingPastePrefix(&results, rest[0..start_offset], paste_start);
                    self.paste_active = true;
                    offset += start_offset + paste_start.len;
                } else {
                    try self.appendParsedInputEventsPreservingPastePrefix(&results, rest, paste_start);
                    offset = input.len;
                }
            }

            return results.toOwnedSlice();
        }

        fn pasteDelimiterPrefixSuffixLen(data: []const u8, delimiter: []const u8) usize {
            const max = @min(data.len, delimiter.len -| 1);
            var len = max;
            while (len > 0) : (len -= 1) {
                if (std.mem.eql(u8, data[data.len - len ..], delimiter[0..len])) return len;
            }
            return 0;
        }

        /// Dispatch a message to the model, applying the filter if set
        fn dispatchToModel(self: *Self, user_msg: UserMsg) UserCmd {
            if (self.filter) |f| {
                if (f(user_msg)) |filtered_msg| {
                    return self.model.update(filtered_msg, &self.context);
                }
                return .none;
            }
            return self.model.update(user_msg, &self.context);
        }

        fn processKeyEvent(self: *Self, key: keyboard.KeyEvent) ?UserCmd {
            // Check for Ctrl+C to quit
            if (key.modifiers.ctrl) {
                switch (key.key) {
                    .char => |c| {
                        if (c == 'c' and self.options.ctrl_c_quits) {
                            return .quit;
                        }
                        // Handle Ctrl+Z for suspend
                        if (c == 'z' and self.options.suspend_enabled) {
                            self.performSuspend();
                            return null;
                        }
                    },
                    else => {},
                }
            }

            // Handle paste events
            if (key.key == .paste) {
                if (@hasField(UserMsg, "paste")) {
                    const user_msg = UserMsg{ .paste = key.key.paste };
                    return self.dispatchToModel(user_msg);
                }
                // If model doesn't handle paste, send as individual key events
                if (@hasField(UserMsg, "key")) {
                    const user_msg = UserMsg{ .key = key };
                    return self.dispatchToModel(user_msg);
                }
                return null;
            }

            // Convert to user message if Model.Msg has a key variant
            if (@hasField(UserMsg, "key")) {
                const user_msg = UserMsg{ .key = key };
                return self.dispatchToModel(user_msg);
            }

            return null;
        }

        fn resolveUnicodeWidthStrategy(self: *const Self, detected: unicode.WidthStrategy) unicode.WidthStrategy {
            if (self.options.unicode_width_strategy) |forced| {
                return forced;
            }
            if (self.environment.unicode_width_override) |from_env| {
                return from_env;
            }
            return detected;
        }

        fn processMouseEvent(self: *Self, mouse_event: keyboard.MouseEvent) ?UserCmd {
            if (@hasField(UserMsg, "mouse")) {
                const user_msg = UserMsg{ .mouse = mouse_event };
                return self.dispatchToModel(user_msg);
            }

            return null;
        }

        /// Perform suspend (Ctrl+Z) — POSIX only
        fn performSuspend(self: *Self) void {
            if (builtin.os.tag == .windows) return;

            // Cleanup terminal
            if (self.terminal) |*term| {
                term.cleanup();
            }

            // Raise SIGTSTP to suspend process
            if (builtin.os.tag != .windows) {
                const posix = std.posix;
                _ = posix.raise(posix.SIG.TSTP) catch {};
            }

            // When we resume (after `fg`), re-setup terminal
            if (self.terminal) |*term| {
                term.setup() catch {};
            }

            // Avoid a large post-resume frame delta, and rebase the pacing anchor
            // so we don't burst-render to "catch up" the suspended interval.
            self.last_frame_time = self.elapsedNs();
            self.pacing_epoch = std.Io.Clock.Timestamp.now(self.io, .boot);
            self.pacing_frame_offset = self.context.frame;

            // Force re-render
            self.last_view_hash = 0;

            // Dispatch resumed message if model supports it
            if (@hasField(UserMsg, "resumed")) {
                const cmd = self.dispatchToModel(.{ .resumed = {} });
                self.processCommand(cmd) catch {};
            }
        }

        fn processCommand(self: *Self, cmd: UserCmd) !void {
            switch (cmd) {
                .none => {},
                .quit => {
                    self.running.store(false, .release);
                },
                .tick => |ns| {
                    self.pending_tick = self.context.elapsed + ns;
                },
                .every => |ns| {
                    self.every_interval = ns;
                    self.last_every_tick = self.context.elapsed;
                },
                .batch => |cmds| {
                    for (cmds) |c| {
                        try self.processCommand(c);
                    }
                },
                .sequence => |cmds| {
                    for (cmds) |c| {
                        try self.processCommand(c);
                    }
                },
                .msg => |m| {
                    const new_cmd = self.dispatchToModel(m);
                    try self.processCommand(new_cmd);
                },
                .perform => |func| {
                    if (func()) |m| {
                        const new_cmd = self.dispatchToModel(m);
                        try self.processCommand(new_cmd);
                    }
                },
                .suspend_process => {
                    self.performSuspend();
                },
                .enable_mouse => {
                    if (self.terminal) |*term| {
                        try term.enableMouse();
                    }
                },
                .disable_mouse => {
                    if (self.terminal) |*term| {
                        try term.disableMouse();
                    }
                },
                .show_cursor => {
                    if (self.terminal) |*term| {
                        const writer = term.writer();
                        try writer.writeAll(ansi.cursor_show);
                        try term.flush();
                    }
                },
                .hide_cursor => {
                    if (self.terminal) |*term| {
                        const writer = term.writer();
                        try writer.writeAll(ansi.cursor_hide);
                        try term.flush();
                    }
                },
                .enter_alt_screen => {
                    if (self.terminal) |*term| {
                        const writer = term.writer();
                        try writer.writeAll(ansi.alt_screen_enter);
                        try term.flush();
                    }
                },
                .exit_alt_screen => {
                    if (self.terminal) |*term| {
                        const writer = term.writer();
                        try writer.writeAll(ansi.alt_screen_exit);
                        try term.flush();
                    }
                },
                .set_title => |title| {
                    if (self.terminal) |*term| {
                        try term.setTitle(title);
                    }
                },
                .println => |line| {
                    if (self.options.inline_bottom_viewport) {
                        try self.context.printAbove(line);
                    } else if (self.terminal) |*term| {
                        const writer = term.writer();
                        try writer.writeAll(ansi.cursor_save);
                        try writer.writeAll(ansi.cursor_home);
                        try writer.writeAll(line);
                        try writer.writeAll("\n");
                        try writer.writeAll(ansi.cursor_restore);
                        try term.flush();
                    }
                },
                .image_file => |image| {
                    self.pending_image = .{ .auto = image };
                },
                .kitty_image_file => |image| {
                    self.pending_image = .{ .kitty = image };
                },
                .image_data => |image| {
                    self.pending_image = .{ .data = image };
                },
                .cache_image => |cache| {
                    if (self.terminal) |*term| {
                        switch (cache.source) {
                            .file => |path| {
                                _ = term.transmitKittyImageFromFile(path, .{
                                    .image_id = cache.image_id,
                                    .format = @enumFromInt(@intFromEnum(cache.format)),
                                    .quiet = cache.quiet,
                                    .pixel_width = cache.pixel_width,
                                    .pixel_height = cache.pixel_height,
                                }) catch {};
                            },
                            .data => |data| {
                                _ = term.transmitKittyImage(data, .{
                                    .image_id = cache.image_id,
                                    .format = @enumFromInt(@intFromEnum(cache.format)),
                                    .quiet = cache.quiet,
                                    .pixel_width = cache.pixel_width,
                                    .pixel_height = cache.pixel_height,
                                }) catch {};
                            },
                        }
                        term.flush() catch {};
                    }
                },
                .place_cached_image => |place| {
                    self.pending_image = .{ .place_cached = place };
                },
                .delete_image => |del| {
                    if (self.terminal) |*term| {
                        const target: @import("../terminal/terminal.zig").KittyDeleteTarget = switch (del) {
                            .by_id => |id| .{ .by_id = id },
                            .by_placement => |bp| .{ .by_placement = .{ .image_id = bp.image_id, .placement_id = bp.placement_id } },
                            .all => .all,
                        };
                        _ = term.deleteKittyImage(target) catch {};
                        term.flush() catch {};
                    }
                },
            }
        }

        fn flushPendingImage(self: *Self) !void {
            const TerminalMod = @import("../terminal/terminal.zig");
            const pending = self.pending_image orelse return;
            self.pending_image = null;
            if (self.terminal) |*term| {
                switch (pending) {
                    .auto => |image| {
                        if (!image.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_save);
                        }
                        try self.positionPendingImage(term, image);
                        const protocol: TerminalMod.ImageProtocol = switch (image.protocol) {
                            .auto => .auto,
                            .kitty => .kitty,
                            .iterm2 => .iterm2,
                            .sixel => .sixel,
                        };
                        _ = try term.drawImageFromFileWithProtocol(image.path, .{
                            .width_cells = image.width_cells,
                            .height_cells = image.height_cells,
                            .preserve_aspect_ratio = image.preserve_aspect_ratio,
                            .image_id = image.image_id,
                            .placement_id = image.placement_id,
                            .move_cursor = image.move_cursor,
                            .quiet = image.quiet,
                            .z_index = image.z_index,
                            .unicode_placeholder = image.unicode_placeholder,
                        }, protocol);
                        if (!image.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_restore);
                        }
                    },
                    .kitty => |image| {
                        if (!image.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_save);
                        }
                        try self.positionPendingImage(term, image);
                        _ = try term.drawKittyImageFromFile(image.path, .{
                            .width_cells = image.width_cells,
                            .height_cells = image.height_cells,
                            .image_id = image.image_id,
                            .placement_id = image.placement_id,
                            .move_cursor = image.move_cursor,
                            .quiet = image.quiet,
                            .z_index = image.z_index,
                            .unicode_placeholder = image.unicode_placeholder,
                        });
                        if (!image.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_restore);
                        }
                    },
                    .data => |image| {
                        if (!image.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_save);
                        }
                        try self.positionPendingImageData(term, image);
                        const protocol: TerminalMod.ImageProtocol = switch (image.protocol) {
                            .auto => .auto,
                            .kitty => .kitty,
                            .iterm2 => .iterm2,
                            .sixel => .sixel,
                        };
                        _ = try term.drawImageDataWithProtocol(image.data, .{
                            .format = @enumFromInt(@intFromEnum(image.format)),
                            .pixel_width = image.pixel_width,
                            .pixel_height = image.pixel_height,
                            .width_cells = image.width_cells,
                            .height_cells = image.height_cells,
                            .image_id = image.image_id,
                            .placement_id = image.placement_id,
                            .move_cursor = image.move_cursor,
                            .quiet = image.quiet,
                            .z_index = image.z_index,
                            .unicode_placeholder = image.unicode_placeholder,
                        }, protocol);
                        if (!image.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_restore);
                        }
                    },
                    .place_cached => |place| {
                        if (!place.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_save);
                        }
                        try self.positionPendingCachedImage(term, place);
                        _ = try term.placeKittyImage(.{
                            .image_id = place.image_id,
                            .placement_id = place.placement_id,
                            .width_cells = place.width_cells,
                            .height_cells = place.height_cells,
                            .move_cursor = place.move_cursor,
                            .quiet = place.quiet,
                            .z_index = place.z_index,
                            .unicode_placeholder = place.unicode_placeholder,
                        });
                        if (!place.move_cursor) {
                            try term.writer().writeAll(ansi.cursor_restore);
                        }
                    },
                }
                try term.flush();
            }
        }

        fn positionPendingImage(self: *Self, term: *Terminal, image: command.ImageFile) !void {
            try self.positionByPlacement(term, image.placement, image.width_cells, image.height_cells, image.row, image.col, image.row_offset, image.col_offset);
        }

        fn positionPendingImageData(self: *Self, term: *Terminal, image: command.ImageData) !void {
            try self.positionByPlacement(term, image.placement, image.width_cells, image.height_cells, image.row, image.col, image.row_offset, image.col_offset);
        }

        fn positionPendingCachedImage(self: *Self, term: *Terminal, place: command.PlaceCachedImage) !void {
            try self.positionByPlacement(term, place.placement, place.width_cells, place.height_cells, place.row, place.col, place.row_offset, place.col_offset);
        }

        fn positionByPlacement(
            self: *Self,
            term: *Terminal,
            placement: command.ImagePlacement,
            width_cells: ?u16,
            height_cells: ?u16,
            opt_row: ?u16,
            opt_col: ?u16,
            row_offset: i16,
            col_offset: i16,
        ) !void {
            var row: u16 = 0;
            var col: u16 = 0;

            switch (placement) {
                .cursor => return,
                .top_left => {
                    row = 0;
                    col = 0;
                },
                .top_center => {
                    if (width_cells) |w_cells| {
                        const term_width = @as(usize, self.context.width);
                        const image_width = @as(usize, w_cells);
                        if (term_width > image_width) {
                            col = @intCast((term_width - image_width) / 2);
                        }
                    }
                    row = 0;
                },
                .center => {
                    if (width_cells) |w_cells| {
                        const term_width = @as(usize, self.context.width);
                        const image_width = @as(usize, w_cells);
                        if (term_width > image_width) {
                            col = @intCast((term_width - image_width) / 2);
                        }
                    }
                    if (height_cells) |h_cells| {
                        const term_height = @as(usize, self.context.height);
                        const image_height = @as(usize, h_cells);
                        if (term_height > image_height) {
                            row = @intCast((term_height - image_height) / 2);
                        }
                    }
                },
            }

            if (opt_row) |r| row = r;
            if (opt_col) |c| col = c;

            const max_row = if (height_cells) |h| self.context.height -| h else self.context.height -| 1;
            const max_col = if (width_cells) |w| self.context.width -| w else self.context.width -| 1;
            row = applySignedOffsetClamped(row, row_offset, max_row);
            col = applySignedOffsetClamped(col, col_offset, max_col);

            try term.moveTo(row, col);
        }

        fn applySignedOffsetClamped(base: u16, offset: i16, max: u16) u16 {
            const base_i32 = @as(i32, @intCast(base));
            const offset_i32 = @as(i32, offset);
            const max_i32 = @as(i32, @intCast(max));
            var value = base_i32 + offset_i32;
            if (value < 0) value = 0;
            if (value > max_i32) value = max_i32;
            return @intCast(value);
        }

        /// Nanoseconds elapsed on the boot clock since `clock_epoch`.
        fn elapsedNs(self: *const Self) u64 {
            const dur = self.clock_epoch.untilNow(self.io);
            const ns = dur.raw.nanoseconds;
            if (ns <= 0) return 0;
            return @intCast(ns);
        }

        /// Nanoseconds elapsed on the boot clock since `pacing_epoch`.
        fn pacingElapsedNs(self: *const Self) u64 {
            const dur = self.pacing_epoch.untilNow(self.io);
            const ns = dur.raw.nanoseconds;
            if (ns <= 0) return 0;
            return @intCast(ns);
        }

        fn sleepNs(io: std.Io, nanoseconds: u64) void {
            if (nanoseconds == 0) return;
            std.Io.sleep(io, .fromNanoseconds(nanoseconds), .boot) catch unreachable;
        }

        fn resetFrameAllocator(self: *Self) void {
            _ = self.arena.reset(.retain_capacity);
            self.context.allocator = self.arena.allocator();
        }

        const resize_debounce_ns: u64 = 150 * std.time.ns_per_ms;

        fn render(self: *Self) !void {
            if (self.resize_deadline != null) return;
            const view_output = self.model.view(&self.context);

            // Compute hash of view output
            const view_hash = std.hash.Wyhash.hash(0, view_output);
            const has_above = self.context.hasPendingAbove();
            if (view_hash == self.last_view_hash and !has_above and !self.needs_repaint and !self.context.clear_screen_requested) return;

            const writer = self.terminal.?.writer();
            // Start synchronized output (prevents tearing on supporting terminals)
            try writer.writeAll(ansi.sync_start);
            if (self.context.clear_screen_requested) {
                self.context.clear_screen_requested = false;
                try writer.writeAll(ansi.screen_clear);
                try writer.writeAll(ansi.CSI ++ "3J");
                try writer.writeAll(ansi.cursor_home);
                self.last_line_count = 0;
                self.last_line_widths.clearRetainingCapacity();
            }

            if (self.options.inline_bottom_viewport) {
                var above: []const u8 = self.context.above_buffer.items;
                if (self.relayout_above_split) |split| {
                    self.relayout_above_split = null;
                    const at = @min(split, above.len);
                    try self.scrollLiveRegionAway(writer, above[0..at]);
                    above = above[at..];
                }
                try self.renderInlineFrame(writer, view_output, above);
            } else {
                // Move cursor home (don't clear entire screen to reduce flicker)
                try writer.writeAll(ansi.cursor_home);
                var lines = std.mem.splitScalar(u8, view_output, '\n');
                var first = true;
                var line_count: usize = 0;
                while (lines.next()) |line| {
                    if (!first) try writer.writeAll("\r\n");
                    first = false;
                    try writer.writeAll(line);
                    try writer.writeAll(ansi.line_clear_right);
                    line_count += 1;
                }
                if (self.last_line_count > line_count) {
                    var remaining = self.last_line_count - line_count;
                    while (remaining > 0) : (remaining -= 1) {
                        try writer.writeAll("\r\n");
                        try writer.writeAll(ansi.line_clear);
                    }
                }
                self.last_line_count = line_count;
            }
            self.context.above_buffer.clearRetainingCapacity();

            // End synchronized output
            try writer.writeAll(ansi.sync_end);
            try self.terminal.?.flush();

            // Save hash for comparison
            self.last_view_hash = view_hash;
            self.needs_repaint = false;
        }

        fn renderInlineFrame(self: *Self, writer: *std.Io.Writer, view_output: []const u8, above: []const u8) !void {
            const height: usize = @max(@as(usize, self.context.height), 1);
            const width: usize = @max(@as(usize, self.context.width), 1);

            var frame_lines: std.ArrayList([]const u8) = .empty;
            defer frame_lines.deinit(self.allocator);
            var skip = countLines(view_output) -| height;
            var lines = std.mem.splitScalar(u8, view_output, '\n');
            while (lines.next()) |line| {
                if (skip > 0) {
                    skip -= 1;
                    continue;
                }
                try frame_lines.append(self.allocator, line);
            }

            if (self.bottom_anchor) {
                // The cursor rests on the bottom row (scrollLiveRegionAway left
                // it there), so anchor the frame's last row to that row instead
                // of homing it to the top-left.
                self.bottom_anchor = false;
                try writer.writeAll("\r");
                if (frame_lines.items.len > 1) {
                    const up: u16 = @intCast(@min(frame_lines.items.len - 1, std.math.maxInt(u16)));
                    try ansi.cursorUp(writer, up);
                }
            } else {
                try self.moveToLiveRegionTop(writer);
            }
            try writeAboveLines(writer, above, width);

            const reuse = above.len == 0 and self.last_line_count > 0;
            var old_lines = std.mem.splitScalar(u8, self.last_frame.items, '\n');
            var next_frame: std.ArrayList(u8) = .empty;
            defer next_frame.deinit(self.allocator);
            self.last_line_widths.clearRetainingCapacity();
            for (frame_lines.items, 0..) |line, i| {
                const old = old_lines.next();
                if (i > 0) try next_frame.append(self.allocator, '\n');
                try next_frame.appendSlice(self.allocator, line);
                try self.last_line_widths.append(self.allocator, @min(inkWidth(line), width));
                if (i + 1 == frame_lines.items.len) {
                    try writer.writeAll(ansi.screen_clear_below);
                    _ = try writeClampedLine(writer, line, width);
                    break;
                }
                const unchanged = reuse and i + 1 < self.last_line_count and old != null and std.mem.eql(u8, old.?, line);
                if (unchanged) {
                    try writer.writeAll("\n");
                    continue;
                }
                const used = try writeClampedLine(writer, line, width);
                if (used < width) try writer.writeAll(ansi.line_clear_right);
                try writer.writeAll("\r\n");
            }
            self.last_line_count = frame_lines.items.len;
            self.last_frame.clearRetainingCapacity();
            try self.last_frame.appendSlice(self.allocator, next_frame.items);
        }

        fn scrollLiveRegionAway(self: *Self, writer: *std.Io.Writer, above: []const u8) !void {
            const height: usize = @max(@as(usize, self.context.height), 1);
            const width: usize = @max(@as(usize, self.context.width), 1);
            try self.moveToReflowedLiveRegionTop(writer);
            try writer.writeAll(ansi.screen_clear_below);
            try writeAboveLines(writer, above, width);
            var n: usize = 0;
            while (n < height) : (n += 1) try writer.writeAll("\r\n");
            self.bottom_anchor = true;
            self.last_line_count = 0;
            self.last_line_widths.clearRetainingCapacity();
        }

        fn moveToLiveRegionTop(self: *Self, writer: *std.Io.Writer) !void {
            if (self.last_line_count > 1) {
                const up: u16 = @intCast(@min(self.last_line_count - 1, std.math.maxInt(u16)));
                try ansi.cursorUp(writer, up);
            }
            try writer.writeAll("\r");
        }

        fn moveToReflowedLiveRegionTop(self: *Self, writer: *std.Io.Writer) !void {
            const width: usize = @max(@as(usize, self.context.width), 1);
            const occupied = reflowedRowCount(self.last_line_widths.items, width);
            if (occupied > 1) {
                const up: u16 = @intCast(@min(occupied - 1, std.math.maxInt(u16)));
                try ansi.cursorUp(writer, up);
            }
            try writer.writeAll("\r");
        }

        fn writeAboveLines(writer: *std.Io.Writer, above: []const u8, width: usize) !void {
            if (above.len == 0) return;
            const body = if (above[above.len - 1] == '\n') above[0 .. above.len - 1] else above;
            var lines = std.mem.splitScalar(u8, body, '\n');
            while (lines.next()) |line| {
                try writer.writeAll(line);
                if (visibleWidth(line) < width) try writer.writeAll(ansi.line_clear_right);
                try writer.writeAll("\r\n");
            }
        }

        fn finishInline(self: *Self) void {
            if (self.terminal) |*term| {
                const writer = term.writer();
                writer.writeAll(ansi.sync_start) catch return;
                self.moveToReflowedLiveRegionTop(writer) catch return;
                writer.writeAll(ansi.screen_clear_below) catch return;
                writeAboveLines(writer, self.context.above_buffer.items, @max(@as(usize, self.context.width), 1)) catch return;
                self.context.above_buffer.clearRetainingCapacity();
                self.last_line_count = 0;
                self.last_line_widths.clearRetainingCapacity();
                writer.writeAll(ansi.sync_end) catch return;
                term.flush() catch return;
            }
        }

        fn writeClampedLine(writer: *std.Io.Writer, line: []const u8, width: usize) !usize {
            var i: usize = 0;
            var used: usize = 0;
            while (i < line.len) {
                const c = line[i];
                if (c == 0x1b) {
                    const end = escapeSequenceEnd(line, i);
                    try writer.writeAll(line[i..end]);
                    i = end;
                    continue;
                }
                const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                const take = @min(len, line.len - i);
                const codepoint: u21 = std.unicode.utf8Decode(line[i .. i + take]) catch c;
                const cell_width = unicode.charWidth(codepoint);
                if (used + cell_width > width) {
                    i += take;
                    continue;
                }
                try writer.writeAll(line[i .. i + take]);
                used += cell_width;
                i += take;
            }
            return used;
        }

        fn countLines(text: []const u8) usize {
            if (text.len == 0) return 1;
            var count: usize = 1;
            for (text) |c| {
                if (c == '\n') count += 1;
            }
            return count;
        }

        /// Send a message to the model.
        ///
        /// Same-thread sends dispatch immediately, preserving the original
        /// synchronous payload lifetime contract for stack/frame-backed data.
        /// Background-thread sends enqueue for main-thread delivery.
        pub fn send(self: *Self, m: UserMsg) !void {
            if (std.Thread.getCurrentId() == self.main_thread_id) {
                const cmd = self.dispatchToModel(m);
                try self.processCommand(cmd);
                return;
            }

            try self.message_queue.push(m);
        }

        /// Stop the program
        pub fn quit(self: *Self) void {
            self.running.store(false, .release);
        }
    };
}

fn reflowedRowCount(widths: []const usize, width: usize) usize {
    var rows: usize = 0;
    for (widths) |w| rows += @max(1, (w + width - 1) / width);
    return rows;
}

test "reflowedRowCount counts rewrapped rows at a narrower width" {
    try std.testing.expectEqual(@as(usize, 5), reflowedRowCount(&.{ 0, 100, 100, 100, 100 }, 100));
    try std.testing.expectEqual(@as(usize, 9), reflowedRowCount(&.{ 0, 100, 100, 100, 100 }, 70));
    try std.testing.expectEqual(@as(usize, 5), reflowedRowCount(&.{ 0, 100, 100, 100, 100 }, 120));
    try std.testing.expectEqual(@as(usize, 9), reflowedRowCount(&.{ 100, 41, 140 }, 40));
    try std.testing.expectEqual(@as(usize, 0), reflowedRowCount(&.{}, 40));
}

fn inkWidth(line: []const u8) usize {
    return visibleWidth(std.mem.trimEnd(u8, line, " "));
}

test "inkWidth ignores trailing padding but keeps styled cells" {
    try std.testing.expectEqual(@as(usize, 0), inkWidth("          "));
    try std.testing.expectEqual(@as(usize, 5), inkWidth("hello     "));
    try std.testing.expectEqual(@as(usize, 8), inkWidth("\x1b[44mhello   \x1b[0m"));
}

fn visibleWidth(line: []const u8) usize {
    var i: usize = 0;
    var used: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == 0x1b) {
            i = escapeSequenceEnd(line, i);
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const take = @min(len, line.len - i);
        const codepoint: u21 = std.unicode.utf8Decode(line[i .. i + take]) catch c;
        used += unicode.charWidth(codepoint);
        i += take;
    }
    return used;
}

fn escapeSequenceEnd(text: []const u8, from: usize) usize {
    var i = from + 1;
    if (i >= text.len) return text.len;
    const second = text[i];
    i += 1;
    switch (second) {
        '[' => {
            while (i < text.len) : (i += 1) {
                const c = text[i];
                if (c >= 0x40 and c <= 0x7e) return i + 1;
            }
            return text.len;
        },
        ']', 'P', '_', '^', 'X' => {
            while (i < text.len) : (i += 1) {
                if (text[i] == 0x07) return i + 1;
                if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i + 2;
            }
            return text.len;
        },
        '(', ')', '*', '+' => return @min(text.len, i + 1),
        else => return i,
    }
}

const AnchorTestModel = struct {
    pub const Msg = union(enum) { nop: void };

    pub fn init(_: *AnchorTestModel, _: *Context) Cmd(AnchorTestModel.Msg) {
        return .none;
    }

    pub fn update(_: *AnchorTestModel, _: AnchorTestModel.Msg, _: *Context) Cmd(AnchorTestModel.Msg) {
        return .none;
    }

    pub fn view(_: *const AnchorTestModel, _: *const Context) []const u8 {
        return "one\ntwo";
    }
};

test "renderInlineFrame anchors a short frame to the bottom after a scroll" {
    var env_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer env_map.deinit();

    var program = Program(AnchorTestModel).init(std.testing.allocator, std.testing.io, &env_map);
    defer program.deinit();
    program.options.inline_bottom_viewport = true;
    program.context.allocator = program.arena.allocator();
    program.context.width = 40;
    program.context.height = 10;

    // scrollLiveRegionAway leaves the cursor on the bottom row and asks the
    // next frame to anchor there instead of homing to the top-left.
    program.bottom_anchor = true;

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try program.renderInlineFrame(&out.writer, "one\ntwo", "");

    // A two-row frame at height 10 must move up 1 from the bottom row, not home.
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "\r\x1b[1A"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[H") == null);
    try std.testing.expectEqual(false, program.bottom_anchor);
}

test "scrollLiveRegionAway leaves the cursor at the bottom row" {
    var env_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer env_map.deinit();

    var program = Program(AnchorTestModel).init(std.testing.allocator, std.testing.io, &env_map);
    defer program.deinit();
    program.options.inline_bottom_viewport = true;
    program.context.allocator = program.arena.allocator();
    program.context.width = 40;
    program.context.height = 10;

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try program.scrollLiveRegionAway(&out.writer, "");

    // One line feed per screen row, no cursor-home, and the next frame anchors.
    try std.testing.expectEqual(@as(usize, 10), std.mem.count(u8, out.written(), "\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[H") == null);
    try std.testing.expectEqual(true, program.bottom_anchor);
}

