//! Perfil de alguém: o cartão pequeno (ao clicar no nome/avatar) e o
//! perfil grande no meio da tela, com abas de atividade, amigos e
//! servidores em comum. As seções são as mesmas nos dois; cada uma mede
//! (sem `dl`) e desenha (com `dl`) pelo mesmo código.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const types = @import("../core/types.zig");
const i18n = @import("i18n.zig");
const rich = @import("rich.zig");
const att = @import("attachments.zig");
const icons = @import("icons.zig");
const dropdown = @import("dropdown.zig");
const logo = @import("logo.zig");
const popup = @import("popup.zig");
const Id = types.Id;

const no_hit: d.Hit = .{ .hovered = false, .clicked = false, .held = false, .middle = false, .right = false, .ctrl = false };

/// Uma coluna de seções. Sem `dl` só mede (y avança igual).
const Col = struct {
    ctx: *d.Ctx,
    dl: ?*c.ImDrawList,
    x: f32,
    w: f32,
    y: f32,
    /// Base dos ids de clique (o cartão e o perfil grande usam faixas diferentes).
    ids: usize,

    fn hit(col: *Col, id: usize, r: d.Rect) d.Hit {
        if (col.dl == null) return no_hit;
        return d.hit(col.ctx, col.ids + id, r);
    }

    fn label(col: *Col, s: []const u8) void {
        if (col.dl) |dl| d.text(dl, col.ctx.ui.get(.bold), 12, col.x, col.y, col.ctx.col(.muted), s);
        col.y += 19;
    }

    fn text(col: *Col, weight: anytype, size: f32, color: d.Rgba, s: []const u8) void {
        if (col.dl) |dl| _ = d.textClipped(dl, col.ctx.ui.get(weight), size, col.x, col.y, color, s, col.w);
        col.y += size + 7;
    }

    fn gap(col: *Col, h: f32) void {
        col.y += h;
    }
};

fn isWebhook(ctx: *const d.Ctx, uid: Id) bool {
    return if (ctx.store.user(uid)) |u| u.webhook else false;
}

fn bannerUrl(buf: []u8, uid: Id, hash: []const u8) []const u8 {
    if (std.mem.startsWith(u8, hash, "demo:")) return hash;
    return std.fmt.bufPrint(buf, "https://cdn.discordapp.com/banners/{d}/{s}.png?size=600", .{ uid, hash }) catch "";
}

fn kindLabel(kind: u8) []const u8 {
    return switch (kind) {
        1 => i18n.tr("Transmitindo", "Streaming"),
        2 => i18n.tr("Ouvindo", "Listening to"),
        3 => i18n.tr("Assistindo", "Watching"),
        5 => i18n.tr("Competindo", "Competing"),
        else => i18n.tr("Jogando", "Playing"),
    };
}

/// "1:08:49" / "12:05".
fn elapsed(buf: []u8, ms: i64) []const u8 {
    const s: u64 = @intCast(@max(@divTrunc(ms, 1000), 0));
    if (s >= 3600) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
}

const months_short = [_][]const u8{ "jan.", "fev.", "mar.", "abr.", "mai.", "jun.", "jul.", "ago.", "set.", "out.", "nov.", "dez." };
const months_short_en = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// "21 de nov. de 2017" / "Nov 21, 2017".
fn dateShort(buf: []u8, ms: i64) []const u8 {
    const t = w.localTime(@divTrunc(ms, 1000));
    if (i18n.ja()) return std.fmt.bufPrint(buf, "{d}年{d}月{d}日", .{ t.year, t.month, t.day }) catch "";
    const m: usize = t.month - 1;
    return i18n.fmt(buf, "{d} de {s} de {d}", "{d} {s}, {d}", .{ t.day, if (i18n.en()) months_short_en[m] else months_short[m], t.year });
}

/// Quando a conta foi criada (no próprio ID). A demonstração tem IDs
/// pequenos: usa uma data fixa por pessoa.
fn accountMs(uid: Id) i64 {
    if (uid < 1 << 32) return (1_600_000_000 + @as(i64, @intCast(uid % 1000)) * 86400 * 30) * 1000;
    return types.snowflakeTime(uid);
}

// --- Seções -------------------------------------------------------------------

/// Nome, @usuário • pronomes e as insígnias.
fn names(col: *Col, uid: Id, pf: ?types.Profile, big: bool) void {
    const ctx = col.ctx;
    const u = ctx.store.user(uid) orelse return;
    const ns: f32 = if (big) 24 else 20;
    const name_room = col.w - w.botTagSpace(ctx, u, false);
    const nr: d.Rect = .{ .x = col.x, .y = col.y, .w = @min(d.width(ctx.ui.get(.bold), ns, u.name), name_room), .h = ns + 4 };
    if (col.dl) |dl| {
        const nw = d.textClipped(dl, ctx.ui.get(.bold), ns, col.x, col.y, ctx.col(.text), u.name, name_room);
        _ = w.botTag(ctx, dl, col.x + nw, col.y + ns * 0.62, u, false, 1);
    }
    if (!big) {
        // No cartão, o nome abre o perfil grande.
        const hb = col.hit(1, nr);
        if (col.dl != null) qa.mark(nr, "profile-name", .{});
        if (hb.hovered) if (col.dl) |dl| d.line(dl, nr.x, nr.bottom() - 1, nr.right(), nr.bottom() - 1, ctx.col(.text).alpha(0.6), 1);
        if (hb.clicked) ctx.act(.{ .open_full_profile = .{ .user = uid } });
    }
    col.y += ns + 8;
    var lb: [160]u8 = undefined;
    const p = pf orelse types.Profile{};
    const uname = if (p.username.len > 0 and !std.mem.eql(u8, p.username, u.name)) p.username else "";
    const line = if (uname.len > 0 and p.pronouns.len > 0)
        std.fmt.bufPrint(&lb, "{s}  •  {s}", .{ uname, p.pronouns }) catch ""
    else if (uname.len > 0) uname else p.pronouns;
    var lx = col.x;
    if (line.len > 0) {
        if (col.dl) |dl| lx += d.textClipped(dl, ctx.ui.get(.regular), 13.5, col.x, col.y, ctx.col(.text).mix(ctx.col(.muted), 0.35), line, col.w - 8) + 8 else lx += d.width(ctx.ui.get(.regular), 13.5, line) + 8;
    }
    // Insígnias: ícones pequenos, com a descrição no tooltip.
    if (p.badges.len > 0) {
        var bx = if (line.len > 0) lx else col.x;
        if (bx + @as(f32, @floatFromInt(p.badges.len)) * 22 > col.x + col.w) {
            col.y += 22;
            bx = col.x;
        }
        if (col.dl) |dl| {
            const pr: d.Rect = .{ .x = bx - 3, .y = col.y - 3, .w = @as(f32, @floatFromInt(@min(p.badges.len, 12))) * 22 + 4, .h = 24 };
            d.rect(dl, pr, ctx.col(.rail).alpha(0.6), 6);
        }
        for (p.badges[0..@min(p.badges.len, 12)], 0..) |b, i| {
            const br: d.Rect = .{ .x = bx + @as(f32, @floatFromInt(i)) * 22, .y = col.y, .w = 18, .h = 18 };
            if (col.dl) |dl| {
                var ub: [192]u8 = undefined;
                const url = std.fmt.bufPrint(&ub, "https://cdn.discordapp.com/badge-icons/{s}.png", .{b.icon}) catch "";
                if (!w.picture(ctx, dl, url, br, 0, 1)) d.circle(dl, br.x + 9, br.y + 9, 7, ctx.col(.faint));
            }
            const hb = col.hit(60 + i, br);
            if (col.dl != null) d.tip(ctx, br, b.description, hb.hovered);
        }
        col.y += 24;
    } else if (line.len > 0) col.y += 22;
}

/// "N amigos em comum • M servidores em comum" (abre a aba no perfil grande).
fn mutuals(col: *Col, uid: Id, pf: ?types.Profile) void {
    const p = pf orelse return;
    if (uid == col.ctx.store.me) return;
    const nf = @max(p.mutual_friends_count, @as(u32, @intCast(p.mutual_friends.len)));
    const ng = p.mutual_guilds.len;
    if (nf == 0 and ng == 0) return;
    const ctx = col.ctx;
    var x = col.x;
    // Até 3 avatares dos amigos em comum, sobrepostos.
    for (p.mutual_friends[0..@min(p.mutual_friends.len, 3)], 0..) |fid, i| {
        if (col.dl) |dl| {
            const cx = col.x + 9 + @as(f32, @floatFromInt(i)) * 12;
            d.circle(dl, cx, col.y + 9, 10, ctx.col(.overlay));
            w.avatar(ctx, dl, cx, col.y + 9, 18, fid, .circle, null, 1);
        }
        x = col.x + 22 + @as(f32, @floatFromInt(i)) * 12;
    }
    if (x > col.x) x += 6;
    const font = ctx.ui.get(.medium);
    var fb: [48]u8 = undefined;
    var gb: [48]u8 = undefined;
    const ft = if (nf == 1) i18n.tr("1 amigo em comum", "1 Mutual Friend") else i18n.fmt(&fb, "{d} amigos em comum", "{d} Mutual Friends", .{nf});
    const gt = if (ng == 1) i18n.tr("1 servidor em comum", "1 Mutual Server") else i18n.fmt(&gb, "{d} servidores em comum", "{d} Mutual Servers", .{ng});
    const parts = [_]struct { s: []const u8, tab: u8, on: bool }{ .{ .s = ft, .tab = 1, .on = nf > 0 }, .{ .s = gt, .tab = 2, .on = ng > 0 } };
    var first = true;
    for (parts, 0..) |part, i| {
        if (!part.on) continue;
        if (!first) {
            if (col.dl) |dl| d.text(dl, font, 13, x, col.y + 2, ctx.col(.faint), "•");
            x += 12;
        }
        first = false;
        const tw = d.width(font, 13, part.s);
        const r: d.Rect = .{ .x = x, .y = col.y, .w = tw, .h = 18 };
        const hb = col.hit(70 + i, r);
        if (col.dl) |dl| {
            qa.mark(r, "profile-mutual:{d}", .{part.tab});
            d.text(dl, font, 13, x, col.y + 2, if (hb.hovered) ctx.col(.text) else ctx.col(.muted), part.s);
        }
        if (hb.clicked) ctx.act(.{ .open_full_profile = .{ .user = uid, .tab = part.tab } });
        x += tw + 6;
    }
    col.y += 28;
}

fn bio(col: *Col, uid: Id, pf: ?types.Profile, heading: bool) void {
    const p = pf orelse return;
    if (p.bio.len == 0) return;
    const ctx = col.ctx;
    const spans = ctx.store.bios.get(uid) orelse return;
    const opts: rich.Opts = .{ .family = ctx.ui, .size = 13.5, .line_h = 19, .color = ctx.col(.text).mix(ctx.col(.muted), 0.1), .underline_links = ctx.st.settings.underline_links };
    if (heading) col.label(i18n.tr("SOBRE MIM", "ABOUT ME"));
    const t = rich.layout(col.dl, ctx.store, ctx.th, spans, col.x, col.y, col.w, opts, ctx.mouse);
    col.y += t.h + 14;
}

/// Imagem da atividade: a do próprio jogo, o ícone da aplicação, ou a inicial.
fn activityPicture(ctx: *d.Ctx, dl: *c.ImDrawList, a: types.Activity, r: d.Rect) void {
    if (w.picture(ctx, dl, a.image, r, 8, 1)) return;
    if (a.image.len == 0 and a.app != 0) {
        if (ctx.store.app_icons.get(a.app)) |icon| {
            var ub: [160]u8 = undefined;
            const url = if (icon.len > 0) std.fmt.bufPrint(&ub, "https://cdn.discordapp.com/app-icons/{d}/{s}.png?size=128", .{ a.app, icon }) catch "" else "";
            if (w.picture(ctx, dl, url, r, 8, 1)) return;
        } else ctx.act(.{ .want_app_icon = a.app });
    }
    d.rect(dl, r, ctx.col(.elevated).mix(ctx.col(.accent), 0.25), 8);
    var up: [8]u8 = undefined;
    const ini = d.upper(&up, d.firstGlyph(a.name));
    const fs = r.h * 0.42;
    const font = ctx.ui.get(.bold);
    d.text(dl, font, fs, r.x + (r.w - d.width(font, fs, ini)) / 2, r.y + r.h / 2 - fs * 0.6, ctx.col(.text), ini);
}

/// Jogos, música, transmissão… cada um num cartãozinho com o tempo.
fn activities(col: *Col, uid: Id, big: bool) void {
    const ctx = col.ctx;
    const list = ctx.store.activities.get(uid) orelse return;
    const img: f32 = if (big) 84 else 56;
    for (list) |a| {
        const top = col.y;
        var lines: f32 = 22;
        for ([_][]const u8{ a.details, a.state }) |t| {
            if (t.len > 0) lines += 18;
        }
        if (a.start_ms > 0) lines += 18;
        const h = 12 + 20 + @max(img, lines) + 12;
        if (col.dl) |dl| {
            const cr: d.Rect = .{ .x = col.x, .y = top, .w = col.w, .h = h };
            qa.mark(cr, "profile-activity", .{});
            d.rect(dl, cr, ctx.col(.rail).alpha(0.55), @max(ctx.th.radius, 6));
            d.text(dl, ctx.ui.get(.semibold), 12, cr.x + 12, top + 10, ctx.col(.text).mix(ctx.col(.muted), 0.3), kindLabel(a.kind));
            const ir: d.Rect = .{ .x = cr.x + 12, .y = top + 32, .w = img, .h = img };
            activityPicture(ctx, dl, a, ir);
            const tx = ir.right() + 12;
            const tw = cr.right() - 12 - tx;
            var ty = top + 32 + @max(0, (img - lines) / 2);
            _ = d.textClipped(dl, ctx.ui.get(.semibold), 14, tx, ty, ctx.col(.text), a.name, tw);
            ty += 22;
            for ([_][]const u8{ a.details, a.state }) |t| if (t.len > 0) {
                _ = d.textClipped(dl, ctx.ui.get(.regular), 13, tx, ty, ctx.col(.muted), t, tw);
                ty += 18;
            };
            if (a.start_ms > 0) {
                var eb: [24]u8 = undefined;
                const now = anim.now_ms;
                const e = elapsed(&eb, now - a.start_ms);
                d.circle(dl, tx + 4, ty + 7, 3.5, ctx.col(.online));
                d.text(dl, ctx.mono.get(.regular), 13, tx + 14, ty, ctx.col(.online).mix(ctx.col(.text), 0.3), e);
                // O relógio anda: redesenha a cada segundo enquanto aparece.
                anim.every(1000);
            }
        }
        col.y += h + 10;
    }
}

/// "Em call": o canal de voz em que a pessoa está, quem mais está lá e Entrar.
fn voice(col: *Col, uid: Id) void {
    const ctx = col.ctx;
    const ch = ctx.store.voiceChannelOf(uid, ctx.st.guild);
    if (ch == 0) return;
    const cs = ctx.store.channel(ch) orelse return;
    const h: f32 = 92;
    if (col.dl) |dl| {
        const cr: d.Rect = .{ .x = col.x, .y = col.y, .w = col.w, .h = h };
        d.rect(dl, cr, ctx.col(.rail).alpha(0.55), @max(ctx.th.radius, 6));
        d.text(dl, ctx.ui.get(.semibold), 12, cr.x + 12, cr.y + 10, ctx.col(.text).mix(ctx.col(.muted), 0.3), i18n.tr("Em call", "In voice"));
        // Até 4 de quem está na call; o resto vira "+N".
        const ms = cs.voice_members.items;
        for (ms[0..@min(ms.len, 4)], 0..) |m, i| {
            const ax = cr.x + 24 + @as(f32, @floatFromInt(i % 2)) * 26;
            const ay = cr.y + 46 + @as(f32, @floatFromInt(i / 2)) * 26;
            w.avatar(ctx, dl, ax, ay, 22, m, .circle, null, 1);
        }
        if (ms.len > 4) {
            var pb: [8]u8 = undefined;
            d.text(dl, ctx.ui.get(.semibold), 11, cr.x + 66, cr.y + 62, ctx.col(.muted), std.fmt.bufPrint(&pb, "+{d}", .{ms.len - 4}) catch "");
        }
        const tx = cr.x + 92;
        icons.speaker(dl, tx + 6, cr.y + 41, ctx.col(.muted).u());
        _ = d.textClipped(dl, ctx.ui.get(.semibold), 14, tx + 21, cr.y + 33, ctx.col(.text), cs.info.name, cr.right() - tx - 110);
        if (ctx.store.guild(cs.info.guild)) |g| {
            var gb: [128]u8 = undefined;
            _ = d.textClipped(dl, ctx.ui.get(.regular), 13, tx, cr.y + 52, ctx.col(.muted), i18n.fmt(&gb, "em {s}", "in {s}", .{g.name}), cr.right() - tx - 12);
        }
        // Nós mesmos nessa call (pelo app ou pelo que o servidor diz): Sair.
        const here = (ctx.st.voice != null and ctx.st.voice.? == ch) or ctx.store.voiceChannelOf(ctx.store.me, cs.info.guild) == ch;
        const br: d.Rect = .{ .x = cr.right() - 86, .y = cr.y + 8, .w = 74, .h = 24 };
        if (here) {
            const hb = col.hit(81, br);
            qa.mark(br, "profile-leave-voice", .{});
            d.rect(dl, br, if (hb.hovered) ctx.col(.danger) else ctx.col(.elevated), 5);
            const lt = i18n.tr("Sair", "Leave");
            const font = ctx.ui.get(.semibold);
            d.text(dl, font, 13, br.x + (br.w - d.width(font, 13, lt)) / 2, d.centerY(br, 13), if (hb.hovered) d.Rgba.white else ctx.col(.danger), lt);
            if (hb.clicked) {
                ctx.st.voice_guild = cs.info.guild;
                ctx.act(.leave_voice);
            }
        } else {
            const hb = col.hit(80, br);
            qa.mark(br, "profile-join-voice", .{});
            d.rect(dl, br, if (hb.hovered) ctx.col(.accent) else ctx.col(.elevated), 5);
            const lt = i18n.tr("Entrar", "Join");
            const font = ctx.ui.get(.semibold);
            d.text(dl, font, 13, br.x + (br.w - d.width(font, 13, lt)) / 2, d.centerY(br, 13), if (hb.hovered) ctx.col(.accent_text) else ctx.col(.text), lt);
            if (hb.clicked) {
                ctx.act(.{ .toggle_voice = ch });
                if (ctx.st.guild != cs.info.guild) ctx.act(.{ .select_guild = cs.info.guild });
            }
        }
    }
    col.y += h + 10;
}

/// Desde quando está no Discord e no servidor aberto (e amigos desde).
fn since(col: *Col, uid: Id, pf: ?types.Profile, gid: Id, friends: bool) void {
    const ctx = col.ctx;
    // Webhook não é uma conta: não tem desde quando.
    if (isWebhook(ctx, uid)) return;
    col.label(i18n.tr("MEMBRO DESDE", "MEMBER SINCE"));
    var x = col.x;
    var db: [48]u8 = undefined;
    const font = ctx.ui.get(.regular);
    const acc = dateShort(&db, accountMs(uid));
    if (col.dl) |dl| {
        logo.still(dl, x + 8, col.y + 8, 16);
        d.text(dl, font, 13.5, x + 22, col.y, ctx.col(.text), acc);
    }
    x += 22 + d.width(font, 13.5, acc) + 10;
    const tip_r: d.Rect = .{ .x = col.x, .y = col.y, .w = x - col.x, .h = 18 };
    const th = col.hit(90, tip_r);
    if (col.dl != null) d.tip(ctx, tip_r, i18n.tr("No Discord desde", "Discord member since"), th.hovered);
    if (pf) |p| if (p.guild == gid and gid != 0 and p.joined_ms > 0) {
        var jb: [48]u8 = undefined;
        const jt = dateShort(&jb, p.joined_ms);
        if (x + 26 + d.width(font, 13.5, jt) > col.x + col.w) {
            col.y += 22;
            x = col.x;
        } else if (col.dl) |dl| d.text(dl, font, 13.5, x - 6, col.y, ctx.col(.faint), "•");
        const gr: d.Rect = .{ .x = x + 6, .y = col.y, .w = 16, .h = 16 };
        if (col.dl) |dl| {
            const g = ctx.store.guild(gid);
            var ib: [160]u8 = undefined;
            const url = if (g) |gg| if (gg.icon) |ic| w.cdnUrl(&ib, .guild, gid, ic) else "" else "";
            if (!w.picture(ctx, dl, url, gr, 4, 1)) d.rect(dl, gr, ctx.col(.accent), 4);
            d.text(dl, font, 13.5, x + 28, col.y, ctx.col(.text), jt);
        }
        const r2: d.Rect = .{ .x = x + 6, .y = col.y, .w = 22 + d.width(font, 13.5, jt), .h = 18 };
        const hb = col.hit(91, r2);
        if (col.dl != null) {
            qa.mark(r2, "profile-joined", .{});
            var tb: [160]u8 = undefined;
            const gname = if (ctx.store.guild(gid)) |g| g.name else "";
            d.tip(ctx, r2, i18n.fmt(&tb, "No servidor {s} desde", "{s} member since", .{gname}), hb.hovered);
        }
    };
    col.y += 28;
    if (friends) if (ctx.store.friend_since.get(uid)) |fs| {
        col.label(i18n.tr("AMIGOS DESDE", "FRIENDS SINCE"));
        var fb: [48]u8 = undefined;
        col.text(.regular, 13.5, ctx.col(.text), dateShort(&fb, fs));
        col.gap(7);
    };
}

/// Cargos no servidor aberto: × tira (com permissão), + abre a lista para dar um.
const role_key: usize = 0xDA000;

fn roles(col: *Col, uid: Id, gid: Id) void {
    const ctx = col.ctx;
    const info = ctx.store.memberInfo(gid, uid) orelse return;
    const manage = ctx.store.can(gid, types.perm.manage_roles);
    const top = ctx.store.topRolePosition(gid);
    var rbuf: [6]Id = undefined;
    var nroles: usize = 0;
    for (info.roleSlice()) |rid| if (ctx.store.roles.get(rid) != null) {
        rbuf[nroles] = rid;
        nroles += 1;
    };
    const byPos = struct {
        fn f(cx: *d.Ctx, a: Id, b: Id) bool {
            return cx.store.roles.get(a).?.position > cx.store.roles.get(b).?.position;
        }
    }.f;
    @import("../core/sort.zig").stable(Id, rbuf[0..nroles], ctx, byPos);
    var cands: [24]Id = undefined;
    var ncand: usize = 0;
    if (manage) {
        var it = ctx.store.roles.valueIterator();
        while (it.next()) |rl| {
            if (rl.guild != gid or rl.id == gid or rl.managed or rl.position >= top or ncand == cands.len) continue;
            if (std.mem.indexOfScalar(Id, rbuf[0..nroles], rl.id) != null) continue;
            cands[ncand] = rl.id;
            ncand += 1;
        }
        @import("../core/sort.zig").stable(Id, cands[0..ncand], ctx, byPos);
    }
    if (nroles == 0 and !(manage and ncand > 0)) return;
    col.label(i18n.tr("CARGOS", "ROLES"));
    const fam = ctx.ui;
    var rx = col.x;
    for (rbuf[0..nroles], 0..) |rid, ri| {
        const rl = ctx.store.roles.get(rid).?;
        const cw = @min(d.width(fam.get(.medium), 12, rl.name) + 30, col.w);
        if (rx + cw > col.x + col.w) {
            rx = col.x;
            col.y += 26;
        }
        const cr: d.Rect = .{ .x = rx, .y = col.y, .w = cw, .h = 22 };
        const editable = manage and !rl.managed and rl.position < top;
        const hb = col.hit(100 + ri, cr);
        if (col.dl) |dl| {
            qa.mark(cr, "role:{d}", .{rid});
            d.rect(dl, cr, ctx.col(.elevated).mix(ctx.col(.text), if (hb.hovered and editable) 0.05 else 0), 5);
            d.border(dl, cr, ctx.col(.border), 5, 1);
            const dot = if (rl.color != 0) d.Rgba.hex(rl.color) else ctx.col(.faint);
            if (hb.hovered and editable) {
                // O pontinho vira um × para tirar o cargo.
                d.line(dl, cr.x + 7, cr.y + 8, cr.x + 13, cr.y + 14, dot, 1.6);
                d.line(dl, cr.x + 13, cr.y + 8, cr.x + 7, cr.y + 14, dot, 1.6);
                d.tip(ctx, cr, i18n.tr("Tirar cargo", "Remove role"), true);
            } else d.circle(dl, cr.x + 10, cr.y + 11, 4, dot);
            _ = d.textClipped(dl, fam.get(.medium), 12, cr.x + 18, d.centerY(cr, 12), ctx.col(.text), rl.name, cw - 24);
        }
        if (hb.clicked and editable) ctx.act(.{ .member_role = .{ .guild = gid, .user = uid, .role = rid, .add = false } });
        rx += cw + 6;
    }
    if (manage and ncand > 0) {
        if (rx + 26 > col.x + col.w) {
            rx = col.x;
            col.y += 26;
        }
        const pr: d.Rect = .{ .x = rx, .y = col.y, .w = 26, .h = 22 };
        const hb = col.hit(98, pr);
        if (col.dl) |dl| {
            qa.mark(pr, "role-add", .{});
            d.rect(dl, pr, ctx.col(.elevated).mix(ctx.col(.text), if (hb.hovered) 0.06 else 0), 5);
            icons.plus(dl, pr.x + 13, pr.y + 11, 4.5, ctx.col(.muted).u());
            d.tip(ctx, pr, i18n.tr("Dar cargo", "Add role"), hb.hovered);
        }
        if (hb.clicked) dropdown.toggle(role_key);
        // Os cargos para dar: por cima do cartão, que não muda de tamanho. Sem
        // desenho é só a medição do cartão.
        if (col.dl != null) if (dropdown.begin(ctx, role_key, pr, 220, 26 * @as(f32, @floatFromInt(ncand)))) |dd_c| {
            var dd = dd_c;
            defer dd.end();
            for (cands[0..ncand]) |rid| {
                const rl = ctx.store.roles.get(rid).?;
                const ro = dd.row(26, false);
                qa.mark(ro.rect, "role-pick:{d}", .{rid});
                d.circle(dd.dl, ro.rect.x + 12, ro.rect.y + 13, 4, if (rl.color != 0) d.Rgba.hex(rl.color) else ctx.col(.faint));
                _ = d.textClipped(dd.dl, fam.get(.medium), 13, ro.rect.x + 24, d.centerY(ro.rect, 13), ctx.col(.text), rl.name, ro.rect.w - 30);
                if (ro.hit.clicked) {
                    ctx.act(.{ .member_role = .{ .guild = gid, .user = uid, .role = rid, .add = true } });
                    dropdown.close();
                }
            }
        };
    }
    col.y += 30;
}

/// Cor e letra de cada serviço (não temos os logotipos).
fn connectionLook(kind: []const u8) struct { color: u32, letter: []const u8 } {
    const table = [_]struct { k: []const u8, c: u32, l: []const u8 }{
        .{ .k = "github", .c = 0x24292e, .l = "G" },      .{ .k = "steam", .c = 0x1b2838, .l = "S" },
        .{ .k = "spotify", .c = 0x1db954, .l = "♫" },     .{ .k = "youtube", .c = 0xff0000, .l = "▶" },
        .{ .k = "twitch", .c = 0x9146ff, .l = "T" },      .{ .k = "reddit", .c = 0xff4500, .l = "R" },
        .{ .k = "twitter", .c = 0x111111, .l = "X" },     .{ .k = "xbox", .c = 0x107c10, .l = "X" },
        .{ .k = "playstation", .c = 0x003791, .l = "P" }, .{ .k = "battlenet", .c = 0x148eff, .l = "B" },
        .{ .k = "epicgames", .c = 0x313131, .l = "E" },   .{ .k = "riotgames", .c = 0xd13639, .l = "R" },
        .{ .k = "tiktok", .c = 0x111111, .l = "♪" },      .{ .k = "instagram", .c = 0xe1306c, .l = "I" },
        .{ .k = "bluesky", .c = 0x0085ff, .l = "B" },     .{ .k = "domain", .c = 0x4e5d94, .l = "@" },
    };
    for (table) |t| if (std.mem.eql(u8, t.k, kind)) return .{ .color = t.c, .letter = t.l };
    return .{ .color = 0x4e5d94, .letter = "•" };
}

fn connections(col: *Col, pf: ?types.Profile) void {
    const p = pf orelse return;
    if (p.connections.len == 0) return;
    const ctx = col.ctx;
    col.label(i18n.tr("CONEXÕES", "CONNECTIONS"));
    for (p.connections[0..@min(p.connections.len, 12)], 0..) |cn, i| {
        const font = ctx.ui.get(.medium);
        const tw = d.width(font, 13.5, cn.name);
        const r: d.Rect = .{ .x = col.x, .y = col.y, .w = @min(tw + 52, col.w), .h = 28 };
        const hb = if (cn.url.len > 0) col.hit(150 + i, r) else no_hit;
        if (col.dl) |dl| {
            if (cn.url.len > 0) qa.mark(r, "profile-conn:{s}", .{cn.kind});
            d.rect(dl, r.inset(-4, 0), ctx.col(.hover).alpha(anim.to(anim.id("pf-hover", col.ids + 20000 + i), if (hb.hovered) 1 else 0, 22)), 5);
            const look = connectionLook(cn.kind);
            const ir: d.Rect = .{ .x = r.x, .y = r.y + 3, .w = 22, .h = 22 };
            d.rect(dl, ir, d.Rgba.hex(look.color), 6);
            const lf = ctx.ui.get(.bold);
            d.text(dl, lf, 12, ir.x + (ir.w - d.width(lf, 12, look.letter)) / 2, d.centerY(ir, 12), d.Rgba.white, look.letter);
            _ = d.textClipped(dl, font, 13.5, r.x + 30, d.centerY(r, 13.5), ctx.col(.text), cn.name, col.w - 52);
            if (cn.url.len > 0) d.text(dl, font, 12, r.x + 34 + @min(tw, col.w - 56), d.centerY(r, 12), ctx.col(.muted), "↗");
            d.tip(ctx, r, cn.kind, hb.hovered);
        }
        if (hb.clicked) att.openUrl(cn.url);
        col.y += 30;
    }
    col.y += 8;
}

/// Nota que só a gente vê. Clicar edita; Enter guarda, Esc desiste.
var note_focus = false;

fn note(col: *Col, uid: Id) void {
    const ctx = col.ctx;
    if (uid == ctx.store.me or isWebhook(ctx, uid)) return;
    col.label(i18n.tr("NOTA (SÓ VOCÊ VÊ)", "NOTE (ONLY VISIBLE TO YOU)"));
    const cur = ctx.store.notes.get(uid) orelse "";
    const r: d.Rect = .{ .x = col.x - 4, .y = col.y, .w = col.w + 8, .h = 30 };
    if (ctx.st.note_editing) {
        if (col.dl) |dl| {
            d.rect(dl, r, ctx.col(.rail).alpha(0.7), 5);
            c.ImGui_PushFontFloat(ctx.ui.get(.regular), 13.5);
            c.ImGui_SetCursorScreenPos(d.v(r.x + 6, r.y + 6));
            c.ImGui_SetNextItemWidth(r.w - 12);
            if (note_focus) {
                c.ImGui_SetKeyboardFocusHere();
                note_focus = false;
            }
            c.ImGui_PushStyleColor(c.ImGuiCol_FrameBg, 0);
            const done = c.ImGui_InputTextWithHint("##note", i18n.trZ("Escreva uma nota", "Add a note"), &ctx.st.note_input, ctx.st.note_input.len, c.ImGuiInputTextFlags_EnterReturnsTrue);
            c.ImGui_PopStyleColor();
            c.ImGui_PopFont();
            if (done) {
                const t = std.mem.sliceTo(&ctx.st.note_input, 0);
                if (!std.mem.eql(u8, t, cur)) if (ctx.st.gpa.dupe(u8, t)) |owned| ctx.act(.{ .set_note = .{ .user = uid, .text = owned } }) else |_| {};
                ctx.st.note_editing = false;
            } else if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) ctx.st.note_editing = false;
        }
    } else {
        const hb = col.hit(170, r);
        if (col.dl) |dl| {
            qa.mark(r, "profile-note", .{});
            d.rect(dl, r, ctx.col(.hover).alpha(anim.to(anim.id("pf-hover", col.ids + 30000), if (hb.hovered) 1 else 0, 22)), 5);
            if (cur.len > 0)
                _ = d.textClipped(dl, ctx.ui.get(.regular), 13.5, r.x + 6, d.centerY(r, 13.5), ctx.col(.text), cur, r.w - 12)
            else
                d.text(dl, ctx.ui.get(.italic), 13.5, r.x + 6, d.centerY(r, 13.5), ctx.col(.faint), i18n.tr("Clique para adicionar uma nota", "Click to add a note"));
        }
        if (hb.clicked) {
            ctx.st.note_editing = true;
            note_focus = true;
            @memset(&ctx.st.note_input, 0);
            const n = @min(cur.len, ctx.st.note_input.len - 1);
            @memcpy(ctx.st.note_input[0..n], cur[0..n]);
        }
    }
    col.y += 38;
}

// --- Cabeçalho (banner + avatar) ---------------------------------------------

/// Banner (imagem, cor de destaque ou do cargo), avatar com status e o botão
/// de zoom. Retorna o y logo abaixo do avatar.
fn header(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, uid: Id, pf: ?types.Profile, banner_h: f32, av: f32, radius: f32, ids: usize) f32 {
    const u = ctx.store.user(uid).?;
    const br: d.Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = banner_h };
    var drew = false;
    if (pf) |p| if (p.banner.len > 0) {
        var ub: [192]u8 = undefined;
        const url = bannerUrl(&ub, uid, p.banner);
        const scale = ctx.io.*.DisplayFramebufferScale.x;
        switch (ctx.images.get(url, br.w * scale, br.w * scale)) {
            .ready => |t| {
                // Cobre a faixa cortando o excesso (sem distorcer).
                const iw: f32 = @floatFromInt(t.w);
                const ih: f32 = @floatFromInt(t.h);
                const vh = @min(1.0, br.h / br.w * iw / ih);
                const v0 = (1 - vh) / 2;
                c.ImDrawList_AddImageRounded(dl, t.ref, d.v(br.x, br.y), d.v(br.right(), br.bottom()), d.v(0, v0), d.v(1, v0 + vh), d.Rgba.white.col(1), radius, c.ImDrawFlags_RoundCornersTop);
                drew = true;
                // Por baixo do botão do canto: quem está em cima ganha o clique.
                const hb = d.hitUnder(ctx, ids + 1, br);
                qa.mark(br, "profile-banner", .{});
                if (hb.clicked) {
                    var fb: [192]u8 = undefined;
                    att.openOriginal(ctx, w.bannerFull(&fb, uid, p.banner), u.name, @intCast(t.w), @intCast(t.h));
                }
            },
            else => {},
        }
    };
    if (!drew) {
        const accent = if (pf) |p| p.accent else 0;
        const base = if (accent != 0) d.Rgba.hex(accent) else ctx.th.role(u.role);
        c.ImDrawList_AddRectFilledMultiColor(dl, d.v(br.x, br.y), d.v(br.right(), br.bottom()), base.u(), base.mix(ctx.col(.accent), if (accent != 0) 0.15 else 0.6).u(), base.mix(ctx.col(.overlay), 0.3).u(), base.mix(ctx.col(.overlay), 0.3).u());
    }
    // Avatar (clicável: abre grande) com a bolinha de status.
    const acx = r.x + 16 + av / 2;
    const acy = br.bottom();
    const bg = ctx.col(.overlay);
    d.circle(dl, acx, acy, av / 2 + 6, bg);
    w.avatar(ctx, dl, acx, acy, av, uid, .circle, null, 1);
    const sr = av * 0.13;
    const sx = acx + av * 0.36;
    const sy = acy + av * 0.36;
    d.circle(dl, sx, sy, sr + 4, bg);
    d.circle(dl, sx, sy, sr, w.statusColor(ctx, u.status));
    const ar: d.Rect = .{ .x = acx - av / 2, .y = acy - av / 2, .w = av, .h = av };
    const hb = d.hit(ctx, ids + 2, ar);
    qa.mark(ar, "profile-avatar", .{});
    var sb: [160]u8 = undefined;
    const small = if (u.avatar) |h| w.cdnUrl(&sb, .avatar, uid, h) else "";
    // Modo economia: o primeiro clique só baixa a foto.
    const held_back = small.len > 0 and ctx.images.blocked(small);
    d.tip(ctx, ar, if (held_back) i18n.tr("Carregar foto", "Load picture") else i18n.tr("Ver foto", "View picture"), hb.hovered and u.avatar != null);
    if (hb.clicked and held_back) {
        ctx.images.allow(small);
    } else if (hb.clicked) viewAvatar(ctx, uid);
    return acy + av / 2 + 14;
}

/// A foto de alguém no visualizador, em tamanho cheio.
pub fn viewAvatar(ctx: *d.Ctx, uid: Id) void {
    const u = ctx.store.user(uid) orelse return;
    const h = u.avatar orelse return;
    var zb: [192]u8 = undefined;
    att.openOriginal(ctx, w.cdnFull(&zb, .avatar, uid, h), u.name, 1024, 1024);
}

/// Botão redondo pequeno no canto do banner.
fn cornerButton(ctx: *d.Ctx, dl: *c.ImDrawList, id: usize, r: d.Rect, tipText: []const u8, mark: []const u8) bool {
    const hb = d.hit(ctx, id, r);
    qa.mark(r, "{s}", .{mark});
    d.circle(dl, r.x + r.w / 2, r.y + r.h / 2, r.w / 2, d.Rgba.black.alpha(if (hb.hovered) 0.65 else 0.45));
    d.tip(ctx, r, tipText, hb.hovered);
    return hb.clicked;
}

// --- Cartão pequeno -------------------------------------------------------------

pub fn card(ctx: *d.Ctx, uid: Id, x: f32, y: f32) void {
    if (ctx.store.user(uid) == null) return popup.close(ctx);
    const hook = isWebhook(ctx, uid);
    if (!hook) ctx.act(.{ .want_profile = uid });
    const pf = ctx.store.profiles.get(uid);
    const width: f32 = 340;
    const banner_h: f32 = if (pf != null and pf.?.banner.len > 0) 120 else 92;
    const gid = ctx.st.guild;
    const av: f32 = 80;

    // Mede as seções antes de abrir a janela.
    var m: Col = .{ .ctx = ctx, .dl = null, .x = 0, .w = width - 32, .y = 0, .ids = 0 };
    body(&m, uid, pf, gid);
    const msg_h: f32 = if (uid != ctx.store.me and !hook) 52 else 8;
    const total_h = banner_h + av / 2 + 14 + m.y + msg_h + 6;

    const r = popup.fit(ctx, x + 6, y - 40, width, total_h);
    const dl = popup.beginWindow("##profile", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    const radius = @max(ctx.th.radius + 4, 6);
    d.shadow(dl, r, radius, 20, ctx.col(.shadow));
    d.rect(dl, r, ctx.col(.overlay), radius);
    const top = header(ctx, dl, .{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = 0 }, uid, pf, banner_h, av, radius, 900);
    d.border(dl, r, ctx.col(.border), radius, 1);
    // Abre o perfil grande.
    const fr: d.Rect = .{ .x = r.right() - 40, .y = r.y + 10, .w = 28, .h = 28 };
    if (cornerButton(ctx, dl, 905, fr, i18n.tr("Ver perfil completo", "View Full Profile"), "profile-full")) ctx.act(.{ .open_full_profile = .{ .user = uid } });
    icons.expand(dl, fr.x + 14, fr.y + 14, d.Rgba.white.alpha(0.9).u());

    var col: Col = .{ .ctx = ctx, .dl = dl, .x = r.x + 16, .w = width - 32, .y = top, .ids = 1000 };
    body(&col, uid, pf, gid);

    // "Mensagem @fulano"
    if (uid != ctx.store.me and !hook) {
        const u = ctx.store.user(uid).?;
        const ir: d.Rect = .{ .x = r.x + 12, .y = r.bottom() - 50, .w = r.w - 24, .h = 38 };
        d.rect(dl, ir, ctx.col(.elevated), @max(ctx.th.radius, 4));
        d.border(dl, ir, ctx.col(.border), @max(ctx.th.radius, 4), 1);
        c.ImGui_PushFontFloat(ctx.ui.get(.regular), 14);
        c.ImGui_SetCursorScreenPos(d.v(ir.x + 10, ir.y + 9));
        c.ImGui_SetNextItemWidth(ir.w - 20);
        var hint: [80]u8 = undefined;
        const h = i18n.fmtZ(&hint, "Mensagem @{s}", "Message @{s}", .{u.name});
        if (popup.appearing) c.ImGui_SetKeyboardFocusHere();
        if (c.ImGui_InputTextWithHint("##pmsg", h.ptr, &ctx.st.popup_input, ctx.st.popup_input.len, c.ImGuiInputTextFlags_EnterReturnsTrue)) {
            const t = std.mem.sliceTo(&ctx.st.popup_input, 0);
            if (t.len > 0) {
                if (ctx.st.gpa.dupe(u8, t)) |owned| ctx.act(.{ .send_dm = .{ .user = uid, .text = owned } }) else |_| {}
            }
            @memset(&ctx.st.popup_input, 0);
            popup.close(ctx);
        }
        c.ImGui_PopFont();
    }
}

/// O miolo do cartão pequeno.
fn body(col: *Col, uid: Id, pf: ?types.Profile, gid: Id) void {
    names(col, uid, pf, false);
    mutuals(col, uid, pf);
    bio(col, uid, pf, false);
    activities(col, uid, false);
    voice(col, uid);
    since(col, uid, pf, gid, false);
    roles(col, uid, gid);
}

// --- Perfil grande ----------------------------------------------------------------

/// Quando a aba do perfil grande mudou (o conteúdo novo entra com fade).
var tab_t0: i64 = 0;

pub fn full(ctx: *d.Ctx, uid: Id) void {
    if (ctx.store.user(uid) == null) return popup.close(ctx);
    if (!isWebhook(ctx, uid)) ctx.act(.{ .want_profile = uid });
    const pf = ctx.store.profiles.get(uid);
    const gid = ctx.st.guild;
    const mw = @min(ctx.win.w - 48, 960);
    const mh = @min(ctx.win.h - 48, 720);
    const r: d.Rect = .{ .x = ctx.win.x + (ctx.win.w - mw) / 2, .y = ctx.win.y + (ctx.win.h - mh) / 2, .w = mw, .h = mh };
    const dl = popup.beginWindow("##profile-full", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    const radius = @max(ctx.th.radius + 4, 8);
    d.shadow(dl, r, radius, 30, ctx.col(.shadow));
    d.rect(dl, r, ctx.col(.overlay), radius);
    d.border(dl, r, ctx.col(.border), radius, 1);

    // Coluna da esquerda: o cartão, com rolagem própria.
    const narrow = r.w < 720;
    const lw: f32 = if (narrow) r.w - 48 else 400;
    const left: d.Rect = .{ .x = r.x + 24, .y = r.y + 24, .w = lw, .h = if (narrow) r.h * 0.55 else r.h - 48 };
    {
        d.rect(dl, left, ctx.col(.surface), radius);
        const ldl = d.beginRegion(ctx, "##pf-left", left, c.ImGuiWindowFlags_NoScrollbar);
        popup.track(ldl);
        const o = c.ImGui_GetCursorScreenPos();
        const banner_h: f32 = 140;
        const top = header(ctx, ldl, .{ .x = o.x, .y = o.y, .w = left.w, .h = 0 }, uid, pf, banner_h, 120, radius, 2000);
        var col: Col = .{ .ctx = ctx, .dl = ldl, .x = o.x + 24, .w = left.w - 48, .y = top + 8, .ids = 3000 };
        names(&col, uid, pf, true);
        buttons(&col, uid);
        bio(&col, uid, pf, false);
        since(&col, uid, pf, gid, true);
        roles(&col, uid, gid);
        connections(&col, pf);
        note(&col, uid);
        d.endRegion(ctx, col.y + 12, left.x);
    }

    // Abas à direita (ou embaixo, se a janela é estreita).
    const right: d.Rect = if (narrow)
        .{ .x = r.x + 24, .y = left.bottom() + 16, .w = r.w - 48, .h = r.bottom() - left.bottom() - 40 }
    else
        .{ .x = left.right() + 32, .y = r.y + 28, .w = r.right() - left.right() - 64, .h = r.h - 56 };
    const nf = if (pf) |p| @max(p.mutual_friends_count, @as(u32, @intCast(p.mutual_friends.len))) else 0;
    const ng = if (pf) |p| p.mutual_guilds.len else 0;
    var tb: [2][48]u8 = undefined;
    const tabs = [_][]const u8{
        i18n.tr("Atividade", "Activity"),
        if (nf == 1) i18n.tr("1 amigo em comum", "1 Mutual Friend") else i18n.fmt(&tb[0], "{d} amigos em comum", "{d} Mutual Friends", .{nf}),
        if (ng == 1) i18n.tr("1 servidor em comum", "1 Mutual Server") else i18n.fmt(&tb[1], "{d} servidores em comum", "{d} Mutual Servers", .{ng}),
    };
    // Webhook não tem amigos nem servidores em comum.
    const own = uid == ctx.store.me or isWebhook(ctx, uid);
    var tx = right.x;
    const tf = ctx.ui.get(.semibold);
    var sel_x: f32 = right.x;
    var sel_w: f32 = 0;
    for (tabs, 0..) |t, i| {
        if (own and i > 0) break;
        const tw = d.width(tf, 14, t);
        const tr: d.Rect = .{ .x = tx, .y = right.y, .w = tw, .h = 28 };
        const hb = d.hit(ctx, 2100 + i, tr);
        qa.mark(tr, "profile-tab:{d}", .{i});
        const on = ctx.st.profile_tab == i;
        // A cor do nome da aba acompanha o marcador.
        const hk = anim.to(anim.id("pf-tab", i), if (on) 1 else if (hb.hovered) 0.6 else 0, 20);
        d.text(dl, tf, 14, tx, right.y + 4, ctx.col(.muted).mix(ctx.col(.text), hk), t);
        if (on) {
            sel_x = tx;
            sel_w = tw;
        }
        if (hb.clicked and !on) {
            ctx.st.profile_tab = @intCast(i);
            tab_t0 = ctx.now_ms;
        }
        tx += tw + 24;
    }
    // O marcador desliza até a aba escolhida.
    const ux = anim.to(anim.id("pf-tab-x", 0), sel_x - right.x, 22);
    const uw = anim.to(anim.id("pf-tab-w", 0), sel_w, 22);
    if (uw > 1) d.rect(dl, .{ .x = right.x + ux, .y = right.y + 27, .w = uw, .h = 2 }, ctx.col(.accent), 1);
    d.line(dl, right.x, right.y + 30, right.right(), right.y + 30, ctx.col(.border), 1);
    const content: d.Rect = .{ .x = right.x, .y = right.y + 40, .w = right.w, .h = right.h - 40 };
    const cdl = d.beginRegion(ctx, "##pf-right", content, 0);
    popup.track(cdl);
    const cdl_start = cdl.*.VtxBuffer.Size;
    const o = c.ImGui_GetCursorScreenPos();
    var col: Col = .{ .ctx = ctx, .dl = cdl, .x = o.x, .w = content.w - 12, .y = o.y, .ids = 4000 };
    switch (if (own) 0 else ctx.st.profile_tab) {
        1 => mutualFriends(&col, pf),
        2 => mutualGuilds(&col, pf),
        else => {
            const before = col.y;
            if (ctx.store.activities.get(uid) != null) col.label(i18n.tr("AGORA", "CURRENT ACTIVITY"));
            activities(&col, uid, true);
            voice(&col, uid);
            if (col.y == before) {
                const u = ctx.store.user(uid).?;
                const msg = if (u.activity) |a| a else i18n.tr("Nenhuma atividade agora.", "No activity right now.");
                col.gap(24);
                col.text(.medium, 14, ctx.col(.faint), msg);
            }
        },
    }
    // Troca de aba: o conteúdo novo entra com um fade e sobe um pouco.
    const tk = if (anim.instant) 1 else d.easeOut(@as(f32, @floatFromInt(ctx.now_ms - tab_t0)) / 180);
    if (tk < 1) {
        anim.active = true;
        d.transformVerts(cdl, cdl_start, d.v(content.x, content.y), 1, 8 * (1 - tk), tk);
    }
    d.endRegion(ctx, col.y + 12, content.x);

    // Fechar.
    const xr: d.Rect = .{ .x = r.right() - 44, .y = r.y + 12, .w = 32, .h = 32 };
    const xb = d.hit(ctx, 2190, xr);
    qa.mark(xr, "profile-full-close", .{});
    d.rect(dl, xr, if (xb.hovered) ctx.col(.hover) else ctx.col(.elevated), 8);
    const xc = ctx.col(.text).alpha(0.85);
    d.line(dl, xr.x + 11, xr.y + 11, xr.right() - 11, xr.bottom() - 11, xc, 1.6);
    d.line(dl, xr.right() - 11, xr.y + 11, xr.x + 11, xr.bottom() - 11, xc, 1.6);
    if (xb.clicked) popup.close(ctx);
}

/// Mensagem / aceitar pedido, no perfil grande.
fn buttons(col: *Col, uid: Id) void {
    const ctx = col.ctx;
    if (uid == ctx.store.me or isWebhook(ctx, uid)) return;
    const rel = ctx.store.relationship(uid);
    const Btn = struct { label: []const u8, mark: []const u8, accent: bool };
    var list: [2]Btn = undefined;
    var n: usize = 0;
    list[n] = .{ .label = i18n.tr("Mensagem", "Message"), .mark = "profile-btn:dm", .accent = true };
    n += 1;
    if (rel == .incoming) {
        list[n] = .{ .label = i18n.tr("Aceitar pedido", "Accept Request"), .mark = "profile-btn:accept", .accent = false };
        n += 1;
    }
    var x = col.x;
    const font = ctx.ui.get(.semibold);
    for (list[0..n], 0..) |b, i| {
        const bw = d.width(font, 13.5, b.label) + 28;
        const br: d.Rect = .{ .x = x, .y = col.y, .w = bw, .h = 32 };
        const hb = col.hit(180 + i, br);
        if (col.dl) |dl| {
            qa.mark(br, "{s}", .{b.mark});
            const bg = if (b.accent) ctx.col(.accent) else ctx.col(.elevated);
            d.rect(dl, br, if (hb.hovered) bg.mix(ctx.col(.text), 0.1) else bg, 6);
            d.text(dl, font, 13.5, br.x + 14, d.centerY(br, 13.5), if (b.accent) ctx.col(.accent_text) else ctx.col(.text), b.label);
        }
        if (hb.clicked) {
            if (i == 0) {
                ctx.act(.{ .open_dm = uid });
                popup.close(ctx);
            } else ctx.act(.{ .accept_friend = uid });
        }
        x += bw + 8;
    }
    col.y += 46;
}

fn mutualFriends(col: *Col, pf: ?types.Profile) void {
    const ctx = col.ctx;
    const p = pf orelse return;
    if (p.mutual_friends.len == 0) {
        col.gap(24);
        col.text(.medium, 14, ctx.col(.faint), i18n.tr("Nenhum amigo em comum.", "No mutual friends."));
        return;
    }
    for (p.mutual_friends, 0..) |fid, i| {
        const u = ctx.store.user(fid) orelse continue;
        const r: d.Rect = .{ .x = col.x - 6, .y = col.y, .w = col.w + 12, .h = 48 };
        const hb = col.hit(200 + i, r);
        if (col.dl) |dl| {
            qa.mark(r, "profile-friend:{d}", .{fid});
            d.rect(dl, r, ctx.col(.hover).alpha(anim.to(anim.id("pf-hover", col.ids + 40000 + i), if (hb.hovered) 1 else 0, 22)), 6);
            w.avatar(ctx, dl, r.x + 26, r.y + 24, 36, fid, .circle, null, 1);
            d.circle(dl, r.x + 39, r.y + 37, 6, ctx.col(.overlay));
            d.circle(dl, r.x + 39, r.y + 37, 4, w.statusColor(ctx, u.status));
            _ = d.textClipped(dl, ctx.ui.get(.semibold), 14.5, r.x + 54, d.centerY(r, 14.5), ctx.col(.text), u.name, r.w - 64);
        }
        if (hb.clicked) ctx.act(.{ .open_full_profile = .{ .user = fid } });
        col.y += 50;
    }
}

fn mutualGuilds(col: *Col, pf: ?types.Profile) void {
    const ctx = col.ctx;
    const p = pf orelse return;
    if (p.mutual_guilds.len == 0) {
        col.gap(24);
        col.text(.medium, 14, ctx.col(.faint), i18n.tr("Nenhum servidor em comum.", "No mutual servers."));
        return;
    }
    for (p.mutual_guilds, 0..) |gid, i| {
        const g = ctx.store.guild(gid) orelse continue;
        const r: d.Rect = .{ .x = col.x - 6, .y = col.y, .w = col.w + 12, .h = 52 };
        const hb = col.hit(400 + i, r);
        if (col.dl) |dl| {
            qa.mark(r, "profile-guild:{d}", .{gid});
            d.rect(dl, r, ctx.col(.hover).alpha(anim.to(anim.id("pf-hover", col.ids + 50000 + i), if (hb.hovered) 1 else 0, 22)), 6);
            const ir: d.Rect = .{ .x = r.x + 8, .y = r.y + 6, .w = 40, .h = 40 };
            var ib: [160]u8 = undefined;
            const url = if (g.icon) |ic| w.cdnUrl(&ib, .guild, gid, ic) else "";
            if (!w.picture(ctx, dl, url, ir, 12, 1)) {
                d.rect(dl, ir, ctx.col(.elevated), 12);
                const af = ctx.ui.get(.semibold);
                d.text(dl, af, 13, ir.x + (ir.w - d.width(af, 13, g.acronym)) / 2, d.centerY(ir, 13), ctx.col(.text), g.acronym);
            }
            _ = d.textClipped(dl, ctx.ui.get(.semibold), 14.5, r.x + 60, d.centerY(r, 14.5), ctx.col(.text), g.name, r.w - 70);
        }
        if (hb.clicked) {
            ctx.act(.{ .select_guild = gid });
            popup.close(ctx);
        }
        col.y += 54;
    }
}
