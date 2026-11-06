//! Anexos na conversa: imagens (com o tamanho reservado antes de chegar),
//! arquivos (cartão clicável), o visualizador em tela cheia e a bandeja do
//! que vai ser enviado junto com a próxima mensagem.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const qa = @import("qa.zig");
const types = @import("../core/types.zig");
const StoredMessage = @import("../core/store.zig").StoredMessage;
const state = @import("state.zig");
const i18n = @import("i18n.zig");
const video = @import("video.zig");

const Attachment = types.Attachment;

const max_w: f32 = 420;
const max_h: f32 = 320;
const file_h: f32 = 58;
const gap: f32 = 6;

/// Configurações → Chat → Mostrar imagens de links (desligado = esconde os
/// anexos que vieram de embeds). Atualizado a cada quadro pelo app.
pub var hide_embeds = false;

fn shown(a: *const Attachment) bool {
    return !(hide_embeds and a.embed);
}

/// Tamanho em que a imagem aparece na conversa (nunca maior que o original).
pub fn imageSize(a: *const Attachment, avail: f32) [2]f32 {
    const w: f32 = @floatFromInt(a.width);
    const h: f32 = @floatFromInt(a.height);
    const s = @min(1.0, @min(@min(max_w, avail) / w, max_h / h));
    return .{ @max(40, @round(w * s)), @max(32, @round(h * s)) };
}

fn fileWidth(avail: f32) f32 {
    return @min(avail, 400);
}

/// Altura do bloco de anexos, contando o espaço acima dele.
pub fn blockHeight(list: []const Attachment, avail: f32, has_text: bool) f32 {
    var h: f32 = if (has_text) gap else 2;
    var n: usize = 0;
    for (list) |*a| {
        if (!shown(a)) continue;
        if (n > 0) h += gap;
        n += 1;
        h += if (a.isImage()) imageSize(a, avail)[1] else file_h;
    }
    return if (n == 0) 0 else h;
}

/// Largura mais larga do bloco (para o balão do tema de bolhas).
pub fn blockWidth(list: []const Attachment, avail: f32) f32 {
    var w: f32 = 0;
    for (list) |*a| if (shown(a)) {
        w = @max(w, if (a.isImage()) imageSize(a, avail)[0] else fileWidth(avail));
    };
    return w;
}

pub fn formatSize(buf: []u8, bytes: u64) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    if (bytes >= 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} MB", .{b / (1024 * 1024)}) catch "";
    if (bytes >= 1024) return std.fmt.bufPrint(buf, "{d:.0} KB", .{b / 1024}) catch "";
    return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "";
}

/// Desenha os anexos a partir de (x, y). `alpha` < 1 enquanto envia.
pub fn draw(ctx: *d.Ctx, dl: *c.ImDrawList, m: *const StoredMessage, x: f32, y_in: f32, avail: f32, alpha: f32) void {
    const list = m.msg.attachments;
    if (list.len == 0) return;
    var y = y_in + (if (m.msg.content.len > 0) gap else 2);
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    var shown_n: usize = 0;
    for (list, 0..) |*a, i| {
        if (!shown(a)) continue;
        if (shown_n > 0) y += gap;
        shown_n += 1;
        const hid: usize = @truncate(m.msg.id ^ (0xA77A_C400 + i) ^ m.msg.nonce);
        if (a.isImage()) {
            const sz = imageSize(a, avail);
            const r: d.Rect = .{ .x = x, .y = y, .w = sz[0], .h = sz[1] };
            image(ctx, dl, a, r, scale, alpha, hid, m.msg.id, i);
            markVisible(r, m.msg.id, i);
            y += sz[1];
        } else {
            const r: d.Rect = .{ .x = x, .y = y, .w = fileWidth(avail), .h = file_h };
            fileCard(ctx, dl, a, r, alpha, hid);
            markVisible(r, m.msg.id, i);
            y += file_h;
        }
    }
}

/// A marca do QA cobre só o pedaço à vista: rolado para trás do cabeçalho, o
/// centro do anexo inteiro cairia num botão de outra coisa.
fn markVisible(r: d.Rect, msg_id: types.Id, index: usize) void {
    if (!qa.on()) return;
    const p = c.ImGui_GetWindowPos();
    const s = c.ImGui_GetWindowSize();
    const x0 = @max(r.x, p.x);
    const y0 = @max(r.y, p.y);
    const x1 = @min(r.right(), p.x + s.x);
    const y1 = @min(r.bottom(), p.y + s.y);
    if (x1 > x0 and y1 > y0) qa.mark(.{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 }, "att:{d}:{d}", .{ msg_id, index });
}

fn image(ctx: *d.Ctx, dl: *c.ImDrawList, a: *const Attachment, r: d.Rect, scale: f32, alpha: f32, hid: usize, msg_id: types.Id, index: usize) void {
    const radius: f32 = 8;
    // Vídeo tocando aqui: o player ocupa o lugar da prévia.
    const vkey = video.keyOf(msg_id, index);
    if (a.video and video.isActive(vkey)) {
        const pv = ctx.images.get(a.url, r.w * scale, r.h * scale);
        video.draw(ctx, dl, r, alpha, msg_id, if (pv == .ready) pv.ready else null);
        return;
    }
    const hb = d.hit(ctx, hid, r);
    const set = &ctx.st.settings;
    // GIF de fora (Tenor/Giphy) desligado nas configurações: fica a prévia.
    var url = if (a.still.len > 0 and !set.gif_hosts) a.still else a.url;
    // Sem tocar sozinho, o GIF anda com o mouse em cima (como no Discord).
    const play = set.autoplay_gifs or hb.hovered;
    var look = ctx.images.getEx(url, r.w * scale, r.h * scale, play);
    if (look == .failed and a.still.len > 0 and url.ptr != a.still.ptr) {
        url = a.still;
        look = ctx.images.getEx(url, r.w * scale, r.h * scale, play);
    }
    var playing = false;
    // Modo economia: no lugar da imagem, um "clique para carregar".
    const held_back = look == .failed and ctx.images.blocked(url);
    if (held_back) {
        savedPlaceholder(ctx, dl, r, a.size, alpha);
        qa.mark(r, "att-blocked:{d}", .{msg_id});
    } else switch (look) {
        .ready => |t| {
            playing = t.animated and play;
            c.ImDrawList_AddImageRounded(dl, t.ref, d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(alpha), radius, 0);
            if (hb.hovered) d.rect(dl, r, d.Rgba.white.alpha(0.06), radius);
        },
        .loading => {
            // Esqueleto com um brilho passando enquanto baixa.
            d.rect(dl, r, ctx.col(.elevated).alpha(alpha), radius);
            const ph = @as(f32, @floatFromInt(@mod(ctx.now_ms, 1400))) / 1400.0;
            const sx = r.x - r.w * 0.4 + (r.w * 1.8) * ph;
            c.ImDrawList_PushClipRect(dl, d.v(r.x, r.y), d.v(r.right(), r.bottom()), true);
            const hl = ctx.col(.text).col(0.05 * alpha);
            c.ImDrawList_AddRectFilledMultiColor(dl, d.v(sx, r.y), d.v(sx + r.w * 0.2, r.bottom()), 0, hl, hl, 0);
            c.ImDrawList_AddRectFilledMultiColor(dl, d.v(sx + r.w * 0.2, r.y), d.v(sx + r.w * 0.4, r.bottom()), hl, 0, 0, hl);
            c.ImDrawList_PopClipRect(dl);
            pictureIcon(dl, r.x + r.w / 2, r.y + r.h / 2, ctx.col(.faint).alpha(alpha));
            anim.every(50);
        },
        .failed => {
            d.rect(dl, r, ctx.col(.elevated).alpha(alpha), radius);
            d.border(dl, r, ctx.col(.border), radius, 1);
            const f = ctx.ui.get(.medium);
            const msg = i18n.tr("imagem indisponível", "image unavailable");
            const tw = d.width(f, 13, msg);
            pictureIcon(dl, r.x + r.w / 2, r.y + r.h / 2 - 12, ctx.col(.faint));
            if (r.h > 60) d.text(dl, f, 13, r.x + (r.w - tw) / 2, r.y + r.h / 2 + 8, ctx.col(.faint), msg);
        },
    }
    if (a.video) playIcon(dl, r.x + r.w / 2, r.y + r.h / 2, alpha);
    if (a.animated and !playing) {
        const br: d.Rect = .{ .x = r.x + 8, .y = r.bottom() - 26, .w = 34, .h = 18 };
        d.rect(dl, br, d.Rgba.black.alpha(0.6 * alpha), 4);
        const f = ctx.ui.get(.bold);
        d.text(dl, f, 11, br.x + (br.w - d.width(f, 11, "GIF")) / 2, d.centerY(br, 11), d.Rgba.white.alpha(alpha), "GIF");
    }
    if (hb.clicked) {
        // Vídeo toca aqui (com FFmpeg) ou abre no navegador.
        if (held_back) {
            ctx.images.allow(url);
        } else if (a.video and a.link.len > 0) video.click(ctx, vkey, a.link, a.link, r, a.size) else open(ctx, a, url);
    }
    if (held_back) d.tip(ctx, r, i18n.tr("Modo economia: clique para baixar", "Data saver: click to download"), hb.hovered);
    if (a.video and !held_back) d.tip(ctx, r, if (video.canPlay(a.link, a.size)) i18n.tr("Tocar o vídeo", "Play video") else i18n.tr("Abrir o vídeo no navegador", "Open video in browser"), hb.hovered);
    if (hb.right and msg_id != 0) ctx.popup(.{ .menu = .{ .kind = .message, .id = msg_id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
}

/// Lugar reservado de uma imagem que o modo economia ainda não baixou.
pub fn savedPlaceholder(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, size: u64, alpha: f32) void {
    const radius: f32 = 8;
    const hovered = ctx.hovering(r);
    d.rect(dl, r, ctx.col(.elevated).mix(ctx.col(.text), if (hovered) 0.04 else 0).alpha(alpha), radius);
    d.border(dl, r, ctx.col(.accent).alpha(0.45 * alpha), radius, 1);
    pictureIcon(dl, r.x + r.w / 2, r.y + r.h / 2 - (if (r.h > 60) @as(f32, 12) else 0), ctx.col(.muted).alpha(alpha));
    if (r.h <= 60) return;
    const f = ctx.ui.get(.medium);
    var buf: [64]u8 = undefined;
    var sb: [32]u8 = undefined;
    const msg = if (size > 0) i18n.fmt(&buf, "clique para carregar · {s}", "click to load · {s}", .{formatSize(&sb, size)}) else i18n.tr("clique para carregar", "click to load");
    const tw = d.width(f, 13, msg);
    if (tw < r.w - 8) d.text(dl, f, 13, r.x + (r.w - tw) / 2, r.y + r.h / 2 + 8, ctx.col(.muted).alpha(alpha), msg);
}

fn fileCard(ctx: *d.Ctx, dl: *c.ImDrawList, a: *const Attachment, r: d.Rect, alpha: f32, hid: usize) void {
    const hb = d.hit(ctx, hid, r);
    const radius = @max(ctx.th.radius, 6);
    d.rect(dl, r, ctx.col(.elevated).mix(ctx.col(.text), if (hb.hovered) 0.04 else 0).alpha(alpha), radius);
    d.border(dl, r, ctx.col(.border).alpha(alpha), radius, 1);
    docIcon(dl, r.x + 26, r.y + r.h / 2, ctx.col(.accent).alpha(alpha));
    const fam = ctx.ui;
    _ = d.textClipped(dl, fam.get(.semibold), 14, r.x + 50, r.y + 11, ctx.col(.link).alpha(alpha), a.filename, r.w - 64);
    var buf: [32]u8 = undefined;
    d.text(dl, fam.get(.regular), 12, r.x + 50, r.y + 31, ctx.col(.faint).alpha(alpha), if (a.size > 0) formatSize(&buf, a.size) else i18n.tr("arquivo", "file"));
    if (hb.hovered) d.tip(ctx, r, i18n.tr("Abrir no navegador", "Open in Browser"), true);
    if (hb.clicked) {
        if (std.mem.startsWith(u8, a.url, "https://")) {
            openUrl(a.url);
        } else ctx.st.showToast(ctx.now_ms, false, "arquivo de demonstração", "demo file", .{});
    }
}

/// Botão de play no meio de uma prévia de vídeo.
pub fn playIcon(dl: *c.ImDrawList, cx: f32, cy: f32, alpha: f32) void {
    d.circle(dl, cx, cy, 24, d.Rgba.black.alpha(0.55 * alpha));
    c.ImDrawList_AddTriangleFilled(dl, d.v(cx - 7, cy - 11), d.v(cx - 7, cy + 11), d.v(cx + 12, cy), d.Rgba.white.col(alpha));
}

pub var last_opened: [512]u8 = undefined;
pub var last_opened_len: usize = 0;

/// Abre no navegador; só http(s), nada de file:// ou esquemas estranhos.
pub fn openUrl(url: []const u8) void {
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return;
    // No QA não abre o navegador: só anota (o teste confere).
    if (qa.on()) {
        const n = @min(url.len, last_opened.len);
        @memcpy(last_opened[0..n], url[0..n]);
        last_opened_len = n;
        return;
    }
    var buf: [2048]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{url}, 0) catch return;
    _ = c.SDL_OpenURL(z.ptr);
}

fn open(ctx: *d.Ctx, a: *const Attachment, url: []const u8) void {
    openImage(ctx, url, a.filename, a.width, a.height);
}

/// Abre uma imagem em tela cheia (anexo, embed, foto de perfil…).
pub fn openImage(ctx: *d.Ctx, url: []const u8, name: []const u8, w: u16, h: u16) void {
    // Abrir em tela cheia é pedir a imagem (vale também no modo economia).
    ctx.images.allow(url);
    var v: state.Viewer = .{ .w = w, .h = h };
    const n = @min(url.len, v.url.len);
    @memcpy(v.url[0..n], url[0..n]);
    v.url_len = @intCast(n);
    const fnl = d.utf8Prefix(name, v.name.len).len;
    @memcpy(v.name[0..fnl], name[0..fnl]);
    v.name_len = @intCast(fnl);
    ctx.st.viewer = v;
}

/// Abre uma imagem de que só se sabe o endereço (banner, ícone, foto): `w` e `h`
/// são um palpite do formato, até ela chegar, e ela vem no tamanho cheio.
pub fn openOriginal(ctx: *d.Ctx, url: []const u8, name: []const u8, w: u16, h: u16) void {
    openImage(ctx, url, name, w, h);
    if (ctx.st.viewer) |*v| v.original = true;
}

// --- Visualizador ------------------------------------------------------------

var viewer_shown = false;
/// O maior tamanho que o cache de imagens guarda.
const full_side: f32 = 4096;

pub fn viewer(ctx: *d.Ctx) void {
    const open_now = ctx.st.viewer != null;
    const k = anim.to(anim.id("viewer", 0), if (open_now) 1 else 0, 20);
    if (k < 0.01) {
        viewer_shown = false;
        return;
    }
    const v = &(ctx.st.viewer orelse {
        d.rect(ctx.fg, ctx.win, d.Rgba.black.alpha(0.85 * k), 0);
        return;
    });
    const appearing = !viewer_shown;
    viewer_shown = true;
    const win = ctx.win;
    c.ImGui_SetNextWindowPos(d.v(win.x, win.y), 0);
    c.ImGui_SetNextWindowSize(d.v(win.w, win.h), 0);
    if (appearing) c.ImGui_SetNextWindowFocus();
    _ = c.ImGui_Begin("##viewer", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse);
    defer c.ImGui_End();
    const dl = c.ImGui_GetWindowDrawList();
    d.rect(dl, win, d.Rgba.black.alpha(0.86 * k), 0);

    // O tamanho de verdade chega com a imagem.
    if (v.original) switch (ctx.images.get(v.url[0..v.url_len], full_side, full_side)) {
        .ready => |t| {
            v.w = @intCast(t.w);
            v.h = @intCast(t.h);
        },
        else => {},
    };

    // Ajusta inicialmente à janela; a roda aumenta/reduz e arrastar move a imagem.
    const ow: f32 = @floatFromInt(v.w);
    const oh: f32 = @floatFromInt(v.h);
    const fit = @min(1.0, @min((win.w - 120) / ow, (win.h - 150) / oh));
    if (win.contains(ctx.mouse.x, ctx.mouse.y) and ctx.io.*.MouseWheel != 0) {
        v.zoom = @max(0.5, @min(8.0, v.zoom * (if (ctx.io.*.MouseWheel > 0) @as(f32, 1.2) else 1.0 / 1.2)));
    }
    const zoom = (0.94 + 0.06 * k) * v.zoom;
    const iw = ow * fit * zoom;
    const ih = oh * fit * zoom;
    const ir: d.Rect = .{
        .x = win.x + (win.w - iw) / 2 + v.pan_x,
        .y = win.y + (win.h - 50 - ih) / 2 + v.pan_y,
        .w = iw,
        .h = ih,
    };
    if (ir.contains(ctx.mouse.x, ctx.mouse.y) and c.ImGui_IsMouseDragging(0, 0)) {
        v.pan_x += ctx.io.*.MouseDelta.x;
        v.pan_y += ctx.io.*.MouseDelta.y;
    }
    qa.mark(ir, "viewer", .{});
    const url = v.url[0..v.url_len];
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    switch (if (v.original) ctx.images.get(url, full_side, full_side) else ctx.images.get(url, ow * fit * zoom * scale, oh * fit * zoom * scale)) {
        .ready => |t| c.ImDrawList_AddImageRounded(dl, t.ref, d.v(ir.x, ir.y), d.v(ir.right(), ir.bottom()), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(k), 6, 0),
        .loading => {
            d.rect(dl, ir, d.Rgba.white.alpha(0.04 * k), 6);
            const t = @as(f32, @floatFromInt(@mod(ctx.now_ms, 100_000))) / 1000.0;
            c.ImDrawList_PathArcTo(dl, d.v(ir.x + ir.w / 2, ir.y + ir.h / 2), 18, t * 5, t * 5 + 4.2, 32);
            c.ImDrawList_PathStroke(dl, d.Rgba.white.col(0.8 * k), 2.5, 0);
            anim.every(50);
        },
        .failed => {
            const f = ctx.ui.get(.medium);
            const msg = i18n.tr("não deu pra carregar a imagem", "couldn't load the image");
            d.text(dl, f, 15, win.x + (win.w - d.width(f, 15, msg)) / 2, ir.y + ir.h / 2 - 9, d.Rgba.white.alpha(0.7 * k), msg);
        },
    }

    // Legenda e ações embaixo.
    const fam = ctx.ui;
    const name = v.name[0..v.name_len];
    var buf: [96]u8 = undefined;
    const dims = std.fmt.bufPrint(&buf, "{d} × {d}", .{ v.w, v.h }) catch "";
    const by = win.bottom() - 46;
    d.text(dl, fam.get(.semibold), 14, win.x + 24, by + 4, d.Rgba.white.alpha(k), name);
    d.text(dl, fam.get(.regular), 12.5, win.x + 24, by + 24, d.Rgba.white.alpha(0.55 * k), dims);
    var bx = win.right() - 24;
    // Rótulos em português também servem de marca para o QA.
    const actions = [_][]const u8{ "Copiar link", "Abrir no navegador" };
    const actions_en = [_][]const u8{ "Copy Link", "Open in Browser" };
    var clicked_action = false;
    for (actions, 0..) |mark_label, i| {
        const label = i18n.tr(mark_label, actions_en[i]);
        const can = std.mem.startsWith(u8, url, "https://");
        const tw = d.width(fam.get(.medium), 13, label);
        const br: d.Rect = .{ .x = bx - tw - 24, .y = by + 2, .w = tw + 24, .h = 32 };
        bx = br.x - 8;
        const hb = d.hit(ctx, 0x7100 + i, br);
        qa.mark(br, "viewer:{s}", .{mark_label});
        d.rect(dl, br, d.Rgba.white.alpha((if (hb.hovered and can) @as(f32, 0.16) else 0.08) * k), 6);
        d.text(dl, fam.get(.medium), 13, br.x + 12, d.centerY(br, 13), d.Rgba.white.alpha((if (can) @as(f32, 0.95) else 0.4) * k), label);
        if (hb.clicked) {
            clicked_action = true;
            if (!can) {
                ctx.st.showToast(ctx.now_ms, false, "imagem de demonstração", "demo image", .{});
            } else if (i == 0) {
                if (ctx.st.gpa.dupe(u8, url)) |owned| ctx.act(.{ .copy = owned }) else |_| {}
            } else openUrl(url);
        }
    }
    // Zoom: roda do mouse; arraste a imagem ampliada para navegar.
    // Fechar: Esc, o X ou um clique fora da imagem.
    const xr: d.Rect = .{ .x = win.right() - 52, .y = win.y + 16, .w = 36, .h = 36 };
    const xh = d.hit(ctx, 0x7200, xr);
    qa.mark(xr, "viewer:fechar", .{});
    d.circle(dl, xr.x + 18, xr.y + 18, 17, d.Rgba.white.alpha((if (xh.hovered) @as(f32, 0.18) else 0.08) * k));
    d.line(dl, xr.x + 12, xr.y + 12, xr.x + 24, xr.y + 24, d.Rgba.white.alpha(k), 1.8);
    d.line(dl, xr.x + 24, xr.y + 12, xr.x + 12, xr.y + 24, d.Rgba.white.alpha(k), 1.8);
    const outside = c.ImGui_IsMouseClicked(0) and !ir.contains(ctx.mouse.x, ctx.mouse.y) and !clicked_action and ctx.mouse.y < by - 4;
    if (xh.clicked or outside or c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) ctx.st.viewer = null;
}

// --- Bandeja de envio --------------------------------------------------------

/// Altura que a bandeja ocupa acima da caixa de texto.
pub fn trayHeight(ctx: *const d.Ctx) f32 {
    return if (ctx.st.uploads.items.len > 0) 132 else 0;
}

/// Cartões dos arquivos escolhidos, com prévia e botão de tirar.
pub fn tray(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect) void {
    const ups = ctx.st.uploads.items;
    if (ups.len == 0) return;
    d.rectFlags(dl, r, ctx.col(.rail).mix(ctx.col(.elevated), 0.5), @max(ctx.th.radius + 4, 4), c.ImDrawFlags_RoundTop);
    var x = r.x + 12;
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    var remove: ?usize = null;
    for (ups, 0..) |*u, i| {
        const cr: d.Rect = .{ .x = x, .y = r.y + 12, .w = 108, .h = 108 };
        if (cr.right() > r.right() - 8) break;
        d.rect(dl, cr, ctx.col(.elevated), 8);
        const pr: d.Rect = .{ .x = cr.x + 8, .y = cr.y + 8, .w = cr.w - 16, .h = 66 };
        if (u.width > 0) {
            var ubuf: [1100]u8 = undefined;
            const url = std.fmt.bufPrint(&ubuf, "file://{s}", .{u.path}) catch "";
            if (ctx.images.get(url, pr.w * scale, pr.h * scale) == .ready) {
                const t = ctx.images.get(url, pr.w * scale, pr.h * scale).ready;
                // Encaixa mantendo a proporção.
                const tw: f32 = @floatFromInt(t.w);
                const th: f32 = @floatFromInt(t.h);
                const s = @min(pr.w / tw, pr.h / th);
                const dw = tw * s;
                const dh = th * s;
                const ix = pr.x + (pr.w - dw) / 2;
                const iy = pr.y + (pr.h - dh) / 2;
                c.ImDrawList_AddImageRounded(dl, t.ref, d.v(ix, iy), d.v(ix + dw, iy + dh), d.v(0, 0), d.v(1, 1), d.Rgba.white.u(), 4, 0);
            } else pictureIcon(dl, pr.x + pr.w / 2, pr.y + pr.h / 2, ctx.col(.faint));
        } else docIcon(dl, pr.x + pr.w / 2, pr.y + pr.h / 2, ctx.col(.accent));
        _ = d.textClipped(dl, ctx.ui.get(.medium), 12, cr.x + 8, cr.y + 80, ctx.col(.text), u.name(), cr.w - 16);
        var sb: [32]u8 = undefined;
        d.text(dl, ctx.ui.get(.regular), 11, cr.x + 8, cr.y + 94, ctx.col(.faint), formatSize(&sb, u.size));
        const xr: d.Rect = .{ .x = cr.right() - 22, .y = cr.y - 6, .w = 26, .h = 26 };
        const hb = d.hit(ctx, 0x7300 + i, xr);
        qa.mark(xr, "upload-remove:{d}", .{i});
        d.circle(dl, xr.x + 13, xr.y + 13, 11, if (hb.hovered) ctx.col(.danger) else ctx.col(.rail));
        d.border(dl, .{ .x = xr.x + 2, .y = xr.y + 2, .w = 22, .h = 22 }, ctx.col(.border), 11, 1);
        const xc = if (hb.hovered) d.Rgba.white else ctx.col(.muted);
        d.line(dl, xr.x + 9, xr.y + 9, xr.x + 17, xr.y + 17, xc, 1.6);
        d.line(dl, xr.x + 17, xr.y + 9, xr.x + 9, xr.y + 17, xc, 1.6);
        if (hb.clicked) remove = i;
        qa.mark(cr, "upload:{d}", .{i});
        x += cr.w + 10;
    }
    if (remove) |i| ctx.act(.{ .remove_upload = i });
}

// --- Ícones --------------------------------------------------------------------

fn pictureIcon(dl: *c.ImDrawList, cx: f32, cy: f32, col: d.Rgba) void {
    const r: d.Rect = .{ .x = cx - 14, .y = cy - 11, .w = 28, .h = 22 };
    d.border(dl, r, col, 4, 1.6);
    c.ImDrawList_AddTriangleFilled(dl, d.v(r.x + 4, r.bottom() - 4), d.v(r.x + 11, r.y + 9), d.v(r.x + 18, r.bottom() - 4), col.u());
    c.ImDrawList_AddTriangleFilled(dl, d.v(r.x + 13, r.bottom() - 4), d.v(r.x + 18, r.y + 12), d.v(r.right() - 4, r.bottom() - 4), col.u());
    d.circle(dl, r.right() - 7, r.y + 7, 2.5, col);
}

fn docIcon(dl: *c.ImDrawList, cx: f32, cy: f32, col: d.Rgba) void {
    const x0 = cx - 11;
    const y0 = cy - 14;
    const pts = [_]c.ImVec2{ d.v(x0, y0), d.v(x0 + 15, y0), d.v(x0 + 22, y0 + 7), d.v(x0 + 22, y0 + 28), d.v(x0, y0 + 28) };
    c.ImDrawList_AddPolyline(dl, &pts, pts.len, col.u(), 1.8, c.ImDrawFlags_Closed);
    d.line(dl, x0 + 15, y0, x0 + 15, y0 + 7, col, 1.6);
    d.line(dl, x0 + 15, y0 + 7, x0 + 22, y0 + 7, col, 1.6);
    for (0..3) |i| {
        const ly = y0 + 13 + @as(f32, @floatFromInt(i)) * 5;
        d.line(dl, x0 + 5, ly, x0 + 17, ly, col.alpha(0.7), 1.4);
    }
}
