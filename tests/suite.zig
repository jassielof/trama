const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

comptime {
    refAllDecls(@This());
}
