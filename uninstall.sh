#!/bin/sh
# Удаление Telegram-уведомлений для Claude Code.
# Трогает ТОЛЬКО свои файлы и записи (по точному списку хуков этого проекта) —
# посторонние хуки в settings.json и каталоге не затрагиваются.
# Секреты ~/.claude/telegram-notify.env НЕ трогает (чтобы не потерять токен) —
# удалите вручную при необходимости.
set -e

CLAUDE_DIR="${CLAUDE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

# файлы этого проекта (и только они)
HOOKS="tg-notify-lib.sh tg-notify-start.sh tg-notify-stop.sh tg-notify-notification.sh tg-notify-permit.sh tg-notify-end.sh tg-notify-debug.sh"
# имена хуков, которые регистрируются в settings.json (lib не регистрируется).
# Якорь "/" перед именем — чтобы не задеть посторонние вроде tg-notify-chrome-apply.sh
# или гипотетический my-tg-notify-end.sh.
OURS='/tg-notify-(start|stop|notification|permit|end|debug)\.sh'

say() { printf '  %s\n' "$1"; }

echo "▶ Удаление Telegram-уведомлений для Claude Code"

# 1. вычистить из settings.json ТОЛЬКО наши хуки (по точному списку, не маской —
#    чтобы не задеть посторонние хуки вроде tg-notify-chrome-apply.sh или прокси)
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1 && jq empty "$SETTINGS" 2>/dev/null; then
  cp "$SETTINGS" "$SETTINGS.bak"
  tmp=$(mktemp)
  jq --arg ours "$OURS" '
    if .hooks then
      .hooks |= ( to_entries
        | map( .value |= map( .hooks |= map(select((.command // "") | test($ours) | not)) )
               | .value |= map(select((.hooks | length) > 0)) )
        | map(select((.value | length) > 0))
        | from_entries )
    else . end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  say "наши хуки убраны из $SETTINGS (бэкап: $SETTINGS.bak)"
else
  say "settings.json не найден или невалиден — пропуск"
fi

# 2. удалить файлы хуков (только свои, по списку)
for h in $HOOKS; do rm -f "$HOOKS_DIR/$h"; done
say "файлы хуков удалены из $HOOKS_DIR"

# 3. выключить и подчистить флаги/временное
#    ВНИМАНИЕ: /tmp/claude_notif_* — общие для всех сессий; чистка собьёт метки
#    у параллельных активных сессий (восстановятся при следующем промпте).
rm -f "$CLAUDE_DIR/telegram-notify.on" "$CLAUDE_DIR/telegram-notify.debug"
rm -f /tmp/claude_notif_* 2>/dev/null || true
say "уведомления выключены, временные файлы очищены"

echo
echo "✓ Удалено. Секреты сохранены в $CLAUDE_DIR/telegram-notify.env"
echo "  Удалить и их:  rm $CLAUDE_DIR/telegram-notify.env"
