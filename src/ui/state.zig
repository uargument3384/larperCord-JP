//! Estado que só a interface usa: o que está selecionado, abas, rolagem,
//! paleta. Os dados em si ficam no Store.
const std = @import("std");
const Id = @import("../core/types.zig").Id;
const i18n = @import("i18n.zig");
pub const Settings = @import("settings_state.zig").Settings;

/// `voice_move`: os canais de voz para onde dá para mover alguém (id = a pessoa).
/// `plugin_choices`: a segunda lista de uma entrada de plugin (id = a mensagem ou a pessoa).
pub const MenuKind = enum { message, user, channel, guild, status, voice_move, thread_delete, plugin_choices };

pub const Popup = union(enum) {
    none,
    menu: struct { kind: MenuKind, id: Id, x: f32, y: f32 },
    profile: struct { user: Id, x: f32, y: f32 },
    /// Perfil grande, no meio da tela (aba em `profile_tab`).
    profile_full: struct { user: Id },
    /// `target` = mensagem que vai receber a reação (0 = caixa de texto).
    emoji: struct { target: Id, x: f32, y: f32 },
    /// Mixer da call: volume individual de cada pessoa.
    mixer: struct { x: f32, y: f32 },
    /// Caixa de entrada (aba 0 = não lidas, 1 = menções) e mensagens salvas.
    inbox: struct { tab: u8 = 0 },
    saved,
    /// Mensagens fixadas de um canal.
    pins: struct { channel: Id },
    /// Threads de um canal de texto, ativas ou arquivadas (ui/forum.zig).
    threads: struct { parent: Id, archived: bool = false },
    /// "Criar thread" a partir de uma mensagem e "Novo post" num fórum.
    new_thread: struct { message: Id },
    new_post: struct { forum: Id },
    /// Encaminhar uma mensagem para outro canal.
    forward: struct { channel: Id, message: Id, target: Id = 0 },
    /// Editar um servidor ou um grupo de DM (ui/edit_place.zig).
    edit_place: struct { id: Id, group: bool },
};

/// Seleção de texto entre mensagens: âncora e cabeça (mensagem + byte).
pub const Selection = struct {
    channel: Id = 0,
    a_id: Id = 0,
    a_off: u32 = 0,
    b_id: Id = 0,
    b_off: u32 = 0,
    dragging: bool = false,

    pub fn empty(s: *const Selection) bool {
        return s.channel == 0 or (s.a_id == s.b_id and s.a_off == s.b_off);
    }
};

/// Imagem aberta em tela cheia (cópia da URL: a mensagem pode sumir).
pub const Viewer = struct {
    url: [1024]u8 = undefined,
    url_len: u16 = 0,
    name: [128]u8 = undefined,
    name_len: u8 = 0,
    w: u16 = 0,
    h: u16 = 0,
    /// Banner, ícone ou foto: o CDN não diz o tamanho antes. `w` e `h` são um
    /// palpite até a imagem chegar, e ela é pedida inteira.
    original: bool = false,
};

/// Arquivo escolhido para ir junto com a próxima mensagem.
pub const Upload = struct {
    /// Caminho completo (c_allocator).
    path: [:0]u8,
    size: u64,
    /// Tamanho da imagem (0 = não é imagem).
    width: u16 = 0,
    height: u16 = 0,

    pub fn name(u: *const Upload) []const u8 {
        return std.fs.path.basename(u.path);
    }
};

pub const Scroll = struct {
    pos: f32 = -1,
    target: f32 = 0,
    stick_bottom: bool = true,
    /// Primeira mensagem visível da última vez e onde ela estava: se algo em
    /// cima mudou de altura (antigas chegaram, uma prévia abriu, cortou), a
    /// rolagem anda junto e o que a pessoa está lendo não pula.
    anchor_id: Id = 0,
    anchor_off: f32 = 0,
};

pub const Toast = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,
    until_ms: i64 = 0,
    is_error: bool = false,

    pub fn text(t: *const Toast) []const u8 {
        return t.buf[0..t.len];
    }
};

pub const PaletteItem = struct {
    label: []const u8,
    hint: []const u8 = "",
    /// `setting`: índice em settings_state.fields(); `page`: página das configurações.
    /// `plugin`: índice em `Engine.list` (abre o painel).
    kind: enum { channel, guild, theme, action, setting, page, plugin },
    id: Id = 0,
    index: usize = 0,
    score: i32 = 0,
};

pub const Palette = struct {
    open: bool = false,
    query: [128]u8 = @splat(0),
    selected: usize = 0,
    focus: bool = false,
    items: std.ArrayList(PaletteItem) = .empty,
    /// Textos montados para os itens (liberados ao reconstruir a lista).
    arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator),
};

pub const State = struct {
    gpa: std.mem.Allocator,
    guild: Id = 0,
    /// Canais abertos em abas; `tab` é a ativa.
    tabs: std.ArrayList(Id) = .empty,
    tab: usize = 0,
    /// Último canal aberto em cada servidor.
    last_channel: std.AutoHashMapUnmanaged(Id, Id) = .empty,
    /// Tela de amigos aberta (no lugar da conversa, nas mensagens diretas).
    friends: bool = false,
    /// Aba da tela de amigos: 0 online, 1 todos, 2 pendentes, 3 bloqueados.
    friends_tab: u8 = 0,
    /// DM pedida ao Discord: abre quando o canal chegar.
    pending_dm: Id = 0,
    voice: ?Id = null,
    voice_guild: Id = 0,
    voice_status: @import("../core/event.zig").VoiceStatus = .disconnected,
    /// Mixer aberto na barra de voz.
    voice_mixer: bool = false,
    /// Volume individual de cada pessoa na call (0..2).
    voice_volumes: std.AutoHashMapUnmanaged(Id, f32) = .empty,
    voice_save_ms: i64 = 0,
    /// Ping da call (heartbeat do gateway de voz); 0 = ainda não mediu.
    voice_ping_ms: u32 = 0,
    /// O microfone ou a saída da call não abriram (a barra de voz avisa).
    voice_mic_failed: bool = false,
    voice_out_failed: bool = false,
    muted: bool = false,
    deafened: bool = false,
    collapsed: std.AutoHashMapUnmanaged(Id, void) = .empty,
    /// Pastas de servidores abertas na barra.
    open_folders: std.AutoHashMapUnmanaged(u64, void) = .empty,
    input: [2000]u8 = @splat(0),
    focus_input: bool = true,
    scroll: std.AutoHashMapUnmanaged(Id, Scroll) = .empty,
    palette: Palette = .{},
    settings: Settings = .{},
    popup: Popup = .none,
    /// Aba do perfil grande: 0 atividade, 1 amigos em comum, 2 servidores em comum.
    profile_tab: u8 = 0,
    /// Editando a nota do perfil (texto em `note_input`).
    note_editing: bool = false,
    /// Até 256 caracteres (4 bytes cada, no pior caso): editar não corta o fim.
    note_input: [1025]u8 = @splat(0),
    /// Caixa de texto do cartão de perfil ("Mensagem @fulano").
    popup_input: [256]u8 = @splat(0),
    reply_to: Id = 0,
    editing: Id = 0,
    /// O conteúdo de `input` mudou por fora: a caixa de texto deve recarregar.
    input_sync: bool = false,
    edit_last: bool = false,
    selection: Selection = .{},
    jump: Id = 0,
    /// A busca em volta de `jump` já foi pedida (a lista espera a resposta).
    jump_asked: Id = 0,
    jump_until_ms: i64 = 0,
    /// A janela está em foco neste quadro.
    window_focused: bool = true,
    muted_channels: std.AutoHashMapUnmanaged(Id, void) = .empty,
    /// Palavras de alerta, filtro, ignorados e modo foco (core/filtros.zig).
    filtros: @import("../core/filtros.zig").Filtros = .{},
    /// Rascunho de cada canal (ui/rascunhos.zig).
    drafts: @import("rascunhos.zig").Drafts = .{},
    toast: Toast = .{},
    viewer: ?Viewer = null,
    uploads: std.ArrayList(Upload) = .empty,
    /// Contador de "geração" do tema (invalida caches de layout).
    theme_gen: u8 = 0,
    nonce: u64 = 1,
    /// Último "digitando" enviado (o Discord pede no máximo um a cada 8 s).
    typing_sent_ms: i64 = 0,
    /// Mensagens salvas da conta (ui/saved.zig lê e grava o arquivo).
    saved: @import("../core/saved.zig").List = .{},
    /// Buffers reaproveitados a cada quadro pela lista de mensagens.
    offsets: std.ArrayList(f32) = .empty,
    groups: std.ArrayList(u8) = .empty,

    pub fn activeChannel(s: *const State) ?Id {
        return if (s.tab < s.tabs.items.len) s.tabs.items[s.tab] else null;
    }

    pub fn scrollOf(s: *State, ch: Id) *Scroll {
        const gop = s.scroll.getOrPut(s.gpa, ch) catch @panic("OOM");
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    /// Aviso rápido no topo, nos dois idiomas: showToast(now, false, "copiado ✓", "copied ✓", .{}).
    pub fn showToast(s: *State, now_ms: i64, is_error: bool, comptime pt: []const u8, comptime en: []const u8, args: anytype) void {
        const out = i18n.fmt(&s.toast.buf, pt, en, args);
        s.toast.len = out.len;
        s.toast.until_ms = now_ms + if (is_error) @as(i64, 6000) else 1800;
        s.toast.is_error = is_error;
    }
};
