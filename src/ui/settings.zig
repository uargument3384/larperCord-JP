//! Tela de configurações (estilo Discord): menu à esquerda, página à direita.
//! Usa as cores e fontes do tema atual, então combina com qualquer tema.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const icons = @import("icons.zig");
const S = @import("settings_state.zig");
const i18n = @import("i18n.zig");
const custom = @import("../theme/custom.zig");
const Preview = @import("../theme/manager.zig").Preview;
const proxy = @import("../net/proxy.zig");
const dropdown = @import("dropdown.zig");
const tray = @import("../platform/tray.zig");
const inbox = @import("inbox.zig");
const mem_use_mod = @import("../core/mem_use.zig");

const Section = struct { title: []const u8, title_en: []const u8, items: []const struct { page: S.Page, label: []const u8, label_en: []const u8 } };

pub const sections = [_]Section{
    .{ .title = "CONFIGURAÇÕES DE USUÁRIO", .title_en = "USER SETTINGS", .items = &.{
        .{ .page = .conta, .label = "Minha conta", .label_en = "My Account" },
        .{ .page = .privacidade, .label = "Privacidade", .label_en = "Privacy" },
        .{ .page = .filtros, .label = "Alertas e filtros", .label_en = "Alerts & Filters" },
    } },
    .{ .title = "CONFIGURAÇÕES DO APLICATIVO", .title_en = "APP SETTINGS", .items = &.{
        .{ .page = .aparencia, .label = "Aparência", .label_en = "Appearance" },
        .{ .page = .acessibilidade, .label = "Acessibilidade", .label_en = "Accessibility" },
        .{ .page = .chat, .label = "Chat", .label_en = "Chat" },
        .{ .page = .voz, .label = "Voz", .label_en = "Voice" },
        .{ .page = .notificacoes, .label = "Notificações", .label_en = "Notifications" },
        .{ .page = .atalhos, .label = "Atalhos de teclado", .label_en = "Keybinds" },
        .{ .page = .idioma, .label = "Idioma", .label_en = "Language" },
        .{ .page = .avancado, .label = "Avançado", .label_en = "Advanced" },
    } },
    .{ .title = "LARPERCORD", .title_en = "LARPERCORD", .items = &.{
        .{ .page = .desempenho, .label = "Desempenho", .label_en = "Performance" },
        .{ .page = .lsp, .label = "Erros no código", .label_en = "Code diagnostics" },
        .{ .page = .plugins, .label = "Plugins", .label_en = "Plugins" },
        .{ .page = .atualizacoes, .label = "Atualizações", .label_en = "Updates" },
        .{ .page = .novidades, .label = "Novidades", .label_en = "What's new" },
        .{ .page = .sobre, .label = "Sobre", .label_en = "About" },
    } },
};

/// Estado de desenho de uma página (posição corrente, largura útil).
const Page = struct {
    ctx: *d.Ctx,
    dl: *c.ImDrawList,
    x: f32,
    y: f32,
    w: f32,
    ids: usize = 0,
    /// Marcações do QA para o que é só texto (o QA confere que nada se sobrepõe).
    marks: usize = 0,
    /// Fim do último botão e, depois de `sameLine`, onde vem o próximo.
    button_end: f32 = 0,
    line_x: ?f32 = null,

    pub fn id(p: *Page) usize {
        p.ids += 1;
        return p.ids;
    }

    fn markText(p: *Page, r: d.Rect) void {
        qa.mark(r, "pg:{d}", .{p.marks});
        p.marks += 1;
    }

    pub fn font(p: *Page, wt: d.Weight) *c.ImFont {
        return p.ctx.ui.get(wt);
    }

    pub fn title(p: *Page, t: []const u8) void {
        d.text(p.dl, p.font(.bold), 22, p.x, p.y, p.ctx.col(.text), t);
        p.markText(.{ .x = p.x, .y = p.y, .w = d.width(p.font(.bold), 22, t), .h = 28 });
        p.y += 44;
    }

    /// Uma linha de texto solta, que ocupa `advance` de altura.
    pub fn line(p: *Page, wt: d.Weight, size: f32, col: d.Rgba, t: []const u8, advance: f32) void {
        const tw = d.textClipped(p.dl, p.font(wt), size, p.x, p.y, col, t, p.w);
        p.markText(.{ .x = p.x, .y = p.y, .w = tw, .h = advance - 4 });
        p.y += advance;
    }

    pub fn heading(p: *Page, t: []const u8) void {
        p.y += 8;
        var buf: [96]u8 = undefined;
        const up = d.upper(&buf, t);
        d.text(p.dl, p.font(.bold), 12, p.x, p.y, p.ctx.col(.muted), up);
        p.markText(.{ .x = p.x, .y = p.y, .w = d.width(p.font(.bold), 12, up), .h = 16 });
        p.y += 26;
    }

    /// Texto de apoio: quebra a linha em vez de passar da página.
    pub fn note(p: *Page, t: []const u8) void {
        const h = inbox.wrapText(p.dl, p.font(.regular), 13.5, p.x, p.y, p.w, t, 8, p.ctx.col(.faint));
        p.markText(.{ .x = p.x, .y = p.y, .w = @min(d.width(p.font(.regular), 13.5, t), p.w), .h = h });
        p.y += @round(h + 7.4);
    }

    pub fn divider(p: *Page) void {
        p.y += 10;
        d.line(p.dl, p.x, p.y, p.x + p.w, p.y, p.ctx.col(.border).mix(p.ctx.col(.text), 0.03), 1);
        p.y += 20;
    }

    /// Linha com título, descrição e um interruptor à direita.
    pub fn toggle(p: *Page, label: []const u8, desc: []const u8, value: *bool) void {
        const ctx = p.ctx;
        // A descrição quebra a linha (numa janela estreita, cortar perderia o que
        // a opção faz), e a linha cresce junto.
        const desc_w = p.w - 80;
        const desc_h = if (desc.len > 0) inbox.wrapText(null, p.font(.regular), 13.5, 0, 0, desc_w, desc, 6, ctx.col(.muted)) else 0;
        const row_h: f32 = if (desc.len > 0) 58 + @round(@max(desc_h - 19, 0)) else 40;
        const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = row_h };
        const k_id = p.id();
        const hb = d.hit(ctx, k_id, r);
        qa.mark(r, "toggle:{s}", .{label});
        if (hb.clicked) value.* = !value.*;
        d.text(p.dl, p.font(.medium), 16, r.x, r.y + 4, ctx.col(.text), label);
        if (desc.len > 0) _ = inbox.wrapText(p.dl, p.font(.regular), 13.5, r.x, r.y + 28, desc_w, desc, 6, ctx.col(.muted));
        // Interruptor.
        const sw: d.Rect = .{ .x = r.right() - 44, .y = r.y + 4, .w = 40, .h = 24 };
        const on = anim.to(anim.id("sw", k_id + @as(usize, @intFromEnum(ctx.st.settings.page)) * 1000), if (value.*) 1 else 0, 22);
        d.rect(p.dl, sw, ctx.col(.faint).mix(ctx.col(.accent), on), 12);
        const kx = sw.x + 12 + on * 16;
        d.circle(p.dl, kx, sw.y + 12, 9, d.Rgba.white);
        const ink = ctx.col(.faint).mix(ctx.col(.accent), on);
        if (on > 0.5) {
            d.line(p.dl, kx - 4, sw.y + 12, kx - 1, sw.y + 15, ink, 2);
            d.line(p.dl, kx - 1, sw.y + 15, kx + 4, sw.y + 9, ink, 2);
        } else {
            d.line(p.dl, kx - 3, sw.y + 9, kx + 3, sw.y + 15, ink, 2);
            d.line(p.dl, kx + 3, sw.y + 9, kx - 3, sw.y + 15, ink, 2);
        }
        p.y += row_h;
        d.line(p.dl, r.x, p.y - 8, r.right(), p.y - 8, ctx.col(.border), 1);
        p.y += 6;
    }

    /// Controle deslizante com valor em texto.
    fn slider(p: *Page, label: []const u8, value: *f32, min: f32, max: f32, comptime fmt: []const u8, scale: f32) void {
        const ctx = p.ctx;
        d.text(p.dl, p.font(.medium), 16, p.x, p.y, ctx.col(.text), label);
        p.y += 30;
        const tr: d.Rect = .{ .x = p.x + 6, .y = p.y + 6, .w = p.w - 80, .h = 8 };
        const k = (value.* - min) / (max - min);
        const hr: d.Rect = .{ .x = tr.x - 8, .y = tr.y - 10, .w = tr.w + 16, .h = 28 };
        const hb = d.hit(ctx, p.id(), hr);
        qa.mark(hr, "slider:{s}", .{label});
        if (hb.held) {
            const t = std.math.clamp((ctx.mouse.x - tr.x) / tr.w, 0, 1);
            value.* = min + t * (max - min);
        }
        d.rect(p.dl, tr, ctx.col(.elevated).mix(ctx.col(.text), 0.08), 4);
        d.rect(p.dl, .{ .x = tr.x, .y = tr.y, .w = tr.w * k, .h = tr.h }, ctx.col(.accent), 4);
        const kx = tr.x + tr.w * k;
        d.shadow(p.dl, .{ .x = kx - 7, .y = tr.y - 7, .w = 14, .h = 22 }, 4, 4, ctx.col(.shadow));
        d.rect(p.dl, .{ .x = kx - 6, .y = tr.y - 8, .w = 12, .h = 24 }, d.Rgba.white, 3);
        var buf: [32]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, fmt, .{value.* * scale}) catch "";
        d.text(p.dl, p.font(.semibold), 14, tr.right() + 22, tr.y - 5, ctx.col(.muted), txt);
        p.y += 40;
    }

    /// Escolha entre opções (clique alterna, como um menu compacto).
    fn select(p: *Page, label: []const u8, options: []const []const u8, value: *u8) void {
        const ctx = p.ctx;
        d.text(p.dl, p.font(.bold), 12, p.x, p.y, ctx.col(.muted), label);
        p.y += 22;
        const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = 42 };
        const hb = d.hit(ctx, p.id(), r);
        qa.mark(r, "select:{s}", .{label});
        if (hb.clicked) value.* = @intCast((@as(usize, value.*) + 1) % options.len);
        d.rect(p.dl, r, ctx.col(.rail).mix(ctx.col(.elevated), if (hb.hovered) 0.4 else 0.2), ctx.th.radius);
        d.border(p.dl, r, if (hb.hovered) ctx.col(.accent).alpha(0.6) else ctx.col(.border), ctx.th.radius, 1);
        d.text(p.dl, p.font(.medium), 15, r.x + 12, d.centerY(r, 15), ctx.col(.text), options[@min(value.*, options.len - 1)]);
        icons.chevron(p.dl, r.right() - 20, r.y + 21, ctx.col(.muted).u(), 1);
        p.y += 54;
    }

    fn radio(p: *Page, options: []const []const u8, descs: []const []const u8, value: *u8) void {
        const ctx = p.ctx;
        for (options, 0..) |o, i| {
            const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = if (descs.len > i) @as(f32, 60) else 44 };
            const hb = d.hit(ctx, p.id(), r);
            qa.mark(r, "radio:{s}", .{o});
            if (hb.clicked) value.* = @intCast(i);
            const sel = value.* == i;
            d.rect(p.dl, r, if (sel) ctx.col(.selected) else if (hb.hovered) ctx.col(.hover) else ctx.col(.rail).alpha(0.5), ctx.th.radius);
            const cx = r.x + 22;
            const cy = r.y + 22;
            c.ImDrawList_AddCircleEx(p.dl, d.v(cx, cy), 9, (if (sel) ctx.col(.accent) else ctx.col(.muted)).u(), 0, 2, 0);
            if (sel) d.circle(p.dl, cx, cy, 5, ctx.col(.accent));
            d.text(p.dl, p.font(.medium), 15, r.x + 44, r.y + 12, ctx.col(.text), o);
            if (descs.len > i) d.text(p.dl, p.font(.regular), 13, r.x + 44, r.y + 34, ctx.col(.muted), descs[i]);
            p.y += r.h + 8;
        }
        p.y += 8;
    }

    /// Botões lado a lado, um selecionado (como no Discord).
    /// Bolinhas de cor (0 = "do tema", depois a paleta).
    fn swatches(p: *Page, colors: []const u32, value: *u8) void {
        const ctx = p.ctx;
        const s: f32 = 40;
        for (0..colors.len + 1) |i| {
            const r: d.Rect = .{ .x = p.x + @as(f32, @floatFromInt(i)) * (s + 12), .y = p.y, .w = s, .h = s };
            const hb = d.hit(ctx, p.id(), r);
            qa.mark(r, "accent:{d}", .{i});
            if (hb.clicked) value.* = @intCast(i);
            const col = if (i == 0) p.ctx.th.c(.accent) else d.Rgba.hex(colors[i - 1]);
            d.circle(p.dl, r.x + s / 2, r.y + s / 2, s / 2 - (if (hb.hovered) @as(f32, 0) else 2), col);
            if (i == 0) {
                // "Do tema": meia bolinha com a cor do tema e um T.
                const tw = d.width(p.font(.bold), 14, "T");
                d.text(p.dl, p.font(.bold), 14, r.x + (s - tw) / 2, d.centerY(r, 14), p.ctx.col(.accent_text), "T");
            }
            if (value.* == i) c.ImDrawList_AddCircleEx(p.dl, d.v(r.x + s / 2, r.y + s / 2), s / 2 + 4, ctx.col(.text).u(), 0, 2.5, 0);
            d.tip(ctx, r, if (i == 0) i18n.tr("Cor do tema", "Theme color") else i18n.tr("Usar esta cor", "Use this color"), hb.hovered);
        }
        p.y += s + 24;
    }

    fn segmented(p: *Page, options: []const []const u8, value: *u8) void {
        const ctx = p.ctx;
        const gap: f32 = 8;
        const bw = (p.w - gap * @as(f32, @floatFromInt(options.len - 1))) / @as(f32, @floatFromInt(options.len));
        for (options, 0..) |o, i| {
            const r: d.Rect = .{ .x = p.x + @as(f32, @floatFromInt(i)) * (bw + gap), .y = p.y, .w = bw, .h = 44 };
            const hb = d.hit(ctx, p.id(), r);
            qa.mark(r, "seg:{s}", .{o});
            if (hb.clicked) value.* = @intCast(i);
            const sel = value.* == i;
            const k = anim.to(anim.id("seg", i + @as(usize, @intFromPtr(value))), if (sel) 1 else if (hb.hovered) 0.4 else 0, 20);
            d.rect(p.dl, r, ctx.col(.rail).alpha(0.6).mix(ctx.col(.accent).alpha(0.22), k), ctx.th.radius + 2);
            d.border(p.dl, r, if (sel) ctx.col(.accent) else ctx.col(.border), ctx.th.radius + 2, if (sel) 2 else 1);
            const tw = d.width(p.font(.semibold), 15, o);
            d.text(p.dl, p.font(.semibold), 15, r.x + (r.w - tw) / 2, d.centerY(r, 15), if (sel) ctx.col(.text) else ctx.col(.muted), o);
        }
        p.y += 60;
    }

    /// Quanto um botão ocupa na página.
    const button_step: f32 = 44;

    /// O botão anda com o cursor da página, como tudo aqui: quem vem depois nunca
    /// cai em cima dele. Dois na mesma linha: `sameLine` entre eles.
    pub fn button(p: *Page, label: []const u8, danger: bool) bool {
        const ctx = p.ctx;
        const r = p.buttonRect(label);
        const hb = d.hit(ctx, p.id(), r);
        qa.mark(r, "button:{s}", .{label});
        const base = if (danger) ctx.col(.danger) else ctx.col(.accent);
        d.rect(p.dl, r, if (hb.hovered) base.mix(d.Rgba.black, 0.12) else base, ctx.th.radius);
        d.text(p.dl, p.font(.semibold), 14, r.x + 16, d.centerY(r, 14), if (danger) d.Rgba.white else ctx.col(.accent_text), label);
        return hb.clicked;
    }

    /// Um botão que não é a ação principal da página: sem a cor de destaque.
    pub fn buttonSoft(p: *Page, label: []const u8) bool {
        const ctx = p.ctx;
        const r = p.buttonRect(label);
        const hb = d.hit(ctx, p.id(), r);
        qa.mark(r, "button:{s}", .{label});
        d.rect(p.dl, r, ctx.col(.elevated).mix(ctx.col(.text), if (hb.hovered) @as(f32, 0.08) else 0), ctx.th.radius);
        d.border(p.dl, r, ctx.col(.border).mix(ctx.col(.text), 0.08), ctx.th.radius, 1);
        d.text(p.dl, p.font(.semibold), 14, r.x + 16, d.centerY(r, 14), ctx.col(.text), label);
        return hb.clicked;
    }

    /// Onde vai o próximo botão; o cursor da página já anda.
    fn buttonRect(p: *Page, label: []const u8) d.Rect {
        const r: d.Rect = .{ .x = p.line_x orelse p.x, .y = p.y, .w = d.width(p.font(.semibold), 14, label) + 32, .h = 36 };
        p.line_x = null;
        p.button_end = r.right();
        p.y += button_step;
        return r;
    }

    /// O próximo botão fica ao lado do último, em vez de embaixo.
    pub fn sameLine(p: *Page) void {
        p.y -= button_step;
        p.line_x = p.button_end + 8;
    }

    fn keyRow(p: *Page, action: []const u8, keys: []const u8) void {
        const ctx = p.ctx;
        p.markText(.{ .x = p.x, .y = p.y, .w = p.w, .h = 36 });
        d.text(p.dl, p.font(.medium), 15, p.x, p.y + 8, ctx.col(.text), action);
        var x = p.x + p.w;
        var it = std.mem.splitBackwardsScalar(u8, keys, '+');
        while (it.next()) |k| {
            const kw = d.width(p.font(.semibold), 13, k) + 18;
            x -= kw;
            const kr: d.Rect = .{ .x = x, .y = p.y + 4, .w = kw, .h = 28 };
            d.rect(p.dl, kr, ctx.col(.elevated), 6);
            d.rect(p.dl, .{ .x = kr.x, .y = kr.bottom() - 3, .w = kr.w, .h = 3 }, d.Rgba.black.alpha(0.25), 3);
            d.text(p.dl, p.font(.semibold), 13, kr.x + 9, kr.y + 5, ctx.col(.text), k);
            x -= 6;
        }
        p.y += 44;
    }
};

pub fn draw(ctx: *d.Ctx, previews: []const Preview) void {
    const s = &ctx.st.settings;
    const k = anim.to(anim.id("settings", 0), if (s.open) 1 else 0, 18);
    if (k < 0.01) return;
    if (!s.open) {
        // Desaparecendo: só um véu, sem interação.
        d.rect(ctx.fg, ctx.win, ctx.col(.surface).alpha(k), 0);
        return;
    }

    const win = ctx.win;
    c.ImGui_SetNextWindowPos(d.v(win.x, win.y), 0);
    c.ImGui_SetNextWindowSize(d.v(win.w, win.h), 0);
    _ = c.ImGui_Begin("##settings", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse);
    defer c.ImGui_End();
    const dl = c.ImGui_GetWindowDrawList();
    const saved_dl = ctx.dl;
    ctx.dl = dl;
    defer ctx.dl = saved_dl;

    // Entra com um leve zoom, como no Discord.
    const z = 1 - (1 - k) * 0.04;
    const bg = ctx.col(.surface);
    const opaque_bg = d.Rgba{ .r = bg.r, .g = bg.g, .b = bg.b, .a = @max(bg.a, 0.97) };
    d.rect(dl, win, opaque_bg.alpha(k), 0);

    const side_w = @max(220, win.w * 0.3);
    const side: d.Rect = .{ .x = win.x, .y = win.y, .w = side_w, .h = win.h };
    const sb = ctx.col(.sidebar);
    d.rect(dl, side, (d.Rgba{ .r = sb.r, .g = sb.g, .b = sb.b, .a = @max(sb.a, 0.97) }).alpha(k), 0);

    // Menu.
    var y = win.y + 60;
    const mx = side.right() - 210;
    const fam = ctx.ui;
    for (sections, 0..) |sec, si| {
        d.text(dl, fam.get(.bold), 11.5, mx + 10, y, ctx.col(.faint), i18n.tr(sec.title, sec.title_en));
        y += 24;
        for (sec.items, 0..) |it, ii| {
            const r: d.Rect = .{ .x = mx, .y = y, .w = 192, .h = 32 };
            const hb = d.hit(ctx, 100 + si * 20 + ii, r);
            const label = i18n.tr(it.label, it.label_en);
            qa.mark(r, "settings:{s}", .{label});
            if (hb.clicked) s.page = it.page;
            const sel = s.page == it.page;
            if (sel) d.rect(dl, r, ctx.col(.selected).mix(ctx.col(.text), 0.04), ctx.th.radius) else if (hb.hovered) d.rect(dl, r, ctx.col(.hover), ctx.th.radius);
            d.text(dl, fam.get(if (sel) .semibold else .medium), 15, r.x + 10, d.centerY(r, 15), if (sel) ctx.col(.text) else ctx.col(.muted), label);
            y += 34;
        }
        y += 8;
        d.line(dl, mx + 10, y, mx + 192, y, ctx.col(.border), 1);
        y += 14;
    }
    {
        const r: d.Rect = .{ .x = mx, .y = y, .w = 192, .h = 32 };
        const hb = d.hit(ctx, 99, r);
        const label = i18n.tr("Sair", "Log Out");
        qa.mark(r, "settings:{s}", .{label});
        if (hb.hovered) d.rect(dl, r, ctx.col(.hover), ctx.th.radius);
        d.text(dl, fam.get(.medium), 15, r.x + 10, d.centerY(r, 15), ctx.col(.danger), label);
        if (hb.clicked) ctx.act(.logout);
    }

    // Conteúdo com rolagem.
    const content: d.Rect = .{ .x = side.right(), .y = win.y, .w = win.w - side_w, .h = win.h };
    const cw = @min(740, content.w - 120);
    c.ImGui_SetCursorScreenPos(d.v(content.x, content.y));
    _ = c.ImGui_BeginChild("##settings-page", d.v(content.w, content.h), 0, c.ImGuiWindowFlags_NoBackground);
    const cdl = c.ImGui_GetWindowDrawList();
    const o = c.ImGui_GetCursorScreenPos();
    ctx.dl = cdl;
    var p: Page = .{ .ctx = ctx, .dl = cdl, .x = content.x + 40, .y = o.y + 60 + (1 - z) * 200, .w = cw };
    page(&p, previews);
    c.ImGui_SetCursorScreenPos(d.v(content.x, p.y + 60));
    c.ImGui_Dummy(d.v(1, 1));
    c.ImGui_EndChild();
    ctx.dl = dl;

    // Fechar (ESC).
    const cx = @min(content.x + 40 + cw + 60, win.right() - 40);
    const cr: d.Rect = .{ .x = cx - 18, .y = win.y + 60, .w = 36, .h = 36 };
    // A página rolável fica por cima desta área e pegaria o clique: o
    // botão olha o mouse direto.
    const hb = d.hitRaw(ctx, cr);
    qa.mark(cr, "settings-close", .{});
    c.ImDrawList_AddCircleEx(dl, d.v(cx, cr.y + 18), 17, (if (hb.hovered) ctx.col(.text) else ctx.col(.muted)).u(), 0, 2, 0);
    const xc = if (hb.hovered) ctx.col(.text) else ctx.col(.muted);
    d.line(dl, cx - 6, cr.y + 12, cx + 6, cr.y + 24, xc, 2);
    d.line(dl, cx + 6, cr.y + 12, cx - 6, cr.y + 24, xc, 2);
    const ew = d.width(fam.get(.bold), 12, "ESC");
    d.text(dl, fam.get(.bold), 12, cx - ew / 2, cr.bottom() + 8, ctx.col(.muted), "ESC");
    if (hb.clicked or (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and !dropdown.ownsEsc())) ctx.act(.close_settings);
}

var color_slot: i32 = -1;
const color_key: usize = 0x8c000;
var color_cell: d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var color_buf: [10]u8 = @splat(0);
var color_sync = false;
var color_bad = false;
var color_theme: [64]u8 = @splat(0);
var color_theme_len: u8 = 0;
var color_mode: i8 = -1;

fn slotColor(ctx: *d.Ctx, slot: usize) d.Rgba {
    if (slot < custom.token_count) return ctx.th.c(@enumFromInt(slot));
    return ctx.th.role(@intCast(slot - custom.token_count));
}

fn slotLabel(buf: []u8, slot: usize) []const u8 {
    if (slot >= custom.token_count) {
        return std.fmt.bufPrint(buf, "role {d}", .{slot - custom.token_count + 1}) catch "role";
    }
    const name = custom.slotName(slot);
    if (name.len > buf.len) return name[0..buf.len];
    for (name, 0..) |ch, i| buf[i] = if (ch == '_') '-' else ch;
    return buf[0..name.len];
}

fn syncColorBuf(ctx: *d.Ctx, slot: usize) void {
    @memset(&color_buf, 0);
    _ = custom.formatColor(&color_buf, slotColor(ctx, slot));
}

fn applyColor(ctx: *d.Ctx) void {
    if (color_slot < 0) return;
    const s = std.mem.trim(u8, std.mem.sliceTo(&color_buf, 0), " \t\r\n");
    if (custom.parseHex(s)) |rgba| {
        color_bad = false;
        ctx.act(.{ .set_theme_color = .{ .slot = @intCast(color_slot), .rgba = rgba } });
    } else {
        color_bad = true;
    }
}

fn themeColors(p: *Page) void {
    const ctx = p.ctx;
    const mode_i: i8 = if (ctx.th.mode == .light) 1 else 0;
    if (color_mode != mode_i or !std.mem.eql(u8, color_theme[0..color_theme_len], ctx.theme_name)) {
        color_mode = mode_i;
        color_slot = -1;
        color_sync = false;
        color_bad = false;
        const n = @min(ctx.theme_name.len, color_theme.len);
        @memcpy(color_theme[0..n], ctx.theme_name[0..n]);
        @memset(color_theme[n..], 0);
        color_theme_len = @intCast(n);
    }
    var hbuf: [96]u8 = undefined;
    const mode = if (ctx.th.mode == .light) i18n.tr("claro", "light") else i18n.tr("escuro", "dark");
    p.heading(i18n.fmt(&hbuf, "Cores do tema — {s} ({s})", "Theme colors — {s} ({s})", .{ ctx.theme_name, mode }));
    p.note(i18n.tr("#RRGGBB ou #RRGGBBAA. Vale só para este tema e este modo.", "#RRGGBB or #RRGGBBAA. Applies only to this theme and mode."));
    p.note(i18n.tr("Cores personalizadas têm prioridade sobre a cor de destaque.", "Custom colors take priority over the accent color."));

    const cols: usize = 2;
    const gap: f32 = 10;
    const cell_w = (p.w - gap) / @as(f32, @floatFromInt(cols));
    const rows = (custom.slot_count + cols - 1) / cols;
    const top = p.y;
    for (0..custom.slot_count) |i| {
        const col = i % cols;
        const row = i / cols;
        const rr: d.Rect = .{
            .x = p.x + @as(f32, @floatFromInt(col)) * (cell_w + gap),
            .y = top + @as(f32, @floatFromInt(row)) * 30,
            .w = cell_w,
            .h = 26,
        };
        const hb = d.hit(ctx, 0x8c00 + i, rr);
        qa.mark(rr, "theme-color:{d}", .{i});
        if (hb.clicked) {
            color_slot = @intCast(i);
            color_sync = true;
            color_bad = false;
            dropdown.toggle(color_key);
        }
        const editing = color_slot == i and dropdown.isOpen(color_key);
        if (editing) color_cell = rr;
        if (editing) d.rect(p.dl, rr, ctx.col(.selected), 5) else if (hb.hovered) d.rect(p.dl, rr, ctx.col(.hover), 5);
        const colr = slotColor(ctx, i);
        const sw: d.Rect = .{ .x = rr.x + 5, .y = rr.y + 5, .w = 16, .h = 16 };
        d.rect(p.dl, sw, colr, 3);
        d.border(p.dl, sw, ctx.col(.text).alpha(0.25), 3, 1);
        var lbuf: [24]u8 = undefined;
        _ = d.textClipped(p.dl, p.font(.medium), 13, rr.x + 28, d.centerY(rr, 13), ctx.col(.text), slotLabel(&lbuf, i), cell_w - 100);
        var hb2: [12]u8 = undefined;
        const hex = custom.formatPacked(&hb2, custom.toPacked(colr));
        _ = d.textClipped(p.dl, p.font(.regular), 11, rr.right() - d.width(p.font(.regular), 11, hex) - 6, d.centerY(rr, 11), ctx.col(.faint), hex, 70);
    }
    p.y = top + @as(f32, @floatFromInt(rows)) * 30 + 10;
    colorEditor(p);
}

/// O editor de uma cor: flutua sobre a grade, colado na cor clicada.
fn colorEditor(p: *Page) void {
    const ctx = p.ctx;
    if (!dropdown.isOpen(color_key)) {
        color_slot = -1;
        return;
    }
    if (color_slot < 0) return;
    const slot: usize = @intCast(color_slot);
    if (color_sync) {
        color_sync = false;
        syncColorBuf(ctx, slot);
    }
    const content_h: f32 = 4 + 34 + 38 + (if (color_bad) @as(f32, 26) else 0) + 44 * 3;
    const dd_opt = dropdown.begin(ctx, color_key, color_cell, 340, content_h);
    if (dd_opt == null) return;
    var dd = dd_opt.?;
    defer dd.end();
    // Uma "página" dentro do painel: os botões e textos de sempre.
    var q: Page = .{ .ctx = ctx, .dl = dd.dl, .x = dd.x + 8, .y = dd.y + 4, .w = dd.w - 16, .ids = 0x8d00 };
    var lbuf: [24]u8 = undefined;
    q.heading(slotLabel(&lbuf, slot));
    const sw: d.Rect = .{ .x = q.x, .y = q.y + 1, .w = 28, .h = 28 };
    d.rect(q.dl, sw, slotColor(ctx, slot), 6);
    d.border(q.dl, sw, ctx.col(.text).alpha(0.35), 6, 1);
    c.ImGui_SetCursorScreenPos(d.v(q.x + 38, q.y));
    c.ImGui_SetNextItemWidth(q.w - 38);
    const enter = c.ImGui_InputText("##theme-color", &color_buf, color_buf.len, c.ImGuiInputTextFlags_CharsNoBlank | c.ImGuiInputTextFlags_EnterReturnsTrue);
    qa.mark(.{ .x = q.x + 38, .y = q.y, .w = q.w - 38, .h = 30 }, "theme-color-input", .{});
    q.y += 38;
    if (color_bad) q.note(i18n.tr("hex inválido — use #RRGGBB ou #RRGGBBAA", "invalid hex — use #RRGGBB or #RRGGBBAA"));
    const apply_click = q.button(i18n.tr("Aplicar", "Apply"), false);
    if (enter or apply_click) applyColor(ctx);
    if (q.button(i18n.tr("Limpar esta cor", "Clear this color"), false)) {
        ctx.act(.{ .set_theme_color = .{ .slot = @intCast(color_slot), .rgba = null } });
        color_sync = true;
    }
    if (q.button(i18n.tr("Restaurar tema", "Reset theme"), false)) {
        ctx.act(.reset_theme_colors);
        color_sync = true;
    }
    dd.y = q.y;
}

// --- Rede (proxy) -----------------------------------------------------------

var proxy_buf: [256]u8 = @splat(0);
/// O valor das configurações que está no campo (se mudar por fora, o campo
/// acompanha).
var proxy_seen: S.Text = .{};
var proxy_bad = false;

fn network(p: *Page) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    p.heading(i18n.tr("Rede", "Network"));
    p.note(i18n.tr("Proxy http, https, socks5 ou socks5h. Tor: socks5h://127.0.0.1:9050", "http, https, socks5 or socks5h proxy. Tor: socks5h://127.0.0.1:9050"));
    if (!std.mem.eql(u8, proxy_seen.slice(), s.proxy.slice())) {
        proxy_seen = s.proxy;
        @memset(&proxy_buf, 0);
        @memcpy(proxy_buf[0..s.proxy.len], s.proxy.slice());
        proxy_bad = false;
    }
    const iw = @min(p.w, 420);
    const ir: d.Rect = .{ .x = p.x, .y = p.y - 3, .w = iw, .h = 32 };
    d.rect(p.dl, ir, ctx.col(.elevated), 6);
    d.border(p.dl, ir, if (proxy_bad) ctx.col(.danger) else ctx.col(.border), 6, 1);
    c.ImGui_SetCursorScreenPos(d.v(p.x + 10, p.y));
    c.ImGui_SetNextItemWidth(iw - 20);
    const enter = c.ImGui_InputTextWithHint("##proxy", "socks5h://127.0.0.1:9050", &proxy_buf, proxy_buf.len, c.ImGuiInputTextFlags_CharsNoBlank | c.ImGuiInputTextFlags_EnterReturnsTrue);
    qa.mark(.{ .x = p.x, .y = p.y, .w = iw, .h = 30 }, "proxy-input", .{});
    p.y += 40;
    if (proxy_bad) p.note(i18n.tr("URL inválida: use esquema://host:porta (http, https, socks5 ou socks5h).", "Invalid URL: use scheme://host:port (http, https, socks5 or socks5h)."));
    var nbuf: [360]u8 = undefined;
    if (s.proxy.len > 0 and !proxy.valid(s.proxy.slice())) {
        p.note(i18n.tr("O proxy salvo é inválido e está sendo ignorado.", "The saved proxy is invalid and is being ignored."));
    } else if (s.proxy.len > 0) {
        const scope = if (s.proxy_all) i18n.tr("todas as conexões", "every connection") else i18n.tr("só GIFs e mídia de fora do Discord", "only GIFs and media from outside Discord");
        // Sem usuário e senha na tela.
        const u = s.proxy.slice();
        var shown_buf: [256]u8 = undefined;
        const shown = if (std.mem.lastIndexOfScalar(u8, u, '@')) |at| (if (std.mem.indexOf(u8, u, "://")) |sch| std.fmt.bufPrint(&shown_buf, "{s}…@{s}", .{ u[0 .. sch + 3], u[at + 1 ..] }) catch u else u) else u;
        p.note(i18n.fmt(&nbuf, "Em uso: {s} ({s}).", "In use: {s} ({s}).", .{ shown, scope }));
    } else p.note(i18n.tr("Sem proxy: conexão direta.", "No proxy: direct connection."));
    const save_click = p.button(i18n.tr("Salvar proxy", "Save proxy"), false);
    if (enter or save_click) {
        const text = std.mem.trim(u8, std.mem.sliceTo(&proxy_buf, 0), " ");
        if (text.len == 0) {
            s.proxy = .{};
            proxy_bad = false;
        } else if (proxy.valid(text)) {
            s.proxy.set(text);
            proxy_bad = false;
            ctx.st.showToast(ctx.now_ms, false, "proxy salvo", "proxy saved", .{});
        } else {
            proxy_bad = true;
            ctx.st.showToast(ctx.now_ms, true, "proxy inválido", "invalid proxy", .{});
        }
    }
    if (s.proxy.len > 0) {
        if (p.button(i18n.tr("Remover proxy", "Remove proxy"), true)) s.proxy = .{};
    }
    p.toggle(i18n.tr("Usar o proxy em tudo", "Use the proxy for everything"), i18n.tr("Também o Discord: API, imagens, vídeos e o gateway (este a partir da próxima conexão).", "Discord too: API, images, videos and the gateway (from the next connection)."), &s.proxy_all);
}

fn page(p: *Page, previews: []const Preview) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    switch (s.page) {
        .aparencia => {
            p.title(i18n.tr("Aparência", "Appearance"));
            p.heading(i18n.tr("Modo", "Mode"));
            p.segmented(if (i18n.en()) &.{ "Dark", "Light", "Follow system" } else &.{ "Escuro", "Claro", "Seguir o sistema" }, &s.color_mode);
            p.heading(i18n.tr("Tema", "Theme"));
            p.note(i18n.tr("Cada tema muda o layout inteiro, não só as cores. Todos têm versão clara e escura.", "Each theme changes the whole layout, not just the colors. All of them come in light and dark."));
            themeGrid(p, previews);
            if (ctx.th.options.len > 0) {
                p.divider();
                var hbuf: [96]u8 = undefined;
                p.heading(i18n.fmt(&hbuf, "Opções do tema {s}", "{s} theme options", .{ctx.theme_name}));
                for (ctx.th.options, 0..) |o, i| {
                    const cur = ctx.th.option(o.name) orelse o.default;
                    var v = cur;
                    const en = i18n.en();
                    p.toggle(if (en and o.label_en.len > 0) o.label_en else o.label, if (en and o.description_en.len > 0) o.description_en else o.description, &v);
                    if (v != cur) ctx.act(.{ .set_theme_option = .{ .index = i, .value = v } });
                }
            }
            p.divider();
            p.heading(i18n.tr("Escala da fonte", "Font scaling"));
            p.slider(i18n.tr("Tamanho do texto", "Text size"), &s.font_scale, 0.8, 1.3, "{d:.0}%", 112);
            p.heading(i18n.tr("Exibição das mensagens", "Message display"));
            p.toggle(i18n.tr("Modo compacto", "Compact mode"), i18n.tr("Menos espaço entre grupos e avatares menores.", "Less space between groups and smaller avatars."), &s.compact);
            p.toggle(i18n.tr("Mostrar avatares", "Show avatars"), i18n.tr("Exibe a foto ao lado do nome.", "Shows the profile picture next to the name."), &s.show_avatars);
            p.toggle(i18n.tr("Relógio de 24 horas", "24-hour clock"), i18n.tr("Ex.: 21:30 em vez de 9:30 PM.", "E.g. 21:30 instead of 9:30 PM."), &s.clock_24h);
            p.toggle(i18n.tr("Status em anel", "Status ring"), i18n.tr("Online, ausente e não perturbe como um anel em volta da foto.", "Online, idle and do-not-disturb as a ring around the picture."), &s.status_ring);
            p.heading(i18n.tr("Cor de destaque", "Accent color"));
            p.note(i18n.tr("Vale para qualquer tema; \"T\" volta à cor do tema.", "Works with every theme; \"T\" goes back to the theme's color."));
            p.swatches(&@import("../app.zig").App.accents, &s.accent);
            p.heading(i18n.tr("Cantos", "Corners"));
            p.segmented(if (i18n.en()) &.{ "Theme", "Square", "Soft", "Round" } else &.{ "Do tema", "Retos", "Suaves", "Redondos" }, &s.corners);
            p.divider();
            themeColors(p);
            p.heading("Layout");
            p.toggle(i18n.tr("Lista de membros", "Member list"), i18n.tr("Mostra quem está no servidor (quando o tema tem uma).", "Shows who's in the server (when the theme has one)."), &s.show_member_list);
            p.toggle(i18n.tr("Barra de status", "Status bar"), i18n.tr("Conexão, ping, RAM e relógio (quando o tema tem uma).", "Connection, ping, RAM and clock (when the theme has one)."), &s.show_status_bar);
            p.note(i18n.tr("Arraste a divisa entre os painéis para mudar a largura da lista de canais, da lista de membros e da tela dividida. Duplo clique na divisa volta ao padrão do tema.", "Drag the edge between panels to resize the channel list, the member list and split view. Double-click an edge to go back to the theme's default."));
            if (!s.panelsAtDefault()) {
                if (p.button(i18n.tr("Restaurar larguras", "Reset panel sizes"), false)) {
                    s.resetPanels();
                    ctx.act(.save_settings);
                }
            }
        },
        .acessibilidade => {
            p.title(i18n.tr("Acessibilidade", "Accessibility"));
            p.heading(i18n.tr("Movimento", "Motion"));
            p.toggle(i18n.tr("Reduzir movimento", "Reduce motion"), i18n.tr("Desliga as animações de hover, rolagem e transições.", "Turns off hover, scrolling and transition animations."), &s.reduce_motion);
            p.heading(i18n.tr("Texto", "Text"));
            p.toggle(i18n.tr("Cores dos cargos", "Role colors"), i18n.tr("Pinta os nomes com a cor do cargo no servidor.", "Shows names in their server role color."), &s.role_colors);
            p.toggle(i18n.tr("Sublinhar links", "Underline links"), i18n.tr("Desligado, o sublinhado só aparece com o mouse em cima.", "When off, links are only underlined on hover."), &s.underline_links);
        },
        .chat => {
            p.title("Chat");
            p.heading(i18n.tr("Imagens", "Images"));
            p.toggle(i18n.tr("Reproduzir GIFs automaticamente", "Automatically play GIFs"), i18n.tr("Desligado, o GIF anda quando o mouse passa por cima.", "When off, a GIF plays while you hover it."), &s.autoplay_gifs);
            p.toggle(i18n.tr("Mostrar imagens de links", "Show images from links"), i18n.tr("Imagens e GIFs de links mandados na conversa.", "Images and GIFs from links posted in chat."), &s.show_embeds);
            p.toggle(i18n.tr("Modo economia", "Data saver"), i18n.tr("Imagens, fotos de perfil e anexos só baixam quando você clica. Bom em rede ruim.", "Images, profile pictures and attachments only download when you click. Good on bad networks."), &s.data_saver);
            p.heading(i18n.tr("Conteúdo", "Content"));
            p.toggle(i18n.tr("Sempre mostrar spoilers", "Always show spoilers"), i18n.tr("Revela o texto ||escondido|| sem precisar clicar.", "Reveals ||hidden|| text without clicking."), &s.show_spoilers);
            p.heading(i18n.tr("Leitura", "Reading"));
            p.toggle(i18n.tr("Abrir na primeira não lida", "Open at the first unread"), i18n.tr("Canal com mensagens novas abre nelas, como no Discord. Desligado, abre no fim.", "A channel with new messages opens at them, like Discord. When off, it opens at the bottom."), &s.open_at_unread);
            p.heading(i18n.tr("Caixa de texto", "Text box"));
            p.toggle(i18n.tr("Prévia do markdown", "Markdown preview"), i18n.tr("Com **negrito**, `código`, ||spoiler||…, mostra acima da caixa como vai ficar.", "With **bold**, `code`, ||spoilers||…, shows above the box how it will look."), &s.md_preview);
        },
        .notificacoes => {
            p.title(i18n.tr("Notificações", "Notifications"));
            p.note(i18n.tr("Para mensagens diretas e menções, quando você não está olhando a conversa.", "For direct messages and mentions, when you're not looking at the conversation."));
            p.toggle(i18n.tr("Notificações na área de trabalho", "Desktop notifications"), i18n.tr("Só com a janela fora de foco ou escondida na bandeja.", "Only while the window is unfocused or hidden in the tray."), &s.desktop_notifs);
            p.toggle(i18n.tr("Piscar na barra de tarefas", "Flash taskbar"), i18n.tr("A janela chama atenção até você voltar para ela.", "The window asks for attention until you come back."), &s.taskbar_flash);
            p.note(i18n.tr("Canais silenciados (botão direito → Silenciar) não notificam.", "Muted channels (right-click → Mute) never notify."));
        },
        .privacidade => {
            p.title(i18n.tr("Privacidade", "Privacy"));
            p.toggle(i18n.tr("Enviar indicador de digitação", "Send typing indicator"), i18n.tr("Os outros veem \"digitando…\" enquanto você escreve.", "Others see \"typing…\" while you write."), &s.send_typing);
            p.toggle(i18n.tr("Animar GIFs do Tenor e do Giphy", "Animate Tenor and Giphy GIFs"), i18n.tr("Baixa do site deles, que vê o seu IP (o app oficial faz igual). Desligado: prévia parada pelo Discord.", "Downloads from their site, which sees your IP (the official app does too). Off: still preview via Discord."), &s.gif_hosts);
            p.toggle(i18n.tr("Modo streamer", "Streamer Mode"), i18n.tr("Esconde o e-mail e o nome de usuário nas configurações.", "Hides your email and username in settings."), &s.streamer_mode);
            p.toggle(i18n.tr("Registro de mensagens", "Message log"), i18n.tr("Apagadas continuam na tela (marcadas) e editadas guardam o original. Só aqui.", "Deleted messages stay visible (marked) and edits keep the original. Local only."), &s.message_log);
            p.toggle(i18n.tr("Guardar mensagens no disco", "Keep messages on disk"), i18n.tr("Conversas abrem na hora e a busca (Ctrl+F) funciona sem internet. Só o seu usuário lê.", "Chats open instantly and search (Ctrl+F) works offline. Only your user can read it."), &s.message_cache);
            {
                const msg_cache = @import("../net/msg_cache.zig");
                var sb: [24]u8 = undefined;
                var lb: [64]u8 = undefined;
                const size = msg_cache.formatSize(&sb, msg_cache.totalBytes(), i18n.en());
                if (p.button(i18n.fmt(&lb, "Apagar cache ({s})", "Clear cache ({s})", .{size}), true)) ctx.act(.clear_cache);
                p.y += 8;
            }
            p.note(i18n.tr("Fora isso, imagens e avatares só vêm dos servidores do Discord.", "Everything else (images, avatars) only comes from Discord's servers."));
            p.divider();
            network(p);
        },
        .atalhos => {
            p.title(i18n.tr("Atalhos de teclado", "Keybinds"));
            p.keyRow(i18n.tr("Paleta de comandos", "Command palette"), "Ctrl+K");
            p.keyRow(i18n.tr("Paleta com as ações primeiro", "Palette, actions first"), "Ctrl+Shift+P");
            p.keyRow(i18n.tr("Buscar mensagens", "Search messages"), "Ctrl+F");
            p.keyRow(i18n.tr("Configurações", "Settings"), "Ctrl+,");
            p.keyRow(i18n.tr("Próximo tema", "Next theme"), "F2");
            p.keyRow(i18n.tr("Tema anterior", "Previous theme"), "Shift+F2");
            p.keyRow(i18n.tr("Próxima aba", "Next tab"), "Ctrl+Tab");
            p.keyRow(i18n.tr("Aba anterior", "Previous tab"), "Ctrl+Shift+Tab");
            p.keyRow(i18n.tr("Ir para a aba N", "Go to tab N"), "Alt+1…9");
            p.keyRow(i18n.tr("Fechar aba", "Close tab"), "Ctrl+W");
            p.keyRow(i18n.tr("Caixa de entrada", "Inbox"), "Ctrl+I");
            p.keyRow(i18n.tr("Mensagens salvas", "Saved messages"), "Ctrl+Shift+S");
            p.keyRow(i18n.tr("Abrir canal em nova aba", "Open channel in a new tab"), i18n.tr("Ctrl+Clique", "Ctrl+Click"));
            p.keyRow(i18n.tr("Fechar aba com o mouse", "Close tab with the mouse"), i18n.tr("Botão do meio", "Middle click"));
            p.divider();
            p.toggle(i18n.tr("Navegação estilo vim", "Vim-style navigation"), i18n.tr("Com a caixa de texto sem foco (Esc sai dela), as teclas abaixo navegam.", "With the text box unfocused (Esc leaves it), the keys below navigate."), &s.vim_keys);
            if (s.vim_keys) {
                p.keyRow(i18n.tr("Rolar para baixo / para cima", "Scroll down / up"), "j / k");
                p.keyRow(i18n.tr("Topo / fim da conversa", "Top / bottom of the conversation"), "gg / G");
                p.keyRow(i18n.tr("Meia página para baixo / para cima", "Half page down / up"), "Ctrl+d / Ctrl+u");
                p.keyRow(i18n.tr("Próximo / anterior canal", "Next / previous channel"), "J / K");
                p.keyRow(i18n.tr("Voltar para a caixa de texto", "Back to the text box"), i18n.tr("i ou Enter", "i or Enter"));
                p.keyRow(i18n.tr("Sair da caixa de texto", "Leave the text box"), "Esc");
                p.keyRow(i18n.tr("Buscar (paleta)", "Search (palette)"), "/");
            }
        },
        .idioma => {
            p.title(i18n.tr("Idioma", "Language"));
            // Os nomes dos idiomas ficam sempre na própria língua.
            p.radio(&.{ i18n.tr("Seguir o sistema", "Follow system"), "Português (Brasil)", "English (US)", "日本語" }, &.{}, &s.language);
            p.note(i18n.tr("Por padrão o app segue o idioma do sistema. A troca vale na hora.", "By default the app follows your system language. Changes apply right away."));
        },
        .avancado => {
            p.title(i18n.tr("Avançado", "Advanced"));
            p.toggle(i18n.tr("Modo desenvolvedor", "Developer Mode"), i18n.tr("Mostra o ID das mensagens e põe \"Copiar ID\" nos menus.", "Shows message IDs and adds \"Copy ID\" to menus."), &s.developer_mode);
            p.toggle(i18n.tr("Recarregar temas ao salvar", "Reload themes on save"), i18n.tr("Salvar um .kdl em themes/ ou ~/.config/larpercord/themes aplica na hora.", "Saving a .kdl in themes/ or ~/.config/larpercord/themes applies it right away."), &s.hot_reload);
            p.toggle(i18n.tr("Fechar para a bandeja", "Close to tray"), i18n.tr("Fechar a janela deixa o app conectado, com um ícone na bandeja do sistema.", "Closing the window keeps the app connected, with an icon in the system tray."), &s.close_to_tray);
            if (s.close_to_tray and !tray.hostSeen(ctx.now_ms)) p.note(i18n.tr("Este sistema não tem bandeja agora: fechar a janela encerra o app.", "This system has no tray right now: closing the window quits the app."));
        },
        .filtros => @import("settings_filtros.zig").page(ctx, p.dl, p.x, &p.y, p.w),
        .voz => @import("settings_voz.zig").draw(p),
        .conta => account(p),
        .desempenho => performance(p),
        .lsp => @import("settings_lsp.zig").draw(p),
        .plugins => @import("plugins_page.zig").draw(p),
        .atualizacoes => @import("settings_update.zig").draw(p),
        .novidades => @import("settings_update.zig").changelog(p),
        .sobre => about(p),
    }
}

fn themeGrid(p: *Page, previews: []const Preview) void {
    const ctx = p.ctx;
    const cols: usize = if (p.w > 600) 3 else 2;
    const gap: f32 = 14;
    const cw = (p.w - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    const ch: f32 = cw * 0.62 + 48;
    for (previews, 0..) |pv, i| {
        const col = i % cols;
        const row = i / cols;
        const r: d.Rect = .{ .x = p.x + @as(f32, @floatFromInt(col)) * (cw + gap), .y = p.y + @as(f32, @floatFromInt(row)) * (ch + gap), .w = cw, .h = ch };
        const hb = d.hit(ctx, 500 + i, r);
        qa.mark(r, "theme-card:{s}", .{pv.name});
        if (hb.clicked) ctx.act(.{ .set_theme = i });
        const sel = i == ctx.theme_index;
        const k = anim.to(anim.id("tcard", i), if (sel) 1 else if (hb.hovered) 0.5 else 0, 18);
        d.rect(p.dl, r, ctx.col(.rail).mix(ctx.col(.elevated), 0.4), 12);
        // Miniatura com as cores do tema.
        const m: d.Rect = .{ .x = r.x + 8, .y = r.y + 8, .w = r.w - 16, .h = r.h - 56 };
        miniature(p.dl, pv, m);
        d.border(p.dl, r, ctx.col(.accent).alpha(0.25 + 0.75 * k), 12, 1 + k * 1.5);
        d.text(p.dl, p.font(.semibold), 15, r.x + 12, r.bottom() - 42, ctx.col(.text), pv.name);
        _ = d.textClipped(p.dl, p.font(.regular), 12, r.x + 12, r.bottom() - 22, ctx.col(.muted), if (i18n.en() and pv.description_en.len > 0) pv.description_en else pv.description, r.w - 24);
        if (sel) {
            d.circle(p.dl, r.right() - 18, r.y + 18, 10, ctx.col(.accent));
            d.line(p.dl, r.right() - 22, r.y + 18, r.right() - 19, r.y + 21, ctx.col(.accent_text), 2);
            d.line(p.dl, r.right() - 19, r.y + 21, r.right() - 13, r.y + 14, ctx.col(.accent_text), 2);
        }
    }
    const rows = (previews.len + cols - 1) / cols;
    p.y += @as(f32, @floatFromInt(rows)) * (ch + gap) + 4;
}

/// Desenho em miniatura do layout de cada tema.
fn miniature(dl: *c.ImDrawList, pv: Preview, m: d.Rect) void {
    const radius: f32 = 8;
    d.rect(dl, m, if (pv.transparent) pv.accent.mix(pv.bg, 0.55) else pv.bg, radius);
    const u = m.w / 100;
    const line_col = pv.text.alpha(0.35);
    switch (pv.kind) {
        .desktop => {
            // Papel de parede, janela flutuante com semáforo e Dock.
            d.rect(dl, m, pv.accent.mix(pv.bg, 0.45), radius);
            d.rect(dl, .{ .x = m.x, .y = m.y, .w = m.w, .h = 4 * u }, pv.bg.alpha(0.5), 0);
            const win: d.Rect = .{ .x = m.x + 8 * u, .y = m.y + 8 * u, .w = m.w - 16 * u, .h = m.h - 21 * u };
            d.shadow(dl, win, 3 * u, 3 * u, d.Rgba.black.alpha(0.4));
            d.rect(dl, win, pv.surface, 3 * u);
            d.rectFlags(dl, .{ .x = win.x, .y = win.y, .w = 22 * u, .h = win.h }, pv.sidebar.mix(pv.accent, 0.12), 3 * u, c.ImDrawFlags_RoundCornersLeft);
            for ([_]u32{ 0xff5f57, 0xfebc2e, 0x28c840 }, 0..) |hex, i| d.circle(dl, win.x + (3 + 3 * @as(f32, @floatFromInt(i))) * u, win.y + 3 * u, 1.1 * u, d.Rgba.hex(hex));
            for (0..4) |i| d.rect(dl, .{ .x = win.x + 3 * u, .y = win.y + 8 * u + @as(f32, @floatFromInt(i)) * 5 * u, .w = 15 * u, .h = 2 * u }, line_col, u);
            for (0..3) |i| d.rect(dl, .{ .x = win.x + 27 * u, .y = win.y + 7 * u + @as(f32, @floatFromInt(i)) * 7 * u, .w = (28 + @as(f32, @floatFromInt((i * 11) % 18))) * u, .h = 3 * u }, if (i == 1) pv.accent else line_col, 1.5 * u);
            const dock: d.Rect = .{ .x = m.x + 30 * u, .y = m.bottom() - 10 * u, .w = 40 * u, .h = 7 * u };
            d.rect(dl, dock, pv.surface.alpha(0.75), 2.5 * u);
            for (0..5) |i| d.rect(dl, .{ .x = dock.x + (3 + 7.2 * @as(f32, @floatFromInt(i))) * u, .y = dock.y + 1.5 * u, .w = 4 * u, .h = 4 * u }, pv.accent.alpha(if (i == 0) 1 else 0.6), u);
        },
        .classic => {
            d.rectFlags(dl, .{ .x = m.x, .y = m.y, .w = 9 * u, .h = m.h }, pv.rail, radius, c.ImDrawFlags_RoundLeft);
            for (0..4) |i| d.circle(dl, m.x + 4.5 * u, m.y + 7 * u + @as(f32, @floatFromInt(i)) * 9 * u, 3 * u, pv.accent.alpha(if (i == 0) 1 else 0.45));
            d.rect(dl, .{ .x = m.x + 9 * u, .y = m.y, .w = 22 * u, .h = m.h }, pv.sidebar, 0);
            for (0..5) |i| d.rect(dl, .{ .x = m.x + 12 * u, .y = m.y + 6 * u + @as(f32, @floatFromInt(i)) * 6 * u, .w = 15 * u, .h = 2.2 * u }, line_col, u);
            for (0..5) |i| {
                const yy = m.y + 8 * u + @as(f32, @floatFromInt(i)) * 10 * u;
                d.circle(dl, m.x + 37 * u, yy, 2.6 * u, pv.accent.alpha(0.6));
                d.rect(dl, .{ .x = m.x + 42 * u, .y = yy - 2 * u, .w = (30 + @as(f32, @floatFromInt((i * 13) % 25))) * u, .h = 2.2 * u }, line_col, u);
            }
        },
        .glass => {
            const g = 2.5 * u;
            const card = pv.surface;
            d.rect(dl, .{ .x = m.x + g, .y = m.y + g, .w = 8 * u, .h = m.h - g * 2 - 7 * u }, card, 3 * u);
            d.rect(dl, .{ .x = m.x + g * 2 + 8 * u, .y = m.y + g, .w = 20 * u, .h = m.h - g * 2 - 7 * u }, card, 3 * u);
            const cx = m.x + g * 3 + 28 * u;
            d.rect(dl, .{ .x = cx, .y = m.y + g, .w = m.right() - cx - g, .h = 6 * u }, card, 3 * u);
            d.rect(dl, .{ .x = cx, .y = m.y + g * 2 + 6 * u, .w = m.right() - cx - g, .h = m.h - g * 4 - 13 * u }, card, 3 * u);
            d.rect(dl, .{ .x = m.x + g, .y = m.bottom() - g - 5 * u, .w = m.w - g * 2, .h = 5 * u }, card, 2.5 * u);
            for (0..4) |i| d.rect(dl, .{ .x = cx + 4 * u, .y = m.y + 18 * u + @as(f32, @floatFromInt(i)) * 7 * u, .w = (25 + @as(f32, @floatFromInt((i * 11) % 20))) * u, .h = 2 * u }, line_col, u);
        },
        .terminal => {
            d.rect(dl, .{ .x = m.x, .y = m.y, .w = m.w, .h = 5 * u }, pv.elevated, 0);
            d.rect(dl, .{ .x = m.x + 2 * u, .y = m.y + 1 * u, .w = 10 * u, .h = 3 * u }, pv.accent, 0);
            d.border(dl, .{ .x = m.x + 2 * u, .y = m.y + 7 * u, .w = 22 * u, .h = m.h - 18 * u }, pv.text.alpha(0.3), 0, 1);
            d.border(dl, .{ .x = m.x + 26 * u, .y = m.y + 7 * u, .w = m.w - 28 * u, .h = m.h - 18 * u }, pv.accent.alpha(0.8), 0, 1);
            for (0..6) |i| {
                const yy = m.y + 11 * u + @as(f32, @floatFromInt(i)) * 5.5 * u;
                d.rect(dl, .{ .x = m.x + 29 * u, .y = yy, .w = 6 * u, .h = 1.8 * u }, pv.text.alpha(0.3), 0);
                d.rect(dl, .{ .x = m.x + 37 * u, .y = yy, .w = 8 * u, .h = 1.8 * u }, pv.accent.alpha(0.7), 0);
                d.rect(dl, .{ .x = m.x + 47 * u, .y = yy, .w = (20 + @as(f32, @floatFromInt((i * 17) % 30))) * u, .h = 1.8 * u }, pv.text.alpha(0.55), 0);
            }
            d.rect(dl, .{ .x = m.x, .y = m.bottom() - 5 * u, .w = m.w, .h = 5 * u }, pv.elevated, 0);
        },
        .bubbles => {
            d.rect(dl, .{ .x = m.x + 3 * u, .y = m.y + 3 * u, .w = m.w - 6 * u, .h = 7 * u }, pv.surface, 3.5 * u);
            for (0..4) |i| d.rect(dl, .{ .x = m.x + 5 * u + @as(f32, @floatFromInt(i)) * 14 * u, .y = m.y + 4.5 * u, .w = 12 * u, .h = 4 * u }, if (i == 0) pv.accent.alpha(0.3) else pv.text.alpha(0.08), 2 * u);
            d.rect(dl, .{ .x = m.x + 3 * u, .y = m.y + 13 * u, .w = 24 * u, .h = m.h - 16 * u }, pv.surface, 4 * u);
            for (0..4) |i| d.rect(dl, .{ .x = m.x + 5 * u, .y = m.y + 16 * u + @as(f32, @floatFromInt(i)) * 7 * u, .w = 20 * u, .h = 5 * u }, if (i == 1) pv.accent else pv.text.alpha(0.06), 2.5 * u);
            const cx = m.x + 30 * u;
            d.rect(dl, .{ .x = cx, .y = m.y + 13 * u, .w = m.right() - cx - 3 * u, .h = m.h - 16 * u }, pv.surface, 4 * u);
            d.rect(dl, .{ .x = cx + 4 * u, .y = m.y + 18 * u, .w = 28 * u, .h = 6 * u }, pv.elevated, 3 * u);
            d.rect(dl, .{ .x = m.right() - 40 * u, .y = m.y + 27 * u, .w = 32 * u, .h = 6 * u }, pv.bubble, 3 * u);
            d.rect(dl, .{ .x = cx + 4 * u, .y = m.y + 36 * u, .w = 22 * u, .h = 6 * u }, pv.elevated, 3 * u);
        },
        .mirror => {
            d.rectFlags(dl, .{ .x = m.right() - 9 * u, .y = m.y, .w = 9 * u, .h = m.h }, pv.rail, radius, c.ImDrawFlags_RoundRight);
            for (0..4) |i| d.rect(dl, .{ .x = m.right() - 7.5 * u, .y = m.y + 4 * u + @as(f32, @floatFromInt(i)) * 9 * u, .w = 6 * u, .h = 6 * u }, pv.accent.alpha(if (i == 0) 1 else 0.4), u);
            d.rect(dl, .{ .x = m.right() - 31 * u, .y = m.y, .w = 22 * u, .h = m.h }, pv.sidebar, 0);
            d.rect(dl, .{ .x = m.right() - 28 * u, .y = m.y + 4 * u, .w = 15 * u, .h = 2.5 * u }, pv.accent, u);
            for (0..4) |i| d.rect(dl, .{ .x = m.right() - 28 * u, .y = m.y + 12 * u + @as(f32, @floatFromInt(i)) * 6 * u, .w = 14 * u, .h = 2 * u }, line_col, u);
            for (0..5) |i| {
                const yy = m.y + 8 * u + @as(f32, @floatFromInt(i)) * 10 * u;
                d.rect(dl, .{ .x = m.x + 5 * u, .y = yy - 2.5 * u, .w = 5 * u, .h = 5 * u }, pv.accent.alpha(0.6), u);
                d.rect(dl, .{ .x = m.x + 13 * u, .y = yy - 1 * u, .w = (28 + @as(f32, @floatFromInt((i * 13) % 22))) * u, .h = 2.2 * u }, line_col, u);
            }
        },
        .office => {
            d.rectFlags(dl, .{ .x = m.x, .y = m.y, .w = 28 * u, .h = m.h }, pv.sidebar, radius, c.ImDrawFlags_RoundLeft);
            for (0..3) |i| {
                const yy = m.y + 5 * u + @as(f32, @floatFromInt(i)) * 6 * u;
                d.rect(dl, .{ .x = m.x + 3 * u, .y = yy, .w = 4 * u, .h = 4 * u }, pv.accent.mix(d.Rgba.white, 0.3), u);
                d.rect(dl, .{ .x = m.x + 9 * u, .y = yy + 1 * u, .w = 14 * u, .h = 2 * u }, d.Rgba.white.alpha(0.6), u);
            }
            for (0..5) |i| d.rect(dl, .{ .x = m.x + 3 * u, .y = m.y + 26 * u + @as(f32, @floatFromInt(i)) * 5.5 * u, .w = 22 * u, .h = 3.5 * u }, if (i == 1) pv.accent else d.Rgba.white.alpha(0.12), u);
            for (0..5) |i| {
                const yy = m.y + 8 * u + @as(f32, @floatFromInt(i)) * 10 * u;
                d.rect(dl, .{ .x = m.x + 32 * u, .y = yy - 2.5 * u, .w = 5 * u, .h = 5 * u }, pv.accent.alpha(0.5), u);
                d.rect(dl, .{ .x = m.x + 40 * u, .y = yy - 1 * u, .w = (28 + @as(f32, @floatFromInt((i * 13) % 22))) * u, .h = 2.2 * u }, pv.text.alpha(0.35), u);
            }
        },
        .zen => {
            const cx = m.x + m.w * 0.22;
            const cw = m.w * 0.56;
            d.rect(dl, .{ .x = cx, .y = m.y + 5 * u, .w = 20 * u, .h = 3 * u }, pv.text.alpha(0.7), u);
            for (0..5) |i| d.rect(dl, .{ .x = cx, .y = m.y + 14 * u + @as(f32, @floatFromInt(i)) * 7 * u, .w = cw * (0.5 + @as(f32, @floatFromInt((i * 7) % 5)) / 10), .h = 2.4 * u }, line_col, u);
            d.rect(dl, .{ .x = cx, .y = m.bottom() - 10 * u, .w = cw, .h = 6 * u }, pv.elevated, 3 * u);
        },
    }
}

/// E-mail só aparece ao clicar em "Mostrar" (não fica na tela num print).
var show_email = false;
var mask_buf: [64]u8 = undefined;

/// "ab•••••@g••••.com": as duas primeiras letras e o fim do domínio.
fn maskEmail(buf: []u8, email: []const u8) []const u8 {
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return "••••••••";
    const dot = std.mem.lastIndexOfScalar(u8, email, '.') orelse email.len;
    const head = email[0..@min(2, at)];
    const tail = if (dot > at) email[dot..] else "";
    return std.fmt.bufPrint(buf, "{s}••••••@••••••{s}", .{ head, tail }) catch "••••••••";
}

fn account(p: *Page) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    const me = ctx.store.user(ctx.store.me) orelse return;
    p.title(i18n.tr("Minha conta", "My Account"));
    const card: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = 250 };
    d.rect(p.dl, card, ctx.col(.rail), 10);
    const banner: d.Rect = .{ .x = card.x, .y = card.y, .w = card.w, .h = 100 };
    const col = ctx.th.role(me.role);
    c.ImDrawList_AddRectFilledMultiColor(p.dl, d.v(banner.x, banner.y), d.v(banner.right(), banner.bottom()), col.u(), ctx.col(.accent).u(), ctx.col(.accent).mix(d.Rgba.black, 0.3).u(), col.mix(d.Rgba.black, 0.3).u());
    d.circle(p.dl, card.x + 64, banner.bottom(), 46, ctx.col(.rail));
    w.avatar(ctx, p.dl, card.x + 64, banner.bottom(), 80, me.id, .circle, ctx.col(.rail), 1);
    d.text(p.dl, p.font(.bold), 20, card.x + 120, banner.bottom() + 10, ctx.col(.text), me.name);
    const er: d.Rect = .{ .x = card.x + 16, .y = banner.bottom() + 56, .w = card.w - 32, .h = 80 };
    d.rect(p.dl, er, ctx.col(.sidebar), 8);
    const hidden = "••••••••";
    var ub: [80]u8 = undefined;
    const uname = if (ctx.store.me_username) |x| (if (s.streamer_mode) hidden else std.fmt.bufPrint(&ub, "@{s}", .{x}) catch x) else "—";
    d.text(p.dl, p.font(.bold), 12, er.x + 14, er.y + 12, ctx.col(.muted), i18n.tr("NOME DE USUÁRIO", "USERNAME"));
    d.text(p.dl, p.font(.medium), 15, er.x + 14, er.y + 28, ctx.col(.text), uname);
    const ex = er.x + er.w / 2;
    d.text(p.dl, p.font(.bold), 12, ex, er.y + 12, ctx.col(.muted), i18n.tr("E-MAIL", "EMAIL"));
    // Escondido até pedir (botão Mostrar), e sempre no modo streamer.
    const visible = show_email and !s.streamer_mode;
    const email = if (ctx.store.me_email) |x| (if (visible) x else maskEmail(&mask_buf, x)) else if (ctx.store.demo) i18n.tr("— (demonstração)", "— (demo)") else "—";
    const ew = d.textClipped(p.dl, p.font(.medium), 15, ex, er.y + 28, ctx.col(.text), email, er.w / 2 - 80);
    if (ctx.store.me_email != null and !s.streamer_mode) {
        const lbl = if (show_email) i18n.tr("Esconder", "Hide") else i18n.tr("Mostrar", "Reveal");
        const br: d.Rect = .{ .x = ex + ew + 8, .y = er.y + 26, .w = d.width(p.font(.semibold), 13, lbl) + 4, .h = 20 };
        const hb = d.hit(ctx, p.id(), br);
        qa.mark(br, "email-toggle", .{});
        d.text(p.dl, p.font(.semibold), 13, br.x + 2, d.centerY(br, 13), if (hb.hovered) ctx.col(.text) else ctx.col(.link), lbl);
        if (hb.clicked) show_email = !show_email;
    }
    d.text(p.dl, p.font(.regular), 12.5, er.x + 14, er.y + 54, ctx.col(.faint), i18n.tr("Nome, foto e senha se mudam pelo app oficial ou pelo site.", "Name, picture and password are changed in the official app or website."));
    p.y += card.h + 24;
    p.heading(i18n.tr("Sessão", "Session"));
    p.note(if (ctx.store.demo) i18n.tr("Você está no modo demonstração. Sair leva à tela de login.", "You're in demo mode. Logging out takes you to the sign-in screen.") else i18n.tr("Sair desconecta e apaga o token desta conta neste computador (as outras contas guardadas continuam).", "Logging out disconnects and deletes this account's token from this computer (other saved accounts stay)."));
    if (p.button(i18n.tr("Sair", "Log Out"), true)) ctx.act(.logout);
    p.y += 8;
}

fn statRow(p: *Page, h: f32, label: []const u8, value: []const u8) void {
    const ctx = p.ctx;
    const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = h };
    d.rect(p.dl, r, ctx.col(.rail).alpha(0.6), ctx.th.radius + 2);
    d.text(p.dl, p.font(.medium), 15, r.x + 16, d.centerY(r, 15), ctx.col(.muted), label);
    p.markText(.{ .x = r.x + 16, .y = d.centerY(r, 15), .w = d.width(p.font(.medium), 15, label), .h = 15 });
    const vw = d.width(p.font(.bold), 18, value);
    d.text(p.dl, p.font(.bold), 18, r.right() - 16 - vw, d.centerY(r, 18), ctx.col(.accent).mix(ctx.col(.text), 0.3), value);
    p.markText(.{ .x = r.right() - 16 - vw, .y = d.centerY(r, 18), .w = vw, .h = 18 });
    p.y += h + 8;
}

fn mbText(buf: []u8, prefix: []const u8, kb: u64) []const u8 {
    if (kb < 1024) return std.fmt.bufPrint(buf, "{s}{d} KB", .{ prefix, kb }) catch "";
    return std.fmt.bufPrint(buf, "{s}{d}.{d} MB", .{ prefix, kb / 1024, (kb % 1024) * 10 / 1024 }) catch "";
}

/// Varrer a conta custa: basta de vez em quando, e só com a página aberta.
pub var mem_use: mem_use_mod.MemUse = .{};
var mem_use_ms: i64 = 0;

fn memoryRows(p: *Page) void {
    const ctx = p.ctx;
    const row_h = 44;
    if (ctx.now_ms - mem_use_ms >= 2000 or ctx.now_ms < mem_use_ms) {
        mem_use_ms = ctx.now_ms;
        mem_use = mem_use_mod.of(ctx.store);
    }
    var l: [64]u8 = undefined;
    var v: [32]u8 = undefined;
    p.heading(i18n.tr("Para onde vai a memória", "Where the memory goes"));
    statRow(p, row_h, i18n.fmt(&l, "Imagens ({d})", "Images ({d})", .{ctx.images.readyCount()}), mbText(&v, "", ctx.images.bytes / 1024));
    statRow(p, row_h, i18n.fmt(&l, "Mensagens ({d})", "Messages ({d})", .{mem_use.n_messages}), mbText(&v, "~", mem_use.messages / 1024));
    statRow(p, row_h, i18n.fmt(&l, "Pessoas ({d})", "People ({d})", .{mem_use.n_people}), mbText(&v, "~", mem_use.people / 1024));
    statRow(p, row_h, i18n.fmt(&l, "Servidores ({d}) e canais ({d})", "Servers ({d}) and channels ({d})", .{ mem_use.n_guilds, mem_use.n_channels }), mbText(&v, "~", mem_use.places / 1024));
    if (ctx.io.*.Fonts.*.TexData) |tex| statRow(p, row_h, i18n.tr("Atlas de fontes", "Font atlas"), mbText(&v, "", @as(u64, @intCast(tex.*.Width * tex.*.Height * tex.*.BytesPerPixel)) / 1024));
    // O que este sistema não informa fica de fora, em vez de aparecer zerado.
    const used = @atomicLoad(u32, &ctx.stats.heap_used_kb, .monotonic);
    const free = @atomicLoad(u32, &ctx.stats.heap_free_kb, .monotonic);
    const file = @atomicLoad(u32, &ctx.stats.file_kb, .monotonic);
    if (used > 0) {
        statRow(p, row_h, i18n.tr("Alocada no total", "Allocated in total"), mbText(&v, "", used));
        statRow(p, row_h, i18n.tr("Livre, ainda não devolvida", "Free, not returned yet"), mbText(&v, "", free));
    }
    if (file > 0) statRow(p, row_h, i18n.tr("Driver, bibliotecas e fontes", "Driver, libraries and fonts"), mbText(&v, "", file));
    p.note(i18n.tr("Com ~ é estimativa. As imagens podem estar na memória da placa de vídeo, e não na RAM.", "Values with ~ are estimates. Images may live in video memory rather than RAM."));
}

fn performance(p: *Page) void {
    const ctx = p.ctx;
    p.title(i18n.tr("Desempenho", "Performance"));
    p.note(i18n.tr("Números ao vivo deste processo.", "Live numbers from this process."));
    var buf: [128]u8 = undefined;
    @atomicStore(bool, &ctx.stats.ram_seen, true, .monotonic);
    const built = ctx.stats.frames_built;
    const skipped = ctx.stats.frames_skipped;
    const stats = [_]struct { label: []const u8, value: []const u8 }{
        .{ .label = "RAM (PSS)", .value = mbText(buf[0..32], "", ctx.stats.ram_kb) },
        .{ .label = i18n.tr("Tempo de CPU por quadro", "CPU time per frame"), .value = std.fmt.bufPrint(buf[32..64], "{d}.{d:0>2} ms", .{ ctx.stats.frame_us / 1000, (ctx.stats.frame_us % 1000) / 10 }) catch "" },
        .{ .label = i18n.tr("Quadros iguais, sem desenhar", "Unchanged frames, not drawn"), .value = std.fmt.bufPrint(buf[96..128], "{d}% ({d})", .{ skipped * 100 / @max(built, 1), skipped }) catch "" },
        .{ .label = i18n.tr("CPU parado", "Idle CPU"), .value = i18n.tr("0% (dorme esperando eventos)", "0% (sleeps until there are events)") },
        .{ .label = i18n.tr("Mensagens por canal", "Messages per channel"), .value = i18n.fmt(buf[64..96], "até {d} na memória", "up to {d} in memory", .{ctx.store.max_messages}) },
    };
    for (stats) |st| statRow(p, 56, st.label, st.value);
    memoryRows(p);
}

fn about(p: *Page) void {
    const ctx = p.ctx;
    p.title(i18n.tr("Sobre", "About"));
    d.text(p.dl, p.font(.bold), 28, p.x, p.y, ctx.col(.accent), "larperCord");
    p.y += 40;
    p.note(i18n.tr("Cliente de Discord nativo: Zig + SDL3 + Dear ImGui + FreeType.", "Native Discord client: Zig + SDL3 + Dear ImGui + FreeType."));
    p.note(i18n.tr("Temas em KDL que reorganizam a interface inteira, recarregados ao salvar.", "KDL themes that rearrange the whole interface, reloaded on save."));
    var about_buf: [96]u8 = undefined;
    p.note(i18n.fmt(&about_buf, "Versão {s} · voz com E2EE (DAVE), mixer por pessoa e Opus 48 kHz.", "Version {s} · voice with E2EE (DAVE), per-person mixer and Opus 48 kHz.", .{@import("build_options").version}));
    p.note(i18n.tr("Cliente não oficial: usar contas de usuário fora do app oficial vai contra os termos do Discord.", "Unofficial client: using user accounts outside the official app is against Discord's terms."));
    p.divider();
    p.heading(i18n.tr("Feito com", "Built with"));
    for ([_][]const u8{ "Zig 0.17", "SDL 3.4", "Dear ImGui 1.93 (dear_bindings)", "FreeType + fontconfig", "libcurl + zlib", "stb_image", "Lua 5.4 (plugins)", "Inter, JetBrains Mono, Noto Color Emoji" }) |t| p.note(t);
}
