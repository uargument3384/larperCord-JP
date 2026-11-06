//! Interface language selection and compact translations.
const std = @import("std");
const c = @import("c");

pub const Lang = enum(u8) { pt, en, ja };
var lang: std.atomic.Value(Lang) = .init(.ja);

const Translation = struct { pt: []const u8, en: []const u8, ja: [:0]const u8 };
const translations = [_]Translation{
    .{ .pt = "CONFIGURAÇÕES DE USUÁRIO", .en = "USER SETTINGS", .ja = "ユーザー設定" },
    .{ .pt = "CONFIGURAÇÕES DO APLICATIVO", .en = "APP SETTINGS", .ja = "アプリ設定" },
    .{ .pt = "LARPERCORD", .en = "LARPERCORD", .ja = "LARPERCORD" },
    .{ .pt = "Minha conta", .en = "My Account", .ja = "マイアカウント" },
    .{ .pt = "Privacidade", .en = "Privacy", .ja = "プライバシー" },
    .{ .pt = "Alertas e filtros", .en = "Alerts & Filters", .ja = "通知とフィルター" },
    .{ .pt = "Aparência", .en = "Appearance", .ja = "外観" },
    .{ .pt = "Acessibilidade", .en = "Accessibility", .ja = "アクセシビリティ" },
    .{ .pt = "Voz", .en = "Voice", .ja = "音声" },
    .{ .pt = "Notificações", .en = "Notifications", .ja = "通知" },
    .{ .pt = "Atalhos de teclado", .en = "Keybinds", .ja = "キーバインド" },
    .{ .pt = "Idioma", .en = "Language", .ja = "言語" },
    .{ .pt = "Avançado", .en = "Advanced", .ja = "詳細設定" },
    .{ .pt = "Desempenho", .en = "Performance", .ja = "パフォーマンス" },
    .{ .pt = "Erros no código", .en = "Code diagnostics", .ja = "コード診断" },
    .{ .pt = "Plugins", .en = "Plugins", .ja = "プラグイン" },
    .{ .pt = "Atualizações", .en = "Updates", .ja = "アップデート" },
    .{ .pt = "Novidades", .en = "What's new", .ja = "新機能" },
    .{ .pt = "Sobre", .en = "About", .ja = "このアプリについて" },
    .{ .pt = "Sair", .en = "Log Out", .ja = "ログアウト" },
    .{ .pt = "Seguir o sistema", .en = "Follow system", .ja = "システム設定に従う" },
    .{ .pt = "Por padrão o app segue o idioma do sistema. A troca vale na hora.", .en = "By default the app follows your system language. Changes apply right away.", .ja = "初期設定ではシステムの言語に従います。変更はすぐに反映されます。" },
    .{ .pt = "Cor do tema", .en = "Theme color", .ja = "テーマの色" },
    .{ .pt = "Usar esta cor", .en = "Use this color", .ja = "この色を使用" },
    .{ .pt = "Modo", .en = "Mode", .ja = "モード" },
    .{ .pt = "Tema", .en = "Theme", .ja = "テーマ" },
    .{ .pt = "Escala da fonte", .en = "Font scaling", .ja = "フォント倍率" },
    .{ .pt = "Tamanho do texto", .en = "Text size", .ja = "文字サイズ" },
    .{ .pt = "Exibição das mensagens", .en = "Message display", .ja = "メッセージ表示" },
    .{ .pt = "Modo compacto", .en = "Compact mode", .ja = "コンパクトモード" },
    .{ .pt = "Mostrar avatares", .en = "Show avatars", .ja = "アバターを表示" },
    .{ .pt = "Rede", .en = "Network", .ja = "ネットワーク" },
    .{ .pt = "Salvar proxy", .en = "Save proxy", .ja = "プロキシを保存" },
    .{ .pt = "Remover proxy", .en = "Remove proxy", .ja = "プロキシを削除" },
    .{ .pt = "Usar o proxy em tudo", .en = "Use the proxy for everything", .ja = "すべての通信でプロキシを使用" },
    .{ .pt = "Sem proxy: conexão direta.", .en = "No proxy: direct connection.", .ja = "プロキシ未設定：直接接続します。" },
    .{ .pt = "Aplicar", .en = "Apply", .ja = "適用" },
    .{ .pt = "Restaurar tema", .en = "Reset theme", .ja = "テーマをリセット" },
    .{ .pt = "Limpar esta cor", .en = "Clear this color", .ja = "この色をクリア" },
    .{ .pt = "claro", .en = "light", .ja = "ライト" },
    .{ .pt = "escuro", .en = "dark", .ja = "ダーク" },
    .{ .pt = "Feito com", .en = "Built with", .ja = "使用技術" },
    .{ .pt = "Cliente de Discord nativo: Zig + SDL3 + Dear ImGui + FreeType.", .en = "Native Discord client: Zig + SDL3 + Dear ImGui + FreeType.", .ja = "Zig・SDL3・Dear ImGui・FreeTypeで構築されたネイティブDiscordクライアントです。" },
    .{ .pt = "Cliente não oficial: usar contas de usuário fora do app oficial vai contra os termos do Discord.", .en = "Unofficial client: using user accounts outside the official app is against Discord's terms.", .ja = "非公式クライアントです。公式アプリ以外でユーザーアカウントを使用すると、Discordの利用規約に違反する場合があります。" },
};

fn japanese(pt: []const u8, english: []const u8) ?[:0]const u8 {
    for (translations) |t| {
        if (std.mem.eql(u8, pt, t.pt) and std.mem.eql(u8, english, t.en)) return t.ja;
    }
    return null;
}

fn japaneseFormat(comptime pt: []const u8, comptime english: []const u8) ?[:0]const u8 {
    inline for (translations) |t| {
        if (comptime std.mem.eql(u8, pt, t.pt) and std.mem.eql(u8, english, t.en)) return t.ja;
    }
    return null;
}

pub fn set(l: Lang) void {
    lang.store(l, .release);
}

// Japanese uses English-only fallback branches until each string has a Japanese entry.
pub fn en() bool {
    const current = lang.load(.acquire);
    return current == .en or current == .ja;
}

pub fn tr(pt: []const u8, english: []const u8) []const u8 {
    const current = lang.load(.acquire);
    if (current == .ja) return japanese(pt, english) orelse english;
    return if (current == .en) english else pt;
}

pub fn trZ(pt: [:0]const u8, english: [:0]const u8) [:0]const u8 {
    const current = lang.load(.acquire);
    if (current == .ja) return japanese(pt, english) orelse english;
    return if (current == .en) english else pt;
}

/// Format text into a fixed buffer without cutting a UTF-8 character.
pub fn fmt(buf: []u8, comptime pt: []const u8, comptime english: []const u8, args: anytype) []const u8 {
    var wr = std.Io.Writer.fixed(buf);
    const current = lang.load(.acquire);
    const ja_format = comptime japaneseFormat(pt, english);
    if (current == .ja) {
        if (ja_format) |format| wr.print(format, args) catch {} else wr.print(english, args) catch {};
    } else if (current == .en) {
        wr.print(english, args) catch {};
    } else {
        wr.print(pt, args) catch {};
    }
    const out = wr.buffered();
    if (out.len < buf.len) return out;
    var k = out.len;
    while (k > 0 and (out[k - 1] & 0xC0) == 0x80) k -= 1;
    if (k > 0 and out[k - 1] >= 0xC0) {
        const want = std.unicode.utf8ByteSequenceLength(out[k - 1]) catch 1;
        if (out.len - (k - 1) < want) return out[0 .. k - 1];
    }
    return out;
}

pub fn fmtZ(buf: []u8, comptime pt: []const u8, comptime english: []const u8, args: anytype) [:0]const u8 {
    const current = lang.load(.acquire);
    const ja_format = comptime japaneseFormat(pt, english);
    if (current == .ja) {
        if (ja_format) |format| return std.fmt.bufPrintSentinel(buf, format, args, 0) catch "";
        return std.fmt.bufPrintSentinel(buf, english, args, 0) catch "";
    }
    return switch (current) {
        .en => std.fmt.bufPrintSentinel(buf, english, args, 0) catch "",
        .pt => std.fmt.bufPrintSentinel(buf, pt, args, 0) catch "",
        .ja => unreachable,
    };
}

pub fn allocPrint(gpa: std.mem.Allocator, comptime pt: []const u8, comptime english: []const u8, args: anytype) ![]u8 {
    const current = lang.load(.acquire);
    const ja_format = comptime japaneseFormat(pt, english);
    if (current == .ja) {
        if (ja_format) |format| return std.fmt.allocPrint(gpa, format, args);
        return std.fmt.allocPrint(gpa, english, args);
    }
    return switch (current) {
        .en => std.fmt.allocPrint(gpa, english, args),
        .pt => std.fmt.allocPrint(gpa, pt, args),
        .ja => unreachable,
    };
}

/// System language: Portuguese and Japanese are detected explicitly; English is the fallback.
pub fn system() Lang {
    var count: c_int = 0;
    const list = c.SDL_GetPreferredLocales(&count) orelse return .en;
    defer c.SDL_free(@ptrCast(list));
    if (count > 0) if (list[0]) |loc| {
        if (loc.*.language) |l| {
            const code = std.mem.span(l);
            if (std.mem.startsWith(u8, code, "pt")) return .pt;
            if (std.mem.startsWith(u8, code, "ja")) return .ja;
        }
    };
    return .en;
}

/// language setting: 0 = system, 1 = Portuguese, 2 = English, 3 = Japanese.
pub fn fromSetting(v: u8) Lang {
    return switch (v) {
        1 => .pt,
        2 => .en,
        3 => .ja,
        else => system(),
    };
}
