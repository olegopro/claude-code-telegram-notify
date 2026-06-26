#!/bin/sh
# Notification (matcher=permission_prompt): шлёт уведомление, когда Claude
# запрашивает разрешение на инструмент. Разделитель, жирный заголовок + папка,
# суть запроса. Если включён Remote Control — добавляет ссылку на сессию.
. "$HOME/.claude/hooks/tg-notify-lib.sh"

in=$(cat)
eval "$(printf '%s' "$in" | jq -r '@sh "m=\(.message // .hook_event_name // "") tp=\(.transcript_path // "") sid=\(.session_id // "")"')"
proj=$(basename "$CLAUDE_PROJECT_DIR")

msg=$(printf '%s\n\n\360\237\224\224 <b>Нужно разрешение</b> \302\267 %s\n\n%s%s' \
  "$TG_SEP" "$(tg_esc "$proj")" "$(tg_esc "$m")" "$(tg_rc_line "$tp")")

mid=$(tg_send "$msg")
[ -n "$mid" ] && [ -n "$sid" ] && printf '%s\n' "$mid" >> "/tmp/claude_notif_msg_${sid}"
exit 0
