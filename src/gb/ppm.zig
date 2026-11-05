//! Export du framebuffer au format PPM (Netpbm), le plus simple des
//! formats d'image : un en-tête texte puis les pixels bruts.
//!
//!   P6\n160 144\n255\n   puis 160 × 144 triplets R, G, B (1 octet chacun)
//!
//! Aucune compression, aucune somme de contrôle : GIMP, IrfanView,
//! ImageMagick ou ffmpeg l'ouvrent directement.

const std = @import("std");
const ppu = @import("ppu.zig");

pub const Framebuffer = [ppu.screen_height][ppu.screen_width]u2;

/// Niveau de gris de chaque teinte DMG, de 0 (blanc) à 3 (noir).
/// Ce sont les valeurs qu'attend dmg-acid2 ($FF, $AA, $55, $00).
pub const gray_levels = [4]u8{ 0xFF, 0xAA, 0x55, 0x00 };

pub fn writePpm(framebuffer: *const Framebuffer, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("P6\n{d} {d}\n255\n", .{ ppu.screen_width, ppu.screen_height });
    for (framebuffer) |row| {
        for (row) |shade| {
            const g = gray_levels[shade];
            try writer.writeAll(&.{ g, g, g });
        }
    }
}

test "writePpm : en-tête puis un triplet RGB par pixel" {
    var fb: Framebuffer = @splat(@splat(0));
    fb[0][1] = 1;
    fb[0][2] = 2;
    fb[143][159] = 3;

    var buf: [32 + ppu.screen_width * ppu.screen_height * 3]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePpm(&fb, &w);
    const out = w.buffered();

    const header = "P6\n160 144\n255\n";
    try std.testing.expectEqualStrings(header, out[0..header.len]);
    const pixels = out[header.len..];
    try std.testing.expectEqual(@as(usize, 160 * 144 * 3), pixels.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF, 0xAA, 0xAA, 0xAA, 0x55, 0x55, 0x55 }, pixels[0..9]);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x00 }, pixels[pixels.len - 3 ..]);
}
