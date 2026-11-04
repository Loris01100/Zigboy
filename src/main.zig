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

    // L'en-tête se lit quel que soit le contrôleur : on l'affiche même
    // pour une cartouche que l'émulateur ne gère pas encore.
    const header = gb.cartridge.Header.parse(rom) catch |err| {
        std.debug.print("{s} : en-tête invalide ({s})\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    std.debug.print("Titre : {s}\n", .{header.title});
    std.debug.print("Type  : {s} (0x{X:0>2})\n", .{ header.typeName(), header.cartridge_type });

    const cart = gb.Cartridge.init(rom) catch |err| {
        std.debug.print("cartouche non prise en charge ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    _ = gb.Bus.init(cart);
}

/// Plus grosse cartouche Game Boy Color (MBC5) : 8 Mio.
const max_rom_size = 8 * 1024 * 1024;
