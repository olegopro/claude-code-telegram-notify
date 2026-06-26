# 🔔 claude-code-telegram-notify

[![shellcheck](https://github.com/olegopro/claude-code-telegram-notify/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/olegopro/claude-code-telegram-notify/actions/workflows/shellcheck.yml)
[![tests](https://github.com/olegopro/claude-code-telegram-notify/actions/workflows/test.yml/badge.svg)](https://github.com/olegopro/claude-code-telegram-notify/actions/workflows/test.yml)

Telegram-уведомления для [Claude Code](https://claude.com/claude-code) на хуках. Бот пишет в Telegram, когда длинная сессия завершилась или Claude просит разрешение на инструмент. Чат держится **синхронным с терминалом**: уведомление само исчезает, когда работа продолжена или сессия закрыта.

```
━━━━━━━━━━━━━━━
✅ Завершено · ~6 мин

📋 Рефакторинг модуля авторизации

📁 my-project

🌐 https://claude.ai/code/session_015mgrRNaj8...
```

## Возможности

- **Уведомление о завершении** длинной обработки (порог настраивается, по умолчанию 3 мин). Короткие ответы чат не засоряют.
- **Зеркало терминала.** Пришло «Завершено» → продолжил диалог → уведомление удаляется. Пришло «Нужно разрешение» → одобрил инструмент → удаляется. Закрыл сессию → её уведомления стираются.
- **Не спешит с фоном.** Если turn закончился, но в сессии ещё работают фоновые задачи (`run_in_background`) — «Завершено» ждёт их реального конца, а не шлёт раньше времени.
- **Перевод названия** треда на русский и **ссылка Remote Control** на сессию (если включён).
- **Публичный репозиторий без секретов** — токен и `chat_id` лежат в локальном `~/.claude/telegram-notify.env`, который не коммитится.

## Установка

Нужны `jq` и `curl` (на macOS: `brew install jq`).

Одной командой:

```sh
curl -fsSL https://raw.githubusercontent.com/olegopro/claude-code-telegram-notify/main/install.sh | sh
```

Или из клона:

```sh
git clone https://github.com/olegopro/claude-code-telegram-notify.git
cd claude-code-telegram-notify
./install.sh
```

Установщик: кладёт хуки в `~/.claude/hooks/`, регистрирует их в `~/.claude/settings.json` (идемпотентно, с бэкапом `.bak`), создаёт шаблон `~/.claude/telegram-notify.env` и включает уведомления.

Опции через окружение:

```sh
WITH_DEBUG=1 ./install.sh   # + отладочный хук (лог событий)
ENABLE=0     ./install.sh   # установить, но не включать
# передать секреты сразу (иначе впишете в env-файл потом):
TELEGRAM_BOT_TOKEN=123:AAH... TELEGRAM_CHAT_ID=123456789 ./install.sh
```

## Получение токена и chat_id

1. **Токен.** В Telegram откройте [@BotFather](https://t.me/BotFather) → `/newbot` → задайте имя и username (заканчивается на `bot`). BotFather пришлёт токен вида `123456789:AAH...`.
2. **chat_id.** Напишите своему боту любое сообщение, затем выполните:
   ```sh
   curl -s "https://api.telegram.org/bot<ТОКЕН>/getUpdates" | jq -r '.result[-1].message.chat.id'
   ```
   Придёт число — это ваш `chat_id`.
3. Сохраните секреты в `~/.claude/telegram-notify.env`. Выполните в терминале, подставив свои значения:
   ```sh
   cat > ~/.claude/telegram-notify.env <<'EOF'
   TELEGRAM_BOT_TOKEN=123456789:AAH...
   TELEGRAM_CHAT_ID=123456789
   EOF
   chmod 600 ~/.claude/telegram-notify.env
   ```
   Либо откройте файл редактором: `nano ~/.claude/telegram-notify.env`. Если запускали `install.sh`, файл уже создан (шаблон или заполнен из окружения) — останется вписать значения.
4. Перезапустите сессию Claude Code. Проверка отправки:
   ```sh
   . ~/.claude/hooks/tg-notify-lib.sh
   mid=$(tg_send "🧪 тест"); echo "message_id: $mid"; tg_delete "$mid"
   ```

## Настройка

| Что | Где | Значение |
|---|---|---|
| Вкл/выкл | файл-флаг `~/.claude/telegram-notify.on` | `touch` — включить, `rm` — выключить. Действует на все сессии сразу, без перезапуска. |
| Порог | `TELEGRAM_MIN_SECONDS` в env-файле | секунды: `180` = 3 мин, `300` = 5 мин. |
| Порог (мгновенно) | файл `~/.claude/telegram-min-seconds` | число секунд; читается с диска на каждый `Stop`, перебивает env без перезапуска. |
| Перевод заголовка | `TELEGRAM_TRANSLATE` в env-файле | `0` — не переводить заголовок треда (не отправлять его в Google Translate). По умолчанию переводится. |
| Отладка | файл-флаг `~/.claude/telegram-notify.debug` | при наличии хуки пишут лог событий в `/tmp/claude_notif_debug.log`. |

**Почему флаг-файл, а не env:** библиотека читается с диска на каждый хук, поэтому флаг подхватывают и уже запущенные сессии. Env кэшируется на старте сессии.

## Как это работает

Хуки в `~/.claude/hooks/` (общая библиотека + шесть хуков):

| Событие | Хук | Действие |
|---|---|---|
| `UserPromptSubmit` | `tg-notify-start.sh` | удаляет прошлые уведомления сессии (диалог продолжен), ставит метку времени старта |
| `Stop` | `tg-notify-stop.sh` | если обработка дольше порога и фон завершён — шлёт «Завершено», запоминает `message_id` |
| `Notification` | `tg-notify-notification.sh` | шлёт «Нужно разрешение» при запросе доступа к инструменту |
| `PreToolUse` | `tg-notify-permit.sh` | инструмент начал выполняться → удаляет уведомление «Нужно разрешение» |
| `SessionEnd` | `tg-notify-end.sh` | сессия закрыта → удаляет оставшиеся уведомления и чистит `/tmp` |
| `PreCompact`/`SessionStart` | `tg-notify-debug.sh` | опционально (`WITH_DEBUG=1`): лог событий, на уведомления не влияет |

Путь к транскрипту и `session_id` приходят хуку на stdin; папка проекта — в `$CLAUDE_PROJECT_DIR`. Время старта хранится в `/tmp/claude_notif_<session_id>`, отправленные `message_id` — в `/tmp/claude_notif_msg_<session_id>`.

### Почему «Завершено» не приходит раньше времени

`Stop` срабатывает на конце **turn**, а фоновые задачи (`run_in_background`) живут дальше и реактивируют сессию позже. `tg-notify-stop.sh` сверяет транскрипт: запущенный фоновый ID (`Command running in background with ID: X`) против метки завершения `<task-id>X</task-id>`. Есть незакрытый — уведомление откладывается до финального `Stop`, когда фон вернулся и обработан.

## Обновление и удаление

Обновить — повторить установку (идемпотентно):

```sh
curl -fsSL https://raw.githubusercontent.com/olegopro/claude-code-telegram-notify/main/install.sh | sh
```

Удалить (хуки из `settings.json`, файлы, флаги; секреты сохраняются):

```sh
./uninstall.sh
```

## Структура репозитория

```
claude-code-telegram-notify/
├── install.sh            # установщик (curl|sh и из клона)
├── uninstall.sh          # удаление
├── .env.example          # шаблон секретов
├── settings.hooks.json   # snippet блока hooks для ручной установки
├── tests/                # bats-тесты идемпотентности установщика
├── hooks/                # семь файлов: библиотека + шесть хуков
└── CHANGELOG.md          # история версий
```

История изменений — в [CHANGELOG.md](CHANGELOG.md).

## Если не работает

- **Нет уведомлений** — проверьте флаг: `ls ~/.claude/telegram-notify.on` (нет файла → бот молчит), затем `tg_send`-тест из шага 4.
- **`jq: command not found`** — нужен `jq` (1.6+): `brew install jq`.
- **Сообщение не уходит** — неверный токен/`chat_id` в `~/.claude/telegram-notify.env`, либо Telegram недоступен (нужен прокси через `HTTPS_PROXY`).
- **Двойные уведомления** — в `settings.json` задвоилась регистрация хуков (например, осталась старая ручная запись через `$HOME` рядом с записью install.sh по абсолютному пути). Уберите дубли или переустановите начисто (`uninstall.sh` → `install.sh`).
- **Заголовок не переведён** — нет сети/таймаут переводчика, либо `TELEGRAM_TRANSLATE=0`; приходит оригинал.

## Лицензия

[MIT](LICENSE) © 2026 olegopro
