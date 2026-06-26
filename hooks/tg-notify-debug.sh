#!/bin/sh
# Только для отладки: логирует факт срабатывания события (PreCompact, SessionStart
# и т.п.) с session_id и источником/триггером. Пишет через tg_log, поэтому молчит,
# если нет флага ~/.claude/telegram-notify.debug. Поведение уведомлений не меняет.
# shellcheck disable=SC2154  # ev, sid, src, trg приходят через eval "$(jq -r @sh ...)" ниже
. "$HOME/.claude/hooks/tg-notify-lib.sh"
in=$(cat)
eval "$(printf '%s' "$in" | jq -r '@sh "ev=\(.hook_event_name // "?") sid=\(.session_id // "") src=\(.source // "") trg=\(.trigger // "")"')"
tg_log "EVENT=$ev sid=$sid src=$src trg=$trg"
exit 0
