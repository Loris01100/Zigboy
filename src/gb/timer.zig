//! Timer : DIV, TIMA, TMA, TAC (0xFF04..0xFF07).
//!
//! Tout part d'un compteur interne 16 bits qui avance de 4 à chaque
//! M-cycle (donc de 1 par cycle d'horloge). DIV en est l'octet haut.
//!
//! TIMA n'a pas de compteur à lui : il s'incrémente sur le front
//! descendant du signal
//!
//!     (bit du compteur choisi par TAC) AND (TAC bit 2, timer actif)
//!
//! c'est-à-dire quand ce signal passe de 1 à 0. Le bit surveillé :
//!
//!     TAC & 3 :  00     01      10     11
//!     bit     :  9      3       5      7
//!     TIMA    :  4096   262144  65536  16384 Hz
//!
//! Avec ce modèle, les cas limites se règlent d'eux-mêmes : remettre DIV
//! à 0 alors que le bit surveillé vaut 1, ou couper le timer via TAC
//! pendant que ce bit vaut 1, fait tomber le signal et donne un tick.

const std = @import("std");

pub const Timer = struct {
    /// Compteur interne. DIV = octet haut.
    counter: u16 = 0,
    /// TIMA (0xFF05) : le compteur visible, incrémenté au rythme de TAC.
    tima: u8 = 0,
    /// TMA (0xFF06) : valeur rechargée dans TIMA à chaque débordement.
    tma: u8 = 0,
    /// TAC (0xFF07) : bit 2 = actif, bits 1-0 = fréquence. 3 bits utiles.
    tac: u3 = 0,

    /// Fait avancer le timer de `m_cycles` M-cycles.
    /// Renvoie `true` si TIMA a débordé : il faut demander l'interruption Timer.
    pub fn tick(self: *Timer, m_cycles: u8) bool {
        var overflow = false;
        for (0..m_cycles) |_| {
            const before = self.signal();
            self.counter +%= 4;
            if (before and !self.signal()) overflow = self.incrementTima() or overflow;
        }
        return overflow;
    }

    pub fn read(self: *const Timer, addr: u16) u8 {
        return switch (addr) {
            0xFF04 => @truncate(self.counter >> 8),
            0xFF05 => self.tima,
            0xFF06 => self.tma,
            // Les bits 3 à 7 de TAC n'existent pas et se lisent à 1.
            0xFF07 => @as(u8, self.tac) | 0xF8,
            else => unreachable,
        };
    }

    /// Écrit un registre. Renvoie `true` si l'écriture a fait déborder TIMA
    /// (front descendant provoqué par une écriture dans DIV ou TAC).
    pub fn write(self: *Timer, addr: u16, value: u8) bool {
        const before = self.signal();
        switch (addr) {
            // Quelle que soit la valeur écrite, tout le compteur repart de 0.
            0xFF04 => self.counter = 0,
            0xFF05 => self.tima = value,
            0xFF06 => self.tma = value,
            0xFF07 => self.tac = @truncate(value),
            else => unreachable,
        }
        if (before and !self.signal()) return self.incrementTima();
        return false;
    }

    /// Le signal dont le front descendant fait avancer TIMA.
    fn signal(self: *const Timer) bool {
        if (self.tac & 0b100 == 0) return false;
        const bit: u4 = switch (@as(u2, @truncate(self.tac))) {
            0b00 => 9,
            0b01 => 3,
            0b10 => 5,
            0b11 => 7,
        };
        return (self.counter >> bit) & 1 != 0;
    }

    /// Renvoie `true` en cas de débordement (TIMA rechargé avec TMA).
    fn incrementTima(self: *Timer) bool {
        const result = @addWithOverflow(self.tima, 1);
        if (result[1] == 1) {
            self.tima = self.tma;
            return true;
        }
        self.tima = result[0];
        return false;
    }
};

// --- Tests -----------------------------------------------------------------

const expectEqual = std.testing.expectEqual;

test "DIV vaut 1 après 64 M-cycles, 4 après 256" {
    var t: Timer = .{};
    _ = t.tick(63);
    try expectEqual(@as(u8, 0), t.read(0xFF04));
    _ = t.tick(1);
    try expectEqual(@as(u8, 1), t.read(0xFF04));
    _ = t.tick(192);
    try expectEqual(@as(u8, 4), t.read(0xFF04));
}

test "DIV : toute écriture remet le compteur entier à 0" {
    var t: Timer = .{};
    _ = t.tick(100);
    _ = t.write(0xFF04, 0xAB);
    try expectEqual(@as(u16, 0), t.counter);
    try expectEqual(@as(u8, 0), t.read(0xFF04));
}

test "TIMA ne bouge pas quand TAC bit 2 vaut 0" {
    var t: Timer = .{};
    _ = t.write(0xFF07, 0b001);
    _ = t.tick(255);
    _ = t.tick(255);
    try expectEqual(@as(u8, 0), t.tima);
}

test "TIMA : TAC=01 (bit 3) -> +1 tous les 4 M-cycles" {
    var t: Timer = .{};
    _ = t.write(0xFF07, 0b101);
    _ = t.tick(3);
    try expectEqual(@as(u8, 0), t.tima);
    _ = t.tick(1);
    try expectEqual(@as(u8, 1), t.tima);
    _ = t.tick(40);
    try expectEqual(@as(u8, 11), t.tima);
}

test "TIMA : TAC=00 (bit 9) -> +1 tous les 256 M-cycles" {
    var t: Timer = .{};
    _ = t.write(0xFF07, 0b100);
    _ = t.tick(255);
    try expectEqual(@as(u8, 0), t.tima);
    _ = t.tick(1);
    try expectEqual(@as(u8, 1), t.tima);
}

test "débordement de TIMA : rechargé avec TMA, interruption demandée" {
    var t: Timer = .{};
    _ = t.write(0xFF06, 0x42);
    _ = t.write(0xFF05, 0xFF);
    _ = t.write(0xFF07, 0b101);
    try expectEqual(false, t.tick(3));
    try expectEqual(true, t.tick(1));
    try expectEqual(@as(u8, 0x42), t.tima);
    try expectEqual(false, t.tick(4));
    try expectEqual(@as(u8, 0x43), t.tima);
}

test "reset de DIV quand le bit surveillé vaut 1 : TIMA prend un tick" {
    var t: Timer = .{};
    _ = t.write(0xFF07, 0b101); // bit 3
    _ = t.tick(2); // compteur = 8 : bit 3 à 1
    try expectEqual(@as(u8, 0), t.tima);
    try expectEqual(false, t.write(0xFF04, 0));
    try expectEqual(@as(u8, 1), t.tima);

    // Bit surveillé à 0 : le reset ne donne rien.
    _ = t.tick(1); // compteur = 4 : bit 3 à 0
    _ = t.write(0xFF04, 0);
    try expectEqual(@as(u8, 1), t.tima);

    // Et le tick provoqué par un reset peut faire déborder.
    t.tima = 0xFF;
    _ = t.tick(2);
    try expectEqual(true, t.write(0xFF04, 0));
    try expectEqual(@as(u8, 0), t.tima); // TMA = 0
}

test "couper le timer via TAC quand le bit surveillé vaut 1 : un tick" {
    var t: Timer = .{};
    _ = t.write(0xFF07, 0b101);
    _ = t.tick(2); // bit 3 à 1
    _ = t.write(0xFF07, 0b001);
    try expectEqual(@as(u8, 1), t.tima);
}

test "TAC : les bits 3-7 se lisent à 1" {
    var t: Timer = .{};
    try expectEqual(@as(u8, 0xF8), t.read(0xFF07));
    _ = t.write(0xFF07, 0xFF);
    try expectEqual(@as(u8, 0xFF), t.read(0xFF07));
}
