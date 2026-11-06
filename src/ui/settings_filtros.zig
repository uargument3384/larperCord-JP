//! Configurações → Alertas e filtros: palavras de alerta, filtro de
//! palavras, pessoas ignoradas e o modo foco (core/filtros.zig).
//! Mesmo visual das outras páginas (ui/settings.zig).
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const w = @import("widgets.zig");
const i18n = @import("i18n.zig");
const filtros = @import("../core/filtros.zig");
const Id = @import("../core/types.zig").Id;

var alert_buf: [filtros.max_word_len + 1]u8 = @splat(0);
var filter_buf: [filtros.max_word_len + 1]u8 = @splat(0);
/// Depois de acrescentar com Enter, a caixa volta a ter o foco.
var refocus: ?filtros.Which = null;

const P = struct {
    ctx: *d.Ctx,
    dl: *c.ImDrawList,
    x: f32,
    y: f32,
    w: f32,

    fn heading(p: *P, t: []const u8) void {
        p.y += 8;
        var buf: [96]u8 = undefined;
        d.text(p.dl, p.ctx.ui.get(.bold), 12, p.x, p.y, p.ctx.col(.muted), d.upper(&buf, t));
        p.y += 26;
    }

    fn note(p: *P, t: []const u8) void {
        _ = d.textClipped(p.dl, p.ctx.ui.get(.regular), 13.5, p.x, p.y, p.ctx.col(.faint), t, p.w);
        p.y += 26;
    }

    fn divider(p: *P) void {
        p.y += 10;
        d.line(p.dl, p.x, p.y, p.x + p.w, p.y, p.ctx.col(.border).mix(p.ctx.col(.text), 0.03), 1);
        p.y += 20;
    }

    /// Botão com o rótulo (português) como marca do QA.
    fn button(p: *P, id: usize, r: d.Rect, comptime pt: []const u8, comptime en: []const u8, primary: bool) bool {
        const ctx = p.ctx;
        const hb = d.hit(ctx, id, r);
        qa.mark(r, "button:{s}", .{pt});
        const f = ctx.ui.get(.semibold);
        const label = i18n.tr(pt, en);
        if (primary) {
            d.rect(p.dl, r, if (hb.hovered) ctx.col(.accent).mix(d.Rgba.black, 0.12) else ctx.col(.accent), ctx.th.radius);
        } else {
            d.rect(p.dl, r, ctx.col(.rail).mix(ctx.col(.elevated), if (hb.hovered) 0.6 else 0.3), ctx.th.radius);
            d.border(p.dl, r, ctx.col(.border), ctx.th.radius, 1);
        }
        const tw = d.width(f, 14, label);
        d.text(p.dl, f, 14, r.x + (r.w - tw) / 2, d.centerY(r, 14), if (primary) ctx.col(.accent_text) else ctx.col(.text), label);
        return hb.clicked;
    }
};

pub fn page(ctx: *d.Ctx, dl: *c.ImDrawList, x: f32, y: *f32, wd: f32) void {
    var p: P = .{ .ctx = ctx, .dl = dl, .x = x, .y = y.*, .w = wd };
    defer y.* = p.y;
    d.text(dl, ctx.ui.get(.bold), 22, p.x, p.y, ctx.col(.text), i18n.tr("Alertas e filtros", "Alerts & Filters"));
    p.y += 44;
    p.note(i18n.tr("Tudo aqui fica só neste computador: ninguém fica sabendo.", "Everything here stays on this computer: nobody is told."));

    p.heading(i18n.tr("Palavras de alerta", "Alert words"));
    p.note(i18n.tr("Mensagem com a palavra inteira (sem diferenciar maiúsculas) conta como menção.", "A message with the whole word (any case) counts as a mention."));
    words(&p, .alert, &alert_buf);
    p.divider();

    p.heading(i18n.tr("Filtro de palavras", "Word filter"));
    p.note(i18n.tr("Mensagens com estas palavras ficam recolhidas (clique para mostrar) e não notificam.", "Messages with these words are collapsed (click to show) and never notify."));
    words(&p, .filter, &filter_buf);
    p.divider();

    p.heading(i18n.tr("Pessoas ignoradas", "Ignored people"));
    p.note(i18n.tr("Ignorar não bloqueia: as mensagens só ficam recolhidas aqui. Botão direito numa pessoa → Ignorar.", "Ignoring isn't blocking: messages are just collapsed here. Right-click someone → Ignore."));
    ignoredList(&p);
    p.divider();

    p.heading(i18n.tr("Modo foco", "Focus mode"));
    p.note(i18n.tr("Por um tempo, só mensagens diretas e menções notificam e marcam não lido.", "For a while, only direct messages and mentions notify and mark unread."));
    focus(&p);
}

fn words(p: *P, which: filtros.Which, buf: []u8) void {
    const ctx = p.ctx;
    const f = &ctx.st.filtros;
    const tag = if (which == .alert) "alerta" else "filtro";
    const base: usize = if (which == .alert) 0x5F000 else 0x5F400;

    // Caixa de texto + "Adicionar".
    const bw: f32 = 120;
    const ir: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w - bw - 10, .h = 38 };
    d.rect(p.dl, ir, ctx.col(.rail).mix(ctx.col(.elevated), 0.3), ctx.th.radius);
    d.border(p.dl, ir, ctx.col(.border), ctx.th.radius, 1);
    c.ImGui_PushFontFloat(ctx.ui.get(.regular), 15);
    c.ImGui_SetCursorScreenPos(d.v(ir.x + 10, ir.y + 8));
    c.ImGui_SetNextItemWidth(ir.w - 20);
    if (refocus == which) {
        refocus = null;
        c.ImGui_SetKeyboardFocusHere();
    }
    const hint = if (which == .alert) i18n.tr("Ex.: seu nome, um projeto, \"bom dia\"", "E.g. your name, a project, \"good morning\"") else i18n.tr("Ex.: spoiler, um assunto", "E.g. spoiler, a topic");
    var hz: [96]u8 = undefined;
    const hint_z = std.fmt.bufPrintSentinel(&hz, "{s}", .{hint}, 0) catch "";
    const enter = c.ImGui_InputTextWithHint(if (which == .alert) "##alert-word" else "##filter-word", hint_z.ptr, buf.ptr, buf.len, c.ImGuiInputTextFlags_EnterReturnsTrue);
    c.ImGui_PopFont();
    qa.mark(ir, "word-input:{s}", .{tag});
    const br: d.Rect = .{ .x = ir.right() + 10, .y = ir.y + 1, .w = bw, .h = 36 };
    const add = if (which == .alert) p.button(base, br, "Adicionar alerta", "Add alert", true) else p.button(base, br, "Adicionar filtro", "Add filter", true);
    p.y += 50;
    if (enter or add) {
        const text = std.mem.sliceTo(buf, 0);
        switch (f.addWord(ctx.st.gpa, which, text)) {
            .added => {
                @memset(buf, 0);
                if (enter) refocus = which;
            },
            .empty => ctx.st.showToast(ctx.now_ms, false, "escreva uma palavra ou expressão", "type a word or phrase", .{}),
            .exists => ctx.st.showToast(ctx.now_ms, false, "essa já está na lista", "that one is already on the list", .{}),
            .full => ctx.st.showToast(ctx.now_ms, true, "lista cheia ({d} no máximo)", "list is full ({d} at most)", .{filtros.max_words}),
        }
    }

    // As palavras, como etiquetas com um × para tirar.
    const l = f.list(which);
    if (l.items.len == 0) {
        p.note(i18n.tr("Nenhuma ainda.", "None yet."));
        return;
    }
    var cx = p.x;
    var remove: ?usize = null;
    for (l.items, 0..) |word, i| {
        const cw = @min(d.width(ctx.ui.get(.medium), 14, word), p.w - 60) + 44;
        if (cx + cw > p.x + p.w and cx > p.x) {
            cx = p.x;
            p.y += 38;
        }
        drawChip(p, .{ .x = cx, .y = p.y, .w = cw, .h = 30 }, word, base + 1 + i, which, i, &remove);
        cx += cw + 8;
    }
    p.y += 42;
    if (remove) |i| f.removeWord(ctx.st.gpa, which, i);
}

fn drawChip(p: *P, chip: d.Rect, word: []const u8, id: usize, which: filtros.Which, i: usize, remove: *?usize) void {
    const ctx = p.ctx;
    const fam = ctx.ui;
    const accent = if (which == .alert) ctx.col(.idle) else ctx.col(.danger);
    d.rect(p.dl, chip, accent.alpha(0.14), 15);
    d.border(p.dl, chip, accent.alpha(0.5), 15, 1);
    _ = d.textClipped(p.dl, fam.get(.medium), 14, chip.x + 12, d.centerY(chip, 14), ctx.col(.text), word, chip.w - 40);
    const xr: d.Rect = .{ .x = chip.right() - 28, .y = chip.y + 3, .w = 24, .h = 24 };
    const hb = d.hit(ctx, id, xr);
    qa.mark(xr, "word-remove:{s}:{d}", .{ if (which == .alert) "alerta" else "filtro", i });
    const xc = if (hb.hovered) ctx.col(.text) else ctx.col(.muted);
    if (hb.hovered) d.circle(p.dl, xr.x + 12, xr.y + 12, 10, ctx.col(.hover));
    d.line(p.dl, xr.x + 8, xr.y + 8, xr.x + 16, xr.y + 16, xc, 1.6);
    d.line(p.dl, xr.x + 16, xr.y + 8, xr.x + 8, xr.y + 16, xc, 1.6);
    d.tip(ctx, xr, i18n.tr("Tirar da lista", "Remove"), hb.hovered);
    if (hb.clicked) remove.* = i;
}

fn ignoredList(p: *P) void {
    const ctx = p.ctx;
    const f = &ctx.st.filtros;
    const ids = f.ignored.keys();
    if (ids.len == 0) {
        p.note(i18n.tr("Ninguém ignorado.", "Nobody ignored."));
        return;
    }
    var drop: ?Id = null;
    for (ids, 0..) |uid, i| {
        const row: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = 48 };
        d.rect(p.dl, row, ctx.col(.rail).alpha(0.5), ctx.th.radius);
        w.avatar(ctx, p.dl, row.x + 26, row.y + 24, 32, uid, .circle, null, 1);
        var nb: [48]u8 = undefined;
        const name = if (ctx.store.user(uid)) |u| u.name else std.fmt.bufPrint(&nb, "ID {d}", .{uid}) catch "?";
        _ = d.textClipped(p.dl, ctx.ui.get(.semibold), 15, row.x + 52, d.centerY(row, 15), ctx.col(.text), name, row.w - 240);
        const label = i18n.tr("Deixar de ignorar", "Unignore");
        const bw = d.width(ctx.ui.get(.semibold), 14, label) + 28;
        const br: d.Rect = .{ .x = row.right() - bw - 8, .y = row.y + 7, .w = bw, .h = 34 };
        const hb = d.hit(ctx, 0x5F800 + i, br);
        qa.mark(br, "unignore:{d}", .{uid});
        d.rect(p.dl, br, ctx.col(.elevated).mix(ctx.col(.text), if (hb.hovered) 0.06 else 0), ctx.th.radius);
        d.border(p.dl, br, ctx.col(.border), ctx.th.radius, 1);
        d.text(p.dl, ctx.ui.get(.semibold), 14, br.x + 14, d.centerY(br, 14), ctx.col(.text), label);
        if (hb.clicked) drop = uid;
        p.y += 56;
    }
    if (drop) |uid| f.setIgnored(ctx.st.gpa, uid, false);
}

fn focus(p: *P) void {
    const ctx = p.ctx;
    const f = &ctx.st.filtros;
    const on = f.focusOn(ctx.now_ms);
    const opts = [_]struct { pt: []const u8, en: []const u8, ja: []const u8, min: ?u32 }{
        .{ .pt = "Desligado", .en = "Off", .ja = "オフ", .min = null },
        .{ .pt = "15 min", .en = "15 min", .ja = "15分", .min = 15 },
        .{ .pt = "30 min", .en = "30 min", .ja = "30分", .min = 30 },
        .{ .pt = "1 h", .en = "1 h", .ja = "1時間", .min = 60 },
        .{ .pt = "Até desligar", .en = "Until I turn it off", .ja = "解除するまで", .min = 0 },
    };
    const gap: f32 = 8;
    const bw = (p.w - gap * @as(f32, @floatFromInt(opts.len - 1))) / @as(f32, @floatFromInt(opts.len));
    for (opts, 0..) |o, i| {
        const r: d.Rect = .{ .x = p.x + @as(f32, @floatFromInt(i)) * (bw + gap), .y = p.y, .w = bw, .h = 44 };
        const hb = d.hit(ctx, 0x5FC00 + i, r);
        qa.mark(r, "seg:{s}", .{o.pt});
        const sel = if (o.min) |m| (on and m == 0 and f.focus_until == filtros.forever) else !on;
        d.rect(p.dl, r, ctx.col(.rail).alpha(0.6).mix(ctx.col(.accent).alpha(0.22), if (sel) 1 else if (hb.hovered) 0.4 else 0), ctx.th.radius + 2);
        d.border(p.dl, r, if (sel) ctx.col(.accent) else ctx.col(.border), ctx.th.radius + 2, if (sel) 2 else 1);
        const label = if (i18n.ja()) o.ja else if (i18n.en()) o.en else o.pt;
        const tw = d.width(ctx.ui.get(.semibold), 15, label);
        _ = d.textClipped(p.dl, ctx.ui.get(.semibold), 15, r.x + @max(6, (r.w - tw) / 2), d.centerY(r, 15), if (sel) ctx.col(.text) else ctx.col(.muted), label, r.w - 12);
        if (hb.clicked) {
            if (o.min) |m| f.startFocus(ctx.now_ms, m) else if (on) f.endFocus(ctx.store);
        }
    }
    p.y += 58;
    var buf: [96]u8 = undefined;
    if (!on) {
        p.note(i18n.tr("Desligado. Também dá para ligar clicando no seu nome, embaixo à esquerda.", "Off. You can also turn it on by clicking your name, bottom left."));
    } else if (f.focusLeftMin(ctx.now_ms)) |mins| {
        p.note(i18n.fmt(&buf, "Ligado: faltam {d} min. O que chegar nos canais volta como não lido no fim.", "On: {d} min left. What arrives in channels shows as unread at the end.", .{mins}));
    } else p.note(i18n.tr("Ligado até você desligar. O que chegar nos canais volta como não lido no fim.", "On until you turn it off. What arrives in channels shows as unread at the end."));
}
