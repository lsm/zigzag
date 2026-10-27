//! Baseline Zig: direct allocation, copying, and explicit thread management.
const std = @import("std");
const Allocator = std.mem.Allocator;
const MAX_LEN: usize = 64;

fn sum(data: []const u8) u64 {
    var total: u64 = 0;
    for (data) |byte| total += byte;
    return total;
}

pub fn copyAndSum(allocator: Allocator, input: []const u8) !u64 {
    if (input.len > MAX_LEN) return error.TooLong;
    const owned = try allocator.alloc(u8, input.len);
    defer allocator.free(owned);
    @memcpy(owned, input);
    return sum(owned);
}

fn worker(bytes: []const u8, out: *u64) void {
    out.* = sum(bytes);
}

pub fn parallelSum(data: []const u8) !u64 {
    const mid = data.len / 2;
    var left: u64 = 0;
    var right: u64 = 0;
    const t1 = try std.Thread.spawn(.{}, worker, .{ data[0..mid], &left });
    errdefer t1.join();
    const t2 = try std.Thread.spawn(.{}, worker, .{ data[mid..], &right });
    t1.join();
    t2.join();
    return left + right;
}

test "copy + sum: empty, ordinary, boundary" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u64, 0), try copyAndSum(a, &.{}));
    try std.testing.expectEqual(@as(u64, 10), try copyAndSum(a, &.{ 1, 2, 3, 4 }));
    const full: [MAX_LEN]u8 = @splat(2);
    try std.testing.expectEqual(@as(u64, 128), try copyAndSum(a, &full));
    const oversized: [MAX_LEN + 1]u8 = @splat(1);
    try std.testing.expectError(error.TooLong, copyAndSum(a, &oversized));
}

test "two real threads write to distinct results" {
    try std.testing.expectEqual(@as(u64, 10), try parallelSum(&.{ 1, 2, 3, 4 }));
    try std.testing.expectEqual(@as(u64, 0), try parallelSum(&.{}));
}
