//! CPU SM83.
//!
//! Chaque opcode est découpé en trois champs :
//!   x = bits 7-6, y = bits 5-3, z = bits 2-0
//! Une valeur 0-7 de y ou z désigne un opérande dans l'ordre
//! B, C, D, E, H, L, (HL), A.
//! Pour les instructions 16 bits, p = y >> 1 désigne une paire :
//!   rp  : BC, DE, HL, SP  (LD rr,nn)
//!   rp2 : BC, DE, HL, AF  (PUSH / POP)
//! et q = y & 1 distingue deux instructions de la même colonne.
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

    // --- Paires de registres -------------------------------------------

    pub fn af(self: *const Cpu) u16 {
        return @as(u16, self.a) << 8 | @as(u8, @bitCast(self.f));
    }

    pub fn bc(self: *const Cpu) u16 {
        return @as(u16, self.b) << 8 | self.c;
    }

    pub fn de(self: *const Cpu) u16 {
        return @as(u16, self.d) << 8 | self.e;
    }

    pub fn hl(self: *const Cpu) u16 {
        return @as(u16, self.h) << 8 | self.l;
    }

    /// Les 4 bits bas de F n'existent pas : ils sont forcés à 0.
    pub fn setAf(self: *Cpu, value: u16) void {
        self.a = @truncate(value >> 8);
        self.f = @bitCast(@as(u8, @truncate(value)) & 0xF0);
    }

    pub fn setBc(self: *Cpu, value: u16) void {
        self.b = @truncate(value >> 8);
        self.c = @truncate(value);
    }

    pub fn setDe(self: *Cpu, value: u16) void {
        self.d = @truncate(value >> 8);
        self.e = @truncate(value);
    }

    pub fn setHl(self: *Cpu, value: u16) void {
        self.h = @truncate(value >> 8);
        self.l = @truncate(value);
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

    /// Lit un mot 16 bits little-endian (octet bas d'abord) à PC.
    fn fetch16(self: *Cpu, bus: *Bus) u16 {
        const lo = self.fetch(bus);
        const hi = self.fetch(bus);
        return @as(u16, hi) << 8 | lo;
    }

    /// Empile un mot : SP descend, octet haut écrit en premier.
    fn push(self: *Cpu, bus: *Bus, value: u16) void {
        self.sp -%= 1;
        bus.write(self.sp, @truncate(value >> 8));
        self.sp -%= 1;
        bus.write(self.sp, @truncate(value));
    }

    /// Dépile un mot : octet bas lu en premier, SP remonte.
    fn pop(self: *Cpu, bus: *Bus) u16 {
        const lo = bus.read(self.sp);
        self.sp +%= 1;
        const hi = bus.read(self.sp);
        self.sp +%= 1;
        return @as(u16, hi) << 8 | lo;
    }

    fn execute(self: *Cpu, bus: *Bus, comptime op: u8) Error!u8 {
        const x: u2 = @truncate(op >> 6);
        const y: u3 = @truncate(op >> 3);
        const z: u3 = @truncate(op);
        const p: u2 = @truncate(y >> 1);
        const q: u1 = @truncate(y);

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

        // LD rr,nn
        if (x == 0 and z == 1 and q == 0) {
            self.writeRp(p, self.fetch16(bus));
            return 3;
        }

        // LD (nn),SP : octet bas à nn, octet haut à nn+1
        if (op == 0x08) {
            const addr = self.fetch16(bus);
            bus.write(addr, @truncate(self.sp));
            bus.write(addr +% 1, @truncate(self.sp >> 8));
            return 5;
        }

        // LD SP,HL
        if (op == 0xF9) {
            self.sp = self.hl();
            return 2;
        }

        // POP rr
        if (x == 3 and z == 1 and q == 0) {
            self.writeRp2(p, self.pop(bus));
            return 3;
        }

        // PUSH rr
        if (x == 3 and z == 5 and q == 0) {
            self.push(bus, self.readRp2(p));
            return 4;
        }

        // ALU A,r : y choisit l'opération, z l'opérande
        if (x == 2) {
            self.alu(y, self.readR(bus, z));
            return if (z == 6) 2 else 1;
        }

        // ALU A,n : même chose avec un octet immédiat
        if (x == 3 and z == 6) {
            self.alu(y, self.fetch(bus));
            return 2;
        }

        // INC r  (lecture + écriture de (HL) pour y = 6)
        if (x == 0 and z == 4) {
            const v = self.readR(bus, y);
            const r = v +% 1;
            self.f.z = r == 0;
            self.f.n = false;
            self.f.h = v & 0x0F == 0x0F;
            self.writeR(bus, y, r);
            return if (y == 6) 3 else 1;
        }

        // DEC r
        if (x == 0 and z == 5) {
            const v = self.readR(bus, y);
            const r = v -% 1;
            self.f.z = r == 0;
            self.f.n = true;
            self.f.h = v & 0x0F == 0;
            self.writeR(bus, y, r);
            return if (y == 6) 3 else 1;
        }

        return error.UnimplementedOpcode;
    }

    /// Opérations ALU 8 bits sur A, dans l'ordre de y :
    /// ADD, ADC, SUB, SBC, AND, XOR, OR, CP.
    fn alu(self: *Cpu, comptime op: u3, v: u8) void {
        const a = self.a;
        switch (op) {
            // ADD / ADC
            0, 1 => {
                const carry: u8 = if (op == 1 and self.f.c) 1 else 0;
                const sum = @as(u16, a) + v + carry;
                const r: u8 = @truncate(sum);
                self.f = .{
                    .z = r == 0,
                    .h = (a & 0x0F) + (v & 0x0F) + carry > 0x0F,
                    .c = sum > 0xFF,
                };
                self.a = r;
            },
            // SUB / SBC / CP (CP = SUB sans garder le résultat)
            2, 3, 7 => {
                const carry: u8 = if (op == 3 and self.f.c) 1 else 0;
                const r = a -% v -% carry;
                self.f = .{
                    .z = r == 0,
                    .n = true,
                    .h = @as(u16, a & 0x0F) < @as(u16, v & 0x0F) + carry,
                    .c = @as(u16, a) < @as(u16, v) + carry,
                };
                if (op != 7) self.a = r;
            },
            // AND : H vaut toujours 1
            4 => {
                self.a = a & v;
                self.f = .{ .z = self.a == 0, .h = true };
            },
            5 => {
                self.a = a ^ v;
                self.f = .{ .z = self.a == 0 };
            },
            6 => {
                self.a = a | v;
                self.f = .{ .z = self.a == 0 };
            },
        }
    }

    fn writeRp(self: *Cpu, comptime i: u2, value: u16) void {
        switch (i) {
            0 => self.setBc(value),
            1 => self.setDe(value),
            2 => self.setHl(value),
            3 => self.sp = value,
        }
    }

    fn readRp2(self: *const Cpu, comptime i: u2) u16 {
        return switch (i) {
            0 => self.bc(),
            1 => self.de(),
            2 => self.hl(),
            3 => self.af(),
        };
    }

    fn writeRp2(self: *Cpu, comptime i: u2, value: u16) void {
        switch (i) {
            0 => self.setBc(value),
            1 => self.setDe(value),
            2 => self.setHl(value),
            3 => self.setAf(value),
        }
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

test "LD rr,nn : 3 M-cycles, little-endian" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{
        0x01, 0x34, 0x12, // LD BC,0x1234
        0x11, 0x78, 0x56, // LD DE,0x5678
        0x21, 0xBC, 0x9A, // LD HL,0x9ABC
        0x31, 0xF0, 0xDF, // LD SP,0xDFF0
    });

    try expectEqual(@as(u8, 3), try cpu.step(&bus));
    try expectEqual(@as(u16, 0x1234), cpu.bc());
    try expectEqual(@as(u8, 3), try cpu.step(&bus));
    try expectEqual(@as(u16, 0x5678), cpu.de());
    try expectEqual(@as(u8, 3), try cpu.step(&bus));
    try expectEqual(@as(u16, 0x9ABC), cpu.hl());
    try expectEqual(@as(u8, 3), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xDFF0), cpu.sp);
    try expectEqual(@as(u16, 0xC00C), cpu.pc);
}

test "LD (nn),SP : 5 M-cycles, octet bas en premier" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x08, 0x00, 0xC1 });
    cpu.sp = 0xBEEF;

    try expectEqual(@as(u8, 5), try cpu.step(&bus));
    try expectEqual(@as(u8, 0xEF), bus.read(0xC100));
    try expectEqual(@as(u8, 0xBE), bus.read(0xC101));
}

test "LD SP,HL : 2 M-cycles" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{0xF9});
    cpu.setHl(0xD000);

    try expectEqual(@as(u8, 2), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xD000), cpu.sp);
}

test "PUSH BC : 4 M-cycles, SP -= 2, octet haut à SP+1" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{0xC5});
    cpu.sp = 0xD000;
    cpu.setBc(0x1234);

    try expectEqual(@as(u8, 4), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xCFFE), cpu.sp);
    try expectEqual(@as(u8, 0x12), bus.read(0xCFFF));
    try expectEqual(@as(u8, 0x34), bus.read(0xCFFE));
}

test "PUSH DE puis POP HL : 3 M-cycles, copie DE dans HL" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xD5, 0xE1 });
    cpu.sp = 0xD000;
    cpu.setDe(0xCAFE);

    _ = try cpu.step(&bus);
    try expectEqual(@as(u8, 3), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xCAFE), cpu.hl());
    try expectEqual(@as(u16, 0xD000), cpu.sp);
}

test "POP AF : les 4 bits bas de F restent à 0" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xC5, 0xF1, 0xF5 });
    cpu.sp = 0xD000;
    cpu.setBc(0x12FF);

    _ = try cpu.step(&bus); // PUSH BC
    _ = try cpu.step(&bus); // POP AF
    try expectEqual(@as(u16, 0x12F0), cpu.af());
    try expectEqual(true, cpu.f.z and cpu.f.n and cpu.f.h and cpu.f.c);

    _ = try cpu.step(&bus); // PUSH AF
    try expectEqual(@as(u8, 0xF0), bus.read(0xCFFE));
}

/// Exécute une instruction et vérifie A, F (z n h c) et le nombre de M-cycles.
fn expectAlu(cpu: *Cpu, bus: *Bus, cycles: u8, a: u8, f: u8) !void {
    try expectEqual(cycles, try cpu.step(bus));
    try expectEqual(a, cpu.a);
    try expectEqual(f, @as(u8, @bitCast(cpu.f)));
}

test "ADD A,B : demi-retenue et retenue" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x80, 0x80, 0x80 });
    cpu.f = .{};

    cpu.a = 0x0F;
    cpu.b = 0x01;
    try expectAlu(&cpu, &bus, 1, 0x10, 0x20); // H
    cpu.a = 0xF0;
    cpu.b = 0x10;
    try expectAlu(&cpu, &bus, 1, 0x00, 0x90); // Z C
    cpu.a = 0x12;
    cpu.b = 0x34;
    try expectAlu(&cpu, &bus, 1, 0x46, 0x00);
}

test "ADC A,n : ajoute la retenue, 2 M-cycles" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xCE, 0x0E, 0xCE, 0xFF });
    cpu.a = 0x01;
    cpu.f = .{ .c = true };

    try expectAlu(&cpu, &bus, 2, 0x10, 0x20); // 1 + 0x0E + 1 : H
    cpu.f = .{ .c = true };
    try expectAlu(&cpu, &bus, 2, 0x10, 0x30); // 0x10 + 0xFF + 1 : H C
}

test "SUB et SBC : emprunts" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x90, 0x90, 0x98 });
    cpu.f = .{};

    cpu.a = 0x10;
    cpu.b = 0x01;
    try expectAlu(&cpu, &bus, 1, 0x0F, 0x60); // N H
    cpu.a = 0x00;
    cpu.b = 0x01;
    try expectAlu(&cpu, &bus, 1, 0xFF, 0x70); // N H C
    // SBC A,B avec C = 1 : 0xFF - 0xFE - 1 = 0
    cpu.b = 0xFE;
    try expectAlu(&cpu, &bus, 1, 0x00, 0xC0); // Z N
}

test "SBC A,n : la retenue compte dans H et C" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xDE, 0x0F });
    cpu.a = 0x0F;
    cpu.f = .{ .c = true };
    try expectAlu(&cpu, &bus, 2, 0xFF, 0x70); // 0x0F - 0x0F - 1
}

test "AND, XOR, OR" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xA0, 0xAF, 0xB1 });
    cpu.f = .{ .c = true, .n = true };

    cpu.a = 0xF0;
    cpu.b = 0x0F;
    try expectAlu(&cpu, &bus, 1, 0x00, 0xA0); // AND B : Z H
    cpu.a = 0x5A;
    try expectAlu(&cpu, &bus, 1, 0x00, 0x80); // XOR A : Z
    cpu.c = 0x81;
    try expectAlu(&cpu, &bus, 1, 0x81, 0x00); // OR C
}

test "CP (HL) : 2 M-cycles, A inchangé" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xBE, 0xFE, 0x42 });
    cpu.setHl(0xC100);
    bus.write(0xC100, 0x42);
    cpu.a = 0x42;
    cpu.f = .{};

    try expectAlu(&cpu, &bus, 2, 0x42, 0xC0); // égal : Z N
    try expectAlu(&cpu, &bus, 2, 0x42, 0xC0); // CP n
}

test "INC / DEC r : C inchangé" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x04, 0x05, 0x3C, 0x3D });
    cpu.f = .{ .c = true };

    cpu.b = 0xFF;
    try expectEqual(@as(u8, 1), try cpu.step(&bus)); // INC B
    try expectEqual(@as(u8, 0x00), cpu.b);
    try expectEqual(@as(u8, 0xB0), @as(u8, @bitCast(cpu.f))); // Z H C
    try expectEqual(@as(u8, 1), try cpu.step(&bus)); // DEC B
    try expectEqual(@as(u8, 0xFF), cpu.b);
    try expectEqual(@as(u8, 0x70), @as(u8, @bitCast(cpu.f))); // N H C

    cpu.a = 0x01;
    cpu.f = .{};
    try expectAlu(&cpu, &bus, 1, 0x02, 0x00); // INC A
    try expectAlu(&cpu, &bus, 1, 0x01, 0x40); // DEC A : N
}

test "INC (HL) / DEC (HL) : 3 M-cycles" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x34, 0x35, 0x35 });
    cpu.setHl(0xC100);
    bus.write(0xC100, 0x0F);

    try expectEqual(@as(u8, 3), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x10), bus.read(0xC100));
    try expectEqual(@as(u8, 3), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x0F), bus.read(0xC100));
    try expectEqual(true, cpu.f.h and cpu.f.n);
    bus.write(0xC100, 0x01);
    _ = try cpu.step(&bus);
    try expectEqual(true, cpu.f.z);
}
