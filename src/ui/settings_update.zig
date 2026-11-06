//! Configurações → Atualizações: versão, verificar, atualizar, reiniciar; e
//! Configurações → Novidades: o que mudou em cada versão.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const rich = @import("rich.zig");
const md = @import("../core/markdown.zig");
const updater = @import("../net/updater.zig");
const att = @import("attachments.zig");
const anim = @import("anim.zig");
const icons = @import("icons.zig");
const log = @import("../core/changelog.zig");

const changelog_en = @embedFile("changelog_en");
const changelog_pt = @embedFile("changelog_pt");

pub fn draw(p: anytype) void {
    const ctx = p.ctx;
    const s = updater.snapshot();
    p.title(i18n.tr("Atualizações", "Updates"));
    var vb: [64]u8 = undefined;
    p.line(.semibold, 16, ctx.col(.text), i18n.fmt(&vb, "Versão {s}", "Version {s}", .{updater.current}), 28);
    if (updater.temporarily_disabled) {
        p.note(i18n.tr("A função de atualização está temporariamente desativada. Ela será reativada quando a integração com o GitHub Releases estiver pronta.", "The update feature is temporarily disabled. It will be re-enabled once GitHub Releases integration is ready."));
        if (p.buttonSoft(i18n.tr("Ver as versões no GitHub", "View releases on GitHub"))) att.openUrl(updater.releases_page);
        return;
    }
    var mb: [120]u8 = undefined;
    const line: []const u8 = switch (s.phase) {
        .idle => i18n.tr("Ainda não verificou nesta sessão.", "Not checked yet in this session."),
        .checking => i18n.tr("Verificando…", "Checking…"),
        .up_to_date => i18n.tr("Você está na versão mais recente.", "You're on the latest version."),
        .available => i18n.fmt(&mb, "Atualização disponível: {s}", "Update available: {s}", .{s.latest()}),
        .downloading => i18n.fmt(&mb, "Baixando {s}… {d}%", "Downloading {s}… {d}%", .{ s.latest(), s.percent }),
        .ready => i18n.fmt(&mb, "{s} instalada. Reinicie para usar.", "{s} installed. Restart to use it.", .{s.latest()}),
        .failed => switch (s.err) {
            .network, .none => i18n.tr("Sem conexão com o GitHub. Tente de novo mais tarde.", "Couldn't reach GitHub. Try again later."),
            .no_release => i18n.tr("Nenhuma versão publicada ainda.", "No published version yet."),
            .bad_signature => i18n.tr("A assinatura da atualização não confere: nada foi instalado.", "The update's signature doesn't match: nothing was installed."),
            .bad_hash => i18n.tr("Um arquivo baixado não confere: nada foi instalado.", "A downloaded file doesn't match: nothing was installed."),
            .read_only => i18n.tr("Sem permissão para escrever na pasta do programa. Atualize com o script de instalação.", "No permission to write to the app's folder. Update with the install script."),
            .disk => i18n.tr("Não consegui gravar os arquivos da atualização.", "Couldn't write the update files."),
        },
    };
    const good = s.phase == .available or s.phase == .ready;
    qa.mark(.{ .x = p.x, .y = p.y, .w = 300, .h = 20 }, "update-status:{t}", .{s.phase});
    p.line(.regular, 14, if (s.phase == .failed) ctx.col(.danger) else if (good) ctx.col(.accent) else ctx.col(.muted), line, 30);
    const working = s.phase == .checking or s.phase == .downloading;
    if (working) anim.every(100);
    if (s.phase == .available) {
        if (p.button(i18n.tr("Baixar e instalar", "Download and install"), false)) updater.install();
        p.sameLine();
    }
    if (s.phase == .ready) {
        if (p.button(i18n.tr("Reiniciar agora", "Restart now"), false)) ctx.act(.restart);
    } else if (!working) {
        // Com uma versão nova na tela, a ação principal é instalar.
        if (if (s.phase == .available) p.buttonSoft(i18n.tr("Verificar atualizações", "Check for updates")) else p.button(i18n.tr("Verificar atualizações", "Check for updates"), false)) updater.check();
    }
    p.y += 8;
    p.toggle(i18n.tr("Verificar ao abrir", "Check when opening"), i18n.tr("Pergunta ao GitHub qual é a última versão ao abrir o app. Nenhum dado da conta vai junto.", "Asks GitHub for the latest version when the app opens. No account data is sent."), &ctx.st.settings.check_updates);
    p.y += 10;
    p.heading(i18n.tr("Reiniciar", "Restart"));
    p.note(i18n.tr("Fecha e abre o larperCord de novo. Se estiver em uma call, ela cai.", "Closes and reopens larperCord. If you're in a call, you'll leave it."));
    if (p.buttonSoft(i18n.tr("Reiniciar o larperCord", "Restart larperCord"))) ctx.act(.restart);
    p.divider();
    p.note(i18n.tr("Toda atualização é assinada; uma versão sem a assinatura certa não é instalada.", "Every update is signed; a version without the right signature isn't installed."));
    if (p.buttonSoft(i18n.tr("Ver as versões no GitHub", "See releases on GitHub"))) att.openUrl(updater.releases_page);
}

// --- Novidades -----------------------------------------------------------------

const Item = struct { bullet: bool, spans: []md.Span };
const Section = struct { title: []const u8, items: []const Item };
const Version = struct { name: []const u8, sections: []const Section };

var parsed_en: ?[]const Version = null;
var parsed_pt: ?[]const Version = null;

/// O CHANGELOG do idioma, já com o markdown de cada item. Uma vez por idioma.
fn versions() ?[]const Version {
    const en = i18n.en();
    const slot = if (en) &parsed_en else &parsed_pt;
    if (slot.* == null) slot.* = load(if (en) changelog_en else changelog_pt) catch null;
    return slot.*;
}

fn load(text: []const u8) ![]const Version {
    const gpa = std.heap.c_allocator;
    const list = try log.parse(gpa, text);
    const out = try gpa.alloc(Version, list.len);
    for (list, out) |v, *o| {
        const secs = try gpa.alloc(Section, v.sections.len);
        for (v.sections, secs) |sec, *so| {
            const items = try gpa.alloc(Item, sec.items.len);
            for (sec.items, items) |it, *io| io.* = .{ .bullet = it.bullet, .spans = try md.parse(gpa, it.text) };
            so.* = .{ .title = sec.title, .items = items };
        }
        o.* = .{ .name = v.name, .sections = secs };
    }
    return out;
}

/// Quais versões a pessoa abriu ou fechou, em relação ao padrão (só a mais nova
/// e a instalada abertas).
var flipped: [64]bool = @splat(false);

const head_h: f32 = 52;
const pad: f32 = 18;
const rail_w: f32 = 28;

fn textOpts(ctx: *d.Ctx) rich.Opts {
    return .{
        .ctx = ctx,
        .family = ctx.ui,
        .size = 14,
        .line_h = 21,
        .color = ctx.col(.text).mix(ctx.col(.muted), 0.12),
        .underline_links = ctx.st.settings.underline_links,
    };
}

/// O miolo de uma versão: desenha com `dl`, só mede sem. Retorna a altura.
fn body(ctx: *d.Ctx, dl: ?*c.ImDrawList, v: Version, x: f32, y0: f32, wd: f32) f32 {
    var y = y0;
    const o = textOpts(ctx);
    var item_n: usize = 0;
    for (v.sections, 0..) |sec, si| {
        if (si > 0) y += 18;
        if (sec.title.len > 0) {
            var ub: [64]u8 = undefined;
            const up = d.upper(&ub, sec.title);
            const font = ctx.ui.get(.bold);
            if (dl) |l| {
                const tw = d.width(font, 11.5, up);
                d.text(l, font, 11.5, x, y, ctx.col(.accent).mix(ctx.col(.text), 0.25), up);
                d.line(l, x + tw + 10, y + 7.5, x + wd, y + 7.5, ctx.col(.border), 1);
                qa.mark(.{ .x = x, .y = y, .w = tw, .h = 15 }, "changelog-section:{s}", .{sec.title});
            }
            y += 25;
        }
        for (sec.items, 0..) |it, ii| {
            if (ii > 0) y += 6;
            const tx = if (it.bullet) x + 15 else x;
            const t = rich.layout(dl, ctx.store, ctx.th, it.spans, tx, y, wd - (tx - x), o, ctx.mouse);
            if (dl) |l| {
                if (it.bullet) d.circle(l, x + 4, y + 10.5, 2, ctx.col(.faint).mix(ctx.col(.muted), 0.5));
                qa.mark(.{ .x = x, .y = y, .w = wd, .h = t.h }, "changelog-item:{s}:{d}", .{ v.name, item_n });
            }
            item_n += 1;
            y += t.h;
        }
    }
    return y - y0;
}

/// Uma linha com o que tem numa versão fechada ("Windows · Voz · …").
fn summary(buf: []u8, v: Version) []const u8 {
    var wr = std.Io.Writer.fixed(buf);
    for (v.sections, 0..) |sec, i| {
        if (sec.title.len == 0) {
            // Sem seções: o começo do texto (o clip corta o que não couber).
            if (sec.items.len > 0 and sec.items[0].spans.len > 0) wr.writeAll(sec.items[0].spans[0].text) catch {};
            continue;
        }
        if (i > 0) wr.writeAll("  ·  ") catch {};
        wr.writeAll(sec.title) catch {};
    }
    return d.utf8Prefix(wr.buffered(), buf.len);
}

pub fn changelog(p: anytype) void {
    const ctx = p.ctx;
    p.title(i18n.tr("Novidades", "What's new"));
    const list = versions() orelse return;
    const top = p.y;
    const rail_x = p.x + 7;
    const card_x = p.x + rail_w;
    const card_w = p.w - rail_w;
    const radius = @max(ctx.th.radius + 2, 4);
    var prev_dot: ?f32 = null;
    for (list, 0..) |v, i| {
        const current = std.mem.eql(u8, v.name, updater.current);
        const open_default = i == 0 or current;
        const flip = i < flipped.len and flipped[i];
        const open = open_default != flip;
        const inner_w = card_w - pad * 2;
        const body_h = if (open) body(ctx, null, v, 0, 0, inner_w) else 0;
        const card: d.Rect = .{ .x = card_x, .y = p.y, .w = card_w, .h = head_h + (if (open) body_h + pad else 0) };
        const hr: d.Rect = .{ .x = card.x, .y = card.y, .w = card.w, .h = head_h };
        const hb = d.hit(ctx, p.id(), hr);
        qa.mark(hr, "changelog-version:{s}", .{v.name});
        if (hb.clicked and i < flipped.len) flipped[i] = !flipped[i];

        const hk = anim.to(anim.id("cl-hover", i), if (hb.hovered) 1 else 0, 22);
        d.rect(p.dl, card, ctx.col(.rail).mix(ctx.col(.elevated), 0.25).alpha(0.62), radius);
        if (hk > 0.01) d.rectFlags(p.dl, hr, ctx.col(.hover).alpha(hk), radius, if (open) c.ImDrawFlags_RoundTop else 0);
        d.border(p.dl, card, if (current) ctx.col(.accent).alpha(0.5) else ctx.col(.border), radius, 1);

        // A linha do tempo: um ponto por versão, ligado ao anterior.
        const dot_y = card.y + head_h / 2;
        if (prev_dot) |py| d.rect(p.dl, .{ .x = rail_x - 1, .y = py + 11, .w = 2, .h = dot_y - py - 18 }, ctx.col(.border).mix(ctx.col(.text), 0.08), 1);
        prev_dot = dot_y;
        if (current) {
            d.circle(p.dl, rail_x, dot_y, 9, ctx.col(.accent).alpha(0.22));
            d.circle(p.dl, rail_x, dot_y, 5, ctx.col(.accent));
        } else {
            d.circle(p.dl, rail_x, dot_y, 5, ctx.col(.surface));
            c.ImDrawList_AddCircleEx(p.dl, d.v(rail_x, dot_y), 4.5, ctx.col(.faint).u(), 0, 2, 0);
        }

        // Cabeçalho: versão, "atual" e, fechada, o que tem nela.
        const vf = p.font(.bold);
        const vw = d.width(vf, 18, v.name);
        d.text(p.dl, vf, 18, hr.x + pad, d.centerY(hr, 18), ctx.col(.text), v.name);
        var nx = hr.x + pad + vw + 10;
        if (current) {
            const lbl = i18n.tr("Versão atual", "Current version");
            const lf = p.font(.semibold);
            const lw = d.width(lf, 11.5, lbl);
            const pill: d.Rect = .{ .x = nx, .y = hr.y + hr.h / 2 - 10, .w = lw + 16, .h = 20 };
            d.rect(p.dl, pill, ctx.col(.accent), 10);
            d.text(p.dl, lf, 11.5, pill.x + 8, d.centerY(pill, 11.5), ctx.col(.accent_text), lbl);
            qa.mark(pill, "changelog-current:{s}", .{v.name});
            nx = pill.right() + 10;
        }
        const chev_x = hr.right() - pad - 4;
        const ok = anim.to(anim.id("cl-open", i), if (open) 1 else 0, 22);
        icons.chevron(p.dl, chev_x, hr.y + hr.h / 2, ctx.col(.muted).mix(ctx.col(.text), hk).u(), ok);
        if (!open) {
            var sb: [240]u8 = undefined;
            _ = d.textClipped(p.dl, p.font(.regular), 13, nx + 4, d.centerY(hr, 13), ctx.col(.muted), summary(&sb, v), chev_x - 16 - (nx + 4));
        }
        if (open) {
            d.line(p.dl, hr.x + pad, hr.bottom() - 1, hr.right() - pad, hr.bottom() - 1, ctx.col(.border), 1);
            _ = body(ctx, p.dl, v, card.x + pad, hr.bottom() + 14, inner_w);
        }
        p.y += card.h + 12;
    }
    qa.mark(.{ .x = p.x, .y = top, .w = p.w, .h = p.y - top }, "changelog", .{});
}
