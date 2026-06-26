#!/bin/sh
# UserPromptSubmit: (1) стирает ранее доставленные Telegram-уведомления этой
# сессии — раз диалог продолжен в терминале, непрочитанные сообщения на телефоне
# уже не нужны; (2) запоминает время старта обработки запроса по session_id.
# Важно: ничего не печатать в stdout — у UserPromptSubmit он попадает в контекст.
. "$HOME/.claude/hooks/tg-notify-lib.sh"
in=$(cat)
sid=$(printf '%s' "$in" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0

# удалить накопленные message_id (уведомления Stop/permission по этой сессии)
msgf="/tmp/claude_notif_msg_${sid}"
if [ -f "$msgf" ]; then
  while IFS= read -r mid; do
    tg_delete "$mid"
  done < "$msgf"
  rm -f "$msgf"
fi

date +%s > "/tmp/claude_notif_${sid}"
tg_log "UserPromptSubmit sid=$sid → отметка старта поставлена"
exit 0
