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
//! Chaque ligne visible est dessinée d'un coup dans `framebuffer` au
//! passage en mode 0 (`renderLine`), avec les registres du moment.
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

/// LCDC bit 0 (DMG) : fond et fenêtre affichés.
const lcdc_bg_enable: u8 = 0x01;
/// LCDC bit 3 : tilemap du fond en 0x9C00 (sinon 0x9800).
const lcdc_bg_map: u8 = 0x08;
/// LCDC bit 4 : tuiles en 0x8000, index non signé (sinon base 0x9000,
/// index signé).
const lcdc_tile_data: u8 = 0x10;

pub const screen_width = 160;
pub const screen_height = vblank_line;

pub const vram_size = 0x2000;
pub const oam_size = 0xA0;

pub const Ppu = struct {
    /// VRAM (0x8000..0x9FFF), indexée depuis 0.
    vram: [vram_size]u8 = @splat(0),
    /// OAM (0xFE00..0xFE9F), indexée depuis 0 : 40 sprites × 4 octets.
    oam: [oam_size]u8 = @splat(0),

    /// L'image : une teinte par pixel (0 = blanc à 3 = noir), palette
    /// déjà appliquée.
    framebuffer: [screen_height][screen_width]u2 = @splat(@splat(0)),

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
                self.renderLine();
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

    /// Dessine la ligne LY dans le framebuffer.
    pub fn renderLine(self: *Ppu) void {
        const row = &self.framebuffer[self.ly];
        // DMG : fond et fenêtre désactivés = couleur 0 partout (passée
        // par BGP). Les sprites, eux, resteront dessinés par-dessus.
        if (self.lcdc & lcdc_bg_enable == 0) {
            @memset(row, applyPalette(self.bgp, 0));
            return;
        }
        // Coordonnées dans la carte de fond 256 × 256 : les u8 reviennent
        // à 0 après 255, comme sur le matériel.
        const bg_y = self.ly +% self.scy;
        for (row, 0..) |*pixel, x| {
            const bg_x = @as(u8, @intCast(x)) +% self.scx;
            pixel.* = applyPalette(self.bgp, self.bgColor(bg_x, bg_y));
        }
    }

    /// Indice de couleur (0 à 3, avant palette) du pixel (x, y) de la
    /// carte de fond.
    fn bgColor(self: *const Ppu, x: u8, y: u8) u2 {
        const map_base: u16 = if (self.lcdc & lcdc_bg_map != 0) 0x1C00 else 0x1800;
        // La carte fait 32 × 32 tuiles de 8 × 8 pixels.
        const tile_index = self.vram[map_base + @as(u16, y / 8) * 32 + x / 8];
        return self.tilePixel(self.tileAddress(tile_index), x % 8, y % 8);
    }

    /// Adresse (dans la VRAM) des 16 octets d'une tuile, selon LCDC bit 4.
    fn tileAddress(self: *const Ppu, index: u8) u16 {
        if (self.lcdc & lcdc_tile_data != 0) return @as(u16, index) * 16;
        // Base 0x9000, index de -128 à 127 : 0x8800..0x97FF.
        const signed: i16 = @as(i8, @bitCast(index));
        return @intCast(0x1000 + signed * 16);
    }

    /// Une tuile = 8 lignes de 2 octets. Le bit 7 de chaque octet est le
    /// pixel de gauche ; le premier octet donne le bit 0 de la couleur,
    /// le second le bit 1.
    fn tilePixel(self: *const Ppu, tile_addr: u16, x: u8, y: u8) u2 {
        const lo = self.vram[tile_addr + @as(u16, y) * 2];
        const hi = self.vram[tile_addr + @as(u16, y) * 2 + 1];
        const bit: u3 = @intCast(7 - x);
        const b0: u2 = @intCast((lo >> bit) & 1);
        const b1: u2 = @intCast((hi >> bit) & 1);
        return b1 << 1 | b0;
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

/// Une palette DMG = 4 teintes de 2 bits : bits 1-0 pour la couleur 0,
/// bits 3-2 pour la couleur 1, etc.
fn applyPalette(palette: u8, color: u2) u2 {
    return @truncate(palette >> (@as(u3, color) * 2));
}

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

/// Tuile de test : chaque ligne vaut les couleurs 0, 1, 2, 3, 0, 1, 2, 3
/// de gauche à droite (octet bas 0b0101_0101, octet haut 0b0011_0011).
fn writeTestTile(ppu: *Ppu, tile_addr: u16) void {
    for (0..8) |row| {
        ppu.vram[tile_addr + row * 2] = 0x55;
        ppu.vram[tile_addr + row * 2 + 1] = 0x33;
    }
}

/// PPU avec le LCDC donné et la palette identité (couleur n = teinte n).
fn testPpu(lcdc: u8) Ppu {
    var ppu: Ppu = .{};
    ppu.lcdc = lcdc;
    ppu.bgp = 0xE4; // 3, 2, 1, 0
    return ppu;
}

const expectEqualSlices = std.testing.expectEqualSlices;

test "fond : tuile 1 en 0x8010, tilemap 0x9800" {
    var ppu = testPpu(0x91);
    writeTestTile(&ppu, 0x0010);
    ppu.vram[0x1800] = 1; // tuile (0, 0) de la carte
    ppu.renderLine();
    try expectEqualSlices(u2, &.{ 0, 1, 2, 3, 0, 1, 2, 3 }, ppu.framebuffer[0][0..8]);
    // La tuile voisine (index 0, vide) : couleur 0.
    try expectEqual(@as(u2, 0), ppu.framebuffer[0][11]);
}

test "fond : BGP est appliquée" {
    var ppu = testPpu(0x91);
    ppu.bgp = 0x1B; // inversée : couleur n -> teinte 3 - n
    writeTestTile(&ppu, 0x0010);
    ppu.vram[0x1800] = 1;
    ppu.renderLine();
    try expectEqualSlices(u2, &.{ 3, 2, 1, 0, 3, 2, 1, 0 }, ppu.framebuffer[0][0..8]);
}

test "fond : la ligne est dessinée au passage en mode 0" {
    var ppu = testPpu(0x91);
    writeTestTile(&ppu, 0x0010);
    @memset(ppu.vram[0x1800..0x1C00], 1); // toute la carte
    gotoLine(&ppu, 5);
    _ = ppu.tick(drawing_end - 1);
    try expectEqual(@as(u2, 0), ppu.framebuffer[5][3]);
    _ = ppu.tick(1);
    try expectEqual(Mode.hblank, ppu.mode);
    try expectEqual(@as(u2, 3), ppu.framebuffer[5][3]);
    try expectEqual(@as(u2, 3), ppu.framebuffer[5][159]);
    try expectEqual(@as(u2, 0), ppu.framebuffer[6][3]);
}

test "fond : SCX décale vers la gauche, SCY vers le haut" {
    var ppu = testPpu(0x91);
    // Tuile (1, 1) de la carte : pixels 8 à 15 en x et en y.
    writeTestTile(&ppu, 0x0010);
    ppu.vram[0x1800 + 32 + 1] = 1;
    ppu.scx = 10;
    ppu.scy = 3;
    ppu.ly = 5; // ligne 8 de la carte
    ppu.renderLine();
    // Écran x = 0 -> carte x = 10 : 3e pixel de la tuile.
    try expectEqualSlices(u2, &.{ 2, 3, 0, 1, 2, 3 }, ppu.framebuffer[5][0..6]);
    try expectEqual(@as(u2, 0), ppu.framebuffer[5][6]); // carte x = 16
    ppu.ly = 4; // ligne 7 de la carte : au-dessus de la tuile
    ppu.renderLine();
    try expectEqual(@as(u2, 0), ppu.framebuffer[4][1]);
}

test "fond : le défilement revient à 0 après 255" {
    var ppu = testPpu(0x91);
    writeTestTile(&ppu, 0x0010);
    ppu.vram[0x1800] = 1; // tuile (0, 0)
    ppu.scx = 252;
    ppu.scy = 250;
    ppu.ly = 6; // 250 + 6 = 256 -> ligne 0 de la carte
    ppu.renderLine();
    // Écran x = 4 -> carte x = 256 -> 0.
    try expectEqualSlices(u2, &.{ 0, 1, 2, 3, 0, 1, 2, 3 }, ppu.framebuffer[6][4..12]);
    try expectEqual(@as(u2, 0), ppu.framebuffer[6][3]); // carte x = 255
}

test "fond : LCDC bit 3 choisit la tilemap 0x9C00" {
    var ppu = testPpu(0x99);
    writeTestTile(&ppu, 0x0010);
    ppu.vram[0x1C00] = 1;
    ppu.renderLine();
    try expectEqual(@as(u2, 3), ppu.framebuffer[0][3]);
    ppu.lcdc = 0x91;
    ppu.renderLine();
    try expectEqual(@as(u2, 0), ppu.framebuffer[0][3]);
}

test "fond : LCDC bit 4 = 0, index signé autour de 0x9000" {
    var ppu = testPpu(0x81);
    writeTestTile(&ppu, 0x1000); // index 0 -> 0x9000
    writeTestTile(&ppu, 0x0FF0); // index 0xFF (-1) -> 0x8FF0
    writeTestTile(&ppu, 0x0800); // index 0x80 (-128) -> 0x8800
    writeTestTile(&ppu, 0x0010); // 0x8010 : ne doit pas être lue
    ppu.vram[0x1800] = 0;
    ppu.vram[0x1801] = 0xFF;
    ppu.vram[0x1802] = 1; // -> 0x9010, vide
    ppu.vram[0x1803] = 0x80;
    ppu.renderLine();
    try expectEqual(@as(u2, 3), ppu.framebuffer[0][3]);
    try expectEqual(@as(u2, 3), ppu.framebuffer[0][11]);
    try expectEqual(@as(u2, 0), ppu.framebuffer[0][19]);
    try expectEqual(@as(u2, 3), ppu.framebuffer[0][27]);
}

test "fond : LCDC bit 0 = 0, couleur 0 partout" {
    var ppu = testPpu(0x90);
    ppu.bgp = 0x1B; // couleur 0 -> teinte 3
    writeTestTile(&ppu, 0x0010);
    @memset(ppu.vram[0x1800..0x1C00], 1);
    ppu.renderLine();
    for (ppu.framebuffer[0]) |pixel| try expectEqual(@as(u2, 3), pixel);
}
