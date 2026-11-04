//! Point d'entrée : lecture des arguments, puis délégation au cœur `gb`.

const std = @import("std");
const gb = @import("gb");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("usage : {s} <rom.gb>\n", .{args[0]});
        return;
    }

    _ = gb.GameBoy.init();
    std.debug.print("ROM : {s}\n", .{args[1]});
}
