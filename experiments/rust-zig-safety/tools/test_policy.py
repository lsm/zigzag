#!/usr/bin/env python3
"""Positive and mutation-negative unit tests for restricted Zig gate."""
import unittest
from pathlib import Path
from policy_check import check_text

ROOT = Path(__file__).resolve().parents[1]


class PolicyTests(unittest.TestCase):
    def test_actual_restricted_app_accepted(self):
        app = (ROOT / "zig_restricted" / "app.zig").read_text()
        self.assertEqual(check_text(app), [])

    def test_normal_comments_ignored(self):
        self.assertEqual(check_text('const std = @import("std"); // std.Thread.spawn\n'), [])

    def test_direct_allocation_rejected(self):
        self.assertTrue(any("raw_heap" in x for x in check_text('const x = try a.alloc(u8, 4);')))

    def test_free_rejected(self):
        self.assertTrue(any("raw_heap" in x for x in check_text('a.free(data);')))

    def test_pointer_reinterpretation_rejected(self):
        self.assertTrue(any("raw_pointer_ops" in x for x in check_text('const p = @ptrFromInt(1234);')))

    def test_direct_spawning_rejected(self):
        self.assertTrue(any("direct_threading" in x for x in check_text('const t = try std.Thread.spawn(.{}, f, .{});')))

    def test_direct_index_rejected(self):
        self.assertTrue(any("unchecked_index" in x for x in check_text('const x = buf[buf.len];')))

    def test_unapproved_import_rejected(self):
        self.assertTrue(any("unauthorized_import" in x for x in check_text('const raw = @import("raw_ptr.zig");')))

    def test_undefined_rejected(self):
        self.assertTrue(any("unsafe_control" in x for x in check_text('var bytes: [8]u8 = undefined;')))

    def test_other_builtins_allowed(self):
        self.assertEqual(check_text('const array = [_]u8{1,2,3};\ntry std.testing.expectEqual(3, array.len);'), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
