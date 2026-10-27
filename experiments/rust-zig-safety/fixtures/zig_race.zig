const std = @import("std");
fn increment(shared: *usize) void {
    for (0..100_000) |_| {
        shared.* += 1; // Intentional unsynchronized shared write: data race UB.
    }
}
test "intentional data race; pass result proves nothing" {
    var counter: usize = 0;
    const t1 = try std.Thread.spawn(.{}, increment, .{&counter});
    const t2 = try std.Thread.spawn(.{}, increment, .{&counter});
    t1.join();
    t2.join();
    try std.testing.expectEqual(@as(usize, 200_000), counter);
}
