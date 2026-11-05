//! PPU (Picture Processing Unit) : la machine à états qui rythme l'écran.
//!
//! Une frame = 154 lignes de 456 dots (1 dot = 1 cycle d'horloge,
//! 4 dots par M-cycle), soit 70 224 dots.
//!
//!   lignes 0..143   (visibles) :
//!       dots   0..79   mode 2  OAM scan (recherche des sprites de la ligne)
//!       dots  80..251  mode 3  dessin (durée fixe de 172 dots pour l'instant)
//!       dots 252..455  mode 0  HBlank
//!   lignes 144..153 :          mode 1  VBlank, toute la ligne
//!
//! L'interruption VBlank part à l'entrée de la ligne 144.

const std = @import("std");

pub const Mode = enum(u2) {
    hblank = 0,
    vblank = 1,
    oam_scan = 2,
    drawing = 3,
};

/// Interruptions demandées par un `tick`. Le bus les reporte dans IF.
pub const Interrupts = struct {
    vblank: bool = false,
};

pub const dots_per_line = 456;
pub const lines_per_frame = 154;
pub const dots_per_frame = dots_per_line * lines_per_frame;
/// Première ligne de VBlank (= nombre de lignes visibles).
pub const vblank_line = 144;

const oam_scan_end = 80;
const drawing_end = oam_scan_end + 172;

pub const Ppu = struct {
    /// Position dans la ligne courante, de 0 à 455.
    dot: u16 = 0,
    /// LY (0xFF44) : ligne courante, de 0 à 153. Lecture seule.
    ly: u8 = 0,
    /// Au démarrage, `vblank` pour que STAT se lise 0x85 comme après le
    /// boot ROM. Incohérent avec LY = 0, mais corrigé au dot 80 de la
    /// première ligne, où le PPU passe en mode 3.
    mode: Mode = .vblank,
    /// Passe à `true` à l'entrée du VBlank : une image complète est prête.
    /// C'est à celui qui l'affiche de la remettre à `false`.
    frame_ready: bool = false,

    /// LCDC (0xFF40) : contrôle de l'écran. 0x91 après le boot ROM :
    /// écran allumé, tiles en 0x8000, fond affiché.
    lcdc: u8 = 0x91,
    /// STAT (0xFF41), bits 2 à 6 seulement : les bits 0-1 (mode) sont
    /// pris dans `mode`, et le bit 7 se lit toujours à 1.
    /// Le bit 2 (LY == LYC) reste figé en attendant LYC.
    stat: u8 = 0x85 & 0x7C,
    /// BGP (0xFF47) : palette du fond. 0xFC = 3, 3, 3, 0 (indices 3 à 0).
    bgp: u8 = 0xFC,

    /// Fait avancer le PPU de `dots` cycles d'horloge.
    /// Renvoie les interruptions à lever.
    pub fn tick(self: *Ppu, dots: u16) Interrupts {
        var irq: Interrupts = .{};
        var remaining = dots;
        // On saute d'une frontière (dot 80, 252 ou 456) à la suivante
        // plutôt que d'avancer dot par dot.
        while (remaining > 0) {
            const boundary: u16 = if (self.dot < oam_scan_end)
                oam_scan_end
            else if (self.dot < drawing_end)
                drawing_end
            else
                dots_per_line;
            const step = @min(remaining, boundary - self.dot);
            self.dot += step;
            remaining -= step;
            if (self.dot == boundary) self.crossBoundary(&irq);
        }
        return irq;
    }

    fn crossBoundary(self: *Ppu, irq: *Interrupts) void {
        const visible = self.ly < vblank_line;
        switch (self.dot) {
            oam_scan_end => if (visible) {
                self.mode = .drawing;
            },
            drawing_end => if (visible) {
                self.mode = .hblank;
            },
            dots_per_line => {
                self.dot = 0;
                self.ly += 1;
                if (self.ly == lines_per_frame) self.ly = 0;
                if (self.ly < vblank_line) {
                    self.mode = .oam_scan;
                } else if (self.ly == vblank_line) {
                    self.mode = .vblank;
                    self.frame_ready = true;
                    irq.vblank = true;
                }
            },
            else => unreachable,
        }
    }

    pub fn read(self: *const Ppu, addr: u16) u8 {
        return switch (addr) {
            0xFF40 => self.lcdc,
            0xFF41 => 0x80 | self.stat | @intFromEnum(self.mode),
            0xFF44 => self.ly,
            0xFF47 => self.bgp,
            else => unreachable,
        };
    }

    pub fn write(self: *Ppu, addr: u16, value: u8) void {
        switch (addr) {
            0xFF40 => self.lcdc = value,
            // Seuls les bits 3 à 6 (sources de l'interruption STAT) s'écrivent.
            0xFF41 => self.stat = (self.stat & 0x04) | (value & 0x78),
            // LY est en lecture seule.
            0xFF44 => {},
            0xFF47 => self.bgp = value,
            else => unreachable,
        }
    }
};

// --- Tests -----------------------------------------------------------------

const expectEqual = std.testing.expectEqual;

test "valeurs après le boot ROM : LCDC = 0x91, STAT = 0x85, BGP = 0xFC" {
    const ppu: Ppu = .{};
    try expectEqual(@as(u8, 0x91), ppu.read(0xFF40));
    try expectEqual(@as(u8, 0x85), ppu.read(0xFF41));
    try expectEqual(@as(u8, 0xFC), ppu.read(0xFF47));
    try expectEqual(@as(u8, 0), ppu.read(0xFF44));
}

test "une ligne : mode 2 pendant 80 dots, 3 pendant 172, puis 0" {
    var ppu: Ppu = .{};
    _ = ppu.tick(79);
    try expectEqual(@as(u16, 79), ppu.dot);
    _ = ppu.tick(1);
    try expectEqual(Mode.drawing, ppu.mode);
    _ = ppu.tick(171);
    try expectEqual(Mode.drawing, ppu.mode);
    _ = ppu.tick(1);
    try expectEqual(Mode.hblank, ppu.mode);
    _ = ppu.tick(203);
    try expectEqual(Mode.hblank, ppu.mode);
    try expectEqual(@as(u8, 0), ppu.ly);
    _ = ppu.tick(1);
    try expectEqual(Mode.oam_scan, ppu.mode);
}

test "LY = 1 après 456 dots" {
    var ppu: Ppu = .{};
    _ = ppu.tick(455);
    try expectEqual(@as(u8, 0), ppu.ly);
    _ = ppu.tick(1);
    try expectEqual(@as(u8, 1), ppu.ly);
    try expectEqual(@as(u16, 0), ppu.dot);
}

test "VBlank levée à 144 × 456 dots" {
    var ppu: Ppu = .{};
    // Par pas de 4 dots, comme le fait le bus.
    for (0..vblank_line * dots_per_line / 4 - 1) |_| {
        try expectEqual(false, ppu.tick(4).vblank);
    }
    try expectEqual(false, ppu.frame_ready);
    try expectEqual(true, ppu.tick(4).vblank);
    try expectEqual(@as(u8, 144), ppu.ly);
    try expectEqual(Mode.vblank, ppu.mode);
    try expectEqual(true, ppu.frame_ready);
}

test "une frame complète fait 70 224 dots, puis LY revient à 0" {
    var ppu: Ppu = .{};
    var vblanks: u32 = 0;
    for (0..dots_per_frame / 4 - 1) |_| {
        if (ppu.tick(4).vblank) vblanks += 1;
    }
    try expectEqual(@as(u8, 153), ppu.ly);
    try expectEqual(Mode.vblank, ppu.mode);
    _ = ppu.tick(4);
    try expectEqual(@as(u8, 0), ppu.ly);
    try expectEqual(@as(u16, 0), ppu.dot);
    try expectEqual(Mode.oam_scan, ppu.mode);
    try expectEqual(@as(u32, 1), vblanks);
}

test "tick en gros morceaux : même résultat qu'en petits pas" {
    var a: Ppu = .{};
    var b: Ppu = .{};
    const dots = 140 * dots_per_line + 100; // ligne 140, en mode 3
    try expectEqual(false, a.tick(dots).vblank);
    for (0..dots) |_| _ = b.tick(1);
    try expectEqual(b.ly, a.ly);
    try expectEqual(b.dot, a.dot);
    try expectEqual(b.mode, a.mode);
}

test "STAT : seuls les bits 3 à 6 s'écrivent, LY est en lecture seule" {
    var ppu: Ppu = .{};
    ppu.write(0xFF41, 0xFF);
    try expectEqual(@as(u8, 0xFD), ppu.read(0xFF41));
    ppu.write(0xFF41, 0x00);
    try expectEqual(@as(u8, 0x85), ppu.read(0xFF41));
    ppu.write(0xFF44, 0x42);
    try expectEqual(@as(u8, 0), ppu.read(0xFF44));
}
