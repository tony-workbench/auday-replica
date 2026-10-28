"""Watch places -> locationContext. Positions here are made up (a point in the ocean)."""

import json
import tempfile
import threading
import unittest
import urllib.request
from datetime import datetime, timedelta
from http.server import ThreadingHTTPServer

from helpers import transcript  # noqa: F401  (adds the repo root to sys.path)

from app import auday_mode, location
from app.core import App
from app.server import make_handler

OFF = "-07:00"


def at(clock):
    return datetime.fromisoformat(f"2026-10-26T{clock}{OFF}")


def samples(*clocks, name=None, accuracy=30):
    return [{"t": f"2026-10-26T{c}{OFF}", "lat": 0.5, "lon": -150.5, "accuracy": accuracy, "name": name}
            for c in clocks]


class ContextTests(unittest.TestCase):
    def test_five_minute_grid_and_evidence_window_match_the_capture(self):
        # Captured: 13:03:24–13:05:00 (evidence 13:03:24–13:05:24), 13:05–13:10 (13:03:24–13:09:31),
        # 13:10–13:15 (13:09:31–13:15:41).
        points = location.parse(samples("13:03:24", "13:05:24", "13:07:28", "13:09:31", "13:11:33",
                                        "13:13:36", "13:15:41"))
        items = location.context(points, at("13:00:00"), at("14:00:00"))
        rows = [(i["start"][11:19], i["end"][11:19], i["evidenceStart"][11:19], i["evidenceEnd"][11:19]) for i in items]
        self.assertEqual(rows[:3], [("13:03:24", "13:05:00", "13:03:24", "13:05:24"),
                                    ("13:05:00", "13:10:00", "13:03:24", "13:09:31"),
                                    ("13:10:00", "13:15:00", "13:09:31", "13:15:41")])
        self.assertEqual(rows[-1][:2], ("13:15:00", "13:16:41"))     # the last sample counts one more minute
        self.assertEqual(list(items[0]), ["confidence", "end", "evidenceEnd", "evidenceStart", "isApproximate",
                                          "nameSource", "start"])
        self.assertEqual({(i["confidence"], i["nameSource"], i["isApproximate"]) for i in items},
                         {("medium", "unresolved", True)})

    def test_lone_sample_is_low_confidence_for_one_minute(self):
        items = location.context(location.parse(samples("11:09:36")), at("11:00:00"), at("12:00:00"))
        self.assertEqual([(i["start"][11:], i["end"][11:], i["confidence"]) for i in items],
                         [("11:09:36" + OFF, "11:10:36" + OFF, "low")])

    def test_cut_at_fragments_and_the_hour_with_names(self):
        points = location.parse(samples("13:28:00", "13:30:05", "13:32:10", name="Harbor Cafe · Pier Road"))
        items = location.context(points, at("13:00:00"), at("13:31:00"), cuts=[at("13:30:01")])
        self.assertEqual([(i["start"][11:19], i["end"][11:19]) for i in items],
                         [("13:28:00", "13:30:00"), ("13:30:00", "13:30:01"), ("13:30:01", "13:31:00")])
        self.assertEqual({(i["name"], i["nameSource"]) for i in items}, {("Harbor Cafe · Pier Road", "appleGeocoder")})

    def test_gap_starts_a_new_stretch_and_poor_accuracy_is_low(self):
        points = location.parse(samples("10:00:00", "10:02:00", accuracy=500) + samples("10:20:00", "10:22:00"))
        items = location.context(points, at("10:00:00"), at("11:00:00"))
        self.assertEqual([(i["start"][11:19], i["end"][11:19], i["confidence"]) for i in items],
                         [("10:00:00", "10:03:00", "low"), ("10:20:00", "10:23:00", "medium")])

    def test_parse_rejects_bad_samples(self):
        with self.assertRaises(ValueError):
            location.parse([{"t": "2026-10-26T10:00:00", "lat": 0, "lon": 0}])
        with self.assertRaises(ValueError):
            location.parse([{"t": "2026-10-26T10:00:00-07:00", "lat": 95, "lon": 0}])


class AppPlacesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.app = App(self.tmp.name, transcriber=lambda *a, **k: ("zh", []))

    def tearDown(self):
        self.tmp.cleanup()

    def post(self, path, body):
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.app))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{server.server_address[1]}/api/{path}",
                                         json.dumps(body).encode(), {"Content-Type": "application/json"})
            with urllib.request.urlopen(req) as response:
                return json.load(response)
        finally:
            server.shutdown()
            server.server_close()

    def test_places_reach_the_recorded_context_and_chips_without_coordinates(self):
        sent = samples("10:00:10", "10:02:10", "10:04:10", name="Harbor Cafe · Pier Road")
        self.assertEqual(self.post("places", {"places": sent, "session": "S1"}), {"places": 3})
        # A resent copy without the name keeps the name.
        self.post("places", {"places": samples("10:00:10")})
        body = self.app.body_for(at("10:00:00"), at("11:00:00"))
        self.assertEqual(body["bodyContext"], [])                   # no Health export imported
        self.assertEqual([i["start"][11:19] for i in body["locationContext"]], ["10:00:10", "10:05:00"])
        self.assertTrue(all(i["name"] == "Harbor Cafe · Pier Road" for i in body["locationContext"]))

        snippets = [{"snippetID": "s1", "date": f"2026-10-26T10:01:00{OFF}", "end": f"2026-10-26T10:01:05{OFF}"},
                    {"snippetID": "s2", "date": f"2026-10-26T10:30:00{OFF}", "end": f"2026-10-26T10:30:05{OFF}"}]
        context = auday_mode.recorded_context(snippets, body)
        self.assertEqual([(c["label"]["start"][11:19], c["sourceIDs"]) for c in context["locationContext"]],
                         [("10:00:10", ["s1"]), ("10:05:00", [])])
        self.assertNotIn("lat", json.dumps(context))
        self.assertNotIn("-150.5", json.dumps(context))
        self.assertEqual(auday_mode.location_chips(body, snippets[0]["date"], snippets[0]["end"]),
                         [{"label": "📍 Harbor Cafe · Pier Road", "kind": "location", "alert": False}])
        self.assertEqual(auday_mode.location_chips(body, snippets[1]["date"], snippets[1]["end"]), [])

    def test_location_switch_off_and_no_data(self):
        self.assertIsNone(self.app.body_for(at("10:00:00"), at("11:00:00")))
        self.app.add_places(samples("10:00:10"))
        self.app.update_settings({"location_data": False})
        self.assertIsNone(self.app.body_for(at("10:00:00"), at("11:00:00")))

    def test_fragment_boundaries_cut_places(self):
        self.app.add_places(samples("12:27:52", "12:29:53", "12:31:55"))
        self.app.put_asset({"id": "a1", "start": f"2026-10-26T12:15:00{OFF}", "duration": 15 * 60 + 1})
        items = self.app.location_for(at("12:00:00"), at("13:00:00"))
        self.assertIn(("12:30:00", "12:30:01"), [(i["start"][11:19], i["end"][11:19]) for i in items])

    def test_body_context_still_works_with_places(self):
        self.app.add_places(samples("10:00:10"))
        body = self.app.body_for(at("10:00:00"), at("11:00:00"))
        self.assertEqual(set(body), {"bodyContext", "healthStatistics", "signals", "locationContext"})
        self.assertEqual(auday_mode._clip(body, f"2026-10-26T10:30:00{OFF}", f"2026-10-26T10:40:00{OFF}")["locationContext"], [])
        self.assertEqual(timedelta(minutes=1), location.TAIL)


if __name__ == "__main__":
    unittest.main()


class PlaceNameTests(unittest.TestCase):
    def test_a_street_address_is_not_a_place(self):
        self.assertIsNone(location.place_name("100 Main St"))
        self.assertIsNone(location.place_name("2200 Oak Ave"))
        self.assertEqual(location.place_name("City University · College Way"), "City University · College Way")
        self.assertEqual(location.place_name("Riverside Market · River Rd"), "Riverside Market · River Rd")
