"""Unit tests for the pure parts of discord_import.py. Run: python -m unittest (from this folder)."""
import json
import os
import shutil
import tempfile
import unittest

import discord_import as di

ULID_A = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
ULID_B = "01ARZ3NDEKTSV4RRFFQ69G5FBV"


def author(uid="1", name="user1", nick="Nick", bot=False, roles=None, avatar=None):
    return {"id": uid, "name": name, "discriminator": "0000", "nickname": nick, "color": None,
            "isBot": bot, "roles": roles or [], "avatarUrl": avatar}


def msg(mid, content="hi", mtype="Default", **kw):
    m = {"id": str(mid), "type": mtype, "timestamp": f"2023-02-13T16:19:{int(mid) % 60:02d}.000+04:00",
         "timestampEdited": None, "isPinned": False, "content": content, "author": author(),
         "attachments": [], "embeds": [], "stickers": [], "reactions": [], "mentions": [], "inlineEmojis": []}
    m.update(kw)
    return m


def index(**kw):
    idx = di.ExportIndex()
    idx.users.update({"100": "Alice", "200": "Bob"})
    idx.roles.update({"300": "Модераторы"})
    idx.channel_names.update({"10": "general", "11": "tech", "12": "unmapped"})
    idx.mapped.update({"10": ULID_A, "11": ULID_B})
    for k, v in kw.items():
        setattr(idx, k, v)
    return idx


class ContentTest(unittest.TestCase):
    def test_space_after_mentions(self):
        msg = {"mentions": [{"name": "dakarx", "nickname": "DakarX"}]}
        self.assertEqual(
            di.space_after_mentions("@DakarXhttps://x.org @DakarX hi", msg),
            "@DakarX https://x.org @DakarX hi",
        )
        self.assertEqual(di.space_after_mentions("@Bobhttps://x.org", {}), "@Bobhttps://x.org")

    def test_user_mentions(self):
        idx = index()
        self.assertEqual(di.convert_content("hi <@100> and <@!200>", idx), "hi @Alice and @Bob")
        self.assertEqual(di.convert_content("<@999>", idx), "@unknown-user")

    def test_role_mentions(self):
        idx = index()
        self.assertEqual(di.convert_content("<@&300> <@&301>", idx), "@Модераторы @role")

    def test_channel_mentions(self):
        idx = index()
        self.assertEqual(di.convert_content("<#10>", idx), f"<#{ULID_A}>")
        self.assertEqual(di.convert_content("<#12>", idx), "#unmapped")
        self.assertEqual(di.convert_content("<#13>", idx), "#channel")

    def test_rendered_channel_names(self):
        idx = index()
        self.assertEqual(di.convert_content("see #tech, not #techno or a#tech", idx),
                         f"see <#{ULID_B}>, not #techno or a#tech")
        self.assertEqual(di.convert_content("url https://x.org/#general", idx), "url https://x.org/#general")
        idx.link_channel_names = False
        self.assertEqual(di.convert_content("#tech", idx), "#tech")

    def test_emoji(self):
        idx = index()
        self.assertEqual(di.convert_content("<:PepeHmm:653027289918865425> <a:dance:1>", idx), ":PepeHmm: :dance:")

    def test_timestamps(self):
        idx = index()
        self.assertEqual(di.convert_content("<t:1700000000>", idx), "2023-11-14 22:13 UTC")
        self.assertEqual(di.convert_content("<t:1700000000:R>", idx), "2023-11-14 22:13 UTC")
        self.assertEqual(di.convert_content("<t:1700000000:d>", idx), "2023-11-14")
        self.assertEqual(di.convert_content("<t:1700000000:t>", idx), "22:13 UTC")

    def test_slash_and_markup_kept(self):
        idx = index()
        self.assertEqual(di.convert_content("</play:123> </COUNTRY> **bold** <…>", idx), "/play </COUNTRY> **bold** <…>")

    def test_author_name(self):
        self.assertEqual(di.author_display_name(author(nick="Ni\x00ck\n")), "Nick")
        self.assertEqual(di.author_display_name(author(name="base", nick="  ")), "base")
        self.assertEqual(len(di.author_display_name(author(nick="x" * 40))), 32)
        self.assertEqual(di.author_display_name({"id": "123456", "name": "", "nickname": None}), "user-3456")


class SkipTest(unittest.TestCase):
    def test_system_types(self):
        for t in ("GuildMemberJoin", "ChannelPinnedMessage", "ThreadCreated", "20", "8", "63"):
            self.assertEqual(di.skip_reason(msg(1, "Joined the server.", t)), f"system:{t}")
        self.assertIsNone(di.skip_reason(msg(1, "x", "Reply")))
        self.assertIsNone(di.skip_reason(msg(1, "", "PollResult")))

    def test_empty(self):
        self.assertEqual(di.skip_reason(msg(1, "  ")), "empty")
        self.assertIsNone(di.skip_reason(msg(1, "", attachments=[{"id": "1", "url": "x", "fileName": "x"}])))
        self.assertIsNone(di.skip_reason(msg(1, "", stickers=[{"name": "Wave"}])))
        self.assertIsNone(di.skip_reason(msg(1, "", forwardedMessage={"content": "fwd"})))
        self.assertEqual(di.skip_reason(msg(1, "", forwardedMessage={"content": ""})), "empty")

    def test_index_only_importable(self):
        idx = di.ExportIndex()
        idx.add_messages([msg(1, "a"), msg(2, "", "GuildMemberJoin"), msg(3, "")])
        self.assertEqual(set(idx.messages), {"1"})


class PlanTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.dir, "assets"))
        with open(os.path.join(self.dir, "assets", "%D0%9F-abc.png"), "wb") as f:
            f.write(b"x" * 10)
        with open(os.path.join(self.dir, "assets", "big-1.mp4"), "wb") as f:
            f.write(b"x" * 3000)
        with open(os.path.join(self.dir, "assets", "Пример-2.png"), "wb") as f:
            f.write(b"y")

    def tearDown(self):
        shutil.rmtree(self.dir)

    def plan(self, m, idx=None, max_bytes=2000):
        return di.plan_message(m, idx or index(), self.dir, max_bytes)

    def test_attachments(self):
        m = msg(5, "look", attachments=[
            {"id": "a1", "url": "assets\\%D0%9F-abc.png", "fileName": "П.png", "fileSizeBytes": 10},
            {"id": "a2", "url": "https://cdn.discordapp.com/attachments/1/2/x.png?ex=1", "fileName": "x.png",
             "fileSizeBytes": 5},
            {"id": "a3", "url": "assets\\gone-1.png", "fileName": "gone.png", "fileSizeBytes": 5},
            {"id": "a4", "url": "assets\\big-1.mp4", "fileName": "big.mp4", "fileSizeBytes": 3000},
            {"id": "a5", "url": "assets\\%D0%9F%D1%80%D0%B8%D0%BC%D0%B5%D1%80-2.png", "fileName": "Пример.png"},
        ])
        p = self.plan(m)
        self.assertEqual([a.kind for a in p.attachments], ["local", "remote", "missing", "too_big", "local"])
        self.assertEqual([a.att_id for a in p.uploads()], ["a1", "a5"])
        body = p.payload({"a1": "F1", "a5": None}, None)
        self.assertEqual(body["attachments"], ["F1"])
        self.assertEqual(body["content"].split("\n"), [
            "look", "[x.png пал жертвой переезда]", "[gone.png пал жертвой переезда]",
            "[big.mp4 пал жертвой переезда]", "[Пример.png пал жертвой переезда]"])

    def test_payload_shape(self):
        m = msg(7, "hello <@100>", isPinned=True, timestampEdited="2023-02-13T16:20:00.000+04:00")
        m["author"] = author("42", "base", "Shown", bot=True)
        body = self.plan(m).payload({}, "AV")
        self.assertEqual(body, {
            "original_id": "7", "timestamp": m["timestamp"], "edited": "2023-02-13T16:20:00.000+04:00",
            "author": {"original_id": "42", "name": "Shown", "avatar": "AV", "bot": True},
            "content": "hello @Alice", "attachments": [], "reply_to": [], "pinned": True})

    def test_reply_filtering(self):
        idx = index(messages={"1": "2023-01-01T00:00:00+00:00"})
        ref = {"type": "Default", "messageId": "1", "channelId": "10", "guildId": None}
        p = self.plan(msg(2, "re", "Reply", reference=ref), idx)
        self.assertEqual(p.reply_to, [{"original_id": "1", "timestamp": "2023-01-01T00:00:00+00:00"}])
        p = self.plan(msg(3, "re", "Reply", reference=dict(ref, messageId="999")), idx)
        self.assertEqual((p.reply_to, p.dropped_replies), ([], 1))

    def test_forwarded(self):
        idx = index()
        m = msg(9, "", reference={"type": "Forward", "messageId": "1"},
                forwardedMessage={"timestamp": "2024-03-22T22:53:54.625+04:00", "content": "line1\n\nline2",
                                  "attachments": [{"id": "f1", "url": "assets\\%D0%9F-abc.png", "fileName": "П.png"}],
                                  "stickers": []})
        p = self.plan(m, idx)
        self.assertEqual(p.content, "↪ Пересланное сообщение (2024-03-22 22:53):\n> line1\n>\n> line2")
        self.assertEqual(p.reply_to, [])
        self.assertEqual([a.att_id for a in p.uploads()], ["f1"])

    def test_stickers_and_poll(self):
        p = self.plan(msg(10, "hey", stickers=[{"id": "1", "name": "Wave", "format": "Lottie"}]))
        self.assertEqual(p.content, "hey\n[стикер: Wave]")
        poll = msg(11, "X's poll Q has closed.", "PollResult", embeds=[{"fields": [
            {"name": "poll_question_text", "value": "Q?"}, {"name": "victor_answer_votes", "value": "2"},
            {"name": "total_votes", "value": "5"}, {"name": "victor_answer_text", "value": "Да"}]}])
        self.assertEqual(self.plan(poll).content, "📊 Опрос «Q?» завершён. Победил ответ «Да» (2 из 5 голосов).")

    def test_truncate(self):
        p = self.plan(msg(12, "a" * 20000))
        self.assertEqual(len(p.payload({}, None)["content"]), di.MAX_CONTENT)

    def test_more_than_ten_files(self):
        atts = [{"id": f"x{i}", "url": "assets\\big-1.mp4", "fileName": f"{i}.mp4"} for i in range(12)]
        p = self.plan(msg(13, "", attachments=atts), max_bytes=10**6)
        self.assertEqual(len(p.uploads()), 10)
        body = p.payload({a.att_id: "F" + a.att_id for a in p.uploads()}, None)
        self.assertEqual(len(body["attachments"]), 10)
        self.assertEqual(body["content"], "[10.mp4 пал жертвой переезда]\n[11.mp4 пал жертвой переезда]")

    def test_only_lost_files_skipped(self):
        remote = {"id": "r", "url": "https://cdn.discordapp.com/attachments/1/2/x.png?ex=1", "fileName": "x.png"}
        big = {"id": "b", "url": "assets\\big-1.mp4", "fileName": "big.mp4"}
        local = {"id": "l", "url": "assets\\%D0%9F-abc.png", "fileName": "П.png"}
        saved = di.saved_check(self.dir, 2000)
        only_lost = msg(20, " ", attachments=[remote, big])
        self.assertEqual(di.skip_reason(only_lost, saved), "lost_files")
        self.assertIsNone(self.plan(only_lost))
        fwd_lost = msg(21, "", forwardedMessage={"content": "", "attachments": [remote]})
        self.assertEqual(di.skip_reason(fwd_lost, saved), "lost_files")
        # one file makes it: the message stays, the lost one becomes a line
        p = self.plan(msg(22, "", attachments=[remote, local]))
        self.assertEqual(p.payload({"l": "F"}, None)["content"], "[x.png пал жертвой переезда]")
        # with text: the text and the line
        p = self.plan(msg(23, "look", attachments=[remote]))
        self.assertEqual(p.payload({}, None)["content"], "look\n[x.png пал жертвой переезда]")
        # a skipped message is not in the index, so replies to it are dropped
        idx = di.ExportIndex()
        idx.add_messages([only_lost, msg(22, "", attachments=[remote, local])], saved)
        self.assertEqual(set(idx.messages), {"22"})


class RateLimitTest(unittest.TestCase):
    def test_state_from_headers(self):
        h = {"X-Ratelimit-Remaining": "0", "X-Ratelimit-Reset-After": "2500", "X-Ratelimit-Limit": "10"}
        self.assertEqual(di.ratelimit_state(h, 100.0), (0, 102.5))
        self.assertIsNone(di.ratelimit_state({"Content-Type": "application/json"}, 100.0))

    def test_buckets_per_service(self):
        self.assertEqual(di.ratelimit_key("https://x.org/autumn/attachments"), "autumn")
        self.assertEqual(di.ratelimit_key("https://x.org/api/admin/import/channels/1/messages"), "api")

    def test_waits_for_an_empty_bucket_only(self):
        h = di.Http()
        slept = []
        real = di.time.sleep
        di.time.sleep = slept.append
        try:
            h.limits["autumn"] = (0, di.time.time() + 5)
            h.wait_for_bucket("https://x.org/api/x")
            self.assertEqual(slept, [])
            h.wait_for_bucket("https://x.org/autumn/attachments")
            self.assertEqual(len(slept), 1)
            self.assertGreater(slept[0], 4)
            h.limits["autumn"] = (3, di.time.time() + 5)
            h.wait_for_bucket("https://x.org/autumn/attachments")
            self.assertEqual(len(slept), 1)
        finally:
            di.time.sleep = real


class ResumeTest(unittest.TestCase):
    def plans(self, ids):
        return [di.MessagePlan(str(i), "t", None, "1", "n", False, "c", [], [], False) for i in ids]

    def test_pending(self):
        ps = self.plans([10, 20, 30, 40])
        self.assertEqual([p.original_id for p in di.pending_plans(ps, None)], ["10", "20", "30", "40"])
        self.assertEqual([p.original_id for p in di.pending_plans(ps, "20")], ["30", "40"])
        self.assertEqual([p.original_id for p in di.pending_plans(ps, None, limit=2)], ["10", "20"])
        self.assertEqual(di.pending_plans(ps, "20", limit=2), [])
        self.assertEqual(di.pending_plans(ps, "40"), [])

    def test_batches(self):
        ps = self.plans(range(250))
        self.assertEqual([len(b) for b in di.make_batches(ps, 100, 10**9)], [100, 100, 50])
        ps[0].attachments = [di.AttachmentPlan("a", "a", "local", "p", 600)]
        ps[1].attachments = [di.AttachmentPlan("b", "b", "local", "p", 600)]
        self.assertEqual([len(b) for b in di.make_batches(ps[:5], 100, 1000)], [2, 3])

    def test_state_roundtrip(self):
        d = tempfile.mkdtemp()
        try:
            path = os.path.join(d, "m.state.json")
            st = di.State(path)
            st.channel("f.json", ULID_A)
            st.data["uploads"]["a1"] = {"id": "F1", "at": 1000.0}
            st.data["avatars"]["u1"] = {"id": "AV", "at": 1000.0, "used": False}
            st.save()
            st = di.State(path)
            self.assertEqual(st.cached_upload("a1", 60, now=1030.0), (True, "F1"))
            self.assertEqual(st.cached_upload("a1", 60, now=2000.0), (False, None))
            self.assertEqual(st.cached_avatar("u1", 60, now=2000.0), (False, None))
            batch = [di.MessagePlan("5", "t", None, "u1", "n", False, "c",
                                    [di.AttachmentPlan("a1", "a", "local", "p", 1)], [], False)]
            st.mark_imported("f.json", batch, 1, 0, 1, 1)
            st.save()
            st = di.State(path)
            self.assertEqual(st.data["uploads"], {})
            self.assertEqual(st.cached_avatar("u1", 60, now=10**9), (True, "AV"))
            ch = st.data["channels"]["f.json"]
            self.assertEqual((ch["last_original_id"], ch["imported"]), ("5", 1))
            self.assertEqual(os.listdir(d), ["m.state.json"])
        finally:
            shutil.rmtree(d)


class ReaderTest(unittest.TestCase):
    def test_stream_matches_json(self):
        data = {"guild": {"id": "1", "name": "G"}, "channel": {"id": "10", "name": "gen \"x\" messages"},
                "exportedAt": "now", "messages": [msg(i, "текст " * (i % 7)) for i in range(1, 300)],
                "messageCount": 299}
        d = tempfile.mkdtemp()
        try:
            path = os.path.join(d, "e.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            old = di.ExportReader.CHUNK
            di.ExportReader.CHUNK = 777  # force many refills mid-object
            try:
                header, msgs = di.read_export(path)
                got = list(msgs)
            finally:
                di.ExportReader.CHUNK = old
            self.assertEqual(header["channel"]["name"], "gen \"x\" messages")
            self.assertEqual([m["id"] for m in got], [str(i) for i in range(1, 300)])
            self.assertEqual(got[5]["content"], data["messages"][5]["content"])
            self.assertNotIn("reactions", got[0])
            self.assertEqual(di.read_channel_header(path), ("10", "gen \"x\" messages"))
        finally:
            shutil.rmtree(d)


class RetryTest(unittest.TestCase):
    def test_retry_after(self):
        self.assertEqual(di.retry_after_seconds({}, {"retry_after": 1500}), 1.5)
        self.assertEqual(di.retry_after_seconds({"Retry-After": "3"}, None), 3.0)
        self.assertEqual(di.retry_after_seconds({"X-RateLimit-Reset-After": "250"}, None), 0.25)

    def test_multipart(self):
        d = tempfile.mkdtemp()
        try:
            p = os.path.join(d, "f.bin")
            with open(p, "wb") as f:
                f.write(b"\x00\x01" * 1000)
            body, length, ctype = di.multipart_factory(p, 'a"b.png')()
            raw = b"".join(body)
            self.assertEqual(len(raw), length)
            self.assertTrue(ctype.startswith("multipart/form-data; boundary="))
            self.assertIn(b'name="file"; filename="a\'b.png"', raw)
            self.assertIn(b"Content-Type: image/png", raw)
        finally:
            shutil.rmtree(d)


if __name__ == "__main__":
    unittest.main()
