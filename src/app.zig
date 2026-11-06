//! O app: liga janela, Store, gateway, temas e interface, e roda o laço.
//! O laço dorme em `SDL_WaitEvent` e só acorda com input, rede, mudança de
//! tema ou o tique do relógio/RAM; parado, a CPU fica em 0%.
const std = @import("std");
const sys = @import("platform/sys.zig");
const c = @import("c");
const platform = @import("platform/window.zig");
const timeline = @import("platform/timeline.zig");
const store_mod = @import("core/store.zig");
const accounts_mod = @import("core/accounts.zig");
const Store = store_mod.Store;
const ev = @import("core/event.zig");
const types = @import("core/types.zig");
const Gateway = @import("net/fake_gateway.zig").Gateway;
const discord = @import("net/discord.zig");
const gw = @import("net/fake_gateway.zig");
const Queue = @import("net/queue.zig").Queue;
const themes = @import("theme/manager.zig");
const layout = @import("theme/layout.zig");
const fonts_mod = @import("ui/fonts.zig");
const State = @import("ui/state.zig").State;
const d = @import("ui/draw.zig");
const anim = @import("ui/anim.zig");
const root = @import("ui/root.zig");
const login_mod = @import("ui/login.zig");
const qa_mod = @import("ui/qa.zig");
const images = @import("ui/images.zig");
const i18n = @import("ui/i18n.zig");
const widgets = @import("ui/widgets.zig");
const settings_state = @import("ui/settings_state.zig");
const kdl = @import("theme/kdl.zig");
const custom = @import("theme/custom.zig");
const guild_color = @import("ui/guild_color.zig");
const theme_mod = @import("theme/theme.zig");
const plugin_host = @import("plugins/host.zig");
const mentions = @import("core/mentions.zig");
const autocomplete = @import("ui/autocomplete.zig");
const inbox_core = @import("core/inbox.zig");
const leitura = @import("core/leitura.zig");
const saved_ui = @import("ui/saved.zig");
const msg_cache = @import("net/msg_cache.zig");
const jsonx = @import("net/jsonx.zig");
const fsutil = @import("platform/fsutil.zig");
const accounts_store = @import("net/accounts_store.zig");
const app_accounts = @import("app_accounts.zig");
const voz_audio = @import("net/voz_audio.zig");
const lsp_net = @import("net/lsp.zig");
const updater = @import("net/updater.zig");
const lsp_ui = @import("ui/lsp_ui.zig");
const mem_tune = @import("platform/mem_tune.zig");
const tray = @import("platform/tray.zig");
const instance = @import("platform/instance.zig");
const janela = @import("core/janela.zig");
const ritmo = @import("core/ritmo.zig");
const quadro = @import("ui/quadro.zig");

pub const Options = struct {
    theme: ?[]const u8 = null,
    shot: ?[*:0]const u8 = null,
    live: bool = true,
    /// Força claro/escuro (ignora as configurações).
    mode: ?@import("theme/theme.zig").Mode = null,
    /// Força o modo demonstração mesmo com token.
    demo: bool = false,
    stats: bool = false,
    settings: bool = false,
    /// Roda o robô de QA (ver qa_runner.zig).
    qa: bool = false,
    /// Mostra a tela de login sem usar o token salvo.
    login: bool = false,
    /// Força o idioma (ignora as configurações).
    lang: ?@import("ui/i18n.zig").Lang = null,
};

var wake_type_global: u32 = 0;

fn lspWake() void {
    platform.Window.wake(wake_type_global, .tick);
}

/// Só guarda o caminho: nada do LSP existe até um bloco de linguagem ligada aparecer.
fn setupLsp(qa_mode: bool) void {
    var buf: [512]u8 = undefined;
    const dir = if (qa_mode)
        "qa-out/lsp-scratch"
    else blk: {
        var hb: [400]u8 = undefined;
        const base = sys.cacheHome(&hb) orelse break :blk "";
        break :blk std.fmt.bufPrint(&buf, "{s}/larpercord/lsp-scratch", .{base}) catch "";
    };
    lsp_net.setup(&lspWake, dir);
}

fn wakeTheme() void {
    platform.Window.wake(wake_type_global, .theme);
}

/// `none`: ainda na tela de login, sem conexão nenhuma.
const Net = union(enum) { none, fake: Gateway, real: discord.Gateway };

pub const App = struct {
    gpa: std.mem.Allocator,
    win: platform.Window,
    store: Store,
    st: State,
    themes: themes.Manager,
    fonts: fonts_mod.Fonts,
    events: Queue(ev.Event),
    net: Net,
    actions: std.ArrayList(ev.Action) = .empty,
    placed: std.ArrayList(layout.Placed) = .empty,
    stats: d.Stats = .{},
    /// Se o quadro pronto vai para a tela (o QA lê as contas).
    gate: ritmo.Gate = .{},
    opts: Options,
    io: *c.ImGuiIO,
    timer: c.SDL_TimerID = 0,
    started_ns: u64,
    layout_key: u32 = 0,
    login: login_mod.Login = .{},
    /// Parar o laço e sair de verdade (nunca para a bandeja). Só da thread da
    /// interface: de outra, chame `Window.wake` em seguida para acordar o laço.
    restart_wanted: bool = false,
    /// Verificações seguidas sem painel com a janela escondida.
    tray_misses: u8 = 0,
    images: images.Cache = undefined,
    /// Arquivos escolhidos no seletor (o SDL pode responder de outra thread).
    picked: Queue([:0]u8) = undefined,
    /// Já tem um aviso da rede na fila do SDL: os próximos eventos só entram
    /// na fila de eventos, sem acordar a janela de novo.
    gw_signaled: std.atomic.Value(bool) = .init(false),
    /// Perfis já pedidos nesta sessão (um pedido por pessoa).
    asked_profiles: std.AutoHashMapUnmanaged(types.Id, void) = .empty,
    profiles_gen: u32 = 0,
    /// Cópia do tema com a cor de destaque e os cantos das configurações.
    th_custom: @import("theme/theme.zig").Theme = undefined,
    /// Cores escolhidas por tema e por modo (persistidas em settings.kdl).
    theme_colors: std.StringHashMapUnmanaged(custom.ThemeOverrides) = .empty,
    /// notify-send em andamento (recolhidos quando terminam).
    notifiers: std.ArrayList(*c.SDL_Process) = .empty,
    paste_n: u32 = 0,
    /// Muita memória acabou de ser solta (READY, rajada de imagens): o tique
    /// do relógio devolve ao sistema.
    trim_wanted: std.atomic.Value(bool) = .init(false),
    /// Guardar o token quando o Discord aceitar (o "Lembrar" do login).
    save_token: bool = false,
    /// Último aviso da rede (vira a mensagem de erro do login).
    last_notice: [200]u8 = undefined,
    last_notice_len: usize = 0,
    /// Plugins em Lua (~/.config/larpercord/plugins).
    plugins: plugin_host.Engine = undefined,
    /// Última gravação do cache de mensagens (no máximo uma por minuto pelo relógio).
    cache_flush_ms: i64 = 0,
    /// Canal aberto por último: ao sair dele, a linha "NOVAS MENSAGENS" acaba.
    viewing: types.Id = 0,
    /// QA: faz de conta que a janela perdeu o foco.
    qa_blur: bool = false,
    /// O QA quer o portão dos quadros valendo (não vai ler os pixels nesse trecho).
    qa_real_gate: bool = false,

    pub fn create(gpa: std.mem.Allocator, opts: Options) !*App {
        const started = c.SDL_GetTicksNS();
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);

        app.win = try platform.Window.init("larperCord", 1280, 800);
        wake_type_global = app.win.wake_type;
        timeline.mark(.janela);

        _ = c.ImGui_CreateContext(null);
        const io = c.ImGui_GetIO();
        io.*.IniFilename = null;
        io.*.ConfigInputTextCursorBlink = false; // sem piscar = sem redesenho parado
        _ = c.cImGui_ImplSDL3_InitForSDLRenderer(app.win.window, app.win.renderer);
        _ = c.cImGui_ImplSDLRenderer3_Init(app.win.renderer);
        timeline.mark(.imgui);

        const theme_list = try themes.Manager.init(gpa);
        timeline.mark(.lista_temas);
        const base_fonts = fonts_mod.Fonts.init(gpa, io.*.Fonts);
        timeline.mark(.fontes_base);
        app.* = .{
            .gpa = gpa,
            .win = app.win,
            .store = Store.init(gpa),
            .st = .{ .gpa = gpa },
            .themes = theme_list,
            .fonts = base_fonts,
            .events = try Queue(ev.Event).init(gpa),
            .net = undefined,
            .opts = opts,
            .io = io,
            .started_ns = started,
        };

        app.store.on_evict = msg_cache.onEvict;
        app.store.muted = &app.st.muted_channels;
        // Cache de mensagens e contas: o QA e os prints nunca usam os de verdade.
        msg_cache.init(opts.qa);
        msg_cache.off = opts.shot != null;
        accounts_store.memory_only = opts.qa or opts.shot != null;
        accounts_store.load();

        // Configurações salvas (ignoradas nos prints, para serem reprodutíveis).
        var saved_theme: ?[]const u8 = null;
        var settings_arena = std.heap.ArenaAllocator.init(gpa);
        defer settings_arena.deinit();
        if (opts.shot == null and !opts.qa) {
            saved_theme = app.loadSettings(settings_arena.allocator());
            var dbuf: [512]u8 = undefined;
            if (draftsPath(&dbuf)) |p| app.st.drafts.load(gpa, p);
        }
        // No QA e nos prints ninguém abre o microfone de verdade.
        voz_audio.force_dummy = opts.qa or opts.shot != null;
        app.themes.mode = app.wantedMode();
        // Já aqui: os dados da demonstração saem no idioma da interface.
        i18n.set(if (opts.qa and opts.lang == null) .pt else opts.lang orelse i18n.fromSetting(app.st.settings.language));
        app.st.settings.open = opts.settings;
        timeline.mark(.config);
        const name = opts.theme orelse saved_theme orelse "classico";
        const want = app.themes.indexOf(name) orelse 0;
        if (!app.themes.load(want)) {
            std.log.err("{s}", .{app.themes.last_error orelse "tema inválido"});
            if (!app.themes.load(0)) return error.NoTheme;
        }
        timeline.mark(.tema);
        app.applyThemeStyle();
        timeline.mark(.fontes_tema);
        app.themes.watch(wakeTheme);
        // Antes da rede: a thread do gateway inicia o libcurl pelo mesmo caminho.
        app.images = try images.Cache.init(app.win.renderer, app.win.wake_type);

        // Com token salvo: conecta direto (a tela de abertura aparece enquanto
        // isso). Sem token: a tela de login. Prints e QA usam a demonstração.
        app.net = .none;
        const qa_login = opts.qa and if (c.SDL_getenv("QA_SUITE")) |q| std.mem.eql(u8, std.mem.span(q), "login") else false;
        if (opts.login or qa_login) {
            app.login.begin(.form);
        } else if (opts.demo or opts.qa or (opts.shot != null and c.SDL_getenv("LARPER_SHOT_REAL") == null)) {
            // (LARPER_SHOT_REAL=1: print com a conta de verdade, para depurar.)
            try app.startDemo();
        } else if (app_accounts.envStartupToken()) |t| {
            try app.startReal(t);
            app.login.begin(.connecting);
        } else {
            // O chaveiro (secret-tool) leva um tempo e pode até pedir senha: a
            // janela abre antes e a resposta chega por `finishStartupLookup`.
            app.login.begin(if (accounts_store.list.len > 0) .connecting else .form);
            app_accounts.startStartupLookup(app.win.wake_type);
        }

        // Relógio e RAM da barra de status: um tique a cada 2 s.
        app.timer = c.SDL_AddTimer(2000, tick, app);
        app.stats.ram_kb = platform.selfMemKb().pss;
        app.picked = try Queue([:0]u8).init(std.heap.c_allocator);
        plugin_host.init(app);
        setupLsp(opts.qa);
        updater.setup(&lspWake);
        updater.offline = opts.qa;
        updater.cleanLeftovers();
        if (opts.qa) tray.fake = false;
        timeline.mark(.create_fim);
        return app;
    }

    /// Fechou a janela e ela deve ficar na bandeja? O app segue conectado e
    /// avisando, sem desenhar. Falso: sem bandeja, ou opção desligada; aí fechar
    /// sai de verdade, nunca fica um processo invisível sem caminho de volta.
    fn hideToTray(app: *App) bool {
        if (app.opts.shot != null or app.restart_wanted) return false;
        const logged_in = app.store.ready and !app.login.visible();
        if (!janela.wantsTray(app.st.settings.close_to_tray, logged_in)) return false;
        if (!tray.show(app.win.wake_type, i18n.trZ("Abrir o larperCord", "Open larperCord").ptr, i18n.trZ("Sair", "Quit").ptr)) return false;
        _ = c.SDL_HideWindow(app.win.window);
        // Sem quadros daqui em diante: o que depende do quadro fica certo agora.
        // Ninguém está olhando: confirmar leitura e o medidor do microfone param,
        // e o vídeo (a imagem também parou) pausa em vez de cortar o som depois de 1 s.
        app.st.window_focused = false;
        voz_audio.setPageOpen(false);
        @import("ui/video.zig").pause();
        // Aperte para falar: a tecla solta fora da janela não chegaria aqui.
        var lost = std.mem.zeroes(c.SDL_Event);
        lost.type = c.SDL_EVENT_WINDOW_FOCUS_LOST;
        _ = voz_audio.onSdlEvent(&lost);
        app.tray_misses = 0;
        // Um desligamento com a janela escondida pode nem passar por destroy.
        app.saveSettings();
        return true;
    }

    /// Volta da bandeja (ou traz para a frente, se a janela já estava aberta).
    fn showWindow(app: *App) void {
        tray.hide();
        app.tray_misses = 0;
        _ = c.SDL_ShowWindow(app.win.window);
        _ = c.SDL_RestoreWindow(app.win.window);
        _ = c.SDL_RaiseWindow(app.win.window);
    }

    pub fn destroy(app: *App) void {
        tray.hide();
        sys.toastExpire(0, true);
        instance.stopListening();
        app.saveSettings();
        // Primeiro: mesmo com um servidor travado, o filho morre antes do vigia de main.zig.
        lsp_net.shutdown();
        voz_audio.shutdown();
        _ = c.SDL_RemoveTimer(app.timer);
        // O painel aberto agora volta aberto na próxima vez.
        plugin_host.savePrefs();
        app.plugins.deinit();
        // O que estava na caixa de texto vira o rascunho do canal.
        _ = app.st.drafts.switchTo(app.gpa, 0, &app.st.input, app.st.editing == 0);
        app.saveDrafts();
        app.st.drafts.deinit(app.gpa);
        app.st.filtros.deinit(app.gpa);
        app.asked_profiles.deinit(app.gpa);
        var colors_it = app.theme_colors.iterator();
        while (colors_it.next()) |e| app.gpa.free(e.key_ptr.*);
        app.theme_colors.deinit(app.gpa);
        for (app.notifiers.items) |p| c.SDL_DestroyProcess(p);
        app.notifiers.deinit(app.gpa);
        app.stopNet();
        msg_cache.flushDirty(&app.store);
        msg_cache.deinit();
        app.login.clearToken();
        app.events.deinit();
        app.clearUploads();
        app.picked.deinit();
        @import("ui/video.zig").shutdown();
        // (Por último, lá dentro: as threads de mídia e de vídeo usam o libcurl.)
        app.images.deinit();
        app.st.saved.deinit(app.gpa);
        app.store.deinit();
        app.themes.deinit();
        c.cImGui_ImplSDLRenderer3_Shutdown();
        c.cImGui_ImplSDL3_Shutdown();
        c.ImGui_DestroyContext(null);
        app.win.deinit();
        // Por último: quem assumir a trava (um reinício) já acha tudo gravado.
        instance.release();
        app.gpa.destroy(app);
    }

    fn cmd(app: *App, command: ev.Command) void {
        switch (app.net) {
            .none => {},
            .fake => |*g| g.commands.push(command),
            .real => |*g| g.commands.push(command),
        }
    }

    /// Conecta na conta de verdade. O gateway passa a ser dono do token.
    pub fn startReal(app: *App, token: [:0]u8) !void {
        app.store.demo = false;
        app.net = .{ .real = .{
            .commands = try Queue(ev.Command).init(app.gpa),
            .sink = .{ .ctx = app, .push = pushEvent },
            .token = token,
        } };
        // Falhou: o token volta para quem chamou (nada de liberar de novo no stop).
        app.net.real.start() catch |err| {
            app.net.real.commands.deinit();
            app.net = .none;
            return err;
        };
    }

    pub fn startDemo(app: *App) !void {
        app.store.demo = true;
        app.net = .{ .fake = .{
            .commands = try Queue(ev.Command).init(app.gpa),
            .sink = .{ .ctx = app, .push = pushEvent },
            .live = app.opts.live,
            .rng = std.Random.DefaultPrng.init(@truncate(app.started_ns)),
        } };
        try app.net.fake.start();
    }

    pub fn stopNet(app: *App) void {
        switch (app.net) {
            .none => {},
            .fake => |*g| {
                g.stop();
                g.commands.deinit();
            },
            .real => |*g| {
                g.stop();
                g.commands.deinit();
            },
        }
        app.net = .none;
        // Eventos que ainda estavam na fila são da conexão que acabou.
        var stale: std.ArrayList(ev.Event) = .empty;
        defer stale.deinit(app.gpa);
        app.events.drain(&stale);
        for (stale.items) |e| app.store.apply(e, now()) catch {};
    }

    // --- Anexos ----------------------------------------------------------------

    /// Limite do Discord para quem não tem Nitro.
    const max_upload: u64 = 10 * 1024 * 1024;

    fn clearUploads(app: *App) void {
        for (app.st.uploads.items) |u| dropUpload(u.path);
        app.st.uploads.clearRetainingCapacity();
    }

    /// Tira um arquivo da bandeja. O de imagem colada era só nosso: apaga.
    fn dropUpload(path: [:0]u8) void {
        if (types.isPastedFile(path)) _ = c.unlink(path.ptr);
        std.heap.c_allocator.free(path);
    }

    /// Coloca um arquivo na bandeja da próxima mensagem.
    pub fn attachFile(app: *App, path: []const u8) void {
        const st = &app.st;
        if (st.uploads.items.len >= 10) return st.showToast(now(), true, "no máximo 10 arquivos por mensagem", "at most 10 files per message", .{});
        const z = std.heap.c_allocator.dupeSentinel(u8, path, 0) catch return;
        var info: c.SDL_PathInfo = undefined;
        if (!c.SDL_GetPathInfo(z.ptr, &info) or info.type != c.SDL_PATHTYPE_FILE) {
            std.heap.c_allocator.free(z);
            return st.showToast(now(), true, "não consegui abrir esse arquivo", "couldn't open that file", .{});
        }
        if (info.size > max_upload) {
            std.heap.c_allocator.free(z);
            return st.showToast(now(), true, "arquivo maior que 10 MB (limite do Discord sem Nitro)", "file larger than 10 MB (Discord's limit without Nitro)", .{});
        }
        var up: @import("ui/state.zig").Upload = .{ .path = z, .size = info.size };
        // Imagem? Lê só as dimensões (para reservar o espaço na conversa).
        var size: usize = 0;
        if (c.SDL_LoadFile(z.ptr, &size)) |data| {
            defer c.SDL_free(data);
            var w: c_int = 0;
            var h: c_int = 0;
            var comp: c_int = 0;
            if (c.stbi_info_from_memory(@ptrCast(data), @intCast(size), &w, &h, &comp) != 0 and w > 0 and h > 0) {
                up.width = @intCast(@min(w, 65535));
                up.height = @intCast(@min(h, 65535));
            }
        }
        st.uploads.append(app.gpa, up) catch std.heap.c_allocator.free(z);
        st.focus_input = true;
    }

    fn pickedCb(data: ?*anyopaque, list: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(data.?));
        if (list == null) return;
        var i: usize = 0;
        while (list[i] != null) : (i += 1) {
            const z = std.heap.c_allocator.dupeSentinel(u8, std.mem.span(list[i]), 0) catch continue;
            app.picked.push(z);
        }
        platform.Window.wake(app.win.wake_type, .media);
    }

    fn pickFiles(app: *App) void {
        if (app.opts.qa) return;
        c.SDL_ShowOpenFileDialog(pickedCb, app, app.win.window, null, 0, null, true);
    }

    /// Só uma imagem, para o ícone ou o banner (ui/edit_place.zig).
    fn pickImage(app: *App) void {
        if (app.opts.qa) return;
        const filters = [_]c.SDL_DialogFileFilter{.{ .name = "Imagens", .pattern = "png;jpg;jpeg;gif;webp" }};
        c.SDL_ShowOpenFileDialog(pickedCb, app, app.win.window, &filters, filters.len, null, false);
    }

    /// Imagem colada: vai para um arquivo temporário e entra na bandeja.
    fn pasteImage(app: *App) void {
        var size: usize = 0;
        const data = c.SDL_GetClipboardData("image/png", &size) orelse return;
        defer c.SDL_free(data);
        const dir = sys.tempDir();
        var pbuf: [512]u8 = undefined;
        app.paste_n += 1;
        // O nome do arquivo aparece na bandeja e vai junto para o Discord.
        const path = i18n.fmtZ(&pbuf, "{s}/larpercord-colado-{d}-{d}.png", "{s}/larpercord-pasted-{d}-{d}.png", .{ dir, c.getpid(), app.paste_n });
        if (path.len == 0) return;
        if (!c.SDL_SaveFile(path.ptr, data, size)) return app.st.showToast(now(), true, "não consegui colar a imagem", "couldn't paste the image", .{});
        app.attachFile(path);
    }

    /// Volta ao estado de antes do login: sem conta, sem abas, sem nada.
    pub fn resetSession(app: *App) void {
        // O que estava na tela vai para o cache antes de sumir.
        msg_cache.flushDirty(&app.store);
        @import("ui/search.zig").close();
        _ = app.st.drafts.switchTo(app.gpa, 0, &app.st.input, app.st.editing == 0);
        app.st.filtros.resetSession();
        app.asked_profiles.clearRetainingCapacity();
        app.clearUploads();
        app.st.viewer = null;
        app.st.saved.clear(app.gpa);
        app.st.saved.owner = 0;
        app.plugins.setAccount(0);
        app.store.deinit();
        app.store = Store.init(app.gpa);
        app.store.on_evict = msg_cache.onEvict;
        app.store.muted = &app.st.muted_channels;
        app.viewing = 0;
        const st = &app.st;
        st.muted_channels.clearRetainingCapacity();
        st.jump = 0;
        st.jump_asked = 0;
        st.tabs.clearRetainingCapacity();
        st.tab = 0;
        st.guild = 0;
        st.last_channel.clearRetainingCapacity();
        st.collapsed.clearRetainingCapacity();
        st.scroll.clearRetainingCapacity();
        st.voice = null;
        st.voice_guild = 0;
        st.voice_status = .disconnected;
        st.voice_mixer = false;
        app.resetCallState();
        st.popup = .none;
        st.palette.open = false;
        st.settings.open = false;
        st.reply_to = 0;
        st.editing = 0;
        st.pending_dm = 0;
        st.selection = .{};
        @memset(&st.input, 0);
        st.input_sync = true;
    }

    /// O que a tela de login pediu.
    fn loginResult(app: *App, r: login_mod.Result) void {
        // Decidiu alguma coisa na tela: a resposta do chaveiro não vale mais.
        app_accounts.abandonStartupLookup();
        const lg = &app.login;
        switch (r) {
            .submit => {
                const t = lg.tokenText();
                if (t.len == 0) return lg.fail(i18n.tr("Cole o token no campo acima.", "Paste the token in the field above."));
                if (t.len < 50 or std.mem.indexOfAny(u8, t, " \t") != null)
                    return lg.fail(i18n.tr("Isso não parece um token do Discord.", "That doesn't look like a Discord token."));
                if (app.opts.qa) {
                    // O QA nunca fala com o Discord: simula a recusa.
                    lg.clearToken();
                    return lg.fail(i18n.tr("O Discord recusou esse token (teste).", "Discord rejected that token (test)."));
                }
                const owned = std.heap.c_allocator.dupeSentinel(u8, t, 0) catch return lg.fail(i18n.tr("Sem memória.", "Out of memory."));
                lg.clearToken();
                // Adicionando conta: a que estava aberta desconecta agora.
                app.stopNet();
                app.resetSession();
                lg.back_len = 0;
                app_accounts.token_source = .typed;
                app.save_token = lg.remember;
                app.last_notice_len = 0;
                app.startReal(owned) catch return lg.fail(i18n.tr("Não consegui iniciar a conexão.", "Couldn't start the connection."));
                lg.setPhase(.connecting);
            },
            .demo => {
                lg.clearToken();
                app.stopNet();
                app.resetSession();
                app_accounts.token_source = .none;
                app.startDemo() catch return;
                lg.setPhase(.connecting);
            },
            .cancel => {
                app.stopNet();
                app.resetSession();
                lg.setPhase(.form);
            },
            .pick => {
                lg.clearToken();
                if (!app_accounts.switchAccount(app, lg.picked)) lg.fail(i18n.tr("Não achei o token dessa conta no chaveiro.", "Couldn't find that account's token in the keyring."));
            },
            .back => {
                lg.clearToken();
                lg.back_len = 0;
                // Adicionando conta com a sessão aberta: só fecha o login.
                if (app.store.ready) return lg.setPhase(.leaving);
                if (accounts_store.list.find(app_accounts.prev_account) != null and app_accounts.switchAccount(app, app_accounts.prev_account)) return;
                lg.fail(i18n.tr("Não achei o token dessa conta no chaveiro.", "Couldn't find that account's token in the keyring."));
            },
        }
    }

    fn pushEvent(ctx: *anyopaque, e: ev.Event) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        app.events.push(e);
        if (!app.gw_signaled.swap(true, .acq_rel)) platform.Window.wake(app.win.wake_type, .gateway);
    }

    fn tick(data: ?*anyopaque, _: c.SDL_TimerID, interval: u32) callconv(.c) u32 {
        const app: *App = @ptrCast(@alignCast(data.?));
        // Aqui, e não na thread da UI: varrer as arenas leva milissegundos. Em
        // call fica para depois: durante a varredura, quem pede memória espera,
        // e a voz não pode esperar. O pedido continua valendo até a call acabar.
        if (!voz_audio.in_call.load(.acquire) and app.trim_wanted.swap(false, .acq_rel)) mem_tune.trim();
        // O número da RAM: só se está na tela. Varrer o mapa de memória do
        // processo leva milissegundos, e o tique roda mesmo com tudo parado.
        const ram_seen = @atomicRmw(bool, &app.stats.ram_seen, .Xchg, false, .monotonic);
        const prev = @atomicLoad(u32, &app.stats.ram_kb, .monotonic);
        var kb = prev;
        if (ram_seen) {
            const mem = platform.selfMemKb();
            kb = mem.pss;
            @atomicStore(u32, &app.stats.file_kb, mem.file, .monotonic);
            if (!voz_audio.in_call.load(.acquire)) if (mem_tune.heap()) |h| {
                @atomicStore(u32, &app.stats.heap_used_kb, h.used_kb, .monotonic);
                @atomicStore(u32, &app.stats.heap_free_kb, h.free_kb, .monotonic);
            };
        }
        const S = struct {
            var last_minute: i64 = 0;
        };
        const minute = @divTrunc(gw.nowMs(), 60_000);
        const new_minute = minute != S.last_minute;
        S.last_minute = minute;
        if (kb / 100 != prev / 100 or new_minute) {
            @atomicStore(u32, &app.stats.ram_kb, kb, .monotonic);
            platform.Window.wake(app.win.wake_type, .tick);
        }
        return interval;
    }

    fn now() i64 {
        return gw.nowMs();
    }

    /// Ajustes do ImGui que dependem do tema.
    fn applyImGuiColors(app: *App, th: *const theme_mod.Theme) void {
        _ = app;
        const style = c.ImGui_GetStyle();
        const col = &style.*.Colors;
        for (col) |*cc| cc.* = .{ .x = 0, .y = 0, .z = 0, .w = 0 };
        const v4 = struct {
            fn f(x: d.Rgba) c.ImVec4 {
                return .{ .x = x.r, .y = x.g, .z = x.b, .w = x.a };
            }
        }.f;
        col[c.ImGuiCol_Text] = v4(th.c(.text));
        col[c.ImGuiCol_TextDisabled] = v4(th.c(.faint));
        col[c.ImGuiCol_TextSelectedBg] = v4(th.c(.accent).alpha(0.35));
        col[c.ImGuiCol_InputTextCursor] = v4(th.c(.accent).mix(th.c(.text), 0.5));
        col[c.ImGuiCol_ScrollbarGrab] = v4(th.c(.text).alpha(0.12));
        col[c.ImGuiCol_ScrollbarGrabHovered] = v4(th.c(.text).alpha(0.2));
        col[c.ImGuiCol_ScrollbarGrabActive] = v4(th.c(.text).alpha(0.3));
    }

    fn applyThemeStyle(app: *App) void {
        const th = app.themes.theme_();
        const style = c.ImGui_GetStyle();
        style.*.WindowPadding = .{ .x = 0, .y = 0 };
        style.*.WindowBorderSize = 0;
        style.*.ChildBorderSize = 0;
        style.*.FrameBorderSize = 0;
        style.*.FramePadding = .{ .x = 0, .y = 4 };
        style.*.ItemSpacing = .{ .x = 0, .y = 0 };
        style.*.ScrollbarSize = 6;
        style.*.ScrollbarRounding = 3;
        style.*.FontSizeBase = th.font_size;
        app.applyImGuiColors(th);

        // Fontes do tema (carregadas sob demanda e reaproveitadas).
        _ = app.fonts.family(th.font_ui) catch app.fonts.family("Inter") catch {};
        _ = app.fonts.family(th.font_mono) catch app.fonts.family("monospace") catch {};
        // Fontes pedidas por componentes (`font="Liberation Serif"`).
        if (th.layout) |lay| app.loadNodeFonts(lay);
        // O fontconfig guarda o cache de todas as fontes do sistema (~MBs);
        // ele se reinicia sozinho se outro tema pedir uma família nova.
        if (!sys.windows) c.FcFini();
        // Na abertura o tique faz isso depois (e junto com o que vier a seguir).
        app.trim_wanted.store(true, .release);
        app.st.theme_gen +%= 1;
    }

    fn settingsPath(buf: []u8) ?[:0]const u8 {
        return fsutil.configPath(buf, "settings.kdl");
    }

    /// Lê ~/.config/larpercord/settings.kdl. Retorna o tema salvo, se houver.
    /// Modo de cor pedido nas configurações (resolvendo "seguir o sistema").
    fn wantedMode(app: *const App) @import("theme/theme.zig").Mode {
        if (app.opts.mode) |m| return m;
        return switch (app.st.settings.color_mode) {
            1 => .light,
            2 => if (c.SDL_GetSystemTheme() == c.SDL_SYSTEM_THEME_LIGHT) .light else .dark,
            else => .dark,
        };
    }

    /// O que só vale durante uma call (entrou, saiu, trocou de conta).
    fn resetCallState(app: *App) void {
        app.st.voice_ping_ms = 0;
        app.st.voice_mic_failed = false;
        app.st.voice_out_failed = false;
        voz_audio.sh.server_mute.store(false, .release);
        voz_audio.sh.server_deaf.store(false, .release);
    }

    /// O servidor nos mutou ou ensurdeceu (ou deixou de): a thread de voz para
    /// de transmitir pelo mesmo caminho, na demonstração e na call de verdade.
    fn serverFlags(app: *App, f: ev.VoiceFlags) void {
        const sh = &voz_audio.sh;
        const was_mute = sh.server_mute.load(.acquire);
        const was_deaf = sh.server_deaf.load(.acquire);
        sh.server_mute.store(f.serverMuted(), .release);
        sh.server_deaf.store(f.deaf, .release);
        if (f.deaf and !was_deaf) {
            app.st.showToast(now(), true, "o servidor te ensurdeceu nesta call", "the server deafened you in this call", .{});
        } else if (f.serverMuted() and !was_mute) {
            app.st.showToast(now(), true, "o servidor te mutou nesta call", "the server muted you in this call", .{});
        } else if ((was_mute or was_deaf) and !f.serverMuted() and !f.deaf) {
            app.st.showToast(now(), false, "o servidor liberou seu microfone", "the server unmuted you", .{});
        }
    }

    fn voiceAudio(app: *App, mic_ok: bool, out_ok: bool) void {
        const st = &app.st;
        if (!mic_ok and !st.voice_mic_failed) {
            st.showToast(now(), true, "o microfone não abriu: ninguém está te ouvindo", "the microphone didn't open: nobody can hear you", .{});
        } else if (!out_ok and !st.voice_out_failed) {
            st.showToast(now(), true, "a saída de áudio não abriu: você não vai ouvir a call", "the audio output didn't open: you won't hear the call", .{});
        }
        st.voice_mic_failed = !mic_ok;
        st.voice_out_failed = !out_ok;
    }

    fn loadSettings(app: *App, arena: std.mem.Allocator) ?[]const u8 {
        const s = &app.st.settings;
        var buf: [512]u8 = undefined;
        const path = settingsPath(&buf) orelse return null;
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
        defer c.SDL_free(data);
        const src = arena.dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch return null;
        const nodes = kdl.parse(arena, src, null) catch {
            fsutil.keepBroken(path);
            return null;
        };
        var theme_name: ?[]const u8 = null;
        for (nodes) |*n| {
            if (std.mem.eql(u8, n.name, "settings")) {
                settings_state.apply(s, n);
                theme_name = n.str("theme");
            } else if (std.mem.eql(u8, n.name, "theme-options")) {
                // `theme-options "terminal" crt=#false ascii=#true`
                const name = (n.arg(0) orelse continue).asString() orelse continue;
                for (n.props) |p| if (p.value.asBool()) |v| app.themes.choose(name, p.key, v);
            } else if (std.mem.eql(u8, n.name, "voice-volume")) {
                // `voice-volume "1234" 0.8`
                const sid = (n.arg(0) orelse continue).asString() orelse continue;
                const gain = (n.arg(1) orelse continue).asNumber() orelse continue;
                const uid = std.fmt.parseInt(types.Id, sid, 10) catch continue;
                app.st.voice_volumes.put(app.gpa, uid, @floatCast(std.math.clamp(gain, 0, 2))) catch {};
            } else if (app.st.filtros.applyNode(app.gpa, n, now())) {
                // Palavras de alerta, filtro, ignorados e foco (core/filtros.zig).
            } else if (std.mem.eql(u8, n.name, "guild-color")) {
                guild_color.load(&guild_color.colors, std.heap.c_allocator, n);
            } else if (std.mem.eql(u8, n.name, "theme-colors")) {
                // `theme-colors "vidro" mode=dark bg="#101014" accent="#ff00aa"`
                const name = (n.arg(0) orelse continue).asString() orelse continue;
                const mode: theme_mod.Mode = if (n.str("mode")) |m|
                    (if (std.mem.eql(u8, m, "light")) .light else .dark)
                else
                    .dark;
                const ov = app.themeOverridesFor(name) orelse continue;
                const dst = ov.at(mode);
                for (n.props) |p| {
                    if (std.mem.eql(u8, p.key, "mode")) continue;
                    const slot = custom.slotFromName(p.key) orelse continue;
                    const text = p.value.asString() orelse continue;
                    if (custom.parseHex(text)) |rgba| dst.set(slot, rgba);
                }
            }
        }
        return theme_name;
    }

    fn themeOverridesFor(app: *App, name: []const u8) ?*custom.ThemeOverrides {
        if (app.theme_colors.getPtr(name)) |o| return o;
        const key = app.gpa.dupe(u8, name) catch return null;
        app.theme_colors.put(app.gpa, key, .{}) catch {
            app.gpa.free(key);
            return null;
        };
        return app.theme_colors.getPtr(key);
    }

    pub fn saveSettings(app: *App) void {
        if (app.opts.shot != null or app.opts.qa) return;
        var buf: [512]u8 = undefined;
        const path = settingsPath(&buf) orelse return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(app.gpa);
        settings_state.write(&app.st.settings, app.themes.name(), &out, app.gpa) catch return;
        var vit = app.st.voice_volumes.iterator();
        while (vit.next()) |e| out.print(app.gpa, "voice-volume \"{d}\" {d:.3}\n", .{ e.key_ptr.*, e.value_ptr.* }) catch return;
        app.st.filtros.save = false;
        app.st.filtros.write(&out, app.gpa) catch return;
        var it = app.themes.choices.iterator();
        while (it.next()) |e| {
            out.print(app.gpa, "theme-options \"{s}\"", .{e.key_ptr.*}) catch return;
            var oit = e.value_ptr.iterator();
            while (oit.next()) |o| out.print(app.gpa, " {s}={s}", .{ o.key_ptr.*, if (o.value_ptr.*) "#true" else "#false" }) catch return;
            out.append(app.gpa, '\n') catch return;
        }
        var cit = app.theme_colors.iterator();
        while (cit.next()) |e| {
            for ([_]theme_mod.Mode{ .dark, .light }) |mode| {
                const ov = e.value_ptr.atConst(mode);
                if (!ov.any()) continue;
                out.print(app.gpa, "theme-colors \"{s}\" mode={s}", .{ e.key_ptr.*, @tagName(mode) }) catch return;
                for (0..custom.slot_count) |slot| {
                    if (ov.get(slot)) |v| {
                        var hb: [16]u8 = undefined;
                        out.print(app.gpa, " {s}=\"{s}\"", .{ custom.slotName(slot), custom.formatPacked(&hb, v) }) catch return;
                    }
                }
                out.append(app.gpa, '\n') catch return;
            }
        }
        guild_color.write(&guild_color.colors, &out, app.gpa) catch return;
        // Só para o dono: tem o proxy (que pode levar usuário:senha), quem
        // está ignorado e as palavras de alerta.
        _ = fsutil.writePrivate(path, out.items);
    }

    /// drafts.kdl, ao lado do settings.kdl.
    fn draftsPath(buf: []u8) ?[:0]const u8 {
        var sb: [512]u8 = undefined;
        const p = settingsPath(&sb) orelse return null;
        const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse return null;
        return std.fmt.bufPrintSentinel(buf, "{s}/drafts.kdl", .{p[0..slash]}, 0) catch null;
    }

    fn saveDrafts(app: *App) void {
        if (!app.st.drafts.dirty) return;
        if (app.opts.shot != null or app.opts.qa) {
            app.st.drafts.dirty = false;
            return;
        }
        var buf: [512]u8 = undefined;
        const path = draftsPath(&buf) orelse return;
        app.st.drafts.save(app.gpa, path);
    }

    fn loadNodeFonts(app: *App, n: *const kdl.Node) void {
        if (n.str("font")) |f| {
            if (!std.mem.eql(u8, f, "mono") and !std.mem.eql(u8, f, "ui")) _ = app.fonts.family(f) catch {};
        }
        for (n.children) |*ch| app.loadNodeFonts(ch);
    }

    pub fn uiFamily(app: *App, name: []const u8) *fonts_mod.Family {
        return app.fonts.family(name) catch app.fonts.family("Inter") catch app.fonts.families.items[0];
    }

    fn setTheme(app: *App, i: usize) void {
        if (app.themes.load(i)) {
            app.applyThemeStyle();
            app.st.showToast(now(), false, "tema: {s}", "theme: {s}", .{app.themes.name()});
            app.saveSettings();
        } else app.st.showToast(now(), true, "{s}", "{s}", .{app.themes.last_error orelse i18n.tr("erro no tema", "theme error")});
    }

    // --- Ações da interface ------------------------------------------------

    fn openChannel(app: *App, id: types.Id, new_tab: bool) void {
        const cs = app.store.channel(id) orelse return;
        if (cs.info.kind != .text and cs.info.kind != .forum) return;
        app.st.guild = cs.info.guild;
        app.st.friends = false;
        app.subscribeTo(cs);
        app.st.last_channel.put(app.gpa, cs.info.guild, id) catch {};
        for (app.st.tabs.items, 0..) |t, i| if (t == id) {
            app.st.tab = i;
            return app.afterOpen(cs);
        };
        if (new_tab or app.st.tabs.items.len == 0) {
            app.st.tabs.append(app.gpa, id) catch return;
            app.st.tab = app.st.tabs.items.len - 1;
        } else app.st.tabs.items[app.st.tab] = id;
        app.afterOpen(cs);
    }

    /// Lista de membros do servidor, vista deste canal. Numa thread, a do
    /// canal pai (ela não tem lista própria no op 14), mais quem está nela.
    fn subscribeTo(app: *App, cs: anytype) void {
        if (cs.info.guild == 0) return;
        const parent = if (cs.info.thread != null) cs.info.parent orelse cs.info.id else cs.info.id;
        app.cmd(.{ .subscribe_guild = .{ .guild = cs.info.guild, .channel = parent, .thread = if (cs.info.thread != null) cs.info.id else 0 } });
    }

    fn afterOpen(app: *App, cs: anytype) void {
        // Saiu do outro canal: a linha de lá acaba e o "não lida" à mão vale
        // só até aqui. Lido de verdade é quando a conversa aparece no fim
        // (ver `channel_seen`).
        if (app.viewing != cs.info.id) {
            if (app.store.channel(app.viewing)) |old| {
                old.divider_after = 0;
                old.divider_seen = false;
                old.pos_unread = false;
                old.hold_unread = false;
            }
            app.viewing = cs.info.id;
            cs.hold_unread = false;
        }
        app.prepareUnread(cs);
        app.st.focus_input = true;
        // Trocou de conversa: a que ficou para trás vai para o disco.
        msg_cache.leaving(&app.store, cs.info.id);
        // Fórum não tem conversa: a página pede os posts (ui/forum.zig).
        if (cs.info.kind == .forum) return;
        if (cs.info.thread != null and !cs.members_asked) {
            cs.members_asked = true;
            app.cmd(.{ .fetch_thread_members = cs.info.id });
        }
        if (cs.history == .none or cs.history == .failed) {
            cs.history = .loading;
            // O cache do disco aparece na hora; o histórico chega por cima.
            msg_cache.restore(&app.store, cs);
            app.cmd(.{ .fetch_history = cs.info.id });
        }
    }

    /// Canal aberto com não lidas: marca onde começa a linha e, se a opção
    /// pede, abre nela.
    fn prepareUnread(app: *App, cs: anytype) void {
        if (!cs.info.unread or cs.divider_after != 0) return;
        cs.divider_after = @max(cs.read_id, 1);
        cs.divider_seen = false;
        cs.pos_unread = app.st.settings.open_at_unread;
    }

    /// Canal lido: limpa aqui e avisa o Discord (a thread de rede junta os que
    /// chegam em sequência). Sozinho, só com a janela em foco: sem ela, ninguém leu.
    /// Pedido pela pessoa (`asked`) vale sempre. O status não entra nisso: o estado
    /// de leitura é da conta, ninguém mais vê.
    fn readChannel(app: *App, id: types.Id, asked: bool) void {
        const cs = app.store.channel(id) orelse return;
        const target = cs.info.last_message;
        app.store.markRead(id);
        app.st.filtros.clear(&app.store, id);
        if (target != 0 and (asked or app.st.window_focused)) app.cmd(.{ .ack = .{ .channel = id, .message = target, .last_viewed = leitura.lastViewed(now()) } });
    }

    /// "Marcar como lido" (canal ou servidor), pedido pela pessoa.
    fn markReadAction(app: *App, id: types.Id) void {
        const st = &app.st;
        if (app.store.channel(id)) |cs| {
            cs.divider_after = 0;
            app.readChannel(id, true);
            return;
        }
        const g = app.store.guild(id) orelse return;
        const list = app.store.channelsOf(id);
        const ca = std.heap.c_allocator;
        var bulk: std.ArrayList([2]types.Id) = .empty;
        for (list) |parent_ch| {
            // O canal e as threads dele.
            const threads = app.store.threadsOf(parent_ch);
            var ti: usize = 0;
            while (ti <= threads.len) : (ti += 1) {
                const ch = if (ti == 0) parent_ch else threads[ti - 1];
                const cs = app.store.channel(ch) orelse continue;
                if (cs.info.kind == .text and cs.info.last_message != 0 and (cs.info.unread or st.filtros.count(ch) > 0)) bulk.append(ca, .{ ch, cs.info.last_message }) catch {};
                cs.divider_after = 0;
                app.store.markRead(ch);
                st.filtros.clear(&app.store, ch);
            }
        }
        g.unread = false;
        g.mentions = 0;
        if (store_mod.read_debug) std.log.info("leitura: servidor {d} marcado como lido, {d} canais no ack", .{ id, bulk.items.len });
        if (bulk.items.len == 0) return bulk.deinit(ca);
        const owned = bulk.toOwnedSlice(ca) catch return bulk.deinit(ca);
        app.cmd(.{ .ack_bulk = owned });
    }

    /// "Marcar como não lida": o canal volta a estar não lido desde esta
    /// mensagem e não confirma leitura sozinho até sair e voltar.
    fn markUnreadAction(app: *App, id: types.Id) void {
        const st = &app.st;
        // Pendente (sem ID): ainda não existe para o Discord.
        if (id == 0) return;
        const f = app.store.findAny(id) orelse return;
        const cs = f.cs;
        const items = cs.messages.items;
        var i = (@intFromPtr(f.m) - @intFromPtr(items.ptr)) / @sizeOf(@TypeOf(items[0]));
        const prev: types.Id = while (i > 0) {
            i -= 1;
            if (items[i].msg.id != 0) break items[i].msg.id;
        } else leitura.beforeId(id);
        cs.read_id = prev;
        cs.info.unread = true;
        cs.hold_unread = true;
        cs.divider_after = prev;
        cs.divider_seen = false;
        cs.pos_unread = false;
        const n = leitura.countFrom(&app.store, cs, prev);
        const pings: u16 = if (cs.info.guild == 0) n.messages else n.mentions;
        st.filtros.setCount(app.gpa, &app.store, cs.info.id, pings);
        app.store.refreshGuildUnread(cs.info.guild);
        app.store.rev +%= 1;
        app.cmd(.{ .ack = .{ .channel = cs.info.id, .message = prev, .manual = true, .mentions = pings } });
    }

    /// Envia uma mensagem: aparece na hora como "pendente" e vai pra rede.
    /// "@fulano" vira a menção de verdade (<@id>) quando o nome existe.
    pub fn sendTo(app: *App, ch: types.Id, text: []const u8, reply_to: types.Id) void {
        app.sendWith(ch, text, reply_to, true);
    }

    /// `with_uploads`: leva os arquivos da bandeja junto. Só o que a própria
    /// pessoa enviou pela caixa de texto; um plugin nunca leva os arquivos dela.
    pub fn sendWith(app: *App, ch: types.Id, text: []const u8, reply_to: types.Id, with_uploads: bool) void {
        const out_text = mentions.expand(app.gpa, &app.store, app.guildOfChannel(ch), text, &.{}) catch return;
        defer app.gpa.free(out_text);
        app.st.nonce += 1;
        // Os arquivos da bandeja vão junto: aparecem na hora na cópia pendente.
        const ca = std.heap.c_allocator;
        const ups = if (with_uploads) app.st.uploads.items else &.{};
        var atts: []types.Attachment = &.{};
        var files: [][:0]const u8 = &.{};
        if (ups.len > 0) {
            atts = ca.alloc(types.Attachment, ups.len) catch return;
            files = ca.alloc([:0]const u8, ups.len) catch return;
            for (ups, 0..) |u, i| {
                atts[i] = .{
                    .url = std.fmt.allocPrint(ca, "file://{s}", .{u.path}) catch return,
                    .filename = ca.dupe(u8, u.name()) catch return,
                    .width = u.width,
                    .height = u.height,
                    .size = @intCast(@min(u.size, std.math.maxInt(u32))),
                };
                files[i] = u.path;
            }
            // Os caminhos passam para o comando; a bandeja esvazia.
            app.st.uploads.clearRetainingCapacity();
        }
        // Mandar de uma conversa antiga leva ao presente, como no Discord.
        if (app.store.channel(ch)) |cs| if (cs.detached) app.handle(.{ .jump_present = ch });
        app.store.addPending(ch, out_text, app.st.nonce, reply_to, now(), atts) catch return;
        app.st.scrollOf(ch).stick_bottom = true;
        const copy = ca.dupe(u8, out_text) catch return;
        app.cmd(.{ .send_message = .{ .channel = ch, .content = copy, .nonce = app.st.nonce, .reply_to = reply_to, .files = files } });
    }

    fn guildOfChannel(app: *const App, ch: types.Id) types.Id {
        return if (app.store.channel(ch)) |cs| cs.info.guild else 0;
    }

    /// Trocou de canal: o texto da caixa vira o rascunho do anterior e o
    /// rascunho do novo volta para a caixa (uma edição em andamento é cancelada).
    fn syncDraft(app: *App) void {
        const st = &app.st;
        const ch = st.activeChannel() orelse 0;
        if (!st.drafts.switchTo(app.gpa, ch, &st.input, st.editing == 0)) return;
        st.input_sync = true;
        st.editing = 0;
        st.reply_to = 0;
        app.saveDrafts();
    }

    /// Depois de editar uma mensagem, a caixa volta com o rascunho do canal.
    fn restoreDraft(app: *App) void {
        const st = &app.st;
        const text = if (st.activeChannel()) |ch| st.drafts.get(ch) orelse "" else "";
        const n = @min(text.len, st.input.len - 1);
        @memcpy(st.input[0..n], text[0..n]);
        @memset(st.input[n..], 0);
        st.input_sync = true;
    }

    fn firstTextChannel(app: *App, guild: types.Id) ?types.Id {
        for (app.store.channelsOf(guild)) |id| {
            if (app.store.channel(id)) |cs| if (cs.info.kind == .text) return id;
        }
        return null;
    }

    pub fn handle(app: *App, a: ev.Action) void {
        const st = &app.st;
        if (app.opts.qa and c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[ação] {t}\n", .{a});
        switch (a) {
            .select_guild => |g| {
                st.guild = g;
                // Mensagens diretas sem conversa aberta: começa pelos amigos.
                // O último aberto pode ter sumido (uma thread apagada).
                const last = if (st.last_channel.get(g)) |id| (if (app.store.channel(id) != null) id else null) else null;
                const ch = last orelse app.firstTextChannel(g) orelse return app.handle(.open_friends);
                if (g == 0 and st.last_channel.get(0) == null) return app.handle(.open_friends);
                app.openChannel(ch, false);
            },
            .set_status => |status| {
                st.settings.my_status = @backingInt(status);
                if (app.store.users.getPtr(app.store.me)) |me| me.status = status;
                app.cmd(.{ .set_status = status });
                app.saveSettings();
            },
            .want_profile => |user| {
                // Por servidor também: "no servidor desde" muda com ele.
                const key = user ^ (st.guild *% 0x9E3779B97F4A7C15);
                // O Store esvaziou os perfis: dá para pedir de novo.
                if (app.profiles_gen != app.store.profiles_gen) {
                    app.profiles_gen = app.store.profiles_gen;
                    app.asked_profiles.clearRetainingCapacity();
                }
                if (app.asked_profiles.contains(key)) return;
                app.asked_profiles.put(app.gpa, key, {}) catch return;
                app.cmd(.{ .fetch_profile = .{ .user = user, .guild = st.guild } });
            },
            .open_full_profile => |fp| {
                st.popup = .{ .profile_full = .{ .user = fp.user } };
                st.profile_tab = fp.tab;
            },
            .set_note => |n| {
                defer app.gpa.free(n.text);
                const ca = std.heap.c_allocator;
                const mine = ca.dupe(u8, n.text) catch return;
                app.store.apply(.{ .note = .{ .user = n.user, .text = mine } }, now()) catch {};
                if (app.store.demo) return;
                app.cmd(.{ .set_note = .{ .user = n.user, .text = ca.dupe(u8, n.text) catch return } });
            },
            .move_member => |mm| app.cmd(.{ .move_member = .{ .guild = mm.guild, .user = mm.user, .channel = mm.channel } }),
            .want_app_icon => |id| {
                if (app.asked_profiles.contains(id)) return;
                app.asked_profiles.put(app.gpa, id, {}) catch return;
                app.cmd(.{ .fetch_app = id });
            },
            .member_role => |mr| {
                app.store.memberRoleLocal(mr.guild, mr.user, mr.role, mr.add) catch return;
                app.cmd(.{ .member_role = .{ .guild = mr.guild, .user = mr.user, .role = mr.role, .add = mr.add } });
            },
            .load_older => |id| {
                const cs = app.store.channel(id) orelse return;
                // (Ainda no cache do disco: espera o histórico de verdade.)
                if (cs.older != .idle or cs.history != .loaded or cs.cached or now() < cs.older_retry_ms) return;
                // A mais antiga que já veio do servidor (a pendente não tem ID).
                const before = for (cs.messages.items) |m| {
                    if (m.msg.id != 0) break m.msg.id;
                } else return;
                cs.older = .loading;
                app.cmd(.{ .fetch_older = .{ .channel = id, .before = before } });
            },
            .load_newer => |id| {
                const cs = app.store.channel(id) orelse return;
                if (!cs.detached or cs.newer != .idle or now() < cs.newer_retry_ms) return;
                var i = cs.messages.items.len;
                const after = while (i > 0) {
                    i -= 1;
                    if (cs.messages.items[i].msg.id != 0) break cs.messages.items[i].msg.id;
                } else return;
                cs.newer = .loading;
                app.cmd(.{ .fetch_newer = .{ .channel = id, .after = after } });
            },
            .jump_present => |id| {
                const cs = app.store.channel(id) orelse return;
                const sc = st.scrollOf(id);
                sc.stick_bottom = true;
                st.jump = 0;
                st.jump_asked = 0;
                if (!cs.detached) return;
                // Enquanto a última página não chega, nada de buscar as mais novas.
                cs.newer = .loading;
                cs.around = .idle;
                app.cmd(.{ .fetch_history = id });
            },
            .fetch_around => |o| {
                const cs = app.store.channel(o.channel) orelse return;
                cs.around = .loading;
                app.cmd(.{ .fetch_around = .{ .channel = o.channel, .id = o.id } });
            },
            .jump_first_unread => |id| {
                const cs = app.store.channel(id) orelse return;
                cs.pos_unread = true;
                const first_loaded = for (cs.messages.items) |m| {
                    if (m.msg.id != 0) break m.msg.id;
                } else 0;
                // A linha já está na lista?
                if (first_loaded != 0 and (first_loaded <= cs.divider_after or cs.older == .done)) return;
                // Não está: busca em volta do que foi lido por último.
                if (cs.divider_after > 1) {
                    cs.around = .loading;
                    app.cmd(.{ .fetch_around = .{ .channel = id, .id = cs.divider_after } });
                } else {
                    // Canal nunca aberto: não há ponto de partida, vai para o topo.
                    cs.pos_unread = false;
                    const sc = st.scrollOf(id);
                    sc.stick_bottom = false;
                    sc.target = 0;
                }
            },
            .open_pins => |id| {
                st.popup = .{ .pins = .{ .channel = id } };
                app.handle(.{ .want_pins = id });
            },
            .want_pins => |id| {
                const gop = app.store.pins.getOrPut(app.store.gpa, id) catch return;
                if (!gop.found_existing) gop.value_ptr.* = .{};
                if (gop.value_ptr.state == .loading or gop.value_ptr.state == .loaded) return;
                gop.value_ptr.state = .loading;
                app.cmd(.{ .fetch_pins = id });
            },
            .forward_message => |f| app.cmd(.{ .forward_message = .{ .source_channel = f.source_channel, .source_message = f.source_message, .destination_channel = f.destination_channel } }),
            .pin_message => |p| {
                if (app.store.channel(p.channel)) |cs| if (app.store.find(cs, p.id)) |m| {
                    m.msg.pinned = p.add;
                    cs.version +%= 1;
                };
                app.cmd(.{ .pin = .{ .channel = p.channel, .id = p.id, .add = p.add } });
                // O pedido da lista vai depois deste, na mesma fila.
                if (app.store.pins.getPtr(p.channel)) |pl| pl.state = .none;
                st.showToast(now(), false, "{s}", "{s}", .{if (p.add) i18n.tr("mensagem fixada", "message pinned") else i18n.tr("mensagem desafixada", "message unpinned")});
            },
            .want_invite => |code| {
                if (app.store.invites.contains(code.slice())) return;
                app.store.putInvite(code.slice(), .{});
                app.cmd(.{ .fetch_invite = code });
            },
            .retry_history => |id| {
                const cs = app.store.channel(id) orelse return;
                if (cs.history != .failed and cs.history != .none) return;
                cs.history = .loading;
                msg_cache.restore(&app.store, cs);
                app.cmd(.{ .fetch_history = id });
            },
            .resend_message => |r| {
                const m = app.store.pendingByNonce(r.channel, r.nonce) orelse return;
                if (!m.failed) return;
                const ca = std.heap.c_allocator;
                const copy = ca.dupe(u8, m.msg.content) catch return;
                // Os anexos locais continuam na cópia pendente (file://caminho).
                var files: [][:0]const u8 = &.{};
                var n: usize = 0;
                if (m.msg.attachments.len > 0) {
                    files = ca.alloc([:0]const u8, m.msg.attachments.len) catch {
                        ca.free(copy);
                        return;
                    };
                    for (m.msg.attachments) |att| {
                        if (!std.mem.startsWith(u8, att.url, "file://")) continue;
                        files[n] = ca.dupeSentinel(u8, att.url[7..], 0) catch continue;
                        n += 1;
                    }
                    files = ca.realloc(files, n) catch files[0..n];
                }
                m.failed = false;
                m.layout_w = -1;
                app.cmd(.{ .send_message = .{ .channel = r.channel, .content = copy, .nonce = r.nonce, .reply_to = m.msg.reply_to, .files = files } });
            },
            .discard_message => |r| app.store.discardPending(r.channel, r.nonce),
            .open_friends => {
                st.guild = 0;
                st.friends = true;
            },
            .set_setting => |ss| if (settings_state.setByte(&st.settings, ss.index, ss.value)) app.saveSettings(),
            .accept_friend => |u| app.cmd(.{ .relationship = .{ .user = u, .accept = true } }),
            .remove_relationship => |u| app.cmd(.{ .relationship = .{ .user = u, .accept = false } }),
            .select_channel => |ch| {
                if (app.opts.qa and c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[ação] select_channel ctrl={}\n", .{app.io.*.KeyCtrl});
                if (app.store.channel(ch)) |cs| if (!app.store.canAccess(&cs.info)) {
                    return st.showToast(now(), true, "você não tem acesso a #{s}", "you don't have access to #{s}", .{cs.info.name});
                };
                app.openChannel(ch, app.io.*.KeyCtrl);
            },
            .focus_tab => |i| if (i < st.tabs.items.len) {
                st.tab = i;
                st.friends = false;
                if (app.store.channel(st.tabs.items[i])) |cs| {
                    st.guild = cs.info.guild;
                    if (cs.info.thread != null) app.subscribeTo(cs);
                    app.afterOpen(cs);
                }
            },
            .next_tab => |delta| if (st.tabs.items.len > 0) {
                const n: i32 = @intCast(st.tabs.items.len);
                app.handle(.{ .focus_tab = @intCast(@mod(@as(i32, @intCast(st.tab)) + delta, n)) });
            },
            .close_tab => |i| if (st.tabs.items.len > 1 and i < st.tabs.items.len) {
                _ = st.tabs.orderedRemove(i);
                if (st.tab >= st.tabs.items.len) st.tab = st.tabs.items.len - 1;
                app.handle(.{ .focus_tab = st.tab });
            },
            .send_message => |text| {
                defer app.gpa.free(text);
                // "/nome" de um plugin: roda aqui e não vai para o Discord.
                if (app.plugins.command(text)) return;
                const ch = st.activeChannel() orelse return;
                // O que foi escolhido na lista vira a menção exata (pelo ID).
                const chosen = mentions.expand(app.gpa, &app.store, app.guildOfChannel(ch), text, autocomplete.tokens()) catch return;
                defer app.gpa.free(chosen);
                autocomplete.clearTokens();
                // Regras fixas dos plugins (tirar o rastreio dos links…). Sem nenhuma, nem entra.
                const cleaned = app.plugins.rewriteOutgoing(chosen);
                defer if (cleaned) |t| app.gpa.free(t);
                app.sendTo(ch, cleaned orelse chosen, st.reply_to);
                st.reply_to = 0;
                st.drafts.remove(app.gpa, ch);
            },
            .reply => |id| {
                st.reply_to = id;
                if (st.editing != 0) {
                    st.editing = 0;
                    app.restoreDraft();
                }
                st.focus_input = true;
            },
            .edit_message => |id| {
                const f = app.store.findAny(id) orelse return;
                const text = f.m.msg.editable();
                // Não cabe na caixa: editar cortaria o fim da mensagem para sempre.
                if (text.len >= st.input.len) return st.showToast(now(), true, "mensagem longa demais para editar aqui", "message too long to edit here", .{});
                // O que estava sendo escrito fica guardado durante a edição.
                if (st.editing == 0) if (st.activeChannel()) |ch| st.drafts.put(app.gpa, ch, std.mem.sliceTo(&st.input, 0));
                @memcpy(st.input[0..text.len], text);
                st.input[text.len] = 0;
                st.editing = id;
                st.reply_to = 0;
                st.input_sync = true;
                st.focus_input = true;
            },
            .save_edit => |typed| {
                defer app.gpa.free(typed);
                const id = st.editing;
                st.editing = 0;
                app.restoreDraft();
                const f = app.store.findAny(id) orelse return;
                const ch = f.cs.info.id;
                const text = mentions.expand(app.gpa, &app.store, f.cs.info.guild, typed, autocomplete.tokens()) catch return;
                defer app.gpa.free(text);
                autocomplete.clearTokens();
                if (std.mem.eql(u8, f.m.msg.editable(), text)) return;
                // Na tela o emoji personalizado continua como `:nome:`.
                const shown = jsonx.simplifyContent(app.gpa, text) catch return;
                defer app.gpa.free(shown);
                app.store.editLocal(ch, id, shown, if (shown.len != text.len) text else null) catch return;
                const copy = std.heap.c_allocator.dupe(u8, text) catch return;
                app.cmd(.{ .edit_message = .{ .channel = ch, .id = id, .content = copy } });
            },
            .cancel_compose => {
                if (st.editing != 0) app.restoreDraft();
                st.editing = 0;
                st.reply_to = 0;
                st.focus_input = true;
            },
            .delete_thread => |id| app.cmd(.{ .delete_thread = id }),
            .pick_image => app.pickImage(),
            .restart => if (app.opts.qa) st.showToast(now(), false, "reiniciando", "restarting", .{}) else {
                app.restart_wanted = true;
            },
            .edit_place => |e| {
                // A interface aloca em gpa; a rede libera com o alocador dela.
                const ca = std.heap.c_allocator;
                var out = e;
                if (e.name) |t| {
                    defer app.gpa.free(t);
                    out.name = ca.dupe(u8, t) catch null;
                }
                if (e.description) |t| {
                    defer app.gpa.free(t);
                    out.description = ca.dupe(u8, t) catch null;
                }
                app.cmd(.{ .edit_place = out });
            },
            .delete_message => |id| {
                const f = app.store.findAny(id) orelse return;
                const ch = f.cs.info.id;
                app.store.apply(.{ .message_delete = .{ .channel = ch, .id = id, .local = true } }, now()) catch {};
                app.cmd(.{ .delete_message = .{ .channel = ch, .id = id } });
                st.showToast(now(), false, "mensagem excluída", "message deleted", .{});
            },
            .react => |r| {
                const f = app.store.findAny(r.id) orelse return;
                var mine = false;
                for (f.m.reactionSlice()) |*x| if (x.same(&r.emoji)) {
                    mine = x.me;
                };
                app.store.react(f.m, r.emoji, true, !mine);
                app.cmd(.{ .react = .{ .channel = f.cs.info.id, .id = r.id, .emoji = r.emoji, .add = !mine } });
            },
            .open_dm => |user| {
                for (app.store.channelsOf(0)) |id| if (app.store.channel(id)) |cs| if (!cs.info.group and cs.info.recipient == user) {
                    return app.openChannel(id, false);
                };
                // Ainda não tem conversa: pede ao Discord e abre quando chegar.
                st.pending_dm = user;
                app.cmd(.{ .create_dm = user });
            },
            .send_dm => |dm| {
                defer app.gpa.free(dm.text);
                app.handle(.{ .open_dm = dm.user });
                const ch = st.activeChannel() orelse return;
                if (app.store.channel(ch)) |cs| if (!cs.info.group and cs.info.recipient == dm.user) return app.sendTo(ch, dm.text, 0);
                if (st.pending_dm == dm.user) st.showToast(now(), false, "abrindo a conversa… mande de novo quando ela abrir", "opening the conversation… send it again once it opens", .{});
            },
            .copy => |text| {
                defer app.gpa.free(text);
                const z = app.gpa.dupeSentinel(u8, text, 0) catch return;
                defer app.gpa.free(z);
                _ = c.SDL_SetClipboardText(z.ptr);
                st.showToast(now(), false, "copiado ✓", "copied ✓", .{});
            },
            .jump_to => |id| {
                st.jump = id;
                st.jump_asked = 0;
            },
            .open_message => |om| {
                const cs = app.store.channel(om.channel) orelse
                    return st.showToast(now(), true, "esse canal não está disponível nesta conta", "that channel isn't available on this account", .{});
                if (!app.store.canAccess(&cs.info)) return app.handle(.{ .select_channel = om.channel });
                app.handle(.{ .select_channel = om.channel });
                if (om.id == 0) return;
                cs.pos_unread = false;
                st.jump = om.id;
                st.jump_asked = 0;
            },
            .mark_read => |id| app.markReadAction(id),
            .channel_seen => |id| app.readChannel(id, false),
            .deco_dismiss => |dd| app.plugins.dismissDeco(dd.run, dd.id),
            .mark_unread => |id| app.markUnreadAction(id),
            .typing => |id| {
                if (!st.settings.send_typing or app.store.demo) return;
                const now_ms = now();
                if (now_ms - st.typing_sent_ms < 8000) return;
                st.typing_sent_ms = now_ms;
                app.cmd(.{ .typing = id });
            },
            .toggle_voice => |ch| {
                if (st.voice != ch) if (app.store.channel(ch)) |cs| if (!app.store.canAccess(&cs.info)) {
                    return st.showToast(now(), true, "você não pode entrar em {s}", "you can't join {s}", .{cs.info.name});
                };
                if (st.voice == ch) {
                    st.voice = null;
                    st.voice_status = .disconnected;
                    st.voice_mixer = false;
                    app.resetCallState();
                    voz_audio.play(.leave);
                    app.cmd(.{ .join_voice = .{ .guild = st.voice_guild, .channel = null, .mute = st.muted, .deaf = st.deafened } });
                } else {
                    const cs = app.store.channel(ch) orelse return;
                    if (cs.info.kind != .voice) return;
                    st.voice = ch;
                    st.voice_guild = cs.info.guild;
                    st.voice_status = .connecting;
                    st.voice_mixer = false;
                    app.resetCallState();
                    app.cmd(.{ .join_voice = .{ .guild = cs.info.guild, .channel = ch, .mute = st.muted, .deaf = st.deafened } });
                    var vit = st.voice_volumes.iterator();
                    while (vit.next()) |e| app.cmd(.{ .voice_volume = .{ .user = e.key_ptr.*, .volume = e.value_ptr.* } });
                }
            },
            .leave_voice => {
                if (st.voice != null) voz_audio.play(.leave);
                app.resetCallState();
                st.voice = null;
                st.voice_status = .disconnected;
                st.voice_mixer = false;
                app.cmd(.{ .join_voice = .{ .guild = st.voice_guild, .channel = null, .mute = st.muted, .deaf = st.deafened } });
            },
            .toggle_mute => {
                st.muted = !st.muted;
                if (st.voice != null) voz_audio.play(if (st.muted) .mute else .unmute);
                if (st.voice != null) app.cmd(.{ .voice_flags = .{ .mute = st.muted, .deaf = st.deafened } });
            },
            .toggle_deafen => {
                st.deafened = !st.deafened;
                if (st.deafened) st.muted = true;
                if (st.voice != null) voz_audio.play(if (st.deafened) .mute else .unmute);
                if (st.voice != null) app.cmd(.{ .voice_flags = .{ .mute = st.muted, .deaf = st.deafened } });
            },
            .toggle_voice_mixer => st.voice_mixer = !st.voice_mixer,
            .set_voice_volume => |vv| {
                const val = std.math.clamp(vv.volume, 0, 2);
                st.voice_volumes.put(app.gpa, vv.user, val) catch {};
                app.cmd(.{ .voice_volume = .{ .user = vv.user, .volume = val } });
                const ms = now();
                if (ms - st.voice_save_ms > 2000) {
                    st.voice_save_ms = ms;
                    app.saveSettings();
                }
            },
            .create_thread => |ct| {
                defer app.gpa.free(ct.name);
                const f = app.store.findAny(ct.message) orelse return;
                const ca = std.heap.c_allocator;
                const name = ca.dupe(u8, ct.name) catch return;
                app.cmd(.{ .create_thread = .{ .channel = f.cs.info.id, .message = ct.message, .name = name } });
            },
            .create_post => |cp| {
                defer {
                    app.gpa.free(cp.name);
                    app.gpa.free(cp.content);
                    app.gpa.free(cp.tags);
                }
                const ca = std.heap.c_allocator;
                const name = ca.dupe(u8, cp.name) catch return;
                const content = ca.dupe(u8, cp.content) catch return ca.free(name);
                const tags = ca.dupe(types.Id, cp.tags) catch {
                    ca.free(name);
                    ca.free(content);
                    return;
                };
                app.cmd(.{ .create_post = .{ .forum = cp.forum, .name = name, .content = content, .tags = tags } });
            },
            .join_thread => |jt| app.cmd(.{ .join_thread = .{ .thread = jt.thread, .join = jt.join } }),
            .fetch_threads => |ft| {
                const cs = app.store.channel(ft.channel) orelse return;
                const page = if (ft.archived) &cs.archived_page else &cs.active_page;
                if (page.state == .loading) return;
                // Sem nenhuma página ainda: começa do começo.
                if (page.state != .loaded) page.* = .{};
                page.state = .loading;
                app.cmd(.{ .fetch_threads = .{ .channel = ft.channel, .guild = cs.info.guild, .archived = ft.archived, .offset = page.offset, .before = page.before } });
            },
            .toggle_category => |id| {
                if (st.collapsed.contains(id)) _ = st.collapsed.remove(id) else st.collapsed.put(app.gpa, id, {}) catch {};
            },
            .set_theme => |i| app.setTheme(i),
            .set_theme_option => |o| {
                const th = app.themes.theme_();
                if (o.index >= th.options.len) return;
                // O nome vive na arena do tema, que vai ser trocado ao recarregar.
                var buf: [64]u8 = undefined;
                const name = buf[0..@min(buf.len, th.options[o.index].name.len)];
                @memcpy(name, th.options[o.index].name[0..name.len]);
                if (app.themes.setOption(name, o.value)) app.applyThemeStyle();
                app.saveSettings();
            },
            .set_theme_color => |cc| app.setThemeColor(cc.slot, cc.rgba),
            .reset_theme_colors => app.resetThemeColors(),
            .set_guild_color => |gc| {
                guild_color.set(gc.guild, gc.rgb);
                app.saveSettings();
            },
            .next_theme => |delta| {
                const n: i32 = @intCast(app.themes.entries.items.len);
                app.setTheme(@intCast(@mod(@as(i32, @intCast(app.themes.current)) + delta, n)));
            },
            .open_palette => {
                st.palette.open = true;
                st.palette.focus = false;
                @memset(&st.palette.query, 0);
                st.palette.selected = 0;
            },
            .close_palette => {
                st.palette.open = false;
                st.focus_input = true;
            },
            .open_settings => {
                st.palette.open = false;
                st.settings.open = true;
            },
            .close_settings => {
                st.settings.open = false;
                st.focus_input = true;
                app.saveSettings();
            },
            .save_settings => app.saveSettings(),
            .pick_files => app.pickFiles(),
            .remove_upload => |i| if (i < st.uploads.items.len) {
                dropUpload(st.uploads.items[i].path);
                _ = st.uploads.orderedRemove(i);
            },
            .paste_image => app.pasteImage(),
            .toggle_inbox => {
                st.palette.open = false;
                if (st.popup == .inbox) {
                    st.popup = .none;
                    st.focus_input = true;
                    return;
                }
                st.popup = .{ .inbox = .{} };
                // Prévia das DMs não lidas que ainda não foram abertas.
                var want: [6]types.Id = undefined;
                for (inbox_core.prefetch(&app.store, &st.muted_channels, &st.filtros, &want)) |id| app.cmd(.{ .fetch_history = id });
            },
            .toggle_saved => {
                st.palette.open = false;
                st.popup = if (st.popup == .saved) .none else .saved;
                if (st.popup == .none) st.focus_input = true;
            },
            .fetch_mentions => if (app.store.mentions_state != .loading) {
                app.store.mentions_state = .loading;
                app.cmd(.fetch_mentions);
            },
            .save_message => |id| switch (st.saved.add(app.gpa, &app.store, id, @divTrunc(now(), 1000)) catch .missing) {
                .added => {
                    app.persistSaved();
                    st.showToast(now(), false, "mensagem salva ✓ (Ctrl+Shift+S mostra as salvas)", "message saved ✓ (Ctrl+Shift+S shows them)", .{});
                },
                .already => st.showToast(now(), false, "essa mensagem já está nas salvas", "that message is already saved", .{}),
                .full => st.showToast(now(), true, "limite de {d} mensagens salvas", "limit of {d} saved messages", .{@import("core/saved.zig").max_items}),
                .missing => {},
            },
            .unsave_message => |id| if (st.saved.remove(app.gpa, id)) {
                app.persistSaved();
                st.showToast(now(), false, "removida das salvas", "removed from saved", .{});
            },
            .saved_note => |sn| {
                defer app.gpa.free(sn.text);
                if (st.saved.setNote(app.gpa, sn.id, sn.text) catch false) app.persistSaved();
            },
            .logout, .switch_account, .add_account, .remove_account => app_accounts.handle(app, a),
            .clear_cache => {
                msg_cache.clearAll(&app.store);
                st.showToast(now(), false, "cache apagado", "cache cleared", .{});
            },
        }
    }

    // --- Laço ----------------------------------------------------------------

    fn drainEvents(app: *App) void {
        var batch: std.ArrayList(ev.Event) = .empty;
        defer batch.deinit(app.gpa);
        app.events.drain(&batch);
        const was_ready = app.store.ready;
        var failed = false;
        var token_dead = false;
        var reconnected = false;
        var new_session = false;
        for (batch.items) |e| {
            if (e == .status and e.status == .ready) reconnected = true;
            if (e == .ready and was_ready) new_session = true;
            if (e == .notice) {
                app.st.showToast(now(), true, "{s}", "{s}", .{e.notice});
                const n = @min(e.notice.len, app.last_notice.len);
                @memcpy(app.last_notice[0..n], e.notice[0..n]);
                app.last_notice_len = n;
            }
            if (e == .voice_status) {
                const mine = e.voice_status.channel == 0 or app.st.voice == e.voice_status.channel;
                if (mine) {
                    const was_connected = app.st.voice_status == .connected;
                    app.st.voice_status = e.voice_status.status;
                    if (e.voice_status.status == .disconnected and app.st.voice != null) {
                        // Sai de verdade (op 4 sem canal): senão os outros
                        // continuam vendo a gente parado na call.
                        app.handle(.leave_voice);
                        app.st.showToast(now(), true, "a call caiu", "the call dropped", .{});
                    } else if (e.voice_status.status == .connected) {
                        app.st.showToast(now(), false, "entrou na call", "joined the call", .{});
                        if (!was_connected) voz_audio.play(.join);
                    }
                }
            }
            // Movido de canal por alguém (ou tirado da call): segue o servidor.
            if (e == .voice_state and e.voice_state.user == app.store.me and app.st.voice != null and app.store.me != 0) {
                if (e.voice_state.channel) |ch| {
                    app.st.voice = ch;
                    app.serverFlags(e.voice_state.flags);
                } else {
                    voz_audio.play(.leave);
                    app.resetCallState();
                    app.st.voice = null;
                    app.st.voice_status = .disconnected;
                    app.st.voice_mixer = false;
                }
            }
            if (e == .voice_ping) app.st.voice_ping_ms = e.voice_ping;
            if (e == .voice_audio) app.voiceAudio(e.voice_audio.mic_ok, e.voice_audio.out_ok);
            if (e == .history) timeline.mark(.historico);
            if (e == .status and e.status == .failed) failed = true;
            if (e == .status and e.status == .rejected) token_dead = true;
            // Antes de o Store ficar com a mensagem (se o canal não existe, ele a libera).
            const quiet: ?types.Id = if (e == .message_create and app.store.ready) app.incoming(e.message_create) else null;
            if (e == .message_create and app.store.ready) plugin_host.onMessage(app, e.message_create);
            if (e == .message_delete) plugin_host.onDelete(app, e.message_delete.channel, e.message_delete.id);
            const edited: types.Id = if (e == .message_update and e.message_update.content != null) e.message_update.id else 0;
            if (app.opts.stats) switch (e) {
                .status => |st| std.log.info("conexão: {t}", .{st}),
                .notice => |n| std.log.info("aviso: {s}", .{n}),
                .latency => |l| std.log.info("ping: {d} ms", .{l}),
                .ready => |r| std.log.info("READY: {d} servidores, {d} canais, {d} usuários", .{ r.guilds.len, r.channels.len, r.users.len }),
                else => {},
            };
            app.store.apply(e, now()) catch {};
            if (edited != 0) plugin_host.onEdit(app, edited);
            if (quiet) |ch| app.st.filtros.quiet(app.gpa, &app.store, ch);
            app.afterEvent(e);
            if (e == .thread_open) app.openChannel(e.thread_open, false);
        }
        if (!was_ready and app.store.ready) {
            // O Discord aceitou: agora sim guarda a conta (e o token, se pediram).
            // Antes do resto: abrir um canal já lê o cache desta conta.
            app_accounts.ready(app);
            app.onReady();
            app.plugins.fireReady();
            // A conversa aparece já neste quadro: nada de esperar uma animação.
            if (app.login.phase == .connecting) app.login.phase = .hidden;
            timeline.mark(.store);
            // O texto do READY e a arena dele já foram: devolve a memória ao sistema.
            app.trim_wanted.store(true, .release);
        } else if (reconnected and was_ready) {
            // Voltou a conexão: as conversas que ficaram só no cache do disco
            // (abertas sem rede) buscam o histórico de novo.
            var it = app.store.channels.valueIterator();
            while (it.next()) |p| {
                const cs = p.*;
                // O que veio antes da queda pode ter mudado: a página pede de novo.
                if (cs.info.kind == .forum) {
                    cs.active_page = .{};
                    cs.archived_page = .{};
                    continue;
                }
                if (cs.cached or cs.history == .failed) {
                    if (cs.history == .failed) cs.history = .loading;
                    app.cmd(.{ .fetch_history = cs.info.id });
                } else if (new_session and cs.history == .loaded) {
                    // Sessão nova: o Discord não repete o que passou enquanto
                    // estávamos fora, e a conversa ficaria com um buraco.
                    const open = std.mem.indexOfScalar(types.Id, app.st.tabs.items, cs.info.id) != null;
                    const unsent = for (cs.messages.items) |m| {
                        if (m.pending) break true;
                    } else false;
                    // Lendo o passado: aquela página continua valendo.
                    if (open or unsent) {
                        if (!cs.detached) app.cmd(.{ .fetch_history = cs.info.id });
                    } else app.store.unload(cs);
                }
            }
        }
        if (failed and app.net == .real) {
            // Token recusado (ou erro fatal), antes de entrar ou com a conversa aberta.
            app_accounts.sessionRefused(app, token_dead, if (app.last_notice_len > 0) app.last_notice[0..app.last_notice_len] else i18n.tr("Não deu pra entrar com esse token.", "Couldn't sign in with that token."));
            return;
        }
        // GUILD_DELETE/CHANNEL_DELETE: não deixa a interface apontando para
        // um servidor ou aba que o Discord acabou de tirar.
        if (app.st.guild != 0 and app.store.guild(app.st.guild) == null) app.st.guild = 0;
        var i: usize = 0;
        while (i < app.st.tabs.items.len) {
            if (app.store.channel(app.st.tabs.items[i]) != null) {
                i += 1;
                continue;
            }
            _ = app.st.tabs.orderedRemove(i);
            if (i < app.st.tab) app.st.tab -= 1;
        }
        if (app.st.tabs.items.len == 0) {
            app.st.tab = 0;
        } else if (app.st.tab >= app.st.tabs.items.len) {
            app.st.tab = app.st.tabs.items.len - 1;
        }
        // A DM que pedimos chegou: abre.
        if (app.st.pending_dm != 0) {
            for (app.store.channelsOf(0)) |id| if (app.store.channel(id)) |cs| if (!cs.info.group and cs.info.recipient == app.st.pending_dm) {
                app.st.pending_dm = 0;
                app.openChannel(id, false);
                break;
            };
        }
    }

    /// O que o estado de leitura faz com um evento já aplicado no Store. (O que
    /// chega no canal aberto é lido pela conversa: ver `channel_seen`.)
    fn afterEvent(app: *App, e: ev.Event) void {
        const st = &app.st;
        switch (e) {
            .read_states => |rs| {
                leitura.applyMuted(&app.store, &st.muted_channels, app.gpa, rs.muted);
                if (rs.muted.len > 0) std.heap.c_allocator.free(rs.muted);
                leitura.applyReady(&app.store, &st.filtros, app.gpa, now());
                // A conversa já abriu antes de o registro chegar.
                if (st.activeChannel()) |ch| if (app.store.channel(ch)) |cs| {
                    cs.divider_after = 0;
                    app.prepareUnread(cs);
                };
            },
            .guild_create => |gc| leitura.applyGuild(&app.store, &st.filtros, app.gpa, gc.guild.id, now()),
            .read => |r| {
                const cs = app.store.channel(r.channel) orelse return;
                if (store_mod.read_debug) std.log.info("leitura: ack do Discord no canal {d}: até {d}, menções {?d}, manual {}", .{ r.channel, r.message, r.mentions, r.manual });
                if (!cs.info.unread) {
                    st.filtros.clear(&app.store, r.channel);
                } else if (r.mentions) |n| st.filtros.setCount(app.gpa, &app.store, r.channel, n);
                // "Não lida" marcada em outro aparelho, com o canal aberto aqui.
                if (r.manual and cs.info.unread and st.activeChannel() == r.channel) {
                    cs.divider_after = @max(cs.read_id, 1);
                    cs.divider_seen = false;
                }
            },
            // Falar é ter lido: o contador zera junto.
            .message_create => |m| if (m.author == app.store.me) st.filtros.clear(&app.store, m.channel),
            else => {},
        }
    }

    /// Mensagem de outra pessoa chegando: ignorada/filtrada não notifica nem
    /// conta; DM, menção ou palavra de alerta conta no canal e notifica.
    /// Retorna o canal que o modo foco deixa sem "não lido" por enquanto.
    fn incoming(app: *App, m: types.Message) ?types.Id {
        const f = &app.st.filtros;
        if (m.author == app.store.me) return null;
        const cs = app.store.channel(m.channel) orelse return null;
        const verdict = f.judge(m.author, m.content, cs.info.guild == 0, app.mentionsMe(m, cs.info.guild));
        if (verdict == .important) {
            f.bump(app.gpa, &app.store, m.channel);
            if (!app.st.muted_channels.contains(m.channel)) {
                f.notified +%= 1;
                app.notify(m, cs);
            }
        }
        if (verdict != .important and f.focusOn(now()) and !cs.info.unread and app.st.activeChannel() != m.channel) return m.channel;
        return null;
    }

    /// DM ou menção chegando sem a pessoa olhando: a janela pisca na barra
    /// de tarefas e sai uma notificação do sistema (notify-send).
    fn notify(app: *App, m: types.Message, cs: *const @import("core/store.zig").ChannelState) void {
        if (app.opts.qa or app.store.demo) return;
        const set = &app.st.settings;
        const flags = c.SDL_GetWindowFlags(app.win.window);
        const hidden = flags & c.SDL_WINDOW_HIDDEN != 0;
        const focused = !hidden and flags & c.SDL_WINDOW_INPUT_FOCUS != 0;
        if (focused and app.st.activeChannel() == m.channel) return;
        if (set.taskbar_flash and !focused and !hidden) _ = c.SDL_FlashWindow(app.win.window, c.SDL_FLASH_UNTIL_FOCUSED);
        if (!set.desktop_notifs or focused or app.notifiers.items.len >= 8) return;

        const who = if (app.store.user(m.author)) |u| u.name else "?";
        var tb: [160]u8 = undefined;
        const title = if (cs.info.guild == 0 and !cs.info.group)
            std.fmt.bufPrintSentinel(&tb, "{s}", .{who}, 0) catch return
        else
            std.fmt.bufPrintSentinel(&tb, "{s} ({s}{s})", .{ who, if (cs.info.guild == 0) "" else "#", cs.info.name }, 0) catch return;
        // Texto curto, cortado sem quebrar um caractere no meio.
        var body_src: []const u8 = m.content;
        if (body_src.len == 0 and m.attachments.len > 0) body_src = i18n.tr("[anexo]", "[attachment]");
        var cut = @min(body_src.len, 200);
        while (cut > 0 and cut < body_src.len and (body_src[cut] & 0xC0) == 0x80) cut -= 1;
        var bb: [208]u8 = undefined;
        const body = std.fmt.bufPrintSentinel(&bb, "{s}{s}", .{ body_src[0..cut], if (cut < body_src.len) "…" else "" }, 0) catch return;
        app.desktopNotify(title, body);
    }

    /// Uma notificação do sistema: notify-send no Linux, o aviso da bandeja no Windows.
    pub fn desktopNotify(app: *App, title: [:0]const u8, body: [:0]const u8) void {
        if (app.notifiers.items.len >= 8) return;
        if (sys.windows) return sys.toast(c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(app.win.window), c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null), now(), title, body);
        var args = [_:null]?[*:0]const u8{ "notify-send", "--app-name=larperCord", "--", title.ptr, body.ptr };
        const proc = c.SDL_CreateProcess(@ptrCast(&args), false) orelse return;
        app.notifiers.append(app.gpa, proc) catch c.SDL_DestroyProcess(proc);
    }

    /// A mensagem chama a gente: quem decide é o servidor, que já desconta
    /// bloco de código e quem não tem permissão de usar @everyone.
    fn mentionsMe(app: *App, m: types.Message, guild: types.Id) bool {
        if (m.mention_everyone or m.mentions_me) return true;
        // Menção a um cargo nosso (`<@&id>`).
        var rest = m.content;
        while (std.mem.indexOf(u8, rest, "<@&")) |i| {
            rest = rest[i + 3..];
            const end = std.mem.indexOfScalar(u8, rest, '>') orelse break;
            const role = std.fmt.parseInt(types.Id, rest[0..end], 10) catch continue;
            if (app.store.hasRole(guild, role)) return true;
        }
        // A demonstração não tem os campos do servidor.
        if (!app.store.demo) return false;
        var b: [32]u8 = undefined;
        const a = std.fmt.bufPrint(&b, "<@{d}>", .{app.store.me}) catch return false;
        if (std.mem.indexOf(u8, m.content, a) != null) return true;
        return std.mem.indexOf(u8, m.content, "@everyone") != null or std.mem.indexOf(u8, m.content, "@here") != null;
    }

    /// Recolhe os notify-send que já terminaram (sem deixar processo zumbi).
    fn reapNotifiers(app: *App) void {
        var i: usize = 0;
        while (i < app.notifiers.items.len) {
            const p = app.notifiers.items[i];
            if (c.SDL_WaitProcess(p, false, null)) {
                c.SDL_DestroyProcess(p);
                _ = app.notifiers.swapRemove(i);
            } else i += 1;
        }
    }

    /// Paleta de destaque das configurações (índice 1..8).
    pub const accents = [_]u32{ 0x5865F2, 0x3BA55C, 0xF0B232, 0xED4245, 0xEB459E, 0x9B59B6, 0x1ABC9C, 0xE67E22 };

    /// O tema do quadro: o atual, ou uma cópia com a cor de destaque e os
    /// cantos escolhidos nas configurações (vale para todos os temas).
    pub fn customTheme(app: *App) *const theme_mod.Theme {
        const base = app.themes.theme_();
        const set = &app.st.settings;
        const ovs = app.theme_colors.getPtr(app.themes.name());
        const has_colors = if (ovs) |o| o.atConst(app.themes.mode).any() else false;
        const gcol = guild_color.get(app.st.guild);
        if (set.accent == 0 and set.corners == 0 and !has_colors and gcol == null) return base;
        app.th_custom = base.*;
        if (set.accent > 0 and set.accent <= accents.len) {
            const col = d.Rgba.hex(accents[set.accent - 1]);
            app.th_custom.colors.set(.accent, col);
            // Texto em cima do destaque: preto ou branco, o que contrastar mais.
            const lum = 0.2126 * col.r + 0.7152 * col.g + 0.0722 * col.b;
            app.th_custom.colors.set(.accent_text, if (lum > 0.6) d.Rgba.black else d.Rgba.white);
        }
        switch (set.corners) {
            1 => app.th_custom.radius = 0,
            2 => app.th_custom.radius = 6,
            3 => app.th_custom.radius = 12,
            else => {},
        }
        // Cores personalizadas do tema/modo têm a palavra final.
        if (ovs) |o| custom.apply(&app.th_custom, o.atConst(app.themes.mode));
        // A cor do servidor aberto vale por cima de tudo (é a escolha mais específica).
        if (gcol) |rgb| guild_color.apply(&app.th_custom, rgb);
        return &app.th_custom;
    }

    fn setThemeColor(app: *App, slot: u8, rgba: ?u32) void {
        const name = app.themes.name();
        if (rgba) |v| {
            const ovs = app.themeOverridesFor(name) orelse return;
            ovs.at(app.themes.mode).set(slot, v);
        } else if (app.theme_colors.getPtr(name)) |ovs| {
            ovs.at(app.themes.mode).set(slot, null);
            if (!ovs.any()) {
                if (app.theme_colors.fetchRemove(name)) |kv| app.gpa.free(kv.key);
            }
        }
        app.saveSettings();
        app.applyImGuiColors(app.customTheme());
    }

    fn resetThemeColors(app: *App) void {
        if (app.theme_colors.fetchRemove(app.themes.name())) |kv| app.gpa.free(kv.key);
        app.saveSettings();
        app.applyImGuiColors(app.customTheme());
    }

    /// Mensagens salvas no arquivo (os prints não gravam nada).
    fn persistSaved(app: *App) void {
        if (app.opts.shot == null) saved_ui.persist(&app.st.saved, app.gpa);
    }

    fn onReady(app: *App) void {
        // As salvas desta conta (o QA e os prints começam sem nenhuma).
        saved_ui.load(&app.st.saved, app.gpa, app.store.me, !app.opts.qa and app.opts.shot == null);
        app.plugins.setAccount(app.store.me);
        // O status escolhido da última vez (o Discord começa em online).
        if (app.st.settings.my_status != 0) app.handle(.{ .set_status = @fromBackingInt(@intCast(@min(app.st.settings.my_status, 3))) });
        if (!app.store.demo) {
            // Conta real: começa pelas DMs (ou pelo primeiro servidor).
            const g0: types.Id = if (app.store.channelsOf(0).len > 0) 0 else if (app.store.guilds.items.len > 0) app.store.guilds.items[0].id else 0;
            app.handle(.{ .select_guild = g0 });
            return;
        }
        const g0 = app.store.guilds.items[0].id;
        app.st.guild = g0;
        // Algumas abas abertas para mostrar o recurso.
        for ([_]usize{ 4, 9, 5 }) |ci| app.openChannel(gw.channelId(0, ci), true);
        app.handle(.{ .focus_tab = 0 });
        const call = gw.channelId(0, 13);
        _ = call;
    }

    /// Monta uma cena para prints de documentação (LARPER_SCENE=…): abre
    /// popups e posiciona o mouse, já que o print não tem ninguém clicando.
    fn scene(app: *App, settled: bool) void {
        const which = std.mem.span(c.SDL_getenv("LARPER_SCENE") orelse return);
        // "firstdm": abre a primeira DM (mede a área de mensagens diretas).
        if (std.mem.eql(u8, which, "firstdm")) {
            const F = struct {
                var done = false;
            };
            if (!F.done and app.store.channelsOf(0).len > 0) {
                F.done = true;
                app.openChannel(app.store.channelsOf(0)[0], false);
            }
            return;
        }
        // "msg:<servidor>:<canal>:<mensagem>": vai até uma mensagem (conferir como
        // ela aparece na conta de verdade). Sem foco: abrir não marca como lido.
        if (std.mem.startsWith(u8, which, "msg:")) {
            const M = struct {
                var step: u8 = 0;
            };
            app.qa_blur = true;
            var it = std.mem.splitScalar(u8, which[4..], ':');
            const gid = std.fmt.parseInt(types.Id, it.next() orelse return, 10) catch return;
            const cid = std.fmt.parseInt(types.Id, it.next() orelse return, 10) catch return;
            const mid = std.fmt.parseInt(types.Id, it.next() orelse return, 10) catch return;
            if (M.step == 0 and app.store.guild(gid) != null) {
                M.step = 1;
                app.handle(.{ .select_guild = gid });
                app.openChannel(cid, false);
            } else if (M.step == 1) if (app.store.channel(cid)) |cs| if (cs.history == .loaded) {
                M.step = 2;
                app.handle(.{ .fetch_around = .{ .channel = cid, .id = mid } });
                app.handle(.{ .jump_to = mid });
            };
            return;
        }
        // "guild": abre o primeiro servidor (testa histórico e lista de membros).
        if (std.mem.eql(u8, which, "guild")) {
            const G = struct {
                var done = false;
            };
            if (!G.done and app.store.guilds.items.len > 0) {
                G.done = true;
                app.handle(.{ .select_guild = app.store.guilds.items[0].id });
            }
            return;
        }
        // "voice": entra numa call e abre o mixer para o print.
        if (std.mem.eql(u8, which, "voice")) {
            const V = struct {
                var done = false;
            };
            if (!V.done) {
                V.done = true;
                if (app.store.guilds.items.len > 0) app.handle(.{ .select_guild = app.store.guilds.items[0].id });
                app.handle(.{ .toggle_voice = gw.channelId(0, 13) });
                app.st.popup = .{ .mixer = .{ .x = 90, .y = 410 } };
            }
            return;
        }
        // As outras cenas esperam a conversa carregar.
        if (!settled) return;
        const ch = app.st.activeChannel() orelse return;
        const cs = app.store.channel(ch) orelse return;
        const items = cs.messages.items;
        if (items.len < 4) return;
        const last = &items[items.len - 1];
        const prev = &items[items.len - 3];
        const S = struct {
            var done = false;
        };
        if (std.mem.eql(u8, which, "hover")) c.ImGuiIO_AddMousePosEvent(app.io, 700, 690);
        if (S.done) return;
        S.done = true;
        if (std.mem.eql(u8, which, "menu")) {
            app.st.popup = .{ .menu = .{ .kind = .message, .id = prev.msg.id, .x = 620, .y = 330 } };
        } else if (std.mem.eql(u8, which, "profile")) {
            app.st.popup = .{ .profile = .{ .user = 1001, .x = 700, .y = 200 } };
        } else if (std.mem.eql(u8, which, "emoji")) {
            app.st.popup = .{ .emoji = .{ .target = 0, .x = 1000, .y = 730 } };
        } else if (std.mem.eql(u8, which, "reply")) {
            app.handle(.{ .reply = prev.msg.id });
            const t = i18n.tr("isso aqui tá **muito** bom 😍", "this is **really** good 😍");
            @memcpy(app.st.input[0..t.len], t);
            app.st.input_sync = true;
        } else if (std.mem.eql(u8, which, "select")) {
            app.st.selection = .{ .channel = ch, .a_id = prev.msg.id, .a_off = 3, .b_id = last.msg.id, .b_off = @intCast(@min(last.msg.content.len, 12)) };
        } else if (std.mem.eql(u8, which, "opcoes")) {
            app.st.settings.open = true;
            app.st.settings.page = .aparencia;
            c.ImGuiIO_AddMouseWheelEvent(app.io, 0, -6);
            c.ImGuiIO_AddMousePosEvent(app.io, 900, 400);
        } else if (std.mem.eql(u8, which, "dm")) {
            app.handle(.{ .select_guild = 0 });
        }
    }

    var prof_frame: u64 = 0;
    var prof_render: u64 = 0;
    var prof_gpu: u64 = 0;
    var prof_cmds: u64 = 0;
    var prof_texs: u64 = 0;
    var prof_vtx: u64 = 0;
    // --stats: por que cada quadro foi feito, e que eventos e ações pediram quadros.
    var prof_why: [7]u32 = @splat(0);
    var prof_events: [8]struct { t: u32 = 0, n: u32 = 0 } = @splat(.{});
    var prof_actions: std.enums.EnumArray(std.meta.Tag(ev.Action), u32) = .initFill(0);

    fn profEvent(t: u32) void {
        for (&prof_events) |*pe| if (pe.n == 0 or pe.t == t) {
            pe.t = t;
            pe.n += 1;
            return;
        };
    }

    pub fn run(app: *App) bool {
        if (!app.opts.qa and app.opts.shot == null and app.st.settings.check_updates) updater.check();
        const Runner = if (qa_mod.compiled) @import("qa_runner.zig").Runner else struct {
            fail: u32 = 0,
            fn holdMouse(_: *@This(), _: *App) void {}
            fn tick(_: *@This(), _: *App) bool {
                return false;
            }
        };
        var runner: Runner = .{};
        @import("ui/root.zig").profile = app.opts.stats;
        widgets.no_pics = c.SDL_getenv("LARPER_NO_PICS") != null;
        widgets.square_pics = c.SDL_getenv("LARPER_SQUARE") != null;
        if (app.opts.qa) {
            qa_mod.enable();
            _ = c.SDL_CreateDirectory("qa-out");
        }
        var pending: u32 = 3;
        var running = true;
        var last = c.SDL_GetTicksNS();
        var frames: u32 = 0;
        var settled_frames: u32 = 0;
        var first_frame_logged = false;
        var login_result: ?login_mod.Result = null;
        var lang_setting: i16 = -1;
        // LARPER_BENCH=1: redesenha sem parar (medir o custo de um quadro parado).
        const bench = c.SDL_getenv("LARPER_BENCH") != null;
        store_mod.read_debug = c.SDL_getenv("LARPER_READ_DEBUG") != null;
        // O que chega da rede (presença, digitando, lista de membros) redesenha
        // no máximo a cada `bg_frame_ms`; o mouse só andando, a cada
        // `MousePace.interval_ms`; clique, roda e teclado redesenham na hora.
        const bg_frame_ms: i64 = 50;
        var bg_dirty = false;
        var mouse: ritmo.MousePace = .{};
        var hidden_since_ms: i64 = 0;
        var skipped_in_row: u32 = 0;
        var last_frame_ms: i64 = 0;
        var typing_check_ms: i64 = 0;
        var was_active = false;
        // LARPER_RECORD=pasta: salva cada quadro da tela de login (a 30 qps fixos)
        // para montar o vídeo/GIF da documentação.
        const record_dir: ?[*:0]const u8 = c.SDL_getenv("LARPER_RECORD");
        var record_n: u32 = 0;

        while (running) {
            // Reinício pedido: sai como qualquer "Sair", sem passar pela bandeja.
            if (app.restart_wanted) {
                _ = c.SDL_HideWindow(app.win.window);
                break;
            }
            var e: c.SDL_Event = undefined;
            // O relógio do sistema andou para trás: sem isso, o quadro adiado
            // só viria quando ele alcançasse a hora antiga.
            if (last_frame_ms > now()) last_frame_ms = now();
            // Janela minimizada ou coberta: ninguém vê. Os eventos da rede são
            // tratados; ao voltar, o SDL avisa e o quadro sai certo.
            const hidden_flags = c.SDL_WINDOW_MINIMIZED | c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_OCCLUDED;
            const unseen = c.SDL_GetWindowFlags(app.win.window) & hidden_flags != 0 and !app.opts.qa and app.opts.shot == null and !bench and record_dir == null;
            // A tela de login anima sem parar: no máximo 60 quadros por segundo.
            const login_anim = app.login.visible() and !unseen;
            if (login_anim and !app.opts.qa and app.opts.shot == null and !bench and record_dir == null) {
                const since_frame = now() - last_frame_ms;
                if (since_frame < 16) c.SDL_Delay(@intCast(16 - since_frame));
            }
            // Com o mouse andando, a animação de destaque também espera o limite dele:
            // é o que mais pede quadro, e só volta ao ritmo da tela quando o mouse para.
            const busy = pending > 0 or (anim.active and !mouse.wanted()) or app.opts.shot != null or app.opts.qa or bench or
                (login_anim and !app.st.settings.reduce_motion);
            // Dorme até o próximo quadro de um GIF, de uma animação lenta ou
            // do redesenho adiado da rede (o que vier primeiro).
            var due = @min(app.images.next_frame_ms, anim.next_wake_ms);
            if (bg_dirty) due = @min(due, last_frame_ms + bg_frame_ms);
            if (mouse.wanted()) due = @min(due, last_frame_ms + ritmo.MousePace.interval_ms);
            const wait = due -| now();
            var got = if (busy or wait <= 0)
                c.SDL_PollEvent(&e)
            else if (due != std.math.maxInt(i64))
                c.SDL_WaitEventTimeout(&e, @intCast(@min(wait, 1000)))
            else
                c.SDL_WaitEvent(&e);
            // Acordou só porque o teto de 1 s da espera venceu.
            const timed_out = !got and !busy and wait > 0;
            var input = false;
            while (got) {
                if (e.type == app.win.wake_type) {
                    switch (@as(platform.Wake, @fromBackingInt(@intCast(e.user.code)))) {
                        .gateway => {
                            app.gw_signaled.store(false, .release);
                            app.drainEvents();
                            bg_dirty = true;
                        },
                        .theme => if (!app.st.settings.hot_reload) {} else if (app.themes.reload()) {
                            app.applyThemeStyle();
                            app.st.showToast(now(), false, "tema recarregado: {s}", "theme reloaded: {s}", .{app.themes.name()});
                        } else app.st.showToast(now(), true, "{s}", "{s}", .{app.themes.last_error orelse i18n.tr("erro no tema", "theme error")}),
                        .tick => {
                            pending = @max(pending, 1);
                            // O relógio já acorda o app: aproveita para gravar o cache
                            // (umas poucas por vez; sobrando, volta no próximo tique).
                            if (now() - app.cache_flush_ms >= 60_000) {
                                app.cache_flush_ms = now();
                                if (msg_cache.flushSome(&app.store, 4)) app.cache_flush_ms -= 50_000;
                            }
                            sys.toastExpire(now(), false);
                            // Por garantia: um aviso dos plugins pode ter se perdido com a fila cheia.
                            app.plugins.drain();
                            // O painel sumiu com a janela escondida (fechou, travou):
                            // a janela volta em vez de ficar sem caminho de volta.
                            if (tray.active()) {
                                app.tray_misses = if (tray.hostAvailable()) 0 else app.tray_misses + 1;
                                if (app.tray_misses >= janela.tray_misses_max) app.showWindow();
                            }
                        },
                        .media => bg_dirty = true,
                        .token => {
                            timeline.mark(.token_fim);
                            app_accounts.finishStartupLookup(app);
                            pending = 3;
                        },
                        .show => {
                            app.showWindow();
                            app.gate.redraw();
                            pending = 3;
                        },
                        .quit => running = false,
                        .plugins => {
                            app.plugins.drain();
                            pending = @max(pending, 2);
                        },
                    }
                } else {
                    // Sem botão apertado, passar por cima das coisas pode esperar o
                    // próximo quadro (o ImGui guarda onde o mouse está).
                    if (e.type == c.SDL_EVENT_MOUSE_MOTION and e.motion.state == 0) {
                        mouse.motion();
                    } else {
                        input = true;
                        if (app.opts.stats) profEvent(e.type);
                    }
                    // A janela mudou ou o contexto foi refeito: o que está na tela
                    // não vale mais, mesmo que o próximo quadro saia igual.
                    if ((e.type >= c.SDL_EVENT_WINDOW_FIRST and e.type <= c.SDL_EVENT_WINDOW_LAST) or
                        e.type == c.SDL_EVENT_RENDER_TARGETS_RESET or e.type == c.SDL_EVENT_RENDER_DEVICE_RESET) app.gate.redraw();
                    // Com a lista do autocompletar aberta, setas, Tab, Enter e Esc são dela.
                    const for_list = e.type == c.SDL_EVENT_KEY_DOWN and autocomplete.takeSdlKey(e.key.key, e.key.mod);
                    // Aperte para falar (e "aperte uma tecla" nas Configurações).
                    if (!for_list and !voz_audio.onSdlEvent(&e)) _ = c.cImGui_ImplSDL3_ProcessEvent(&e);
                    // QUIT é sair sempre (sinal, fim da sessão); o fechar da janela, depende.
                    if (e.type == c.SDL_EVENT_QUIT or (e.type == c.SDL_EVENT_WINDOW_CLOSE_REQUESTED and !app.hideToTray())) {
                        running = false;
                        // Some da tela na hora; o resto do encerramento é por trás.
                        _ = c.SDL_HideWindow(app.win.window);
                    }
                    // Arquivo arrastado para a janela: vai para a bandeja.
                    if (e.type == c.SDL_EVENT_DROP_FILE and app.store.ready and app.st.activeChannel() != null)
                        if (e.drop.data) |p| app.attachFile(std.mem.span(p));
                }
                got = c.SDL_PollEvent(&e);
            }
            if (input) pending = 3;
            // "Digitando" vence em segundos: conferir 4 vezes por segundo basta
            // (são todos os canais).
            if (now() - typing_check_ms >= 250) {
                typing_check_ms = now();
                if (app.store.expireTyping(typing_check_ms)) pending = 2;
            }
            if (app.notifiers.items.len > 0) app.reapNotifiers();

            app.images.now_ms = now();
            if (app.images.pump()) bg_dirty = true;
            if (app.images.trim_due) {
                app.images.trim_due = false;
                app.trim_wanted.store(true, .release);
            }
            {
                var picked: std.ArrayList([:0]u8) = .empty;
                defer picked.deinit(std.heap.c_allocator);
                app.picked.drain(&picked);
                for (picked.items) |p| {
                    defer std.heap.c_allocator.free(p);
                    if (@import("ui/edit_place.zig").takePicked(&app.st, now(), p)) continue;
                    if (app.store.ready) app.attachFile(p);
                }
                if (picked.items.len > 0) pending = 3;
            }
            if (updater.takeNotice()) app.st.showToast(now(), false, "atualização disponível: veja em Configurações → Atualizações", "update available: see Settings → Updates", .{});
            const now_ms = now();
            // Nada venceu ainda: não há por que redesenhar.
            if (timed_out and pending == 0 and !bg_dirty and !mouse.wanted() and !was_active and now_ms < due) continue;
            const win_flags = c.SDL_GetWindowFlags(app.win.window);
            if (win_flags & hidden_flags != 0 and running and !app.opts.qa and app.opts.shot == null and !bench and record_dir == null) {
                bg_dirty = false;
                pending = 0;
                was_active = false;
                mouse = .{};
                app.gate.redraw();
                anim.active = false;
                anim.next_wake_ms = std.math.maxInt(i64);
                app.images.next_frame_ms = std.math.maxInt(i64);
                if (win_flags & (c.SDL_WINDOW_MINIMIZED | c.SDL_WINDOW_HIDDEN) == 0) {
                    hidden_since_ms = 0;
                } else if (hidden_since_ms == 0) {
                    hidden_since_ms = now_ms;
                } else if (now_ms - hidden_since_ms >= janela.hidden_release_ms) {
                    const before = app.images.bytes;
                    if (app.images.releaseHidden()) {
                        app.trim_wanted.store(true, .release);
                        if (app.opts.stats) std.log.info("janela escondida: soltou {d} KB, ficaram {d} imagens, {d} KB", .{ (before - app.images.bytes) / 1024, app.images.readyCount(), app.images.bytes / 1024 });
                    }
                }
                continue;
            }
            hidden_since_ms = 0;
            // Só coisa da rede ou o mouse passando, e o último quadro foi agora há pouco: espera.
            const soft_ms = if (mouse.wanted()) ritmo.MousePace.interval_ms else bg_frame_ms;
            if ((bg_dirty or mouse.wanted()) and pending == 0 and (!was_active or mouse.wanted()) and app.opts.shot == null and !app.opts.qa and
                !app.login.visible() and now_ms - last_frame_ms < soft_ms and now_ms < @min(app.images.next_frame_ms, anim.next_wake_ms)) continue;
            if (app.opts.stats) {
                const why: usize = if (pending > 0) 0 else if (was_active) 1 else if (now_ms >= app.images.next_frame_ms) 2 else if (now_ms >= anim.next_wake_ms) 3 else if (mouse.wanted()) 4 else if (bg_dirty) 5 else 6;
                prof_why[why] += 1;
            }
            bg_dirty = false;
            mouse.frame();
            last_frame_ms = now_ms;
            anim.now_ms = now_ms;
            anim.next_wake_ms = std.math.maxInt(i64);
            app.images.next_frame_ms = std.math.maxInt(i64);
            app.images.drawn_ms = now_ms;
            const t0 = c.SDL_GetTicksNS();
            anim.dt = std.math.clamp(@as(f32, @floatFromInt(t0 - last)) / 1e9, 0.001, 1.0 / 30.0);
            last = t0;
            anim.active = false;

            c.cImGui_ImplSDLRenderer3_NewFrame();
            c.cImGui_ImplSDL3_NewFrame();
            if (app.opts.qa) runner.holdMouse(app);
            // Janela em foco? (Confirmar leitura depende disso; o QA e os prints
            // rodam fora da tela, sem foco de verdade.)
            app.st.window_focused = if (app.opts.qa or app.opts.shot != null) !app.qa_blur else c.SDL_GetWindowFlags(app.win.window) & c.SDL_WINDOW_INPUT_FOCUS != 0;
            // Configurações que valem para o quadro inteiro.
            const set = &app.st.settings;
            // Claro/escuro (inclusive quando o sistema troca, no modo "seguir").
            const mode = app.wantedMode();
            if (mode != app.themes.mode) {
                if (app.themes.setMode(mode)) app.applyThemeStyle();
            }
            d.text_scale = std.math.clamp(set.font_scale, 0.5, 3);
            // Idioma: o QA roda em português (as marcações usam os rótulos), salvo com --lang.
            if (set.language != lang_setting) {
                lang_setting = set.language;
                i18n.set(if (app.opts.qa and app.opts.lang == null) .pt else app.opts.lang orelse i18n.fromSetting(set.language));
                app.st.theme_gen +%= 1;
            }
            anim.instant = set.reduce_motion;
            @import("net/media_url.zig").allow_gif_hosts.store(set.gif_hosts, .release);
            @import("net/proxy.zig").set(set.proxy.slice(), set.proxy_all);
            voz_audio.apply(set);
            lsp_ui.apply(set);
            voz_audio.setPageOpen(set.open and set.page == .voz and app.store.ready);
            plugin_host.frame(app);
            @import("ui/attachments.zig").hide_embeds = !set.show_embeds;
            app.store.keep_log = set.message_log;
            msg_cache.enabled = set.message_cache;
            widgets.hour12 = !set.clock_24h;
            app.images.data_saver = set.data_saver;
            // Modo foco venceu: o que chegou nos outros canais volta como não lido.
            if (app.st.filtros.focus_until != 0 and !app.st.filtros.focusOn(now_ms)) app.st.filtros.endFocus(&app.store);
            if (app.st.filtros.save) {
                app.st.filtros.save = false;
                app.saveSettings();
            }
            if (app.store.ready) app.syncDraft();
            const key = set.layoutKey();
            if (key != app.layout_key) {
                app.layout_key = key;
                app.st.theme_gen +%= 1;
            }

            if (app.store.ready and (app.opts.stats or app.opts.shot != null)) app.scene(settled_frames >= 3);
            c.ImGui_NewFrame();
            qa_mod.beginFrame();
            // (O login por cima da conta aberta, ao adicionar outra, cobre tudo.)
            if (app.store.ready and app.login.phase != .form) {
                const th = app.customTheme();
                // Trocou de servidor (ou de cor do servidor): seleção e cursor do texto acompanham.
                if (guild_color.changed(app.st.guild)) app.applyImGuiColors(th);
                var ctx: d.Ctx = .{
                    .th = th,
                    .theme_name = app.themes.name(),
                    .theme_names = app.themes.names.items,
                    .theme_index = app.themes.current,
                    .store = &app.store,
                    .st = &app.st,
                    .fonts = &app.fonts,
                    .ui = app.uiFamily(th.font_ui),
                    .mono = app.uiFamily(th.font_mono),
                    .dl = undefined,
                    .fg = undefined,
                    .io = app.io,
                    .mouse = app.io.*.MousePos,
                    .now_ms = now(),
                    .actions = &app.actions,
                    .stats = &app.stats,
                    .images = &app.images,
                    .win = undefined,
                };
                const tf = c.SDL_GetTicksNS();
                // As miniaturas de tema só existem para a página de Configurações.
                if (app.st.settings.open) app.themes.ensurePreviews();
                root.frame(&ctx, &app.placed, app.themes.previews.items);
                plugin_host.pollKeys(app);
                // Um clique pode ter mexido no Store direto (marcar como não lida
                // pelo menu): a caixa de entrada confere no próximo quadro.
                const rel = &app.io.*.MouseReleased;
                if (rel[0] or rel[1] or rel[2]) app.store.rev +%= 1;
                if (app.opts.stats) prof_frame += (c.SDL_GetTicksNS() - tf) / 1000;
            }
            if (app.login.visible()) {
                const th = app.themes.theme_();
                var login_accounts: [login_mod.max_accounts]*const accounts_mod.Account = undefined;
                const result = login_mod.draw(&app.login, .{
                    .ui = app.uiFamily("Inter"),
                    .io = app.io,
                    .light = app.themes.mode == .light,
                    .reduce = set.reduce_motion,
                    .dt = if (record_dir != null) 1.0 / 30.0 else anim.dt,
                    .accounts = app_accounts.others(&login_accounts),
                });
                _ = th;
                if (result) |r| login_result = r;
            }
            // Vídeo que não foi desenhado neste quadro pausa.
            @import("ui/video.zig").endFrame(now());
            const tr0 = c.SDL_GetTicksNS();
            c.ImGui_Render();
            if (app.opts.stats) prof_render += (c.SDL_GetTicksNS() - tr0) / 1000;

            const r = app.win.renderer;
            const bg = app.themes.theme_().c(.bg);
            const clear = [4]f32{ bg.r * bg.a, bg.g * bg.a, bg.b * bg.a, bg.a };
            const draw_data = c.ImGui_GetDrawData();
            if (@import("ui/video.zig").takeChanged()) app.gate.redraw();
            // Igual ao que já está na tela: sem GPU nem present. Prints e QA leem os pixels.
            const show = app.gate.check(quadro.sum(draw_data, clear), (app.opts.qa and !app.qa_real_gate) or app.opts.shot != null or bench or record_dir != null or quadro.texturesDirty(draw_data));
            app.stats.frames_built = app.gate.built;
            app.stats.frames_skipped = app.gate.skipped;
            if (show) {
                _ = c.SDL_SetRenderScale(r, app.io.*.DisplayFramebufferScale.x, app.io.*.DisplayFramebufferScale.y);
                _ = c.SDL_SetRenderDrawColorFloat(r, clear[0], clear[1], clear[2], clear[3]);
                _ = c.SDL_RenderClear(r);
            }
            if (app.opts.stats) {
                const dd = c.ImGui_GetDrawData();
                var cmds: u64 = 0;
                var texs: u64 = 0;
                var vtx: u64 = 0;
                for (0..@intCast(dd.*.CmdLists.Size)) |li| {
                    const cl = dd.*.CmdLists.Data[li];
                    vtx += @intCast(cl.*.VtxBuffer.Size);
                    var prev_tex: u64 = 0;
                    for (0..@intCast(cl.*.CmdBuffer.Size)) |ci| {
                        const id = cl.*.CmdBuffer.Data[ci].TexRef._TexID;
                        cmds += 1;
                        if (id != prev_tex) texs += 1;
                        prev_tex = id;
                    }
                }
                prof_cmds += cmds;
                prof_texs += texs;
                prof_vtx += vtx;
            }
            const tg0 = c.SDL_GetTicksNS();
            if (show) c.cImGui_ImplSDLRenderer3_RenderDrawData(draw_data, r);
            if (app.opts.stats) prof_gpu += (c.SDL_GetTicksNS() - tg0) / 1000;
            app.stats.frame_us = @intCast((c.SDL_GetTicksNS() - t0) / 1000);

            if (login_result) |lr| {
                login_result = null;
                app.loginResult(lr);
                pending = 3;
            }
            // Ações acumuladas no quadro.
            if (app.opts.stats) for (app.actions.items) |a| {
                prof_actions.getPtr(std.meta.activeTag(a)).* += 1;
            };
            for (app.actions.items) |a| app.handle(a);
            if (app.actions.items.len > 0) pending = 3;
            app.actions.clearRetainingCapacity();

            frames += 1;
            // --stats: quadros desenhados e custo médio/máximo a cada 2 s.
            if (app.opts.stats) {
                const S = struct {
                    var since: u64 = 0;
                    var n: u32 = 0;
                    var sum: u64 = 0;
                    var max: u32 = 0;
                    var skipped: u64 = 0;
                };
                S.n += 1;
                S.sum += app.stats.frame_us;
                S.max = @max(S.max, app.stats.frame_us);
                const t = c.SDL_GetTicksNS();
                if (S.since == 0) S.since = t;
                if (t - S.since >= 2_000_000_000) {
                    std.log.info("{d} quadros em 2 s, {d} sem desenhar, média {d} µs, pior {d} µs", .{ S.n, app.gate.skipped - S.skipped, S.sum / S.n, S.max });
                    S.skipped = app.gate.skipped;
                    std.log.info("   root.frame {d} µs, ImGui_Render {d} µs, RenderDrawData {d} µs (por quadro)", .{ prof_frame / S.n, prof_render / S.n, prof_gpu / S.n });
                    std.log.info("   {d} comandos, {d} trocas de textura, {d} vértices (por quadro)", .{ prof_cmds / S.n, prof_texs / S.n, prof_vtx / S.n });
                    std.log.info("   por quê: pedido {d}, animação {d}, GIF {d}, hora marcada {d}, mouse {d}, rede {d}, outro {d}", .{ prof_why[0], prof_why[1], prof_why[2], prof_why[3], prof_why[4], prof_why[5], prof_why[6] });
                    for (prof_events) |pe| if (pe.n > 0) std.log.info("   evento 0x{x}: {d}", .{ pe.t, pe.n });
                    var acts = prof_actions.iterator();
                    while (acts.next()) |x| if (x.value.* > 0) std.log.info("   ação {s}: {d}", .{ @tagName(x.key), x.value.* });
                    prof_why = @splat(0);
                    prof_events = @splat(.{});
                    prof_actions = .initFill(0);
                    prof_cmds = 0;
                    prof_texs = 0;
                    prof_vtx = 0;
                    prof_frame = 0;
                    prof_render = 0;
                    prof_gpu = 0;
                    const rt = @import("ui/root.zig");
                    for (rt.prof_names[0..rt.prof_n], rt.prof_us[0..rt.prof_n]) |nm, us| if (us / S.n >= 20) std.log.info("   {s}: {d} µs/quadro", .{ nm, us / S.n });
                    @memset(&rt.prof_us, 0);
                    S.since = t;
                    S.n = 0;
                    S.sum = 0;
                    S.max = 0;
                }
            }
            if (app.opts.stats) {
                timeline.mark(.tela_1);
                if (!first_frame_logged and app.store.ready) {
                    first_frame_logged = true;
                    timeline.mark(.conversa_1);
                    std.log.info("primeiro quadro em {d} ms", .{(c.SDL_GetTicksNS() - app.started_ns) / 1_000_000});
                }
                if (!app.login.visible() and app.store.ready) timeline.mark(.login_fora);
                if (timeline.isMarked(.login_fora) and timeline.isMarked(.historico)) timeline.report();
            }
            if (record_dir) |dir| if (app.login.visible()) {
                var pbuf: [512]u8 = undefined;
                const p = std.fmt.bufPrintSentinel(&pbuf, "{s}/{d:0>4}.png", .{ std.mem.span(dir), record_n }, 0) catch unreachable;
                _ = app.win.screenshot(p.ptr);
                record_n += 1;
                const max: u32 = if (c.SDL_getenv("LARPER_RECORD_FRAMES")) |n| std.fmt.parseInt(u32, std.mem.span(n), 10) catch 150 else 150;
                if (record_n >= max) running = false;
            };
            if (app.opts.shot) |path| if (app.login.visible() and !app.store.ready and c.SDL_getenv("LARPER_SHOT_REAL") == null) {
                // Print da tela de login: espera a animação de entrada.
                if (app.login.t > 2.6) {
                    if (!app.win.screenshot(path)) std.log.err("não consegui salvar {s}", .{path});
                    running = false;
                }
            } else {
                const ready = app.store.ready and !app.images.busy() and if (app.st.activeChannel()) |ch| (app.store.channel(ch).?.history == .loaded and app.store.channel(ch).?.around != .loading) else false;
                settled_frames = if (ready) settled_frames + 1 else 0;
                // Conta real: a rede pode demorar mais que a demonstração.
                const limit: u64 = if (app.store.demo) 6 else 20;
                if (settled_frames == 12 or c.SDL_GetTicksNS() - app.started_ns > limit * std.time.ns_per_s) {
                    if (!app.win.screenshot(path)) std.log.err("não consegui salvar {s}", .{path});
                    running = false;
                }
            };
            if (app.opts.qa and (app.store.ready or app.login.visible()) and !runner.tick(app)) running = false;
            if (show) _ = c.SDL_RenderPresent(r);
            if (pending > 0) pending -= 1;
            was_active = anim.active;
            // Sem o present, nada segura o laço no ritmo da tela. Os quadros que
            // `pending` pede depois de um evento são poucos e podem correr; animação
            // que não muda nada, ou quem pede quadro sem parar, não.
            skipped_in_row = if (show) 0 else skipped_in_row +| 1;
            if (!show and (was_active or (pending > 0 and skipped_in_row > 3))) {
                const spent_ms = (c.SDL_GetTicksNS() - t0) / std.time.ns_per_ms;
                if (spent_ms < 16) c.SDL_Delay(@intCast(16 - spent_ms));
            }
        }
        // Não chegou a conectar: o que deu para medir ainda sai.
        timeline.report();
        return runner.fail == 0;
    }
};
