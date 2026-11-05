//! CPU SM83.
//!
//! Chaque opcode est découpé en trois champs :
//!   x = bits 7-6, y = bits 5-3, z = bits 2-0
//! Une valeur 0-7 de y ou z désigne un opérande dans l'ordre
//! B, C, D, E, H, L, (HL), A.
//!
//! `step` exécute une instruction et renvoie son nombre de M-cycles.

const std = @import("std");
const Bus = @import("bus.zig").Bus;

pub const Error = error{
    /// Opcode pas encore implémenté.
    UnimplementedOpcode,
};

/// Registre F. Les 4 bits bas valent toujours 0.
pub const Flags = packed struct(u8) {
    _unused: u4 = 0,
    c: bool = false,
    h: bool = false,
    n: bool = false,
    z: bool = false,
};

pub const Cpu = struct {
    a: u8,
    f: Flags,
    b: u8,
    c: u8,
    d: u8,
    e: u8,
    h: u8,
    l: u8,
    sp: u16,
    pc: u16,

    /// État post-boot d'une DMG (on saute la ROM de boot).
    pub fn init() Cpu {
        return .{
            .a = 0x01,
            .f = @bitCast(@as(u8, 0xB0)),
            .b = 0x00,
            .c = 0x13,
            .d = 0x00,
            .e = 0xD8,
            .h = 0x01,
            .l = 0x4D,
            .sp = 0xFFFE,
            .pc = 0x0100,
        };
    }

    pub fn hl(self: *const Cpu) u16 {
        return @as(u16, self.h) << 8 | self.l;
    }

    /// Exécute une instruction et renvoie son nombre de M-cycles.
    pub fn step(self: *Cpu, bus: *Bus) Error!u8 {
        const opcode = self.fetch(bus);
        return switch (opcode) {
            inline else => |op| self.execute(bus, op),
        };
    }

    fn fetch(self: *Cpu, bus: *Bus) u8 {
        const value = bus.read(self.pc);
        self.pc +%= 1;
        return value;
    }

    fn execute(self: *Cpu, bus: *Bus, comptime op: u8) Error!u8 {
        const x: u2 = @truncate(op >> 6);
        const y: u3 = @truncate(op >> 3);
        const z: u3 = @truncate(op);

        // NOP
        if (op == 0x00) return 1;

        // LD r,n  (LD (HL),n pour y = 6)
        if (x == 0 and z == 6) {
            const n = self.fetch(bus);
            self.writeR(bus, y, n);
            return if (y == 6) 3 else 2;
        }

        // LD r,r'  (0x76 serait LD (HL),(HL) : c'est HALT)
        if (x == 1 and op != 0x76) {
            self.writeR(bus, y, self.readR(bus, z));
            return if (y == 6 or z == 6) 2 else 1;
        }

        return error.UnimplementedOpcode;
    }

    fn readR(self: *Cpu, bus: *Bus, comptime i: u3) u8 {
        return switch (i) {
            0 => self.b,
            1 => self.c,
            2 => self.d,
            3 => self.e,
            4 => self.h,
            5 => self.l,
            6 => bus.read(self.hl()),
            7 => self.a,
        };
    }

    fn writeR(self: *Cpu, bus: *Bus, comptime i: u3, value: u8) void {
        switch (i) {
            0 => self.b = value,
            1 => self.c = value,
            2 => self.d = value,
            3 => self.e = value,
            4 => self.h = value,
            5 => self.l = value,
            6 => bus.write(self.hl(), value),
            7 => self.a = value,
        }
    }
};

// --- Tests -----------------------------------------------------------------

const cartridge = @import("cartridge.zig");

/// Bus sur une ROM ONLY vide, et CPU qui exécute `program` depuis la WRAM.
fn setup(buf: *[32 * 1024]u8, program: []const u8) !struct { Cpu, Bus } {
    @memset(buf, 0);
    buf[0x014D] = cartridge.computeChecksum(buf);
    var bus = Bus.init(try cartridge.Cartridge.init(buf));
    for (program, 0..) |byte, i| bus.write(0xC000 + @as(u16, @intCast(i)), byte);
    var cpu = Cpu.init();
    cpu.pc = 0xC000;
    return .{ cpu, bus };
}

const expectEqual = std.testing.expectEqual;

test "NOP : 1 M-cycle, PC avance, rien d'autre ne change" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{0x00});
    const avant = cpu;

    try expectEqual(@as(u8, 1), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xC001), cpu.pc);
    cpu.pc = avant.pc;
    try expectEqual(avant, cpu);
}

test "LD B,C et LD A,L : 1 M-cycle" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x41, 0x7D });
    cpu.c = 0x42;
    cpu.l = 0x99;

    try expectEqual(@as(u8, 1), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x42), cpu.b);
    try expectEqual(@as(u8, 1), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x99), cpu.a);
}

test "LD r,n : 2 M-cycles, lit l'octet immédiat" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x06, 0x12, 0x3E, 0xAB });

    try expectEqual(@as(u8, 2), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x12), cpu.b);
    try expectEqual(@as(u8, 2), try cpu.step(&bus));
    try expectEqual(@as(u8, 0xAB), cpu.a);
    try expectEqual(@as(u16, 0xC004), cpu.pc);
}

test "LD (HL),r : 2 M-cycles, écrit à l'adresse HL" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x77, 0x74 });
    cpu.h = 0xC1;
    cpu.l = 0x00;
    cpu.a = 0x5A;

    try expectEqual(@as(u8, 2), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x5A), bus.read(0xC100));
    // LD (HL),H : écrit l'octet haut de l'adresse elle-même.
    try expectEqual(@as(u8, 2), try cpu.step(&bus));
    try expectEqual(@as(u8, 0xC1), bus.read(0xC100));
}

test "LD r,(HL) : 2 M-cycles ; LD (HL),n : 3 M-cycles" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x36, 0x77, 0x4E });
    cpu.h = 0xC2;
    cpu.l = 0x34;

    try expectEqual(@as(u8, 3), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x77), bus.read(0xC234));
    try expectEqual(@as(u8, 2), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x77), cpu.c);
}

test "0x76 (HALT) n'est pas un LD" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{0x76});
    try std.testing.expectError(error.UnimplementedOpcode, cpu.step(&bus));
}
