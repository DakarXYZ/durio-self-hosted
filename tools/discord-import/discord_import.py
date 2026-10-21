#!/usr/bin/env python3
"""Import Discord history (DiscordChatExporter JSON) into dur.io server channels.

Standard library only, Python 3.10+. See README.md next to this file (Russian).

    python discord_import.py check   --config mapping.json
    python discord_import.py dry-run --config mapping.json
    python discord_import.py import  --config mapping.json [--limit 50] [--only general]
    python discord_import.py status  --config mapping.json

Server contract (dur.io 0.16.0-fork.3+), auth header x-session-token:
    POST /api/auth/session/login            {email, password, friendly_name} -> Success | MFA ticket
    PUT  /api/auth/mfa/ticket {totp_code}   -> {token}; POST /api/admin/elevate with x-mfa-ticket
    POST /autumn/attachments | /autumn/avatars   multipart field "file" -> {id}
    POST /api/admin/import/channels/<id>/messages
        {"source": "discord", "messages": [{original_id, timestamp, edited, author{original_id, name,
          avatar, bot}, content, attachments[<=10 ids], reply_to[<=5 {original_id, timestamp}], pinned}]}
        (1..100 messages, oldest first) -> {imported, skipped}
    Admin calls fail with {"type": "AdminElevationRequired"} once elevation expires: re-elevate, retry.
"""
from __future__ import annotations

import argparse
import datetime as dt
import getpass
import glob
import http.client
import json
import mimetypes
import os
import re
import ssl
import sys
import tempfile
import time
import unicodedata
import urllib.parse
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Iterator

VERSION = "1.0"
SOURCE = "discord"
FRIENDLY_NAME = "discord-import"
USER_AGENT = f"durio-discord-import/{VERSION}"

MAX_CONTENT = 10000
MAX_ATTACHMENTS = 10
MAX_REPLIES = 5
MAX_NAME = 32

# Message types imported as normal messages. Everything else is a system message and is skipped,
# except PollResult which becomes a short text summary of the closed poll.
NORMAL_TYPES = {"Default", "Reply"}
POLL_RESULT = "PollResult"

DEFAULT_OPTIONS: dict[str, Any] = {
    "max_file_mb": 100,          # server attachment limit; bigger files become a text line
    "batch_size": 100,           # messages per import request (server max 100)
    "max_batch_upload_mb": 500,  # close a batch early once its uploads reach this size
    "link_channel_names": True,  # "#general" in text -> link to the mapped dur.io channel
    "import_avatars": True,
    "progress_every": 10,        # progress line every N batches
    "upload_reuse_minutes": 30,  # reuse an unclaimed upload from an interrupted run if younger
}

ULID_RE = re.compile(r"^[0-9A-HJKMNP-TV-Z]{26}$")


# ----------------------------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------------------------

def log(*parts: Any) -> None:
    print(*parts, flush=True)


def human_mb(n: int) -> str:
    return f"{n / 2**20:.1f} МБ"


def human_size(n: int) -> str:
    if n >= 2**30:
        return f"{n / 2**30:.2f} ГБ"
    return human_mb(n)


def strip_control(s: str) -> str:
    return "".join(ch for ch in s if unicodedata.category(ch) != "Cc")


def author_display_name(author: dict) -> str:
    """Nickname or name, without control chars, at most 32 characters."""
    for candidate in (author.get("nickname"), author.get("name")):
        name = strip_control(candidate or "").strip()
        if name:
            return name[:MAX_NAME].strip() or name[:MAX_NAME]
    return "user-" + str(author.get("id", "?"))[-4:]


def snowflake(s: str | None) -> int:
    try:
        return int(s or 0)
    except ValueError:
        return 0


def format_unix(ts: int, style: str | None) -> str:
    """Discord <t:unix:style> -> readable UTC date. Relative style R is shown as an absolute date."""
    try:
        d = dt.datetime.fromtimestamp(ts, tz=dt.timezone.utc)
    except (OverflowError, OSError, ValueError):
        return str(ts)
    if style in ("d", "D"):
        return d.strftime("%Y-%m-%d")
    if style == "t":
        return d.strftime("%H:%M UTC")
    if style == "T":
        return d.strftime("%H:%M:%S UTC")
    return d.strftime("%Y-%m-%d %H:%M UTC")


def format_iso_date(iso: str | None) -> str:
    """'2024-03-22T22:53:54.625+04:00' -> '2024-03-22 22:53' (wall time of the export, offset dropped)."""
    if not iso:
        return ""
    m = re.match(r"(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})", iso)
    return f"{m.group(1)} {m.group(2)}" if m else iso


def is_remote(url: str) -> bool:
    return bool(re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", url))


# ----------------------------------------------------------------------------------------------
# Export index: names and importable message ids across all mapped files
# ----------------------------------------------------------------------------------------------

@dataclass
class ExportIndex:
    users: dict[str, str] = field(default_factory=dict)          # discord user id -> display name
    roles: dict[str, str] = field(default_factory=dict)          # role id -> name
    channel_names: dict[str, str] = field(default_factory=dict)  # discord channel id -> name
    mapped: dict[str, str] = field(default_factory=dict)         # discord channel id -> dur.io id
    messages: dict[str, str] = field(default_factory=dict)       # importable message id -> timestamp
    avatars: dict[str, str] = field(default_factory=dict)        # author id -> avatarUrl (local preferred)
    link_channel_names: bool = True
    _name_rx: Any = None

    def add_user(self, u: dict | None) -> None:
        if not u or not u.get("id"):
            return
        self.users.setdefault(u["id"], author_display_name(u))
        for r in u.get("roles") or []:
            if r.get("id") and r.get("name"):
                self.roles.setdefault(r["id"], r["name"])

    def add_author(self, a: dict) -> None:
        aid = a.get("id")
        if not aid:
            return
        self.users[aid] = author_display_name(a)
        for r in a.get("roles") or []:
            if r.get("id") and r.get("name"):
                self.roles[r["id"]] = r["name"]
        url = a.get("avatarUrl")
        if url:
            prev = self.avatars.get(aid)
            if prev is None or (is_remote(prev) and not is_remote(url)):
                self.avatars[aid] = url

    def add_messages(self, messages: Iterable[dict]) -> None:
        for m in messages:
            self.add_author(m.get("author") or {})
            for u in m.get("mentions") or []:
                self.add_user(u)
            self.add_user((m.get("interaction") or {}).get("user"))
            if skip_reason(m) is None:
                self.messages[m["id"]] = m["timestamp"]

    def channel_name_rx(self) -> tuple[Any, dict[str, str]]:
        by_name = {self.channel_names[cid]: target for cid, target in self.mapped.items()
                   if self.channel_names.get(cid)}
        if self._name_rx is None or self._name_rx[1] != by_name:
            rx = None
            if by_name:
                names = sorted(by_name, key=len, reverse=True)
                rx = re.compile(r"(?<!\S)#(" + "|".join(re.escape(n) for n in names) + r")(?![\w-])")
            self._name_rx = (rx, by_name)
        return self._name_rx


HEADER_RE = re.compile(r'"channel"\s*:\s*\{\s*"id"\s*:\s*"(\d+)".*?"name"\s*:\s*"((?:[^"\\]|\\.)*)"', re.S)


def read_channel_header(path: str) -> tuple[str, str] | None:
    """Channel id and name from the beginning of an export file, without parsing the whole file."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            head = f.read(16384)
    except OSError:
        return None
    m = HEADER_RE.search(head)
    if not m:
        return None
    try:
        return m.group(1), json.loads('"' + m.group(2) + '"')
    except ValueError:
        return None


# ----------------------------------------------------------------------------------------------
# Content conversion
# ----------------------------------------------------------------------------------------------

USER_MENTION_RE = re.compile(r"<@!?(\d+)>")
ROLE_MENTION_RE = re.compile(r"<@&(\d+)>")
CHANNEL_MENTION_RE = re.compile(r"<#(\d+)>")
EMOJI_RE = re.compile(r"<a?:([A-Za-z0-9_~\-]+):\d+>")
TIMESTAMP_RE = re.compile(r"<t:(-?\d+)(?::([tTdDfFR]))?>")
SLASH_RE = re.compile(r"</([^<>:\n]+):\d+>")


def convert_content(text: str, idx: ExportIndex) -> str:
    """Discord markup -> dur.io text. DiscordChatExporter usually renders mentions already
    (as @name, #channel, :emoji:); raw markup is handled too."""
    def user(m: re.Match) -> str:
        return "@" + idx.users.get(m.group(1), "unknown-user")

    def role(m: re.Match) -> str:
        return "@" + idx.roles.get(m.group(1), "role")

    def channel(m: re.Match) -> str:
        cid = m.group(1)
        if cid in idx.mapped:
            return f"<#{idx.mapped[cid]}>"
        if cid in idx.channel_names:
            return "#" + idx.channel_names[cid]
        return "#channel"

    text = ROLE_MENTION_RE.sub(role, text)
    text = USER_MENTION_RE.sub(user, text)
    text = CHANNEL_MENTION_RE.sub(channel, text)
    text = EMOJI_RE.sub(lambda m: f":{m.group(1)}:", text)
    text = TIMESTAMP_RE.sub(lambda m: format_unix(int(m.group(1)), m.group(2)), text)
    text = SLASH_RE.sub(lambda m: "/" + m.group(1), text)
    if idx.link_channel_names and idx.mapped:
        rx, by_name = idx.channel_name_rx()
        if rx is not None:
            text = rx.sub(lambda m: f"<#{by_name[m.group(1)]}>", text)
    return text


def quote(text: str) -> str:
    return "\n".join("> " + line if line else ">" for line in text.split("\n"))


def poll_result_text(msg: dict) -> str:
    fields: dict[str, str] = {}
    for e in msg.get("embeds") or []:
        for f in e.get("fields") or []:
            fields[f.get("name", "")] = f.get("value", "")
    q = fields.get("poll_question_text")
    if not q:
        return msg.get("content") or ""
    total = fields.get("total_votes", "?")
    votes = fields.get("victor_answer_votes", "?")
    answer = fields.get("victor_answer_text")
    if answer:
        return f"📊 Опрос «{q}» завершён. Победил ответ «{answer}» ({votes} из {total} голосов)."
    return f"📊 Опрос «{q}» завершён. Голосов: {total}, у победившего ответа: {votes}."


def skip_reason(msg: dict) -> str | None:
    """None if the message is imported, otherwise why it is skipped ('system:<type>' or 'empty')."""
    mtype = msg.get("type", "Default")
    if mtype == POLL_RESULT:
        return None
    if mtype not in NORMAL_TYPES:
        return f"system:{mtype}"
    if (msg.get("content") or "").strip():
        return None
    if msg.get("attachments") or msg.get("stickers"):
        return None
    fwd = msg.get("forwardedMessage") or {}
    if (fwd.get("content") or "").strip() or fwd.get("attachments") or fwd.get("stickers"):
        return None
    return "empty"


# ----------------------------------------------------------------------------------------------
# Attachments
# ----------------------------------------------------------------------------------------------

@dataclass
class AttachmentPlan:
    att_id: str
    file_name: str
    kind: str          # local | remote | missing | too_big
    path: str | None = None
    size: int = 0

    def placeholder(self) -> str:
        if self.kind == "too_big":
            return f"[файл слишком большой: {self.file_name}, {self.size / 2**20:.0f} МБ]"
        return f"[вложение не сохранено: {self.file_name}]"


def resolve_local(base_dir: str, url: str) -> str | None:
    rel = url.replace("\\", "/")
    for cand in (rel, urllib.parse.unquote(rel)):
        p = cand if os.path.isabs(cand) else os.path.join(base_dir, cand)
        if os.path.isfile(p):
            return p
    return None


def plan_attachment(att: dict, base_dir: str, max_bytes: int) -> AttachmentPlan:
    url = att.get("url") or ""
    name = strip_control(att.get("fileName") or os.path.basename(url.replace("\\", "/")) or "file")
    plan = AttachmentPlan(att_id=str(att.get("id") or url), file_name=name, kind="missing",
                          size=int(att.get("fileSizeBytes") or 0))
    if is_remote(url):
        plan.kind = "remote"
        return plan
    path = resolve_local(base_dir, url) if url else None
    if path is None:
        return plan
    plan.path = path
    plan.size = os.path.getsize(path)
    plan.kind = "too_big" if plan.size > max_bytes else "local"
    return plan


# ----------------------------------------------------------------------------------------------
# Message plan (everything except upload results)
# ----------------------------------------------------------------------------------------------

@dataclass
class MessagePlan:
    original_id: str
    timestamp: str
    edited: str | None
    author_id: str
    author_name: str
    bot: bool
    content: str                     # converted text without attachment placeholder lines
    attachments: list[AttachmentPlan]
    reply_to: list[dict]
    pinned: bool
    dropped_replies: int = 0
    forwarded: bool = False

    def uploads(self) -> list[AttachmentPlan]:
        """Local files to upload (at most 10 per message, the rest become text lines)."""
        return [a for a in self.attachments if a.kind == "local"][:MAX_ATTACHMENTS]

    def payload(self, uploaded: dict[str, str | None], avatar: str | None) -> dict:
        """API message object. uploaded: attachment id -> autumn id (None = upload rejected)."""
        ids: list[str] = []
        lines: list[str] = []
        for a in self.attachments:
            fid = uploaded.get(a.att_id) if a.kind == "local" else None
            if fid and len(ids) < MAX_ATTACHMENTS:
                ids.append(fid)
            elif a.kind == "local" and a.att_id not in uploaded:
                lines.append(f"[вложение пропущено: {a.file_name}]")
            else:
                lines.append(a.placeholder())
        content = self.content
        if lines:
            content = (content + "\n" if content else "") + "\n".join(lines)
        if len(content) > MAX_CONTENT:
            content = content[: MAX_CONTENT - 1] + "…"
        return {
            "original_id": self.original_id,
            "timestamp": self.timestamp,
            "edited": self.edited,
            "author": {"original_id": self.author_id, "name": self.author_name,
                       "avatar": avatar, "bot": self.bot},
            "content": content,
            "attachments": ids,
            "reply_to": self.reply_to,
            "pinned": self.pinned,
        }


def plan_message(msg: dict, idx: ExportIndex, base_dir: str, max_bytes: int) -> MessagePlan | None:
    if skip_reason(msg) is not None:
        return None
    author = msg.get("author") or {}
    parts: list[str] = []
    if msg.get("type") == POLL_RESULT:
        parts.append(poll_result_text(msg))
    else:
        text = convert_content(msg.get("content") or "", idx).strip()
        if text:
            parts.append(text)
    atts = [plan_attachment(a, base_dir, max_bytes) for a in msg.get("attachments") or []]
    fwd = msg.get("forwardedMessage")
    if fwd:
        when = format_iso_date(fwd.get("timestamp"))
        body = convert_content(fwd.get("content") or "", idx).strip()
        block = f"↪ Пересланное сообщение ({when}):" if when else "↪ Пересланное сообщение:"
        if body:
            block += "\n" + quote(body)
        for s in fwd.get("stickers") or []:
            block += f"\n> [стикер: {s.get('name', '?')}]"
        parts.append(block)
        atts += [plan_attachment(a, base_dir, max_bytes) for a in fwd.get("attachments") or []]
    for s in msg.get("stickers") or []:
        parts.append(f"[стикер: {s.get('name', '?')}]")

    replies: list[dict] = []
    dropped = 0
    ref = msg.get("reference") or {}
    if ref.get("messageId") and ref.get("type", "Default") == "Default" \
            and msg.get("type") in ("Reply", POLL_RESULT):
        target = ref["messageId"]
        if target in idx.messages and target != msg["id"]:
            replies.append({"original_id": target, "timestamp": idx.messages[target]})
        else:
            dropped += 1

    return MessagePlan(
        original_id=msg["id"],
        timestamp=msg["timestamp"],
        edited=msg.get("timestampEdited") or None,
        author_id=str(author.get("id") or "0"),
        author_name=author_display_name(author),
        bot=bool(author.get("isBot")),
        content="\n".join(parts).strip(),
        attachments=atts,
        reply_to=replies[:MAX_REPLIES],
        pinned=bool(msg.get("isPinned")),
        dropped_replies=dropped,
        forwarded=bool(fwd),
    )


def pending_plans(plans: list[MessagePlan], last_id: str | None, limit: int | None = None) -> list[MessagePlan]:
    """Plans still to send: the first `limit` plans (test runs), minus those up to last_id."""
    if limit is not None:
        plans = plans[:limit]
    last = snowflake(last_id)
    return [p for p in plans if snowflake(p.original_id) > last]


def make_batches(plans: list[MessagePlan], size: int, max_bytes: int) -> Iterator[list[MessagePlan]]:
    batch: list[MessagePlan] = []
    total = 0
    for p in plans:
        batch.append(p)
        total += sum(a.size for a in p.uploads())
        if len(batch) >= size or total >= max_bytes:
            yield batch
            batch, total = [], 0
    if batch:
        yield batch


# ----------------------------------------------------------------------------------------------
# Config, exports
# ----------------------------------------------------------------------------------------------

class ToolError(Exception):
    pass


@dataclass
class ChannelMap:
    file: str
    path: str
    channel: str
    discord_id: str = ""
    name: str = ""


@dataclass
class Config:
    path: str
    server: str
    api: str
    autumn: str
    export_dir: str
    channels: list[ChannelMap]
    options: dict[str, Any]


def load_config(path: str) -> Config:
    try:
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise ToolError(f"не удалось прочитать конфиг {path}: {e}")
    server = (raw.get("server") or "").rstrip("/")
    export_dir = raw.get("export_dir") or os.path.dirname(os.path.abspath(path))
    options = dict(DEFAULT_OPTIONS)
    options.update(raw.get("options") or {})
    for k in DEFAULT_OPTIONS:
        if k in raw:
            options[k] = raw[k]
    chans = []
    for i, c in enumerate(raw.get("channels") or []):
        if not c.get("file") or not c.get("channel"):
            raise ToolError(f"channels[{i}]: нужны поля file и channel")
        p = c["file"] if os.path.isabs(c["file"]) else os.path.join(export_dir, c["file"])
        chans.append(ChannelMap(file=c["file"], path=p, channel=c["channel"].strip()))
    if not chans:
        raise ToolError("в конфиге нет каналов (channels)")
    return Config(path=path, server=server, api=(raw.get("api_url") or server + "/api").rstrip("/"),
                  autumn=(raw.get("autumn_url") or server + "/autumn").rstrip("/"),
                  export_dir=export_dir, channels=chans, options=options)


def validate_config(cfg: Config) -> list[str]:
    problems = []
    if not re.match(r"^https?://", cfg.server):
        problems.append(f"server должен начинаться с https://, сейчас: {cfg.server!r}")
    seen: dict[str, str] = {}
    for c in cfg.channels:
        if not os.path.isfile(c.path):
            problems.append(f"файл не найден: {c.path}")
        if not ULID_RE.match(c.channel):
            problems.append(f"{c.file}: channel {c.channel!r} не похож на id канала dur.io (26 символов)")
        if c.channel in seen:
            problems.append(f"канал {c.channel} указан дважды: {seen[c.channel]} и {c.file}")
        seen[c.channel] = c.file
    return problems


MESSAGES_KEY_RE = re.compile(r'(?<!\\)"messages"\s*:\s*\[')
KEEP_FIELDS = ("id", "type", "timestamp", "timestampEdited", "isPinned", "content", "author", "attachments",
               "embeds", "stickers", "mentions", "reference", "forwardedMessage", "interaction")


def slim(msg: dict) -> dict:
    """Drop fields the import never uses (reactions, inline emoji, embeds of normal messages)."""
    out = {k: msg[k] for k in KEEP_FIELDS if k in msg}
    if out.get("type") != POLL_RESULT:
        out.pop("embeds", None)
    return out


class ExportReader:
    """Streams a DiscordChatExporter JSON file: header first, then messages one by one.

    A 300 MB export does not fit json.load on a 32-bit Python; this keeps only a few MB in memory."""

    CHUNK = 4 * 1024 * 1024

    def __init__(self, path: str):
        self.path = path
        self.f = open(path, encoding="utf-8")
        self.buf = ""
        self.pos = 0
        self.eof = False
        self.dec = json.JSONDecoder()
        while True:
            m = MESSAGES_KEY_RE.search(self.buf)
            if m:
                break
            if not self._fill():
                raise ToolError(f"{path}: не похоже на экспорт DiscordChatExporter (нет \"messages\")")
        head = self.buf[: m.start()].rstrip().rstrip(",") + "}"
        try:
            self.header: dict = json.loads(head)
        except ValueError as e:
            raise ToolError(f"{path}: не удалось разобрать заголовок экспорта: {e}")
        self.pos = m.end()

    def _fill(self) -> bool:
        if self.eof:
            return False
        chunk = self.f.read(self.CHUNK)
        if not chunk:
            self.eof = True
            return False
        self.buf = self.buf[self.pos:] + chunk
        self.pos = 0
        return True

    def messages(self) -> Iterator[dict]:
        try:
            while True:
                while True:
                    while self.pos < len(self.buf) and self.buf[self.pos] in " \t\r\n,":
                        self.pos += 1
                    if self.pos < len(self.buf) or not self._fill():
                        break
                if self.pos >= len(self.buf):
                    raise ToolError(f"{self.path}: файл обрывается внутри списка сообщений")
                if self.buf[self.pos] == "]":
                    return
                try:
                    obj, end = self.dec.raw_decode(self.buf, self.pos)
                except json.JSONDecodeError:
                    if self._fill():
                        continue
                    raise ToolError(f"{self.path}: файл повреждён или обрывается (позиция {self.pos})")
                self.pos = end
                yield obj
        finally:
            self.close()

    def close(self) -> None:
        self.f.close()


def read_export(path: str) -> tuple[dict, Iterator[dict]]:
    r = ExportReader(path)
    return r.header, (slim(m) for m in r.messages())


def load_export(path: str) -> dict:
    """Whole export as a dict (messages slimmed and sorted oldest first)."""
    header, msgs = read_export(path)
    data = dict(header)
    data["messages"] = sorted_messages({"messages": list(msgs)})
    return data


def sorted_messages(data: dict) -> list[dict]:
    return sorted(data.get("messages") or [], key=lambda m: snowflake(m.get("id")))


def build_index(cfg: Config) -> ExportIndex:
    """Pass 1 over all mapped files (replies and channel links may point into other channels)."""
    idx = ExportIndex(link_channel_names=bool(cfg.options.get("link_channel_names", True)))
    for p in glob.glob(os.path.join(glob.escape(cfg.export_dir), "*.json")):
        h = read_channel_header(p)
        if h:
            idx.channel_names[h[0]] = h[1]
    for c in cfg.channels:
        log(f"  индекс: {c.file}")
        header, msgs = read_export(c.path)
        ch = header.get("channel") or {}
        c.discord_id, c.name = str(ch.get("id", "")), ch.get("name", "")
        idx.channel_names[c.discord_id] = c.name
        idx.mapped[c.discord_id] = c.channel
        idx.add_messages(msgs)
    return idx


def channel_plans(cfg: Config, c: ChannelMap, idx: ExportIndex) -> tuple[list[MessagePlan], dict]:
    _, msgs = read_export(c.path)
    base = os.path.dirname(os.path.abspath(c.path))
    max_bytes = int(float(cfg.options["max_file_mb"]) * 2**20)
    stats: dict[str, Any] = {"total": 0, "skipped": {}, "empty": 0, "replies": 0, "replies_dropped": 0,
                             "forwarded": 0, "stickers": 0, "polls": 0, "edited": 0, "pinned": 0,
                             "att": {"local": 0, "remote": 0, "missing": 0, "too_big": 0},
                             "bytes": 0, "authors": set(), "big_files": []}
    plans = []
    for m in msgs:
        stats["total"] += 1
        reason = skip_reason(m)
        if reason == "empty":
            stats["empty"] += 1
            continue
        if reason:
            t = reason.split(":", 1)[1]
            stats["skipped"][t] = stats["skipped"].get(t, 0) + 1
            continue
        p = plan_message(m, idx, base, max_bytes)
        assert p is not None
        plans.append(p)
        stats["authors"].add(p.author_id)
        stats["replies"] += len(p.reply_to)
        stats["replies_dropped"] += p.dropped_replies
        stats["forwarded"] += int(p.forwarded)
        stats["stickers"] += len(m.get("stickers") or [])
        stats["polls"] += int(m.get("type") == POLL_RESULT)
        stats["edited"] += int(bool(p.edited))
        stats["pinned"] += int(p.pinned)
        for a in p.attachments:
            stats["att"][a.kind] += 1
            if a.kind == "too_big":
                stats["big_files"].append((a.file_name, a.size))
        stats["bytes"] += sum(a.size for a in p.uploads())
    plans.sort(key=lambda p: snowflake(p.original_id))  # exports are chronological; be sure
    return plans, stats


def avatar_path(cfg: Config, idx: ExportIndex, author_id: str) -> str | None:
    url = idx.avatars.get(author_id)
    if not url:
        return None
    if not is_remote(url):
        return resolve_local(cfg.export_dir, url)
    # Remote URL like .../avatars/<user>/<hash>.png: DiscordChatExporter stores assets/<hash>-<x>.png
    m = re.search(r"/avatars/\d+/([0-9A-Za-z_]+)\.", url)
    if m:
        hits = glob.glob(os.path.join(glob.escape(cfg.export_dir), "assets", glob.escape(m.group(1)) + "-*"))
        if hits:
            return hits[0]
    return None


# ----------------------------------------------------------------------------------------------
# State file
# ----------------------------------------------------------------------------------------------

class State:
    """Resume data. Written atomically after every successful request.

    channels: per config file name -> dur.io channel, original id of the last imported message, counters.
    uploads:  Discord attachment id -> autumn id of an upload not yet claimed by an imported message
              (removed once its batch is imported).
    avatars:  Discord author id -> {"id": autumn id or null, "used": claimed by an imported message}.
    """

    def __init__(self, path: str):
        self.path = path
        self.data: dict[str, Any] = {"version": 1, "channels": {}, "uploads": {}, "avatars": {},
                                     "totals": {"imported": 0, "skipped": 0, "files": 0, "bytes": 0},
                                     "errors": []}
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                self.data.update(json.load(f))

    def channel(self, key: str, target: str) -> dict:
        return self.data["channels"].setdefault(key, {"channel": target, "last_original_id": None,
                                                      "imported": 0, "skipped": 0, "files": 0,
                                                      "bytes": 0, "done": False})

    def cached_upload(self, att_id: str, max_age: float, now: float | None = None) -> tuple[bool, str | None]:
        """(known, id): an upload from an interrupted run, if still young enough to be unclaimed-safe."""
        u = self.data["uploads"].get(att_id)
        now = time.time() if now is None else now
        if u is None:
            return False, None
        if u.get("id") is None or now - u.get("at", 0) <= max_age:
            return True, u.get("id")
        return False, None

    def cached_avatar(self, author_id: str, max_age: float, now: float | None = None) -> tuple[bool, str | None]:
        """(known, id). Claimed avatars are reused forever, unclaimed ones only while young."""
        a = self.data["avatars"].get(author_id)
        now = time.time() if now is None else now
        if a is None:
            return False, None
        if a.get("id") is None or a.get("used") or now - a.get("at", 0) <= max_age:
            return True, a.get("id")
        return False, None

    def mark_imported(self, key: str, batch: list[MessagePlan], imported: int, skipped: int,
                      files: int, nbytes: int) -> None:
        ch = self.data["channels"][key]
        for p in batch:
            for a in p.uploads():
                self.data["uploads"].pop(a.att_id, None)
            if p.author_id in self.data["avatars"]:
                self.data["avatars"][p.author_id]["used"] = True
        ch["last_original_id"] = batch[-1].original_id
        for d in (ch, self.data["totals"]):
            d["imported"] += imported
            d["skipped"] += skipped
            d["files"] += files
            d["bytes"] += nbytes

    def error(self, channel: str, what: str) -> None:
        self.data["errors"].append({"time": dt.datetime.now().isoformat(timespec="seconds"),
                                    "channel": channel, "error": what})
        self.data["errors"] = self.data["errors"][-500:]

    def save(self) -> None:
        d = os.path.dirname(os.path.abspath(self.path))
        fd, tmp = tempfile.mkstemp(prefix=".state-", suffix=".tmp", dir=d)
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
                json.dump(self.data, f, ensure_ascii=False, indent=1)
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise


# ----------------------------------------------------------------------------------------------
# HTTP
# ----------------------------------------------------------------------------------------------

class ApiError(Exception):
    def __init__(self, status: int, body: Any, what: str):
        self.status, self.body, self.what = status, body, what
        self.type = body.get("type") if isinstance(body, dict) else None
        text = json.dumps(body, ensure_ascii=False)[:300] if body else ""
        super().__init__(f"{what}: HTTP {status} {text}")


def retry_after_seconds(headers: dict[str, str], body: Any) -> float:
    if isinstance(body, dict) and isinstance(body.get("retry_after"), (int, float)):
        return body["retry_after"] / 1000.0
    h = {k.lower(): v for k, v in headers.items()}
    for name, scale in (("retry-after", 1.0), ("x-ratelimit-reset-after", 0.001)):
        if name in h:
            try:
                return float(h[name]) * scale
            except ValueError:
                pass
    return 5.0


class Http:
    def __init__(self, tries: int = 5):
        self.tries = tries
        self.token: str | None = None
        self.ctx = ssl.create_default_context()

    def _once(self, method: str, url: str, headers: dict[str, str], body: Any,
              timeout: float) -> tuple[int, dict[str, str], Any]:
        u = urllib.parse.urlsplit(url)
        if u.scheme == "https":
            conn: http.client.HTTPConnection = http.client.HTTPSConnection(
                u.hostname or "", u.port, timeout=timeout, context=self.ctx)
        else:
            conn = http.client.HTTPConnection(u.hostname or "", u.port, timeout=timeout)
        try:
            path = (u.path or "/") + ("?" + u.query if u.query else "")
            conn.request(method, path, body=body, headers=headers)
            r = conn.getresponse()
            raw = r.read()
            hdrs = dict(r.getheaders())
        finally:
            conn.close()
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = raw.decode("utf-8", "replace")[:500]
        return r.status, hdrs, parsed

    def request(self, method: str, url: str, what: str, json_body: Any = None,
                body_factory: Callable[[], tuple[Iterable[bytes], int, str]] | None = None,
                extra_headers: dict[str, str] | None = None, timeout: float = 120.0) -> Any:
        """Retries network errors and 5xx with exponential backoff, waits out 429."""
        attempt = 0
        limited = 0
        while True:
            headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
            if self.token:
                headers["x-session-token"] = self.token
            headers.update(extra_headers or {})
            body: Any = None
            if json_body is not None:
                body = json.dumps(json_body, ensure_ascii=False).encode("utf-8")
                headers["Content-Type"] = "application/json"
            elif body_factory is not None:
                body, length, ctype = body_factory()
                headers["Content-Type"] = ctype
                headers["Content-Length"] = str(length)
            try:
                status, hdrs, parsed = self._once(method, url, headers, body, timeout)
            except (OSError, http.client.HTTPException) as e:
                attempt += 1
                if attempt >= self.tries:
                    raise ToolError(f"{what}: сеть недоступна после {attempt} попыток: {e}")
                wait = 2 ** attempt
                log(f"    сетевая ошибка ({e}); повтор через {wait} с")
                time.sleep(wait)
                continue
            if status == 429:
                limited += 1
                if limited > 50:
                    raise ApiError(status, parsed, what)
                wait = max(0.5, retry_after_seconds(hdrs, parsed)) + 0.2
                if wait > 2:
                    log(f"    лимит запросов, ждём {wait:.1f} с")
                time.sleep(wait)
                continue
            if status >= 500:
                attempt += 1
                if attempt >= self.tries:
                    raise ApiError(status, parsed, what)
                wait = 2 ** attempt
                log(f"    сервер ответил {status}; повтор через {wait} с")
                time.sleep(wait)
                continue
            if status >= 400:
                raise ApiError(status, parsed, what)
            return parsed


def sanitize_filename(name: str) -> str:
    name = strip_control(name).replace('"', "'").replace("\\", "_").replace("/", "_")
    return name or "file"


def multipart_factory(path: str, filename: str, content_type: str | None = None
                      ) -> Callable[[], tuple[Iterable[bytes], int, str]]:
    """Streams one file as multipart/form-data field 'file' (1 MiB chunks)."""
    ctype = content_type or mimetypes.guess_type(filename)[0] or "application/octet-stream"

    def make() -> tuple[Iterable[bytes], int, str]:
        boundary = "----durio" + uuid.uuid4().hex
        head = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
                f"filename=\"{sanitize_filename(filename)}\"\r\nContent-Type: {ctype}\r\n\r\n").encode("utf-8")
        tail = f"\r\n--{boundary}--\r\n".encode("ascii")
        size = os.path.getsize(path)

        def gen() -> Iterator[bytes]:
            yield head
            with open(path, "rb") as f:
                while True:
                    chunk = f.read(1024 * 1024)
                    if not chunk:
                        break
                    yield chunk
            yield tail

        return gen(), len(head) + size + len(tail), f"multipart/form-data; boundary={boundary}"

    return make


# ----------------------------------------------------------------------------------------------
# Session: login, elevation, uploads, import
# ----------------------------------------------------------------------------------------------

class Session:
    def __init__(self, cfg: Config, args: argparse.Namespace):
        self.cfg = cfg
        self.http = Http()
        self.first_code: str | None = args.totp_code
        self.email: str | None = args.email
        self.login_code: str | None = None

    def code(self, prompt: str = "Код TOTP из приложения-аутентификатора: ") -> str:
        if self.first_code:
            c, self.first_code = self.first_code, None
            return c
        while True:
            c = input(prompt).strip().replace(" ", "")
            if re.fullmatch(r"\d{6}", c):
                return c
            log("  нужен 6-значный код")

    def login(self) -> None:
        email = self.email or input("Email аккаунта dur.io: ").strip()
        password = os.environ.get("DURIO_PASSWORD") or getpass.getpass("Пароль: ")
        r = self.http.request("POST", self.cfg.api + "/auth/session/login", "вход",
                              json_body={"email": email, "password": password, "friendly_name": FRIENDLY_NAME})
        if isinstance(r, dict) and r.get("result") == "MFA":
            code = self.code()
            self.login_code = code
            r = self.http.request("POST", self.cfg.api + "/auth/session/login", "вход (2FA)",
                                  json_body={"mfa_ticket": r["ticket"], "mfa_response": {"totp_code": code},
                                             "friendly_name": FRIENDLY_NAME})
        if not isinstance(r, dict) or r.get("result") != "Success" or not r.get("token"):
            raise ToolError(f"вход не удался: {r.get('result') if isinstance(r, dict) else r}")
        self.http.token = r["token"]
        log("  вход выполнен")

    def elevate(self) -> None:
        """MFA ticket from a TOTP code, then POST /admin/elevate. The code typed at login is tried once."""
        code, self.login_code = self.login_code, None
        for attempt in range(3):
            if code is None:
                code = self.code("Код TOTP для режима администратора: " if attempt == 0 else
                                 "Код не подошёл; дождитесь следующего кода и введите его: ")
            try:
                t = self.http.request("PUT", self.cfg.api + "/auth/mfa/ticket", "MFA-тикет",
                                      json_body={"totp_code": code})
            except ApiError as e:
                if e.status in (400, 401, 403) and attempt < 2:
                    code = None
                    continue
                raise
            r = self.http.request("POST", self.cfg.api + "/admin/elevate", "режим администратора",
                                  extra_headers={"x-mfa-ticket": t["token"]})
            until = r.get("expires_at", "?") if isinstance(r, dict) else "?"
            log(f"  режим администратора до {until}")
            return
        raise ToolError("не удалось включить режим администратора")

    def logout(self) -> None:
        if not self.http.token:
            return
        try:
            self.http.tries = 2
            self.http.request("POST", self.cfg.api + "/auth/session/logout", "выход", timeout=20)
            log("  сеанс завершён (logout)")
        except (ApiError, ToolError) as e:
            log(f"  выход не удался: {e}")
        self.http.token = None

    def admin(self, method: str, path: str, what: str, json_body: Any = None) -> Any:
        while True:
            try:
                return self.http.request(method, self.cfg.api + path, what, json_body=json_body, timeout=300)
            except ApiError as e:
                if e.status in (401, 403) and e.type == "AdminElevationRequired":
                    log("  режим администратора истёк, нужен новый код")
                    self.elevate()
                    continue
                raise

    def upload(self, tag: str, path: str, filename: str) -> str:
        r = self.http.request("POST", f"{self.cfg.autumn}/{tag}", f"загрузка {filename}",
                              body_factory=multipart_factory(path, filename), timeout=900)
        if not isinstance(r, dict) or not r.get("id"):
            raise ApiError(200, r, f"загрузка {filename}")
        return r["id"]


# ----------------------------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------------------------

def select_channels(cfg: Config, only: list[str] | None) -> list[ChannelMap]:
    if not only:
        return cfg.channels
    out = []
    for c in cfg.channels:
        keys = {c.file, os.path.basename(c.file), c.channel, c.discord_id, c.name}
        if any(o in keys or (o and o in c.file) for o in only):
            out.append(c)
    if not out:
        raise ToolError(f"--only {only}: ни один канал конфига не подошёл")
    return out


def print_stats(c: ChannelMap, plans: list[MessagePlan], st: dict) -> None:
    sk = ", ".join(f"{k}: {v}" for k, v in sorted(st["skipped"].items(), key=lambda x: -x[1])) or "нет"
    a = st["att"]
    log(f"\n== #{c.name} ({c.discord_id}) -> {c.channel}")
    log(f"   сообщений в файле: {st['total']}; к импорту: {len(plans)}; пустых пропущено: {st['empty']}")
    log(f"   системные пропущены: {sk}")
    log(f"   ответы: {st['replies']} (отброшено: {st['replies_dropped']}); пересланных: {st['forwarded']};"
        f" стикеров: {st['stickers']}; итогов опросов: {st['polls']}; изменённых: {st['edited']};"
        f" закреплённых: {st['pinned']}")
    log(f"   вложения: локальных {a['local']} ({human_size(st['bytes'])}), удалённых ссылок {a['remote']},"
        f" нет файла {a['missing']}, слишком больших {a['too_big']}")
    for name, size in st["big_files"]:
        log(f"     слишком большой: {name} ({human_mb(size)})")
    log(f"   авторов: {len(st['authors'])}")


def show_samples(plans: list[MessagePlan], n: int) -> None:
    picks: list[MessagePlan] = []

    def add(pred: Callable[[MessagePlan], bool]) -> None:
        for p in plans:
            if pred(p) and p not in picks:
                picks.append(p)
                return

    for pred in (lambda p: True,
                 lambda p: bool(p.reply_to),
                 lambda p: any(a.kind == "local" for a in p.attachments),
                 lambda p: any(a.kind != "local" for a in p.attachments),
                 lambda p: p.forwarded,
                 lambda p: "<#" in p.content,
                 lambda p: "[стикер" in p.content,
                 lambda p: p.content.startswith("📊")):
        add(pred)
    for p in picks[:n]:
        uploaded = {a.att_id: f"<upload:{a.file_name}>" for a in p.uploads()}
        payload = p.payload(uploaded, "<avatar>")
        log("   пример: " + json.dumps(payload, ensure_ascii=False)[:1200])


def cmd_check(cfg: Config, args: argparse.Namespace, samples: int = 0) -> int:
    problems = validate_config(cfg)
    for p in problems:
        log("ОШИБКА:", p)
    if any("не найден" in p for p in problems):
        return 2
    log("Чтение экспорта…")
    idx = build_index(cfg)
    chans = select_channels(cfg, args.only)
    totals = {"msgs": 0, "bytes": 0, "local": 0, "remote": 0, "missing": 0, "too_big": 0,
              "replies": 0, "skipped": 0}
    authors: set[str] = set()
    for c in chans:
        plans, st = channel_plans(cfg, c, idx)
        if args.limit is not None:
            plans = plans[: args.limit]
        print_stats(c, plans, st)
        totals["msgs"] += len(plans)
        totals["bytes"] += st["bytes"]
        totals["replies"] += st["replies"]
        totals["skipped"] += st["empty"] + sum(st["skipped"].values())
        for k in ("local", "remote", "missing", "too_big"):
            totals[k] += st["att"][k]
        authors |= st["authors"]
        if samples:
            show_samples(plans, samples)
    av_bytes = 0
    av_found = 0
    for a in authors:
        p = avatar_path(cfg, idx, a)
        if p:
            av_found += 1
            av_bytes += os.path.getsize(p)
    log("\n== Итого")
    log(f"   сообщений к импорту: {totals['msgs']} (пропущено системных и пустых: {totals['skipped']});"
        f" ответов: {totals['replies']}")
    log(f"   авторов: {len(authors)} (аватары найдены: {av_found})")
    log(f"   файлов к загрузке: {totals['local']} ({human_size(totals['bytes'])}) + аватары {human_mb(av_bytes)}")
    log(f"   не будут загружены: удалённые ссылки {totals['remote']}, нет файла {totals['missing']},"
        f" больше {cfg.options['max_file_mb']} МБ {totals['too_big']}")
    if problems:
        log(f"\nВ конфиге проблем: {len(problems)}, см. выше.")
        return 1
    return 0


def cmd_status(cfg: Config, args: argparse.Namespace) -> int:
    if not os.path.exists(args.state):
        log(f"Файла состояния нет ({args.state}): импорт ещё не запускался.")
        return 0
    st = State(args.state)
    for key, ch in st.data["channels"].items():
        log(f"{key}\n   -> {ch['channel']}: импортировано {ch['imported']}, пропущено сервером {ch['skipped']},"
            f" файлов {ch['files']} ({human_size(ch['bytes'])}), последний id {ch['last_original_id']},"
            f" {'завершён' if ch.get('done') else 'не завершён'}")
    t = st.data["totals"]
    log(f"Всего: импортировано {t['imported']}, пропущено сервером {t['skipped']}, файлов {t['files']}"
        f" ({human_size(t['bytes'])}); аватаров {sum(1 for a in st.data['avatars'].values() if a.get('id'))};"
        f" незакреплённых загрузок {len(st.data['uploads'])}")
    errs = st.data["errors"]
    if errs:
        log(f"Ошибки ({len(errs)}, последние 10):")
        for e in errs[-10:]:
            log(f"   {e['time']} {e['channel']}: {e['error']}")
    return 0


def cmd_import(cfg: Config, args: argparse.Namespace) -> int:
    problems = validate_config(cfg)
    if problems:
        for p in problems:
            log("ОШИБКА:", p)
        return 2
    state = State(args.state)
    state.data["server"] = cfg.server
    log("Чтение экспорта…")
    idx = build_index(cfg)
    chans = select_channels(cfg, args.only)
    log(f"\nСервер: {cfg.server}; каналов: {len(chans)}" + (f"; --limit {args.limit}" if args.limit else ""))
    if not args.yes:
        if input("Начать импорт? [y/N] ").strip().lower() not in ("y", "yes", "д", "да"):
            return 1
    sess = Session(cfg, args)
    try:
        sess.login()
        sess.elevate()
        for c in chans:
            info = sess.http.request("GET", f"{cfg.api}/channels/{c.channel}", f"канал {c.channel}")
            if not isinstance(info, dict) or info.get("channel_type") != "TextChannel":
                raise ToolError(f"{c.channel} — не текстовый канал сервера")
            log(f"  канал {c.channel}: «{info.get('name')}» — ок")
        for c in chans:
            import_channel(cfg, args, sess, state, idx, c)
        log("\nГотово.")
        return 0
    except KeyboardInterrupt:
        log("\nПрервано (Ctrl+C). Состояние сохранено, повторный запуск продолжит с места остановки.")
        return 130
    except (ApiError, ToolError) as e:
        state.error("-", str(e))
        log(f"\nОШИБКА: {e}\nСостояние сохранено; после исправления запустите import снова.")
        return 1
    finally:
        try:
            state.save()
        finally:
            sess.logout()


def import_channel(cfg: Config, args: argparse.Namespace, sess: Session, state: State, idx: ExportIndex,
                   c: ChannelMap) -> None:
    opts = cfg.options
    plans, _ = channel_plans(cfg, c, idx)
    ch = state.channel(c.file, c.channel)
    if ch["channel"] != c.channel:
        raise ToolError(f"{c.file}: в состоянии канал {ch['channel']}, в конфиге {c.channel}. "
                        f"Для другого канала используйте отдельный файл состояния (--state).")
    todo = pending_plans(plans, ch["last_original_id"], args.limit)
    total = len(plans) if args.limit is None else min(len(plans), args.limit)
    log(f"\n== #{c.name} -> {c.channel}: осталось {len(todo)} из {total}")
    if not todo:
        ch["done"] = ch["done"] or args.limit is None
        return
    max_age = float(opts["upload_reuse_minutes"]) * 60
    t0 = time.time()
    sent = 0
    files0, bytes0 = ch["files"], ch["bytes"]
    batches = list(make_batches(todo, int(opts["batch_size"]), int(float(opts["max_batch_upload_mb"]) * 2**20)))
    for n, batch in enumerate(batches, 1):
        uploaded: dict[str, str | None] = {}
        avatars: dict[str, str | None] = {}
        new_files = new_bytes = 0
        for p in batch:
            if opts.get("import_avatars", True) and p.author_id not in avatars:
                avatars[p.author_id] = get_avatar(cfg, sess, state, idx, p.author_id, max_age)
            for a in p.uploads():
                known, fid = state.cached_upload(a.att_id, max_age)
                if not known:
                    try:
                        fid = sess.upload("attachments", a.path or "", a.file_name)
                        new_files += 1
                        new_bytes += a.size
                    except ApiError as e:
                        if e.status >= 500 or e.status == 429 or e.status == 401:
                            raise
                        state.error(c.file, f"{p.original_id}: файл {a.file_name} отклонён: {e}")
                        fid = None
                    state.data["uploads"][a.att_id] = {"id": fid, "at": time.time()}
                    state.save()
                uploaded[a.att_id] = fid
        payload = {"source": SOURCE, "messages": [p.payload(uploaded, avatars.get(p.author_id)) for p in batch]}
        r = sess.admin("POST", f"/admin/import/channels/{c.channel}/messages", "импорт", json_body=payload)
        imported = int(r.get("imported", 0)) if isinstance(r, dict) else 0
        skipped = int(r.get("skipped", 0)) if isinstance(r, dict) else 0
        state.mark_imported(c.file, batch, imported, skipped, new_files, new_bytes)
        state.save()
        sent += len(batch)
        if n % int(opts["progress_every"]) == 0 or n == len(batches):
            el = max(time.time() - t0, 0.001)
            rate = sent / el
            eta = (len(todo) - sent) / rate if rate > 0 else 0
            done = total - len(todo) + sent
            log(f"   {done}/{total} сообщений, файлов {ch['files'] - files0} ({human_size(ch['bytes'] - bytes0)}),"
                f" {rate:.1f} сообщ/с, осталось ~{dt.timedelta(seconds=int(eta))}")
    ch["done"] = ch["done"] or args.limit is None
    state.save()


def get_avatar(cfg: Config, sess: Session, state: State, idx: ExportIndex, author_id: str,
               max_age: float) -> str | None:
    known, fid = state.cached_avatar(author_id, max_age)
    if known:
        return fid
    path = avatar_path(cfg, idx, author_id)
    fid = None
    if path:
        try:
            fid = sess.upload("avatars", path, os.path.basename(path))
        except ApiError as e:
            if e.status >= 500 or e.status == 429 or e.status == 401:
                raise
            log(f"    аватар {idx.users.get(author_id, author_id)} не принят: {e.type or e.status}")
    state.data["avatars"][author_id] = {"id": fid, "at": time.time(), "used": False}
    state.save()
    return fid


def main(argv: list[str] | None = None) -> int:
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser(description="Импорт истории Discord (DiscordChatExporter JSON) в dur.io")
    ap.add_argument("command", choices=["check", "dry-run", "import", "status"])
    ap.add_argument("--config", required=True, help="JSON-файл сопоставления каналов")
    ap.add_argument("--state", help="файл состояния (по умолчанию <config>.state.json)")
    ap.add_argument("--only", action="append",
                    help="только этот канал (имя файла, имя или id канала Discord/dur.io); можно повторять")
    ap.add_argument("--limit", type=int, help="только первые N сообщений каждого канала (тест)")
    ap.add_argument("--samples", type=int, default=5, help="dry-run: примеров на канал")
    ap.add_argument("--yes", action="store_true", help="не спрашивать подтверждение")
    ap.add_argument("--email", help="email аккаунта (пароль — из DURIO_PASSWORD или запрос)")
    ap.add_argument("--totp-code", help="первый код TOTP (следующие будут запрошены)")
    args = ap.parse_args(argv)
    if args.state is None:
        base = args.config[:-5] if args.config.lower().endswith(".json") else args.config
        args.state = base + ".state.json"
    try:
        cfg = load_config(args.config)
        if args.command == "check":
            return cmd_check(cfg, args)
        if args.command == "dry-run":
            return cmd_check(cfg, args, samples=max(1, args.samples))
        if args.command == "status":
            return cmd_status(cfg, args)
        return cmd_import(cfg, args)
    except ToolError as e:
        log(f"ОШИБКА: {e}")
        return 2
    except KeyboardInterrupt:
        log("\nПрервано.")
        return 130


if __name__ == "__main__":
    sys.exit(main())
