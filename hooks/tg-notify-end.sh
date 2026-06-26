#!/bin/sh
# SessionEnd: сессия закрыта (выход или закрытие терминала) — стираем оставшиеся
# Telegram-уведомления этой сессии, чтобы не копились, и чистим временные файлы.
# Срабатывает при штатном завершении; при kill -9 процесса хуки не выполняются.
. "$HOME/.claude/hooks/tg-notify-lib.sh"
in=$(cat)
sid=$(printf '%s' "$in" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0

# удалить накопленные message_id (уведомления Stop/permission этой сессии)
msgf="/tmp/claude_notif_msg_${sid}"
if [ -f "$msgf" ]; then
  while IFS= read -r mid; do
    tg_delete "$mid"
  done < "$msgf"
  rm -f "$msgf"
fi

# подчистить отметку времени старта, чтобы не оставалась в /tmp
rm -f "/tmp/claude_notif_${sid}"
exit 0
