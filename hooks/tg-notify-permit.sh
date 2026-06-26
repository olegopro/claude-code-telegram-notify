#!/bin/sh
# PreToolUse: инструмент вот-вот выполнится — значит запрос разрешения (если был)
# уже одобрен в терминале. Стираем накопленные permission-уведомления этой сессии:
# одобрение разрешения НЕ генерирует UserPromptSubmit, поэтому tg-notify-start.sh
# их не трогает и они бы висели до нового промпта или закрытия сессии.
# Старт-метку /tmp/claude_notif_${sid} НЕ трогаем — она нужна хуку Stop.
. "$HOME/.claude/hooks/tg-notify-lib.sh"
in=$(cat)
sid=$(printf '%s' "$in" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0

msgf="/tmp/claude_notif_msg_${sid}"
[ -f "$msgf" ] || exit 0
while IFS= read -r mid; do
  tg_delete "$mid"
done < "$msgf"
rm -f "$msgf"
exit 0
