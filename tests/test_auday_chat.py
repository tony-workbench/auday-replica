"""Auday-style Chat: retrieval rounds with local tools, an evidence-backed answer, a verifier."""

import json
import re
import tempfile
import unittest

from helpers import transcript  # noqa: F401  (adds the repo root to sys.path)

from app import auday_chat, auday_mode
from app.core import App
from memengine.llm import ScriptedProvider


def make_app(tmp, provider):
    app = App(tmp, provider=provider)
    app.update_settings({"pipeline": "auday"})
    app.add_transcript("2026-10-26T13:35:00-07:00", [
        {"start": 2, "end": 9, "text": "My idea here is to build on the paper's repository.", "speaker": "unknown"}])
    app.add_transcript("2026-10-26T14:38:54-07:00", [
        {"start": 0, "end": 6, "text": "我养了一只猫，叫年糕。", "speaker": "user", "owner": "Me"}])
    memory = auday_mode.add_review_candidates(app.store, [{"candidateIDs": ["m1"], "text": "You have a cat named Niangao.",
        "topic": "Pet", "kind": "attribute", "ownership": "clear", "hours": ["h"]}], {}, "2026-10-26T16:07:00-07:00")[0]
    app.memory_action(memory.id, "confirm")
    return app, memory


class ChatLoopTests(unittest.TestCase):
    def scripted(self, memory_id, wrong_quote=False, verdict="supported"):
        rounds = {"n": 0}

        def reply(system, user):
            if "final factual editor" in system:
                packet = json.loads(user)
                return {"checks": [{"claimIndex": i, "status": verdict, "correctedText": ""}
                                   for i, _ in enumerate(packet["candidateAnswer"]["claims"])]}
            if "Write the final answer" in system:
                quote = "a dog called Rex" if wrong_quote else "You have a cat named Niangao."
                return {"claims": [{"text": "Your cat is Niangao.", "identityMemoryIDs": [],
                                    "evidence": [{"quote": quote, "sourceID": "", "memoryID": memory_id}]}],
                        "insufficientEvidence": False, "reply": "Your cat is called Niangao."}
            rounds["n"] += 1
            if rounds["n"] == 1:
                return {"intent": "lookup", "focus": "Find the user's pet.", "tools": [
                    {"name": "read_memory", "query": "cat"}, {"name": "search", "query": "猫",
                                                              "startDate": "2026-10-26", "endDate": "2026-10-26"},
                    {"name": "search", "query": ""}]}
            return {"intent": "lookup", "focus": "done", "tools": []}
        return reply

    def test_rounds_tools_answer_and_verifier(self):
        with tempfile.TemporaryDirectory() as tmp:
            provider = ScriptedProvider(lambda s, u: {})
            app, memory = make_app(tmp, provider)
            provider.fn = self.scripted(memory.id)
            result = app.ask("我的猫 Niangao 是什么猫？")
        systems = [s for s, _ in provider.calls]
        self.assertEqual(sum("Plan the next retrieval step" in s for s in systems), 2)   # round 1 + empty round 2
        self.assertEqual(sum("final factual editor" in s for s in systems), 1)
        first = provider.calls[0][1]
        self.assertIn('"savedMemoryCount": 1', first)
        packet = json.loads(first.split("[user]\n", 1)[1].split("\n\n[user]")[0])
        self.assertEqual([m["id"] for m in packet["memories"]], [memory.id])     # metadata only, no text
        self.assertNotIn("text", packet["memories"][0])
        self.assertIn("Retrieval round 1", first)
        second = provider.calls[1][1]
        results = json.loads(re.search(r'\{"toolResults".*', second).group(0).split("\n\n[")[0])["toolResults"]
        self.assertEqual([r["tool"] for r in results], ["read_memory", "search", "search"])
        self.assertTrue(results[2]["wasRejected"])                         # empty query is refused
        self.assertEqual(result["answer"], "Your cat is called Niangao.")
        self.assertEqual(result["cited"], [memory.id])

    def test_ungrounded_or_unsupported_claims_are_dropped(self):
        for kwargs in ({"wrong_quote": True}, {"verdict": "unsupported"}):
            with tempfile.TemporaryDirectory() as tmp:
                provider = ScriptedProvider(lambda s, u: {})
                app, memory = make_app(tmp, provider)
                provider.fn = self.scripted(memory.id, **kwargs)
                result = app.ask("我养了什么宠物？")
            self.assertEqual(result["claims"], [])
            self.assertTrue(result["insufficientEvidence"])

    def test_improved_mode_marks_owner_snippets_and_adds_rule(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _ = make_app(tmp, ScriptedProvider(lambda s, u: {}))
            archive = auday_chat.Archive(app, "improved")
            hits = archive.run({"name": "read", "date": "2026-10-26", "hour": "14"})["items"]
            lecture = archive.run({"name": "read", "date": "2026-10-26", "hour": "13"})["items"]
        self.assertEqual(hits[0]["me"], 1)
        self.assertNotIn("me", lecture[0])
        self.assertIn("may cite only snippets", auday_chat._system("x", "improved"))
        self.assertNotIn("may cite only snippets", auday_chat._system("x", "auday"))


if __name__ == "__main__":
    unittest.main()
