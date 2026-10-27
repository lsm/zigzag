const std = @import("std");
test "intentional runtime out of bounds" {
    const data = [_]u8{ 1, 2, 3 };
    var pos: usize = 8;
    _ = &pos; // prevent compile-time-known indexing
    try std.testing.expectEqual(@as(u8, 1), data[pos]);
}
