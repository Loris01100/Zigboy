//! Racine du module `gb` : le cœur de l'émulateur.
//!
//! Ce module ne dépend que de `std` : aucune bibliothèque graphique,
//! aucune fenêtre. Il se teste donc entièrement en headless et pourra
//! plus tard être compilé pour WebAssembly.
//!
//! Les composants (cpu.zig, bus.zig, cartridge.zig, ...) seront ajoutés
//! dans ce dossier au fil des phases et ré-exportés ici.

const std = @import("std");

pub const cartridge = @import("cartridge.zig");
pub const Cartridge = cartridge.Cartridge;

/// Assemble les composants de la machine. Vide pour l'instant.
pub const GameBoy = struct {
    pub fn init() GameBoy {
        return .{};
    }
};

test "init" {
    _ = GameBoy.init();
}

test {
    // Inclut les blocs `test` des fichiers ré-exportés par ce module.
    std.testing.refAllDecls(@This());
}
