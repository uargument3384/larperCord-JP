//! Tela de entrada: a logo se monta, o fundo respira e o cartão pede o token.
//! Também é a tela de abertura enquanto conecta com um token salvo, e some
//! num esmaecimento quando o READY chega.
//!
//! Tudo é desenhado aqui mesmo (sem tema): é a cara do app, igual em todos
//! os temas, só respeitando claro/escuro e "reduzir movimento".
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const logo = @import("logo.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const accounts_mod = @import("../core/accounts.zig");

const Rgba = d.Rgba;
const Rect = d.Rect;

pub const Phase = enum { hidden, form, connecting, leaving };

/// `back`: "Voltar" (adicionando outra conta, ou depois de sair de uma).
pub const Result = enum { submit, demo, cancel, back, pick };

/// Contas guardadas que cabem no cartão.
pub const max_accounts = 4;

pub const Login = struct {
    phase: Phase = .hidden,
    /// Relógio da tela (segundos desde que apareceu).
    t: f32 = 0,
    phase_at: f32 = 0,
    token: [256]u8 = @splat(0),
    show: bool = false,
    remember: bool = true,
    help: bool = false,
    err_buf: [200]u8 = undefined,
    err_len: usize = 0,
    err_at: f32 = -10,
    want_focus: bool = true,
    /// Texto do "Voltar" no topo do cartão (vazio = sem). Ex.: "Voltar para ana".
    back_buf: [96]u8 = undefined,
    back_len: usize = 0,
    /// Contas guardadas deste quadro e a escolhida (com `Result.pick`).
    accounts: []const *const accounts_mod.Account = &.{},
    picked: @import("../core/types.zig").Id = 0,
    /// Valores suavizados entre quadros.
    look: [2]f32 = .{ 0, 0 },
    card_h: f32 = 0,
    help_k: f32 = 0,
    show_k: f32 = 0,
    remember_k: f32 = 1,
    focus_k: f32 = 0,

    pub fn visible(l: *const Login) bool {
        return l.phase != .hidden;
    }

    pub fn begin(l: *Login, phase: Phase) void {
        l.* = .{ .phase = phase, .remember = l.remember };
    }

    pub fn setPhase(l: *Login, phase: Phase) void {
        l.phase = phase;
        l.phase_at = l.t;
        if (phase == .form) l.want_focus = true;
    }

    /// O Discord recusou (ou a conexão falhou de vez): volta ao formulário.
    pub fn fail(l: *Login, msg: []const u8) void {
        if (l.phase == .hidden) l.t = 10; // veio direto do token salvo: sem a abertura
        l.setPhase(.form);
        const n = @min(msg.len, l.err_buf.len);
        @memcpy(l.err_buf[0..n], msg[0..n]);
        l.err_len = n;
        l.err_at = l.t;
    }

    pub fn setBack(l: *Login, label: []const u8) void {
        const n = @min(label.len, l.back_buf.len);
        @memcpy(l.back_buf[0..n], label[0..n]);
        l.back_len = n;
    }

    pub fn tokenText(l: *const Login) []const u8 {
        return std.mem.trim(u8, std.mem.sliceTo(&l.token, 0), " \t\r\n\"");
    }

    pub fn clearToken(l: *Login) void {
        std.crypto.secureZero(u8, &l.token);
    }

    fn err(l: *const Login) []const u8 {
        return l.err_buf[0..l.err_len];
    }
};

pub const Env = struct {
    ui: *d.Family,
    io: *c.ImGuiIO,
    light: bool,
    reduce: bool,
    /// Segundos desde o último quadro (fixo ao gravar a animação).
    dt: f32,
    accounts: []const *const accounts_mod.Account = &.{},
};

// --- Cores ---------------------------------------------------------------------

/// Neutra de propósito: a cor da marca fica só no mascote e em detalhes
/// (foco, interruptor). Nada de degradê no fundo nem no botão.
const Pal = struct {
    bg: Rgba,
    card: Rgba,
    card_border: Rgba,
    field: Rgba,
    field_border: Rgba,
    text: Rgba,
    muted: Rgba,
    faint: Rgba,
    danger: Rgba,
    /// Pontos da grade do fundo.
    dot: Rgba,
    /// Botão principal (sólido) e o texto dele.
    primary: Rgba,
    on_primary: Rgba,
    /// Detalhe de cor: foco do campo, interruptor, links.
    accent: Rgba,
    link: Rgba,
};

const dark: Pal = .{
    .bg = Rgba.hex(0x0A0A0C),
    .card = Rgba.hex(0x111114),
    .card_border = Rgba.hex(0x232329),
    .field = Rgba.hex(0x0B0B0E),
    .field_border = Rgba.hex(0x2A2A31),
    .text = Rgba.hex(0xEDEDEF),
    .muted = Rgba.hex(0xA0A0AB),
    .faint = Rgba.hex(0x66666F),
    .danger = Rgba.hex(0xF2555A),
    .dot = Rgba.white,
    .primary = Rgba.hex(0xEDEDEF),
    .on_primary = Rgba.hex(0x0A0A0C),
    .accent = Rgba.hex(0x8B5CF6),
    .link = Rgba.hex(0xB9A4F8),
};

const light: Pal = .{
    .bg = Rgba.hex(0xFAFAFA),
    .card = Rgba.white,
    .card_border = Rgba.hex(0xE4E4E7),
    .field = Rgba.hex(0xFAFAFA),
    .field_border = Rgba.hex(0xD4D4D8),
    .text = Rgba.hex(0x18181B),
    .muted = Rgba.hex(0x52525B),
    .faint = Rgba.hex(0x8E8E96),
    .danger = Rgba.hex(0xDC2626),
    .dot = Rgba.black,
    .primary = Rgba.hex(0x18181B),
    .on_primary = Rgba.white,
    .accent = Rgba.hex(0x7C3AED),
    .link = Rgba.hex(0x6D28D9),
};

// --- Curvas de animação ------------------------------------------------------

fn seg(t: f32, a: f32, b: f32) f32 {
    return std.math.clamp((t - a) / (b - a), 0, 1);
}
fn outCubic(x: f32) f32 {
    const u = 1 - x;
    return 1 - u * u * u;
}
fn outBack(x: f32, s: f32) f32 {
    const u = x - 1;
    return 1 + (s + 1) * u * u * u + s * u * u;
}
fn hash(i: usize, salt: u64) f32 {
    const h = std.hash.Wyhash.hash(salt, std.mem.asBytes(&i));
    return @as(f32, @floatFromInt(h & 0xffff)) / 65535.0;
}

// --- Interação -----------------------------------------------------------------

const Hit = struct { hovered: bool, clicked: bool, held: bool };

fn hit(id: usize, r: Rect) Hit {
    c.ImGui_SetCursorScreenPos(d.v(r.x, r.y));
    c.ImGui_PushIDInt(@intCast(id));
    const clicked = c.ImGui_InvisibleButton("##l", d.v(@max(r.w, 1), @max(r.h, 1)), c.ImGuiButtonFlags_MouseButtonLeft);
    const hovered = c.ImGui_IsItemHovered(0);
    const held = c.ImGui_IsItemActive();
    c.ImGui_PopID();
    if (hovered) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    return .{ .hovered = hovered, .clicked = clicked, .held = held };
}

// --- Desenho -------------------------------------------------------------------

const Frame = struct {
    l: *Login,
    env: Env,
    dl: *c.ImDrawList,
    win: Rect,
    p: Pal,
    /// Alpha geral (o esmaecimento da saída).
    a: f32,
    mouse: c.ImVec2,

    fn font(f: *const Frame, w: d.Weight) *c.ImFont {
        return f.env.ui.get(w);
    }

    fn text(f: *const Frame, w: d.Weight, size: f32, x: f32, y: f32, col: Rgba, s: []const u8) void {
        d.text(f.dl, f.font(w), size, x, y, col.alpha(f.a), s);
    }

    fn width(f: *const Frame, w: d.Weight, size: f32, s: []const u8) f32 {
        return d.width(f.font(w), size, s);
    }

    fn centered(f: *const Frame, w: d.Weight, size: f32, cx: f32, y: f32, col: Rgba, s: []const u8) void {
        f.text(w, size, cx - f.width(w, size, s) / 2, y, col, s);
    }
};

pub fn draw(l: *Login, env: Env) ?Result {
    if (l.phase == .hidden) return null;
    l.accounts = env.accounts;
    l.t += if (env.reduce) 10 else env.dt;
    if (env.reduce and l.phase == .leaving) l.phase_at = l.t - 10;

    const vp = c.ImGui_GetMainViewport();
    c.ImGui_SetNextWindowPos(vp.*.Pos, 0);
    c.ImGui_SetNextWindowSize(vp.*.Size, 0);
    // Na saída o app já está por baixo: a janela não pode roubar o mouse.
    const pass_through: c_int = if (l.phase == .leaving) c.ImGuiWindowFlags_NoInputs else 0;
    _ = c.ImGui_Begin("##login", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_NoScrollWithMouse |
        c.ImGuiWindowFlags_NoNav | pass_through);
    defer c.ImGui_End();

    const leave_k = if (l.phase == .leaving) seg(l.t, l.phase_at, l.phase_at + 0.75) else 0;
    if (l.phase == .leaving and leave_k >= 1) {
        l.phase = .hidden;
        return null;
    }
    var f: Frame = .{
        .l = l,
        .env = env,
        .dl = c.ImGui_GetWindowDrawList(),
        .win = .{ .x = vp.*.Pos.x, .y = vp.*.Pos.y, .w = vp.*.Size.x, .h = vp.*.Size.y },
        .p = if (env.light) light else dark,
        .a = 1 - leave_k * leave_k,
        .mouse = env.io.*.MousePos,
    };
    const t = l.t;

    background(&f);

    // Disposição: lado a lado na janela larga, empilhado na estreita.
    const W = f.win.w;
    const H = f.win.h;
    const wide = W >= 940 and H >= 540;
    const card_w: f32 = @min(404, W - 32);
    var logo_size: f32 = undefined;
    var hero_cx: f32 = undefined;
    var hero_cy: f32 = undefined;
    var card_x: f32 = undefined;
    var card_y: f32 = undefined;
    const ch = if (l.card_h > 0) l.card_h else 420;
    if (wide) {
        logo_size = std.math.clamp(H * 0.42, 220, 360);
        hero_cx = f.win.x + W * 0.31;
        hero_cy = f.win.y + H * 0.46 - 40;
        card_x = f.win.x + @max(W * 0.69 - card_w / 2, hero_cx + 230);
        card_y = f.win.y + @max(16, (H - ch) / 2);
    } else {
        // Estreita: logo e nome lado a lado no topo, cartão embaixo.
        logo_size = 84;
        const lock_w = logo_size + 8 + f.width(.bold, 34, "larperCord");
        hero_cx = f.win.x + (W - lock_w) / 2 + logo_size / 2;
        hero_cy = f.win.y + 22 + logo_size * 0.375;
        card_x = f.win.x + (W - card_w) / 2;
        card_y = f.win.y + @max(logo_size * 0.75 + 44, (H - ch) / 2 + 30);
    }

    // --- Logo -------------------------------------------------------------
    var pose: logo.Pose = .{
        .body = outBack(seg(t, 0.12, 0.72), 2.4),
        // Chega de olhos fechados e "acorda" com a cara de deboche.
        .eyes = outBack(seg(t, 0.95, 1.2), 2),
        .smile = outCubic(seg(t, 1.1, 1.4)),
        .star = outBack(seg(t, 0.7, 1.05), 3) * (1 + 0.07 * @sin(t * 3.1)),
        .spin = (1 - outCubic(seg(t, 0.7, 1.2))) * -2.6 + 0.1 * @sin(t * 0.9),
        .alpha = f.a,
    };
    // Piscadas (às vezes duas seguidas).
    if (t > 3) {
        const period: f32 = 3.7;
        const cyc = @floor((t - 3) / period);
        const ph = (t - 3) - cyc * period;
        const blink = struct {
            fn at(x: f32) f32 {
                return if (x >= 0 and x <= 0.16) @sin(std.math.pi * x / 0.16) else 0;
            }
        }.at;
        var b = blink(ph);
        if (@mod(cyc, 3) == 1) b = @max(b, blink(ph - 0.26));
        pose.eyes *= 1 - b;
    }
    // Para onde olha: o mouse; o campo do token enquanto digita; de um lado
    // pro outro enquanto conecta; para baixo quando dá erro.
    const lc = d.v(hero_cx, hero_cy);
    var want: [2]f32 = .{
        std.math.clamp((f.mouse.x - lc.x) / (W * 0.4), -1, 1),
        std.math.clamp((f.mouse.y - lc.y) / (H * 0.4), -1, 1),
    };
    if (f.l.focus_k > 0.5 and l.phase == .form) want = .{ if (wide) 1 else 0, if (wide) 0.3 else 1 };
    if (l.phase == .connecting) want = .{ @sin(t * 2.2), -0.4 };
    if (t - l.err_at < 1.6) want = .{ 0, 1 };
    if (f.mouse.x < -1000) want = .{ 0, 0 };
    l.look[0] = anim.step(l.look[0], want[0], 9);
    l.look[1] = anim.step(l.look[1], want[1], 9);
    pose.look = l.look;
    pose.glow = 0.3 + 0.05 * @sin(t * 2.0);

    var bob = if (t > 1.4) @sin((t - 1.4) * 1.6) * 5 else 0;
    var shake: f32 = 0;
    const since_err = t - l.err_at;
    if (since_err < 0.7) shake = @sin(since_err * 42) * 9 * @exp(-since_err * 5);
    if (l.phase == .connecting) bob += @sin(t * 4) * 2;
    const zoom = 1 + 0.18 * outCubic(leave_k);
    logo.draw(f.dl, hero_cx + shake * 0.6, hero_cy + bob, logo_size * zoom, pose);

    // --- Nome e frase ---------------------------------------------------------
    if (wide) {
        const word_y = hero_cy + logo_size * 0.375 + 14;
        wordmark(&f, hero_cx, word_y, 50);
        const tag_k = outCubic(seg(t, 1.35, 1.8));
        f.centered(.medium, 17, hero_cx, word_y + 50 * 1.25 + (1 - tag_k) * 8, f.p.muted.alpha(tag_k), i18n.tr("o Discord leve, nativo e do seu jeito", "a light, native Discord, your way"));
    } else {
        const ww = f.width(.bold, 34, "larperCord");
        wordmark(&f, hero_cx + logo_size / 2 + 10 + ww / 2, hero_cy - 34 * 0.62, 34);
    }

    // --- Cartão ----------------------------------------------------------------
    const card_k = outCubic(seg(t, 1.2, 1.9));
    if (card_k <= 0.001) return null;
    const cr: Rect = .{ .x = card_x + shake, .y = card_y + (1 - card_k) * 28 + leave_k * 24, .w = card_w, .h = ch };
    const ca = card_k * f.a;
    d.shadow(f.dl, cr, 14, 18, Rgba.black.alpha((if (env.light) @as(f32, 0.06) else 0.4) * ca));
    d.rect(f.dl, cr, f.p.card.alpha(ca), 14);
    d.border(f.dl, cr, f.p.card_border.alpha(ca), 14, 1);

    const saved_a = f.a;
    f.a = ca;
    defer f.a = saved_a;
    const inner_x = cr.x + 32;
    const inner_w = cr.w - 64;
    const result: ?Result = switch (l.phase) {
        .form, .leaving => form(&f, inner_x, cr.y + 30, inner_w),
        .connecting => connecting(&f, inner_x, cr.y + 30, inner_w),
        .hidden => null,
    };

    // Rodapé, embaixo do cartão.
    const foot_k = outCubic(seg(t, 1.7, 2.3)) * f.a;
    const foot_y = cr.bottom() + 18;
    const fcx = cr.x + cr.w / 2;
    // Sem espaço embaixo do cartão: o aviso não pode cobrir os botões.
    f.a = if (foot_y + 34 > f.win.bottom()) 0 else foot_k;
    f.centered(.regular, 12, fcx, foot_y, f.p.faint, i18n.tr("cliente não oficial · vai contra os Termos do Discord, use por sua conta e risco", "unofficial client · against Discord's Terms of Service, use at your own risk"));
    f.centered(.regular, 12, fcx, foot_y + 17, f.p.faint, i18n.tr("o token fica neste computador e só é enviado ao próprio Discord", "your token stays on this computer and is only ever sent to Discord"));
    return result;
}

fn background(f: *Frame) void {
    const dl = f.dl;
    const r = f.win;
    const t = f.l.t;
    const intro = outCubic(seg(t, 0, 0.8));
    const a = f.a;
    d.rect(dl, r, f.p.bg.alpha(a), 0);
    // Uma luz neutra e larga atrás do mascote, só para o fundo não ficar chapado.
    logo.glow(dl, r.x + r.w * 0.5, r.y - r.h * 0.1, r.w * 0.75, r.h * 0.75, f.p.dot.alpha((if (f.env.light) @as(f32, 0.025) else 0.045) * intro * a));

    // Grade de pontos que acende em volta do mouse.
    const gap: f32 = 26;
    const base_a: f32 = if (f.env.light) 0.09 else 0.07;
    const spot: f32 = 240;
    const has_mouse = f.mouse.x > -1000;
    var y = r.y + @mod(gap / 2, gap);
    while (y < r.bottom()) : (y += gap) {
        var x = r.x + gap / 2;
        while (x < r.right()) : (x += gap) {
            var k = base_a;
            if (has_mouse) {
                const dx = x - f.mouse.x;
                const dy = y - f.mouse.y;
                const dist = @sqrt(dx * dx + dy * dy);
                if (dist < spot) {
                    const near = 1 - dist / spot;
                    k += near * near * 0.28;
                }
            }
            // As bordas somem (vinheta só na grade).
            const ex = @min(x - r.x, r.right() - x) / (r.w * 0.18);
            const ey = @min(y - r.y, r.bottom() - y) / (r.h * 0.18);
            k *= std.math.clamp(@min(ex, ey), 0, 1);
            if (k > 0.004) c.ImDrawList_AddRectFilled(dl, d.v(x - 0.75, y - 0.75), d.v(x + 0.75, y + 0.75), f.p.dot.col(k * intro * a));
        }
    }
}

/// "larperCord" letra por letra, subindo; "Cord" no degradê da marca.
fn wordmark(f: *Frame, cx: f32, y: f32, size: f32) void {
    const word = "larperCord";
    const fb = f.font(.bold);
    const total = f.width(.bold, size, word) - size * 0.02 * 9;
    var x = cx - total / 2;
    for (word, 0..) |ch, i| {
        const k = outCubic(seg(f.l.t, 0.9 + @as(f32, @floatFromInt(i)) * 0.045, 1.25 + @as(f32, @floatFromInt(i)) * 0.045));
        const s = word[i .. i + 1];
        const cw = d.width(fb, size, s);
        if (k > 0.001) {
            d.text(f.dl, fb, size, x, y + (1 - k) * 16, f.p.text.alpha(k * f.a), s);
        }
        _ = ch;
        x += cw - size * 0.02;
    }
}

fn form(f: *Frame, x: f32, y0: f32, w: f32) ?Result {
    const l = f.l;
    const dl = f.dl;
    var result: ?Result = null;
    var y = y0;

    // Voltar (para a conta aberta ou uma guardada).
    if (l.back_len > 0) {
        const label = l.back_buf[0..l.back_len];
        const lw = f.width(.medium, 13.5, label) + 22;
        const br: Rect = .{ .x = x - 6, .y = y - 6, .w = @min(lw + 12, w + 12), .h = 26 };
        const hb = hit(36, br);
        qa.mark(br, "login:voltar", .{});
        if (hb.clicked or c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) result = .back;
        if (hb.hovered) d.rect(dl, br, f.p.text.alpha(0.06 * f.a), 6);
        const col = if (hb.hovered) f.p.text else f.p.muted;
        const ay = br.y + br.h / 2;
        d.line(dl, x, ay, x + 9, ay, col.alpha(f.a), 1.6);
        d.line(dl, x, ay, x + 4, ay - 4, col.alpha(f.a), 1.6);
        d.line(dl, x, ay, x + 4, ay + 4, col.alpha(f.a), 1.6);
        _ = d.textClipped(dl, f.font(.medium), 13.5, x + 16, d.centerY(br, 13.5), col.alpha(f.a), label, w - 16);
        y += 34;
    }

    f.text(.semibold, 24, x, y, f.p.text, i18n.tr("Entrar", "Sign in"));
    y += 36;
    // Contas guardadas: um clique, sem token nenhum na tela.
    for (l.accounts, 0..) |a, i| {
        const row: Rect = .{ .x = x, .y = y, .w = w, .h = 44 };
        const hr = hit(40 + i, row);
        qa.mark(row, "login:conta:{d}", .{a.id});
        if (hr.clicked) {
            l.picked = a.id;
            result = .pick;
        }
        d.rect(dl, row, f.p.text.alpha((if (hr.hovered) @as(f32, 0.08) else 0.04) * f.a), 8);
        d.border(dl, row, f.p.field_border.alpha(f.a), 8, 1);
        d.circle(dl, x + 22, y + 22, 13, f.p.primary.alpha(f.a));
        const name = a.name();
        const first = if (name.len > 0) name[0..@min(name.len, std.unicode.utf8ByteSequenceLength(name[0]) catch 1)] else "?";
        f.centered(.bold, 13, x + 22, y + 22 - 8, f.p.on_primary, first);
        var b: [96]u8 = undefined;
        _ = d.textClipped(dl, f.font(.medium), 14, x + 44, d.centerY(row, 14), f.p.text.alpha(f.a), i18n.fmt(&b, "Entrar como {s}", "Sign in as {s}", .{name}), w - 56);
        y += row.h + 8;
    }
    if (l.accounts.len > 0) y += 6;
    f.text(.regular, 14.5, x, y, f.p.muted, if (l.accounts.len > 0) i18n.tr("Ou cole o token de outra conta.", "Or paste the token of another account.") else i18n.tr("Cole o token da sua conta do Discord pra começar.", "Paste your Discord account token to get started."));
    y += 26;

    // Antes de colar: quem corre o risco é a conta de quem usa.
    d.circle(dl, x + 6, y + 8, 6, f.p.danger.alpha(f.a));
    f.text(.bold, 10, x + 3.5, y + 1.5, f.p.card, "!");
    f.text(.regular, 12.5, x + 18, y, f.p.muted, i18n.tr("Use uma conta secundária: o Discord pode", "Use a secondary account: Discord can"));
    f.text(.regular, 12.5, x + 18, y + 17, f.p.muted, i18n.tr("desativar contas em clientes de terceiros.", "disable accounts on third-party clients."));
    y += 46;

    // Campo do token.
    f.text(.medium, 13, x, y, f.p.text, "Token");
    y += 22;
    const fr: Rect = .{ .x = x, .y = y, .w = w, .h = 46 };
    qa.mark(fr, "login:token", .{});
    const has_err = l.err_len > 0;
    d.rect(dl, fr, f.p.field.alpha(f.a), 8);
    // Borda: cor de destaque com o foco, mais um anel suave por fora.
    const idle_col = if (has_err) f.p.danger else f.p.field_border;
    const focus_col = if (has_err) f.p.danger else f.p.accent;
    d.border(dl, fr, idle_col.mix(focus_col, l.focus_k).alpha(f.a), 8, 1);
    if (l.focus_k > 0.01) d.border(dl, fr.inset(-3, -3), focus_col.alpha(0.22 * l.focus_k * f.a), 11, 3);
    lockIcon(dl, fr.x + 20, fr.y + fr.h / 2, (if (l.focus_k > 0.5) f.p.muted else f.p.faint).alpha(f.a));

    // Botões dentro do campo: colar (vazio) e mostrar/ocultar.
    const eye_r: Rect = .{ .x = fr.right() - 42, .y = fr.y + 5, .w = 36, .h = 36 };
    const empty = l.tokenText().len == 0;
    const paste_label = i18n.tr("Colar", "Paste");
    const paste_w = f.width(.semibold, 12.5, paste_label) + 20;
    const paste_r: Rect = .{ .x = eye_r.x - paste_w - 4, .y = fr.y + 10, .w = paste_w, .h = 26 };

    const tx = fr.x + 40;
    c.ImGui_SetCursorScreenPos(d.v(tx, fr.y + (fr.h - 18) / 2 - 1));
    c.ImGui_PushFontFloat(f.font(.regular), 15);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Text, v4(f.p.text.alpha(f.a)));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_TextDisabled, v4(f.p.faint.alpha(f.a)));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_TextSelectedBg, v4(f.p.accent.alpha(0.35)));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_InputTextCursor, v4(f.p.text));
    c.ImGui_SetNextItemWidth((if (empty) paste_r.x else eye_r.x) - tx - 8);
    if (l.want_focus and l.t > 1.5) {
        c.ImGui_SetKeyboardFocusHere();
        l.want_focus = false;
    }
    const flags = c.ImGuiInputTextFlags_EnterReturnsTrue | (if (l.show) 0 else c.ImGuiInputTextFlags_Password);
    const enter = c.ImGui_InputTextWithHint("##token", i18n.trZ("Cole aqui o seu token", "Paste your token here").ptr, &l.token, l.token.len, flags);
    const focused = c.ImGui_IsItemActive();
    if (c.ImGui_IsItemEdited()) l.err_len = 0;
    c.ImGui_PopStyleColorEx(4);
    c.ImGui_PopFont();
    l.focus_k = anim.step(l.focus_k, if (focused) 1 else 0, 14);
    if (enter) result = .submit;

    if (empty) {
        const hp = hit(30, paste_r);
        qa.mark(paste_r, "login:colar", .{});
        d.rect(dl, paste_r, f.p.text.alpha((if (hp.hovered) @as(f32, 0.1) else 0.05) * f.a), 6);
        d.border(dl, paste_r, f.p.field_border.alpha(f.a), 6, 1);
        f.text(.medium, 12.5, paste_r.x + 10, d.centerY(paste_r, 12.5), f.p.muted, paste_label);
        if (hp.clicked) paste(l);
    }
    const he = hit(31, eye_r);
    qa.mark(eye_r, "login:mostrar", .{});
    if (he.clicked) l.show = !l.show;
    if (he.hovered) d.rect(dl, eye_r, f.p.text.alpha(0.06 * f.a), 8);
    l.show_k = anim.step(l.show_k, if (l.show) 1 else 0, 18);
    eyeIcon(dl, eye_r.x + 18, eye_r.y + 18, (if (he.hovered) f.p.text else f.p.muted).alpha(f.a), l.show_k);
    y += fr.h;

    // Erro (balança junto com o cartão).
    if (has_err) {
        y += 9;
        d.circle(dl, x + 6, y + 9, 6, f.p.danger.alpha(f.a));
        f.text(.bold, 10, x + 3.5, y + 2.5, f.p.card, "!");
        _ = d.textClipped(dl, f.font(.regular), 13.5, x + 18, y + 1, f.p.danger.alpha(f.a), l.err(), w - 18);
        y += 20;
    }
    y += 16;

    // Lembrar.
    {
        const row: Rect = .{ .x = x, .y = y, .w = w, .h = 26 };
        const hr = hit(32, row);
        qa.mark(row, "login:lembrar", .{});
        if (hr.clicked) l.remember = !l.remember;
        l.remember_k = anim.step(l.remember_k, if (l.remember) 1 else 0, 20);
        const tr: Rect = .{ .x = x, .y = y + 4, .w = 32, .h = 18 };
        d.rect(dl, tr, f.p.field_border.mix(f.p.accent, l.remember_k).alpha(f.a), 9);
        d.circle(dl, tr.x + 9 + 14 * l.remember_k, tr.y + 9, 6.5, Rgba.white.alpha(f.a));
        const remember_label = i18n.tr("Lembrar neste computador", "Remember on this computer");
        f.text(.regular, 14, x + 44, y + 3, f.p.text, remember_label);
        const note = i18n.tr("no chaveiro do sistema", "in the system keyring");
        f.text(.regular, 12.5, x + 44 + f.width(.regular, 14, remember_label) + 8, y + 4.5, f.p.faint, note);
        y += row.h + 22;
    }

    // Entrar.
    {
        const br: Rect = .{ .x = x, .y = y, .w = w, .h = 44 };
        const hb = hit(33, br);
        qa.mark(br, "login:entrar", .{});
        if (hb.clicked) result = .submit;
        const hk = anim.to(anim.id("login-entrar", 0), if (hb.hovered) 1 else 0, 18);
        const fill = f.p.primary.mix(f.p.card, if (hb.held) 0.2 else 0.1 * hk);
        d.rect(dl, br, fill.alpha(f.a), 8);
        const label = i18n.tr("Entrar", "Sign in");
        const lw = f.width(.semibold, 15, label);
        f.text(.semibold, 15, br.x + (br.w - lw) / 2 - 9, d.centerY(br, 15), f.p.on_primary, label);
        // Setinha que anda um pouco no hover.
        const ax = br.x + (br.w + lw) / 2 + 1 + 3 * hk;
        const ay = br.y + br.h / 2;
        const ac = f.p.on_primary.alpha(f.a);
        d.line(dl, ax, ay, ax + 11, ay, ac, 1.6);
        d.line(dl, ax + 6.5, ay - 4.5, ax + 11.3, ay + 0.4, ac, 1.6);
        d.line(dl, ax + 6.5, ay + 4.5, ax + 11.3, ay - 0.4, ac, 1.6);
        y += br.h + 18;
    }

    // ou
    {
        const ou = i18n.tr("ou", "or");
        const ow = f.width(.semibold, 12, ou);
        const my = y + 8;
        d.line(dl, x, my, x + w / 2 - ow / 2 - 12, my, f.p.card_border.alpha(f.a * 1.4), 1);
        d.line(dl, x + w / 2 + ow / 2 + 12, my, x + w, my, f.p.card_border.alpha(f.a * 1.4), 1);
        f.centered(.regular, 12, x + w / 2, y, f.p.faint, ou);
        y += 30;
    }

    // Demonstração.
    {
        const br: Rect = .{ .x = x, .y = y, .w = w, .h = 44 };
        const hb = hit(34, br);
        qa.mark(br, "login:demo", .{});
        if (hb.clicked) result = .demo;
        d.rect(dl, br, f.p.text.alpha((if (hb.hovered) @as(f32, 0.06) else 0) * f.a), 8);
        d.border(dl, br, f.p.field_border.alpha(f.a), 8, 1);
        const label = i18n.tr("Explorar o modo demonstração", "Explore the demo");
        f.centered(.medium, 14.5, x + w / 2, d.centerY(br, 14.5), f.p.text, label);
        y += br.h + 18;
    }

    // Ajuda.
    {
        const label = if (l.help) i18n.tr("Esconder a ajuda", "Hide help") else i18n.tr("Onde encontro o meu token?", "Where do I find my token?");
        const lw = f.width(.semibold, 13.5, label);
        const lr: Rect = .{ .x = x + (w - lw) / 2 - 6, .y = y - 3, .w = lw + 12, .h = 24 };
        const hh = hit(35, lr);
        qa.mark(lr, "login:ajuda", .{});
        if (hh.clicked) l.help = !l.help;
        const lcol = if (hh.hovered) f.p.text else f.p.muted;
        f.centered(.medium, 13.5, x + w / 2, y, lcol, label);
        if (hh.hovered) d.line(dl, lr.x + 6, y + 19, lr.right() - 6, y + 19, lcol.alpha(f.a), 1);
        y += 28;
        l.help_k = anim.step(l.help_k, if (l.help) 1 else 0, 14);
        if (l.help_k > 0.01) {
            const steps_ja = [_][]const u8{
                "このアプリはDiscord公式クライアントではありません。",
                "アカウントのトークンは非常に重要な認証情報です。",
                "トークンを他人に共有したり、不審な場所へ入力しないでください。",
                "安全性を確認できない場合は、デモモードを利用してください。",
            };
            const steps_pt = [_][]const u8{
                "Este app não é um cliente oficial do Discord.",
                "O token da conta é uma credencial muito importante.",
                "Não compartilhe o token nem o insira em locais suspeitos.",
                "Se não puder verificar a segurança, use o modo demonstração.",
            };
            const steps_en = [_][]const u8{
                "This app is not an official Discord client.",
                "Your account token is highly sensitive authentication data.",
                "Never share it or enter it into untrusted places.",
                "If you cannot verify the app's safety, use demo mode.",
            };
            const steps = if (i18n.ja()) steps_ja else if (i18n.en()) steps_en else steps_pt;
            const full_h: f32 = 4 * 26 + 50;
            const hr: Rect = .{ .x = x, .y = y, .w = w, .h = full_h * l.help_k };
            c.ImDrawList_PushClipRect(dl, d.v(hr.x - 2, hr.y), d.v(hr.right() + 2, hr.bottom()), true);
            d.rect(dl, .{ .x = hr.x, .y = hr.y, .w = hr.w, .h = full_h }, f.p.field.alpha(f.a), 8);
            d.border(dl, .{ .x = hr.x, .y = hr.y, .w = hr.w, .h = full_h }, f.p.card_border.alpha(f.a), 8, 1);
            var hy = hr.y + 12;
            for (steps, 0..) |s, i| {
                const nc = d.v(hr.x + 22, hy + 9);
                c.ImDrawList_AddCircleEx(dl, nc, 9, f.p.field_border.mix(f.p.muted, 0.4).alpha(f.a).u(), 24, 1, 0);
                var nb: [2]u8 = undefined;
                const num = std.fmt.bufPrint(&nb, "{d}", .{i + 1}) catch "";
                f.centered(.semibold, 11, nc.x, nc.y - 7, f.p.muted, num);
                _ = d.textClipped(dl, f.font(.regular), 13, hr.x + 40, hy, f.p.text.alpha(f.a), s, hr.w - 52);
                hy += 26;
            }
            hy += 4;
            _ = d.textClipped(dl, f.font(.medium), 12.5, hr.x + 16, hy, f.p.danger.alpha(f.a), i18n.tr("Quem tem o token tem a sua conta. Não mande pra ninguém.", "Anyone with your token has your account. Never share it."), hr.w - 28);
            c.ImDrawList_PopClipRect(dl);
            y += hr.h + 6;
        }
    }

    y += 22;
    l.card_h = y - y0 + 30;
    return result;
}

fn connecting(f: *Frame, x: f32, y0: f32, w: f32) ?Result {
    const l = f.l;
    const dl = f.dl;
    const t = l.t;
    var result: ?Result = null;
    var y = y0 + 8;
    // Anel girando.
    const cx = x + w / 2;
    const cy = y + 34;
    const rot = t * 5.2;
    const sweep = 1.7 + 0.9 * @sin(t * 2.6);
    c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), 26, f.p.text.alpha(0.08 * f.a).u(), 48, 3, 0);
    c.ImDrawList_PathArcTo(dl, d.v(cx, cy), 26, rot, rot + sweep, 40);
    c.ImDrawList_PathStroke(dl, f.p.text.alpha(f.a).u(), 3, 0);
    y += 86;

    const dots = @as(usize, @intFromFloat(@mod(t * 2.5, 4)));
    var buf: [48]u8 = undefined;
    const title = i18n.fmt(&buf, "Conectando ao Discord{s}", "Connecting to Discord{s}", .{"..."[0..dots]});
    f.text(.bold, 20, cx - f.width(.bold, 20, i18n.tr("Conectando ao Discord...", "Connecting to Discord...")) / 2, y, f.p.text, title);
    y += 32;
    const tips_pt = [_][]const u8{
        "Abrindo a conexão com o gateway",
        "Carregando servidores e mensagens diretas",
        "Arrumando os seus canais",
    };
    const tips_en = [_][]const u8{
        "Opening the gateway connection",
        "Loading servers and direct messages",
        "Getting your channels ready",
    };
    const tips_ja = [_][]const u8{
        "ゲートウェイへの接続を開始しています",
        "サーバーとダイレクトメッセージを読み込んでいます",
        "チャンネルを準備しています",
    };
    const tips = if (i18n.ja()) tips_ja else if (i18n.en()) tips_en else tips_pt;
    const since = t - l.phase_at;
    const tip = tips[@min(tips.len - 1, @as(usize, @intFromFloat(since / 1.6)))];
    f.centered(.regular, 14, cx, y, f.p.muted, tip);
    y += 34;

    // Demorando: oferece as saídas.
    if (since > 7) {
        const k = outCubic(seg(since, 7, 7.5));
        const sa = f.a;
        f.a *= k;
        defer f.a = sa;
        f.centered(.regular, 13, cx, y, f.p.faint, i18n.tr("Está demorando mais que o normal. Confira a internet.", "This is taking longer than usual. Check your connection."));
        y += 30;
        const bw = (w - 12) / 2;
        const r1: Rect = .{ .x = x, .y = y, .w = bw, .h = 40 };
        const r2: Rect = .{ .x = x + bw + 12, .y = y, .w = bw, .h = 40 };
        for ([_]Rect{ r1, r2 }, 0..) |r, i| {
            const hb = hit(40 + i, r);
            qa.mark(r, "login:{s}", .{if (i == 0) "outro" else "demo"});
            d.rect(dl, r, f.p.text.alpha((if (hb.hovered) @as(f32, 0.1) else 0.05) * f.a), 11);
            d.border(dl, r, f.p.card_border.alpha(f.a), 11, 1);
            f.centered(.semibold, 13.5, r.x + r.w / 2, d.centerY(r, 13.5), f.p.text, if (i == 0) i18n.tr("Usar outro token", "Use another token") else i18n.tr("Modo demonstração", "Demo mode"));
            if (hb.clicked) result = if (i == 0) .cancel else .demo;
        }
        y += 52;
    }
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) result = .cancel;
    y += 8;
    l.card_h = y - y0 + 30;
    return result;
}

// --- Ícones ----------------------------------------------------------------------

fn lockIcon(dl: *c.ImDrawList, cx: f32, cy: f32, col: Rgba) void {
    d.rect(dl, .{ .x = cx - 7, .y = cy - 2, .w = 14, .h = 11 }, col, 3);
    c.ImDrawList_PathArcTo(dl, d.v(cx, cy - 3), 4.5, std.math.pi, std.math.tau, 12);
    c.ImDrawList_PathStroke(dl, col.u(), 2, 0);
    d.line(dl, cx - 4.5, cy - 3.5, cx - 4.5, cy - 1, col, 2);
    d.line(dl, cx + 4.5, cy - 3.5, cx + 4.5, cy - 1, col, 2);
}

/// Olho para mostrar/ocultar. `open` 0 = riscado.
fn eyeIcon(dl: *c.ImDrawList, cx: f32, cy: f32, col: Rgba, open: f32) void {
    c.ImDrawList_PathLineTo(dl, d.v(cx - 9, cy));
    c.ImDrawList_PathBezierQuadraticCurveTo(dl, d.v(cx, cy - 9), d.v(cx + 9, cy), 0);
    c.ImDrawList_PathBezierQuadraticCurveTo(dl, d.v(cx, cy + 9), d.v(cx - 9, cy), 0);
    c.ImDrawList_PathStroke(dl, col.u(), 1.8, 0);
    d.circle(dl, cx, cy, 2.6, col);
    const k = 1 - open;
    if (k > 0.01) d.line(dl, cx - 7, cy - 7, cx - 7 + 14 * k, cy - 7 + 14 * k, col, 1.8);
}

fn v4(x: Rgba) c.ImVec4 {
    return .{ .x = x.r, .y = x.g, .z = x.b, .w = x.a };
}

/// "Colar": copia a área de transferência para o campo.
fn paste(l: *Login) void {
    const clip = c.SDL_GetClipboardText() orelse return;
    defer c.SDL_free(clip);
    const s = std.mem.trim(u8, std.mem.span(clip), " \t\r\n\"");
    const n = @min(s.len, l.token.len - 1);
    @memcpy(l.token[0..n], s[0..n]);
    l.token[n] = 0;
    l.err_len = 0;
    l.want_focus = true;
}
