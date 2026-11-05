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
//!
//! L'interruption STAT (« LCD STAT », IF bit 1) a plusieurs sources,
//! activées par les bits 3 à 6 de STAT : mode 0, mode 1, mode 2, LY = LYC.
//! Le matériel en fait un seul fil, le OU des sources activées, et ne lève
//! l'interruption que quand ce fil passe de 0 à 1 (front montant). Tant
//! qu'une source le tient à 1, une autre source qui s'allume ne déclenche
//! rien : c'est le « STAT blocking ».
//!
//! Écran éteint (LCDC bit 7 = 0) : LY = 0, mode 0, le PPU ne bouge plus.
//! Au rallumage, il repart du dot 0 de la ligne 0.
//!
//! Le PPU possède aussi la VRAM (tuiles et tilemaps) et l'OAM (attributs
//! des 40 sprites) : le bus ne fait qu'aiguiller vers elles. Le CPU y a
//! accès à tout moment, même en modes 2 et 3 : le vrai matériel le
//! bloque, mais dmg-acid2 n'en a pas besoin.

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
    /// Front montant du fil d'interruption STAT.
    stat: bool = false,
};

pub const dots_per_line = 456;
pub const lines_per_frame = 154;
pub const dots_per_frame = dots_per_line * lines_per_frame;
/// Première ligne de VBlank (= nombre de lignes visibles).
pub const vblank_line = 144;

const oam_scan_end = 80;
const drawing_end = oam_scan_end + 172;

/// LCDC bit 7 : écran allumé.
const lcdc_enable: u8 = 0x80;
/// STAT bit 2 : LY == LYC (lecture seule, calculé à la lecture).
const stat_coincidence: u8 = 0x04;
/// STAT bits 3 à 6 : sources de l'interruption STAT, écrites par le jeu.
const stat_irq_hblank: u8 = 0x08;
const stat_irq_vblank: u8 = 0x10;
const stat_irq_oam: u8 = 0x20;
const stat_irq_lyc: u8 = 0x40;
const stat_writable: u8 = 0x78;

pub const vram_size = 0x2000;
pub const oam_size = 0xA0;

pub const Ppu = struct {
    /// VRAM (0x8000..0x9FFF), indexée depuis 0.
    vram: [vram_size]u8 = @splat(0),
    /// OAM (0xFE00..0xFE9F), indexée depuis 0 : 40 sprites × 4 octets.
    oam: [oam_size]u8 = @splat(0),

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
    /// STAT (0xFF41), bits 3 à 6 seulement (les sources d'interruption).
    /// À la lecture, les bits 0-1 viennent de `mode`, le bit 2 de
    /// LY == LYC, et le bit 7 vaut toujours 1.
    stat: u8 = 0x85 & stat_writable,
    /// LYC (0xFF45) : ligne à comparer à LY.
    lyc: u8 = 0,
    /// État actuel du fil d'interruption STAT (le OU des sources activées).
    /// On le garde pour détecter le front montant.
    stat_line: bool = false,
    /// BGP (0xFF47) : palette du fond. 0xFC = 3, 3, 3, 0 (indices 3 à 0).
    bgp: u8 = 0xFC,
    /// SCY, SCX (0xFF42, 0xFF43) : défilement du fond.
    scy: u8 = 0,
    scx: u8 = 0,
    /// DMA (0xFF46) : dernière valeur écrite. La copie elle-même est
    /// faite par le bus, le seul à voir toute la mémoire.
    dma: u8 = 0xFF,
    /// OBP0, OBP1 (0xFF48, 0xFF49) : palettes des sprites (la couleur 0
    /// est transparente, ses bits sont ignorés). Le boot ROM ne les
    /// initialise pas : 0xFF, comme la plupart des émulateurs.
    obp0: u8 = 0xFF,
    obp1: u8 = 0xFF,
    /// WY, WX (0xFF4A, 0xFF4B) : position de la fenêtre (X décalé de 7).
    wy: u8 = 0,
    wx: u8 = 0,

    /// Fait avancer le PPU de `dots` cycles d'horloge.
    /// Renvoie les interruptions à lever.
    pub fn tick(self: *Ppu, dots: u16) Interrupts {
        var irq: Interrupts = .{};
        if (!self.enabled()) return irq;
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
            if (self.dot == boundary) {
                self.crossBoundary(&irq);
                self.updateStatLine(&irq);
            }
        }
        return irq;
    }

    pub fn enabled(self: *const Ppu) bool {
        return self.lcdc & lcdc_enable != 0;
    }

    /// Le OU des sources d'interruption STAT activées.
    fn statConditions(self: *const Ppu) bool {
        return (self.stat & stat_irq_hblank != 0 and self.mode == .hblank) or
            (self.stat & stat_irq_vblank != 0 and self.mode == .vblank) or
            (self.stat & stat_irq_oam != 0 and self.mode == .oam_scan) or
            (self.stat & stat_irq_lyc != 0 and self.ly == self.lyc);
    }

    /// Recalcule le fil STAT et lève l'interruption sur front montant.
    /// À appeler après tout ce qui peut changer une source : changement
    /// de mode ou de ligne, écriture dans LCDC, STAT ou LYC.
    fn updateStatLine(self: *Ppu, irq: *Interrupts) void {
        // Écran éteint : le fil retombe, pour pouvoir remonter au rallumage.
        const line = self.enabled() and self.statConditions();
        if (line and !self.stat_line) irq.stat = true;
        self.stat_line = line;
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
            0xFF41 => blk: {
                const coincidence: u8 = if (self.ly == self.lyc) stat_coincidence else 0;
                break :blk 0x80 | self.stat | coincidence | @backingInt(self.mode);
            },
            0xFF42 => self.scy,
            0xFF43 => self.scx,
            0xFF44 => self.ly,
            0xFF45 => self.lyc,
            0xFF46 => self.dma,
            0xFF47 => self.bgp,
            0xFF48 => self.obp0,
            0xFF49 => self.obp1,
            0xFF4A => self.wy,
            0xFF4B => self.wx,
            else => unreachable,
        };
    }

    /// Une écriture peut lever l'interruption STAT : activer une source
    /// déjà vraie, ou écrire dans LYC la ligne en cours, fait monter le fil.
    pub fn write(self: *Ppu, addr: u16, value: u8) Interrupts {
        var irq: Interrupts = .{};
        switch (addr) {
            0xFF40 => {
                const was_on = self.enabled();
                self.lcdc = value;
                if (was_on and !self.enabled()) {
                    // Extinction : tout s'arrête en ligne 0, mode 0.
                    self.dot = 0;
                    self.ly = 0;
                    self.mode = .hblank;
                } else if (!was_on and self.enabled()) {
                    // Rallumage : début de la ligne 0 (dot et LY déjà à 0).
                    self.mode = .oam_scan;
                }
            },
            // Seuls les bits 3 à 6 (sources de l'interruption STAT) s'écrivent.
            0xFF41 => self.stat = value & stat_writable,
            0xFF42 => self.scy = value,
            0xFF43 => self.scx = value,
            // LY est en lecture seule.
            0xFF44 => {},
            0xFF45 => self.lyc = value,
            0xFF46 => self.dma = value,
            0xFF47 => self.bgp = value,
            0xFF48 => self.obp0 = value,
            0xFF49 => self.obp1 = value,
            0xFF4A => self.wy = value,
            0xFF4B => self.wx = value,
            else => unreachable,
        }
        self.updateStatLine(&irq);
        return irq;
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

test "SCY, SCX, DMA, palettes, WY, WX : relus tels qu'écrits" {
    var ppu: Ppu = .{};
    const addrs = [_]u16{ 0xFF42, 0xFF43, 0xFF46, 0xFF47, 0xFF48, 0xFF49, 0xFF4A, 0xFF4B };
    for (addrs, 0..) |addr, i| {
        const value: u8 = @intCast(0x11 * (i + 1));
        try expectEqual(false, ppu.write(addr, value).stat);
        try expectEqual(value, ppu.read(addr));
    }
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
    _ = ppu.write(0xFF41, 0xFF);
    try expectEqual(@as(u8, 0xFD), ppu.read(0xFF41));
    _ = ppu.write(0xFF41, 0x00);
    try expectEqual(@as(u8, 0x85), ppu.read(0xFF41));
    _ = ppu.write(0xFF44, 0x42);
    try expectEqual(@as(u8, 0), ppu.read(0xFF44));
}

/// Avance jusqu'au dot 0 de la ligne `line` (depuis l'état de démarrage).
fn gotoLine(ppu: *Ppu, line: u8) void {
    _ = ppu.tick(@as(u16, line) * dots_per_line);
}

/// Compte les interruptions STAT levées en `dots` dots, par pas de 4.
fn countStat(ppu: *Ppu, dots: u32) u32 {
    var n: u32 = 0;
    for (0..dots / 4) |_| {
        if (ppu.tick(4).stat) n += 1;
    }
    return n;
}

test "coïncidence LY = LYC : STAT bit 2 suit LY" {
    var ppu: Ppu = .{};
    _ = ppu.write(0xFF45, 5);
    try expectEqual(@as(u8, 5), ppu.read(0xFF45));
    try expectEqual(@as(u8, 0), ppu.read(0xFF41) & 0x04);
    gotoLine(&ppu, 4);
    _ = ppu.tick(455);
    try expectEqual(@as(u8, 0), ppu.read(0xFF41) & 0x04);
    _ = ppu.tick(1); // LY = 5
    try expectEqual(@as(u8, 0x04), ppu.read(0xFF41) & 0x04);
    _ = ppu.tick(455);
    try expectEqual(@as(u8, 0x04), ppu.read(0xFF41) & 0x04);
    _ = ppu.tick(1); // LY = 6
    try expectEqual(@as(u8, 0), ppu.read(0xFF41) & 0x04);
}

test "interruption STAT LYC : une fois par frame, à l'entrée de la ligne" {
    var ppu: Ppu = .{};
    _ = ppu.write(0xFF45, 100);
    _ = ppu.write(0xFF41, 0x40);
    gotoLine(&ppu, 99);
    _ = ppu.tick(452);
    try expectEqual(true, ppu.tick(4).stat);
    try expectEqual(@as(u8, 100), ppu.ly);
    // Rien d'autre jusqu'au même point de la frame suivante.
    try expectEqual(@as(u32, 0), countStat(&ppu, dots_per_frame - 4));
    try expectEqual(true, ppu.tick(4).stat);
}

test "écrire dans LYC la ligne en cours lève l'interruption tout de suite" {
    var ppu: Ppu = .{};
    _ = ppu.write(0xFF41, 0x40);
    gotoLine(&ppu, 7);
    try expectEqual(true, ppu.write(0xFF45, 7).stat);
    // Le fil est déjà haut : réécrire la même valeur ne relève rien.
    try expectEqual(false, ppu.write(0xFF45, 7).stat);
}

test "interruption STAT mode 0 : à chaque HBlank, au dot 252" {
    var ppu: Ppu = .{};
    _ = ppu.write(0xFF41, 0x08);
    gotoLine(&ppu, 3);
    _ = ppu.tick(248);
    try expectEqual(true, ppu.tick(4).stat);
    try expectEqual(Mode.hblank, ppu.mode);
    // Une seule par ligne visible, aucune en VBlank.
    var other: Ppu = .{};
    _ = other.write(0xFF41, 0x08);
    try expectEqual(@as(u32, 144), countStat(&other, dots_per_frame));
}

test "interruption STAT mode 2 : au début de chaque ligne visible" {
    var ppu: Ppu = .{};
    _ = ppu.write(0xFF41, 0x20);
    gotoLine(&ppu, 10);
    _ = ppu.tick(452);
    try expectEqual(true, ppu.tick(4).stat);
    try expectEqual(Mode.oam_scan, ppu.mode);
    try expectEqual(@as(u8, 11), ppu.ly);
    // Lignes 1 à 143, puis ligne 0 de la frame suivante. La ligne 0 de la
    // première frame démarre en mode 1 (état du boot ROM) : pas de mode 2.
    var other: Ppu = .{};
    _ = other.write(0xFF41, 0x20);
    try expectEqual(@as(u32, 144), countStat(&other, dots_per_frame));
}

test "STAT blocking : HBlank puis LYC à la ligne suivante = une seule interruption" {
    var ppu: Ppu = .{};
    // HBlank de la ligne 9 (fil à 1), puis ligne 10 avec LY = LYC : le fil
    // reste à 1 d'un bout à l'autre, donc pas de second front.
    _ = ppu.write(0xFF45, 10);
    _ = ppu.write(0xFF41, 0x48);
    gotoLine(&ppu, 9);
    try expectEqual(@as(u32, 1), countStat(&ppu, 2 * dots_per_line));
    try expectEqual(@as(u8, 11), ppu.ly);
}

test "STAT blocking : modes 0 et 2 ensemble ne doublent pas les interruptions" {
    var ppu: Ppu = .{};
    // Le HBlank de la ligne N enchaîne sur le mode 2 de la ligne N+1 sans
    // que le fil retombe : 144 HBlank, plus le mode 2 de la ligne 0 de la
    // frame suivante (le fil est retombé pendant le VBlank). Sans blocking,
    // on en compterait 144 + 144.
    _ = ppu.write(0xFF41, 0x28);
    try expectEqual(@as(u32, 145), countStat(&ppu, dots_per_frame));
}

test "écran éteint : LY = 0, mode 0, rien n'avance" {
    var ppu: Ppu = .{};
    _ = ppu.write(0xFF41, 0x78); // toutes les sources
    gotoLine(&ppu, 50);
    _ = ppu.tick(100);
    try expectEqual(false, ppu.write(0xFF40, 0x11).stat);
    try expectEqual(@as(u8, 0), ppu.read(0xFF44));
    try expectEqual(@as(u8, 0), ppu.read(0xFF41) & 0x03);
    for (0..dots_per_frame / 4 * 2) |_| {
        const irq = ppu.tick(4);
        try expectEqual(false, irq.vblank);
        try expectEqual(false, irq.stat);
    }
    try expectEqual(@as(u8, 0), ppu.ly);
    try expectEqual(@as(u16, 0), ppu.dot);
}

test "rallumage : repart du dot 0 de la ligne 0" {
    var ppu: Ppu = .{};
    gotoLine(&ppu, 120);
    _ = ppu.write(0xFF40, 0x11);
    _ = ppu.tick(1000);
    _ = ppu.write(0xFF41, 0x20);
    // Le fil remonte au rallumage (mode 2) : interruption.
    try expectEqual(true, ppu.write(0xFF40, 0x91).stat);
    try expectEqual(Mode.oam_scan, ppu.mode);
    try expectEqual(@as(u8, 0), ppu.ly);
    _ = ppu.tick(455);
    try expectEqual(@as(u8, 0), ppu.ly);
    _ = ppu.tick(1);
    try expectEqual(@as(u8, 1), ppu.ly);
}
