//! Valores das configurações. Todas têm efeito de verdade (o que ainda não
//! existe não aparece aqui até existir).
//! São salvos em ~/.config/larpercord/settings.kdl.
const std = @import("std");
const L = @import("../core/lsp.zig");

pub const Page = enum {
    conta,
    privacidade,
    filtros,
    aparencia,
    acessibilidade,
    chat,
    voz,
    notificacoes,
    atalhos,
    idioma,
    avancado,
    desempenho,
    lsp,
    plugins,
    atualizacoes,
    novidades,
    sobre,
};

/// Texto curto salvo nas configurações (o proxy). Tamanho fixo: as
/// configurações são copiadas e comparadas byte a byte.
pub const Text = struct {
    len: u8 = 0,
    buf: [255]u8 = @splat(0),

    pub fn slice(t: *const Text) []const u8 {
        return t.buf[0..t.len];
    }

    pub fn set(t: *Text, s: []const u8) void {
        const n = @min(s.len, t.buf.len);
        t.* = .{};
        @memcpy(t.buf[0..n], s[0..n]);
        t.len = @intCast(n);
    }
};

pub const split_two_default: i16 = 500;
pub const split_three_a_default: i16 = 333;
pub const split_three_b_default: i16 = 667;

pub const Settings = struct {
    open: bool = false,
    page: Page = .aparencia,

    // Aparência / acessibilidade
    font_scale: f32 = 1.12,
    compact: bool = false,
    show_avatars: bool = true,
    reduce_motion: bool = false,
    clock_24h: bool = true,
    show_member_list: bool = true,
    show_status_bar: bool = true,
    underline_links: bool = true,
    role_colors: bool = true,
    /// Status como um anel em volta da foto (em vez da bolinha).
    status_ring: bool = false,
    /// Cor de destaque: 0 = a do tema, 1..8 = as da paleta.
    accent: u8 = 0,
    /// Cantos: 0 = os do tema, 1 = retos, 2 = suaves, 3 = redondos.
    corners: u8 = 0,

    // Chat
    show_spoilers: bool = false,
    autoplay_gifs: bool = true,
    /// Imagens e GIFs que vêm de links (embeds).
    show_embeds: bool = true,
    /// Modo economia: imagens, avatares e anexos só baixam ao clicar.
    data_saver: bool = false,
    /// Prévia do markdown acima da caixa de texto, quando tem formatação.
    md_preview: bool = true,
    /// Canal com não lidas abre na primeira delas, como no Discord (senão, no fim).
    open_at_unread: bool = true,

    // Largura dos painéis (ui/resize.zig): quanto a pessoa alargou em relação ao
    // que o tema pede, em pixels, e as divisas da tela dividida, em milésimos.
    width_channels: i16 = 0,
    width_members: i16 = 0,
    split_two: i16 = split_two_default,
    split_three_a: i16 = split_three_a_default,
    split_three_b: i16 = split_three_b_default,

    /// Pergunta ao GitHub se há versão nova ao abrir o app.
    check_updates: bool = true,

    // Privacidade
    send_typing: bool = true,
    /// Mensagens apagadas ficam na tela (marcadas) e as editadas guardam o
    /// texto original. Só neste computador.
    message_log: bool = false,
    /// GIFs do Tenor/Giphy direto do site deles (eles veem o IP).
    gif_hosts: bool = false,
    /// Esconde o e-mail e o @usuário na conta.
    streamer_mode: bool = false,
    /// Proxy (socks5h://127.0.0.1:9050…): vazio = conexão direta. Só a mídia
    /// de fora passa por ele, ou tudo com `proxy_all` (net/proxy.zig).
    proxy: Text = .{},
    proxy_all: bool = false,
    /// Emojis usados há pouco, do mais novo para o mais velho (ui/emoji_picker.zig).
    emoji_recent: Text = .{},
    /// Últimas mensagens de cada canal em disco (abrir na hora, busca offline).
    message_cache: bool = true,

    /// Nosso status: 0 online, 1 ausente, 2 não perturbe, 3 invisível.
    /// Reaplicado ao conectar.
    my_status: u8 = 0,

    // Notificações (DMs e menções)
    desktop_notifs: bool = true,
    taskbar_flash: bool = true,

    // Voz (net/voz_audio.zig, core/voz.zig)
    /// Nome do microfone e da saída; vazio = padrão do sistema. Se o dispositivo
    /// sumiu, usa o padrão e o nome fica guardado para quando ele voltar.
    voice_mic: Text = .{},
    voice_out: Text = .{},
    /// Volumes em % (0..200).
    voice_in_gain: u8 = 100,
    voice_out_gain: u8 = 100,
    /// Limiar da detecção de voz: posição na barra (0..100; -80..0 dB).
    voice_sens: u8 = 39,
    /// O limiar segue o ruído de fundo em vez de `voice_sens`.
    voice_auto: bool = false,
    /// Aperte para falar, com a tecla ou o botão em `voice_key` ("k:44", "m:4").
    voice_ptt: bool = false,
    voice_key: Text = .{},
    voice_highpass: bool = true,
    voice_gate: bool = false,
    /// Supressão de ruído: o número de `core/ruido.zig` Mode (0 desligada, 1 RNNoise).
    voice_denoise: u8 = 1,
    voice_sounds: bool = true,

    /// Volume dos vídeos em % (0..100; 0 = mudo).
    video_volume: u8 = 100,

    // Erros no código (ui/settings_lsp.zig): uma linguagem de core/lsp.zig `known`
    // em cada par. Tudo desligado por padrão; ligar é sempre a pessoa quem faz.
    lsp_on_zig: bool = false,
    lsp_cmd_zig: Text = .{},
    lsp_on_python: bool = false,
    lsp_cmd_python: Text = .{},
    lsp_on_rust: bool = false,
    lsp_cmd_rust: Text = .{},
    lsp_on_cpp: bool = false,
    lsp_cmd_cpp: Text = .{},
    lsp_on_go: bool = false,
    lsp_cmd_go: Text = .{},
    lsp_on_typescript: bool = false,
    lsp_cmd_typescript: Text = .{},
    lsp_on_lua: bool = false,
    lsp_cmd_lua: Text = .{},
    /// Servidores propostos por plugins que a pessoa liberou (ver `approvalKey`).
    lsp_plugins_ok: Text = .{},

    // Atalhos
    /// Navegação estilo vim com a caixa de texto sem foco (ui/vim.zig).
    vim_keys: bool = false,

    // Avançado
    developer_mode: bool = false,
    hot_reload: bool = true,
    /// Fechar a janela deixa o app na bandeja (sem bandeja, fechar sai igual).
    close_to_tray: bool = true,
    /// 0 = seguir o sistema, 1 = português, 2 = inglês.
    language: u8 = 0,
    /// 0 = escuro, 1 = claro, 2 = seguir o sistema.
    color_mode: u8 = 0,

    /// Os painéis estão como o tema pede?
    pub fn panelsAtDefault(s: *const Settings) bool {
        return s.width_channels == 0 and s.width_members == 0 and s.split_two == split_two_default and
            s.split_three_a == split_three_a_default and s.split_three_b == split_three_b_default;
    }

    pub fn resetPanels(s: *Settings) void {
        s.width_channels = 0;
        s.width_members = 0;
        s.split_two = split_two_default;
        s.split_three_a = split_three_a_default;
        s.split_three_b = split_three_b_default;
    }

    /// Muda quando algo que afeta o layout das mensagens muda.
    pub fn layoutKey(s: *const Settings) u32 {
        var h: u32 = @intFromFloat(s.font_scale * 100);
        h = h *% 31 +% @intFromBool(s.compact);
        h = h *% 31 +% @intFromBool(s.show_avatars);
        h = h *% 31 +% @intFromBool(s.show_embeds);
        // No modo economia, emoji personalizado vira `:nome:` (ui/rich.zig).
        h = h *% 31 +% @intFromBool(s.data_saver);
        return h;
    }
};

/// Volume do slider para o ganho do som. O ouvido é logarítmico: ao quadrado, o
/// meio da barra soa como metade do volume, e não quase igual ao máximo.
pub fn videoGain(volume: u8) f32 {
    const k = @as(f32, @floatFromInt(@min(volume, 100))) / 100;
    return k * k;
}

pub fn lspOn(s: *Settings, i: usize) *bool {
    return switch (i) {
        inline 0...L.known.len - 1 => |k| &@field(s, "lsp_on_" ++ L.known[k].key),
        else => unreachable,
    };
}
pub fn lspOnC(s: *const Settings, i: usize) *const bool {
    return switch (i) {
        inline 0...L.known.len - 1 => |k| &@field(s, "lsp_on_" ++ L.known[k].key),
        else => unreachable,
    };
}
pub fn lspCmd(s: *Settings, i: usize) *Text {
    return switch (i) {
        inline 0...L.known.len - 1 => |k| &@field(s, "lsp_cmd_" ++ L.known[k].key),
        else => unreachable,
    };
}
pub fn lspCmdC(s: *const Settings, i: usize) *const Text {
    return switch (i) {
        inline 0...L.known.len - 1 => |k| &@field(s, "lsp_cmd_" ++ L.known[k].key),
        else => unreachable,
    };
}

/// Alguma linguagem ligada? Falso é o caso comum: o caminho de quem não usa.
pub fn lspAnyOn(s: *const Settings) bool {
    if (s.lsp_plugins_ok.len > 0) return true;
    for (0..L.known.len) |i| if (lspOnC(s, i).*) return true;
    return false;
}

pub const Field = struct { name: []const u8, kind: enum { boolean, float, byte, int, text }, offset: usize };

/// Campos persistidos (todos menos `open` e `page`).
pub fn fields() []const Field {
    const S = struct {
        const list = blk: {
            const info = @typeInfo(Settings).@"struct";
            var out: [info.field_names.len]Field = undefined;
            var n: usize = 0;
            for (info.field_names, info.field_types) |fname, ftype| {
                if (std.mem.eql(u8, fname, "open") or std.mem.eql(u8, fname, "page")) continue;
                // Só estes tipos são salvos byte a byte; outro tipo aqui
                // corromperia o arquivo (ou a memória) ao ler.
                if (ftype != bool and ftype != f32 and ftype != u8 and ftype != i16 and ftype != Text) @compileError("configuração com tipo não suportado: " ++ fname);
                out[n] = .{
                    .name = fname,
                    .kind = if (ftype == bool) .boolean else if (ftype == f32) .float else if (ftype == Text) .text else if (ftype == i16) .int else .byte,
                    .offset = @offsetOf(Settings, fname),
                };
                n += 1;
            }
            const final = out[0..n].*;
            break :blk final;
        };
    };
    return &S.list;
}

/// Lê um campo booleano ou de um byte pelo índice em `fields()` (para a
/// paleta de comandos). Número quebrado ou maior que um byte não tem como ler
/// assim: null.
pub fn getByte(s: *const Settings, index: usize) ?u8 {
    const fs = fields();
    if (index >= fs.len or fs[index].kind == .float or fs[index].kind == .int or fs[index].kind == .text) return null;
    return (@as([*]const u8, @ptrCast(s)) + fs[index].offset)[0];
}

/// Muda um campo booleano (0/1) ou de um byte pelo índice em `fields()`.
pub fn setByte(s: *Settings, index: usize, value: u8) bool {
    const fs = fields();
    if (index >= fs.len) return false;
    const p = @as([*]u8, @ptrCast(s)) + fs[index].offset;
    switch (fs[index].kind) {
        .boolean => @as(*bool, @ptrCast(p)).* = value != 0,
        .byte => p[0] = value,
        .float, .int, .text => return false,
    }
    return true;
}

/// Índice do campo em `fields()` (para tabelas montadas em tempo de compilação).
pub fn fieldIndex(comptime name: []const u8) usize {
    @setEvalBranchQuota(20_000);
    if (!@hasField(Settings, name)) @compileError("configuração inexistente: " ++ name);
    @setEvalBranchQuota(20_000);
    for (fields(), 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return i;
    unreachable;
}

/// Serializa em KDL: `settings theme="vidro" compact=#true font_scale=1.1 …`
pub fn write(s: *const Settings, theme_name: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    try out.print(gpa, "// gerado pelo larperCord\nsettings theme=\"{s}\"", .{theme_name});
    const base: [*]const u8 = @ptrCast(s);
    for (fields()) |f| {
        switch (f.kind) {
            .boolean => try out.print(gpa, " {s}={s}", .{ f.name, if (@as(*const bool, @ptrCast(base + f.offset)).*) "#true" else "#false" }),
            .float => try out.print(gpa, " {s}={d:.3}", .{ f.name, @as(*const f32, @ptrCast(@alignCast(base + f.offset))).* }),
            .byte => try out.print(gpa, " {s}={d}", .{ f.name, (base + f.offset)[0] }),
            .int => try out.print(gpa, " {s}={d}", .{ f.name, @as(*const i16, @ptrCast(@alignCast(base + f.offset))).* }),
            .text => {
                // Comandos têm aspas, e caminhos do Windows têm barras.
                try out.print(gpa, " {s}=\"", .{f.name});
                for (@as(*const Text, @ptrCast(@alignCast(base + f.offset))).slice()) |ch| {
                    if (ch == '"' or ch == '\\') try out.append(gpa, '\\');
                    if (ch >= 0x20) try out.append(gpa, ch);
                }
                try out.append(gpa, '"');
            },
        }
    }
    try out.append(gpa, '\n');
}

pub fn apply(s: *Settings, node: anytype) void {
    const base: [*]u8 = @ptrCast(s);
    for (fields()) |f| {
        switch (f.kind) {
            .boolean => if (node.flag(f.name)) |v| {
                @as(*bool, @ptrCast(base + f.offset)).* = v;
            },
            .float => if (node.num(f.name)) |v| {
                @as(*f32, @ptrCast(@alignCast(base + f.offset))).* = @floatCast(std.math.clamp(v, 0.5, 3));
            },
            .byte => if (node.num(f.name)) |v| {
                (base + f.offset)[0] = @intFromFloat(std.math.clamp(v, 0, 255));
            },
            .int => if (node.num(f.name)) |v| {
                @as(*i16, @ptrCast(@alignCast(base + f.offset))).* = @intFromFloat(std.math.clamp(v, -32768, 32767));
            },
            .text => if (node.str(f.name)) |v| {
                @as(*Text, @ptrCast(@alignCast(base + f.offset))).set(v);
            },
        }
    }
}

test "configurações vão e voltam pelo KDL" {
    const kdl = @import("../theme/kdl.zig");
    var s: Settings = .{};
    s.compact = true;
    s.font_scale = 1.2;
    s.language = 2;
    s.proxy.set("socks5h://127.0.0.1:9050");
    s.emoji_recent.set("😀 ❤️ pepe:12");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try write(&s, "vidro", &out, std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var back: Settings = .{};
    apply(&back, &nodes[0]);
    try std.testing.expect(back.compact);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), back.font_scale, 0.001);
    try std.testing.expectEqual(@as(u8, 2), back.language);
    try std.testing.expectEqualStrings("socks5h://127.0.0.1:9050", back.proxy.slice());
    try std.testing.expectEqualStrings("😀 ❤️ pepe:12", back.emoji_recent.slice());
    try std.testing.expectEqualStrings("vidro", nodes[0].str("theme").?);
}

test "configurações de voz vão e voltam (volume acima de 3x e nome com acento)" {
    const kdl = @import("../theme/kdl.zig");
    var s: Settings = .{};
    s.voice_mic.set("Microfone do headset (USB) ção");
    s.voice_out.set("Saída HDMI");
    s.voice_in_gain = 180;
    s.voice_out_gain = 0;
    s.voice_sens = 12;
    s.voice_auto = true;
    s.voice_ptt = true;
    s.voice_key.set("k:44");
    s.voice_highpass = false;
    s.voice_gate = true;
    s.voice_denoise = 0;
    s.voice_sounds = false;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try write(&s, "vidro", &out, std.testing.allocator);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var back: Settings = .{};
    apply(&back, &nodes[0]);
    try std.testing.expectEqualStrings("Microfone do headset (USB) ção", back.voice_mic.slice());
    try std.testing.expectEqualStrings("Saída HDMI", back.voice_out.slice());
    try std.testing.expectEqual(@as(u8, 180), back.voice_in_gain);
    try std.testing.expectEqual(@as(u8, 0), back.voice_out_gain);
    try std.testing.expectEqual(@as(u8, 12), back.voice_sens);
    try std.testing.expect(back.voice_auto and back.voice_ptt and back.voice_gate);
    try std.testing.expect(!back.voice_highpass and !back.voice_sounds);
    try std.testing.expectEqualStrings("k:44", back.voice_key.slice());
    try std.testing.expectEqual(@as(u8, 0), back.voice_denoise);
    // Arquivo antigo, sem nada disso: os padrões.
    const old = try kdl.parse(arena.allocator(), "settings compact=#true\n", null);
    var fresh: Settings = .{};
    apply(&fresh, &old[0]);
    try std.testing.expectEqual(@as(u8, 100), fresh.voice_in_gain);
    try std.testing.expectEqual(@as(usize, 0), fresh.voice_mic.slice().len);
    try std.testing.expect(fresh.voice_highpass and fresh.voice_sounds and !fresh.voice_ptt);
    try std.testing.expectEqual(@as(u8, 1), fresh.voice_denoise);
}

test "volume dos vídeos e fechar para a bandeja vão e voltam" {
    const kdl = @import("../theme/kdl.zig");
    var s: Settings = .{};
    try std.testing.expect(s.close_to_tray);
    try std.testing.expectEqual(@as(u8, 100), s.video_volume);
    s.video_volume = 35;
    s.close_to_tray = false;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try write(&s, "vidro", &out, std.testing.allocator);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var back: Settings = .{};
    apply(&back, &nodes[0]);
    try std.testing.expectEqual(@as(u8, 35), back.video_volume);
    try std.testing.expect(!back.close_to_tray);
    // Arquivo antigo: os padrões. Volta para a bandeja ligada e som cheio.
    const old = try kdl.parse(arena.allocator(), "settings compact=#true\n", null);
    var fresh: Settings = .{};
    apply(&fresh, &old[0]);
    try std.testing.expect(fresh.close_to_tray);
    try std.testing.expectEqual(@as(u8, 100), fresh.video_volume);
}

test "largura dos painéis vai e volta, e um arquivo editado à mão não estoura" {
    const kdl = @import("../theme/kdl.zig");
    var s: Settings = .{};
    s.width_channels = 90;
    s.width_members = -40;
    s.split_two = 620;
    s.split_three_a = 250;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try write(&s, "vidro", &out, std.testing.allocator);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var back: Settings = .{};
    apply(&back, &nodes[0]);
    try std.testing.expectEqual(@as(i16, 90), back.width_channels);
    try std.testing.expectEqual(@as(i16, -40), back.width_members);
    try std.testing.expectEqual(@as(i16, 620), back.split_two);
    try std.testing.expectEqual(@as(i16, 250), back.split_three_a);
    try std.testing.expectEqual(split_three_b_default, back.split_three_b);
    // Número fora do que cabe vira o maior que cabe (a tela limita depois).
    const big = try kdl.parse(arena.allocator(), "settings width_channels=999999 width_members=-999999\n", null);
    var fresh: Settings = .{};
    apply(&fresh, &big[0]);
    try std.testing.expectEqual(@as(i16, 32767), fresh.width_channels);
    try std.testing.expectEqual(@as(i16, -32768), fresh.width_members);
    // Arquivo antigo: como o tema pede.
    const old = try kdl.parse(arena.allocator(), "settings compact=#true\n", null);
    var older: Settings = .{};
    apply(&older, &old[0]);
    try std.testing.expectEqual(@as(i16, 0), older.width_channels);
    try std.testing.expectEqual(split_two_default, older.split_two);
}

test "ganho do vídeo: mudo em 0, cheio em 100, e um arquivo editado à mão não estoura" {
    try std.testing.expectEqual(@as(f32, 0), videoGain(0));
    try std.testing.expectEqual(@as(f32, 1), videoGain(100));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), videoGain(50), 0.001);
    try std.testing.expectEqual(@as(f32, 1), videoGain(255));
}

test "comandos de LSP vão e voltam, com aspas e barras" {
    const kdl = @import("../theme/kdl.zig");
    var s: Settings = .{};
    try std.testing.expect(!lspAnyOn(&s));
    s.lsp_on_python = true;
    s.lsp_cmd_python.set("\"/opt/meu servidor/ruff\" server");
    s.lsp_cmd_zig.set("C:\\tools\\zls.exe --flag");
    s.lsp_plugins_ok.set("0123456789abcdef");
    try std.testing.expect(lspAnyOn(&s));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try write(&s, "vidro", &out, std.testing.allocator);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var back: Settings = .{};
    apply(&back, &nodes[0]);
    try std.testing.expect(back.lsp_on_python and !back.lsp_on_zig);
    try std.testing.expectEqualStrings("\"/opt/meu servidor/ruff\" server", back.lsp_cmd_python.slice());
    try std.testing.expectEqualStrings("C:\\tools\\zls.exe --flag", back.lsp_cmd_zig.slice());
    try std.testing.expectEqualStrings("0123456789abcdef", back.lsp_plugins_ok.slice());
    // Cada linguagem conhecida tem o seu par de campos, e o padrão é desligado.
    var fresh: Settings = .{};
    for (0..L.known.len) |i| {
        try std.testing.expect(!lspOn(&fresh, i).*);
        try std.testing.expectEqual(@as(usize, 0), lspCmd(&fresh, i).slice().len);
    }
}

test "campos pelo índice (paleta de comandos)" {
    var s: Settings = .{};
    const i = fieldIndex("compact");
    try std.testing.expectEqual(@as(?u8, 0), getByte(&s, i));
    try std.testing.expect(setByte(&s, i, 1));
    try std.testing.expect(s.compact);
    try std.testing.expect(setByte(&s, fieldIndex("color_mode"), 2));
    try std.testing.expectEqual(@as(u8, 2), s.color_mode);
    try std.testing.expect(!setByte(&s, fieldIndex("font_scale"), 1));
    try std.testing.expect(!s.vim_keys and s.md_preview);
}
