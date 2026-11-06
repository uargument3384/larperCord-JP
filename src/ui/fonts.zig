//! Fontes: resolve famílias pelo fontconfig, mapeia cada arquivo uma única
//! vez na memória (compartilhado entre pesos e famílias) e mescla o emoji
//! colorido em todas. Famílias novas podem ser carregadas a qualquer momento
//! (troca de tema), fora do intervalo NewFrame/Render.
const std = @import("std");
const sys = @import("../platform/sys.zig");
const c = @import("c");

pub const Weight = enum(u3) { regular, medium, semibold, bold, italic };

pub const Family = struct {
    name: []const u8,
    faces: [5]*c.ImFont,

    pub fn get(f: *const Family, w: Weight) *c.ImFont {
        return f.faces[@intFromEnum(w)];
    }
};

const load_color: c_uint = 1 << 8; // ImGuiFreeTypeLoaderFlags_LoadColor
const load_bitmap: c_uint = 1 << 9; // ImGuiFreeTypeLoaderFlags_Bitmap (emoji CBDT)
const light_hinting: c_uint = 1 << 3; // ImGuiFreeTypeLoaderFlags_LightHinting

pub const Fonts = struct {
    gpa: std.mem.Allocator,
    atlas: *c.ImFontAtlas,
    families: std.ArrayList(*Family) = .empty,
    maps: std.StringHashMapUnmanaged([]u8) = .empty,
    faces: std.ArrayList(struct { data: [*]u8, index: c_int, font: *c.ImFont }) = .empty,
    emoji: ?[]u8 = null,
    /// Fonte reserva para símbolos que a fonte principal não tem (⌁ ▣ ◐ ♪ …).
    symbols: ?struct { data: []u8, index: c_int } = null,
    /// Fonte japonesa empacotada ao lado do executável (não depende de C:\\Windows\\Fonts).
    japanese: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, atlas: *c.ImFontAtlas) Fonts {
        var f: Fonts = .{ .gpa = gpa, .atlas = atlas };
        if (resolve("emoji", 80, 0)) |m| {
            defer std.heap.c_allocator.free(m.path);
            f.emoji = f.mapPath(m.path) catch null;
        }
        if (resolve("DejaVu Sans", 80, 0)) |m| {
            defer std.heap.c_allocator.free(m.path);
            if (f.mapPath(m.path)) |data| {
                f.symbols = .{ .data = data, .index = m.index };
            } else |_| {}
        }
        // SDL_GetBasePath aponta para a pasta do executável. Assim o pacote
        // funciona mesmo quando o usuário inicia o app por outro diretório.
        if (c.SDL_GetBasePath()) |base| {
            var path_buf: [1024]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&path_buf, "{s}fonts/NotoSansJP.ttf", .{std.mem.span(base)}, 0) catch return f;
            if (sys.exists(path.ptr)) f.japanese = f.mapPath(path) catch null;
        }
        return f;
    }

    /// Família já carregada (não carrega nada: seguro no meio do quadro).
    pub fn find(f: *const Fonts, name: []const u8) ?*Family {
        for (f.families.items) |fam| if (std.mem.eql(u8, fam.name, name)) return fam;
        return null;
    }

    /// Família pelo nome ("Inter", "JetBrains Mono"...). Carrega se preciso.
    pub fn family(f: *Fonts, name: []const u8) !*Family {
        for (f.families.items) |fam| if (std.mem.eql(u8, fam.name, name)) return fam;

        const fam = try f.gpa.create(Family);
        fam.name = try f.gpa.dupe(u8, name);
        const specs = [_]struct { w: c_int, slant: c_int }{
            .{ .w = 80, .slant = 0 }, // regular
            .{ .w = 100, .slant = 0 }, // medium
            .{ .w = 180, .slant = 0 }, // semibold
            .{ .w = 200, .slant = 0 }, // bold
            .{ .w = 80, .slant = 100 }, // itálico
        };
        for (specs, 0..) |s, i| {
            const m = resolve(name, s.w, s.slant) orelse return error.FontNotFound;
            defer std.heap.c_allocator.free(m.path);
            const data = try f.mapPath(m.path);
            fam.faces[i] = try f.faceFor(data, m.index);
        }
        try f.families.append(f.gpa, fam);
        return fam;
    }

    /// O mesmo arquivo pode atender vários pesos e famílias (a família não tem
    /// aquele peso, ou "monospace" é a fonte de outro nome): uma fonte só no atlas.
    fn faceFor(f: *Fonts, data: []u8, index: c_int) !*c.ImFont {
        for (f.faces.items) |e| if (e.data == data.ptr and e.index == index) return e.font;
        const font = try f.add(data, index);
        try f.faces.append(f.gpa, .{ .data = data.ptr, .index = index, .font = font });
        return font;
    }

    fn add(f: *Fonts, data: []u8, index: c_int) !*c.ImFont {
        var cfg = defaultConfig();
        cfg.FontNo = @intCast(index);
        cfg.PixelSnapH = true;
        // Hinting leve: encaixa só na vertical (como o ClearType), sem o
        // serrilhado do hinting completo nas letras pequenas; e um traço um
        // pouco mais cheio, porque o SDL mistura em sRGB e o texto claro no
        // fundo escuro sai fino demais.
        cfg.FontLoaderFlags = light_hinting;
        cfg.RasterizerMultiply = 1.15;
        cfg.FontDataOwnedByAtlas = false;
        if (f.emoji != null) cfg.GlyphExcludeRanges = &emoji_ranges;
        const font = c.ImFontAtlas_AddFontFromMemoryTTF(f.atlas, data.ptr, @intCast(data.len), 16, &cfg, null) orelse return error.FontLoad;
        if (f.emoji) |e| {
            var ecfg = defaultConfig();
            ecfg.MergeMode = true;
            ecfg.FontLoaderFlags = load_color | load_bitmap;
            ecfg.FontDataOwnedByAtlas = false;
            _ = c.ImFontAtlas_AddFontFromMemoryTTF(f.atlas, e.ptr, @intCast(e.len), 16, &ecfg, null);
        }
        if (f.symbols) |sym| {
            var scfg = defaultConfig();
            scfg.MergeMode = true;
            scfg.FontNo = @intCast(sym.index);
            scfg.FontDataOwnedByAtlas = false;
            _ = c.ImFontAtlas_AddFontFromMemoryTTF(f.atlas, sym.data.ptr, @intCast(sym.data.len), 16, &scfg, null);
        }
        // Mescla kana, kanji e pontuação japonesa em cada família já carregada.
        // Os glifos latinos continuam vindo da fonte escolhida pelo tema.
        if (f.japanese) |jp| {
            var jcfg = defaultConfig();
            jcfg.MergeMode = true;
            jcfg.FontLoaderFlags = light_hinting;
            // O Noto JP fica um pouco mais encorpado para manter a leitura
            // nítida no fundo escuro, sem engrossar os glifos latinos.
            jcfg.RasterizerMultiply = 1.40;
            jcfg.FontDataOwnedByAtlas = false;
            _ = c.ImFontAtlas_AddFontFromMemoryTTF(f.atlas, jp.ptr, @intCast(jp.len), 16, &jcfg, &japanese_ranges);
        }
        return font;
    }

    /// Mapeia o arquivo (somente leitura); só as páginas lidas ficam na RAM.
    fn mapPath(f: *Fonts, path: [:0]const u8) ![]u8 {
        if (f.maps.get(path)) |m| return m;
        const data = sys.mapFile(path.ptr) orelse return error.FontLoad;
        try f.maps.put(f.gpa, try f.gpa.dupe(u8, path), data);
        return data;
    }
};

/// Faixas que o emoji colorido deve fornecer mesmo que a fonte do texto tenha
/// uma versão em preto e branco (❤ ☀ ✨ …).
const emoji_ranges = [_]c.ImWchar{ 0x2600, 0x27BF, 0x2B00, 0x2BFF, 0x1F000, 0x1FAFF, 0 };
/// Hiragana, katakana, kanji, CJK symbols, and full-width punctuation.
const japanese_ranges = [_]c.ImWchar{
    0x3000, 0x30FF,
    0x31F0, 0x31FF,
    0x3200, 0x32FF,
    0x3300, 0x33FF,
    0x3400, 0x4DBF,
    0x4E00, 0x9FFF,
    0xF900, 0xFAFF,
    0xFF00, 0xFFEF,
    0,
};

fn defaultConfig() c.ImFontConfig {
    var cfg = std.mem.zeroes(c.ImFontConfig);
    cfg.FontDataOwnedByAtlas = true;
    cfg.ExtraSizeScale = 1.0;
    cfg.GlyphMaxAdvanceX = std.math.floatMax(f32);
    cfg.RasterizerMultiply = 1.0;
    cfg.RasterizerDensity = 1.0;
    return cfg;
}

const Match = struct { path: [:0]u8, index: c_int };

/// Sem fontconfig: procura em C:\\Windows\\Fonts. Primeiro um arquivo com o nome
/// da família; senão a fonte do sistema do mesmo tipo (Segoe UI, Georgia, Consolas).
fn resolveWindows(name: []const u8, weight: c_int, slant: c_int) ?Match {
    const windir = if (c.SDL_getenv("WINDIR")) |w| std.mem.span(w) else "C:/Windows";
    const italic = slant != 0;
    const bold = weight >= 200;
    const semi = weight >= 180 and !bold;
    var lower: [64]u8 = undefined;
    var n: usize = 0;
    for (name) |ch| {
        if (ch == ' ' or n == lower.len) continue;
        lower[n] = std.ascii.toLower(ch);
        n += 1;
    }
    const low = lower[0..n];
    const has = struct {
        fn f(s: []const u8, words: []const []const u8) bool {
            for (words) |w| if (std.mem.indexOf(u8, s, w) != null) return true;
            return false;
        }
    }.f;
    const emoji: []const []const u8 = &.{ "seguiemj", "seguisym" };
    const symbols: []const []const u8 = &.{ "seguisym", "arial" };
    const mono: []const []const u8 = if (bold) &.{ "consolab", "courbd" } else if (italic) &.{ "consolai", "couri" } else &.{ "consola", "cour" };
    const serif: []const []const u8 = if (bold) &.{ "georgiab", "timesbd" } else if (italic) &.{ "georgiai", "timesi" } else &.{ "georgia", "times" };
    const sans: []const []const u8 = if (bold) &.{ "segoeuib", "arialbd", "tahomabd", "tahoma" } else if (semi) &.{ "seguisb", "segoeuib", "arialbd", "tahoma" } else if (italic) &.{ "segoeuii", "ariali", "tahoma" } else &.{ "segoeui", "arial", "tahoma" };
    const family = if (std.mem.eql(u8, low, "emoji")) emoji else if (has(low, &.{"dejavusans"})) symbols else if (has(low, &.{ "mono", "code", "consol", "courier", "term" })) mono else if (has(low, &.{ "serif", "georgia", "times", "garamond", "playfair" }) and !has(low, &.{"sans"})) serif else sans;
    var pb: [300]u8 = undefined;
    const exact = std.fmt.bufPrintSentinel(&pb, "{s}/Fonts/{s}.ttf", .{ windir, low }, 0) catch return null;
    if (sys.exists(exact.ptr)) return .{ .path = std.heap.c_allocator.dupeSentinel(u8, exact, 0) catch return null, .index = 0 };
    for (family) |file| {
        const p = std.fmt.bufPrintSentinel(&pb, "{s}/Fonts/{s}.ttf", .{ windir, file }, 0) catch continue;
        if (sys.exists(p.ptr)) return .{ .path = std.heap.c_allocator.dupeSentinel(u8, p, 0) catch return null, .index = 0 };
    }
    return null;
}

/// Pergunta ao fontconfig qual arquivo atende família + peso + inclinação.
fn resolve(name: []const u8, weight: c_int, slant: c_int) ?Match {
    if (sys.windows) return resolveWindows(name, weight, slant);
    var buf: [128]u8 = undefined;
    const zname = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return null;
    const pat = c.FcPatternCreate() orelse return null;
    defer c.FcPatternDestroy(pat);
    _ = c.FcPatternAddString(pat, c.FC_FAMILY, zname.ptr);
    _ = c.FcPatternAddInteger(pat, c.FC_WEIGHT, weight);
    _ = c.FcPatternAddInteger(pat, c.FC_SLANT, slant);
    if (std.mem.eql(u8, name, "emoji")) _ = c.FcPatternAddBool(pat, c.FC_COLOR, c.FcTrue);
    _ = c.FcConfigSubstitute(null, pat, c.FcMatchPattern);
    c.FcDefaultSubstitute(pat);
    var result: c.FcResult = undefined;
    const m = c.FcFontMatch(null, pat, &result) orelse return null;
    defer c.FcPatternDestroy(m);
    var file: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(m, c.FC_FILE, 0, &file) != c.FcResultMatch) return null;
    var index: c_int = 0;
    _ = c.FcPatternGetInteger(m, c.FC_INDEX, 0, &index);
    const path = std.heap.c_allocator.dupeSentinel(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file))), 0) catch return null;
    return .{ .path = path, .index = index };
}
