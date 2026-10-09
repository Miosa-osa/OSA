#!/usr/bin/env python3
"""A deterministic model provider for `osa run` end-to-end tests.

Speaks the two wire protocols OSA's providers use:

  * OpenAI-compatible: POST /v1/chat/completions (SSE when "stream": true),
    which is also what the MIOSA AI Gateway serves;
  * Ollama native: POST /api/chat (NDJSON), GET /api/tags, POST /api/show.

The reply is decided by the conversation, so a test drives the agent with
plain-text commands in the user message:

  REMEMBER <key>=<value>   answer "Noted <key>."
  RECALL <key>             answer "<key> is <value>", searching every message
                           (the compaction summary included), or "unknown"
  RUN <shell command>      call the shell tool with that command; after the
                           tool result, answer "Tool said: <result>"
  FILLER <n>               answer with n filler words (grows the context)
  FAIL                     answer HTTP 400 (a non-retryable provider error)
  anything else            "Hello from the stub."

A request without tools is an auxiliary call (session titles, compaction).
When it asks to summarize, the summary repeats every `key=value` fact the
excerpt contains, as a real summarizer would preserve them.

Every request is appended to $STUB_LOG as one JSON line (path, model,
authorization, whether tools were offered, the last user text).

Usage: stub_provider.py <port-file>   (binds 127.0.0.1:0, writes the port)
"""
import json
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FACT = re.compile(r"\b([A-Za-z][A-Za-z0-9_]*)=([A-Za-z0-9_-]+)")
LOG_LOCK = threading.Lock()


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for block in content:
            if isinstance(block, dict) and isinstance(block.get("text"), str):
                out.append(block["text"])
            elif isinstance(block, str):
                out.append(block)
        return "\n".join(out)
    return ""


def all_text(messages):
    return "\n".join(text_of(m.get("content")) for m in messages if isinstance(m, dict))


REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)


def last_user_text(messages):
    """The newest user text the PERSON wrote: OSA appends its own budget and
    context notes as `<system-reminder>` user messages, which are skipped."""
    for message in reversed(messages):
        if message.get("role") == "user":
            text = REMINDER.sub("", text_of(message.get("content"))).strip()
            if text:
                return text
    return ""


def decide(messages, has_tools):
    """Returns ("text", str) or ("tool", command) or ("fail", reason)."""
    if not has_tools:
        excerpt = all_text(messages)
        if "ummar" in excerpt:
            facts = "; ".join(sorted(set(f"{k}={v}" for k, v in FACT.findall(excerpt)))) or "none"
            # The nine sections OSA's compaction quality gate requires.
            return ("text", "\n".join([
                f"1. Primary Request and Intent: the user is checking that facts survive. Facts: {facts}",
                "2. Key Technical Concepts: remembered key=value facts, filler turns.",
                "3. Files and Code Sections: none touched.",
                "4. Errors and fixes: none.",
                "5. Problem Solving: none needed.",
                f"6. All user messages: REMEMBER lines with {facts}, then FILLER requests.",
                "7. Pending Tasks: none.",
                "8. Current Work: answering the user's questions about remembered facts.",
                "9. Optional Next Step: wait for the next user message.",
            ]))
        return ("text", "Stub session")

    # Once a tool has answered since the person's latest message, the turn's
    # work is done: report the newest tool result. (OSA appends its own notes
    # after a tool result, so "the last message" is not reliably the tool's.)
    last_user = max((i for i, m in enumerate(messages)
                     if m.get("role") == "user" and REMINDER.sub("", text_of(m.get("content"))).strip()),
                    default=-1)
    tool_results = [m for m in messages[last_user + 1:] if m.get("role") == "tool"]
    if tool_results:
        return ("text", "Tool said: " + text_of(tool_results[-1].get("content")).strip()[:200])

    prompt = last_user_text(messages)
    command = prompt.split(None, 1)
    verb = command[0].upper() if command else ""
    rest = command[1] if len(command) > 1 else ""

    if verb == "REMEMBER":
        key = rest.split("=", 1)[0].strip()
        return ("text", f"Noted {key}.")
    if verb == "RECALL":
        key = rest.strip()
        found = None
        # The newest mention wins, and the RECALL line itself never counts.
        for k, v in FACT.findall(all_text(messages)):
            if k == key:
                found = v
        return ("text", f"{key} is {found or 'unknown'}")
    if verb == "RUN":
        return ("tool", rest)
    if verb == "FILLER":
        n = int(rest.strip() or "100")
        return ("text", " ".join(f"filler{i}" for i in range(n)) + " ok")
    if verb == "FAIL":
        return ("fail", "stub refuses this request")
    return ("text", "Hello from the stub.")


def usage_for(messages, text):
    prompt_tokens = max(1, len(json.dumps(messages)) // 4)
    return prompt_tokens, max(1, len(text) // 4)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def _log(self, body):
        path = os.environ.get("STUB_LOG")
        if not path:
            return
        messages = body.get("messages") or []
        entry = {
            "path": self.path,
            "model": body.get("model"),
            "authorization": self.headers.get("Authorization"),
            "has_tools": bool(body.get("tools")),
            "last_user": last_user_text(messages) if isinstance(messages, list) else "",
            # What the model can still see: every key=value fact anywhere in
            # the request, and how many verbatim REMEMBER messages remain.
            "system": "\n".join(text_of(m.get("content")) for m in messages
                                 if isinstance(m, dict) and m.get("role") == "system"),
            "facts": sorted(set(f"{k}={v}" for k, v in FACT.findall(all_text(messages)))),
            "remember_messages": sum(
                1 for m in messages
                if m.get("role") == "user"
                and REMINDER.sub("", text_of(m.get("content"))).strip().upper().startswith("REMEMBER")
            ),
        }
        with LOG_LOCK, open(path, "a") as log:
            log.write(json.dumps(entry) + "\n")

    def _json(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/api/tags"):
            self._json(200, {"models": [{"name": "stub-model:cloud", "model": "stub-model:cloud"}]})
        elif self.path.rstrip("/").endswith("/models"):
            self._json(200, {"object": "list", "data": [{"id": "stub-model", "object": "model"}]})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        body = self._body()
        if self.path.startswith("/api/show"):
            self._json(200, {
                "capabilities": ["completion", "tools"],
                "model_info": {"general.architecture": "stub", "stub.context_length": 131072},
            })
            return
        self._log(body)
        messages = body.get("messages") or []
        kind, value = decide(messages, bool(body.get("tools")))
        if kind == "fail":
            self._json(400, {"error": {"message": value, "type": "invalid_request_error"}})
            return
        if self.path.startswith("/api/chat"):
            self._ollama(body, messages, kind, value)
        else:
            self._openai(body, messages, kind, value)

    # ── OpenAI-compatible ────────────────────────────────────────────────

    def _openai(self, body, messages, kind, value):
        model = body.get("model") or "stub-model"
        text = value if kind == "text" else ""
        prompt_tokens, completion_tokens = usage_for(messages, text)
        usage = {"prompt_tokens": prompt_tokens, "completion_tokens": completion_tokens,
                 "total_tokens": prompt_tokens + completion_tokens}
        tool_call = None
        if kind == "tool":
            tool_call = {"id": f"call_stub_{abs(hash(value)) % 10**8}", "type": "function",
                         "function": {"name": "shell_execute",
                                      "arguments": json.dumps({"command": value})}}
        if not body.get("stream"):
            message = {"role": "assistant", "content": text or None}
            if tool_call:
                message["tool_calls"] = [tool_call]
            self._json(200, {"id": "chatcmpl-stub", "object": "chat.completion", "model": model,
                             "choices": [{"index": 0, "message": message,
                                          "finish_reason": "tool_calls" if tool_call else "stop"}],
                             "usage": usage})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def send(chunk):
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.flush()

        base = {"id": "chatcmpl-stub", "object": "chat.completion.chunk", "model": model}
        if text:
            words = text.split(" ")
            pieces = [" ".join(words[i:i + 8]) + (" " if i + 8 < len(words) else "")
                      for i in range(0, len(words), 8)]
            for piece in pieces:
                send({**base, "choices": [{"index": 0, "delta": {"content": piece}}]})
        if tool_call:
            send({**base, "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, **tool_call}]}}]})
        send({**base, "choices": [{"index": 0, "delta": {},
                                   "finish_reason": "tool_calls" if tool_call else "stop"}]})
        send({**base, "choices": [], "usage": usage})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    # ── Ollama native ────────────────────────────────────────────────────

    def _ollama(self, body, messages, kind, value):
        model = body.get("model") or "stub-model"
        text = value if kind == "text" else ""
        prompt_tokens, completion_tokens = usage_for(messages, text)
        message = {"role": "assistant", "content": text}
        if kind == "tool":
            message["tool_calls"] = [{"function": {"name": "shell_execute",
                                                   "arguments": {"command": value}}}]
        final = {"model": model, "message": message, "done": True, "done_reason": "stop",
                 "prompt_eval_count": prompt_tokens, "eval_count": completion_tokens}
        if body.get("stream") is False:
            self._json(200, final)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Connection", "close")
        self.end_headers()
        if text:
            self.wfile.write(json.dumps({"model": model, "message": {"role": "assistant", "content": text},
                                         "done": False}).encode() + b"\n")
        final_message = dict(message)
        final_message["content"] = ""
        self.wfile.write(json.dumps({**final, "message": final_message}).encode() + b"\n")
        self.wfile.flush()
        self.close_connection = True


def main():
    port_file = sys.argv[1]
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(port_file, "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
