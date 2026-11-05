//! Racine du module `gb` : le cœur de l'émulateur.
//!
//! Ce module ne dépend que de `std` : aucune bibliothèque graphique,
//! aucune fenêtre. Il se teste donc entièrement en headless et pourra
//! plus tard être compilé pour WebAssembly.
//!
//! Les composants (cpu.zig, bus.zig, cartridge.zig, ...) vivent dans ce
//! dossier et sont ré-exportés ici ; `GameBoy` les assemble.

const std = @import("std");

pub const cartridge = @import("cartridge.zig");
pub const Cartridge = cartridge.Cartridge;
pub const bus = @import("bus.zig");
pub const Bus = bus.Bus;
pub const Interrupt = bus.Interrupt;
pub const cpu = @import("cpu.zig");
pub const Cpu = cpu.Cpu;
pub const timer = @import("timer.zig");
pub const Timer = timer.Timer;

/// La machine complète : le CPU et le bus, qui porte la mémoire et les
/// périphériques (timer sur 0xFF04..0xFF07, port série, IF/IE...).
///
/// Le bus pèse plusieurs dizaines de Kio : allouer le `GameBoy` sur le
/// tas (ou en global) plutôt que sur une petite pile.
pub const GameBoy = struct {
    cpu: Cpu,
    bus: Bus,

    pub fn init(cart: Cartridge) GameBoy {
        return .{ .cpu = Cpu.init(), .bus = Bus.init(cart) };
    }

    /// Exécute une instruction (ou un M-cycle de HALT, ou la prise en
    /// charge d'une interruption) puis fait avancer les périphériques
    /// d'autant. Renvoie le nombre de M-cycles écoulés.
    ///
    /// Les interruptions levées pendant ce tick (débordement de TIMA...)
    /// sont dans IF : le CPU les verra au début du `step` suivant.
    pub fn step(self: *GameBoy) cpu.Error!u8 {
        const m_cycles = try self.cpu.step(&self.bus);
        self.bus.tick(m_cycles);
        return m_cycles;
    }
};

/// ROM ONLY de 32 Kio : `program` en 0x0100, le reste à 0 (NOP).
fn testRom(buf: *[32 * 1024]u8, program: []const u8) !Cartridge {
    @memset(buf, 0);
    @memcpy(buf[0x0100..][0..program.len], program);
    buf[0x014D] = cartridge.computeChecksum(buf);
    return Cartridge.init(buf);
}

test "step : exécute une instruction et fait avancer le timer d'autant" {
    var buf: [32 * 1024]u8 = undefined;
    // 0x0100 : NOP. 0x0101 : JP 0x0101 (4 M-cycles), en boucle.
    var gameboy = GameBoy.init(try testRom(&buf, &.{ 0x00, 0xC3, 0x01, 0x01 }));

    try std.testing.expectEqual(@as(u8, 1), try gameboy.step());
    try std.testing.expectEqual(@as(u16, 0x0101), gameboy.cpu.pc);
    try std.testing.expectEqual(@as(u16, 4), gameboy.bus.timer.counter);

    // DIV avance tous les 64 M-cycles : 1 + 15 × 4 = 61, puis 65.
    for (0..15) |_| try std.testing.expectEqual(@as(u8, 4), try gameboy.step());
    try std.testing.expectEqual(@as(u8, 0), gameboy.bus.read(0xFF04));
    _ = try gameboy.step();
    try std.testing.expectEqual(@as(u8, 1), gameboy.bus.read(0xFF04));
}

test "step : le débordement de TIMA réveille HALT et déclenche l'interruption" {
    var buf: [32 * 1024]u8 = undefined;
    // EI ; HALT. Le timer (TAC=0x05 : +1 tous les 4 M-cycles) part de
    // TIMA=0xFF : il déborde vite et doit faire sauter le CPU en 0x0050.
    var gameboy = GameBoy.init(try testRom(&buf, &.{ 0xFB, 0x76 }));
    gameboy.bus.write(0xFFFF, Interrupt.timer.mask());
    gameboy.bus.write(0xFF05, 0xFF);
    gameboy.bus.write(0xFF07, 0x05);

    var steps: u32 = 0;
    while (gameboy.cpu.pc != 0x0050) : (steps += 1) {
        if (steps == 100) return error.TestUnexpectedResult;
        _ = try gameboy.step();
    }
    try std.testing.expect(!gameboy.cpu.ime);
    try std.testing.expectEqual(@as(u8, 0), gameboy.bus.if_ & Interrupt.timer.mask());
}

test {
    // Inclut les blocs `test` des fichiers ré-exportés par ce module.
    std.testing.refAllDecls(@This());
}
