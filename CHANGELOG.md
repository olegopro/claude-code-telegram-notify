# Changelog

Заметные изменения проекта. Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версии — [SemVer](https://semver.org/lang/ru/).

## [Unreleased]

## [1.1.0] — 2026-10-10
### Changed
- **Семь скриптов объединены в один `tg-notify.sh`** (2026-10-10). Ветвление — по первому аргументу-подкоманде (`prompt` · `stop` · `permit` · `ask` · `chrome` · `end` · `debug`), библиотека `tg-notify-lib.sh` не менялась. Регистрация в `settings.json` теперь `sh "$HOME/.claude/hooks/tg-notify.sh" <подкоманда>`; `install.sh` и `settings.hooks.json` обновлены, `uninstall.sh` чистит и старые имена файлов (следы прежней установки). Поведение уведомлений сохранено один-в-один, проверено прогоном каждой подкоманды и установкой в изолированном каталоге.
- Подкоманда `chrome` (уведомление «Нужно нажать Apply в Chrome» и его гашение после успешного вызова) — раньше жила отдельным локальным файлом вне репозитория, теперь входит в общий скрипт.

### Fixed
- `stop.sh`: guard фоновых задач не распознавал инструмент `Workflow` (только Bash `run_in_background`) — формат `Workflow launched in background. Task ID: X` не совпадал с regex, заточенным под `Command running in background with ID: X`, и «Завершено» уходило раньше реального конца воркфлоу.

## [1.0.2] — 2026-06-26
### Added
- bats-тесты идемпотентности установщика (двойной `install` не плодит дубли, посторонние хуки не затрагиваются) + CI-workflow для них.
- `CHANGELOG.md`.

## [1.0.1] — 2026-06-26
### Changed
- `stop.sh`: заголовок треда не переводится, если он уже не на латинице (кириллица и т.п.) — русский заголовок не уходит в Google Translate впустую и не покидает машину.

## [1.0.0] — 2026-06-26
### Added
- Установщик `install.sh` (через `curl | sh` или из клона) и `uninstall.sh` (точечное удаление только своих хуков).
- Библиотека + шесть хуков: завершение сессии, запрос разрешения, синхронизация чата с терминалом (авто-удаление), опциональный отладочный.
- Секреты в `~/.claude/telegram-notify.env` (вне репозитория), с фолбэком на окружение.
- shellcheck CI; поддержка `CLAUDE_CONFIG_DIR` и установки из тега (`REF=`).
- `tg_send --max-time` (зависший Telegram API не блокирует Stop-хук); opt-out перевода (`TELEGRAM_TRANSLATE=0`).
- Guard фоновых задач: «Завершено» не уходит, пока в сессии есть незавершённые `run_in_background`.

[1.1.0]: https://github.com/olegopro/claude-code-telegram-notify/releases/tag/v1.1.0
[1.0.2]: https://github.com/olegopro/claude-code-telegram-notify/releases/tag/v1.0.2
[1.0.1]: https://github.com/olegopro/claude-code-telegram-notify/releases/tag/v1.0.1
[1.0.0]: https://github.com/olegopro/claude-code-telegram-notify/releases/tag/v1.0.0
