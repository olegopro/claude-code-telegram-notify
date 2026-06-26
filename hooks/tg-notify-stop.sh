#!/bin/sh
# Stop: шлёт уведомление в Telegram, только если обработка запроса заняла
# не меньше порога (TELEGRAM_MIN_SECONDS, по умолчанию 180 = 3 минуты).
# Формат (HTML): разделитель, жирный заголовок с длительностью, переведённое
# на русский название треда (ai-title), имя папки. Если включён Remote Control —
# добавляется прямая ссылка на сессию.
# shellcheck disable=SC2154  # sid, tp приходят через eval "$(jq -r @sh ...)" ниже
. "$HOME/.claude/hooks/tg-notify-lib.sh"

in=$(cat)
eval "$(printf '%s' "$in" | jq -r '@sh "sid=\(.session_id // "") tp=\(.transcript_path // "")"')"
f="/tmp/claude_notif_${sid}"
# Порог берём из файла ~/.claude/telegram-min-seconds (читается с диска на каждый
# Stop — подхватывают и уже открытые сессии, не зависит от env-кэша и перезаписи
# settings.json). Фолбэк: env TELEGRAM_MIN_SECONDS, затем 180.
thr=$(cat "$HOME/.claude/telegram-min-seconds" 2>/dev/null | tr -dc '0-9')
[ -n "$thr" ] || thr="${TELEGRAM_MIN_SECONDS:-180}"

# нет отметки старта — тихо выходим
[ -f "$f" ] || { tg_log "Stop sid=$sid НЕТ отметки старта → выход"; exit 0; }
start=$(cat "$f")
rm -f "$f"
dur=$(( $(date +%s) - start ))
tg_log "Stop sid=$sid dur=${dur}s thr=${thr}s"

# короче порога — не засоряем чат
[ "$dur" -ge "$thr" ] || exit 0

# Фоновые shell ещё работают? Stop срабатывает на конце turn, а задачи из
# run_in_background живут дальше и реактивируют сессию позже. Если в транскрипте
# есть запущенный фоновый ID ("Command running in background with ID: X") без
# парного <task-id>X</task-id> (метка завершения) — turn кончился, а работа нет:
# молчим. Уведомление уйдёт на финальном Stop, когда фон вернулся и обработан.
if [ -n "$tp" ] && [ -f "$tp" ]; then
  bg_launched=$(grep -oE 'background with ID: [A-Za-z0-9]+' "$tp" | sed -E 's/.*: //' | sort -u)
  if [ -n "$bg_launched" ]; then
    bg_done=$(grep -oE '<task-id>[A-Za-z0-9]+</task-id>' "$tp" | sed -E 's#</?task-id>##g' | sort -u)
    if [ -z "$bg_done" ]; then
      bg_pending="$bg_launched"
    else
      bg_pending=$(printf '%s\n' "$bg_launched" | grep -vxF "$bg_done")
    fi
    if [ -n "$bg_pending" ]; then
      tg_log "Stop sid=$sid dur=${dur}s → отложено: фон не завершён ($(printf '%s' "$bg_pending" | tr '\n' ' '))"
      exit 0
    fi
  fi
fi

mins=$(( dur / 60 ))

proj=$(basename "$CLAUDE_PROJECT_DIR")

# название треда: последняя ai-title запись транскрипта
title=""
[ -n "$tp" ] && [ -f "$tp" ] && title=$(grep '"type":"ai-title"' "$tp" | tail -1 | jq -r '.aiTitle // empty')

# перевод названия на русский (Google Translate, fallback — оригинал).
# Отключить можно через TELEGRAM_TRANSLATE=0 — тогда заголовки тредов не уходят к Google.
if [ -n "$title" ] && [ "${TELEGRAM_TRANSLATE:-1}" != "0" ]; then
  tru=$(curl -s --max-time 4 -G \
    --data-urlencode "q=$title" \
    'https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=ru&dt=t' \
    | jq -r '[.[0][][0]] | join("")' 2>/dev/null)
  [ -n "$tru" ] && [ "$tru" != "null" ] && title="$tru"
fi

[ -z "$title" ] && title="$proj"

msg=$(printf '%s\n\n\342\234\205 <b>Завершено</b> \302\267 ~%s мин\n\n\360\237\223\213 <b>%s</b>\n\n\360\237\223\201 %s%s' \
  "$TG_SEP" "$mins" "$(tg_esc "$title")" "$(tg_esc "$proj")" "$(tg_rc_line "$tp")")

# отправляем и запоминаем message_id — чтобы стереть уведомление,
# если диалог будет продолжен в терминале (см. tg-notify-start.sh)
mid=$(tg_send "$msg")
[ -n "$mid" ] && printf '%s\n' "$mid" >> "/tmp/claude_notif_msg_${sid}"
exit 0
