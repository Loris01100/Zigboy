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

    const path = args[1];
    const rom = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(max_rom_size + 1)) catch |err| {
        std.debug.print("impossible de lire {s} : {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };

    _ = gb.GameBoy.init();
    std.debug.print("ROM : {s} ({d} octets)\n", .{ path, rom.len });
}

/// Plus grosse cartouche Game Boy Color (MBC5) : 8 Mio.
const max_rom_size = 8 * 1024 * 1024;
