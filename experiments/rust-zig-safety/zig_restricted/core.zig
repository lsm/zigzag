//! Audited core. Policy checker does NOT inspect this file; it is the trusted base.
//! Interface deliberately exposes neither allocated buffers nor writable shared state.
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
