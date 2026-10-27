const std = @import("std");
test "intentional use after free; undefined behavior" {
    const a = std.testing.allocator;
    const data = try a.alloc(u8, 1);
    data[0] = 17;
    a.free(data);
    var index: usize = 0;
    _ = &index;
    try std.testing.expectEqual(@as(u8, 17), data[index]);
}
