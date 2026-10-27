const std = @import("std");
test "intentional leak detected by std.testing.allocator" {
    const leaked = try std.testing.allocator.alloc(u8, 32);
    @memset(leaked, 42);
    // Intentionally no free(): the Zig test allocator should report it.
}
