//! Modelo de dados, espelhando o do Discord (IDs são snowflakes de 64 bits).
const std = @import("std");

pub const Id = u64;

pub const Status = enum { online, idle, dnd, offline };

/// `forum`: fórum e canal de mídia (tipos 15 e 16). Thread é `text` com
/// `Channel.thread` preenchido: abre como conversa normal.
pub const ChannelKind = enum { text, voice, category, forum };

pub const User = struct {
    id: Id,
    name: []const u8,
    /// Índice da cor do cargo (o tema decide a cor de cada índice).
    role: u8 = 0,
    status: Status = .offline,
    activity: ?[]const u8 = null,
    /// Hash do avatar no CDN do Discord (null = sem foto).
    /// Na demonstração: "demo:av:N" (gerado, não baixa nada).
    avatar: ?[]const u8 = null,
    /// Decoração do avatar (o "asset" da loja; animada em APNG).
    decoration: ?[]const u8 = null,
    /// Conta de bot e, entre elas, as verificadas pelo Discord.
    bot: bool = false,
    verified_bot: bool = false,
    /// Autor de uma mensagem de webhook: não é uma conta, então não tem perfil
    /// nem DM (ver `webhook_id_bit`).
    webhook: bool = false,
};

/// Cada webhook escreve com o nome e a foto que quiser, então cada combinação é
/// uma "pessoa" aqui, com um ID inventado. Este bit os separa dos snowflakes,
/// que só chegam nele em 2084.
pub const webhook_id_bit: Id = 1 << 63;

/// Perfil completo, buscado quando o cartão de alguém abre
/// (GET /users/{id}/profile). Textos alocados; vazio = não tem.
pub const Profile = struct {
    banner: []const u8 = "",
    /// Cor do banner quando não há imagem (0xRRGGBB, 0 = sem).
    accent: u32 = 0,
    bio: []const u8 = "",
    pronouns: []const u8 = "",
    /// Nome de usuário (o @), quando é diferente do nome que aparece.
    username: []const u8 = "",
    /// Servidor do pedido e quando a pessoa entrou nele (ms; 0 = não sabe).
    guild: Id = 0,
    joined_ms: i64 = 0,
    /// Impulsionando o servidor desde (ms; 0 = não).
    boost_ms: i64 = 0,
    mutual_guilds: []const Id = &.{},
    mutual_friends: []const Id = &.{},
    mutual_friends_count: u32 = 0,
    connections: []const Connection = &.{},
    badges: []const Badge = &.{},
};

/// Conta ligada ao perfil (GitHub, Steam, Spotify…). `url` vazio = sem link.
pub const Connection = struct {
    kind: []const u8,
    name: []const u8,
    url: []const u8 = "",
};

/// Insígnia do perfil: `icon` é o hash em cdn.discordapp.com/badge-icons/.
pub const Badge = struct {
    icon: []const u8,
    description: []const u8,
};

/// Atividade de alguém (jogo, música, transmissão…), da presença.
/// `kind` é o do Discord: 0 jogando, 1 transmitindo, 2 ouvindo,
/// 3 assistindo, 5 competindo. Textos alocados; vazio = não tem.
pub const Activity = struct {
    kind: u8 = 0,
    name: []const u8 = "",
    details: []const u8 = "",
    state: []const u8 = "",
    /// Começo/fim (ms Unix; 0 = não diz).
    start_ms: i64 = 0,
    end_ms: i64 = 0,
    /// Imagem grande já como URL (CDN/proxy do Discord) ou "".
    image: []const u8 = "",
    /// Aplicação (para o ícone do jogo quando não há imagem).
    app: Id = 0,
};

/// Pasta de servidores da barra lateral (como no cliente oficial).
/// `id` 0 = servidor solto (não é pasta de verdade, tem um servidor só).
pub const GuildFolder = struct {
    id: u64,
    name: []const u8,
    color: u32,
    guilds: []const Id,
};

/// Permissões do Discord que o cliente usa.
pub const perm = struct {
    pub const administrator: u64 = 1 << 3;
    pub const manage_guild: u64 = 1 << 5;
    pub const manage_messages: u64 = 1 << 13;
    pub const mention_everyone: u64 = 1 << 17;
    pub const view_channel: u64 = 1 << 10;
    pub const send_messages: u64 = 1 << 11;
    pub const read_history: u64 = 1 << 16;
    pub const connect: u64 = 1 << 20;
    pub const move_members: u64 = 1 << 24;
    pub const manage_roles: u64 = 1 << 28;
    pub const manage_threads: u64 = 1 << 34;
    pub const create_public_threads: u64 = 1 << 35;
    pub const send_messages_in_threads: u64 = 1 << 38;
};

/// O que só uma thread (ou post de fórum) tem. `Channel.parent` é o canal pai.
pub const ThreadInfo = struct {
    owner: Id = 0,
    archived: bool = false,
    locked: bool = false,
    private: bool = false,
    joined: bool = false,
    /// O evento disse se estamos nela (THREAD_UPDATE não diz: fica o que era).
    joined_known: bool = false,
    message_count: u32 = 0,
    member_count: u32 = 0,
    /// 0 = não veio.
    last_message: Id = 0,
    /// Quando foi arquivada (s); é por onde as arquivadas paginam.
    archive_ts: i64 = 0,
    /// Tags aplicadas (alocadas com o c_allocator).
    tags: []const Id = &.{},
};

/// Tag que um fórum oferece. Textos alocados com o c_allocator.
pub const ForumTag = struct {
    id: Id,
    name: []const u8,
    /// Emoji unicode ("" = não tem ou é personalizado).
    emoji: []const u8 = "",
    /// Só quem modera o fórum pode usar.
    moderated: bool = false,
};

/// Primeira mensagem de um post, para a lista do fórum (texto alocado).
pub const ThreadPreview = struct { thread: Id, author: Id, text: []const u8 };

/// Cargo de um servidor. `color` é 0xRRGGBB (0 = sem cor).
pub const Role = struct {
    id: Id,
    guild: Id,
    name: []const u8,
    color: u32 = 0,
    position: i32 = 0,
    permissions: u64 = 0,
    /// Cargo de bot/integração: ninguém dá ou tira à mão.
    managed: bool = false,
    /// Qualquer um pode mencionar (`<@&id>`).
    mentionable: bool = false,
};

/// Emoji personalizado de um servidor. `name` é alocado.
pub const Emoji = struct {
    id: Id,
    guild: Id = 0,
    name: []const u8,
    animated: bool = false,
    /// O servidor perdeu o nível de impulso que liberava este emoji.
    available: bool = true,
};

/// O que a pessoa é da gente (os números são os do Discord).
pub const Relationship = enum(u8) { none = 0, friend = 1, blocked = 2, incoming = 3, outgoing = 4 };

/// Grupos fixos da lista de membros; os outros grupos são cargos (pelo ID).
pub const group_online: Id = 1;
pub const group_offline: Id = 2;

/// O que sabemos de alguém num servidor: cor do nome e cargos (do mais
/// alto para o mais baixo, até 6).
pub const MemberInfo = struct {
    color: u32 = 0,
    roles: [6]Id = @splat(0),
    n_roles: u8 = 0,

    pub fn roleSlice(m: *const MemberInfo) []const Id {
        return m.roles[0..m.n_roles];
    }
};

/// Uma linha da lista de membros, na ordem em que o Discord manda
/// (GUILD_MEMBER_LIST_UPDATE): cabeçalho de grupo ou membro.
pub const MemberItem = union(enum) {
    none,
    group: struct { id: Id, count: u32 },
    member: struct { user: Id, info: MemberInfo = .{} },
};

pub const MemberOp = struct {
    kind: enum { sync, insert, update, delete, invalidate },
    /// SYNC/INVALIDATE: faixa [index, end]; INSERT/UPDATE/DELETE: a posição.
    index: u32,
    end: u32 = 0,
    /// Alocado com o c_allocator (vazio em DELETE/INVALIDATE).
    items: []const MemberItem = &.{},
};

pub const Guild = struct {
    id: Id,
    name: []const u8,
    /// Texto do ícone quando não há imagem ("LC", "☕"...).
    acronym: []const u8,
    color: u8 = 0,
    unread: bool = false,
    mentions: u16 = 0,
    /// Hash do ícone no CDN (null = mostra a sigla).
    icon: ?[]const u8 = null,
    /// Dono do servidor (tem todas as permissões).
    owner: Id = 0,
    /// Snowflake de quando entramos (o que veio antes não conta como não lido).
    joined_id: Id = 0,
    /// Hash do banner no CDN (null = sem banner).
    banner: ?[]const u8 = null,
    /// O servidor tem o recurso de banner (o Discord recusa sem ele).
    can_banner: bool = false,
    description: []const u8 = "",
};

pub const Channel = struct {
    id: Id,
    guild: Id,
    parent: ?Id = null,
    kind: ChannelKind = .text,
    name: []const u8,
    topic: []const u8 = "",
    position: u16 = 0,
    unread: bool = false,
    /// Em DMs (guild = 0): a outra pessoa da conversa.
    recipient: Id = 0,
    /// Grupo (DM com várias pessoas): todos os participantes menos a gente.
    /// Vazio numa DM comum. Alocado com o c_allocator.
    recipients: []const Id = &.{},
    /// Ícone do grupo (hash no CDN).
    icon: ?[]const u8 = null,
    /// DM em grupo (tipo 3 do Discord), mesmo que só reste uma pessoa.
    group: bool = false,
    /// Exceções de permissão do canal (alocadas com o c_allocator).
    overwrites: []const Overwrite = &.{},
    /// A última mensagem que o Discord diz existir no canal (READY e o que chega).
    last_message: Id = 0,
    /// Thread ou post de fórum (null nos outros canais).
    thread: ?ThreadInfo = null,
    /// Fórum: tags oferecidas (alocadas), canal de mídia, post precisa de tag.
    tags: []const ForumTag = &.{},
    media: bool = false,
    require_tag: bool = false,
};

/// Registro de leitura de um canal (`read_state` do READY).
pub const ReadEntry = struct {
    channel: Id,
    last_read: Id = 0,
    mentions: u16 = 0,
    /// Só a demonstração usa: a última do canal, que o READY dela não traz.
    last_message: Id = 0,
};

/// Convite (GET /invites/{code}). `name` e `icon` alocados com o c_allocator.
pub const Invite = struct {
    state: enum { loading, ok, invalid, failed } = .loading,
    /// Servidor do convite (0 = convite de grupo).
    guild: Id = 0,
    name: []const u8 = "",
    icon: ?[]const u8 = null,
    members: u32 = 0,
    online: u32 = 0,
    /// Imagem do topo do cartão: o banner do servidor ou, sem ele, o splash.
    banner: ?[]const u8 = null,
    splash: bool = false,
};

/// Exceção de permissão de um canal para um cargo (o @everyone tem o ID do
/// servidor) ou para uma pessoa.
pub const Overwrite = struct {
    id: Id,
    member: bool = false,
    allow: u64 = 0,
    deny: u64 = 0,
};

/// Anexo de uma mensagem. `url` pode ser https:// (CDN do Discord),
/// file:// (arquivo nosso ainda subindo) ou demo:N (imagem da demonstração).
pub const Attachment = struct {
    url: []const u8,
    filename: []const u8,
    /// Tamanho da imagem (0 = não é imagem). Vem junto com a mensagem, então
    /// dá pra reservar o espaço antes de a imagem chegar.
    width: u16 = 0,
    height: u16 = 0,
    size: u32 = 0,
    animated: bool = false,
    /// Prévia parada (GIF do Tenor/Giphy: `url` é o GIF no site deles,
    /// `still` é a miniatura pelo proxy do Discord). Vazio = não tem.
    still: []const u8 = "",
    /// Veio de um link (embed), não foi anexado: some com
    /// Configurações → Chat → Mostrar imagens de links desligado.
    embed: bool = false,
    /// Vídeo: `url` é a prévia (um quadro, pelo proxy) e `link` o vídeo,
    /// que abre no navegador.
    video: bool = false,
    link: []const u8 = "",

    pub fn isImage(a: *const Attachment) bool {
        return a.width > 0 and a.height > 0;
    }
};

/// Libera os anexos (alocados com `gpa`, como o resto da mensagem).
pub fn freeAttachments(gpa: std.mem.Allocator, list: []const Attachment) void {
    for (list) |a| freeAttachment(gpa, a);
    if (list.len > 0) gpa.free(list);
}

/// Só os textos de um anexo (a lista em que ele está não).
pub fn freeAttachment(gpa: std.mem.Allocator, a: Attachment) void {
    gpa.free(a.url);
    gpa.free(a.filename);
    if (a.still.len > 0) gpa.free(a.still);
    if (a.link.len > 0) gpa.free(a.link);
}

/// Cartão de link/bot (embed "rich", "article", "link", "video"…).
/// Textos alocados com o mesmo alocador da mensagem; vazio = não tem.
pub const Embed = struct {
    /// 0xRRGGBB; `has_color` diz se veio cor (preto também é cor).
    color: u32 = 0,
    has_color: bool = false,
    provider: []const u8 = "",
    author: []const u8 = "",
    title: []const u8 = "",
    url: []const u8 = "",
    description: []const u8 = "",
    footer: []const u8 = "",
    fields: []const EmbedField = &.{},
    /// Imagem grande (ou a prévia do vídeo) e a miniatura do canto.
    image: []const u8 = "",
    image_w: u16 = 0,
    image_h: u16 = 0,
    thumb: []const u8 = "",
    /// Tem vídeo (YouTube…): a imagem ganha um botão de play que abre `url`.
    video: bool = false,
    /// O arquivo do vídeo pelo proxy de mídia do Discord (link direto para
    /// um .mp4…): esse toca aqui dentro. Vazio = só no navegador (YouTube).
    video_url: []const u8 = "",
    /// Cartão de componentes (o formato novo dos bots): uma lista de blocos.
    blocks: []const EmbedBlock = &.{},
    /// Componentes soltos na mensagem: sem fundo nem barra de cor.
    bare: bool = false,
    /// Cartão marcado como spoiler: coberto até passar o mouse.
    spoiler: bool = false,
};

pub const EmbedField = struct { name: []const u8, value: []const u8 };

/// Imagem, vídeo, arquivo ou botão de link de um bloco.
pub const EmbedMedia = struct {
    /// O que se mostra (pelo proxy do Discord).
    url: []const u8 = "",
    /// Para onde o clique vai: o vídeo, o arquivo, o endereço do botão.
    link: []const u8 = "",
    /// Nome do arquivo ou texto do botão.
    label: []const u8 = "",
    w: u16 = 0,
    h: u16 = 0,
    size: u32 = 0,
    video: bool = false,
    spoiler: bool = false,
};

pub const EmbedBlock = struct {
    kind: enum { text, separator, gallery, file, buttons } = .text,
    /// Markdown (`.text`).
    text: []const u8 = "",
    /// `.text`: a miniatura ao lado, se houver. Os outros: os itens.
    media: []const EmbedMedia = &.{},
    /// `.separator`: linha visível e espaço maior.
    divider: bool = false,
    large: bool = false,
};

pub fn freeBlocks(gpa: std.mem.Allocator, list: []const EmbedBlock) void {
    for (list) |b| {
        if (b.text.len > 0) gpa.free(b.text);
        for (b.media) |m| for ([_][]const u8{ m.url, m.link, m.label }) |t| if (t.len > 0) gpa.free(t);
        if (b.media.len > 0) gpa.free(b.media);
    }
    if (list.len > 0) gpa.free(list);
}

pub fn freeEmbeds(gpa: std.mem.Allocator, list: []const Embed) void {
    for (list) |e| freeEmbed(gpa, e);
    if (list.len > 0) gpa.free(list);
}

/// Só os textos de um embed (a lista em que ele está não).
pub fn freeEmbed(gpa: std.mem.Allocator, e: Embed) void {
    for ([_][]const u8{ e.provider, e.author, e.title, e.url, e.description, e.footer, e.image, e.thumb, e.video_url }) |t| if (t.len > 0) gpa.free(t);
    for (e.fields) |f| {
        gpa.free(f.name);
        gpa.free(f.value);
    }
    if (e.fields.len > 0) gpa.free(e.fields);
    freeBlocks(gpa, e.blocks);
}

pub const Message = struct {
    id: Id,
    channel: Id,
    author: Id,
    /// Segundos desde 1970 (UTC).
    timestamp: i64,
    content: []const u8,
    /// O texto como o Discord guarda, quando difere de `content` (emoji
    /// personalizado vira `:nome:` na tela). Vazio = igual. É o que se edita.
    raw: []const u8 = "",
    /// Identificador local de uma mensagem enviada por nós, para casar a
    /// confirmação do servidor com a cópia "pendente" já exibida.
    nonce: u64 = 0,
    /// Mensagem que esta responde (0 = nenhuma).
    reply_to: Id = 0,
    /// Original location for a native Discord forward.
    forward_channel: Id = 0,
    forward_message: Id = 0,
    forwarded: bool = false,
    edited: bool = false,
    attachments: []const Attachment = &.{},
    embeds: []const Embed = &.{},
    /// Mensagem de sistema (entrou, saiu, chamada, fixou…): `content` já
    /// vem com o texto pronto e a interface desenha como uma linha cinza.
    system: SystemKind = .none,
    /// Do servidor: @everyone/@here valendo (quem escreveu tinha permissão) e
    /// menção a nós fora de bloco de código.
    mention_everyone: bool = false,
    mentions_me: bool = false,
    /// Fixada no canal.
    pinned: bool = false,
    /// Thread aberta a partir desta mensagem (0 = nenhuma): o cartão clicável.
    thread: Id = 0,

    /// O texto que vai para a caixa ao editar (e volta ao Discord).
    pub fn editable(m: *const Message) []const u8 {
        return if (m.raw.len > 0) m.raw else m.content;
    }
};

pub const SystemKind = enum(u8) { none, join, leave, call, pin, edit, boost, other };

/// Uma reação: o emoji (UTF-8; o nome, se for personalizado), quantas pessoas
/// e se inclui a gente. 32 bytes cabem qualquer emoji Unicode (os mais longos,
/// bandeiras de tags e famílias, têm 28) e qualquer nome do Discord.
pub const Reaction = struct {
    emoji: [32]u8 = @splat(0),
    len: u8 = 0,
    count: u16 = 0,
    me: bool = false,
    /// Personalizado animado (`<a:…>`).
    animated: bool = false,
    /// Emoji personalizado (0 = unicode): é assim que a API o reconhece.
    custom: Id = 0,

    pub fn text(r: *const Reaction) []const u8 {
        return r.emoji[0..r.len];
    }

    pub fn init(e: []const u8) Reaction {
        var r: Reaction = .{};
        const n = @min(e.len, r.emoji.len);
        @memcpy(r.emoji[0..n], e[0..n]);
        r.len = @intCast(n);
        return r;
    }

    pub fn initCustom(name: []const u8, id: Id, animated: bool) Reaction {
        var r = init(name);
        r.custom = id;
        r.animated = animated;
        return r;
    }

    /// É o mesmo emoji? (Personalizado vale pelo ID: o nome pode mudar.)
    pub fn same(a: *const Reaction, b: *const Reaction) bool {
        if (a.custom != 0 or b.custom != 0) return a.custom == b.custom;
        return std.mem.eql(u8, a.text(), b.text());
    }
};

/// Imagem colada: um arquivo temporário nosso, apagado depois de enviado.
pub fn isPastedFile(path: []const u8) bool {
    const name = path[(if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0)..];
    return std.mem.startsWith(u8, name, "larpercord-colado-") or std.mem.startsWith(u8, name, "larpercord-pasted-");
}

/// Timestamp embutido num snowflake do Discord (ms desde 2015-01-01).
pub fn snowflakeTime(id: Id) i64 {
    return @intCast((id >> 22) + 1420070400000);
}

pub fn makeSnowflake(ms: i64, seq: u64) Id {
    const since: u64 = @intCast(ms - 1420070400000);
    return (since << 22) | (seq & 0x3fffff);
}

test "snowflake ida e volta" {
    const ms: i64 = 1_793_000_000_123;
    try std.testing.expectEqual(ms, snowflakeTime(makeSnowflake(ms, 7)));
}
