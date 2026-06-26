#!/bin/sh
# Удаление Telegram-уведомлений для Claude Code.
# Убирает хуки из settings.json (по сигнатуре tg-notify-), удаляет файлы хуков,
# выключает уведомления и чистит временные файлы.
# Секреты ~/.claude/telegram-notify.env НЕ трогает (чтобы не потерять токен) —
# удалите вручную при необходимости.
set -e

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

say() { printf '  %s\n' "$1"; }

echo "▶ Удаление Telegram-уведомлений для Claude Code"

# 1. вычистить наши хуки из settings.json (по подстроке "tg-notify-")
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1 && jq empty "$SETTINGS" 2>/dev/null; then
  cp "$SETTINGS" "$SETTINGS.bak"
  tmp=$(mktemp)
  jq '
    if .hooks then
      .hooks |= ( to_entries
        | map( .value |= map( .hooks |= map(select((.command // "") | test("tg-notify-") | not)) )
               | .value |= map(select((.hooks | length) > 0)) )
        | map(select((.value | length) > 0))
        | from_entries )
    else . end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  say "хуки убраны из $SETTINGS (бэкап: $SETTINGS.bak)"
else
  say "settings.json не найден или невалиден — пропуск"
fi

# 2. удалить файлы хуков
rm -f "$HOOKS_DIR"/tg-notify-*.sh
say "файлы хуков удалены из $HOOKS_DIR"

# 3. выключить и подчистить флаги/временное
rm -f "$CLAUDE_DIR/telegram-notify.on" "$CLAUDE_DIR/telegram-notify.debug"
rm -f /tmp/claude_notif_* 2>/dev/null || true
say "уведомления выключены, временные файлы очищены"

echo
echo "✓ Удалено. Секреты сохранены в $CLAUDE_DIR/telegram-notify.env"
echo "  Удалить и их:  rm $CLAUDE_DIR/telegram-notify.env"
