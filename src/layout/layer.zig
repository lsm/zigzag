//! Layer compositing system for z-ordered UI overlays.
//! Manages a stack of rendered text layers and composites them
//! into a single output with proper z-ordering and transparency.

const std = @import("std");
const Writer = std.Io.Writer;
const measure = @import("measure.zig");
const unicode = @import("../unicode.zig");

/// A single layer in the stack.
pub const Layer = struct {
    /// Rendered content string.
    content: []const u8,
    /// X position (column offset).
    x: u16 = 0,
    /// Y position (row offset).
    y: u16 = 0,
    /// Z-index for ordering. Higher = on top.
    z: i16 = 0,
    /// If true, space characters are transparent (show layer below).
    transparent: bool = true,
};

/// Composites multiple layers into a single rendered output.
pub const LayerStack = struct {
    allocator: std.mem.Allocator,
    layers: std.array_list.Managed(Layer),
    width: u16 = 80,
    height: u16 = 24,
    /// Background character for empty cells.
    background: u8 = ' ',

    pub fn init(allocator: std.mem.Allocator) LayerStack {
        return .{
            .allocator = allocator,
            .layers = std.array_list.Managed(Layer).init(allocator),
        };
    }

    pub fn deinit(self: *LayerStack) void {
        self.layers.deinit();
    }

    pub fn setSize(self: *LayerStack, w: u16, h: u16) void {
        self.width = w;
        self.height = h;
    }

    pub fn push(self: *LayerStack, layer: Layer) !void {
        try self.layers.append(layer);
    }

    pub fn clear(self: *LayerStack) void {
        self.layers.clearRetainingCapacity();
    }

    /// Composite all layers and return the final rendered string.
    ///
    /// Fallible on purpose: an allocation failure part-way through used to
    /// return an empty or truncated frame, which reaches the screen looking
    /// like a rendering bug rather than an error.
    pub fn render(self: *const LayerStack, allocator: std.mem.Allocator) ![]const u8 {
        const w: usize = self.width;
        const h: usize = self.height;

        // Create cell buffer: each cell stores a byte slice (content) and ANSI state
        // For simplicity, we use a 2D grid of cells that stores display characters
        const grid = try allocator.alloc(Cell, w * h);

        // Fill with background
        const bg = [1]u8{self.background};
        const background: Cell = .{ .content = &bg, .ansi_prefix = "" };
        for (grid) |*cell| {
            cell.* = background;
        }
        // What each cell showed before the glyph now in it was painted, so
        // erasing half of a wide glyph can reveal the layer beneath it.
        const under = try allocator.alloc(Cell, w * h);
        @memset(under, background);

        // Sort layers by z-index
        const sorted = try allocator.alloc(Layer, self.layers.items.len);
        @memcpy(sorted, self.layers.items);
        std.mem.sort(Layer, sorted, {}, struct {
            fn lessThan(_: void, a: Layer, b: Layer) bool {
                return a.z < b.z;
            }
        }.lessThan);

        // Paint each layer onto the grid
        for (sorted) |layer| {
            paintLayer(grid, under, w, h, layer, background);
        }

        // Render grid to string
        var result: Writer.Allocating = .init(allocator);
        const writer = &result.writer;

        for (0..h) |row| {
            if (row > 0) try writer.writeByte('\n');
            for (0..w) |col| {
                const cell = grid[row * w + col];
                // Empty content marks the second column of a wide character
                if (cell.content.len == 0) continue;
                if (cell.ansi_prefix.len > 0) {
                    try writer.writeAll(cell.ansi_prefix);
                    try writer.writeAll(cell.content);
                    try writer.writeAll("\x1b[0m");
                } else {
                    try writer.writeAll(cell.content);
                }
            }
        }

        return result.toArrayList().items;
    }

    fn paintLayer(grid: []Cell, under: []Cell, w: usize, h: usize, layer: Layer, background: Cell) void {
        const content = layer.content;
        var row: usize = layer.y;
        var col: usize = layer.x;
        var i: usize = 0;
        var current_ansi: []const u8 = "";
        // The cell this layer painted last on the current row, and where its
        // bytes start and end in `content`.
        var last_cell: ?usize = null;
        var last_start: usize = 0;
        var last_end: usize = 0;

        while (i < content.len and row < h) {
            if (content[i] == '\n') {
                row += 1;
                col = layer.x;
                i += 1;
                last_cell = null;
                continue;
            }

            // Detect ANSI escape sequence
            if (content[i] == 0x1b and i + 1 < content.len and content[i + 1] == '[') {
                const seq_start = i;
                i += 2;
                while (i < content.len and content[i] != 'm' and content[i] != 'H' and content[i] != 'J' and content[i] != 'K') : (i += 1) {}
                if (i < content.len) {
                    i += 1;
                    // Check if it's a reset sequence
                    if (content[seq_start + 2 .. i - 1].len == 1 and content[seq_start + 2] == '0') {
                        current_ansi = "";
                    } else {
                        current_ansi = content[seq_start..i];
                    }
                }
                continue;
            }

            // Decode one UTF-8 character; treat invalid bytes as single cells
            const start = i;
            const char_len = std.unicode.utf8ByteSequenceLength(content[i]) catch 1;
            const end = @min(i + char_len, content.len);
            const char = content[i..end];
            const codepoint: u21 = std.unicode.utf8Decode(char) catch content[i];
            const char_width = measure.charWidth(codepoint);
            i = end;

            // A zero-width mark (a combining accent, say) belongs to the
            // character before it, so it rides along in that cell instead of
            // taking one. Controls are dropped, and so are the joiner and the
            // emoji presentation selectors: those make a terminal draw a
            // cluster narrower or wider than the per-code-point width every
            // layout here measures, which would shift the rest of the row.
            if (char_width == 0) {
                if (attachesToPrevious(codepoint)) {
                    if (last_cell) |idx| {
                        if (last_end == start) {
                            grid[idx].content = content[last_start..end];
                            last_end = end;
                        }
                    }
                }
                continue;
            }

            const is_transparent = layer.transparent and codepoint == ' ' and current_ansi.len == 0;
            if (!is_transparent and col + char_width <= w) {
                const first = row * w + col;
                // Landing on the second half of a wide character below leaves
                // its first half unable to draw; show what it covered instead.
                if (col > 0 and grid[first].content.len == 0) grid[first - 1] = revealed(under[first - 1], background);
                under[first] = grid[first];
                grid[first] = .{
                    .content = char,
                    .ansi_prefix = current_ansi,
                };
                last_cell = first;
                last_start = start;
                last_end = end;
                // A wide character covers the following cell as well
                if (char_width == 2) {
                    under[first + 1] = grid[first + 1];
                    grid[first + 1] = .{ .content = "" };
                }
                // Covering the first half of a wide character below orphans
                // its second half, which would otherwise draw nothing; show
                // what it covered instead.
                if (col + char_width < w and grid[first + char_width].content.len == 0) {
                    grid[first + char_width] = revealed(under[first + char_width], background);
                }
            } else {
                last_cell = null;
            }
            col += char_width;
        }
    }
};

/// Whether a zero-width code point can share the cell of the character before
/// it without changing how wide the terminal draws that cell.
fn attachesToPrevious(codepoint: u21) bool {
    if (unicode.codepointWidth(codepoint) != 0) return false;
    return switch (codepoint) {
        0x200D, 0xFE0E, 0xFE0F => false,
        else => true,
    };
}

/// The cell to show where half of a wide glyph was erased: what that half
/// covered, unless that is itself part of a wide glyph, which cannot draw in
/// one column.
fn revealed(cell: Cell, background: Cell) Cell {
    if (cell.content.len == 0) return background;
    const len = std.unicode.utf8ByteSequenceLength(cell.content[0]) catch 1;
    const codepoint: u21 = std.unicode.utf8Decode(cell.content[0..@min(len, cell.content.len)]) catch cell.content[0];
    return if (measure.charWidth(codepoint) == 1) cell else background;
}

const Cell = struct {
    /// UTF-8 bytes of the character in this cell.
    /// Empty for the second column of a wide character.
    content: []const u8 = " ",
    ansi_prefix: []const u8 = "",
};
