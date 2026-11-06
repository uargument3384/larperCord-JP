//! Gateway falso: roda numa thread e se comporta como o do Discord, emitindo
//! READY, histórico sob demanda, mensagens novas, "digitando", presença e
//! latência. Quando o gateway real existir, ele implementa a mesma interface
//! (recebe `Command`, entrega `Event` no `Sink`) e o resto do app não muda.
const std = @import("std");
const timeline = @import("../platform/timeline.zig");
const c = @import("c");
const types = @import("../core/types.zig");
const ev = @import("../core/event.zig");
const Queue = @import("queue.zig").Queue;
const i18n = @import("../ui/i18n.zig");
const leitura = @import("../core/leitura.zig");
const jsonx = @import("jsonx.zig");
const Id = types.Id;

const alloc = std.heap.c_allocator;

const voice_mod = @import("voice.zig");

pub const Sink = struct {
    ctx: *anyopaque,
    push: *const fn (ctx: *anyopaque, event: ev.Event) void,
};

/// O que a demonstração "mandou para o Discord" (o QA confere; não há servidor
/// para perguntar). Lido da thread da interface.
pub const sent = struct {
    const A = std.atomic.Value(u64);
    pub var acks: A = .init(0);
    pub var ack_channel: A = .init(0);
    pub var ack_message: A = .init(0);
    pub var ack_viewed: A = .init(0);
    pub var manual_acks: A = .init(0);
    pub var manual_message: A = .init(0);
    pub var bulks: A = .init(0);
    pub var bulk_len: A = .init(0);
    pub var arounds: A = .init(0);
    pub var pin_ops: A = .init(0);
    pub var pin_fetches: A = .init(0);
    pub var invite_fetches: A = .init(0);
};

pub const Gateway = struct {
    commands: Queue(ev.Command),
    sink: Sink,
    thread: ?*c.SDL_Thread = null,
    live: bool,
    rng: std.Random.DefaultPrng,
    hot_channel: Id = 0,
    last_live: Id = 0,
    next_live_ms: i64 = 0,
    pending_typing: ?struct { channel: Id, user: Id, at_ms: i64 } = null,
    next_latency_ms: i64 = 0,
    voice: ?*voice_mod.Voice = null,
    voice_channel: ?Id = null,
    nonce_replies: std.ArrayList(struct { at_ms: i64, msg: types.Message }) = .empty,
    history_replies: std.ArrayList(struct { at_ms: i64, channel: Id }) = .empty,
    /// Servidores cujos cargos já foram mandados.
    roles_sent: u64 = 0,
    /// LARPER_FLOOD=N: N trocas de presença por segundo (teste de carga,
    /// como um servidor grande).
    flood_per_s: u32 = 0,
    next_flood_ms: i64 = std.math.maxInt(i64),
    /// Começo da sessão: o histórico de um canal é sempre o mesmo dentro
    /// dela (mesmos IDs, como no Discord), mesmo pedido de novo.
    epoch_ms: i64 = 0,
    /// A mesma fila do gateway de verdade (um ack por canal a cada ~3 s).
    acks: leitura.AckQueue = .{},
    /// Fixadas da demonstração, por canal (preenche ao primeiro uso).
    pins: std.ArrayList(struct { channel: Id, id: Id }) = .empty,
    pins_seeded: std.AutoHashMapUnmanaged(Id, void) = .empty,
    /// As menções recentes que foram mostradas: a busca em volta traz as mesmas.
    mention_log: []types.Message = &.{},
    /// Threads e posts da demonstração: o que cada uma tem de conversa.
    threads: std.AutoHashMapUnmanaged(Id, DemoThread) = .empty,

    pub fn start(g: *Gateway) !void {
        g.thread = c.SDL_CreateThread(threadMain, "gateway", g) orelse return error.SdlThread;
    }

    /// A call da demonstração: só o áudio local (net/voice.zig, `local`).
    fn stopVoice(g: *Gateway) void {
        const vc = g.voice orelse return;
        vc.stop();
        vc.deinit();
        alloc.destroy(vc);
        g.voice = null;
    }

    fn startVoice(g: *Gateway, guild: Id, channel: Id, mute: bool, deaf: bool) void {
        g.stopVoice();
        const vc = alloc.create(voice_mod.Voice) catch return;
        vc.* = voice_mod.Voice.init(g.sink, guild, channel, me_id, "", "", "", mute, deaf);
        vc.local = true;
        vc.start() catch {
            vc.deinit();
            alloc.destroy(vc);
            return;
        };
        g.voice = vc;
    }

    pub fn stop(g: *Gateway) void {
        g.commands.push(.shutdown);
        if (g.thread) |t| c.SDL_WaitThread(t, null);
    }

    /// Editar servidor ou grupo: volta como o gateway de verdade, com o
    /// servidor ou canal inteiro. O que não mudou vem da semente.
    fn editPlace(g: *Gateway, e: ev.EditPlace) !void {
        defer {
            if (e.name) |t| alloc.free(t);
            if (e.description) |t| alloc.free(t);
            for ([_]ev.ImageChange{ e.icon, e.banner }) |ch| switch (ch) {
                .path => |p| alloc.free(p),
                else => {},
            };
        }
        const new_image = struct {
            fn f(ch: ev.ImageChange, demo: []const u8) !?[]const u8 {
                return if (ch == .path) try alloc.dupe(u8, demo) else null;
            }
        }.f;
        if (e.group) {
            g.emit(.{ .channel_upsert = .{
                .id = e.id,
                .guild = 0,
                .name = try alloc.dupe(u8, e.name orelse pick("rolê de sexta", "friday hangout")),
                .topic = try alloc.dupe(u8, ""),
                .position = 2,
                .recipient = group_members[0],
                .recipients = try alloc.dupe(Id, &group_members),
                .group = true,
                .icon = try new_image(e.icon, "demo:icon:3"),
            } });
            return;
        }
        const i: usize = @intCast((e.id - guildId(0)) / 1000);
        const seed = guilds[i];
        g.emit(.{ .guild_create = .{
            .guild = .{
                .id = e.id,
                .name = try alloc.dupe(u8, e.name orelse pick(seed.name, seed.name_en)),
                .acronym = try alloc.dupe(u8, pick(seed.acronym, seed.acronym_en)),
                .color = seed.color,
                .icon = try new_image(e.icon, "demo:icon:3"),
                .banner = try new_image(e.banner, "demo:2"),
                .can_banner = i < 2,
                .description = if (e.description) |t| try alloc.dupe(u8, t) else "",
                .owner = if (i == 0) me_id else 1001,
            },
            .channels = try alloc.alloc(types.Channel, 0),
            .voice = try alloc.alloc([2]Id, 0),
        } });
    }

    fn emit(g: *Gateway, e: ev.Event) void {
        g.sink.push(g.sink.ctx, e);
    }

    fn threadMain(data: ?*anyopaque) callconv(.c) c_int {
        const g: *Gateway = @ptrCast(@alignCast(data.?));
        g.run() catch |err| std.log.err("gateway: {t}", .{err});
        return 0;
    }

    fn run(g: *Gateway) !void {
        timeline.mark(.gateway);
        g.epoch_ms = nowMs();
        g.emit(.{ .ready = try buildReady() });
        g.emit(.{ .read_states = .{ .entries = try demoReadStates(g.epoch_ms) } });
        // Quem está em call na demonstração: um mudo, uma surda, um mudado pelo servidor.
        g.emit(.{ .voice_member_flags = .{ .user = 1001, .flags = .{ .self_mute = true } } });
        g.emit(.{ .voice_member_flags = .{ .user = 1005, .flags = .{ .self_mute = true, .self_deaf = true } } });
        g.emit(.{ .voice_member_flags = .{ .user = 1003, .flags = .{ .mute = true } } });
        // O @everyone do segundo servidor (que não é nosso): com ele, o #bugs
        // e o AFK de lá aparecem trancados (demoOverwrites).
        {
            const rs = try alloc.alloc(types.Role, 1);
            rs[0] = .{ .id = guildId(1), .guild = guildId(1), .name = try alloc.dupe(u8, "@everyone"), .permissions = types.perm.view_channel | types.perm.send_messages | types.perm.read_history | types.perm.connect };
            g.emit(.{ .roles = .{ .guild = guildId(1), .roles = rs } });
            // Igual no servidor das threads sem permissão: nada de responder
            // nelas nem de criar novas (ver `demoThreads`).
            const rs2 = try alloc.alloc(types.Role, 1);
            rs2[0] = .{ .id = guildId(locked_guild), .guild = guildId(locked_guild), .name = try alloc.dupe(u8, "@everyone"), .permissions = rs[0].permissions };
            g.emit(.{ .roles = .{ .guild = guildId(locked_guild), .roles = rs2 } });
        }
        for (relations, 0..) |rel, i| g.emit(.{ .relationship = .{ .user = rel.user, .kind = rel.kind, .since_ms = nowMs() - @as(i64, @intCast(i + 1)) * 97 * 86_400_000 } });
        try g.demoActivities();
        g.emit(.{ .guild_folders = try demoFolders() });
        try g.demoThreads();
        try g.demoEmojis();
        g.emit(.{ .status = .ready });
        g.next_live_ms = nowMs() + 6000;
        if (c.SDL_getenv("LARPER_FLOOD")) |f| {
            g.flood_per_s = std.fmt.parseInt(u32, std.mem.span(f), 10) catch 0;
            if (g.flood_per_s > 0) g.next_flood_ms = nowMs() + 500;
        }
        g.next_latency_ms = nowMs() + 1500;

        var cmds: std.ArrayList(ev.Command) = .empty;
        defer cmds.deinit(alloc);
        defer g.stopVoice();
        while (true) {
            const now = nowMs();
            const wait: i32 = @intCast(std.math.clamp(g.nextDeadline() - now, 1, 2000));
            g.commands.waitDrain(&cmds, wait);
            for (cmds.items) |cmd| switch (cmd) {
                .shutdown => return,
                .send_message => |m| {
                    // Os arquivos já aparecem na cópia pendente (o Store
                    // mantém os anexos dela na confirmação).
                    for (m.files) |f| alloc.free(f);
                    if (m.files.len > 0) alloc.free(m.files);
                    // Como o gateway de verdade: emoji personalizado aparece
                    // como `:nome:` e o texto original fica em `raw`.
                    const shown = try jsonx.simplifyContent(alloc, m.content);
                    var raw: []const u8 = "";
                    if (shown.len != m.content.len) raw = m.content else alloc.free(m.content);
                    // O "servidor" confirma depois de um RTT simulado.
                    try g.nonce_replies.append(alloc, .{ .at_ms = nowMs() + 90, .msg = .{
                        .id = types.makeSnowflake(nowMs(), g.rng.random().int(u22)),
                        .channel = m.channel,
                        .author = me_id,
                        .timestamp = @divTrunc(nowMs(), 1000),
                        .content = shown,
                        .raw = raw,
                        .nonce = m.nonce,
                        .reply_to = m.reply_to,
                    } });
                },
                .forward_message => {}, // O gateway de demonstração não simula encaminhamentos.
                .edit_message => |m| {
                    const shown = try jsonx.simplifyContent(alloc, m.content);
                    var raw: ?[]const u8 = null;
                    if (shown.len != m.content.len) raw = m.content else alloc.free(m.content);
                    g.emit(.{ .message_update = .{ .channel = m.channel, .id = m.id, .content = shown, .raw = raw } });
                },
                .delete_message => |m| g.emit(.{ .message_delete = .{ .channel = m.channel, .id = m.id } }),
                .delete_thread => |id| g.emit(.{ .channel_delete = id }),
                .edit_place => |e| try g.editPlace(e),
                .react => |r| g.emit(.{ .reaction = .{ .channel = r.channel, .id = r.id, .emoji = r.emoji, .user = me_id, .add = r.add } }),
                .fetch_history => |ch| {
                    g.hot_channel = ch;
                    try g.history_replies.append(alloc, .{ .at_ms = nowMs() + 140, .channel = ch });
                },
                .fetch_threads => |ft| try g.threadsPage(ft.channel, ft.guild, ft.archived, ft.offset),
                .create_thread => |ct| {
                    // Como no Discord: a thread tem o ID da mensagem que a abriu.
                    try g.threads.put(alloc, ct.message, .{ .count = 0, .members = 1 });
                    g.emit(.{ .channel_upsert = .{
                        .id = ct.message,
                        .guild = guildOfChannel(ct.channel),
                        .parent = ct.channel,
                        .name = ct.name,
                        .topic = try alloc.dupe(u8, ""),
                        .thread = .{ .owner = me_id, .joined = true, .joined_known = true, .member_count = 1 },
                    } });
                    g.emit(.{ .thread_open = ct.message });
                },
                .create_post => |cp| {
                    const id = types.makeSnowflake(nowMs(), g.rng.random().int(u22));
                    try g.threads.put(alloc, id, .{ .count = 0, .members = 1 });
                    g.emit(.{ .channel_upsert = .{
                        .id = id,
                        .guild = guildOfChannel(cp.forum),
                        .parent = cp.forum,
                        .name = cp.name,
                        .topic = try alloc.dupe(u8, ""),
                        .thread = .{ .owner = me_id, .joined = true, .joined_known = true, .member_count = 1, .tags = cp.tags },
                    } });
                    g.emit(.{ .message_create = .{ .id = id, .channel = id, .author = me_id, .timestamp = @divTrunc(nowMs(), 1000), .content = cp.content } });
                    g.emit(.{ .thread_open = id });
                },
                .join_thread => |jt| {
                    g.emit(.{ .thread_joined = .{ .thread = jt.thread, .joined = jt.join } });
                    const list = try alloc.alloc(Id, 1);
                    list[0] = me_id;
                    g.emit(.{ .thread_members = if (jt.join) .{ .thread = jt.thread, .added = list } else .{ .thread = jt.thread, .removed = list } });
                },
                .fetch_thread_members => |tid| {
                    const n: usize = if (g.threads.get(tid)) |t| t.members else 0;
                    // Sem ninguém na lista: a interface usa a do canal pai.
                    if (n == 0) continue;
                    const list = try alloc.alloc(Id, n);
                    for (list, 0..) |*u, i| u.* = users[1 + (i + tid % 5) % 7].id;
                    g.emit(.{ .thread_members = .{ .thread = tid, .replace = true, .added = list } });
                },
                .typing => {},
                .fetch_older => |o| {
                    const msgs = try buildOlder(o.channel, o.before);
                    // Duas semanas para trás é o "começo do canal" na demonstração.
                    const more = @divTrunc(nowMs(), 1000) - msgs[0].timestamp < 14 * 86400;
                    g.emit(.{ .history = .{ .channel = o.channel, .messages = msgs, .older = true, .more = more } });
                },
                .subscribe_guild => |sg| try g.memberList(sg.guild),
                .relationship => |r| g.emit(.{ .relationship = .{ .user = r.user, .kind = if (r.accept) .friend else .none } }),
                .fetch_profile => |fp| {
                    const seed = for (users) |x| {
                        if (x.id == fp.user) break x;
                    } else continue;
                    // Servidores em comum: os da demonstração em que a pessoa está.
                    var mg: std.ArrayList(Id) = .empty;
                    for (guilds, 0..) |_, gi| if (fp.user == me_id or (fp.user * 7 + gi) % 5 != 0) try mg.append(alloc, guildId(gi));
                    var mf: std.ArrayList(Id) = .empty;
                    for (relations) |rel| if (rel.kind == .friend and rel.user != fp.user and (rel.user + fp.user) % 3 != 0) try mf.append(alloc, rel.user);
                    const cns = try alloc.alloc(types.Connection, 2);
                    cns[0] = .{ .kind = try alloc.dupe(u8, "github"), .name = try alloc.dupe(u8, seed.name), .url = try std.fmt.allocPrint(alloc, "https://github.com/{s}", .{seed.name}) };
                    cns[1] = .{ .kind = try alloc.dupe(u8, "steam"), .name = try alloc.dupe(u8, seed.name), .url = "" };
                    const nf: u32 = @intCast(mf.items.len);
                    g.emit(.{ .profile = .{ .user = fp.user, .profile = .{
                        .banner = if (fp.user % 2 == 1) try alloc.dupe(u8, "demo:1") else "",
                        .accent = 0x5865F2,
                        .bio = try i18n.allocPrint(alloc, "oi! sou **{s}** 👋\nfalo de zig, rice e café.", "hi! I'm **{s}** 👋\ninto zig, ricing and coffee.", .{seed.name}),
                        .pronouns = try alloc.dupe(u8, if (fp.user % 3 == 0) "ela/dela" else "ele/dele"),
                        .username = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ seed.name, fp.user % 100 }),
                        .guild = fp.guild,
                        .joined_ms = if (fp.guild != 0) nowMs() - @as(i64, @intCast(fp.user % 40 + 3)) * 30 * 86_400_000 else 0,
                        .mutual_guilds = try mg.toOwnedSlice(alloc),
                        .mutual_friends = try mf.toOwnedSlice(alloc),
                        .mutual_friends_count = nf,
                        .connections = cns,
                    } } });
                    if (fp.user == 1001) g.emit(.{ .note = .{ .user = fp.user, .text = try i18n.allocPrint(alloc, "conheci na game jam", "met at the game jam", .{}) } });
                },
                .member_role => {},
                .set_note => |n| alloc.free(n.text),
                .move_member => |mm| g.emit(.{ .voice_state = .{ .channel = mm.channel, .user = mm.user } }),
                .fetch_app => |app| g.emit(.{ .app_icon = .{ .app = app, .icon = "" } }),
                .set_status => |st| g.emit(.{ .presence_update = .{ .user = me_id, .status = st } }),
                .create_dm => |u| {
                    const seed = for (users) |x| {
                        if (x.id == u) break x;
                    } else continue;
                    g.emit(.{ .channel_upsert = .{
                        .id = 900_100 + u,
                        .guild = 0,
                        .name = try alloc.dupe(u8, seed.name),
                        .topic = try alloc.dupe(u8, ""),
                        .recipient = u,
                    } });
                },
                .join_voice => |v| {
                    g.emit(.{ .voice_state = .{ .channel = v.channel, .user = me_id, .flags = .{ .self_mute = v.mute, .self_deaf = v.deaf } } });
                    g.emit(.{ .voice_status = .{ .status = if (v.channel != null) .connected else .disconnected, .channel = v.channel orelse 0 } });
                    if (v.channel) |ch| {
                        g.startVoice(v.guild, ch, v.mute, v.deaf);
                        g.voice_channel = ch;
                        g.emit(.{ .voice_ping = 38 + g.rng.random().uintLessThan(u32, 24) });
                    } else {
                        g.stopVoice();
                        g.voice_channel = null;
                    }
                },
                .voice_flags => |f| {
                    if (g.voice) |vc| vc.setFlags(f.mute, f.deaf);
                    g.emit(.{ .voice_state = .{ .channel = g.voice_channel, .user = me_id, .flags = .{ .self_mute = f.mute, .self_deaf = f.deaf } } });
                },
                .voice_volume => {},
                .fetch_mentions => {
                    const t = nowMs();
                    if (g.mention_log.len > 0) freeMessages(g.mention_log);
                    g.mention_log = try demoMentions(t);
                    g.emit(.{ .recent_mentions = try demoMentions(t) });
                },
                .ack => |a| {
                    if (!a.manual) {
                        g.acks.push(alloc, .{ .channel = a.channel, .message = a.message, .last_viewed = a.last_viewed });
                        continue;
                    }
                    g.acks.cancel(alloc, a.channel, nowMs());
                    _ = sent.manual_acks.fetchAdd(1, .monotonic);
                    sent.manual_message.store(a.message, .monotonic);
                    g.emit(.{ .read = .{ .channel = a.channel, .message = a.message, .mentions = a.mentions, .manual = true } });
                },
                .ack_bulk => |list| {
                    _ = sent.bulks.fetchAdd(1, .monotonic);
                    sent.bulk_len.store(list.len, .monotonic);
                    for (list) |e| {
                        g.acks.cancel(alloc, e[0], nowMs());
                        g.emit(.{ .read = .{ .channel = e[0], .message = e[1] } });
                    }
                    if (list.len > 0) alloc.free(list);
                },
                .fetch_around => |o| {
                    _ = sent.arounds.fetchAdd(1, .monotonic);
                    const page = try buildAround(o.channel, o.id, g.epoch_ms);
                    g.placeMention(page, o.id);
                    g.emit(.{ .history = .{ .channel = o.channel, .messages = page, .around = true, .more = true } });
                },
                .fetch_newer => |o| {
                    const page = try buildNewer(o.channel, o.after, g.epoch_ms);
                    g.emit(.{ .history = .{ .channel = o.channel, .messages = page.msgs, .newer = true, .more = page.more } });
                },
                .fetch_pins => |channel| {
                    _ = sent.pin_fetches.fetchAdd(1, .monotonic);
                    try g.seedPins(channel);
                    g.emit(.{ .pins = .{ .channel = channel, .messages = try g.buildPins(channel) } });
                },
                .pin => |p| {
                    _ = sent.pin_ops.fetchAdd(1, .monotonic);
                    try g.seedPins(p.channel);
                    for (g.pins.items, 0..) |x, i| if (x.channel == p.channel and x.id == p.id) {
                        _ = g.pins.orderedRemove(i);
                        break;
                    };
                    if (p.add) try g.pins.append(alloc, .{ .channel = p.channel, .id = p.id });
                    g.emit(.{ .message_update = .{ .channel = p.channel, .id = p.id, .content = null, .pinned = p.add } });
                    g.emit(.{ .pins_changed = p.channel });
                },
                .fetch_invite => |code| {
                    _ = sent.invite_fetches.fetchAdd(1, .monotonic);
                    g.emit(.{ .invite = .{ .code = code, .invite = try demoInvite(code.slice()) } });
                },
            };
            cmds.clearRetainingCapacity();
            try g.tick(nowMs());
        }
    }

    /// Threads ativas, como o Discord manda ao abrir o servidor: duas abertas
    /// de mensagens do #zig (o cartão aparece nelas) e uma solta; no servidor
    /// sem permissões, uma no #geral (sem poder responder) e uma no #bugs
    /// (trancado, porque o pai é).
    fn demoThreads(g: *Gateway) !void {
        const zig = channelId(thread_guild, 9);
        const msgs = try buildHistory(zig, g.epoch_ms);
        defer freeMessages(msgs);
        const n = msgs.len;
        const specs = [_]struct { id: Id, name: []const u8, en: []const u8, parent: Id, guild: usize, count: u32, members: u8, joined: bool, unread: bool, first: ?*const types.Message = null, secs: i64 = 0 }{
            .{ .id = msgs[n - 8].id, .name = "quem dá free nisso?", .en = "who frees this?", .parent = zig, .guild = thread_guild, .count = 7, .members = 3, .joined = true, .unread = false, .first = &msgs[n - 8] },
            .{ .id = msgs[n - 34].id, .name = "migração para o zig 0.17", .en = "moving to zig 0.17", .parent = zig, .guild = thread_guild, .count = 12, .members = 0, .joined = false, .unread = true, .first = &msgs[n - 34] },
            .{ .id = 0, .name = "benchmarks do cliente", .en = "client benchmarks", .parent = zig, .guild = thread_guild, .count = 4, .members = 2, .joined = false, .unread = false, .secs = 3 * 3600 },
            .{ .id = 0, .name = "dúvida sobre o tema", .en = "question about the theme", .parent = channelId(locked_guild, 4), .guild = locked_guild, .count = 5, .members = 2, .joined = false, .unread = false, .secs = 2 * 3600 },
            .{ .id = 0, .name = "bug secreto", .en = "secret bug", .parent = channelId(locked_guild, 11), .guild = locked_guild, .count = 2, .members = 0, .joined = false, .unread = false, .secs = 5 * 3600 },
        };
        for ([_]usize{ thread_guild, locked_guild }) |gi| {
            var list: std.ArrayList(types.Channel) = .empty;
            var joined: std.ArrayList(Id) = .empty;
            var parents: std.ArrayList(Id) = .empty;
            for (specs, 0..) |t, si| {
                if (t.guild != gi) continue;
                const id = if (t.id != 0) t.id else types.makeSnowflake(g.epoch_ms - t.secs * 1000, 0x2f0000 + si);
                var rec: DemoThread = .{ .count = t.count, .members = t.members };
                if (t.first) |m| {
                    rec.first_author = m.author;
                    rec.first_text = try alloc.dupe(u8, m.content);
                }
                try g.threads.put(alloc, id, rec);
                try list.append(alloc, .{
                    .id = id,
                    .guild = guildId(gi),
                    .parent = t.parent,
                    .name = try alloc.dupe(u8, pick(t.name, t.en)),
                    .topic = try alloc.dupe(u8, ""),
                    .unread = t.unread,
                    .thread = .{ .owner = 1001, .joined = t.joined, .joined_known = true, .message_count = t.count, .member_count = t.members, .last_message = types.makeSnowflake(g.epoch_ms - 240_000 - @as(i64, @intCast(si)) * 700_000, 0x2e0000 + si) },
                });
                if (std.mem.indexOfScalar(Id, parents.items, t.parent) == null) try parents.append(alloc, t.parent);
                if (t.joined) try joined.append(alloc, id);
            }
            g.emit(.{ .thread_list_sync = .{ .guild = guildId(gi), .parents = try parents.toOwnedSlice(alloc), .threads = try list.toOwnedSlice(alloc), .joined = try joined.toOwnedSlice(alloc) } });
        }
    }

    /// Uma página de threads de um canal da demonstração: nos fóruns, os
    /// posts; num canal de texto, só as arquivadas (as ativas vieram no sync).
    fn threadsPage(g: *Gateway, channel: Id, guild: Id, archived: bool, offset: u32) !void {
        const forum = isDemoForum(channel);
        const total: u32 = if (forum) (if (archived) @as(u32, 8) else 60) else if (archived and channel == channelId(thread_guild, 9)) 6 else 0;
        const page: u32 = if (archived) 50 else 25;
        const first = @min(offset, total);
        const last = @min(first + page, total);
        const threads = try alloc.alloc(types.Channel, last - first);
        const previews = try alloc.alloc(types.ThreadPreview, last - first);
        var joined: std.ArrayList(Id) = .empty;
        const tags = demoTags(channel);
        for (first..last) |i| {
            const post = demo_posts[i % demo_posts.len];
            // Um post a cada 7 h para trás; as arquivadas, depois de todas as ativas.
            const age: i64 = @intCast((i + (if (archived) @as(usize, 80) else 0)) * 7 + 1);
            const t_ms = g.epoch_ms - age * 3_600_000;
            const id = types.makeSnowflake(t_ms, 0x100000 + (channel % 512) * 256 + i + (if (archived) @as(usize, 128) else 0));
            const replies: u32 = @intCast((i * 13 + 3) % 40);
            const author = users[1 + (i * 3) % 7].id;
            try g.threads.put(alloc, id, .{ .count = @min(replies, 12), .members = @intCast(i % 4), .first_author = author, .first_text = try alloc.dupe(u8, pick(post.body, post.body_en)) });
            var applied: []Id = &.{};
            if (forum) {
                applied = try alloc.alloc(Id, 1 + i % 2);
                for (applied, 0..) |*a, k| a.* = tags[(i + k) % tags.len];
            }
            const title = pick(post.title, post.title_en);
            threads[i - first] = .{
                .id = id,
                .guild = guild,
                .parent = channel,
                .name = if (i < demo_posts.len) try alloc.dupe(u8, title) else try std.fmt.allocPrint(alloc, "{s} ({d})", .{ title, i / demo_posts.len + 1 }),
                .topic = try alloc.dupe(u8, ""),
                .thread = .{
                    .owner = author,
                    .archived = archived,
                    .locked = archived and i == 2,
                    .joined = !archived and i % 9 == 4,
                    .joined_known = true,
                    .message_count = replies,
                    .member_count = @intCast(i % 4 + 1),
                    .last_message = types.makeSnowflake(t_ms + @as(i64, @intCast((i * 37) % 300)) * 60_000, 0x80000 + i),
                    .archive_ts = if (archived) @divTrunc(t_ms, 1000) else 0,
                    .tags = applied,
                },
            };
            previews[i - first] = .{ .thread = id, .author = author, .text = try alloc.dupe(u8, pick(post.body, post.body_en)) };
            if (!archived and i % 9 == 4) try joined.append(alloc, id);
        }
        g.emit(.{ .threads_page = .{ .channel = channel, .archived = archived, .threads = threads, .previews = previews, .joined = try joined.toOwnedSlice(alloc), .more = last < total } });
    }

    /// Jogos da demonstração (com tempo de jogo, para o cartão de perfil).
    fn demoActivities(g: *Gateway) !void {
        const list = [_]struct { user: Id, name: []const u8, details: []const u8, mins: i64 }{
            .{ .user = 1002, .name = "Hollow Knight", .details = "Cidade das Lágrimas", .mins = 68 },
            .{ .user = 1007, .name = "Minecraft", .details = "Survival com a galera", .mins = 23 },
        };
        for (list, 0..) |a, i| {
            const acts = try alloc.alloc(types.Activity, 1);
            acts[0] = .{
                .name = try alloc.dupe(u8, a.name),
                .details = try alloc.dupe(u8, a.details),
                .start_ms = nowMs() - a.mins * 60_000,
                .image = try std.fmt.allocPrint(alloc, "demo:icon:{d}", .{i + 1}),
            };
            const u = for (users) |x| {
                if (x.id == a.user) break x;
            } else continue;
            g.emit(.{ .presence_update = .{ .user = a.user, .status = u.status, .activities = acts } });
        }
    }

    /// Lista de membros de um servidor da demonstração, no formato do
    /// GUILD_MEMBER_LIST_UPDATE: online por cargo em destaque, depois offline.
    fn demoEmojis(g: *Gateway) !void {
        for (0..guilds.len) |gi| {
            var n: usize = 0;
            for (demo_emojis) |e| {
                if (e.guild == gi) n += 1;
            }
            if (n == 0) continue;
            const list = try alloc.alloc(types.Emoji, n);
            n = 0;
            for (demo_emojis) |e| if (e.guild == gi) {
                list[n] = .{ .id = e.id, .guild = guildId(gi), .name = try alloc.dupe(u8, e.name), .animated = e.animated, .available = e.available };
                n += 1;
            };
            g.emit(.{ .guild_emojis = .{ .guild = guildId(gi), .emojis = list } });
        }
    }

    fn memberList(g: *Gateway, gid: Id) !void {
        if (gid < guildId(0)) return;
        const gi: usize = @intCast((gid - guildId(0)) / 1000);
        if (gi >= guilds.len) return;
        const role_ids = [_]Id{ gid + 901, gid + 902, gid + 903 };
        if (g.roles_sent & (@as(u64, 1) << @intCast(gi)) == 0) {
            g.roles_sent |= @as(u64, 1) << @intCast(gi);
            const rs = try alloc.alloc(types.Role, demo_roles.len);
            for (demo_roles, 0..) |r, i| rs[i] = .{ .id = role_ids[i], .guild = gid, .name = try alloc.dupe(u8, pick(r.name, r.name_en)), .color = r.color, .position = @intCast(3 - i), .mentionable = i != 0 };
            g.emit(.{ .roles = .{ .guild = gid, .roles = rs } });
        }
        // Quem está neste servidor e em qual cargo (0 = fundação, 1 = moderação, 2 = membro).
        var rank: [users.len]?u8 = @splat(null);
        for (users, 0..) |u, i| {
            if (u.id != me_id and (u.id * 7 + gi) % 5 == 0) continue;
            rank[i] = if (u.id == 1001 or (u.id == me_id and gi == 0)) 0 else if ((u.id + gi) % 3 == 0) 1 else 2;
        }
        var items: std.ArrayList(types.MemberItem) = .empty;
        defer items.deinit(alloc);
        var online: u32 = 0;
        var total: u32 = 0;
        // Grupos online (cargos 0 e 1 em destaque; o 2 cai em "online").
        for ([_]u8{ 0, 1, 2 }) |want| {
            var count: u32 = 0;
            for (users, 0..) |u, i| if (rank[i] == want and u.status != .offline) {
                count += 1;
            };
            if (count == 0) continue;
            try items.append(alloc, .{ .group = .{ .id = if (want == 2) types.group_online else role_ids[want], .count = count } });
            for (users, 0..) |u, i| if (rank[i] == want and u.status != .offline) {
                try items.append(alloc, .{ .member = .{ .user = u.id, .info = demoInfo(role_ids, want) } });
            };
            online += count;
        }
        var offline: u32 = 0;
        for (users, 0..) |u, i| if (rank[i] != null and u.status == .offline) {
            offline += 1;
        };
        if (offline > 0) {
            try items.append(alloc, .{ .group = .{ .id = types.group_offline, .count = offline } });
            for (users, 0..) |u, i| if (rank[i] != null and u.status == .offline) {
                try items.append(alloc, .{ .member = .{ .user = u.id, .info = demoInfo(role_ids, rank[i].?) } });
            };
        }
        total = online + offline;
        const ops = try alloc.alloc(types.MemberOp, 1);
        ops[0] = .{ .kind = .sync, .index = 0, .end = 99, .items = try alloc.dupe(types.MemberItem, items.items) };
        g.emit(.{ .member_list = .{ .guild = gid, .list_id = gid, .online = online, .total = total, .ops = ops } });
    }

    fn demoInfo(role_ids: [3]Id, rank: u8) types.MemberInfo {
        var info: types.MemberInfo = .{ .color = demo_roles[rank].color };
        // Todo mundo tem "Membros"; quem está acima tem também o próprio cargo.
        if (rank < 2) {
            info.roles[0] = role_ids[rank];
            info.n_roles = 1;
        }
        info.roles[info.n_roles] = role_ids[2];
        info.n_roles += 1;
        return info;
    }

    fn nextDeadline(g: *Gateway) i64 {
        var d = @min(@min(g.next_live_ms, g.next_latency_ms), g.next_flood_ms);
        if (g.pending_typing) |t| d = @min(d, t.at_ms);
        for (g.nonce_replies.items) |r| d = @min(d, r.at_ms);
        for (g.history_replies.items) |r| d = @min(d, r.at_ms);
        return @min(d, g.acks.nextDue());
    }

    /// Os acks que já podem sair, com o eco que o Discord manda de volta.
    fn flushAcks(g: *Gateway, now: i64) void {
        while (g.acks.take(now)) |a| {
            _ = sent.acks.fetchAdd(1, .monotonic);
            sent.ack_channel.store(a.channel, .monotonic);
            sent.ack_message.store(a.message, .monotonic);
            sent.ack_viewed.store(a.last_viewed, .monotonic);
            g.emit(.{ .read = .{ .channel = a.channel, .message = a.message } });
        }
    }

    /// A menção recente (que não existe no histórico inventado) aparece na
    /// página com o texto que a caixa de entrada mostrou.
    fn placeMention(g: *Gateway, page: []types.Message, id: Id) void {
        for (g.mention_log) |ml| {
            if (ml.id != id) continue;
            var at: usize = 0;
            for (page, 0..) |m, i| if (m.id <= id) {
                at = i;
            };
            if (page.len == 0) return;
            const text = alloc.dupe(u8, ml.content) catch return;
            freeOne(page[at]);
            page[at] = .{ .id = id, .channel = ml.channel, .author = ml.author, .timestamp = ml.timestamp, .content = text };
            return;
        }
    }

    /// Duas recentes e uma antiga (fora do que carrega ao abrir).
    fn seedPins(g: *Gateway, channel: Id) !void {
        const gop = try g.pins_seeded.getOrPut(alloc, channel);
        if (gop.found_existing) return;
        const latest = try buildHistory(channel, g.epoch_ms);
        defer freeMessages(latest);
        try g.pins.append(alloc, .{ .channel = channel, .id = oldPinId(channel, g.epoch_ms) });
        for (pinned_backs) |back| try g.pins.append(alloc, .{ .channel = channel, .id = latest[latest.len - back].id });
    }

    /// As fixadas do canal, da última fixada para a primeira, como a API manda.
    fn buildPins(g: *Gateway, channel: Id) ![]types.Message {
        const latest = try buildHistory(channel, g.epoch_ms);
        defer freeMessages(latest);
        var out: std.ArrayList(types.Message) = .empty;
        var i = g.pins.items.len;
        while (i > 0) {
            i -= 1;
            const p = g.pins.items[i];
            if (p.channel != channel) continue;
            const from = for (latest) |m| {
                if (m.id == p.id) break m;
            } else null;
            if (from) |m| {
                try out.append(alloc, .{ .id = m.id, .channel = channel, .author = m.author, .timestamp = m.timestamp, .content = try alloc.dupe(u8, m.content), .pinned = true });
            } else {
                var m = try syntheticAt(channel, p.id, g.epoch_ms);
                m.pinned = true;
                try out.append(alloc, m);
            }
        }
        return out.toOwnedSlice(alloc);
    }

    fn tick(g: *Gateway, now: i64) !void {
        g.flushAcks(now);
        var i: usize = 0;
        while (i < g.nonce_replies.items.len) {
            const r = g.nonce_replies.items[i];
            if (r.at_ms <= now) {
                g.emit(.{ .message_create = r.msg });
                _ = g.nonce_replies.orderedRemove(i);
            } else i += 1;
        }
        i = 0;
        while (i < g.history_replies.items.len) {
            const r = g.history_replies.items[i];
            if (r.at_ms <= now) {
                // Thread ou post: uma conversa curta, que tem começo.
                if (g.threads.get(r.channel)) |t| {
                    g.emit(.{ .history = .{ .channel = r.channel, .messages = try buildThreadHistory(r.channel, t, g.epoch_ms), .more = false } });
                    _ = g.history_replies.orderedRemove(i);
                    continue;
                }
                const msgs = try buildHistory(r.channel, g.epoch_ms);
                g.emit(.{ .history = .{ .channel = r.channel, .messages = msgs, .more = msgs.len > 0 } });
                // Algumas reações nas mensagens recentes.
                var prng = std.Random.DefaultPrng.init(r.channel ^ 0xABCD);
                const rr = prng.random();
                var k: usize = 0;
                while (k < 24) : (k += 1) {
                    const mi = msgs.len - 1 - rr.uintLessThan(usize, @min(msgs.len, 60));
                    const emoji = reaction_pool[rr.uintLessThan(usize, reaction_pool.len)];
                    const n = 1 + rr.uintLessThan(usize, 4);
                    for (0..n) |u| g.emit(.{ .reaction = .{ .channel = r.channel, .id = msgs[mi].id, .emoji = types.Reaction.init(emoji), .user = users[1 + (u + mi) % 7].id, .add = true } });
                }
                // Reações personalizadas (uma animada) na mensagem com emoji.
                if (r.channel == emoji_channel) {
                    const target = msgs[msgs.len - 2].id;
                    for (0..3) |u| g.emit(.{ .reaction = .{ .channel = r.channel, .id = target, .emoji = types.Reaction.initCustom("larper", demo_emojis[0].id, false), .user = users[1 + u].id, .add = true } });
                    g.emit(.{ .reaction = .{ .channel = r.channel, .id = target, .emoji = types.Reaction.initCustom("festa", demo_emojis[3].id, true), .user = users[4].id, .add = true } });
                }
                _ = g.history_replies.orderedRemove(i);
            } else i += 1;
        }
        if (now >= g.next_flood_ms) {
            // Em rajadas de 10 ms, como chegam do gateway de verdade.
            const n = @max(1, g.flood_per_s / 100);
            const r = g.rng.random();
            for (0..n) |_| {
                const who = users[1 + r.uintLessThan(usize, users.len - 1)].id;
                g.emit(.{ .presence_update = .{ .user = who, .status = @enumFromInt(r.uintLessThan(u8, 3)) } });
            }
            g.next_flood_ms = now + 10;
        }
        if (now >= g.next_latency_ms) {
            g.emit(.{ .latency = 38 + g.rng.random().uintLessThan(u32, 24) });
            g.next_latency_ms = now + 20_000;
            if (g.voice != null) g.emit(.{ .voice_ping = 38 + g.rng.random().uintLessThan(u32, 24) });
        }
        if (!g.live) {
            g.next_live_ms = std.math.maxInt(i64) / 2;
            return;
        }
        // Alguém começa a digitar e, pouco depois, manda a mensagem.
        if (g.pending_typing) |t| {
            if (now >= t.at_ms) {
                const r = g.rng.random();
                const id = types.makeSnowflake(now, r.int(u22));
                g.emit(.{ .message_create = .{
                    .id = id,
                    .channel = t.channel,
                    .author = t.user,
                    .timestamp = @divTrunc(now, 1000),
                    .content = try alloc.dupe(u8, phrase(r.uintLessThan(usize, phrases.len))),
                    .reply_to = if (r.uintLessThan(u8, 3) == 0) g.last_live else 0,
                } });
                g.last_live = id;
                g.pending_typing = null;
                g.next_live_ms = now + r.intRangeLessThan(i64, 7000, 16000);
            }
        } else if (now >= g.next_live_ms and g.hot_channel != 0) {
            const r = g.rng.random();
            const user = if (dmRecipient(g.hot_channel)) |u| u else users[1 + r.uintLessThan(usize, 7)].id;
            g.emit(.{ .typing_start = .{ .channel = g.hot_channel, .user = user } });
            g.pending_typing = .{ .channel = g.hot_channel, .user = user, .at_ms = now + r.intRangeLessThan(i64, 2200, 4000) };
            if (r.uintLessThan(u8, 4) == 0) {
                const who = users[1 + r.uintLessThan(usize, users.len - 1)].id;
                const st: types.Status = @enumFromInt(r.uintLessThan(u8, 3));
                g.emit(.{ .presence_update = .{ .user = who, .status = st } });
            }
        }
    }
};

pub fn nowMs() i64 {
    var t: c.SDL_Time = 0;
    _ = c.SDL_GetCurrentTime(&t);
    return @divTrunc(t, 1_000_000);
}

// --- Dados de demonstração -------------------------------------------------
//
// Os textos têm versão em inglês ao lado (`*_en`), escolhida na hora em que o
// READY ou o histórico é montado. Nomes, ids, ordem e sorteios são os mesmos
// nos dois idiomas: só muda o texto.

/// O texto no idioma atual: `en` quando existir e a interface estiver em inglês.
fn pick(pt: []const u8, en: ?[]const u8) []const u8 {
    return if (i18n.en()) en orelse pt else pt;
}

const me_id: Id = 1000;

/// Emojis personalizados da demonstração (a imagem sai do carregador:
/// "demo:emoji:<id>:<animado>"). `guild`: índice do servidor. Sem Nitro na conta
/// da demonstração: os do segundo servidor e os animados ficam travados.
pub const demo_emojis = [_]struct { id: Id, guild: usize, name: []const u8, animated: bool = false, available: bool = true }{
    .{ .id = 900_101, .guild = 0, .name = "larper" },
    .{ .id = 900_102, .guild = 0, .name = "pepe_ok" },
    .{ .id = 900_103, .guild = 0, .name = "ziguana" },
    .{ .id = 900_104, .guild = 0, .name = "festa", .animated = true },
    .{ .id = 900_105, .guild = 0, .name = "cafe" },
    .{ .id = 900_106, .guild = 0, .name = "gato_triste" },
    .{ .id = 900_201, .guild = 1, .name = "hypr_rice" },
    .{ .id = 900_202, .guild = 1, .name = "dance", .animated = true },
    .{ .id = 900_203, .guild = 1, .name = "antigo", .available = false },
    .{ .id = 900_301, .guild = 2, .name = "comptime" },
};

/// A conversa com emoji, figurinha e reações personalizadas: #geral do primeiro servidor.
pub const emoji_channel: Id = 500_005;

const UserSeed = struct { id: Id, name: []const u8, role: u8, status: types.Status, activity: ?[]const u8 = null, activity_en: ?[]const u8 = null, avatar: bool = false, bot: bool = false, verified: bool = false };

const users = [_]UserSeed{
    .{ .id = 1000, .name = "rsha", .role = 0, .status = .online, .activity = "Programando em Zig", .activity_en = "Coding in Zig", .avatar = true },
    .{ .id = 1001, .name = "ana.exe", .role = 1, .status = .online, .activity = "Ouvindo Spotify", .activity_en = "Listening to Spotify", .avatar = true },
    .{ .id = 1002, .name = "brunão", .role = 2, .status = .dnd, .activity = "Jogando Hollow Knight", .activity_en = "Playing Hollow Knight", .avatar = true },
    .{ .id = 1003, .name = "kaique", .role = 3, .status = .online },
    .{ .id = 1004, .name = "lulu", .role = 4, .status = .idle, .activity = "Assistindo YouTube", .activity_en = "Watching YouTube", .avatar = true },
    .{ .id = 1005, .name = "duda", .role = 5, .status = .online, .activity = "No Hyprland 🌸", .activity_en = "On Hyprland 🌸", .avatar = true },
    .{ .id = 1006, .name = "thiaguinho", .role = 6, .status = .idle },
    .{ .id = 1007, .name = "mari", .role = 7, .status = .online, .activity = "Jogando Minecraft", .activity_en = "Playing Minecraft", .avatar = true },
    .{ .id = 1008, .name = "gustavo", .role = 2, .status = .offline },
    .{ .id = 1009, .name = "nanda", .role = 3, .status = .offline, .avatar = true },
    .{ .id = 1010, .name = "pedro", .role = 5, .status = .offline },
    .{ .id = 1011, .name = "joão vitor", .role = 1, .status = .offline },
    // Bots: um verificado (que também tem uma DM com a gente) e um comum.
    .{ .id = 1012, .name = "zigbot", .role = 4, .status = .online, .activity = "Usando /ajuda", .activity_en = "Using /help", .avatar = true, .bot = true, .verified = true },
    .{ .id = 1013, .name = "radinho", .role = 6, .status = .online, .activity = "Tocando na call", .activity_en = "Playing in the call", .bot = true },
};

/// A DM com o bot verificado (canal 900_011 conversa com users[12]).
pub const bot_dm: Id = 900_011;
pub const bot_user: Id = 1012;
pub const plain_bot_user: Id = 1013;
/// O autor de uma mensagem de webhook, como o gateway de verdade monta (ver
/// `authorId` em net/discord.zig).
pub const webhook_user: Id = types.webhook_id_bit | 0x77;

const GuildSeed = struct { name: []const u8, acronym: []const u8, color: u8, name_en: ?[]const u8 = null, acronym_en: ?[]const u8 = null, icon: bool = false };

/// Cargos de cada servidor da demonstração (cor 0 = sem cor).
const demo_roles = [_]struct { name: []const u8, name_en: []const u8, color: u32 }{
    .{ .name = "Fundação", .name_en = "Founders", .color = 0xF0B232 },
    .{ .name = "Moderação", .name_en = "Moderators", .color = 0x3BA55C },
    .{ .name = "Membros", .name_en = "Members", .color = 0 },
};

/// Amigos, pedidos e bloqueados da demonstração.
const relations = [_]struct { user: Id, kind: types.Relationship }{
    .{ .user = 1001, .kind = .friend },
    .{ .user = 1002, .kind = .friend },
    .{ .user = 1003, .kind = .friend },
    .{ .user = 1004, .kind = .friend },
    .{ .user = 1005, .kind = .friend },
    .{ .user = 1007, .kind = .friend },
    .{ .user = 1008, .kind = .friend },
    .{ .user = 1010, .kind = .friend },
    .{ .user = 1009, .kind = .incoming },
    .{ .user = 1006, .kind = .outgoing },
    .{ .user = 1011, .kind = .blocked },
};

/// Grupo da demonstração (canal 900_006): DM com três pessoas.
const group_members = [_]Id{ 1001, 1003, 1005 };
const group_id: Id = 900_006;

const guilds = [_]GuildSeed{
    .{ .name = "larperCord dev", .acronym = "LC", .color = 0 },
    .{ .name = "Rice do Hyprland", .acronym = "RH", .color = 4, .name_en = "Hyprland Rice", .acronym_en = "HR", .icon = true },
    .{ .name = "Zig Brasil", .acronym = "Z", .color = 1, .name_en = "Zig Brazil", .icon = true },
    .{ .name = "os larpers", .acronym = "ol", .color = 3, .name_en = "the larpers", .acronym_en = "tl" },
    .{ .name = "CTF da madrugada", .acronym = "CTF", .color = 6, .name_en = "Late-night CTF", .icon = true },
    .{ .name = "Faculdade 2026", .acronym = "F26", .color = 2, .name_en = "College 2026", .acronym_en = "C26" },
    .{ .name = "Minecraft SMP", .acronym = "MC", .color = 7, .icon = true },
    .{ .name = "Lo-fi & café", .acronym = "☕", .color = 5, .name_en = "Lo-fi & coffee" },
    .{ .name = "Arch Linux BR", .acronym = "A", .color = 4 },
    .{ .name = "Memes", .acronym = "😂", .color = 1 },
};

const ChannelSeed = struct { name: []const u8, kind: types.ChannelKind = .text, topic: []const u8 = "", name_en: ?[]const u8 = null, topic_en: ?[]const u8 = null };

/// O que o gateway falso sabe de uma thread para montar a conversa dela.
const DemoThread = struct {
    count: u32,
    /// Quantas pessoas estão nela (0 = a lista de membros cai na do pai).
    members: u8,
    /// A primeira mensagem: a que abriu a thread, ou o texto do post.
    first_author: Id = 0,
    first_text: []const u8 = "",
};

/// Fórum e canal de mídia entram na categoria "geral", depois do #música, com
/// IDs novos fora da faixa do `channel_tree`: nenhum canal antigo muda de ID.
pub fn forumId(guild_index: usize) Id {
    return channelId(guild_index, 30);
}
pub fn mediaId(guild_index: usize) Id {
    return channelId(guild_index, 31);
}
/// Threads e fóruns ficam em servidores próprios ("Faculdade 2026" e "Lo-fi &
/// café"): os dois primeiros seguem iguais, sem linhas a mais na lista.
pub const thread_guild = 5;
/// Aqui só vale o @everyone: as threads herdam a falta de permissão.
pub const locked_guild = 7;

fn isDemoForum(ch: Id) bool {
    return ch == forumId(thread_guild) or ch == mediaId(thread_guild) or ch == mediaId(locked_guild);
}

fn guildOfChannel(ch: Id) Id {
    return guildId(@intCast((ch - guildId(0)) / 1000));
}

const demo_tags = [_]struct { name: []const u8, en: []const u8, emoji: []const u8 = "" }{
    .{ .name = "Dúvida", .en = "Question", .emoji = "❓" },
    .{ .name = "Tema", .en = "Theme", .emoji = "🎨" },
    .{ .name = "Bug", .en = "Bug", .emoji = "🐛" },
    .{ .name = "Resolvido", .en = "Solved", .emoji = "✅" },
};

fn demoTags(forum: Id) [demo_tags.len]Id {
    var out: [demo_tags.len]Id = undefined;
    for (&out, 0..) |*t, i| t.* = forum * 10 + i;
    return out;
}

fn demoForumTags(forum: Id) ![]const types.ForumTag {
    const list = try alloc.alloc(types.ForumTag, demo_tags.len);
    const ids = demoTags(forum);
    for (demo_tags, 0..) |t, i| list[i] = .{ .id = ids[i], .name = try alloc.dupe(u8, pick(t.name, t.en)), .emoji = try alloc.dupe(u8, t.emoji) };
    return list;
}

const demo_posts = [_]struct { title: []const u8, title_en: []const u8, body: []const u8, body_en: []const u8 }{
    .{ .title = "Como trocar a fonte só das mensagens?", .title_en = "How do I change the font only for messages?", .body = "Queria usar uma fonte monoespaçada na conversa e deixar o resto como está. Dá para fazer pelo tema?", .body_en = "I'd like a monospaced font in the chat and leave the rest alone. Can a theme do that?" },
    .{ .title = "Tema escuro com fundo de estrelas", .title_en = "Dark theme with a starry background", .body = "Fiz um tema com o starfield e cores frias. Segue o arquivo, aceito sugestões de contraste.", .body_en = "Made a theme with the starfield and cold colors. File attached, contrast suggestions welcome." },
    .{ .title = "A barra lateral some ao redimensionar", .title_en = "The sidebar disappears when resizing", .body = "Em janelas muito estreitas a lista de canais desaparece e não volta. Alguém mais vê isso?", .body_en = "In very narrow windows the channel list vanishes and doesn't come back. Anyone else?" },
    .{ .title = "Plugin de lembretes em Lua", .title_en = "Reminder plugin in Lua", .body = "Escrevi um /lembrar que manda uma mensagem depois de um tempo. Está no meu repositório.", .body_en = "Wrote a /remind that sends a message after a while. It's in my repo." },
    .{ .title = "Qual o menor uso de memória que vocês já viram?", .title_en = "What's the lowest memory usage you've seen?", .body = "Aqui fica em 41 MB parado. Curioso para saber o de vocês, com qual driver e quantos servidores.", .body_en = "Mine idles at 41 MB. Curious about yours, with which driver and how many servers." },
    .{ .title = "Atalho para responder à última mensagem", .title_en = "Shortcut to reply to the last message", .body = "Existe? Procurei nas configurações e só achei o de editar.", .body_en = "Is there one? I looked in the settings and only found the edit one." },
    .{ .title = "Guia: montando um tema do zero", .title_en = "Guide: building a theme from scratch", .body = "Passo a passo do layout em KDL até as cores, com os erros mais comuns no caminho.", .body_en = "Step by step from the KDL layout to the colors, with the usual mistakes along the way." },
    .{ .title = "Voz cortando no Wayland", .title_en = "Voice cutting out on Wayland", .body = "O microfone corta a cada poucos segundos no Hyprland. No X11 não acontece.", .body_en = "The mic cuts out every few seconds on Hyprland. It doesn't happen on X11." },
};

const channel_tree = [_]ChannelSeed{
    .{ .name = "informações", .kind = .category, .name_en = "info" },
    .{ .name = "regras", .topic = "leia antes de postar", .name_en = "rules", .topic_en = "read before posting" },
    .{ .name = "anúncios", .topic = "novidades do servidor", .name_en = "announcements", .topic_en = "server news" },
    .{ .name = "geral", .kind = .category, .name_en = "general" },
    .{ .name = "geral", .topic = "papo livre, sem spam 🙏", .name_en = "general", .topic_en = "free talk, no spam 🙏" },
    .{ .name = "memes", .topic = "só o suprassumo", .topic_en = "only the finest" },
    .{ .name = "setups", .topic = "mostra o rice", .topic_en = "show off your rice" },
    .{ .name = "música", .topic = "o que vocês estão ouvindo?", .name_en = "music", .topic_en = "what are you all listening to?" },
    .{ .name = "projetos", .kind = .category, .name_en = "projects" },
    .{ .name = "zig", .topic = "allocators, comptime e sofrimento", .topic_en = "allocators, comptime and suffering" },
    .{ .name = "interface", .topic = "design do larperCord", .topic_en = "larperCord's design" },
    .{ .name = "bugs", .topic = "reporte com print", .topic_en = "report with a screenshot" },
    .{ .name = "voz", .kind = .category, .name_en = "voice" },
    .{ .name = "Call da madrugada", .kind = .voice, .name_en = "Late-night call" },
    .{ .name = "Jogando", .kind = .voice, .name_en = "Gaming" },
    .{ .name = "AFK", .kind = .voice },
};

const reaction_pool = [_][]const u8{ "😂", "👍", "❤️", "🔥", "💀", "😭", "🎉", "👀" };

/// DMs: canal 900_000 + i conversa com users[i + 1].
pub fn dmId(i: usize) Id {
    return 900_000 + @as(Id, i);
}

pub fn dmRecipient(ch: Id) ?Id {
    if (ch < 900_000 or ch >= 900_000 + 6) return null;
    return users[@intCast(ch - 900_000 + 1)].id;
}

pub fn guildId(i: usize) Id {
    return 500_000 + @as(Id, i) * 1000;
}

pub fn channelId(guild_index: usize, i: usize) Id {
    return guildId(guild_index) + 1 + @as(Id, i);
}

/// No segundo servidor (e no das threads sem permissão), o #bugs só a
/// moderação vê e no AFK ninguém entra.
fn demoOverwrites(gi: usize, ci: usize) ![]const types.Overwrite {
    if (gi != 1 and gi != locked_guild) return &.{};
    const deny: u64 = switch (ci) {
        11 => types.perm.view_channel,
        15 => types.perm.connect,
        else => return &.{},
    };
    return demoDeny(gi, deny);
}

fn demoDeny(gi: usize, deny: u64) ![]const types.Overwrite {
    const o = try alloc.alloc(types.Overwrite, 1);
    o[0] = .{ .id = guildId(gi), .deny = deny };
    return o;
}

/// Pastas da demonstração: soltos, "Programação" e "Jogos".
fn demoFolders() ![]types.GuildFolder {
    const spec = [_]struct { id: u64, name: []const u8, name_en: []const u8, color: u32, guilds: []const usize }{
        .{ .id = 0, .name = "", .name_en = "", .color = 0, .guilds = &.{0} },
        .{ .id = 0, .name = "", .name_en = "", .color = 0, .guilds = &.{1} },
        .{ .id = 77, .name = "Programação", .name_en = "Programming", .color = 0x3BA55C, .guilds = &.{ 2, 8, 4 } },
        .{ .id = 0, .name = "", .name_en = "", .color = 0, .guilds = &.{5} },
        .{ .id = 78, .name = "Jogos", .name_en = "Games", .color = 0xF0B232, .guilds = &.{ 6, 3 } },
        .{ .id = 0, .name = "", .name_en = "", .color = 0, .guilds = &.{7} },
        .{ .id = 0, .name = "", .name_en = "", .color = 0, .guilds = &.{9} },
    };
    const out = try alloc.alloc(types.GuildFolder, spec.len);
    for (spec, 0..) |f, i| {
        const ids = try alloc.alloc(Id, f.guilds.len);
        for (f.guilds, 0..) |gi, k| ids[k] = guildId(gi);
        out[i] = .{ .id = f.id, .name = try alloc.dupe(u8, pick(f.name, f.name_en)), .color = f.color, .guilds = ids };
    }
    return out;
}

fn buildReady() !ev.Ready {
    const us = try alloc.alloc(types.User, users.len + 1);
    for (users, 0..) |u, i| us[i] = .{
        .id = u.id,
        .name = try alloc.dupe(u8, u.name),
        .role = u.role,
        .status = u.status,
        .activity = if (u.activity) |a| try alloc.dupe(u8, pick(a, u.activity_en)) else null,
        .avatar = if (u.avatar) try std.fmt.allocPrint(alloc, "demo:av:{d}", .{u.id}) else null,
        .bot = u.bot,
        .verified_bot = u.verified,
    };
    us[users.len] = .{ .id = webhook_user, .name = try alloc.dupe(u8, "Deploy"), .role = 3, .avatar = try alloc.dupe(u8, "demo:icon:5"), .bot = true, .webhook = true };
    const gs = try alloc.alloc(types.Guild, guilds.len);
    for (guilds, 0..) |g, i| gs[i] = .{
        .id = guildId(i),
        .name = try alloc.dupe(u8, pick(g.name, g.name_en)),
        .acronym = try alloc.dupe(u8, pick(g.acronym, g.acronym_en)),
        .color = g.color,
        .icon = if (g.icon) try std.fmt.allocPrint(alloc, "demo:icon:{d}", .{i}) else null,
        // O segundo servidor mostra o banner (o primeiro, o cabeçalho sem imagem).
        .banner = if (i == 1) try alloc.dupe(u8, "demo:2") else null,
        .can_banner = i < 2,
        // O primeiro servidor é nosso (dá para mexer em cargos e mensagens).
        .owner = if (i == 0) me_id else 1001,
    };
    const chs = try alloc.alloc(types.Channel, guilds.len * channel_tree.len + 8 + 3);
    var n: usize = 0;
    for (0..guilds.len) |gi| {
        var parent: ?Id = null;
        for (channel_tree, 0..) |ch, ci| {
            const id = channelId(gi, ci);
            if (ch.kind == .category) parent = id;
            chs[n] = .{
                .id = id,
                .guild = guildId(gi),
                .parent = if (ch.kind == .category) null else parent,
                .kind = ch.kind,
                .name = try alloc.dupe(u8, pick(ch.name, ch.name_en)),
                .topic = try alloc.dupe(u8, pick(ch.topic, ch.topic_en)),
                .position = @intCast(ci),
                .overwrites = try demoOverwrites(gi, ci),
            };
            n += 1;
            // Depois do #música: um fórum e um canal de mídia.
            if (ci == 7 and (gi == thread_guild or gi == locked_guild)) for ([_]Id{ forumId(gi), mediaId(gi) }) |fid| {
                // No servidor sem permissões, só o canal de mídia.
                if (gi == locked_guild and fid == forumId(gi)) continue;
                const media = fid == mediaId(gi);
                chs[n] = .{
                    .id = fid,
                    .guild = guildId(gi),
                    .parent = parent,
                    .kind = .forum,
                    .media = media,
                    .name = try alloc.dupe(u8, if (media) pick("capturas", "screenshots") else pick("ajuda", "help")),
                    .topic = try alloc.dupe(u8, if (media) pick("mostre o seu tema", "show off your theme") else pick("um post por dúvida, com o que você já tentou", "one post per question, with what you've tried")),
                    .position = @intCast(ci),
                    .tags = try demoForumTags(fid),
                    // No canal de mídia de lá ninguém posta.
                    .overwrites = if (gi == locked_guild) try demoDeny(gi, types.perm.send_messages) else &.{},
                };
                n += 1;
            };
        }
    }
    for (0..6) |i| {
        chs[n] = .{
            .id = dmId(i),
            .guild = 0,
            .name = try alloc.dupe(u8, users[i + 1].name),
            .topic = try alloc.dupe(u8, ""),
            .position = @intCast(i),
            .recipient = users[i + 1].id,
        };
        n += 1;
        // O grupo entra em terceiro na lista de DMs.
        if (i == 1) {
            chs[n] = .{
                .id = group_id,
                .guild = 0,
                .name = try alloc.dupe(u8, pick("rolê de sexta", "friday hangout")),
                .topic = try alloc.dupe(u8, ""),
                .position = 2,
                .recipient = group_members[0],
                .recipients = try alloc.dupe(Id, &group_members),
                .group = true,
            };
            n += 1;
        }
    }
    chs[n] = .{
        .id = bot_dm,
        .guild = 0,
        .name = try alloc.dupe(u8, "zigbot"),
        .topic = try alloc.dupe(u8, ""),
        .position = 7,
        .recipient = bot_user,
    };
    n += 1;
    const voice = try alloc.alloc([2]Id, 4 * guilds.len);
    var vn: usize = 0;
    for (0..guilds.len) |gi| {
        const call = channelId(gi, 13);
        for ([_]Id{ 1001, 1005, 1003 }) |u| {
            voice[vn] = .{ call, u };
            vn += 1;
        }
        voice[vn] = .{ channelId(gi, 14), 1002 };
        vn += 1;
    }
    return .{ .me = me_id, .users = us, .guilds = gs, .channels = chs, .voice = voice, .username = try alloc.dupe(u8, "rsha") };
}

/// Quantas não lidas cada canal tem ao abrir a demonstração (0 = nenhuma).
fn demoUnread(channel: Id) usize {
    return switch (channel) {
        channelId(0, 2) => 2,
        channelId(0, 4) => 3,
        channelId(0, 5) => 4,
        channelId(0, 9) => 2,
        // Mais do que cabe na tela: abre na primeira não lida.
        channelId(0, 10) => 60,
        channelId(1, 4) => 5,
        channelId(3, 4) => 6,
        channelId(5, 4) => 40,
        channelId(9, 4) => 2,
        dmId(1) => 2,
        dmId(3) => 1,
        group_id => 3,
        else => 0,
    };
}

/// `read_state` da demonstração: o mesmo formato do READY de verdade. O
/// histórico é sempre o mesmo dentro da sessão, então dá para apontar para uma
/// mensagem dele e contar as menções de verdade.
fn demoReadStates(epoch_ms: i64) ![]types.ReadEntry {
    const list = [_]Id{ channelId(0, 2), channelId(0, 4), channelId(0, 5), channelId(0, 9), channelId(0, 10), channelId(1, 4), channelId(3, 4), channelId(5, 4), channelId(9, 4), dmId(1), dmId(3), group_id };
    const out = try alloc.alloc(types.ReadEntry, list.len);
    for (list, 0..) |ch, i| {
        const msgs = try buildHistory(ch, epoch_ms);
        defer freeMessages(msgs);
        const k = demoUnread(ch);
        var mentions: u16 = 0;
        for (msgs[msgs.len - k..]) |m| {
            const dm = ch >= 900_000;
            if (dm or std.mem.indexOf(u8, m.content, "<@1000>") != null or std.mem.indexOf(u8, m.content, "@everyone") != null) mentions += 1;
        }
        out[i] = .{ .channel = ch, .last_read = msgs[msgs.len - k - 1].id, .mentions = mentions, .last_message = msgs[msgs.len - 1].id };
    }
    return out;
}

/// Cartão de convite da demonstração (sem conta, sem entrar em nada).
fn demoInvite(code: []const u8) !types.Invite {
    if (std.mem.eql(u8, code, "larper")) return .{ .state = .ok, .guild = guildId(0), .name = try alloc.dupe(u8, pick(guilds[0].name, guilds[0].name_en)), .members = 12, .online = 7 };
    if (std.mem.eql(u8, code, "zigbr")) return .{ .state = .ok, .guild = 777_000, .name = try alloc.dupe(u8, "Zig Brasil (oficial)"), .icon = try alloc.dupe(u8, "demo:icon:2"), .banner = try alloc.dupe(u8, "demo:2"), .members = 4312, .online = 389 };
    return .{ .state = .invalid };
}

fn freeOne(m: types.Message) void {
    alloc.free(m.content);
    types.freeAttachments(alloc, m.attachments);
    types.freeEmbeds(alloc, m.embeds);
}

/// Copia a fatia `lo..hi` e libera o resto.
fn keepRange(msgs: []types.Message, lo: usize, hi: usize) ![]types.Message {
    const out = try alloc.alloc(types.Message, hi - lo);
    @memcpy(out, msgs[lo..hi]);
    for (msgs[0..lo]) |m| freeOne(m);
    for (msgs[hi..]) |m| freeOne(m);
    alloc.free(msgs);
    return out;
}

/// As mensagens fixadas que ficam dentro do histórico (contando do fim).
const pinned_backs = [_]usize{ 120, 40 };

/// A fixada antiga: 40 dias antes do começo da sessão, longe do que carrega.
pub fn oldPinId(channel: Id, epoch_ms: i64) Id {
    return types.makeSnowflake(epoch_ms - 40 * 86_400_000, demoSeq(channel, 1000));
}

/// Uma mensagem fora do histórico, sempre a mesma para o mesmo ID.
fn syntheticAt(channel: Id, id: Id, epoch_ms: i64) !types.Message {
    var prng = std.Random.DefaultPrng.init(channel ^ id);
    const r = prng.random();
    const text = if (id == oldPinId(channel, epoch_ms)) pick("regra de ouro: sem spam e sem pedir cargo 🙏", "golden rule: no spam and no asking for roles 🙏") else phrase(r.uintLessThan(usize, phrases.len));
    return .{
        .id = id,
        .channel = channel,
        .author = if (dmRecipient(channel)) |u| u else users[1 + r.uintLessThan(usize, 7)].id,
        .timestamp = @divTrunc(types.snowflakeTime(id), 1000),
        .content = try alloc.dupe(u8, text),
    };
}

/// GET messages?around=: 25 de cada lado da mensagem. Dentro do histórico,
/// o próprio; antes dele, uma conversa inventada (sempre a mesma).
fn buildAround(channel: Id, id: Id, epoch_ms: i64) ![]types.Message {
    const latest = try buildHistory(channel, epoch_ms);
    if (id >= latest[0].id) {
        var at: usize = 0;
        for (latest, 0..) |m, i| if (m.id <= id) {
            at = i;
        };
        return keepRange(latest, at -| 25, @min(at + 25, latest.len));
    }
    defer freeMessages(latest);
    const oldest_s = @divTrunc(types.snowflakeTime(latest[0].id), 1000);
    const t0 = @divTrunc(types.snowflakeTime(id), 1000);
    var out: std.ArrayList(types.Message) = .empty;
    for (0..50) |i| {
        const off = (@as(i64, @intCast(i)) - 25) * 90;
        if (t0 + off >= oldest_s) break;
        const mid = if (i == 25) id else types.makeSnowflake((t0 + off) * 1000, demoSeq(channel, i));
        try out.append(alloc, try syntheticAt(channel, mid, epoch_ms));
    }
    return out.toOwnedSlice(alloc);
}

/// GET messages?after=: voltando para o presente, até encostar no histórico.
fn buildNewer(channel: Id, after: Id, epoch_ms: i64) !struct { msgs: []types.Message, more: bool } {
    const latest = try buildHistory(channel, epoch_ms);
    if (after >= latest[0].id) {
        var from = latest.len;
        for (latest, 0..) |m, i| if (m.id > after) {
            from = i;
            break;
        };
        const end = @min(from + 50, latest.len);
        const more = end < latest.len;
        return .{ .msgs = try keepRange(latest, from, end), .more = more };
    }
    const oldest_s = @divTrunc(types.snowflakeTime(latest[0].id), 1000);
    const t0 = @divTrunc(types.snowflakeTime(after), 1000);
    var out: std.ArrayList(types.Message) = .empty;
    // Uma mensagem por hora: de um mês para cá, em algumas páginas.
    for (1..51) |i| {
        const t = t0 + @as(i64, @intCast(i)) * 3600;
        if (t >= oldest_s) break;
        try out.append(alloc, try syntheticAt(channel, types.makeSnowflake(t * 1000, demoSeq(channel, i)), epoch_ms));
    }
    // Encostou: daqui em diante é o histórico.
    if (out.items.len == 0) {
        out.deinit(alloc);
        return .{ .msgs = try keepRange(latest, 0, 50), .more = true };
    }
    freeMessages(latest);
    return .{ .msgs = try out.toOwnedSlice(alloc), .more = true };
}

/// Menções recentes da demonstração (o que o GET /users/@me/mentions
/// devolveria): de horas a dias atrás, em vários servidores e no grupo.
fn demoMentions(now_ms: i64) ![]types.Message {
    const spec = [_]struct { ch: Id, author: Id, hours: i64, pt: []const u8, en: []const u8 }{
        .{ .ch = channelId(3, 4), .author = 1001, .hours = 2, .pt = "<@1000> bora jogar hoje à noite?", .en = "<@1000> gaming tonight?" },
        .{ .ch = channelId(3, 5), .author = 1002, .hours = 5, .pt = "<@1000> olha isso kkkkkk", .en = "<@1000> look at this lmao" },
        .{ .ch = group_id, .author = 1003, .hours = 9, .pt = "<@1000> sexta tá de pé?", .en = "<@1000> still on for friday?" },
        .{ .ch = channelId(5, 4), .author = 1007, .hours = 26, .pt = "<@1000> tu fez o trabalho de cálculo? manda a **questão 3**", .en = "<@1000> did you do the calculus homework? send **question 3**" },
        .{ .ch = channelId(0, 9), .author = 1003, .hours = 49, .pt = "<@1000> o allocator tava vazando mesmo, valeu 🙏", .en = "<@1000> the allocator really was leaking, thanks 🙏" },
        .{ .ch = channelId(2, 4), .author = 1005, .hours = 73, .pt = "@everyone live de zig hoje às 20h", .en = "@everyone zig stream today at 8pm" },
        .{ .ch = channelId(0, 4), .author = 1004, .hours = 120, .pt = "<@1000> e o tema novo, sai quando?", .en = "<@1000> so when's the new theme coming out?" },
    };
    const out = try alloc.alloc(types.Message, spec.len);
    for (spec, 0..) |m, i| {
        const t = now_ms - m.hours * 3_600_000;
        out[i] = .{
            .id = types.makeSnowflake(t, 0x3f0000 + i),
            .channel = m.ch,
            .author = m.author,
            .timestamp = @divTrunc(t, 1000),
            .content = try alloc.dupe(u8, pick(m.pt, m.en)),
        };
    }
    return out;
}

/// Parte baixa do ID: o canal entra junto, senão a mensagem N de canais
/// diferentes teria o mesmo ID (o horário de partida é o mesmo).
fn demoSeq(channel: Id, i: usize) u64 {
    return ((channel % 4096) << 10) | (i & 0x3ff);
}

/// 50 mensagens antes de `before` (rolou para cima na demonstração).
fn buildOlder(channel: Id, before: Id) ![]types.Message {
    var prng = std.Random.DefaultPrng.init(channel ^ before);
    const r = prng.random();
    const n: usize = 50;
    const msgs = try alloc.alloc(types.Message, n);
    var t: i64 = @divTrunc(types.snowflakeTime(before), 1000) - 300;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const author = if (dmRecipient(channel)) |u| (if (r.boolean()) u else me_id) else users[r.uintLessThan(usize, 8)].id;
        msgs[i] = .{
            .id = types.makeSnowflake(t * 1000, demoSeq(channel, i)),
            .channel = channel,
            .author = author,
            .timestamp = t,
            .content = try alloc.dupe(u8, phrase(r.uintLessThan(usize, phrases.len))),
        };
        t -= if (r.uintLessThan(u8, 6) == 0) r.intRangeLessThan(i64, 3600, 40000) else r.intRangeLessThan(i64, 20, 600);
    }
    return msgs;
}

/// Devolve uma lista de mensagens que ninguém assumiu.
fn freeMessages(msgs: []types.Message) void {
    for (msgs) |m| {
        alloc.free(m.content);
        types.freeAttachments(alloc, m.attachments);
        types.freeEmbeds(alloc, m.embeds);
    }
    alloc.free(msgs);
}

/// A conversa de uma thread: a mensagem que a abriu (ou o texto do post, com
/// o ID da própria thread) e respostas de lá até agora.
fn buildThreadHistory(id: Id, t: DemoThread, now_ms: i64) ![]types.Message {
    var prng = std.Random.DefaultPrng.init(id *% 0x9E3779B97F4A7C15);
    const r = prng.random();
    const has_first = t.first_text.len > 0;
    const n: usize = t.count + @intFromBool(has_first);
    const msgs = try alloc.alloc(types.Message, n);
    const start = @divTrunc(types.snowflakeTime(id), 1000);
    const now_s = @divTrunc(now_ms, 1000);
    const step: i64 = @max(@divTrunc(now_s - start, @as(i64, @intCast(n + 1))), 1);
    for (msgs, 0..) |*m, i| {
        const ts = start + step * @as(i64, @intCast(i));
        const first = has_first and i == 0;
        m.* = .{
            .id = if (first) id else types.makeSnowflake((ts + 1) * 1000, demoSeq(id, i)),
            .channel = id,
            .author = if (first) t.first_author else users[r.uintLessThan(usize, 8)].id,
            .timestamp = ts,
            .content = try alloc.dupe(u8, if (first) t.first_text else phrase(r.uintLessThan(usize, phrases.len))),
        };
    }
    return msgs;
}

fn buildHistory(channel: Id, now_ms: i64) ![]types.Message {
    var prng = std.Random.DefaultPrng.init(channel *% 0x9E3779B97F4A7C15);
    const r = prng.random();
    const n: usize = 300;
    const msgs = try alloc.alloc(types.Message, n);
    // Gera de trás para frente a partir de "agora".
    var t: i64 = @divTrunc(now_ms, 1000) - 60 * 3;
    var author: Id = users[1].id;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        if (i == n - 1 or r.uintLessThan(u8, 3) != 0) author = if (dmRecipient(channel)) |u| (if (r.boolean()) u else me_id) else if (channel == group_id) (if (r.uintLessThan(u8, 4) == 0) me_id else group_members[r.uintLessThan(usize, group_members.len)]) else users[r.uintLessThan(usize, 8)].id;
        msgs[i] = .{
            .id = types.makeSnowflake(t * 1000, demoSeq(channel, i)),
            .channel = channel,
            .author = author,
            .timestamp = t,
            .content = try alloc.dupe(u8, phrase(r.uintLessThan(usize, phrases.len))),
            .edited = r.uintLessThan(u8, 25) == 0,
        };
        const gap: i64 = if (r.uintLessThan(u8, 10) == 0) r.intRangeLessThan(i64, 1800, 14000) else r.intRangeLessThan(i64, 5, 240);
        t -= gap;
    }
    // Algumas respostas a mensagens um pouco anteriores.
    for (msgs, 0..) |*m, j| {
        if (j > 3 and r.uintLessThan(u8, 9) == 0) m.reply_to = msgs[j - 1 - r.uintLessThan(usize, 3)].id;
    }
    // #anúncios do primeiro servidor termina com uma menção a nós, de outra
    // pessoa: a caixa de entrada da demonstração tem uma menção não lida.
    if (channel == channelId(0, 2)) {
        alloc.free(msgs[n - 2].content);
        msgs[n - 2].content = try alloc.dupe(u8, pick("<@1000> dá uma olhada no anúncio novo quando puder 🙏", "<@1000> take a look at the new announcement when you can 🙏"));
        msgs[n - 2].author = 1001;
        msgs[n - 2].reply_to = 0;
        msgs[n - 1].author = 1002;
    }
    // Quem ainda não foi lido não é nosso (falar é ter lido).
    const unread_k = demoUnread(channel);
    for (msgs[n - unread_k..]) |*m| if (m.author == me_id) {
        m.author = dmRecipient(channel) orelse if (channel == group_id) group_members[0] else 1001;
    };
    // Duas fixadas dentro do histórico (a antiga fica fora: seedPins).
    for (pinned_backs) |back| msgs[n - back].pinned = true;
    if (channel == emoji_channel) try demoEmojiMessages(msgs);
    // Imagens (geradas na hora pelo carregador: "demo:N") e um arquivo.
    const pics = [_]struct { back: usize, text: []const u8, url: []const u8, name: []const u8, w: u16, h: u16, text_en: ?[]const u8 = null, name_en: ?[]const u8 = null }{
        .{ .back = 5, .text = "olha o pôr do sol daqui de casa 🌅", .url = "demo:1", .name = "por-do-sol.png", .w = 900, .h = 560, .text_en = "check out the sunset from my place 🌅", .name_en = "sunset.png" },
        .{ .back = 14, .text = "wallpaper novo, que acharam?", .url = "demo:2", .name = "synthwave.png", .w = 720, .h = 720, .text_en = "new wallpaper, thoughts?" },
        .{ .back = 23, .text = "", .url = "demo:3", .name = "aurora.png", .w = 960, .h = 540 },
        .{ .back = 31, .text = "o relatório que eu falei", .url = "demo:file", .name = "relatorio-de-ram.pdf", .w = 0, .h = 0, .text_en = "the report i mentioned", .name_en = "ram-report.pdf" },
        // Um GIF de link (como os do Tenor): animado e marcado como embed.
        .{ .back = 9, .text = "https://tenor.com/view/larper-loading", .url = "demo:gif", .name = "loading.gif", .w = 480, .h = 270 },
    };
    for (pics) |p| {
        const m = &msgs[n - p.back];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, pick(p.text, p.text_en));
        m.reply_to = 0;
        const list = try alloc.alloc(types.Attachment, 1);
        const gif = std.mem.eql(u8, p.url, "demo:gif");
        list[0] = .{ .url = try alloc.dupe(u8, p.url), .filename = try alloc.dupe(u8, pick(p.name, p.name_en)), .width = p.w, .height = p.h, .size = if (p.w == 0) 482_133 else 0, .animated = gif, .embed = gif };
        m.attachments = list;
    }
    // Um vídeo anexado (toca aqui com o FFmpeg do sistema; a prévia é um
    // quadro qualquer) e um GIF que só existe em MP4, como os antigos do
    // Tenor (anima pelo FFmpeg; sem ele, fica a prévia parada).
    {
        const m = &msgs[n - 12];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, pick("gravei a tela rapidinho", "quick screen recording"));
        m.reply_to = 0;
        const list = try alloc.alloc(types.Attachment, 1);
        list[0] = .{ .url = try alloc.dupe(u8, "demo:3"), .filename = try alloc.dupe(u8, "gravacao.mp4"), .width = 426, .height = 240, .size = 48_435, .video = true, .link = try alloc.dupe(u8, "demo:video") };
        m.attachments = list;
    }
    {
        const m = &msgs[n - 20];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, "https://tenor.com/view/larper-antigo");
        m.reply_to = 0;
        const list = try alloc.alloc(types.Attachment, 1);
        list[0] = .{ .url = try alloc.dupe(u8, "demo:mp4"), .filename = try alloc.dupe(u8, "antigo.gif"), .width = 426, .height = 240, .animated = true, .still = try alloc.dupe(u8, "demo:2"), .embed = true };
        m.attachments = list;
    }
    // Embeds: prévia de link, cartão de bot com campos e um vídeo.
    {
        const m = &msgs[n - 3];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, "https://ziglang.org");
        m.reply_to = 0;
        const e = try alloc.alloc(types.Embed, 1);
        e[0] = .{
            .provider = try alloc.dupe(u8, "ziglang.org"),
            .title = try alloc.dupe(u8, "Zig Programming Language"),
            .url = try alloc.dupe(u8, "https://ziglang.org"),
            .description = try alloc.dupe(u8, pick("Zig é uma linguagem de uso geral para software **robusto**, **ótimo** e **reutilizável**.", "Zig is a general-purpose language for **robust**, **optimal** and **reusable** software.")),
            .color = 0xF7A41D,
            .has_color = true,
            .thumb = try alloc.dupe(u8, "demo:icon:2"),
        };
        m.embeds = e;
    }
    {
        const m = &msgs[n - 18];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, "");
        m.reply_to = 0;
        const fields = try alloc.alloc(types.EmbedField, 2);
        fields[0] = .{ .name = try alloc.dupe(u8, pick("Membros", "Members")), .value = try alloc.dupe(u8, "**12** (7 online)") };
        fields[1] = .{ .name = try alloc.dupe(u8, pick("Ping", "Ping")), .value = try alloc.dupe(u8, "`42 ms`") };
        const e = try alloc.alloc(types.Embed, 1);
        e[0] = .{
            .author = try alloc.dupe(u8, "larperBot"),
            .title = try alloc.dupe(u8, pick("Status do servidor", "Server status")),
            .description = try alloc.dupe(u8, pick("Tudo funcionando. Use `/ajuda` para ver os comandos.", "All systems go. Use `/help` to see the commands.")),
            .fields = fields,
            .footer = try alloc.dupe(u8, pick("atualizado agora", "updated just now")),
            .color = 0x5865F2,
            .has_color = true,
        };
        m.embeds = e;
    }
    {
        const m = &msgs[n - 27];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, pick("esse vídeo explica tudo", "this video explains everything"));
        m.reply_to = 0;
        const e = try alloc.alloc(types.Embed, 1);
        e[0] = .{
            .provider = try alloc.dupe(u8, "YouTube"),
            .author = try alloc.dupe(u8, "Zig SHOWTIME"),
            .title = try alloc.dupe(u8, pick("Comptime sem medo", "Comptime without fear")),
            .url = try alloc.dupe(u8, "https://www.youtube.com/"),
            .image = try alloc.dupe(u8, "demo:3"),
            .image_w = 960,
            .image_h = 540,
            .video = true,
            .color = 0xFF0000,
            .has_color = true,
        };
        m.embeds = e;
    }
    // Quem escreve como bot: um aviso do bot verificado e um webhook, nos canais.
    if (dmRecipient(channel) == null and channel != group_id and channel != emoji_channel) {
        const bot = &msgs[n - 4];
        alloc.free(bot.content);
        bot.content = try alloc.dupe(u8, pick("✅ build #412 passou em 38 s", "✅ build #412 passed in 38 s"));
        bot.author = bot_user;
        bot.reply_to = 0;
        const hook = &msgs[n - 10];
        alloc.free(hook.content);
        hook.content = try alloc.dupe(u8, pick("🚀 versão nova no ar", "🚀 new version is live"));
        hook.author = webhook_user;
        hook.reply_to = 0;
    }
    // Mensagens de bot só com componentes (Components V2).
    {
        const m = &msgs[n - 22];
        if (dmRecipient(channel) == null and channel != group_id) m.author = plain_bot_user;
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, "");
        m.reply_to = 0;
        const thumb = try alloc.alloc(types.EmbedMedia, 1);
        thumb[0] = .{ .url = try alloc.dupe(u8, "demo:icon:2"), .w = 640, .h = 640 };
        const gallery_items = try alloc.alloc(types.EmbedMedia, 2);
        gallery_items[0] = .{ .url = try alloc.dupe(u8, "demo:1"), .w = 900, .h = 560 };
        gallery_items[1] = .{ .url = try alloc.dupe(u8, "demo:3"), .w = 960, .h = 540 };
        const btn = try alloc.alloc(types.EmbedMedia, 1);
        btn[0] = .{ .link = try alloc.dupe(u8, "https://ziglang.org"), .label = try alloc.dupe(u8, pick("Abrir", "Open")) };
        const blocks = try alloc.alloc(types.EmbedBlock, 5);
        blocks[0] = .{ .text = try alloc.dupe(u8, pick("### Na fila, posição 1\n[Comptime sem medo](https://ziglang.org) por [Zig SHOWTIME](https://ziglang.org) [03:48]", "### Queued at position 1\n[Comptime without fear](https://ziglang.org) by [Zig SHOWTIME](https://ziglang.org) [03:48]")), .media = thumb };
        blocks[1] = .{ .kind = .separator, .divider = true };
        blocks[2] = .{ .text = try alloc.dupe(u8, pick("-# Música errada? Use `/buscar`", "-# Wrong track? Use `/search`")) };
        blocks[3] = .{ .kind = .gallery, .media = gallery_items };
        blocks[4] = .{ .kind = .buttons, .media = btn };
        const e = try alloc.alloc(types.Embed, 1);
        e[0] = .{ .color = 0xFFA500, .has_color = true, .blocks = blocks };
        m.embeds = e;
    }
    // #interface: links do Discord, convites e menções clicáveis.
    if (channel == channelId(0, 10)) {
        const set = struct {
            fn f(m: *types.Message, text: []const u8) !void {
                alloc.free(m.content);
                m.content = text;
                m.reply_to = 0;
            }
        }.f;
        try set(&msgs[n - 1], try i18n.allocPrint(alloc, "entra lá: https://discord.gg/larper", "join us: https://discord.gg/larper", .{}));
        try set(&msgs[n - 2], try i18n.allocPrint(alloc, "o pessoal do zig também: https://discord.gg/zigbr", "the zig folks too: https://discord.gg/zigbr", .{}));
        try set(&msgs[n - 4], try i18n.allocPrint(alloc, "a regra fixada é esta: https://discord.com/channels/{d}/{d}/{d}", "the pinned rule is this one: https://discord.com/channels/{d}/{d}/{d}", .{ guildId(0), channel, oldPinId(channel, now_ms) }));
        try set(&msgs[n - 6], try i18n.allocPrint(alloc, "vejam <#{d}> e falem com <@1001>; o outro canal: https://ptb.discord.com/channels/{d}/{d}", "check <#{d}> and talk to <@1001>; the other channel: https://ptb.discord.com/channels/{d}/{d}", .{ channelId(0, 4), guildId(0), channelId(0, 5) }));
    }
    return msgs;
}

/// Emoji personalizado no meio do texto, mensagens só de emoji (grandes) e
/// figurinhas. Passa pelo mesmo caminho do gateway de verdade.
fn demoEmojiMessages(msgs: []types.Message) !void {
    const n = msgs.len;
    const texts = [_]struct { back: usize, raw: []const u8, raw_en: []const u8 }{
        .{ .back = 2, .raw = "ficou muito bom <:larper:900101> o tema novo <:pepe_ok:900102>", .raw_en = "the new theme looks so good <:larper:900101> <:pepe_ok:900102>" },
        .{ .back = 4, .raw = "<:ziguana:900103> <a:festa:900104>", .raw_en = "<:ziguana:900103> <a:festa:900104>" },
        .{ .back = 6, .raw = "🔥🔥😂", .raw_en = "🔥🔥😂" },
    };
    for (texts) |t| {
        const m = &msgs[n - t.back];
        alloc.free(m.content);
        const raw = pick(t.raw, t.raw_en);
        m.content = try jsonx.simplifyContent(alloc, raw);
        m.raw = if (m.content.len != raw.len) try alloc.dupe(u8, raw) else "";
        m.reply_to = 0;
    }
    // Figurinhas: uma imagem e uma animada; a de Lottie só tem o nome.
    {
        const m = &msgs[n - 7];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, "");
        m.reply_to = 0;
        const list = try alloc.alloc(types.Attachment, 1);
        list[0] = .{ .url = try alloc.dupe(u8, "demo:sticker:900401:1"), .filename = try alloc.dupe(u8, pick("bom dia", "good morning")), .width = 160, .height = 160 };
        m.attachments = list;
    }
    {
        const m = &msgs[n - 8];
        alloc.free(m.content);
        m.content = try i18n.allocPrint(alloc, "[figurinha: {s}]", "[sticker: {s}]", .{"wumpus"});
        m.reply_to = 0;
    }
}

const phrases = [_][]const u8{
    "bom dia rapaziada ☀️",
    "alguém vai jogar hoje à noite?",
    "kkkkkkkkkkkkk",
    "olha o `ps aux` do vesktop: **1.28 GB** de RAM pra mandar mensagem 💀",
    "<@1000> viu isso aqui?",
    "acabei de atualizar pro zig 0.17 e quebrou tudo de novo 🙃",
    "mano o hyprland novo tá *muito* liso",
    "**finalmente** consegui compilar",
    "alguém tem um wallpaper bom aí? to cansado do meu",
    "isso é muito larper kkkk",
    "vou dormir, amanhã cedo tenho prova 😴",
    "tá, mas e o allocator? quem dá `free` nisso?",
    "manda o print",
    "que isso, ficou lindo demais 😍",
    "eu acho que o problema é o cache, tenta limpar com `rm -rf ~/.cache/zig` e compila de novo",
    "imagina um cliente de discord que abre em 200ms e gasta 30MB. seria o sonho né",
    "<@1005> tu usa qual tema no kitty?",
    "brabo",
    "sim",
    "não sei, mas confia",
    "joguei aquele jogo que tu falou, viciei demais. fiquei até 4 da manhã e nem vi o tempo passar, agora tô um zumbi no trabalho 🧟",
    "**urgente**: alguém tem carregador de notebook usb-c aí na sala?",
    "😂😂😂",
    "o segredo é dormir quando nada acontece. cpu em 0% parado é outro nível",
    "ok",
    "eu mudaria o raio das bordas pra uns 8px, fica mais moderno",
    "tô ouvindo lo-fi e programando, vibe perfeita ☕",
    "quem roubou meu energético da geladeira 😤",
    "amanhã tem call?",
    "fiz um script que troca as cores do sistema inteiro com o wallpaper, depois mando o repo",
    "<@1003> bora?",
    "pior que faz sentido",
    "vou testar aqui e já falo",
    "funcionou!!! 🎉",
    "o final da série é ||o cachorro era o vilão o tempo todo|| 😭",
    "~~não~~ sim, eu admito",
    "docs aqui: https://ziglang.org/documentation/master",
    "temas em KDL que mudam o layout inteiro? isso é *outro* nível",
};

/// As mesmas frases em inglês, na mesma ordem (o sorteio é pelo índice).
const phrases_en = [_][]const u8{
    "morning everyone ☀️",
    "anyone gaming tonight?",
    "LMAOOOOOOOOO",
    "look at vesktop's `ps aux`: **1.28 GB** of RAM just to send a message 💀",
    "<@1000> did you see this?",
    "just updated to zig 0.17 and everything broke again 🙃",
    "dude the new hyprland is *so* smooth",
    "**finally** got it to compile",
    "anyone got a good wallpaper? i'm sick of mine",
    "this is so larper lmao",
    "going to bed, got an exam early tomorrow 😴",
    "ok, but what about the allocator? who calls `free` on this?",
    "send a screenshot",
    "whoa, that looks way too good 😍",
    "i think the problem is the cache, try clearing it with `rm -rf ~/.cache/zig` and build again",
    "imagine a discord client that opens in 200ms and uses 30MB. that'd be the dream huh",
    "<@1005> which theme do you use in kitty?",
    "based",
    "yes",
    "no idea, but trust me",
    "played that game you told me about, got completely hooked. stayed up till 4am without noticing, now i'm a zombie at work 🧟",
    "**urgent**: anyone got a usb-c laptop charger in the room?",
    "😂😂😂",
    "the secret is sleeping when nothing's happening. 0% cpu when idle is next level",
    "ok",
    "i'd bump the border radius to like 8px, looks more modern",
    "listening to lo-fi and coding, perfect vibe ☕",
    "who stole my energy drink from the fridge 😤",
    "call tomorrow?",
    "wrote a script that recolors the whole system to match the wallpaper, i'll send the repo later",
    "<@1003> you in?",
    "annoyingly, that makes sense",
    "gonna test it here and get back to you",
    "it works!!! 🎉",
    "the show's ending is ||the dog was the villain the whole time|| 😭",
    "~~no~~ yes, i admit it",
    "docs here: https://ziglang.org/documentation/master",
    "KDL themes that change the whole layout? that's *next* level",
};

comptime {
    std.debug.assert(phrases.len == phrases_en.len);
}

fn phrase(i: usize) []const u8 {
    return if (i18n.en()) phrases_en[i] else phrases[i];
}
