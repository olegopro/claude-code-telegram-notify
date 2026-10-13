#!/usr/bin/env python3
"""Сквозная проверка вопросов в ЖИВОМ Claude Code: реальный TUI + хуки из репозитория + mock Telegram.

Зачем: вся механика вопросов держится на поведении Claude Code, которого нет в документации
(хук PermissionRequest идёт ПАРАЛЛЕЛЬНО диалогу, не останавливается при ответе в терминале,
PostToolUse приходит с ответами). После обновления Claude Code прогоните этот скрипт — он
скажет, не сломалось ли что-то. Unit-тесты (bats + mock) этого не ловят: они не видят TUI.

Что нужно: python3, установленный и залогиненный `claude`. Тратит несколько коротких запросов
к модели (по умолчанию haiku). Пользовательские хуки и настройки не затрагиваются: Claude
Code стартует с `--setting-sources project --settings <временный файл>`, а Telegram заменён
локальным mock — реальный бот и токен не нужны.

Запуск:
    python3 tests/e2e/tui-question.py                 # все сценарии
    python3 tests/e2e/tui-question.py single series   # выбранные
    python3 tests/e2e/tui-question.py --proxy-from-settings   # взять прокси из ~/.claude/settings.json

Сценарии: single · series · text · terminal · esc · perm-allow · perm-deny (описание — в SCENARIOS ниже).
Код возврата: 0 — все прошли, 1 — есть провалы.
"""
import argparse
import fcntl
import json
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ANSI = re.compile(r"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][A-Z0-9]|\x1b[=>MD78]")
NOPROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))

ASK_ONE = ("Call the AskUserQuestion tool exactly once with one question: question 'Which color?', header 'Color', "
           "multiSelect false, options: label 'Red' description 'Warm'; label 'Blue' description 'Cold'. "
           "After the tool returns, reply with one line: RESULT=<the answers text you received, verbatim>.")
ASK_TWO = ("Call the AskUserQuestion tool exactly once with TWO questions. Question 1: question 'Which format?', "
           "header 'Format', multiSelect false, options: label 'Short' description 'Brief'; label 'Long' description "
           "'Detailed'. Question 2: question 'Which sections?', header 'Sections', multiSelect true, options: label "
           "'Intro' description 'Opening'; label 'Code' description 'Examples'; label 'Summary' description 'Wrap-up'. "
           "After the tool returns, reply with one line: RESULT=<the answers text you received, verbatim>.")


# запись в файл через перенаправление — не «безопасная» команда, в режиме default просит разрешение
ASK_BASH = ("Use the Bash tool to run exactly this command: printf 'PERM_%s' $((6*7)) > {out} && cat {out}   "
            "After it finishes, reply with one line: RESULT=<its output>. If it is denied, reply: RESULT=DENIED.")


class Stand:
    """Один прогон: mock Telegram + временный HOME хуков + TUI Claude Code в pty."""

    def __init__(self, args):
        self.args = args
        self.tmp = tempfile.mkdtemp(prefix="tg-e2e-")
        self.t0 = time.time()
        self.raw = bytearray()
        self.pid = self.fd = self.mock = None
        self.perm_mode = False  # True: Claude Code в режиме default — инструменты просят разрешение

    # ── журнал ─────────────────────────────────────────────────────────────
    def log(self, msg):
        print(f"  [{time.time() - self.t0:5.1f}s] {msg}", flush=True)

    # ── mock Telegram ──────────────────────────────────────────────────────
    def start_mock(self):
        port_file = os.path.join(self.tmp, "port")
        self.mock = subprocess.Popen([sys.executable, os.path.join(REPO, "tests", "mock-telegram.py"), port_file, "42"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            if os.path.exists(port_file) and os.path.getsize(port_file):
                break
            time.sleep(0.1)
        self.api = "http://127.0.0.1:" + open(port_file).read().strip()

    def get(self, path):
        with NOPROXY.open(self.api + path, timeout=5) as r:
            return json.load(r)

    def post(self, path, obj):
        req = urllib.request.Request(self.api + path, data=json.dumps(obj).encode(),
                                     headers={"Content-Type": "application/json"})
        with NOPROXY.open(req, timeout=5) as r:
            return json.load(r)

    def messages(self):
        return self.get("/_state")["messages"]

    def tap(self, text_sub):
        """Нажать кнопку первого сообщения по подстроке её текста."""
        msg = self.messages()[0]
        for row in msg["reply_markup"]["inline_keyboard"]:
            for b in row:
                if text_sub in b["text"]:
                    self.post("/_click", {"message_id": msg["message_id"], "data": b["callback_data"]})
                    self.log(f"Telegram: нажато «{text_sub}»")
                    return
        raise AssertionError(f"кнопки «{text_sub}» нет в сообщении")

    def wait_msg(self, sub, timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            self.pump()
            msgs = self.messages()
            if msgs and sub in msgs[0]["text"]:
                return True
        return False

    # ── pty / TUI ──────────────────────────────────────────────────────────
    def pump(self, timeout=0.15):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if r:
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return False
            if not data:
                return False
            self.raw.extend(data)
        return True

    def screen(self):
        # TUI рисует сдвигами курсора, пробелов в потоке нет — сравниваем без пробелов
        return re.sub(r"\s+", "", ANSI.sub("", self.raw.decode("utf-8", "replace")))

    def send(self, s):
        os.write(self.fd, s.encode())

    def wait_screen(self, pattern, timeout, since=0):
        end = time.time() + timeout
        rx = re.compile(pattern, re.S)
        while time.time() < end:
            self.pump()
            m = rx.search(self.screen()[since:])
            if m:
                return m
        return None

    def start_tui(self):
        home = os.path.join(self.tmp, "home")
        os.makedirs(os.path.join(home, ".claude", "hooks"))
        for f in ("tg-notify.sh", "tg-notify-lib.sh"):
            shutil.copy(os.path.join(REPO, "hooks", f), os.path.join(home, ".claude", "hooks", f))
        # telegram-notify.debug: хуки пишут причины выхода в /tmp/claude_notif_debug.log
        for flag in ("telegram-notify.on", "telegram-question.on", "telegram-permission.on", "telegram-notify.debug"):
            open(os.path.join(home, ".claude", flag), "w").close()
        self.decision = os.path.join(self.tmp, "decision.json")
        # команда хука — простая, без конвейера, как в рабочей регистрации (иначе sh -c гибнет по
        # SIGTERM раньше хука); решение хук пишет в файл сам (TELEGRAM_DECISION_FILE)
        hook = (f"HOME={home} TELEGRAM_BOT_TOKEN=test TELEGRAM_CHAT_ID=42 TELEGRAM_API_BASE={self.api} "
                f"TELEGRAM_QUESTION_POLL=0.3 TELEGRAM_QUESTION_TIMEOUT=240 TELEGRAM_TRANSLATE=0 TELEGRAM_NOTIFY=1 "
                f"TELEGRAM_DECISION_FILE={self.decision} NO_PROXY='*' no_proxy='*' sh {home}/.claude/hooks/tg-notify.sh")
        settings = {"hooks": {
            # решение хука пишется в файл (TELEGRAM_DECISION_FILE) — сверять ответы по нему надёжнее,
            # чем по экрану TUI
            "PermissionRequest": [
                {"matcher": "AskUserQuestion", "hooks": [
                    {"type": "command", "command": f"{hook} question", "timeout": 600}]},
                {"matcher": "", "hooks": [
                    {"type": "command", "command": f"{hook} permission", "timeout": 600}]},
            ],
            "PostToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": f"{hook} answered"}]}],
            "Notification": [{"matcher": "permission_prompt", "hooks": [{"type": "command", "command": f"{hook} ask"}]}],
            "UserPromptSubmit": [{"hooks": [{"type": "command", "command": f"{hook} prompt"}]}],
            "Stop": [{"hooks": [{"type": "command", "command": f"{hook} stop"}]}],
            "PreToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": f"{hook} permit"}]}],
        }}
        settings_file = os.path.join(self.tmp, "settings.json")
        json.dump(settings, open(settings_file, "w"))
        project = os.path.join(self.tmp, "project")
        os.makedirs(project)

        env = dict(os.environ, TERM="xterm-256color", DISABLE_AUTOUPDATER="1", NO_COLOR="1")
        if self.args.proxy_from_settings:
            try:
                user = json.load(open(os.path.expanduser("~/.claude/settings.json"))).get("env") or {}
                env.update({k: v for k, v in user.items() if "proxy" in k.lower()})
            except (OSError, ValueError):
                pass
        claude = self.args.claude
        mode = "default" if self.perm_mode else "bypassPermissions"
        argv = [claude, "--setting-sources", "project", "--settings", settings_file,
                "--permission-mode", mode, "--model", self.args.model]
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(project)
            os.execvpe(claude, argv, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 150, 0, 0))

        # диалоги первого запуска: доверие к папке (по умолчанию стоит «No, exit»!) и bypass
        handled, end = set(), time.time() + 90
        while time.time() < end:
            if not self.pump():
                break
            tail = self.screen()[-4000:]
            if re.search(r"bypasspermissionson|\?forshortcuts|❯", tail) and "Yes,Itrustthisfolder" not in tail[-600:] \
                    and "Yes,Iaccept" not in tail[-600:]:
                return True
            for key, needle in (("trust", "Yes,Itrustthisfolder"), ("accept", "Yes,Iaccept")):
                if needle in tail and key not in handled and "Entertoconfirm" in tail:
                    handled.add(key)
                    time.sleep(1.2)
                    self.send("\x1b[B"); time.sleep(0.6); self.send("\r"); time.sleep(1.0)
        return False

    def stop(self):
        try:
            self.send("\x03"); time.sleep(0.3); self.send("\x03"); time.sleep(0.5)
            os.kill(self.pid, signal.SIGKILL)
        except Exception:
            pass
        if self.mock:
            self.mock.terminate()
        if not self.args.keep:
            shutil.rmtree(self.tmp, ignore_errors=True)

    # ── сценарий ───────────────────────────────────────────────────────────
    def ask(self, prompt):
        """Отправить промпт и дождаться вопроса и в Telegram, и в терминале."""
        mark = len(self.screen())
        self.send(prompt); time.sleep(0.8); self.send("\r")
        end = time.time() + 90
        while time.time() < end and not self.messages():
            self.pump()
        if not self.messages():
            raise AssertionError("вопрос не пришёл в Telegram")
        in_terminal = self.wait_screen(r"Entertoselect|Typesomething|Chataboutthis", 30, since=mark)
        if not in_terminal:
            raise AssertionError("диалог в терминале не показан (хук не должен его скрывать)")
        self.log("вопрос в Telegram и диалог в терминале показаны ПАРАЛЛЕЛЬНО")
        return mark

    def decision_answers(self, timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            self.pump()
            try:
                return json.load(open(self.decision))["hookSpecificOutput"]["decision"]["updatedInput"]["answers"]
            except (OSError, ValueError, KeyError):
                pass
        return None


def scenario_single(s):
    s.ask(ASK_ONE)
    s.tap("Blue")
    ans = s.decision_answers()
    assert ans == {"Which color?": "Blue"}, f"ответы хука: {ans}"
    assert s.wait_msg("Ответ отправлен"), "сообщение не стало «Ответ отправлен»"
    assert "→ Blue" in s.messages()[0]["text"]
    # диалог в терминале закрылся сам, и модель продолжила
    assert s.wait_screen(r"RESULT=(?!<)", 60), "модель не получила ответ"


def scenario_series(s):
    s.ask(ASK_TWO)
    s.tap("Short")
    assert s.wait_msg("2/2"), "нет перехода ко второму вопросу"
    s.tap("Назад")
    assert s.wait_msg("1/2"), "«Назад» не вернул к первому вопросу"
    s.tap("2. Long")
    assert s.wait_msg("2/2")
    s.tap("Intro"); time.sleep(0.8)
    s.tap("Summary"); time.sleep(0.8)
    s.tap("Готово")
    assert s.wait_msg("Проверка"), "нет экрана проверки"
    s.tap("Отправить")
    ans = s.decision_answers()
    assert ans == {"Which format?": "Long", "Which sections?": "Intro, Summary"}, f"ответы хука: {ans}"


def scenario_text(s):
    s.ask(ASK_ONE)
    s.tap("Свой вариант")
    end = time.time() + 15
    while time.time() < end and len(s.messages()) < 2:
        s.pump()
    assert len(s.messages()) >= 2, "нет подсказки force_reply"
    s.post("/_text", {"text": "purple haze", "reply_to": s.messages()[1]["message_id"]})
    ans = s.decision_answers()
    assert ans == {"Which color?": "purple haze"}, f"ответы хука: {ans}"


def scenario_terminal(s):
    s.ask(ASK_ONE)
    time.sleep(2.0)
    s.log("ответ В ТЕРМИНАЛЕ: Enter (первый вариант)")
    s.send("\r")
    assert s.wait_msg("Отвечено в терминале", 40), "хук не заметил ответ в терминале (PostToolUse)"
    assert "→ Red" in s.messages()[0]["text"]


def scenario_esc(s):
    s.ask(ASK_ONE)
    time.sleep(2.0)
    # TUI иногда «съедает» первый Esc (занят перерисовкой) — до трёх попыток
    for attempt in range(1, 4):
        s.log(f"Esc в терминале (попытка {attempt})")
        s.send("\x1b")
        if s.wait_msg("Отменено в терминале", 8):
            return
    raise AssertionError("хук не убран по SIGTERM после Esc")


def _perm_prompt(s):
    out = os.path.join(s.tmp, "perm-out.txt")
    return ASK_BASH.format(out=out), out


def scenario_perm_allow(s):
    prompt, out = _perm_prompt(s)
    s.perm_mode = True  # применяется при следующем запуске; стенд запускает TUI заново ниже
    mark = len(s.screen())
    s.send(prompt); time.sleep(0.8); s.send("\r")
    end = time.time() + 90
    while time.time() < end and not s.messages():
        s.pump()
    assert s.messages(), "запрос разрешения не пришёл в Telegram"
    assert "Нужно разрешение" in s.messages()[0]["text"] and "printf" in s.messages()[0]["text"], \
        "в сообщении нет инструмента и команды"
    assert s.wait_screen(r"Doyouwanttoproceed|Yes|Allow|permission", 30, since=mark), "диалог разрешения в терминале не показан"
    s.log("запрос разрешения и в Telegram, и в терминале — ПАРАЛЛЕЛЬНО")
    s.tap("Разрешить")
    assert s.wait_screen(r"RESULT=PERM_42", 90, since=mark), "команда не выполнилась после «Разрешить»"
    dec = json.load(open(s.decision))["hookSpecificOutput"]["decision"]
    assert dec["behavior"] == "allow", dec
    assert s.wait_msg("Разрешено", 20)


def scenario_perm_deny(s):
    prompt, out = _perm_prompt(s)
    s.perm_mode = True
    mark = len(s.screen())
    s.send(prompt); time.sleep(0.8); s.send("\r")
    end = time.time() + 90
    while time.time() < end and not s.messages():
        s.pump()
    assert s.messages(), "запрос разрешения не пришёл в Telegram"
    s.tap("❌ Отклонить")
    assert s.wait_screen(r"RESULT=DENIED", 90, since=mark), "модель не получила отказ"
    dec = json.load(open(s.decision))["hookSpecificOutput"]["decision"]
    assert dec["behavior"] == "deny" and "denied" in dec["message"], dec
    assert not os.path.exists(out), "команда выполнилась, хотя отказано"
    assert s.wait_msg("Отклонено", 20)


SCENARIOS = {
    "single": scenario_single,    # одиночный выбор из Telegram → ответ в модель, диалог закрыт
    "series": scenario_series,    # серия: назад, смена ответа, чекбоксы, проверка, отправка
    "text": scenario_text,        # «Свой вариант» → ответ текстом
    "terminal": scenario_terminal,  # ответ в терминале → Telegram прибран (PostToolUse)
    "esc": scenario_esc,          # Esc в терминале → SIGTERM хуку → Telegram прибран
    "perm-allow": scenario_perm_allow,  # обычный запрос разрешения (Bash) → «Разрешить» → команда выполнена
    "perm-deny": scenario_perm_deny,    # «Отклонить» → модель получает отказ, команда не выполнена
}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("scenarios", nargs="*", help="сценарии (по умолчанию все): " + ", ".join(SCENARIOS))
    ap.add_argument("--claude", default="claude", help="путь к бинарнику claude")
    ap.add_argument("--model", default="haiku")
    ap.add_argument("--keep", action="store_true", help="не удалять временный каталог")
    ap.add_argument("--proxy-from-settings", action="store_true",
                    help="взять переменные *proxy* из блока env в ~/.claude/settings.json")
    args = ap.parse_args()
    names = args.scenarios or list(SCENARIOS)
    unknown = [n for n in names if n not in SCENARIOS]
    if unknown:
        ap.error("неизвестные сценарии: " + ", ".join(unknown))
    if not shutil.which(args.claude) and not os.path.exists(args.claude):
        ap.error(f"не найден {args.claude}; укажите --claude")

    failed = 0
    for name in names:
        print(f"▶ {name}")
        s = Stand(args)
        try:
            s.start_mock()
            s.perm_mode = name.startswith("perm-")
            if not s.start_tui():
                raise AssertionError("TUI не дошёл до готовности")
            SCENARIOS[name](s)
            print(f"  ✅ {name}")
        except Exception as e:  # AssertionError — проверка не прошла; остальное — сбой самого стенда
            failed += 1
            kind = "" if isinstance(e, AssertionError) else f"{type(e).__name__}: "
            print(f"  ❌ {name}: {kind}{e}")
            # для разбора: что сейчас в Telegram и хвост экрана TUI
            try:
                for m in s.messages():
                    print("  --- сообщение в Telegram ---\n" + m["text"].replace("\n", "\n  "))
            except Exception:
                pass
            print("  --- хвост экрана ---\n  " + s.screen()[-700:])
        finally:
            s.stop()
    print(f"\nитог: {len(names) - failed} из {len(names)} прошли")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
