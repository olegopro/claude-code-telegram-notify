#!/bin/sh
# Telegram-уведомления Claude Code — ОДИН скрипт вместо шести (объединены 2026-10-10).
#
# Зачем объединение: раньше на каждое событие был свой файл (tg-notify-start / -stop /
# -permit / -notification / -end / -debug / -chrome-apply), у всех общая шапка и общий
# импорт библиотеки — правка в одном месте повторялась шесть раз. Поведение сохранено
# ОДИН-В-ОДИН, а ветвление идёт по первому аргументу (подкоманда = смысл действия, а не
# имя события Claude Code: у одного события бывает разный смысл — см. chrome-*).
#
# Подкоманды и куда вешаются (settings.json):
#   prompt        ← UserPromptSubmit              снять уведомления сессии + метка старта хода
#   stop          ← Stop                          «Завершено ~N мин» — по порогу, с названием треда
#   permit        ← PreToolUse                    разрешение одобрено → снять его уведомления
#   ask           ← Notification (permission_prompt)  «Нужно разрешение» + текст запроса
#   chrome        ← PreToolUse И PostToolUse (matcher: chrome) — событие разбирается внутри:
#                   первый вызов Chrome шлёт «Нужно нажать Apply», успешный конец гасит его
#   end           ← SessionEnd                    снять всё оставшееся + подчистить /tmp
#   debug         ← PreCompact, SessionStart      запись события в лог (только при флаге)
#
# ОБЩИЕ ПРАВИЛА (унаследованы от прежних скриптов, нарушать нельзя):
#   • ничего не печатать в stdout — у UserPromptSubmit он попадает в контекст модели;
#   • отправка управляется флагом ~/.claude/telegram-notify.on (lib перечитывает с диска);
#   • message_id отправленных уведомлений пишутся в /tmp/claude_notif_msg_<sid>, чтобы
#     снять их, когда диалог продолжили в терминале.
#
# shellcheck disable=SC2154  # sid/tp/m и другие приходят через eval "$(jq -r @sh ...)"
. "$HOME/.claude/hooks/tg-notify-lib.sh"

in=$(cat)
cmd="${1:-}"

# Общие поля разбираем одним jq: session_id нужен почти везде, transcript_path — в stop/ask.
eval "$(printf '%s' "$in" | jq -r '@sh "sid=\(.session_id // "") tp=\(.transcript_path // "")"')"

# Снять все уведомления этой сессии (общий шаг для prompt / permit / end).
drop_messages() {
  msgf="/tmp/claude_notif_msg_${sid}"
  [ -f "$msgf" ] || return 0
  while IFS= read -r mid; do
    tg_delete "$mid"
  done < "$msgf"
  rm -f "$msgf"
}

case "$cmd" in
  prompt)
    # (1) стираем ранее доставленные уведомления: раз диалог продолжен в терминале,
    # непрочитанные сообщения на телефоне уже не нужны;
    # (2) запоминаем время старта обработки запроса — по нему Stop считает длительность.
    [ -n "$sid" ] || exit 0
    drop_messages
    date +%s > "/tmp/claude_notif_${sid}"
    tg_log "UserPromptSubmit sid=$sid → отметка старта поставлена"
    ;;

  stop)
    # Уведомление шлётся только если ход длился не меньше порога (TELEGRAM_MIN_SECONDS,
    # по умолчанию 180 с): короткие ответы не должны дёргать телефон.
    f="/tmp/claude_notif_${sid}"
    # Порог читается с диска на каждый вызов — подхватывается и уже открытыми сессиями.
    thr=$(cat "$HOME/.claude/telegram-min-seconds" 2>/dev/null | tr -dc '0-9')
    [ -n "$thr" ] || thr="${TELEGRAM_MIN_SECONDS:-180}"

    [ -f "$f" ] || { tg_log "Stop sid=$sid НЕТ отметки старта → выход"; exit 0; }
    start=$(cat "$f")
    rm -f "$f"
    dur=$(( $(date +%s) - start ))
    tg_log "Stop sid=$sid dur=${dur}s thr=${thr}s"
    [ "$dur" -ge "$thr" ] || exit 0

    # Фоновые задачи ещё работают? Stop срабатывает на конце turn, а run_in_background и
    # Workflow живут дальше и реактивируют сессию позже. Ищем запущенный фоновый ID без
    # парной метки <task-id>X</task-id> — работа не закончена: молчим, уведомление уйдёт
    # на финальном Stop, когда фон вернулся и обработан.
    if [ -n "$tp" ] && [ -f "$tp" ]; then
      bg_launched=$(grep -oE 'background with ID: [A-Za-z0-9_-]+|Workflow launched in background\. Task ID: [A-Za-z0-9_-]+' "$tp" | sed -E 's/.*: //' | sort -u)
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

    # название треда — последняя ai-title запись транскрипта
    title=""
    [ -n "$tp" ] && [ -f "$tp" ] && title=$(grep '"type":"ai-title"' "$tp" | tail -1 | jq -r '.aiTitle // empty')

    # перевод на русский (Google Translate, фолбэк — оригинал). Кириллицу не гоняем
    # через переводчик: не тратим и не шлём русский текст наружу. Отключается
    # TELEGRAM_TRANSLATE=0.
    if [ -n "$title" ] && [ "${TELEGRAM_TRANSLATE:-1}" != "0" ] && ! printf '%s' "$title" | LC_ALL=C grep -q '[^ -~]'; then
      tru=$(curl -s --max-time 4 -G \
        --data-urlencode "q=$title" \
        'https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=ru&dt=t' \
        | jq -r '[.[0][][0]] | join("")' 2>/dev/null)
      [ -n "$tru" ] && [ "$tru" != "null" ] && title="$tru"
    fi
    [ -z "$title" ] && title="$proj"

    msg=$(printf '%s\n\n\342\234\205 <b>Завершено</b> \302\267 ~%s мин\n\n\360\237\223\213 <b>%s</b>\n\n\360\237\223\201 %s%s' \
      "$TG_SEP" "$mins" "$(tg_esc "$title")" "$(tg_esc "$proj · $(tg_host)")" "$(tg_rc_line "$tp")")

    mid=$(tg_send "$msg")
    [ -n "$mid" ] && printf '%s\n' "$mid" >> "/tmp/claude_notif_msg_${sid}"
    ;;

  permit)
    # Инструмент вот-вот выполнится — значит запрос разрешения уже одобрен в терминале.
    # Одобрение не генерирует UserPromptSubmit, поэтому чистить надо здесь, иначе
    # permission-уведомление висело бы до нового промпта или закрытия сессии.
    # Метку старта /tmp/claude_notif_${sid} НЕ трогаем — она нужна хуку stop.
    [ -n "$sid" ] || exit 0
    drop_messages
    ;;

  ask)
    # Notification (matcher=permission_prompt): Claude просит разрешение на инструмент.
    m=$(printf '%s' "$in" | jq -r '.message // .hook_event_name // ""')
    proj=$(basename "$CLAUDE_PROJECT_DIR")
    msg=$(printf '%s\n\n\360\237\224\224 <b>Нужно разрешение</b> \302\267 %s\n\n%s%s' \
      "$TG_SEP" "$(tg_esc "$proj · $(tg_host)")" "$(tg_esc "$m")" "$(tg_rc_line "$tp")")
    mid=$(tg_send "$msg")
    [ -n "$mid" ] && [ -n "$sid" ] && printf '%s\n' "$mid" >> "/tmp/claude_notif_msg_${sid}"
    ;;

  chrome)
    # Одна подкоманда на два события (PreToolUse и PostToolUse с matcher на chrome):
    # различаем по hook_event_name из входа — иначе пришлось бы держать два вызова.
    # Состояния метки /tmp/claude_chrome_apply_<sid>: нет файла — Chrome ещё не звали;
    # <message_id> — уведомление висит; done — уже погашено (Apply нажат).
    [ -n "$sid" ] || exit 0
    mark="/tmp/claude_chrome_apply_${sid}"
    evt=$(printf '%s' "$in" | jq -r '.hook_event_name // empty')
    case "$evt" in
      PostToolUse)
        # инструмент Chrome отработал → Apply нажат → гасим висящее уведомление
        [ -f "$mark" ] || exit 0
        mid=$(cat "$mark")
        case "$mid" in
          ''|done) ;;
          *) tg_delete "$mid"; printf 'done' > "$mark" ;;
        esac
        ;;
      *)
        # PreToolUse: шлём только на самый первый вызов Chrome в сессии
        [ -f "$mark" ] && exit 0
        proj=$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")
        msg=$(printf '%s\n\n\360\237\214\220 <b>Нужно нажать Apply в Chrome</b> \302\267 %s\n\nБраузер ждёт подтверждения подключения.' \
          "$TG_SEP" "$(tg_esc "$proj · $(tg_host)")")
        mid=$(tg_send "$msg")
        printf '%s' "${mid:-done}" > "$mark"
        ;;
    esac
    ;;

  end)
    # SessionEnd: сессия закрыта — снимаем оставшиеся уведомления и чистим /tmp.
    # Срабатывает при штатном завершении; при kill -9 хуки не выполняются.
    [ -n "$sid" ] || exit 0
    drop_messages
    rm -f "/tmp/claude_notif_${sid}"
    ;;

  debug)
    # Только для отладки: через tg_log, поэтому молчит без флага ~/.claude/telegram-notify.debug.
    eval "$(printf '%s' "$in" | jq -r '@sh "ev=\(.hook_event_name // "?") src=\(.source // "") trg=\(.trigger // "")"')"
    tg_log "EVENT=$ev sid=$sid src=$src trg=$trg"
    ;;

  *)
    tg_log "tg-notify.sh: неизвестная подкоманда '$cmd' — выход"
    ;;
esac

exit 0
