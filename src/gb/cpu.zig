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
//! Pour les sauts conditionnels, cc = y & 3 : NZ, Z, NC, C.
//!
//! `step` exécute une instruction et renvoie son nombre de M-cycles.
//!
//! Le bus est un paramètre `anytype` : tout type qui fournit
//! `read(addr: u16) u8` et `write(addr: u16, value: u8)` convient.
//! L'émulateur passe le vrai `Bus` ; le harnais SingleStepTests passe
//! une mémoire plate de 64 Kio. Zig compile une version par type.

const std = @import("std");

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
    /// Interrupt Master Enable : autorise les interruptions (RETI, EI, DI).
    ime: bool,
    /// Posé par EI : IME passe à 1 au début de l'instruction suivante,
    /// donc après qu'elle s'est exécutée côté interruptions.
    ime_pending: bool,
    /// HALT : le CPU ne fait plus rien jusqu'à une interruption (phase 3).
    halted: bool,
    /// STOP : mode basse consommation jusqu'à un appui sur un bouton (phase 5).
    stopped: bool,

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
            .ime = false,
            .ime_pending = false,
            .halted = false,
            .stopped = false,
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

    /// Exécute une instruction (ou prend en charge une interruption) et
    /// renvoie son nombre de M-cycles.
    /// En HALT ou STOP, le CPU est à l'arrêt : 1 M-cycle sans rien lire.
    pub fn step(self: *Cpu, bus: anytype) Error!u8 {
        if (self.halted or self.stopped) return 1;
        // Les interruptions sont testées AVANT d'appliquer le délai de EI :
        // juste après EI, IME vaut encore 0 ici, donc l'instruction qui suit
        // EI s'exécute toujours avant qu'une interruption puisse être prise.
        if (self.ime) {
            const pending = bus.read(0xFFFF) & bus.read(0xFF0F) & 0x1F;
            if (pending != 0) return self.serviceInterrupt(bus, pending);
        }
        // Délai de EI : l'instruction qui suit EI s'exécute encore avec
        // l'ancien IME ; les interruptions ne seront vues qu'après elle.
        if (self.ime_pending) {
            self.ime_pending = false;
            self.ime = true;
        }
        const opcode = self.fetch(bus);
        return switch (opcode) {
            inline else => |op| self.execute(bus, op),
        };
    }

    /// Prise en charge d'une interruption : la plus prioritaire est celle
    /// du bit le plus bas (VBlank > STAT > Timer > Série > Joypad).
    /// IME passe à 0, son bit est effacé de IF, PC est empilé puis on saute
    /// au vecteur 0x40 + 8 × bit. Coûte 5 M-cycles.
    fn serviceInterrupt(self: *Cpu, bus: anytype, pending: u8) u8 {
        const bit: u3 = @intCast(@ctz(pending));
        self.ime = false;
        // Un EI juste avant ne doit pas réactiver IME au milieu du handler.
        self.ime_pending = false;
        const flags = bus.read(0xFF0F) & 0x1F;
        bus.write(0xFF0F, flags & ~(@as(u8, 1) << bit));
        self.push(bus, self.pc);
        self.pc = 0x40 + 8 * @as(u16, bit);
        return 5;
    }

    fn fetch(self: *Cpu, bus: anytype) u8 {
        const value = bus.read(self.pc);
        self.pc +%= 1;
        return value;
    }

    /// Lit un mot 16 bits little-endian (octet bas d'abord) à PC.
    fn fetch16(self: *Cpu, bus: anytype) u16 {
        const lo = self.fetch(bus);
        const hi = self.fetch(bus);
        return @as(u16, hi) << 8 | lo;
    }

    /// Empile un mot : SP descend, octet haut écrit en premier.
    fn push(self: *Cpu, bus: anytype, value: u16) void {
        self.sp -%= 1;
        bus.write(self.sp, @truncate(value >> 8));
        self.sp -%= 1;
        bus.write(self.sp, @truncate(value));
    }

    /// Dépile un mot : octet bas lu en premier, SP remonte.
    fn pop(self: *Cpu, bus: anytype) u16 {
        const lo = bus.read(self.sp);
        self.sp +%= 1;
        const hi = bus.read(self.sp);
        self.sp +%= 1;
        return @as(u16, hi) << 8 | lo;
    }

    fn execute(self: *Cpu, bus: anytype, comptime op: u8) Error!u8 {
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

        // LD (rr),A / LD A,(rr) : p choisit l'adresse BC, DE, HL+ ou HL-,
        // q le sens (0 : écriture de A, 1 : lecture dans A).
        // HL+ et HL- : HL est incrémenté / décrémenté après l'accès.
        if (x == 0 and z == 2) {
            const addr = switch (p) {
                0 => self.bc(),
                1 => self.de(),
                2, 3 => self.hl(),
            };
            if (p == 2) self.setHl(addr +% 1);
            if (p == 3) self.setHl(addr -% 1);
            if (q == 0) bus.write(addr, self.a) else self.a = bus.read(addr);
            return 2;
        }

        // LDH (n),A / LDH A,(n) : adresse 0xFF00 + n (registres d'E/S, HRAM)
        if (op == 0xE0 or op == 0xF0) {
            const addr = 0xFF00 | @as(u16, self.fetch(bus));
            if (op == 0xE0) bus.write(addr, self.a) else self.a = bus.read(addr);
            return 3;
        }

        // LD (C),A / LD A,(C) : comme LDH, avec C à la place de n
        if (op == 0xE2 or op == 0xF2) {
            const addr = 0xFF00 | @as(u16, self.c);
            if (op == 0xE2) bus.write(addr, self.a) else self.a = bus.read(addr);
            return 2;
        }

        // LD (nn),A / LD A,(nn)
        if (op == 0xEA or op == 0xFA) {
            const addr = self.fetch16(bus);
            if (op == 0xEA) bus.write(addr, self.a) else self.a = bus.read(addr);
            return 4;
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

        // ADD HL,rr : Z inchangé, H sur le bit 11, C sur le bit 15
        if (x == 0 and z == 1 and q == 1) {
            const v = self.readRp(p);
            const h = self.hl();
            self.f.n = false;
            self.f.h = (h & 0x0FFF) + (v & 0x0FFF) > 0x0FFF;
            self.f.c = @as(u32, h) + v > 0xFFFF;
            self.setHl(h +% v);
            return 2;
        }

        // INC rr / DEC rr : aucun flag touché
        if (x == 0 and z == 3) {
            const v = self.readRp(p);
            self.writeRp(p, if (q == 0) v +% 1 else v -% 1);
            return 2;
        }

        // ADD SP,e
        if (op == 0xE8) {
            self.sp = self.spPlusE(self.fetch(bus));
            return 4;
        }

        // LD HL,SP+e
        if (op == 0xF8) {
            self.setHl(self.spPlusE(self.fetch(bus)));
            return 3;
        }

        // JP nn
        if (op == 0xC3) {
            self.pc = self.fetch16(bus);
            return 4;
        }

        // JP cc,nn : l'adresse est lue même si le saut n'est pas pris
        if (x == 3 and z == 2 and y < 4) {
            const addr = self.fetch16(bus);
            if (!self.cond(@truncate(y))) return 3;
            self.pc = addr;
            return 4;
        }

        // JP HL : pas de lecture mémoire, 1 seul M-cycle
        if (op == 0xE9) {
            self.pc = self.hl();
            return 1;
        }

        // JR e : déplacement signé depuis l'adresse qui suit l'instruction
        if (op == 0x18) {
            self.jr(self.fetch(bus));
            return 3;
        }

        // JR cc,e
        if (x == 0 and z == 0 and y >= 4) {
            const e = self.fetch(bus);
            if (!self.cond(@truncate(y))) return 2;
            self.jr(e);
            return 3;
        }

        // CALL nn : empile l'adresse de retour (celle qui suit le CALL)
        if (op == 0xCD) {
            const addr = self.fetch16(bus);
            self.push(bus, self.pc);
            self.pc = addr;
            return 6;
        }

        // CALL cc,nn
        if (x == 3 and z == 4 and y < 4) {
            const addr = self.fetch16(bus);
            if (!self.cond(@truncate(y))) return 3;
            self.push(bus, self.pc);
            self.pc = addr;
            return 6;
        }

        // RET
        if (op == 0xC9) {
            self.pc = self.pop(bus);
            return 4;
        }

        // RETI : RET + IME = 1 tout de suite (sans le délai de EI)
        if (op == 0xD9) {
            self.pc = self.pop(bus);
            self.ime = true;
            return 4;
        }

        // RET cc : un M-cycle de plus que RET quand il est pris (test de cc)
        if (x == 3 and z == 0 and y < 4) {
            if (!self.cond(@truncate(y))) return 2;
            self.pc = self.pop(bus);
            return 5;
        }

        // RST n : CALL vers l'adresse fixe y * 8 (0x00, 0x08, ..., 0x38)
        if (x == 3 and z == 7) {
            self.push(bus, self.pc);
            self.pc = @as(u16, y) * 8;
            return 4;
        }

        // RLCA, RRCA, RLA, RRA : comme leurs versions CB sur A,
        // mais Z vaut toujours 0 et 1 seul M-cycle
        if (x == 0 and z == 7 and y < 4) {
            self.a = self.rot(@truncate(y), self.a);
            self.f.z = false;
            return 1;
        }

        // DAA : corrige A après une addition ou soustraction BCD
        // (chaque quartet code un chiffre décimal 0-9). Algorithme des Pan Docs.
        if (op == 0x27) {
            var adj: u8 = 0;
            var c = self.f.c;
            if (self.f.n) {
                if (self.f.h) adj |= 0x06;
                if (c) adj |= 0x60;
                self.a -%= adj;
            } else {
                if (self.f.h or self.a & 0x0F > 0x09) adj |= 0x06;
                if (c or self.a > 0x99) {
                    adj |= 0x60;
                    c = true;
                }
                self.a +%= adj;
            }
            self.f = .{ .z = self.a == 0, .n = self.f.n, .c = c };
            return 1;
        }

        // CPL : A = ~A ; N = H = 1, Z et C inchangés
        if (op == 0x2F) {
            self.a = ~self.a;
            self.f.n = true;
            self.f.h = true;
            return 1;
        }

        // SCF / CCF : C = 1 ou C inversé ; N = H = 0, Z inchangé
        if (op == 0x37 or op == 0x3F) {
            self.f.c = if (op == 0x37) true else !self.f.c;
            self.f.n = false;
            self.f.h = false;
            return 1;
        }

        // DI : immédiat, et annule un EI qui n'aurait pas encore pris effet
        if (op == 0xF3) {
            self.ime = false;
            self.ime_pending = false;
            return 1;
        }

        // EI : IME = 1 seulement après l'instruction suivante
        if (op == 0xFB) {
            self.ime_pending = true;
            return 1;
        }

        // HALT : le réveil (IE & IF != 0) et le « HALT bug » viendront en phase 3
        if (op == 0x76) {
            self.halted = true;
            return 1;
        }

        // STOP : suivi d'un octet ignoré (normalement 0x00)
        if (op == 0x10) {
            _ = self.fetch(bus);
            self.stopped = true;
            return 1;
        }

        // Préfixe CB : un second octet choisit l'instruction.
        // Les 4 M-cycles de base incluent la lecture des deux octets.
        if (op == 0xCB) {
            const cb = self.fetch(bus);
            return switch (cb) {
                inline else => |cb_op| self.executeCb(bus, cb_op),
            };
        }

        return error.UnimplementedOpcode;
    }

    /// Opcodes préfixés CB, décodés avec les mêmes champs x, y, z :
    ///   x = 0 : rotation / décalage y sur r[z]
    ///   x = 1 : BIT y,r[z]
    ///   x = 2 : RES y,r[z]
    ///   x = 3 : SET y,r[z]
    /// Les 256 combinaisons sont valides.
    fn executeCb(self: *Cpu, bus: anytype, comptime op: u8) u8 {
        const x: u2 = @truncate(op >> 6);
        const y: u3 = @truncate(op >> 3);
        const z: u3 = @truncate(op);
        const mask: u8 = @as(u8, 1) << y;
        const v = self.readR(bus, z);

        switch (x) {
            0 => self.writeR(bus, z, self.rot(y, v)),
            // BIT : Z = bit testé inversé, C inchangé, pas d'écriture
            1 => {
                self.f.z = v & mask == 0;
                self.f.n = false;
                self.f.h = true;
                return if (z == 6) 3 else 2;
            },
            2 => self.writeR(bus, z, v & ~mask),
            3 => self.writeR(bus, z, v | mask),
        }
        // (HL) : lecture + écriture mémoire en plus
        return if (z == 6) 4 else 2;
    }

    /// Rotations et décalages, dans l'ordre de y :
    /// RLC, RRC, RL, RR, SLA, SRA, SWAP, SRL.
    /// Le bit sorti va dans C ; Z selon le résultat ; N = H = 0.
    fn rot(self: *Cpu, comptime op: u3, v: u8) u8 {
        const old_c: u8 = @intFromBool(self.f.c);
        const r: u8, const c: bool = switch (op) {
            0 => .{ v << 1 | v >> 7, v & 0x80 != 0 }, // RLC : bit 7 → bit 0 et C
            1 => .{ v >> 1 | v << 7, v & 0x01 != 0 }, // RRC : bit 0 → bit 7 et C
            2 => .{ v << 1 | old_c, v & 0x80 != 0 }, // RL : à travers C
            3 => .{ v >> 1 | old_c << 7, v & 0x01 != 0 }, // RR : à travers C
            4 => .{ v << 1, v & 0x80 != 0 }, // SLA : 0 entre à droite
            5 => .{ v >> 1 | (v & 0x80), v & 0x01 != 0 }, // SRA : le bit 7 (signe) reste
            6 => .{ v << 4 | v >> 4, false }, // SWAP : échange les quartets
            7 => .{ v >> 1, v & 0x01 != 0 }, // SRL : 0 entre à gauche
        };
        self.f = .{ .z = r == 0, .c = c };
        return r;
    }

    /// Condition des sauts : NZ, Z, NC, C.
    fn cond(self: *const Cpu, comptime cc: u2) bool {
        return switch (cc) {
            0 => !self.f.z,
            1 => self.f.z,
            2 => !self.f.c,
            3 => self.f.c,
        };
    }

    /// PC += e, avec e signé (-128..127).
    fn jr(self: *Cpu, e: u8) void {
        const offset: i16 = @as(i8, @bitCast(e));
        self.pc +%= @as(u16, @bitCast(offset));
    }

    /// SP + e (e signé) pour ADD SP,e et LD HL,SP+e.
    /// Z = N = 0 ; H et C viennent de l'addition non signée de l'octet bas
    /// de SP avec e, comme si e était un u8.
    fn spPlusE(self: *Cpu, e: u8) u16 {
        const sp = self.sp;
        const lo: u8 = @truncate(sp);
        self.f = .{
            .h = (lo & 0x0F) + (e & 0x0F) > 0x0F,
            .c = @as(u16, lo) + e > 0xFF,
        };
        const offset: i16 = @as(i8, @bitCast(e));
        return sp +% @as(u16, @bitCast(offset));
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

    fn readRp(self: *const Cpu, comptime i: u2) u16 {
        return switch (i) {
            0 => self.bc(),
            1 => self.de(),
            2 => self.hl(),
            3 => self.sp,
        };
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

    fn readR(self: *Cpu, bus: anytype, comptime i: u3) u8 {
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

    fn writeR(self: *Cpu, bus: anytype, comptime i: u3, value: u8) void {
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
const Bus = @import("bus.zig").Bus;

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

test "HALT (0x76, pas un LD) : le CPU s'arrête, PC ne bouge plus" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x76, 0x04 });
    cpu.b = 0x00;

    try expectEqual(@as(u8, 1), try cpu.step(&bus));
    try expectEqual(true, cpu.halted);
    try expectEqual(@as(u16, 0xC001), cpu.pc);
    try expectEqual(@as(u8, 1), try cpu.step(&bus)); // rien n'est exécuté
    try expectEqual(@as(u16, 0xC001), cpu.pc);
    try expectEqual(@as(u8, 0x00), cpu.b);
}

test "LD (BC),A / LD A,(DE) : 2 M-cycles" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x02, 0x1A });
    cpu.setBc(0xC100);
    cpu.setDe(0xC200);
    cpu.a = 0x5A;
    bus.write(0xC200, 0x77);

    try expectEqual(@as(u8, 2), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x5A), bus.read(0xC100));
    try expectEqual(@as(u8, 2), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x77), cpu.a);
}

test "LD (HL+),A / LD A,(HL-) : HL bouge après l'accès" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x22, 0x3A });
    cpu.setHl(0xC1FF);
    cpu.a = 0x11;

    try expectEqual(@as(u8, 2), try cpu.step(&bus)); // LD (HL+),A
    try expectEqual(@as(u8, 0x11), bus.read(0xC1FF));
    try expectEqual(@as(u16, 0xC200), cpu.hl());

    bus.write(0xC200, 0x22);
    try expectEqual(@as(u8, 2), try cpu.step(&bus)); // LD A,(HL-)
    try expectEqual(@as(u8, 0x22), cpu.a);
    try expectEqual(@as(u16, 0xC1FF), cpu.hl());
}

test "LDH, LD (C) et LD (nn) : adresses 0xFF00 + n, 0xFF00 + C et nn" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{
        0xE0, 0x80, // LDH (0x80),A    3 M-cycles
        0xF2, // LD A,(C)        2 M-cycles
        0xEA, 0x00, 0xC1, // LD (0xC100),A   4 M-cycles
        0xF0, 0x81, // LDH A,(0x81)
        0xFA, 0x00, 0xC1, // LD A,(0xC100)
    });
    cpu.a = 0x42;
    cpu.c = 0x81;
    bus.write(0xFF81, 0x99);

    try expectEqual(@as(u8, 3), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x42), bus.read(0xFF80));
    try expectEqual(@as(u8, 2), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x99), cpu.a);
    try expectEqual(@as(u8, 4), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x99), bus.read(0xC100));
    cpu.a = 0;
    try expectEqual(@as(u8, 3), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x99), cpu.a);
    cpu.a = 0;
    try expectEqual(@as(u8, 4), try cpu.step(&bus));
    try expectEqual(@as(u8, 0x99), cpu.a);
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

test "ADD HL,rr : 2 M-cycles, Z inchangé, H au bit 11, C au bit 15" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x09, 0x19, 0x29, 0x39 });
    cpu.f = .{ .z = true, .n = true };

    cpu.setHl(0x0FFF);
    cpu.setBc(0x0001);
    try expectEqual(@as(u8, 2), try cpu.step(&bus)); // ADD HL,BC
    try expectEqual(@as(u16, 0x1000), cpu.hl());
    try expectEqual(@as(u8, 0xA0), @as(u8, @bitCast(cpu.f))); // Z (inchangé) H

    cpu.setHl(0x8000);
    cpu.setDe(0x8000);
    _ = try cpu.step(&bus); // ADD HL,DE
    try expectEqual(@as(u16, 0x0000), cpu.hl());
    try expectEqual(@as(u8, 0x90), @as(u8, @bitCast(cpu.f))); // Z (inchangé) C, pas de Z recalculé

    cpu.f = .{};
    cpu.setHl(0x1234);
    _ = try cpu.step(&bus); // ADD HL,HL
    try expectEqual(@as(u16, 0x2468), cpu.hl());
    try expectEqual(@as(u8, 0x00), @as(u8, @bitCast(cpu.f)));

    cpu.sp = 0xF000;
    _ = try cpu.step(&bus); // ADD HL,SP
    try expectEqual(@as(u16, 0x1468), cpu.hl());
    try expectEqual(@as(u8, 0x10), @as(u8, @bitCast(cpu.f))); // C
}

test "INC rr / DEC rr : 2 M-cycles, débordement, flags intacts" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x03, 0x1B, 0x23, 0x3B });
    cpu.f = .{ .z = true, .c = true };
    const f = cpu.f;

    cpu.setBc(0xFFFF);
    try expectEqual(@as(u8, 2), try cpu.step(&bus)); // INC BC
    try expectEqual(@as(u16, 0x0000), cpu.bc());
    cpu.setDe(0x0000);
    try expectEqual(@as(u8, 2), try cpu.step(&bus)); // DEC DE
    try expectEqual(@as(u16, 0xFFFF), cpu.de());
    cpu.setHl(0x00FF);
    _ = try cpu.step(&bus); // INC HL
    try expectEqual(@as(u16, 0x0100), cpu.hl());
    cpu.sp = 0xD000;
    _ = try cpu.step(&bus); // DEC SP
    try expectEqual(@as(u16, 0xCFFF), cpu.sp);
    try expectEqual(f, cpu.f);
}

test "ADD SP,e : 4 M-cycles, e signé, H et C sur l'octet bas" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xE8, 0x01, 0xE8, 0xFF, 0xE8, 0x80 });
    cpu.f = .{ .z = true, .n = true };

    cpu.sp = 0xD00F;
    try expectEqual(@as(u8, 4), try cpu.step(&bus)); // +1
    try expectEqual(@as(u16, 0xD010), cpu.sp);
    try expectEqual(@as(u8, 0x20), @as(u8, @bitCast(cpu.f))); // H, Z et N à 0

    // -1 : 0x10 + 0xFF en non signé → C, pas de H
    _ = try cpu.step(&bus);
    try expectEqual(@as(u16, 0xD00F), cpu.sp);
    try expectEqual(@as(u8, 0x10), @as(u8, @bitCast(cpu.f)));

    // -128 : 0x0F + 0x80 → ni H ni C
    _ = try cpu.step(&bus);
    try expectEqual(@as(u16, 0xCF8F), cpu.sp);
    try expectEqual(@as(u8, 0x00), @as(u8, @bitCast(cpu.f)));
}

test "LD HL,SP+e : 3 M-cycles, SP inchangé" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xF8, 0xFE });
    cpu.sp = 0xFFFF;
    cpu.f = .{ .z = true };

    try expectEqual(@as(u8, 3), try cpu.step(&bus)); // SP - 2
    try expectEqual(@as(u16, 0xFFFD), cpu.hl());
    try expectEqual(@as(u16, 0xFFFF), cpu.sp);
    try expectEqual(@as(u8, 0x30), @as(u8, @bitCast(cpu.f))); // 0xFF + 0xFE : H C
}

test "JP nn : 4 M-cycles ; JP HL : 1 M-cycle" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xC3, 0x00, 0xC1 });
    bus.write(0xC100, 0xE9); // JP HL
    cpu.setHl(0xC200);

    try expectEqual(@as(u8, 4), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xC100), cpu.pc);
    try expectEqual(@as(u8, 1), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xC200), cpu.pc);
}

test "JP cc,nn : 4 M-cycles si pris, 3 sinon" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{
        0xC2, 0x00, 0xD0, // JP NZ (non pris : Z = 1)
        0xCA, 0x00, 0xC1, // JP Z  (pris)
    });
    cpu.f = .{ .z = true };

    try expectEqual(@as(u8, 3), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xC003), cpu.pc);
    try expectEqual(@as(u8, 4), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xC100), cpu.pc);
}

test "JR e : déplacement signé depuis la fin de l'instruction" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x18, 0x02, 0x00, 0x00, 0x18, 0xFA });

    try expectEqual(@as(u8, 3), try cpu.step(&bus)); // +2 depuis 0xC002
    try expectEqual(@as(u16, 0xC004), cpu.pc);
    _ = try cpu.step(&bus); // -6 depuis 0xC006
    try expectEqual(@as(u16, 0xC000), cpu.pc);
}

test "JR cc,e : 3 M-cycles si pris, 2 sinon" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x38, 0x10, 0x30, 0x10 });
    cpu.f = .{ .c = true };

    try expectEqual(@as(u8, 3), try cpu.step(&bus)); // JR C : pris
    try expectEqual(@as(u16, 0xC012), cpu.pc);
    cpu.pc = 0xC002;
    try expectEqual(@as(u8, 2), try cpu.step(&bus)); // JR NC : non pris
    try expectEqual(@as(u16, 0xC004), cpu.pc);
}

test "CALL nn puis RET : 6 et 4 M-cycles" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xCD, 0x00, 0xC1 });
    bus.write(0xC100, 0xC9); // RET
    cpu.sp = 0xD000;

    try expectEqual(@as(u8, 6), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xC100), cpu.pc);
    try expectEqual(@as(u16, 0xCFFE), cpu.sp);
    // Adresse de retour 0xC003 : octet haut à SP+1.
    try expectEqual(@as(u8, 0xC0), bus.read(0xCFFF));
    try expectEqual(@as(u8, 0x03), bus.read(0xCFFE));

    try expectEqual(@as(u8, 4), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xC003), cpu.pc);
    try expectEqual(@as(u16, 0xD000), cpu.sp);
}

test "CALL cc,nn : 6 M-cycles si pris, 3 sinon et rien empilé" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{
        0xC4, 0x00, 0xC1, // CALL NZ (non pris)
        0xCC, 0x00, 0xC1, // CALL Z  (pris)
    });
    cpu.sp = 0xD000;
    cpu.f = .{ .z = true };

    try expectEqual(@as(u8, 3), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xC003), cpu.pc);
    try expectEqual(@as(u16, 0xD000), cpu.sp);
    try expectEqual(@as(u8, 6), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xC100), cpu.pc);
    try expectEqual(@as(u16, 0xCFFE), cpu.sp);
}

test "RET cc : 5 M-cycles si pris, 2 sinon" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{0xD0}); // RET NC
    bus.write(0xC100, 0xD8); // RET C
    cpu.sp = 0xCFFE;
    bus.write(0xCFFE, 0x00);
    bus.write(0xCFFF, 0xC1);
    cpu.f = .{ .c = true };

    try expectEqual(@as(u8, 2), try cpu.step(&bus)); // RET NC : non pris
    try expectEqual(@as(u16, 0xC001), cpu.pc);
    try expectEqual(@as(u16, 0xCFFE), cpu.sp);

    cpu.pc = 0xC100;
    try expectEqual(@as(u8, 5), try cpu.step(&bus)); // RET C : pris
    try expectEqual(@as(u16, 0xC100), cpu.pc);
    try expectEqual(@as(u16, 0xD000), cpu.sp);
}

test "RETI : comme RET, et IME passe à 1" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{0xD9});
    cpu.sp = 0xCFFE;
    bus.write(0xCFFE, 0x00);
    bus.write(0xCFFF, 0xC1);

    try expectEqual(@as(u8, 4), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xC100), cpu.pc);
    try expectEqual(@as(u16, 0xD000), cpu.sp);
    try expectEqual(true, cpu.ime);
}

test "RST : 4 M-cycles, saut à y * 8, adresse de retour empilée" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xFF, 0xC7 });
    cpu.sp = 0xD000;

    try expectEqual(@as(u8, 4), try cpu.step(&bus)); // RST 38h
    try expectEqual(@as(u16, 0x0038), cpu.pc);
    try expectEqual(@as(u8, 0xC0), bus.read(0xCFFF));
    try expectEqual(@as(u8, 0x01), bus.read(0xCFFE));

    cpu.pc = 0xC001;
    _ = try cpu.step(&bus); // RST 00h
    try expectEqual(@as(u16, 0x0000), cpu.pc);
}

test "RLCA / RRCA : 1 M-cycle, Z toujours 0" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x07, 0x0F, 0x07 });
    cpu.f = .{ .z = true, .n = true, .h = true };

    cpu.a = 0x85;
    try expectAlu(&cpu, &bus, 1, 0x0B, 0x10); // bit 7 → bit 0 et C
    try expectAlu(&cpu, &bus, 1, 0x85, 0x10); // bit 0 → bit 7 et C
    cpu.a = 0x00;
    try expectAlu(&cpu, &bus, 1, 0x00, 0x00); // résultat nul, mais Z = 0
}

test "RLA / RRA : rotation à travers C" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x17, 0x17, 0x1F, 0x1F });
    cpu.f = .{};

    cpu.a = 0x80;
    try expectAlu(&cpu, &bus, 1, 0x00, 0x10); // le bit 7 part dans C
    try expectAlu(&cpu, &bus, 1, 0x01, 0x00); // l'ancien C entre au bit 0
    try expectAlu(&cpu, &bus, 1, 0x00, 0x10); // le bit 0 part dans C
    try expectAlu(&cpu, &bus, 1, 0x80, 0x00); // l'ancien C entre au bit 7
}

test "CB RLC / RRC / RL / RR : 2 M-cycles, Z calculé" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xCB, 0x00, 0xCB, 0x09, 0xCB, 0x12, 0xCB, 0x1F });
    cpu.f = .{};

    cpu.b = 0x80;
    try expectEqual(@as(u8, 2), try cpu.step(&bus)); // RLC B
    try expectEqual(@as(u8, 0x01), cpu.b);
    try expectEqual(@as(u8, 0x10), @as(u8, @bitCast(cpu.f))); // C

    cpu.c = 0x00;
    _ = try cpu.step(&bus); // RRC C
    try expectEqual(@as(u8, 0x00), cpu.c);
    try expectEqual(@as(u8, 0x80), @as(u8, @bitCast(cpu.f))); // Z (contrairement à RRCA)

    cpu.d = 0x80;
    _ = try cpu.step(&bus); // RL D, C = 0
    try expectEqual(@as(u8, 0x00), cpu.d);
    try expectEqual(@as(u8, 0x90), @as(u8, @bitCast(cpu.f))); // Z C

    cpu.a = 0x02;
    try expectAlu(&cpu, &bus, 2, 0x81, 0x00); // RR A : l'ancien C entre au bit 7
}

test "CB SLA / SRA / SWAP / SRL" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xCB, 0x27, 0xCB, 0x2F, 0xCB, 0x37, 0xCB, 0x3F, 0xCB, 0x37 });
    cpu.f = .{ .c = true };

    cpu.a = 0xC1;
    try expectAlu(&cpu, &bus, 2, 0x82, 0x10); // SLA : 0 entre, bit 7 → C
    try expectAlu(&cpu, &bus, 2, 0xC1, 0x00); // SRA : bit 7 recopié
    try expectAlu(&cpu, &bus, 2, 0x1C, 0x00); // SWAP
    cpu.f = .{ .c = true };
    try expectAlu(&cpu, &bus, 2, 0x0E, 0x00); // SRL : 0 entre au bit 7, C = 0
    cpu.a = 0x00;
    try expectAlu(&cpu, &bus, 2, 0x00, 0x80); // SWAP de 0 : Z, C effacé
}

test "CB rotation sur (HL) : 4 M-cycles" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xCB, 0x06, 0xCB, 0x3E });
    cpu.setHl(0xC100);
    bus.write(0xC100, 0x81);

    try expectEqual(@as(u8, 4), try cpu.step(&bus)); // RLC (HL)
    try expectEqual(@as(u8, 0x03), bus.read(0xC100));
    try expectEqual(@as(u8, 4), try cpu.step(&bus)); // SRL (HL)
    try expectEqual(@as(u8, 0x01), bus.read(0xC100));
    try expectEqual(true, cpu.f.c);
}

test "CB BIT : 2 M-cycles (3 sur (HL)), C inchangé, rien écrit" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xCB, 0x7F, 0xCB, 0x47, 0xCB, 0x46 });
    cpu.f = .{ .c = true, .n = true };
    cpu.a = 0x80;
    cpu.setHl(0xC100);
    bus.write(0xC100, 0xFE);

    try expectAlu(&cpu, &bus, 2, 0x80, 0x30); // BIT 7,A : bit à 1 → Z = 0, H C
    try expectAlu(&cpu, &bus, 2, 0x80, 0xB0); // BIT 0,A : bit à 0 → Z H C
    try expectEqual(@as(u8, 3), try cpu.step(&bus)); // BIT 0,(HL)
    try expectEqual(true, cpu.f.z);
    try expectEqual(@as(u8, 0xFE), bus.read(0xC100));
}

test "CB RES / SET : 2 M-cycles (4 sur (HL)), flags intacts" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xCB, 0x87, 0xCB, 0xF8, 0xCB, 0xBE, 0xCB, 0xC6 });
    cpu.f = .{ .z = true, .c = true };
    const f = cpu.f;
    cpu.a = 0xFF;
    cpu.b = 0x00;
    cpu.setHl(0xC100);
    bus.write(0xC100, 0xF0);

    try expectEqual(@as(u8, 2), try cpu.step(&bus)); // RES 0,A
    try expectEqual(@as(u8, 0xFE), cpu.a);
    try expectEqual(@as(u8, 2), try cpu.step(&bus)); // SET 7,B
    try expectEqual(@as(u8, 0x80), cpu.b);
    try expectEqual(@as(u8, 4), try cpu.step(&bus)); // RES 7,(HL)
    try expectEqual(@as(u8, 0x70), bus.read(0xC100));
    try expectEqual(@as(u8, 4), try cpu.step(&bus)); // SET 0,(HL)
    try expectEqual(@as(u8, 0x71), bus.read(0xC100));
    try expectEqual(f, cpu.f);
}

test "DAA après une addition BCD" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x80, 0x27, 0x80, 0x27, 0x80, 0x27 });
    cpu.f = .{};

    // 15 + 27 = 42 : 0x3C → 0x42 (quartet bas > 9)
    cpu.a = 0x15;
    cpu.b = 0x27;
    _ = try cpu.step(&bus);
    try expectAlu(&cpu, &bus, 1, 0x42, 0x00);

    // 09 + 09 = 18 : 0x12 avec H → 0x18
    cpu.a = 0x09;
    cpu.b = 0x09;
    _ = try cpu.step(&bus);
    try expectAlu(&cpu, &bus, 1, 0x18, 0x00);

    // 99 + 01 = 100 : 0x9A → 0x00, Z C
    cpu.a = 0x99;
    cpu.b = 0x01;
    _ = try cpu.step(&bus);
    try expectAlu(&cpu, &bus, 1, 0x00, 0x90);
}

test "DAA après une soustraction BCD : N conservé" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x90, 0x27, 0x90, 0x27 });
    cpu.f = .{};

    // 42 - 15 = 27 : 0x2D avec H → 0x27
    cpu.a = 0x42;
    cpu.b = 0x15;
    _ = try cpu.step(&bus);
    try expectAlu(&cpu, &bus, 1, 0x27, 0x40); // N

    // 10 - 20 = -10 → 90 avec emprunt : 0xF0 avec C → 0x90
    cpu.a = 0x10;
    cpu.b = 0x20;
    _ = try cpu.step(&bus);
    try expectAlu(&cpu, &bus, 1, 0x90, 0x50); // N C
}

test "CPL, SCF, CCF : 1 M-cycle, Z inchangé" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x2F, 0x37, 0x3F, 0x3F });
    cpu.f = .{ .z = true };
    cpu.a = 0x35;

    try expectAlu(&cpu, &bus, 1, 0xCA, 0xE0); // CPL : Z N H
    try expectAlu(&cpu, &bus, 1, 0xCA, 0x90); // SCF : Z C
    try expectAlu(&cpu, &bus, 1, 0xCA, 0x80); // CCF : C → 0
    try expectAlu(&cpu, &bus, 1, 0xCA, 0x90); // CCF : C → 1
}

test "EI : IME à 1 seulement après l'instruction suivante ; DI immédiat" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0xFB, 0x00, 0x00, 0xF3, 0xFB, 0xF3, 0x00 });

    try expectEqual(@as(u8, 1), try cpu.step(&bus)); // EI
    try expectEqual(false, cpu.ime);
    _ = try cpu.step(&bus); // NOP : s'exécute encore avec IME = 0
    try expectEqual(true, cpu.ime);
    _ = try cpu.step(&bus); // NOP
    try expectEqual(@as(u8, 1), try cpu.step(&bus)); // DI
    try expectEqual(false, cpu.ime);

    _ = try cpu.step(&bus); // EI
    _ = try cpu.step(&bus); // DI juste après : IME reste à 0
    _ = try cpu.step(&bus); // NOP
    try expectEqual(false, cpu.ime);
}

test "STOP : 2 octets, le CPU s'arrête" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x10, 0x00, 0x04 });

    try expectEqual(@as(u8, 1), try cpu.step(&bus));
    try expectEqual(true, cpu.stopped);
    try expectEqual(@as(u16, 0xC002), cpu.pc);
    _ = try cpu.step(&bus);
    try expectEqual(@as(u16, 0xC002), cpu.pc);
}

test "interruption : IME = 0, bit effacé de IF, PC empilé, saut au vecteur" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{0x00});
    cpu.ime = true;
    cpu.sp = 0xDFFE;
    bus.ie = 0x1F;
    bus.requestInterrupt(.timer);
    bus.requestInterrupt(.joypad);

    try expectEqual(@as(u8, 5), try cpu.step(&bus));
    try expectEqual(false, cpu.ime);
    try expectEqual(@as(u16, 0x0050), cpu.pc); // 0x40 + 8 × 2
    try expectEqual(@as(u16, 0xDFFC), cpu.sp);
    try expectEqual(@as(u8, 0xC0), bus.read(0xDFFD)); // octet haut de 0xC000
    try expectEqual(@as(u8, 0x00), bus.read(0xDFFC)); // octet bas
    try expectEqual(@as(u8, 0x10), bus.if_); // seul le joypad reste demandé
}

test "interruption : priorité au bit le plus bas, IE filtre" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{0x00});
    cpu.sp = 0xDFFE;
    bus.if_ = 0x1F;

    // Tout est demandé : VBlank (bit 0) passe en premier.
    cpu.ime = true;
    bus.ie = 0x1F;
    _ = try cpu.step(&bus);
    try expectEqual(@as(u16, 0x0040), cpu.pc);
    try expectEqual(@as(u8, 0x1E), bus.if_);

    // VBlank et STAT masqués par IE : c'est le timer.
    cpu.ime = true;
    bus.if_ = 0x1F;
    bus.ie = 0x1C;
    _ = try cpu.step(&bus);
    try expectEqual(@as(u16, 0x0050), cpu.pc);
    try expectEqual(@as(u8, 0x1B), bus.if_);

    // Restent série et joypad : la série (0x58) avant le joypad (0x60).
    cpu.ime = true;
    bus.if_ = 0x18;
    _ = try cpu.step(&bus);
    try expectEqual(@as(u16, 0x0058), cpu.pc);
    cpu.ime = true;
    _ = try cpu.step(&bus);
    try expectEqual(@as(u16, 0x0060), cpu.pc);
    try expectEqual(@as(u8, 0x00), bus.if_);
}

test "interruption : rien si IME = 0 ou si IE & IF = 0" {
    var buf: [32 * 1024]u8 = undefined;
    var cpu, var bus = try setup(&buf, &.{ 0x00, 0x00 });
    bus.ie = 0x01;
    bus.if_ = 0x01;

    try expectEqual(@as(u8, 1), try cpu.step(&bus)); // IME = 0 : NOP normal
    try expectEqual(@as(u16, 0xC001), cpu.pc);
    try expectEqual(@as(u8, 0x01), bus.if_);

    cpu.ime = true;
    bus.ie = 0x02; // seul STAT autorisé, mais seul VBlank demandé
    try expectEqual(@as(u8, 1), try cpu.step(&bus));
    try expectEqual(@as(u16, 0xC002), cpu.pc);
}

test "interruption : l'instruction qui suit EI s'exécute d'abord" {
    var buf: [32 * 1024]u8 = undefined;
    // EI ; INC A ; INC A
    var cpu, var bus = try setup(&buf, &.{ 0xFB, 0x3C, 0x3C });
    cpu.a = 0;
    cpu.sp = 0xDFFE;
    bus.ie = 0x01;
    bus.if_ = 0x01;

    _ = try cpu.step(&bus); // EI
    try expectEqual(@as(u8, 1), try cpu.step(&bus)); // INC A, pas l'interruption
    try expectEqual(@as(u8, 1), cpu.a);
    try expectEqual(@as(u8, 5), try cpu.step(&bus)); // maintenant seulement
    try expectEqual(@as(u16, 0x0040), cpu.pc);
    try expectEqual(@as(u8, 1), cpu.a); // le 2e INC A n'a pas été exécuté
    try expectEqual(@as(u8, 0x02), bus.read(0xDFFC)); // retour vers 0xC002
    try expectEqual(@as(u8, 0xC0), bus.read(0xDFFD));
}
