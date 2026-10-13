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
#   question      ← PermissionRequest (matcher: AskUserQuestion)  вопрос Claude → Telegram с
#                   кнопками; ответ уходит обратно в Claude Code (параллельно диалогу в терминале)
#   answered      ← PostToolUse (matcher: AskUserQuestion)        вопрос отвечен где-то ещё —
#                   сообщить ждущему question, чтобы тот прибрал Telegram
#   end           ← SessionEnd                    снять всё оставшееся + подчистить /tmp
#   debug         ← PreCompact, SessionStart      запись события в лог (только при флаге)
#
# ОБЩИЕ ПРАВИЛА (унаследованы от прежних скриптов, нарушать нельзя):
#   • ничего не печатать в stdout — у UserPromptSubmit он попадает в контекст модели.
#     Единственное исключение — question: его JSON-решение (allow + answers) и есть ответ хука;
#   • отправка управляется флагом ~/.claude/telegram-notify.on (lib перечитывает с диска);
#     вопросы с кнопками — отдельным флагом ~/.claude/telegram-question.on;
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

# Название треда для шапки (stop / question): последняя ai-title запись транскрипта.
# Перевод на русский (Google Translate, фолбэк — оригинал). Кириллицу не гоняем через
# переводчик: не тратим и не шлём русский текст наружу. Отключается TELEGRAM_TRANSLATE=0.
# Нет названия — имя папки проекта ($proj задаёт вызывающий).
session_title() {
  st_title=""
  [ -n "$tp" ] && [ -f "$tp" ] && st_title=$(grep '"type":"ai-title"' "$tp" | tail -1 | jq -r '.aiTitle // empty')
  if [ -n "$st_title" ] && [ "${TELEGRAM_TRANSLATE:-1}" != "0" ] && ! printf '%s' "$st_title" | LC_ALL=C grep -q '[^ -~]'; then
    st_tru=$(curl -s --max-time 4 -G \
      --data-urlencode "q=$st_title" \
      'https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=ru&dt=t' \
      | jq -r '[.[0][][0]] | join("")' 2>/dev/null)
    [ -n "$st_tru" ] && [ "$st_tru" != "null" ] && st_title="$st_tru"
  fi
  [ -z "$st_title" ] && st_title="$proj"
  printf '%s' "$st_title"
}

# ── Вопросы AskUserQuestion с кнопками (подкоманда question) ───────────────────────────
# PermissionRequest срабатывает сразу, как Claude Code собрался показать диалог, и идёт
# ПАРАЛЛЕЛЬНО с ним — кто ответил первым, того ответ и применяется (проверено на 2.1.294,
# в т.ч. при permissions.defaultMode=bypassPermissions). Вопрос уходит в Telegram с кнопками;
# нажатия приходят коротким опросом getUpdates; решение хук печатает в stdout:
# allow + updatedInput {questions, answers} — ровно как если бы ответили в диалоге.
#
# Состояние ожидающего вопроса — файл /tmp/claude_tg_q_<sid>:
#   pending <pid> <rid>        хук ждёт ответа
#   done <pid> <answers-json>  ответили в терминале (пишет PostToolUse → подкоманда answered)
#   (файла нет)                вопрос снят: новый промпт, Stop, закрытие сессии
# Ждущий хук проверяет файл на каждой итерации и сам прибирает своё сообщение в Telegram:
# сам Claude Code хук при ответе в терминале не останавливает (только по Esc — SIGTERM).
# Stop приходит через секунды после PostToolUse, а длинный опрос проверяет файл раз в ~5 с:
# «done» поэтому Stop/prompt не стирают, пока хук жив, — иначе ответ терялся бы (q_clear).
#
# Серия вопросов листается в ОДНОМ сообщении: экран q_idx = 0..n-1 — вопросы, n — «Проверка»
# (сводка ответов; «Отправить» появляется, когда отвечены все). Состояние каждого вопроса —
# q_sts[i] = {sel, txt, done}: назад/вперёд ничего не теряют, отметки чекбоксов сохраняются.
#
# Чужие нажатия (другая сессия, другая машина на том же боте) не подтверждаются: offset не
# уходит выше самого старого чужого обновления — поэтому общий бот работает без блокировок.

# общие определения jq для вопросов: экранирование, обрезка и ответ на вопрос по его состоянию.
# Состояние вопроса — {sel: [индексы вариантов], txt: "свой текст", done: отвечен ли}.
# Ответ: чекбоксы — метки отмеченных и свой текст через «, »; одиночный — свой текст, иначе метка.
q_jqdefs='
  def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
  def cut($k): if length > $k then .[0:$k] + "…" else . end;
  def ans($q; $s):
    if ($q.multiSelect // false) then
      ([ $s.sel[] as $i | ($q.options[$i].label // "") ]
       + (if ($s.txt // "") != "" then [$s.txt] else [] end)) | join(", ")
    elif ($s.txt // "") != "" then $s.txt
    elif ($s.sel | length) > 0 then ($q.options[$s.sel[0]].label // "")
    else "" end;
'

# разобрать вопрос q_idx: q_cur (JSON), q_qtext, q_nopt, q_multi (true/false)
q_load() {
  q_cur=$(printf '%s' "$q_qs" | jq -c ".[$q_idx]")
  eval "$(printf '%s' "$q_cur" | jq -r '@sh "q_qtext=\(.question // "") q_nopt=\(.options // [] | length) q_multi=\(.multiSelect // false)"')"
}

# отрисовать экран q_idx: вопрос (0..n-1) или проверка (n, только в серии) → JSON {text, keyboard}.
# callback_data = q<rid>:<номер экрана>:<действие>; действия: o<N> вариант, t свой текст,
# d готово (чекбоксы), p назад, x вперёд, s отправить (проверка), e<N> к вопросу N (проверка)
q_render() {
  printf '%s' "$q_qs" | jq -c \
    --argjson idx "$q_idx" --argjson st "$q_sts" --arg rid "$q_rid" \
    --arg title "$q_title" --arg proj "$q_proj" --arg host "$q_host" --arg rc "$q_rc" \
    "$q_jqdefs"'
    def cd($a): "q" + $rid + ":" + ($idx | tostring) + ":" + $a;
    def hdr($sub):
      "❓ <b>Вопрос Claude</b>" + $sub
      + (if $title != "" then "\n\n📋 <b>" + ($title | esc) + "</b>" else "" end)
      + "\n\n📁 " + ($proj | esc) + "\n💻 " + ($host | esc);
    . as $qs
    | ($qs | length) as $n
    | if $idx >= $n then
        { text: (hdr(" · Проверка") + "\n\nПроверьте ответы и отправьте:"
                 + ([ range(0; $n) as $i | $qs[$i] as $q | ans($q; $st[$i]) as $a
                      | "\n\n" + (($i + 1) | tostring) + ". <b>" + ($q.question | cut(200) | esc) + "</b>\n"
                        + (if $st[$i].done then "→ " + ($a | cut(300) | esc) else "⚠️ не отвечено" end) ] | join(""))
                 + $rc),
          keyboard: {inline_keyboard: (
            [ [ range(0; $n) as $i | {text: ("✏️ " + (($i + 1) | tostring)), callback_data: cd("e" + ($i | tostring))} ] ]
            + [ [ {text: "◀ Назад", callback_data: cd("p")} ]
                + (if all($st[]; .done) then [ {text: "✅ Отправить", callback_data: cd("s")} ] else [] end) ]
          )} }
      else
        $qs[$idx] as $q
        | ($q.multiSelect // false) as $multi
        | ($q.options // []) as $o
        | $st[$idx] as $s
        | [range(0; ($o | length))] as $ix
        | ans($q; $s) as $a
        | { text: (hdr((if $n > 1 then " · " + (($idx + 1) | tostring) + "/" + ($n | tostring) else "" end)
                       + (if ($q.header // "") != "" then " · <i>" + ($q.header | cut(24) | esc) + "</i>" else "" end))
                   + "\n\n<b>" + (($q.question // "") | cut(700) | esc) + "</b>\n\n"
                   + ([ $ix[] as $i | $o[$i]
                        | (($i + 1 | tostring) + ". <b>" + ((.label // "") | cut(80) | esc) + "</b>"
                           + (if (.description // "") != "" then " — " + (.description | cut(220) | esc) else "" end)
                           + (if (.preview // "") != "" then "\n<pre>" + (.preview | cut(320) | esc) + "</pre>" else "" end)) ]
                      | join("\n\n"))
                   + (if $multi then
                        "\n\n" + (if $a != "" then "☑ Выбрано: " + ($a | cut(200) | esc) else "Отметьте варианты и нажмите «Готово»" end)
                      elif $s.done then "\n\n✓ Ваш ответ: " + ($a | cut(200) | esc)
                      else "" end)
                   + (if $n > 1 then "\n\nОтвечено: " + (([ $st[] | select(.done) ] | length) | tostring) + " из " + ($n | tostring) else "" end)
                   + $rc),
            keyboard: {inline_keyboard: (
              [ $ix[] as $i
                | [ {text: ((if $multi then (if ($s.sel | index($i)) != null then "☑ " else "☐ " end)
                             elif ($s.sel | index($i)) != null then "✓ " else "" end)
                            + ($i + 1 | tostring) + ". " + (($o[$i].label // "") | cut(44))),
                     callback_data: cd("o" + ($i | tostring))} ] ]
              + [ [ {text: "✍️ Свой вариант", callback_data: cd("t")} ]
                  + (if $multi then [ {text: "✅ Готово", callback_data: cd("d")} ] else [] end) ]
              + (if $n > 1 then
                   [ (if $idx > 0 then [ {text: "◀ Назад", callback_data: cd("p")} ] else [] end)
                     + [ {text: (if $idx == $n - 1 then "Проверка ▶" else "Вперёд ▶" end), callback_data: cd("x")} ] ]
                 else [] end)
            )} }
      end'
}

# итоговый текст сообщения: $1 = строка статуса (HTML), $2 = JSON ответов {вопрос: ответ}
q_summary() {
  q_a="$2"; [ -n "$q_a" ] || q_a='{}'
  printf '%s' "$q_qs" | jq -r --arg st "$1" --arg title "$q_title" \
    --arg proj "$q_proj" --arg host "$q_host" --argjson a "$q_a" "$q_jqdefs"'
    $st
    + (if $title != "" then "\n\n📋 <b>" + ($title | esc) + "</b>" else "" end)
    + "\n\n📁 " + ($proj | esc) + "\n💻 " + ($host | esc)
    + ([ .[] | . as $q | ($a[$q.question] // null) as $v | select($v != null)
         | "\n\n<b>" + ($q.question | cut(200) | esc) + "</b>\n→ " + ($v | cut(300) | esc) ] | join(""))'
}

# снять состояние вопроса ($1 = файл): «pending» — всегда (вопрос закрыт без ответа);
# «done» — только если ждущего хука уже нет: живой хук сам прочтёт ответы и приберётся
q_clear() {
  [ -f "$1" ] || return 0
  read -r qc_st qc_pid _ < "$1"
  if [ "$qc_st" = "done" ] && kill -0 "$qc_pid" 2>/dev/null; then
    return 0
  fi
  rm -f "$1"
}

# вызвать команду в фоне со своими дескрипторами: там, где ответ не нужен, а сеть до Telegram
# даёт ~1 с на вызов — ждать нечего
q_bg() { ( "$@" >/dev/null 2>&1 & ); }

# перерисовать текущий экран в том же сообщении (в пачке нажатий — один раз, в конце: q_dirty).
# Правка уходит в фоне: пока она летит (~1 с через VPN), уже идёт следующий опрос и второе
# нажатие не ждёт, пока «прогреется» новое соединение. Правки строго по очереди — следующая
# стартует после завершения предыдущей, иначе устаревший экран мог бы лечь поверх нового.
q_redraw() {
  [ -n "$q_edpid" ] && wait "$q_edpid" 2>/dev/null
  q_r=$(q_render)
  tg_edit "$q_mid" "$(printf '%s' "$q_r" | jq -r .text)" "$(printf '%s' "$q_r" | jq -c .keyboard)" >/dev/null 2>&1 &
  q_edpid=$!
}

# изменить состояние текущего вопроса: $1 = jq-фильтр над массивом состояний ($i — номер
# вопроса), остальное — дополнительные аргументы jq
q_upd() {
  q_f="$1"; shift
  q_sts=$(printf '%s' "$q_sts" | jq -c --argjson i "$q_idx" "$@" "$q_f")
}

# у текущего вопроса есть что отправлять (отмеченный вариант или свой текст)
q_has_answer() {
  printf '%s' "$q_sts" | jq -e --argjson i "$q_idx" '.[$i] | ((.sel | length) > 0) or (.txt != "")' >/dev/null 2>&1
}

# перейти на экран $1 (вопрос или проверка); висящую подсказку «свой вариант» снимаем —
# она относилась к прежнему вопросу
q_goto() {
  q_idx=$1
  if [ -n "$q_prompt" ]; then
    q_bg tg_delete "$q_prompt"
    q_prompt=''
    q_pmids="[$q_mid]"
  fi
  [ "$q_idx" -lt "$q_n" ] && q_load
  q_dirty=1
}

# ответ на текущий вопрос принят: один вопрос — конец; серия — следующий вопрос, а после
# последнего экран проверки (там можно вернуться и поправить). Если к вопросу пришли с экрана
# проверки (✏️), после ответа возвращаемся туда же, а не листаем дальше (q_rev).
q_next() {
  if [ "$q_n" -le 1 ]; then
    q_fin=1
  elif [ "$q_rev" = 1 ]; then
    q_rev=0
    q_goto "$q_n"
  else
    q_goto $((q_idx + 1))
  fi
}

# «✍️ Свой вариант»: просим ответить на сообщение текстом (force_reply открывает поле ввода)
q_ask_text() {
  [ -n "$q_prompt" ] && q_bg tg_delete "$q_prompt"
  q_prompt=$(tg_send_kb '✍️ <b>Напишите свой вариант</b> — ответом на это сообщение.' \
    '{"force_reply":true,"input_field_placeholder":"Ваш вариант…"}')
  if [ -n "$q_prompt" ]; then q_pmids="[$q_mid,$q_prompt]"; else q_pmids="[$q_mid]"; fi
}

# нажата кнопка (ev_cb ev_qi ev_act)
q_on_click() {
  # кнопка с устаревшего экрана (двойной тап, запаздывающий клиент): без этой проверки
  # двойное «Вперёд» перепрыгнуло бы через вопрос
  if [ "$ev_qi" != "$q_idx" ]; then
    tg_cb_answer "$ev_cb" "Экран уже обновился — нажмите ещё раз"
    return 0
  fi
  # кнопки вопроса на экране проверки не работают
  case "$ev_act" in
    o[0-9]*|d|t|x)
      if [ "$q_idx" -ge "$q_n" ]; then tg_cb_answer "$ev_cb"; return 0; fi
      ;;
  esac
  case "$ev_act" in
    o[0-9]*)
      q_i=${ev_act#o}
      case "$q_i" in *[!0-9]*) tg_cb_answer "$ev_cb"; return 0 ;; esac
      if [ "$q_i" -ge "$q_nopt" ]; then tg_cb_answer "$ev_cb"; return 0; fi
      if [ "$q_multi" = true ]; then
        # переключатель; «отвечен» сохраняется, пока остаётся хоть что-то отмеченное
        q_upd '.[$i] |= (.sel as $s
          | (if ($s | index($p)) != null then ($s - [$p]) else (($s + [$p]) | sort) end) as $n
          | {sel: $n, txt: .txt, done: (.done and (($n | length) > 0 or .txt != ""))})' --argjson p "$q_i"
        tg_cb_answer "$ev_cb"
        q_dirty=1
      else
        q_label=$(printf '%s' "$q_cur" | jq -r --argjson i "$q_i" '.options[$i].label // ""')
        q_upd '.[$i] = {sel: [$p], txt: "", done: true}' --argjson p "$q_i"
        tg_cb_answer "$ev_cb" "✓ $q_label"
        q_next
      fi
      ;;
    d)
      if q_has_answer; then
        q_upd '.[$i].done = true'
        tg_cb_answer "$ev_cb" "✓ Готово"
        q_next
      else
        tg_cb_answer "$ev_cb" "Отметьте хотя бы один вариант"
      fi
      ;;
    t)
      tg_cb_answer "$ev_cb" "Напишите ответ в чат"
      q_ask_text
      ;;
    p)
      q_rev=0
      tg_cb_answer "$ev_cb"
      [ "$q_idx" -gt 0 ] && q_goto $((q_idx - 1))
      ;;
    x)
      q_rev=0
      # чекбоксы с отметками при «Вперёд» считаем подтверждёнными — отдельное «Готово» не нужно
      [ "$q_multi" = true ] && q_upd '.[$i] |= (if .done or ((.sel | length) == 0 and .txt == "") then . else .done = true end)'
      tg_cb_answer "$ev_cb"
      q_goto $((q_idx + 1))
      ;;
    s)
      if [ "$q_idx" -ge "$q_n" ] && printf '%s' "$q_sts" | jq -e 'all(.[]; .done)' >/dev/null 2>&1; then
        tg_cb_answer "$ev_cb" "✓ Отправлено"
        q_fin=1
      else
        tg_cb_answer "$ev_cb" "Есть неотвеченные вопросы"
      fi
      ;;
    e[0-9]*)
      q_i=${ev_act#e}
      case "$q_i" in *[!0-9]*) tg_cb_answer "$ev_cb"; return 0 ;; esac
      tg_cb_answer "$ev_cb"
      if [ "$q_i" -lt "$q_n" ]; then
        q_rev=1
        q_goto "$q_i"
      fi
      ;;
    *) tg_cb_answer "$ev_cb" ;;
  esac
}

# пришёл текст ответом на вопрос или на подсказку «Свой вариант» (ev_text, ev_mid)
# чекбоксы: текст дописывается к отмеченным; одиночный вопрос — заменяет выбор
q_on_text() {
  [ -n "$ev_text" ] || return 0
  # на экране проверки текст не к чему привязать
  [ "$q_idx" -lt "$q_n" ] || return 0
  q_bg tg_delete "$ev_mid"
  if [ -n "$q_prompt" ]; then
    q_bg tg_delete "$q_prompt"
    q_prompt=''
    q_pmids="[$q_mid]"
  fi
  q_upd '.[$i] |= (.txt = $t | .done = true | if $m then . else .sel = [] end)' \
    --arg t "$ev_text" --argjson m "$q_multi"
  q_next
}

# один опрос Telegram: разобрать обновления, отреагировать на наши, сдвинуть q_off.
# Класс обновления (k): cb/text — наше; stale — кнопка давно закрытого вопроса;
# pin — чужое, ещё живое (не подтверждаем); drop — не интересно; done — уже обработано нами.
# Возвращает 1, если Telegram недоступен (409 при вебхуке, сеть) — итерация пропускается.
q_poll() {
  # Длинный опрос: ответ приходит в момент нажатия. Секунд — не больше остатка до дедлайна,
  # чтобы выход по таймауту не запаздывал. curl идёт в фоне, а ждём его через wait: сигнал
  # (Esc → SIGTERM) тогда срабатывает сразу, не после ответа сервера.
  q_lp=$(( q_deadline - $(date +%s) ))
  [ "$q_lp" -gt "${TELEGRAM_QUESTION_LONGPOLL:-5}" ] && q_lp="${TELEGRAM_QUESTION_LONGPOLL:-5}"
  [ "$q_lp" -lt 1 ] && q_lp=0
  tg_updates "$q_off" "$q_lp" > "$q_respf" 2>/dev/null &
  q_cpid=$!
  wait "$q_cpid"
  q_cpid=''
  q_resp=$(cat "$q_respf" 2>/dev/null)
  if ! printf '%s' "$q_resp" | jq -e '.ok == true' >/dev/null 2>&1; then
    tg_log "question sid=$sid: getUpdates недоступен: $(printf '%s' "$q_resp" | cut -c1-120)"
    return 1
  fi
  q_res=$(printf '%s' "$q_resp" | jq -c --arg chat "$TELEGRAM_CHAT_ID" --arg rid "$q_rid" \
    --argjson pm "$q_pmids" --argjson seen "$q_seen" --argjson now "$(date +%s)" \
    --argjson maxage "$q_maxage" '
    def cls:
      . as $u
      | if ($seen | index($u.update_id)) != null then {uid: $u.update_id, k: "done"}
        elif $u.callback_query != null then
          $u.callback_query as $c
          | (($c.message.chat.id // "") | tostring) as $cid
          | ($c.data // "") as $d
          | if $cid != $chat then {uid: $u.update_id, k: "drop"}
            elif ($d | startswith("q" + $rid + ":")) then
              ($d | split(":")) as $p
              | {uid: $u.update_id, k: "cb", cb: $c.id, qi: (($p[1] // "") | tonumber? // -1),
                 act: ($p[2] // ""), mid: $c.message.message_id}
            elif ($d | test("^q[0-9a-f]+:")) then
              if ($now - ($c.message.date // 0)) > $maxage
              then {uid: $u.update_id, k: "stale", cb: $c.id, mid: $c.message.message_id}
              else {uid: $u.update_id, k: "pin"} end
            else {uid: $u.update_id, k: "drop"} end
        elif $u.message != null then
          $u.message as $m
          | if (($m.chat.id // "") | tostring) != $chat then {uid: $u.update_id, k: "drop"}
            elif $m.reply_to_message == null then {uid: $u.update_id, k: "drop"}
            elif ($pm | index($m.reply_to_message.message_id)) != null then
              {uid: $u.update_id, k: "text", text: ($m.text // ""), mid: $m.message_id}
            elif ($now - ($m.reply_to_message.date // 0)) > $maxage then {uid: $u.update_id, k: "drop"}
            else {uid: $u.update_id, k: "pin"} end
        else {uid: $u.update_id, k: "drop"} end;
    [.result[] | cls] as $e
    | {events: [$e[] | select(.k == "cb" or .k == "text" or .k == "stale")],
       off: (([$e[] | select(.k == "pin") | .uid] | min)
             // (([$e[].uid] | max) as $mx | if $mx == null then null else $mx + 1 end))}')
  q_o=$(printf '%s' "$q_res" | jq -r '.off // empty')
  [ -n "$q_o" ] && q_off="$q_o"
  printf '%s' "$q_res" | jq -c '.events[]' > "$q_evf"
  while IFS= read -r q_e; do
    eval "$(printf '%s' "$q_e" | jq -r '@sh "ev_k=\(.k) ev_uid=\(.uid) ev_cb=\(.cb // "") ev_qi=\(.qi // -1) ev_act=\(.act // "") ev_mid=\(.mid // "")"')"
    q_seen=$(printf '%s' "$q_seen" | jq -c --argjson u "$ev_uid" '. + [$u]')
    case "$ev_k" in
      stale)
        tg_cb_answer "$ev_cb" "Этот вопрос уже закрыт"
        tg_edit_kb "$ev_mid" ""
        ;;
      cb) q_on_click ;;
      text)
        ev_text=$(printf '%s' "$q_e" | jq -r '.text')
        q_on_text
        ;;
    esac
    [ "$q_fin" = 1 ] && break
  done < "$q_evf"
  # пачка нажатий — одна правка сообщения в конце, а не по правке на каждое
  if [ "$q_dirty" = 1 ] && [ "$q_fin" != 1 ]; then
    q_dirty=0
    q_redraw
  fi
  return 0
}

# подтвердить в Telegram всё, что мы обработали: иначе нажатие осталось бы в очереди и
# ещё час перечитывалось бы чужими хуками (offset держится ниже самого старого чужого)
q_confirm() {
  [ -n "$q_off" ] && tg_updates "$q_off" >/dev/null
}

# выход из question (trap EXIT): прибрать сообщение в Telegram по причине выхода q_end
q_exit() {
  trap - EXIT
  # в журнал (только при флаге отладки): чем закончился вопрос — answered / terminal /
  # timeout / closed; пусто — сигнал (Esc, закрытие сессии)
  tg_log "question sid=$sid → выход: ${q_end:-сигнал}"
  q_a=""
  case "$q_end" in
    answered) q_st="✅ <b>Ответ отправлен</b>"; q_a="$q_answers" ;;
    terminal) q_st="🖥 <b>Отвечено в терминале</b>"
              [ -f "$qf" ] && q_a=$(sed -n 's/^done [0-9]* //p' "$qf" | head -1) ;;
    timeout)  q_st="⏱ <b>Время ожидания вышло</b> — ответьте в терминале" ;;
    closed)   q_st="➖ <b>Вопрос закрыт</b>" ;;
    *)        q_st="🚫 <b>Отменено в терминале</b>" ;;
  esac
  # остаётся в чате как отметка; снимется со следующим действием в терминале (drop_messages)
  [ -n "$q_mid" ] && printf '%s\n' "$q_mid" >> "/tmp/claude_notif_msg_${sid}"
  [ -n "$q_cpid" ] && kill "$q_cpid" 2>/dev/null
  # летящая правка экрана должна завершиться до итогового текста, иначе порядок не гарантирован
  [ -n "$q_edpid" ] && wait "$q_edpid" 2>/dev/null
  rm -f "$qf" "$q_evf" "$q_respf"
  if [ "$q_end" = answered ]; then
    # правка уходит в фоне со своими дескрипторами: хук должен завершиться сразу —
    # Claude Code применит решение только после выхода процесса
    { [ -n "$q_prompt" ] && tg_delete "$q_prompt"
      tg_edit "$q_mid" "$(q_summary "$q_st" "$q_a")"
      q_confirm; } >/dev/null 2>&1 &
  else
    [ -n "$q_prompt" ] && q_bg tg_delete "$q_prompt"
    tg_edit "$q_mid" "$(q_summary "$q_st" "$q_a")"
    q_confirm
  fi
}

ask_question() {
  [ -n "$sid" ] || return 0
  tg_enabled || return 0
  [ -f "$HOME/.claude/telegram-question.on" ] || return 0
  [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || return 0

  q_qs=$(printf '%s' "$in" | jq -c '.tool_input.questions // empty' 2>/dev/null)
  q_n=$(printf '%s' "$q_qs" | jq 'length' 2>/dev/null)
  case "$q_n" in ''|*[!0-9]*|0) return 0 ;; esac

  qf="/tmp/claude_tg_q_${sid}"
  # повторный вызов на тот же вопрос: первый хук ещё жив — второй не нужен
  if [ -f "$qf" ]; then
    read -r q_st q_opid _ < "$qf"
    [ "$q_st" = pending ] && kill -0 "$q_opid" 2>/dev/null && return 0
  fi

  q_rid=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$q_rid" ] || q_rid=$(printf '%s%s' "$sid" "$$" | cksum | cut -d' ' -f1)
  proj=$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")
  q_proj="$proj"
  q_host=$(tg_host)
  # без перевода: первое сообщение должно уйти сразу, а не ждать Google Translate
  q_title=$(TELEGRAM_TRANSLATE=0 session_title)
  # названия ещё нет (свежая сессия) — session_title вернул папку, а она и так в строке 📁
  [ "$q_title" = "$proj" ] && q_title=""
  q_rc=$(tg_rc_line "$tp")
  q_idx=0; q_rev=0; q_answers='{}'; q_seen='[]'; q_off=''; q_fin=0; q_end=''
  q_sts=$(jq -nc --argjson n "$q_n" '[range(0; $n) | {sel: [], txt: "", done: false}]')
  q_prompt=''; q_mid=''; q_pmids='[]'
  q_evf="/tmp/claude_tg_q_${sid}.ev.$$"
  q_respf="/tmp/claude_tg_q_${sid}.resp.$$"
  q_dirty=0; q_cpid=''; q_edpid=''
  # чужое обновление старше этого возраста считаем мёртвым (хук столько не живёт)
  q_maxage=$(( ${TELEGRAM_QUESTION_TIMEOUT:-3300} + 600 ))

  # файл состояния — ДО отправки: Notification permission_prompt (через ~6 с) увидит его
  # и не продублирует вопрос сообщением «Нужно разрешение»
  printf 'pending %s %s\n' "$$" "$q_rid" > "$qf"
  q_load
  q_r=$(q_render)
  q_mid=$(tg_send_kb "$(printf '%s' "$q_r" | jq -r .text)" "$(printf '%s' "$q_r" | jq -c .keyboard)")
  if [ -z "$q_mid" ]; then
    tg_log "question sid=$sid: вопрос не отправлен — остаётся диалог в терминале"
    rm -f "$qf"
    return 0
  fi
  q_pmids="[$q_mid]"
  tg_log "question sid=$sid rid=$q_rid mid=$q_mid n=$q_n → ждём ответ в Telegram"

  q_deadline=$(( $(date +%s) + ${TELEGRAM_QUESTION_TIMEOUT:-3300} ))
  trap 'q_exit' EXIT
  trap 'exit 0' HUP INT TERM
  while [ "$q_fin" != 1 ]; do
    if [ ! -f "$qf" ]; then q_end=closed; break; fi
    read -r q_st _ < "$qf"
    if [ "$q_st" = "done" ]; then q_end=terminal; break; fi
    if [ "$(date +%s)" -ge "$q_deadline" ]; then q_end=timeout; break; fi
    # родитель (Claude Code) закрыт — ждать некому
    if ! kill -0 "$PPID" 2>/dev/null; then q_end=closed; break; fi
    q_t0=$(date +%s)
    q_poll
    [ "$q_fin" = 1 ] && break
    # опрос вернулся мгновенно (409, недоступность, чужие неподтверждённые обновления в
    # очереди) — не крутить цикл вхолостую
    [ $(( $(date +%s) - q_t0 )) -ge 1 ] || sleep "${TELEGRAM_QUESTION_POLL:-1}"
  done

  if [ "$q_fin" = 1 ]; then
    q_end=answered
    q_answers=$(printf '%s' "$q_qs" | jq -c --argjson st "$q_sts" "$q_jqdefs"'
      . as $qs | [range(0; length) as $i | select($st[$i].done)
                  | {key: $qs[$i].question, value: ans($qs[$i]; $st[$i])}] | from_entries')
    # решение хука: allow + исходный ввод с ответами (updatedInput заменяет ввод целиком)
    printf '%s' "$in" | jq -c --argjson a "$q_answers" \
      '{hookSpecificOutput: {hookEventName: "PermissionRequest",
        decision: {behavior: "allow", updatedInput: (.tool_input + {answers: $a})}}}'
  fi
  exit 0
}

case "$cmd" in
  prompt)
    # (1) стираем ранее доставленные уведомления: раз диалог продолжен в терминале,
    # непрочитанные сообщения на телефоне уже не нужны;
    # (2) запоминаем время старта обработки запроса — по нему Stop считает длительность.
    [ -n "$sid" ] || exit 0
    drop_messages
    # новый промпт — вопрос, если он ещё висел, уже снят (ждущий question сам прибирается)
    q_clear "/tmp/claude_tg_q_${sid}"
    date +%s > "/tmp/claude_notif_${sid}"
    tg_log "UserPromptSubmit sid=$sid → отметка старта поставлена"
    ;;

  stop)
    # ход закончен — вопрос, который не отвечали («Chat about this» в терминале), снят
    [ -n "$sid" ] && q_clear "/tmp/claude_tg_q_${sid}"
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

    # название треда (ai-title транскрипта, переведённое на русский) — см. session_title
    title=$(session_title)

    msg=$(printf '\342\234\205 <b>Завершено</b> \302\267 ~%s мин\n\n\360\237\223\213 <b>%s</b>\n\n\360\237\223\201 %s\n\360\237\222\273 %s%s' \
      "$mins" "$(tg_esc "$title")" "$(tg_esc "$proj")" "$(tg_esc "$(tg_host)")" "$(tg_rc_line "$tp")")

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
    # Вопрос AskUserQuestion уже ушёл в Telegram с кнопками (его ведёт живой question) —
    # общее «Нужно разрешение» только продублировало бы его, да ещё и без текста вопроса.
    # Файл от умершего хука (kill -9) не в счёт: pid проверяем.
    if [ -n "$sid" ] && [ -f "/tmp/claude_tg_q_${sid}" ]; then
      read -r qs_st qs_pid _ < "/tmp/claude_tg_q_${sid}"
      [ "$qs_st" = "pending" ] && kill -0 "$qs_pid" 2>/dev/null && exit 0
    fi
    m=$(printf '%s' "$in" | jq -r '.message // .hook_event_name // ""')
    proj=$(basename "$CLAUDE_PROJECT_DIR")
    msg=$(printf '\360\237\224\224 <b>Нужно разрешение</b>\n\n\360\237\223\201 %s\n\360\237\222\273 %s\n\n%s%s' \
      "$(tg_esc "$proj")" "$(tg_esc "$(tg_host)")" "$(tg_esc "$m")" "$(tg_rc_line "$tp")")
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
        msg=$(printf '\360\237\214\220 <b>Нужно нажать Apply в Chrome</b>\n\n\360\237\223\201 %s\n\360\237\222\273 %s\n\nБраузер ждёт подтверждения подключения.' \
          "$(tg_esc "$proj")" "$(tg_esc "$(tg_host)")")
        mid=$(tg_send "$msg")
        printf '%s' "${mid:-done}" > "$mark"
        ;;
    esac
    ;;

  question)
    # PermissionRequest (matcher=AskUserQuestion): вопрос Claude → Telegram с кнопками.
    # Единственная подкоманда с выводом в stdout — решение хука. Любой сбой (флаг выключен,
    # Telegram недоступен) = выход без вывода: диалог в терминале остаётся как есть.
    ask_question
    ;;

  answered)
    # PostToolUse (matcher=AskUserQuestion): вопрос отвечен — в терминале, из Telegram или
    # через Remote Control. Если question ещё ждёт, передаём ему ответы: он прибёрет сообщение.
    # Файла нет — вопрос уже закрыт самим question (ответ был из Telegram), делать нечего.
    [ -n "$sid" ] || exit 0
    qf="/tmp/claude_tg_q_${sid}"
    [ -f "$qf" ] || exit 0
    a=$(printf '%s' "$in" | jq -c '.tool_response.answers // {}' 2>/dev/null)
    [ -n "$a" ] || a='{}'
    read -r _ qa_pid _ < "$qf"
    printf 'done %s %s\n' "$qa_pid" "$a" > "$qf"
    ;;

  end)
    # SessionEnd: сессия закрыта — снимаем оставшиеся уведомления и чистим /tmp.
    # Срабатывает при штатном завершении; при kill -9 хуки не выполняются.
    [ -n "$sid" ] || exit 0
    drop_messages
    rm -f "/tmp/claude_notif_${sid}" "/tmp/claude_tg_q_${sid}"
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
