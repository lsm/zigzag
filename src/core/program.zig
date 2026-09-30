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
const model_contract = @import("model.zig");

pub const Cmd = command.Cmd;
pub const Msg = message;

const PendingImage = union(enum) {
    auto: command.ImageFile,
    kitty: command.KittyImageFile,
    data: command.ImageData,
    place_cached: command.PlaceCachedImage,
};

/// Bytes pulled from the terminal per read.
const read_chunk_size = 1024;

/// Upper bound on reads per tick, so a firehose on stdin cannot starve
/// rendering.
const max_reads_per_tick = 8;

/// Program runtime that manages the application lifecycle
pub fn Program(comptime Model: type) type {
    model_contract.validate(Model, "Model");

    // `init`, `update` and `view` may each return an error union; the runtime
    // propagates it instead of the model having to swallow it.
    const init_fallible = model_contract.returnsError(@TypeOf(Model.init));
    const update_fallible = model_contract.returnsError(@TypeOf(Model.update));
    const view_fallible = model_contract.returnsError(@TypeOf(Model.view));

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
        /// `context.elapsed` captured when the active one-shot `pending_tick` was
        /// scheduled, so the delivered `Tick.delta` reflects the time since the
        /// tick was requested rather than the per-frame render delta.
        pending_tick_scheduled_at: u64,
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
        /// Retains escape sequences that a read cut in half.
        input_parser: keyboard.InputParser,

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
                .pending_tick_scheduled_at = 0,
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
                .input_parser = .{},
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

            self.input_parser.escape_timeout_ns =
                @as(u64, self.options.escape_timeout_ms) * std.time.ns_per_ms;

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
            const init_cmd = if (comptime init_fallible)
                try self.model.init(&self.context)
            else
                self.model.init(&self.context);
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
                        const cmd = try self.dispatchToModel(.{ .window_size = .{
                            .width = self.context.width,
                            .height = self.context.height,
                        } });
                        try self.processCommand(cmd);
                        if (!self.isRunning()) return;
                    }
                }
            }

            // Non-blocking drain; input typed during pacing sits in the TTY buffer.
            try self.drainInput();

            // Handle pending tick
            if (self.pending_tick) |tick_ns| {
                if (self.context.elapsed >= tick_ns) {
                    self.pending_tick = null;
                    // Deliver tick to user's update if Model.Msg has a tick variant
                    if (@hasField(UserMsg, "tick")) {
                        // Time since the tick was scheduled, not the frame delta.
                        const tick_delta = self.context.elapsed -| self.pending_tick_scheduled_at;
                        const user_msg = UserMsg{ .tick = .{
                            .timestamp = @intCast(tick_start),
                            .delta = tick_delta,
                        } };
                        const cmd = try self.dispatchToModel(user_msg);
                        try self.processCommand(cmd);
                        if (!self.isRunning()) return;
                    }
                }
            }

            // Handle repeating tick
            if (self.every_interval) |interval| {
                if (self.context.elapsed - self.last_every_tick >= interval) {
                    // Time since the previous repeating tick, not the frame delta.
                    const tick_delta = self.context.elapsed -| self.last_every_tick;
                    self.last_every_tick = self.context.elapsed;
                    if (@hasField(UserMsg, "tick")) {
                        const user_msg = UserMsg{ .tick = .{
                            .timestamp = @intCast(tick_start),
                            .delta = tick_delta,
                        } };
                        const cmd = try self.dispatchToModel(user_msg);
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
                    // A wait that fails (a cancelled or interrupted sleep)
                    // just means this frame is not paced; `unreachable` here
                    // would be undefined behaviour in a release build.
                    deadline.wait(self.io) catch {};
                }
            }
        }

        pub fn drainMessageQueue(self: *Self) !void {
            var batch = std.array_list.Managed(UserMsg).init(self.allocator);
            defer batch.deinit();

            try self.message_queue.popBatch(&batch);
            for (batch.items, 0..) |m, i| {
                const cmd = try self.dispatchToModel(m);
                self.processCommand(cmd) catch |err| {
                    try self.message_queue.requeueFront(batch.items[i + 1 ..]);
                    return err;
                };
            }
        }

        /// Read whatever the terminal has ready and dispatch the events it
        /// decodes into.
        ///
        /// Reads are non-blocking, so a burst that outgrows one buffer (paste,
        /// or a trackpad producing mouse reports faster than a frame) is
        /// picked up within the same tick instead of trickling in over the
        /// following ones. `InputParser` stitches sequences back together when
        /// a read lands in the middle of one.
        fn drainInput(self: *Self) !void {
            var input_buf: [read_chunk_size]u8 = undefined;

            var reads: usize = 0;
            while (reads < max_reads_per_tick) : (reads += 1) {
                const bytes_read = try self.terminal.?.readInput(&input_buf, 0);

                const events = try self.input_parser.feed(
                    self.context.allocator,
                    input_buf[0..bytes_read],
                    self.context.elapsed,
                );
                try self.dispatchInputEvents(events);
                if (!self.isRunning()) return;

                // A short read means the terminal has nothing left for now.
                if (bytes_read < input_buf.len) break;
            }
        }

        /// Hand parsed input to the model in order, stopping at the event that
        /// quits: nothing typed after it may reach the model or suspend us.
        fn dispatchInputEvents(self: *Self, events: []const keyboard.ParseResult) !void {
            for (events) |event| {
                const user_cmd = switch (event) {
                    .key => |k| try self.processKeyEvent(k),
                    .mouse => |m| try self.processMouseEvent(m),
                    .none => null,
                };
                if (user_cmd) |cmd| {
                    try self.processCommand(cmd);
                    if (!self.isRunning()) return;
                }
            }
        }

        /// Dispatch a message to the model, applying the filter if set
        fn dispatchToModel(self: *Self, user_msg: UserMsg) !UserCmd {
            const delivered = if (self.filter) |f|
                f(user_msg) orelse return .none
            else
                user_msg;

            return if (comptime update_fallible)
                try self.model.update(delivered, &self.context)
            else
                self.model.update(delivered, &self.context);
        }

        fn processKeyEvent(self: *Self, key: keyboard.KeyEvent) !?UserCmd {
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
                    return try self.dispatchToModel(user_msg);
                }
                // If model doesn't handle paste, send as individual key events
                if (@hasField(UserMsg, "key")) {
                    const user_msg = UserMsg{ .key = key };
                    return try self.dispatchToModel(user_msg);
                }
                return null;
            }

            // Convert to user message if Model.Msg has a key variant
            if (@hasField(UserMsg, "key")) {
                const user_msg = UserMsg{ .key = key };
                return try self.dispatchToModel(user_msg);
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

        fn processMouseEvent(self: *Self, mouse_event: keyboard.MouseEvent) !?UserCmd {
            if (@hasField(UserMsg, "mouse")) {
                const user_msg = UserMsg{ .mouse = mouse_event };
                return try self.dispatchToModel(user_msg);
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

            // Raise SIGTSTP to suspend process. If the signal cannot be
            // raised we simply never stop; carrying on is better than dying.
            if (builtin.os.tag != .windows) {
                const posix = std.posix;
                _ = posix.raise(posix.SIG.TSTP) catch {};
            }

            // When we resume (after `fg`), re-setup terminal. A failure here
            // leaves the terminal in the shell's mode, which renders badly but
            // still runs -- and there is no caller to report it to.
            if (self.terminal) |*term| {
                term.setup() catch {};
            }

            // Whatever was mid-sequence when we stopped will never be
            // completed; drop it instead of merging it with post-resume input.
            self.input_parser.reset();

            // The shell wrote its prompt and `fg` output while we were stopped,
            // so the cursor no longer marks the live region. Scroll to a known
            // row and re-anchor the next frame there; forget the old frame so
            // the reuse path cannot skip rows the shell overwrote.
            if (self.options.inline_bottom_viewport) {
                if (self.terminal) |*term| {
                    const writer = term.writer();
                    const height: usize = @max(@as(usize, self.context.height), 1);
                    var n: usize = 0;
                    while (n < height) : (n += 1) writer.writeAll("\r\n") catch break;
                    term.flush() catch {};
                }
                self.reanchorInline();
            }

            // Avoid a large post-resume delta, and rebase the pacing anchor so we
            // don't burst-render to "catch up" the suspended interval. Advance the
            // user-visible clock to "now" so the timer checks below run against a
            // consistent post-resume `elapsed`.
            const resume_elapsed = self.elapsedNs();
            self.last_frame_time = resume_elapsed;
            self.context.elapsed = resume_elapsed;
            self.pacing_epoch = std.Io.Clock.Timestamp.now(self.io, .boot);
            self.pacing_frame_offset = self.context.frame;

            // Re-anchor the timers to "now" so the first post-resume Tick.delta is a
            // normal interval rather than the whole suspended span (mirrors the
            // last_frame_time and pacing resets above: we resume the cadence from
            // here instead of bursting to catch up the suspended time). The
            // repeating timer fires one interval after resume; an already-overdue
            // one-shot fires next with a ~zero delta. Anchoring to `resume_elapsed`
            // (== context.elapsed) also keeps the later `elapsed - last_every_tick`
            // subtraction from underflowing.
            self.last_every_tick = resume_elapsed;
            self.pending_tick_scheduled_at = resume_elapsed;

            // The terminal was handed back to the shell in between, so nothing
            // about the previous frame can be relied on.
            self.invalidate();

            // Dispatch resumed message if model supports it
            if (@hasField(UserMsg, "resumed")) {
                if (self.dispatchToModel(.{ .resumed = {} })) |cmd| {
                    self.processCommand(cmd) catch {};
                } else |_| {}
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
                    self.pending_tick_scheduled_at = self.context.elapsed;
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
                    const new_cmd = try self.dispatchToModel(m);
                    try self.processCommand(new_cmd);
                },
                .perform => |func| {
                    if (func()) |m| {
                        const new_cmd = try self.dispatchToModel(m);
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
                    // Switching buffers swaps out everything on screen.
                    self.invalidate();
                },
                .exit_alt_screen => {
                    if (self.terminal) |*term| {
                        const writer = term.writer();
                        try writer.writeAll(ansi.alt_screen_exit);
                        try term.flush();
                    }
                    self.invalidate();
                },
                .repaint => {
                    self.invalidate();
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
                    // This wrote over the frame area.
                    self.invalidate();
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
                        // An unsupported protocol returns false rather than an
                        // error, so anything that does surface here is a real
                        // I/O failure, the same as in `flushPendingImage`.
                        switch (cache.source) {
                            .file => |path| {
                                _ = try term.transmitKittyImageFromFile(path, .{
                                    .image_id = cache.image_id,
                                    .format = @enumFromInt(@intFromEnum(cache.format)),
                                    .quiet = cache.quiet,
                                    .pixel_width = cache.pixel_width,
                                    .pixel_height = cache.pixel_height,
                                });
                            },
                            .data => |data| {
                                _ = try term.transmitKittyImage(data, .{
                                    .image_id = cache.image_id,
                                    .format = @enumFromInt(@intFromEnum(cache.format)),
                                    .quiet = cache.quiet,
                                    .pixel_width = cache.pixel_width,
                                    .pixel_height = cache.pixel_height,
                                });
                            },
                        }
                        try term.flush();
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
                        _ = try term.deleteKittyImage(target);
                        try term.flush();
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
                // An image covers cells the renderer thinks it owns; the next
                // frame repaints over it the way a full redraw always did.
                self.invalidate();
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

        fn resetFrameAllocator(self: *Self) void {
            _ = self.arena.reset(.retain_capacity);
            self.context.allocator = self.arena.allocator();
        }

        const resize_debounce_ns: u64 = 150 * std.time.ns_per_ms;

        fn render(self: *Self) !void {
            if (self.resize_deadline != null) return;
            const view_output = if (comptime view_fallible)
                try self.model.view(&self.context)
            else
                self.model.view(&self.context);

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

            const reuse = self.options.render_mode == .diff and above.len == 0 and self.last_line_count > 0;
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

        /// Repaint the whole frame on the next render. A pending resize still
        /// owes the model its window_size message and the relayout, so it
        /// survives. The inline renderer also keeps the rows it drew so it can
        /// find their top; the full-screen path forgets the previous frame's rows.
        pub fn invalidate(self: *Self) void {
            self.needs_repaint = true;
            self.last_frame.clearRetainingCapacity();
            if (self.options.inline_bottom_viewport) return;
            self.last_line_count = 0;
            self.last_line_widths.clearRetainingCapacity();
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

        /// Re-establish the bottom anchor and drop the stale frame, for the
        /// paths where another writer moved the cursor (resume after suspend).
        fn reanchorInline(self: *Self) void {
            self.bottom_anchor = true;
            self.last_line_count = 0;
            self.last_frame.clearRetainingCapacity();
            self.last_line_widths.clearRetainingCapacity();
            self.needs_repaint = true;
        }

        fn writeClampedLine(writer: *std.Io.Writer, line: []const u8, width: usize) !usize {
            var i: usize = 0;
            var used: usize = 0;
            var clipped = false;
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
                if (clipped or used + cell_width > width) {
                    // Past the truncation point: drop printable characters so a
                    // wide glyph straddling the edge cannot pull later text in,
                    // but keep emitting escape sequences (trailing resets).
                    clipped = true;
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
                const cmd = try self.dispatchToModel(m);
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

const QuitTestModel = struct {
    pub const Msg = union(enum) { key: keyboard.KeyEvent };

    keys: usize = 0,

    pub fn init(_: *QuitTestModel, _: *Context) Cmd(QuitTestModel.Msg) {
        return .none;
    }

    pub fn update(self: *QuitTestModel, msg: QuitTestModel.Msg, _: *Context) Cmd(QuitTestModel.Msg) {
        switch (msg) {
            .key => |k| {
                self.keys += 1;
                if (k.key == .char and k.key.char == 'q') return .quit;
            },
        }
        return .none;
    }

    pub fn view(_: *const QuitTestModel, _: *const Context) []const u8 {
        return "";
    }
};

test "dispatchInputEvents stops at the quit and hands nothing after it to the model" {
    var env_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer env_map.deinit();

    var program = Program(QuitTestModel).init(std.testing.allocator, std.testing.io, &env_map);
    defer program.deinit();
    program.running.store(true, .release);

    const events = [_]keyboard.ParseResult{
        .{ .key = .{ .key = .{ .char = 'q' } } },
        .{ .key = .{ .key = .{ .char = 'x' } } },
    };
    try program.dispatchInputEvents(&events);

    try std.testing.expect(!program.isRunning());
    try std.testing.expectEqual(@as(usize, 1), program.model.keys);
}

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

test "invalidate in inline mode repaints every row in place and keeps a pending relayout" {
    var env_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer env_map.deinit();

    var program = Program(AnchorTestModel).init(std.testing.allocator, std.testing.io, &env_map);
    defer program.deinit();
    program.options.inline_bottom_viewport = true;
    program.context.allocator = program.arena.allocator();
    program.context.width = 40;
    program.context.height = 10;

    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    try program.renderInlineFrame(&first.writer, "one\ntwo", "");

    program.resize_deadline = 42;
    program.invalidate();
    try std.testing.expectEqual(@as(?u64, 42), program.resize_deadline);
    try std.testing.expect(program.needs_repaint);

    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try program.renderInlineFrame(&second.writer, "one\ntwo", "");

    // The next frame starts back at the top of the two rows it replaces, and
    // rewrites both even though neither changed.
    try std.testing.expect(std.mem.startsWith(u8, second.written(), "\x1b[1A\r"));
    try std.testing.expect(std.mem.indexOf(u8, second.written(), "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.written(), "two") != null);
}

test "invalidate outside inline mode forgets the previous frame's rows but keeps a pending resize" {
    var env_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer env_map.deinit();

    var program = Program(AnchorTestModel).init(std.testing.allocator, std.testing.io, &env_map);
    defer program.deinit();
    program.options.inline_bottom_viewport = false;
    program.last_line_count = 3;
    try program.last_line_widths.append(program.allocator, 5);
    program.resize_deadline = 42;

    program.invalidate();

    try std.testing.expectEqual(@as(usize, 0), program.last_line_count);
    try std.testing.expectEqual(@as(usize, 0), program.last_line_widths.items.len);
    try std.testing.expectEqual(@as(?u64, 42), program.resize_deadline);
    try std.testing.expect(program.needs_repaint);
}

test "render_mode full rewrites the unchanged rows that diff skips" {
    var env_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer env_map.deinit();

    for ([_]bool{ false, true }) |full| {
        var program = Program(AnchorTestModel).init(std.testing.allocator, std.testing.io, &env_map);
        defer program.deinit();
        program.options.inline_bottom_viewport = true;
        program.options.render_mode = if (full) .full else .diff;
        program.context.allocator = program.arena.allocator();
        program.context.width = 40;
        program.context.height = 10;

        var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer first.deinit();
        try program.renderInlineFrame(&first.writer, "one\ntwo", "");

        var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer second.deinit();
        try program.renderInlineFrame(&second.writer, "one\ntwo", "");

        const rewrote_first_row = std.mem.indexOf(u8, second.written(), "one") != null;
        try std.testing.expectEqual(full, rewrote_first_row);
    }
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

test "writeClampedLine stops at a wide character that crosses the edge" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const used = try Program(AnchorTestModel).writeClampedLine(&out.writer, "123456789漢ab", 10);

    // The wide glyph does not fit the last cell, so truncation stops before it
    // and the trailing 'a' from beyond the boundary is not pulled in.
    try std.testing.expectEqualStrings("123456789", out.written());
    try std.testing.expectEqual(@as(usize, 9), used);
}

test "writeClampedLine still flushes escape sequences past the edge" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    _ = try Program(AnchorTestModel).writeClampedLine(&out.writer, "123456789漢\x1b[0m", 10);

    // The reset after the truncation point is still written.
    try std.testing.expectEqualStrings("123456789\x1b[0m", out.written());
}

test "reanchorInline drops the stale frame and re-anchors at the bottom" {
    var env_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer env_map.deinit();

    var program = Program(AnchorTestModel).init(std.testing.allocator, std.testing.io, &env_map);
    defer program.deinit();
    program.context.allocator = program.arena.allocator();
    program.last_line_count = 7;
    try program.last_frame.appendSlice(program.allocator, "stale");
    try program.last_line_widths.append(program.allocator, 5);

    program.reanchorInline();

    try std.testing.expectEqual(true, program.bottom_anchor);
    try std.testing.expectEqual(@as(usize, 0), program.last_line_count);
    try std.testing.expectEqual(@as(usize, 0), program.last_frame.items.len);
    try std.testing.expectEqual(@as(usize, 0), program.last_line_widths.items.len);
    try std.testing.expectEqual(true, program.needs_repaint);
}
