# Changelog

Заметные изменения проекта. Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версии — [SemVer](https://semver.org/lang/ru/).

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

[1.0.2]: https://github.com/olegopro/claude-code-telegram-notify/releases/tag/v1.0.2
[1.0.1]: https://github.com/olegopro/claude-code-telegram-notify/releases/tag/v1.0.1
[1.0.0]: https://github.com/olegopro/claude-code-telegram-notify/releases/tag/v1.0.0
