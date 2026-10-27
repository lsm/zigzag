//! Safe-subset application: no direct allocation, pointer reinterpretation or spawning.
const std = @import("std");
const core = @import("core.zig");

test "copy + sum: empty, ordinary, boundary" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u64, 0), try core.copyAndSum(a, &.{}));
    try std.testing.expectEqual(@as(u64, 10), try core.copyAndSum(a, &.{ 1, 2, 3, 4 }));
    const full: [64]u8 = @splat(2);
    try std.testing.expectEqual(@as(u64, 128), try core.copyAndSum(a, &full));
    const oversized: [65]u8 = @splat(1);
    try std.testing.expectError(error.TooLong, core.copyAndSum(a, &oversized));
}

test "two real threads with audited API" {
    try std.testing.expectEqual(@as(u64, 10), try core.parallelSum(&.{ 1, 2, 3, 4 }));
    try std.testing.expectEqual(@as(u64, 0), try core.parallelSum(&.{}));
}
