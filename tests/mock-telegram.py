#!/usr/bin/env python3
"""Минимальный mock Telegram Bot API для тестов подкоманды question (только stdlib).

Запуск:  mock-telegram.py <файл-для-порта> [chat_id] [задержка_мс]
Слушает 127.0.0.1 на свободном порту и пишет порт в файл. Методы Bot API — по пути
/bot<token>/<метод>; задержка_мс имитирует сеть (рукопожатие + запрос) на каждый вызов Bot API.
getUpdates честно ждёт новых обновлений до timeout секунд (длинный опрос). Управление
тестом — пути с подчёркиванием:

  GET  /_state        всё накопленное: сообщения, правки, ответы на кнопки, offset, очередь
  POST /_click        {"message_id": N, "data": "..."}   нажать инлайн-кнопку
  POST /_text         {"text": "...", "reply_to": N}      написать текст (ответом на сообщение)
  POST /_raw_update   {...}                              положить в очередь произвольное обновление
  POST /_conflict     {"on": true}                       getUpdates отвечает 409, как при вебхуке
  POST /_fail_send    {"on": true}                       sendMessage отвечает отказом (вызов в журнале остаётся)
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOCK = threading.Lock()
CHAT = int(sys.argv[2]) if len(sys.argv) > 2 else 42
DELAY = int(sys.argv[3]) / 1000.0 if len(sys.argv) > 3 else 0.0
S = {
    "next_msg": 100,
    "next_upd": 1000,
    "messages": {},     # message_id -> {message_id, text, reply_markup, deleted, edits}
    "updates": [],      # очередь неподтверждённых обновлений
    "answers": [],      # answerCallbackQuery: {id, text}
    "confirmed": 0,     # максимальный offset, присланный клиентом
    "conflict": False,
    "fail_send": False,
    "calls": [],        # журнал вызовов: метод
}


def parse_json(value):
    try:
        return json.loads(value) if value else None
    except ValueError:
        return None


def new_update(body):
    S["next_upd"] += 1
    body = dict(body)
    body["update_id"] = S["next_upd"]
    S["updates"].append(body)
    return body


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # тишина в выводе тестов
        pass

    def _reply(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        if "json" in (self.headers.get("Content-Type") or ""):
            return parse_json(raw) or {}
        form = {k: v[0] for k, v in parse_qs(raw, keep_blank_values=True).items()}
        return form

    def do_GET(self):
        self._dispatch(urlparse(self.path))

    def do_POST(self):
        self._dispatch(urlparse(self.path))

    def _dispatch(self, url):
        params = {k: v[0] for k, v in parse_qs(url.query).items()}
        body = self._body() if self.command == "POST" else {}
        params.update(body)
        parts = url.path.strip("/").split("/")
        if parts[0].startswith("bot") and len(parts) >= 2:
            if DELAY:
                time.sleep(DELAY)  # сеть: рукопожатие TLS + запрос
            if parts[1] == "getUpdates":
                return self._get_updates(params)
        with LOCK:
            if parts[0] == "_state":
                return self._reply({**S, "messages": list(S["messages"].values())})
            if parts[0] == "_click":
                msg = S["messages"].get(int(params["message_id"]))
                upd = new_update({"callback_query": {
                    "id": "cb%d" % (S["next_upd"] + 1),
                    "from": {"id": CHAT},
                    "message": {"message_id": int(params["message_id"]), "chat": {"id": CHAT},
                                "date": msg["date"] if msg else int(time.time())},
                    "data": params["data"]}})
                return self._reply({"ok": True, "result": upd})
            if parts[0] == "_text":
                S["next_msg"] += 1
                message = {"message_id": S["next_msg"], "from": {"id": CHAT}, "chat": {"id": CHAT},
                           "date": int(time.time()), "text": params["text"]}
                reply_to = params.get("reply_to")
                if reply_to is not None:
                    src = S["messages"].get(int(reply_to))
                    message["reply_to_message"] = {"message_id": int(reply_to), "chat": {"id": CHAT},
                                                   "date": src["date"] if src else int(time.time())}
                return self._reply({"ok": True, "result": new_update({"message": message})})
            if parts[0] == "_raw_update":
                return self._reply({"ok": True, "result": new_update(params)})
            if parts[0] == "_conflict":
                S["conflict"] = bool(params.get("on", True))
                return self._reply({"ok": True})
            if parts[0] == "_fail_send":
                S["fail_send"] = bool(params.get("on", True))
                return self._reply({"ok": True})
            if not parts[0].startswith("bot") or len(parts) < 2:
                return self._reply({"ok": False, "description": "not found"}, 404)
            return self._reply(self._bot(parts[1], params))

    def _bot(self, method, p):
        S["calls"].append(method)
        if method == "sendMessage":
            if S["fail_send"]:
                return {"ok": False, "error_code": 500, "description": "mock: send failed"}
            S["next_msg"] += 1
            mid = S["next_msg"]
            S["messages"][mid] = {"message_id": mid, "text": p.get("text", ""), "date": int(time.time()),
                                  "reply_markup": parse_json(p.get("reply_markup")),
                                  "deleted": False, "edits": 0}
            return {"ok": True, "result": {"message_id": mid, "chat": {"id": CHAT}, "date": S["messages"][mid]["date"]}}
        if method in ("editMessageText", "editMessageReplyMarkup", "deleteMessage"):
            msg = S["messages"].get(int(p.get("message_id", 0)))
            if msg is None:
                return {"ok": False, "error_code": 400, "description": "message to edit not found"}
            if method == "deleteMessage":
                msg["deleted"] = True
            else:
                if method == "editMessageText":
                    msg["text"] = p.get("text", msg["text"])
                msg["reply_markup"] = parse_json(p.get("reply_markup"))
                msg["edits"] += 1
            return {"ok": True, "result": True}
        if method == "answerCallbackQuery":
            S["answers"].append({"id": p.get("callback_query_id"), "text": p.get("text", "")})
            return {"ok": True, "result": True}
        return {"ok": False, "error_code": 404, "description": "unknown method " + method}

    def _get_updates(self, p):
        """getUpdates: подтверждает offset и, если новых нет, ждёт до timeout секунд."""
        deadline = time.time() + float(p.get("timeout") or 0)
        offset = int(p.get("offset") or 0)
        first = True
        while True:
            with LOCK:
                if first:
                    S["calls"].append("getUpdates")
                    first = False
                if S["conflict"]:
                    return self._reply({"ok": False, "error_code": 409,
                                        "description": "Conflict: webhook is active"})
                if offset:
                    S["confirmed"] = max(S["confirmed"], offset)
                    S["updates"] = [u for u in S["updates"] if u["update_id"] >= offset]
                result = S["updates"][: int(p.get("limit") or 100)]
            if result or time.time() >= deadline:
                if result and DELAY and time.time() < deadline:
                    time.sleep(DELAY / 6)  # путь ответа по уже открытому соединению
                return self._reply({"ok": True, "result": result})
            time.sleep(0.03)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as fh:
        fh.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
