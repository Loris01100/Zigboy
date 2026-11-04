//! Cartouche : lecture de l'en-tête et accès à la ROM.
//!
//! L'en-tête occupe 0x0100..0x014F. On ne garde que les champs utiles :
//!   0x0134..0x0143  titre (ASCII, complété par des 0)
//!   0x0147          type de cartouche (contrôleur mémoire)
//!   0x0148          taille de la ROM (32 Kio << n)
//!   0x0149          taille de la RAM externe
//!   0x014D          checksum de l'en-tête (0x0134..0x014C)

const std = @import("std");

pub const Error = error{
    /// Le fichier est trop court pour contenir un en-tête.
    RomTooSmall,
    /// Le checksum en 0x014D ne correspond pas à celui calculé.
    /// La console refuse de démarrer dans ce cas.
    InvalidChecksum,
    /// Type de cartouche (0x0147) non géré pour l'instant.
    UnsupportedCartridge,
};

const title_start = 0x0134;
const title_end = 0x0144; // exclu
const type_addr = 0x0147;
const rom_size_addr = 0x0148;
const ram_size_addr = 0x0149;
const checksum_addr = 0x014D;
const header_end = 0x0150;

pub const Header = struct {
    /// Titre sans les 0 de remplissage. Pointe dans la ROM.
    title: []const u8,
    cartridge_type: u8,
    rom_size: usize,
    ram_size: usize,
    checksum: u8,

    pub fn parse(rom: []const u8) Error!Header {
        if (rom.len < header_end) return error.RomTooSmall;

        const header: Header = .{
            .title = std.mem.sliceTo(rom[title_start..title_end], 0),
            .cartridge_type = rom[type_addr],
            .rom_size = @as(usize, 32 * 1024) << @intCast(@min(rom[rom_size_addr], 8)),
            .ram_size = ramSize(rom[ram_size_addr]),
            .checksum = rom[checksum_addr],
        };
        if (computeChecksum(rom) != header.checksum) return error.InvalidChecksum;
        return header;
    }

    /// Nom lisible du type de cartouche (0x0147).
    pub fn typeName(self: Header) []const u8 {
        return switch (self.cartridge_type) {
            0x00 => "ROM ONLY",
            0x01 => "MBC1",
            0x02 => "MBC1+RAM",
            0x03 => "MBC1+RAM+BATTERY",
            0x05 => "MBC2",
            0x06 => "MBC2+BATTERY",
            0x0F => "MBC3+TIMER+BATTERY",
            0x10 => "MBC3+TIMER+RAM+BATTERY",
            0x11 => "MBC3",
            0x12 => "MBC3+RAM",
            0x13 => "MBC3+RAM+BATTERY",
            0x19...0x1E => "MBC5",
            else => "inconnu",
        };
    }
};

/// Algorithme du boot ROM : x = x - rom[i] - 1 sur 0x0134..0x014C.
/// Suppose `rom.len >= 0x014D`.
pub fn computeChecksum(rom: []const u8) u8 {
    var x: u8 = 0;
    for (rom[title_start..checksum_addr]) |byte| x = x -% byte -% 1;
    return x;
}

fn ramSize(code: u8) usize {
    return switch (code) {
        0x02 => 8 * 1024,
        0x03 => 32 * 1024,
        0x04 => 128 * 1024,
        0x05 => 64 * 1024,
        else => 0, // 0x00 : aucune ; 0x01 : non utilisé
    };
}

/// Cartouche sans contrôleur : 32 Kio de ROM mappés en 0x0000..0x7FFF.
pub const RomOnly = struct {
    rom: []const u8,

    pub fn read(self: RomOnly, addr: u16) u8 {
        // 0xA000..0xBFFF (RAM externe) : absente, lue comme 0xFF.
        return if (addr < 0x8000 and addr < self.rom.len) self.rom[addr] else 0xFF;
    }

    pub fn write(self: *RomOnly, addr: u16, value: u8) void {
        // La ROM est en lecture seule : les écritures sont ignorées.
        _ = self;
        _ = addr;
        _ = value;
    }
};

pub const Cartridge = union(enum) {
    rom_only: RomOnly,
    /// Pas encore implémenté : `init` renvoie `error.UnsupportedCartridge`.
    mbc1: void,
    /// Pas encore implémenté : `init` renvoie `error.UnsupportedCartridge`.
    mbc3: void,

    /// `rom` doit vivre au moins aussi longtemps que la cartouche.
    pub fn init(rom: []const u8) Error!Cartridge {
        const h = try Header.parse(rom);
        return switch (h.cartridge_type) {
            0x00 => .{ .rom_only = .{ .rom = rom } },
            else => error.UnsupportedCartridge,
        };
    }

    pub fn header(self: Cartridge) Header {
        // `init` a déjà validé l'en-tête.
        return Header.parse(self.romBytes()) catch unreachable;
    }

    pub fn read(self: Cartridge, addr: u16) u8 {
        return switch (self) {
            .rom_only => |c| c.read(addr),
            .mbc1, .mbc3 => unreachable,
        };
    }

    pub fn write(self: *Cartridge, addr: u16, value: u8) void {
        switch (self.*) {
            .rom_only => |*c| c.write(addr, value),
            .mbc1, .mbc3 => unreachable,
        }
    }

    fn romBytes(self: Cartridge) []const u8 {
        return switch (self) {
            .rom_only => |c| c.rom,
            .mbc1, .mbc3 => unreachable,
        };
    }
};

// --- Tests -----------------------------------------------------------------

/// Construit une fausse ROM de 32 Kio avec un en-tête valide.
fn fakeRom(buf: *[32 * 1024]u8, title: []const u8, cartridge_type: u8) []u8 {
    @memset(buf, 0);
    @memcpy(buf[title_start..][0..title.len], title);
    buf[type_addr] = cartridge_type;
    buf[rom_size_addr] = 0x00;
    buf[ram_size_addr] = 0x00;
    buf[checksum_addr] = computeChecksum(buf);
    return buf;
}

test "en-tête : champs lus correctement" {
    var buf: [32 * 1024]u8 = undefined;
    const rom = fakeRom(&buf, "TETRIS", 0x00);

    const h = try Header.parse(rom);
    try std.testing.expectEqualStrings("TETRIS", h.title);
    try std.testing.expectEqual(@as(u8, 0x00), h.cartridge_type);
    try std.testing.expectEqualStrings("ROM ONLY", h.typeName());
    try std.testing.expectEqual(@as(usize, 32 * 1024), h.rom_size);
    try std.testing.expectEqual(@as(usize, 0), h.ram_size);
}

test "checksum : valeur calculée = valeur en 0x014D" {
    var buf: [32 * 1024]u8 = undefined;
    const rom = fakeRom(&buf, "TETRIS", 0x00);
    try std.testing.expectEqual(rom[checksum_addr], computeChecksum(rom));

    // Valeur de référence calculée à la main pour cet en-tête.
    var sum: u8 = 0;
    for (rom[0x0134..0x014D]) |b| sum = sum -% b -% 1;
    try std.testing.expectEqual(sum, rom[checksum_addr]);
}

test "checksum : en-tête corrompu refusé" {
    var buf: [32 * 1024]u8 = undefined;
    const rom = fakeRom(&buf, "TETRIS", 0x00);
    rom[title_start] ^= 0xFF;
    try std.testing.expectError(error.InvalidChecksum, Header.parse(rom));
}

test "ROM trop courte refusée" {
    const rom: [0x100]u8 = @splat(0);
    try std.testing.expectError(error.RomTooSmall, Header.parse(&rom));
}

test "type inconnu : UnsupportedCartridge" {
    var buf: [32 * 1024]u8 = undefined;
    const rom = fakeRom(&buf, "INCONNU", 0xEE);
    try std.testing.expectError(error.UnsupportedCartridge, Cartridge.init(rom));
}

test "MBC1 et MBC3 : pas encore gérés" {
    var buf: [32 * 1024]u8 = undefined;
    try std.testing.expectError(error.UnsupportedCartridge, Cartridge.init(fakeRom(&buf, "A", 0x01)));
    try std.testing.expectError(error.UnsupportedCartridge, Cartridge.init(fakeRom(&buf, "A", 0x13)));
}

test "ROM ONLY : lecture et écriture ignorée" {
    var buf: [32 * 1024]u8 = undefined;
    const rom = fakeRom(&buf, "TETRIS", 0x00);
    rom[0x0100] = 0x42;

    // Le checksum ne couvre pas 0x0100 : l'en-tête reste valide.
    var cart = try Cartridge.init(rom);
    try std.testing.expectEqual(@as(u8, 0x42), cart.read(0x0100));
    cart.write(0x0100, 0x99);
    try std.testing.expectEqual(@as(u8, 0x42), cart.read(0x0100));
    try std.testing.expectEqualStrings("TETRIS", cart.header().title);
}
