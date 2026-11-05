//! Harnais SingleStepTests (https://github.com/SingleStepTests/sm83).
//!
//! Chaque fichier JSON du jeu de données (`00.json` ... `cb ff.json`)
//! contient 1000 cas pour un opcode : état du CPU et de la RAM avant,
//! état attendu après, et la liste des M-cycles sur le bus.
//! Pour chaque cas, on charge l'état initial dans un CPU branché sur
//! une mémoire plate de 64 Kio, on exécute une instruction, puis on
//! compare registres, IME, RAM et nombre de M-cycles.
//!
//! Usage : zig build sst [-- <opcode>...]
//!   zig build sst              tous les opcodes
//!   zig build sst -- 27 cb37   seulement DAA et SWAP A

const std = @import("std");
const gb = @import("gb");

/// Les tests supposent 64 Kio de RAM sans aucun aiguillage :
/// pas de ROM, pas de registres d'E/S, pas d'echo RAM.
const FlatBus = struct {
    mem: [0x10000]u8,

    pub fn read(self: *FlatBus, addr: u16) u8 {
        return self.mem[addr];
    }

    pub fn write(self: *FlatBus, addr: u16, value: u8) void {
        self.mem[addr] = value;
    }
};

/// Un état tel qu'écrit dans le JSON. Les champs absents du JSON
/// (`ie`) sont ignorés ; `ei` n'apparaît que lorsqu'il vaut 1.
const State = struct {
    pc: u16,
    sp: u16,
    a: u8,
    b: u8,
    c: u8,
    d: u8,
    e: u8,
    f: u8,
    h: u8,
    l: u8,
    ime: u1,
    /// EI vient de s'exécuter : IME passera à 1 après l'instruction
    /// suivante. C'est notre `ime_pending`.
    ei: u1 = 0,
    /// Paires [adresse, valeur].
    ram: []const [2]u16,
};

const Case = struct {
    name: []const u8,
    initial: State,
    final: State,
    /// Un élément par M-cycle. Seule la longueur nous sert : le CPU
    /// n'est pas encore cadencé cycle par cycle.
    cycles: []const std.json.Value,
};

var bus: FlatBus = undefined;

/// Nom du cas en cours, affiché si le CPU panique (dépassement
/// d'entier, par exemple) : sans lui, on ne saurait pas lequel.
var current_case: []const u8 = "";

pub const panic = std.debug.FullPanic(struct {
    fn call(msg: []const u8, first_trace_addr: ?usize) noreturn {
        std.debug.print("\npanique pendant le cas \"{s}\"\n", .{current_case});
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.call);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // build.zig passe toujours le dossier des données en premier.
    const data_path = args[1];
    const filters = args[2..];

    var dir = std.Io.Dir.cwd().openDir(io, data_path, .{}) catch |err| {
        std.debug.print(
            \\dossier introuvable : {s} ({s})
            \\Récupère les données avec :
            \\  git clone --depth 1 https://github.com/SingleStepTests/sm83.git test-roms/sm83
            \\
        , .{ data_path, @errorName(err) });
        std.process.exit(1);
    };
    defer dir.close(io);

    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();

    var files_run: u32 = 0;
    var files_ok: u32 = 0;
    var cases_run: u32 = 0;
    var cases_ok: u32 = 0;

    for ([_]bool{ false, true }) |cb| {
        for (0..256) |op| {
            var name_buf: [16]u8 = undefined;
            const name = if (cb)
                try std.fmt.bufPrint(&name_buf, "cb {x:0>2}.json", .{op})
            else
                try std.fmt.bufPrint(&name_buf, "{x:0>2}.json", .{op});
            if (!matches(filters, cb, @intCast(op))) continue;

            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();

            const json = dir.readFileAlloc(io, name, arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
                // Opcodes illégaux (D3, DB, ...) et 0xCB lui-même : pas de fichier.
                error.FileNotFound => {
                    if (filters.len > 0) std.debug.print("{s} : pas de fichier (opcode illégal ?)\n", .{name});
                    continue;
                },
                else => return err,
            };
            const cases = try std.json.parseFromSliceLeaky([]const Case, arena, json, .{
                .ignore_unknown_fields = true,
            });

            var failed: u32 = 0;
            for (cases) |*case| {
                if (try runCase(case, failed == 0)) {
                    cases_ok += 1;
                } else {
                    failed += 1;
                }
            }
            cases_run += @intCast(cases.len);
            files_run += 1;
            if (failed == 0) {
                files_ok += 1;
            } else {
                std.debug.print("ÉCHEC {s} : {d}/{d} cas faux\n\n", .{ name, failed, cases.len });
            }
        }
    }

    std.debug.print("{d}/{d} opcodes OK, {d}/{d} cas OK\n", .{ files_ok, files_run, cases_ok, cases_run });
    if (files_run == 0 or files_ok != files_run) std.process.exit(1);
}

/// Sans filtre, tout passe. Un filtre s'écrit "27" ou "cb37"
/// (majuscules et espace après "cb" acceptées).
fn matches(filters: []const []const u8, cb: bool, op: u8) bool {
    if (filters.len == 0) return true;
    for (filters) |raw| {
        var buf: [8]u8 = undefined;
        var len: usize = 0;
        for (raw) |ch| {
            if (ch == ' ' or len == buf.len) continue;
            buf[len] = std.ascii.toLower(ch);
            len += 1;
        }
        var f: []const u8 = buf[0..len];
        const f_cb = std.mem.startsWith(u8, f, "cb") and f.len > 2;
        if (f_cb) f = f[2..];
        const f_op = std.fmt.parseInt(u8, f, 16) catch continue;
        if (f_cb == cb and f_op == op) return true;
    }
    return false;
}

/// Exécute un cas. Renvoie true s'il passe. Si `report`, affiche
/// le détail des différences (seulement pour le premier échec d'un
/// fichier, sinon la sortie serait illisible).
fn runCase(case: *const Case, report: bool) !bool {
    current_case = case.name;
    const in = case.initial;

    @memset(&bus.mem, 0);
    for (in.ram) |entry| bus.mem[entry[0]] = @intCast(entry[1]);

    var cpu: gb.Cpu = .{
        .a = in.a,
        .f = @bitCast(in.f & 0xF0),
        .b = in.b,
        .c = in.c,
        .d = in.d,
        .e = in.e,
        .h = in.h,
        .l = in.l,
        .sp = in.sp,
        .pc = in.pc,
        .ime = in.ime == 1,
        .ime_pending = in.ei == 1,
        .halted = false,
        .stopped = false,
    };

    const cycles = cpu.step(&bus) catch |err| {
        if (report) std.debug.print("{s} : {s}\n", .{ case.name, @errorName(err) });
        return false;
    };

    const want = case.final;
    var ok = true;
    const regs = .{ "a", "b", "c", "d", "e", "h", "l" };
    inline for (regs) |r| {
        ok = check(report, &ok, case.name, r, @field(want, r), @field(cpu, r)) and ok;
    }
    ok = check(report, &ok, case.name, "f", want.f, @as(u8, @bitCast(cpu.f))) and ok;
    ok = check(report, &ok, case.name, "pc", want.pc, cpu.pc) and ok;
    ok = check(report, &ok, case.name, "sp", want.sp, cpu.sp) and ok;
    ok = check(report, &ok, case.name, "ime", want.ime, @intFromBool(cpu.ime)) and ok;
    ok = check(report, &ok, case.name, "ei", want.ei, @intFromBool(cpu.ime_pending)) and ok;
    ok = check(report, &ok, case.name, "M-cycles", case.cycles.len, cycles) and ok;
    for (want.ram) |entry| {
        var label_buf: [16]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "[{X:0>4}]", .{entry[0]});
        ok = check(report, &ok, case.name, label, entry[1], bus.mem[entry[0]]) and ok;
    }

    if (!ok and report) printInitial(in);
    return ok;
}

/// Compare une valeur. Au premier écart d'un cas, affiche son nom.
fn check(report: bool, ok_so_far: *const bool, case: []const u8, what: []const u8, want: anytype, got: anytype) bool {
    const w: u64 = want;
    const g: u64 = got;
    if (w == g) return true;
    if (report) {
        if (ok_so_far.*) std.debug.print("{s} :\n", .{case});
        std.debug.print("  {s:<8} attendu 0x{X:0>2}, obtenu 0x{X:0>2}\n", .{ what, w, g });
    }
    return false;
}

fn printInitial(in: State) void {
    std.debug.print(
        "  avant : A={X:0>2} F={X:0>2} B={X:0>2} C={X:0>2} D={X:0>2} E={X:0>2} H={X:0>2} L={X:0>2} SP={X:0>4} PC={X:0>4} IME={d}\n",
        .{ in.a, in.f, in.b, in.c, in.d, in.e, in.h, in.l, in.sp, in.pc, in.ime },
    );
    std.debug.print("  RAM   :", .{});
    for (in.ram) |entry| std.debug.print(" [{X:0>4}]={X:0>2}", .{ entry[0], entry[1] });
    std.debug.print("\n", .{});
}
