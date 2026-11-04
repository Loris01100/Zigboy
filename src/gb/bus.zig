//! Bus mémoire : aiguille chaque adresse 16 bits vers le bon composant.
//!
//!   0x0000..0x7FFF  ROM de la cartouche
//!   0x8000..0x9FFF  VRAM
//!   0xA000..0xBFFF  RAM de la cartouche (gérée par la cartouche)
//!   0xC000..0xDFFF  WRAM
//!   0xE000..0xFDFF  echo RAM (miroir de 0xC000..0xDDFF)
//!   0xFE00..0xFE9F  OAM
//!   0xFEA0..0xFEFF  zone inutilisable
//!   0xFF00..0xFF7F  registres d'E/S
//!   0xFF80..0xFFFE  HRAM
//!   0xFFFF          IE (interrupt enable)

const std = @import("std");
const cartridge = @import("cartridge.zig");
const Cartridge = cartridge.Cartridge;

pub const Bus = struct {
    cart: Cartridge,
    vram: [0x2000]u8 = @splat(0),
    wram: [0x2000]u8 = @splat(0),
    oam: [0xA0]u8 = @splat(0),
    hram: [0x7F]u8 = @splat(0),
    ie: u8 = 0,
    /// Nombre d'accès (lectures et écritures) à des registres d'E/S
    /// pas encore implémentés.
    unimplemented_io_accesses: u64 = 0,

    pub fn init(cart: Cartridge) Bus {
        return .{ .cart = cart };
    }

    pub fn read(self: *Bus, addr: u16) u8 {
        return switch (addr) {
            0x0000...0x7FFF => self.cart.read(addr),
            0x8000...0x9FFF => self.vram[addr - 0x8000],
            0xA000...0xBFFF => self.cart.read(addr),
            0xC000...0xDFFF => self.wram[addr - 0xC000],
            0xE000...0xFDFF => self.wram[addr - 0xE000],
            0xFE00...0xFE9F => self.oam[addr - 0xFE00],
            0xFEA0...0xFEFF => 0xFF,
            0xFF00...0xFF7F => self.readIo(addr),
            0xFF80...0xFFFE => self.hram[addr - 0xFF80],
            0xFFFF => self.ie,
        };
    }

    pub fn write(self: *Bus, addr: u16, value: u8) void {
        switch (addr) {
            // Sur ROM : la cartouche décide (ignoré en ROM ONLY,
            // registres de banque pour les MBC).
            0x0000...0x7FFF => self.cart.write(addr, value),
            0x8000...0x9FFF => self.vram[addr - 0x8000] = value,
            0xA000...0xBFFF => self.cart.write(addr, value),
            0xC000...0xDFFF => self.wram[addr - 0xC000] = value,
            0xE000...0xFDFF => self.wram[addr - 0xE000] = value,
            0xFE00...0xFE9F => self.oam[addr - 0xFE00] = value,
            0xFEA0...0xFEFF => {},
            0xFF00...0xFF7F => self.writeIo(addr, value),
            0xFF80...0xFFFE => self.hram[addr - 0xFF80] = value,
            0xFFFF => self.ie = value,
        }
    }

    fn readIo(self: *Bus, addr: u16) u8 {
        // Aucun registre d'E/S n'est encore implémenté.
        _ = addr;
        self.unimplemented_io_accesses += 1;
        return 0xFF;
    }

    fn writeIo(self: *Bus, addr: u16, value: u8) void {
        _ = addr;
        _ = value;
        self.unimplemented_io_accesses += 1;
    }
};

// --- Tests -----------------------------------------------------------------

/// Bus branché sur une ROM ONLY de 32 Kio, toute à 0 sauf le checksum.
fn testBus(buf: *[32 * 1024]u8) !Bus {
    @memset(buf, 0);
    buf[0x014D] = cartridge.computeChecksum(buf);
    return Bus.init(try Cartridge.init(buf));
}

test "echo RAM : une écriture en 0xC010 se relit en 0xE010" {
    var buf: [32 * 1024]u8 = undefined;
    var bus = try testBus(&buf);

    bus.write(0xC010, 0x5A);
    try std.testing.expectEqual(@as(u8, 0x5A), bus.read(0xE010));

    // Et dans l'autre sens.
    bus.write(0xE020, 0xA5);
    try std.testing.expectEqual(@as(u8, 0xA5), bus.read(0xC020));
}

test "écriture dans la zone ROM : rien ne change" {
    var buf: [32 * 1024]u8 = undefined;
    var bus = try testBus(&buf);

    const avant = bus.read(0x0150);
    bus.write(0x0150, 0x42);
    try std.testing.expectEqual(avant, bus.read(0x0150));
    try std.testing.expectEqual(@as(u8, 0), buf[0x0150]);
}

test "E/S non implémentées : 0xFF, écriture ignorée, accès comptés" {
    var buf: [32 * 1024]u8 = undefined;
    var bus = try testBus(&buf);

    bus.write(0xFF40, 0x91);
    try std.testing.expectEqual(@as(u8, 0xFF), bus.read(0xFF40));
    try std.testing.expectEqual(@as(u64, 2), bus.unimplemented_io_accesses);
}
