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

        const bg = [1]u8{self.background};
        const background: Cell = .{ .content = &bg, .ansi_prefix = "" };

        // Sort layers by z-index
        const sorted = try allocator.alloc(Layer, self.layers.items.len);
        @memcpy(sorted, self.layers.items);
        std.mem.sort(Layer, sorted, {}, struct {
            fn lessThan(_: void, a: Layer, b: Layer) bool {
                return a.z < b.z;
            }
        }.lessThan);

        // Each layer paints onto its own plane; a null cell is one the layer
        // leaves showing through.
        const cells = w * h;
        const planes = try allocator.alloc(?Cell, sorted.len * cells);
        @memset(planes, null);
        for (sorted, 0..) |layer, index| {
            try paintLayer(allocator, planes[index * cells ..][0..cells], w, h, layer);
        }

        // Composite from the top down. A glyph shows only when no visible
        // glyph above it covers any of its columns; one that is partly
        // covered shows nowhere, so the layers beneath show through all of
        // its columns, however deep the stack.
        const grid = try allocator.alloc(Cell, cells);
        @memset(grid, background);
        const covered = try allocator.alloc(bool, cells);
        @memset(covered, false);
        var index = sorted.len;
        while (index > 0) {
            index -= 1;
            const plane = planes[index * cells ..][0..cells];
            for (0..h) |row| {
                for (0..w) |col| {
                    const at = row * w + col;
                    const cell = plane[at] orelse continue;
                    // The second column of a wide glyph goes with its first.
                    if (cell.content.len == 0) continue;
                    const wide = col + 1 < w and plane[at + 1] != null and plane[at + 1].?.content.len == 0;
                    if (covered[at] or (wide and covered[at + 1])) continue;
                    grid[at] = cell;
                    covered[at] = true;
                    if (wide) {
                        grid[at + 1] = .{ .content = "" };
                        covered[at + 1] = true;
                    }
                }
            }
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
                // A mark styled apart from its base carries its own escape.
                if (cell.ansi_prefix.len > 0 or std.mem.indexOfScalar(u8, cell.content, 0x1b) != null) {
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

    fn paintLayer(allocator: std.mem.Allocator, plane: []?Cell, w: usize, h: usize, layer: Layer) !void {
        const content = layer.content;
        var row: usize = layer.y;
        var col: usize = layer.x;
        var i: usize = 0;
        var current_ansi: []const u8 = "";
        // The cell this layer painted last on the current row, where its
        // bytes start and end in `content`, and whether its text is still that
        // one slice of `content`.
        var last_cell: ?usize = null;
        var last_start: usize = 0;
        var last_end: usize = 0;
        var last_sliced = true;
        // The style in effect at the end of that cell's text.
        var last_style: []const u8 = "";

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
            // A style escape between the two takes no column, so the mark
            // still joins the cell, copied onto its text when the bytes are
            // not adjacent, and switching to the mark's own style if that
            // differs from the style the cell's text ends in.
            if (char_width == 0) {
                if (attachesToPrevious(codepoint)) {
                    if (last_cell) |at| {
                        const restyle = !std.mem.eql(u8, current_ansi, last_style);
                        if (last_sliced and last_end == start and !restyle) {
                            plane[at].?.content = content[last_start..end];
                        } else if (restyle) {
                            plane[at].?.content = try std.mem.concat(allocator, u8, &.{ plane[at].?.content, "\x1b[0m", current_ansi, char });
                            last_style = current_ansi;
                            last_sliced = false;
                        } else {
                            plane[at].?.content = try std.mem.concat(allocator, u8, &.{ plane[at].?.content, char });
                            last_sliced = false;
                        }
                        last_end = end;
                    }
                }
                continue;
            }

            const is_transparent = layer.transparent and codepoint == ' ' and current_ansi.len == 0;
            if (!is_transparent and col + char_width <= w) {
                const at = row * w + col;
                plane[at] = .{
                    .content = char,
                    .ansi_prefix = current_ansi,
                };
                last_cell = at;
                last_start = start;
                last_end = end;
                last_sliced = true;
                last_style = current_ansi;
                // A wide character covers the following cell as well
                if (char_width == 2) {
                    plane[at + 1] = .{ .content = "" };
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
        // Zero-width joiner, text and emoji presentation selectors, and the
        // enclosing keycap, which turns `1` into a two-column keycap.
        0x200D, 0xFE0E, 0xFE0F, 0x20E3 => false,
        else => true,
    };
}

const Cell = struct {
    /// UTF-8 bytes of the character in this cell.
    /// Empty for the second column of a wide character.
    content: []const u8 = " ",
    ansi_prefix: []const u8 = "",
};
