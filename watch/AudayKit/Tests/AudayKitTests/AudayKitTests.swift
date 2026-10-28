import Foundation
import Testing
@testable import AudayKit

private let pacific = TimeZone(identifier: "America/Los_Angeles")!
private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = pacific
    return c
}

private func at(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: text)!
}

@Test func fragmentsFollowTheObservedCuts() {
    // Observed on the real watch: 11:09:33 → 11:24:33 → 11:39:33 → 11:54:33, then a cut at 12:00.
    var start = at("2026-10-26T11:09:33-07:00")
    var cuts: [String] = []
    for _ in 0..<5 {
        start = FragmentClock.end(of: start, calendar: calendar)
        cuts.append(ReplicaAPI.iso(start, timeZone: pacific))
    }
    #expect(cuts == ["2026-10-26T11:24:33-07:00", "2026-10-26T11:39:33-07:00", "2026-10-26T11:54:33-07:00",
                     "2026-10-26T12:00:00-07:00", "2026-10-26T12:15:00-07:00"])
}

@Test func fragmentStartingOnTheHourRunsFifteenMinutes() {
    let start = at("2026-10-26T12:00:00-07:00")
    #expect(FragmentClock.end(of: start, calendar: calendar).timeIntervalSince(start) == 900)
}

@Test func metadataRoundTrips() {
    let fragment = Fragment(session: "S1", start: at("2026-10-26T11:09:33-07:00"), duration: 870.5)
    #expect(Fragment(metadata: fragment.metadata) == fragment)
    let mark = Mark(start: at("2026-10-26T11:20:00-07:00"))
    #expect(Mark(userInfo: mark.userInfo) == mark)
    #expect(Fragment(metadata: mark.userInfo) == nil)
}

@Test func uploadRequestMatchesTheServer() {
    let fragment = Fragment(id: "F1", session: "S1", start: at("2026-10-26T11:09:33-07:00"), duration: 10)
    let server = ReplicaAPI.serverURL(from: " 192.168.1.10:8765/ ")!
    let request = ReplicaAPI.upload(fragment, server: server, token: "t0k")
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString ==
            "http://192.168.1.10:8765/api/audio?start=2026-10-26T11:09:33-07:00&ext=caf&session=S1&fragment=F1")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
}

@Test func positiveOffsetIsEscaped() {
    let fragment = Fragment(id: "F1", session: "S1", start: at("2026-10-26T11:09:33+08:00"), duration: 10)
    let request = ReplicaAPI.upload(fragment, server: URL(string: "http://mac.local:8765")!, token: nil,
                                    timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    #expect(request.url!.absoluteString.contains("start=2026-10-26T11:09:33%2B08:00"))
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func markRequestBody() throws {
    let (request, body) = ReplicaAPI.mark(Mark(start: at("2026-10-26T11:20:00-07:00")),
                                          server: URL(string: "http://mac.local:8765")!, token: nil, timeZone: pacific)
    #expect(request.url?.path == "/api/marks")
    let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
    #expect(json == ["start": "2026-10-26T11:20:00-07:00"])
}

@Test func serverURLRejectsJunk() {
    #expect(ReplicaAPI.serverURL(from: "") == nil)
    #expect(ReplicaAPI.serverURL(from: "ftp://mac.local") == nil)
    #expect(ReplicaAPI.serverURL(from: "https://mac.local:8765")?.absoluteString == "https://mac.local:8765")
}

@Test func outcomesAndBackoff() {
    #expect(ReplicaAPI.outcome(status: 200) == .done)
    #expect(ReplicaAPI.outcome(status: 400) == .giveUp)
    #expect(ReplicaAPI.outcome(status: 422) == .giveUp)
    #expect(ReplicaAPI.outcome(status: 500) == .retry)
    #expect(ReplicaAPI.outcome(status: 401) == .retry)
    #expect(ReplicaAPI.outcome(status: nil) == .retry)
    #expect((1...8).map { ReplicaAPI.retryDelay(afterFailures: $0) } == [5, 10, 20, 40, 80, 160, 300, 300])
}

@Test func outboxKeepsItemsInOrderAcrossInstances() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let outbox = try Outbox(folder: folder)
    let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
    try Data("caf".utf8).write(to: audio)
    let late = Fragment(session: "S1", start: at("2026-10-26T11:24:33-07:00"), duration: 900)
    let mark = Mark(start: at("2026-10-26T11:20:00-07:00"))
    try outbox.add(late, audio: audio)
    try outbox.add(mark)
    #expect(!FileManager.default.fileExists(atPath: audio.path))

    let reopened = try Outbox(folder: folder)
    #expect(reopened.items() == [.mark(mark), .fragment(late)])
    #expect(try Data(contentsOf: reopened.audioURL(for: late)) == Data("caf".utf8))

    let failed = try Outbox(folder: folder.appendingPathComponent("Failed"))
    reopened.park(.fragment(late), in: failed)
    reopened.remove(.mark(mark))
    #expect(reopened.items().isEmpty)
    #expect(failed.fragments() == [late])
}

@Test func todayTotalResetsAtMidnight() {
    var today = RecordedToday()
    today.add(3600 + 19 * 60, startedAt: at("2026-10-26T09:00:00-07:00"), calendar: calendar)
    today.add(5 * 3600, startedAt: at("2026-10-26T10:00:00-07:00"), calendar: calendar)
    #expect(RecordedToday.format(today.seconds(on: at("2026-10-26T23:00:00-07:00"), calendar: calendar)) == "6h 19m")
    #expect(today.seconds(on: at("2026-10-27T08:00:00-07:00"), calendar: calendar) == 0)
    today.add(600, startedAt: at("2026-10-27T08:00:00-07:00"), calendar: calendar)
    #expect(RecordedToday.format(today.seconds) == "10m")
}

@Test func placesTravelWithTheFragment() {
    let places = [PlaceSample(time: at("2026-10-26T11:09:36-07:00"), latitude: 0.5, longitude: -150.5, accuracy: 35)]
    let fragment = Fragment(session: "S1", start: at("2026-10-26T11:09:33-07:00"), duration: 60, places: places)
    #expect(Fragment(metadata: fragment.metadata) == fragment)
    let old = Fragment(metadata: ["kind": "fragment", "id": "F", "session": "S", "start": 0.0])
    #expect(old?.places == [])
}

@Test func oldOutboxFragmentsWithoutPlacesStillDecode() throws {
    let json = #"{"fragment":{"id":"F","session":"S","start":0,"duration":5,"ext":"caf"}}"#
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let outbox = try Outbox(folder: folder)
    try Data(json.utf8).write(to: folder.appendingPathComponent("F.json"))
    #expect(outbox.fragments().map(\.id) == ["F"])
}

@Test func placeBatchQueuesAndUploads() throws {
    let samples = [PlaceSample(time: at("2026-10-26T11:09:36-07:00"), latitude: 0.5, longitude: -150.5, accuracy: 35,
                               name: "Harbor Cafe · Pier Road"),
                   PlaceSample(time: at("2026-10-26T11:11:36-07:00"), latitude: 0.5, longitude: -150.5, accuracy: 35)]
    var batch = PlaceBatch(fragment: Fragment(id: "F", session: "S1", start: samples[0].time, duration: 120, places: samples))
    #expect(batch.id == "F-places" && !batch.resolved)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let outbox = try Outbox(folder: folder)
    try outbox.add(batch)
    batch.resolved = true
    try outbox.add(batch)                       // replaced, not duplicated
    #expect(outbox.items() == [.places(batch)])

    let (request, body) = ReplicaAPI.places(batch, server: URL(string: "http://mac.local:8765")!, token: "t", timeZone: pacific)
    #expect(request.url?.path == "/api/places")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    let places = json["places"] as! [[String: Any]]
    #expect(json["session"] as? String == "S1")
    #expect(places[0]["t"] as? String == "2026-10-26T11:09:36-07:00")
    #expect(places[0]["name"] as? String == "Harbor Cafe · Pier Road")
    #expect(places[1]["name"] == nil)
}

@Test func stayAndLabel() {
    let t = at("2026-10-26T11:00:00-07:00")
    let still = [PlaceSample(time: t, latitude: 0.5, longitude: -150.5, accuracy: 30),
                 PlaceSample(time: t, latitude: 0.5005, longitude: -150.5, accuracy: 30)]     // ~55 m apart
    #expect(PlaceNaming.stay(still) != nil)
    let moving = still + [PlaceSample(time: t, latitude: 0.51, longitude: -150.5, accuracy: 30)]  // ~1.1 km
    #expect(PlaceNaming.stay(moving) == nil)
    #expect(PlaceNaming.stay([]) == nil)
    #expect(abs(PlaceNaming.metres(0, 0, 0, 1) - 111_195) < 5)
    #expect(PlaceNaming.label(place: "Harbor Cafe", street: "Pier Road") == "Harbor Cafe · Pier Road")
    #expect(PlaceNaming.label(place: "Pier Road", street: "Pier Road") == "Pier Road")
    #expect(PlaceNaming.label(place: nil, street: " ") == nil)
}

@Test func healthBatchesSplitQueueAndUpload() throws {
    let t = at("2026-10-26T13:35:00-07:00")
    let many = (0..<(HealthBatch.maxSamples + 1)).map { HealthSample(start: t.addingTimeInterval(Double($0)), end: t, value: 61) }
    let batches = HealthBatch.batches(kind: "hr", many)
    #expect(batches.map(\.count) == [HealthBatch.maxSamples, 1])

    let batch = HealthBatch(id: "H1", samples: ["hr": [HealthSample(start: t, end: t, value: 61)],
                                                "sleep": [HealthSample(start: t, end: t.addingTimeInterval(3600), value: 1)]])
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let outbox = try Outbox(folder: folder)
    try outbox.add(batch)
    #expect(outbox.items() == [.health(batch)])

    let (request, body) = ReplicaAPI.health(batch, server: URL(string: "http://mac.local:8765")!, token: nil, timeZone: pacific)
    #expect(request.url?.path == "/api/health/samples")
    let json = try JSONSerialization.jsonObject(with: body) as! [String: [String: [[Any]]]]
    #expect(json["samples"]?["hr"]?[0][0] as? String == "2026-10-26T13:35:00-07:00")
    #expect(json["samples"]?["sleep"]?[0][1] as? String == "2026-10-26T14:35:00-07:00")
    #expect(json["samples"]?["hr"]?[0][2] as? Double == 61)
}

@Test func pairingPasswordsFollowAudaysRules() {
    for _ in 0..<50 {
        let password = Pairing.newPassword()
        #expect(Pairing.normalize(password) == password)
        #expect(!password.contains { "01IO".contains($0) })
    }
    #expect(Pairing.normalize("abcd-efgh-jkmn-pqrs") == "ABCDEFGHJKMNPQRS")
    #expect(Pairing.normalize("AAAA-AAAA-AAAA-AAAA") == nil)   // fewer than 4 different characters
    #expect(Pairing.normalize("123456") == nil)
    #expect(Pairing.formatted("ABCDEFGHJKMNPQRS") == "ABCD-EFGH-JKMN-PQRS")
    #expect(Pairing.pskKey("abcd efgh jkmn pqrs") == Pairing.pskKey("ABCD-EFGH-JKMN-PQRS"))
    #expect(Pairing.pskKey("ABCD-EFGH-JKMN-PQRS")?.count == 32)
}

@Test func pairingFramesRoundTrip() {
    let data = Pairing.frame(["op": "pair", "port": 8765])
    #expect(data.prefix(4) == Data([0, 0, 0, UInt8(data.count - 4)]))
    let back = Pairing.object(inFrame: data)
    #expect(back?["op"] as? String == "pair")
    #expect(back?["port"] as? Int == 8765)
    #expect(Pairing.object(inFrame: data.dropLast()) == nil)
}

// Values from the Mac's app/speaker.fbank on the same signal, so both sides make the same features.
@Test func voiceFeaturesMatchTheMac() throws {
    let x: [Float] = (0..<8000).map { i in
        let t = Double(i) / 16000
        return Float(0.3 * sin(2 * .pi * 440 * t) + 0.1 * sin(2 * .pi * 1234 * t) + 0.05 * sin(2 * .pi * 97 * t * t * 40))
    }
    let f = try #require(Voice.fbank(x))
    #expect(f.count == 48 && f[0].count == 80)
    let expected: [(Int, Int, Float)] = [(0, 0, 6.4591), (0, 10, -0.2239), (0, 40, -1.9879), (0, 79, 0.3768), (20, 5, -0.4326), (47, 60, 14.6498)]
    for (r, c, v) in expected { #expect(abs(f[r][c] - v) < 0.01, "fbank[\(r)][\(c)] = \(f[r][c]), Mac \(v)") }
    #expect(Voice.voiced([Float](repeating: 0, count: 1600) + x).count == 8000)
}

@Test func voiceLabelsFollowTheMacRules() {
    #expect(Voice.label(whole: 0.5, best: 0.5, seconds: 2.9) == nil)          // too short
    #expect(Voice.label(whole: 0.43, best: 0.2, seconds: 4) == "Me")
    #expect(Voice.label(whole: 0.3, best: 0.40, seconds: 7) == "Me*")
    #expect(Voice.label(whole: 0.3, best: 0.40, seconds: 5) == "Me*")         // phone: Me* from 3 s
    #expect(Voice.label(whole: 0.398, best: 0.38, seconds: 5) == "Me*")       // whole nearly at Me
    #expect(Voice.label(whole: 0.3, best: 0.38, seconds: 5) == nil)
    #expect(Voice.calibrate(Array(repeating: (0.3, 0.3), count: 49)) == nil)
    let t = Voice.calibrate((0..<100).map { (Double($0) / 200, Double($0) / 200) })!
    #expect(abs(t.me - 0.55) < 1e-9)                                          // q90 0.45 + 0.10
    #expect(abs(t.mixed - 0.50) < 1e-9)                                       // q90 0.45 + 0.05
}

// Values from a numpy front end that decodes the sherpa-onnx test clips like sherpa-onnx itself
// (Hamming-window Kaldi fbank, 7-of-6 frame stacking), on the same signal.
@Test func senseVoiceFeaturesMatchTheMac() {
    let x: [Float] = (0..<16000).map { i in
        let t = Double(i) / 16000
        return Float(0.3 * sin(2 * .pi * 440 * t) + 0.1 * sin(2 * .pi * 1234 * t) + 0.05 * sin(2 * .pi * 97 * t * t * 40))
    }
    let (f, frames) = SenseVoice.features(x, negMean: [Float](repeating: 0, count: 560), invStd: [Float](repeating: 1, count: 560))
    #expect(frames == 16 && f.count == 16 * 560)
    let expected: [(Int, Int, Float)] = [(0, 0, 15.6038), (0, 85, 18.0878), (3, 300, 10.6751), (10, 559, 9.7925), (15, 42, 8.8669)]
    for (r, c, v) in expected { #expect(abs(f[r * 560 + c] - v) < 0.01, "features[\(r)][\(c)] = \(f[r * 560 + c]), Mac \(v)") }
}

// Same probabilities through faster-whisper's get_speech_timestamps (threshold 0.35, 1000 ms, 400 ms pad).
@Test func senseVoiceSpeechPiecesMatchTheMac() {
    let probs: [Float] = Array(repeating: 0.1, count: 20) + Array(repeating: 0.9, count: 40) + Array(repeating: 0.1, count: 10)
        + Array(repeating: 0.8, count: 30) + Array(repeating: 0.1, count: 60) + Array(repeating: 0.6, count: 25) + Array(repeating: 0.05, count: 15)
    let pieces = SenseVoice.speech(probabilities: probs, length: 102300)
    #expect(pieces.map { [$0.0, $0.1] } == [[3840, 57600], [75520, 102300]])
}

@Test func senseVoiceDecodesGreedyCTC() {
    let tokens = ["<blank>", "<|zh|>", "<|NEUTRAL|>", "<|Speech|>", "<|withitn|>", "你", "好", "▁ok"]
    let path = [1, 2, 3, 4, 5, 5, 0, 6, 6, 7]
    var logits = [Float](repeating: 0, count: path.count * tokens.count)
    for (t, id) in path.enumerated() { logits[t * tokens.count + id] = 5 }
    let r = SenseVoice.decode(logits, frames: path.count, vocab: tokens.count, tokens: tokens)
    #expect(r.text == "你好 ok" && r.language == "<|zh|>" && r.emotion == "<|NEUTRAL|>" && r.event == "<|Speech|>")
    #expect(SenseVoice.snippets([(0, 16000 * 20)]).map { $0.1 - $0.0 } == [16000 * 15, 16000 * 5])
    #expect(SenseVoice.snippets([(0, 16000 * 4), (16000 * 6, 16000 * 9)]).count == 1)
    #expect(!SenseVoice.keeps("。") && SenseVoice.keeps("好"))
}

@Test func whisperTextKeepsSpeechOnly() {
    #expect(WhisperText.clean("[MUSIC] (painting) [MUSIC]") == nil)
    #expect(WhisperText.clean("[BLANK_AUDIO]") == nil)
    #expect(WhisperText.clean("[ [ Thank you. [wind blowing]", doubtsSpeech: true) == nil)
    #expect(WhisperText.clean(" Thank you.") == "Thank you.")
    #expect(WhisperText.clean("Thanks for watching!") == nil)
    #expect(WhisperText.clean("♪ ♪") == nil)
    #expect(WhisperText.clean("(door opens) Hi, come in [MUSIC]") == "Hi, come in")
    #expect(WhisperText.clean("我们明天去牙医那里（笑）") == "我们明天去牙医那里")
    #expect(WhisperText.clean("එරට්ාියනේ ජවාර්ව පිරිස්සම") == nil)
    #expect(WhisperText.clean("ლ ლ") == nil)
    #expect(WhisperText.clean("ラテ、甘いね。라떼 좋아요 café") == "ラテ、甘いね。라떼 좋아요 café")
}

@Test func locationContextCutsAtTheGridAndNamesByMajority() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let t0 = Date(timeIntervalSince1970: Double(1_793_000_000 - 1_793_000_000 % 3600 + 7 * 60))   // hh:07:00
    let samples = (0..<4).map { PlaceSample(time: t0.addingTimeInterval(Double($0) * 120), latitude: 1, longitude: 2,
                                            accuracy: 10, name: $0 == 3 ? "Park · Main St" : "Home · Elm St") }
    let labels = LocationContext.labels(samples, start: t0.addingTimeInterval(-420), end: t0.addingTimeInterval(3180), calendar: utc)
    // 07:00–10:00 (to the 5-minute grid), 10:00–14:00 (the last sample at 13:00 counts one minute)
    #expect(labels.map { $0.end.timeIntervalSince($0.start) } == [180, 240])
    #expect(labels[0].name == "Home · Elm St")
    #expect(labels[0].confidence == "medium")
    let lone = LocationContext.labels([samples[0]], start: t0.addingTimeInterval(-420), end: t0.addingTimeInterval(3180), calendar: utc)
    #expect(lone.count == 1 && lone[0].confidence == "low")
}

@Test func placesAreNamedOnlyWhenTheyArePlaces() {
    #expect(PlaceNaming.placeLabel(name: "100 Main St", addressLine: "100 Main St", isPlace: false) == nil)
    #expect(PlaceNaming.placeLabel(name: "2200 Oak Ave", addressLine: "2200 Oak Ave", isPlace: false) == nil)
    #expect(PlaceNaming.placeLabel(name: "City University", addressLine: "450 College Way", isPlace: true)
            == "City University · College Way")
    #expect(PlaceNaming.placeLabel(name: "Riverside Market", addressLine: "1200 River Rd", isPlace: false) == "Riverside Market · River Rd")
    #expect(PlaceNaming.placeLabel(name: nil, addressLine: "12 Elm St", isPlace: false) == nil)
}

@Test func stutteredEnglishWordsAreRepaired() {
    let words: Set = ["transcription", "test", "coffee", "letter"]
    let isWord = { words.contains($0) }
    #expect(Stutter.fix("我要尝试一下这个这个transranscription。", isWord: isWord) == "我要尝试一下这个这个transcription。")
    #expect(Stutter.fix("这个transscription", isWord: isWord) == "这个transcription")
    #expect(Stutter.fix("Transranscription works", isWord: isWord) == "Transcription works")
    #expect(Stutter.fix("a letter about Niangao", isWord: isWord) == "a letter about Niangao")   // real word and a name stay
    #expect(Stutter.fix("Mississippi", isWord: isWord) == "Mississippi")                         // no word left by a repair
}

// Body context must match app/health.py. The expected rows below are the Python output for the
// same samples (a sedentary elevated run with stress, a calm run, a walk with a high heart rate).
@Test func bodyContextMatchesTheMac() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
    func t(_ hm: String) -> Date {
        let p = hm.split(separator: ":").map { Int($0)! }
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: p[0], minute: p[1]))!
    }
    func point(_ hm: String, _ v: Double) -> HealthSample { HealthSample(start: t(hm), end: t(hm), value: v) }
    let samples: Body.Samples = [
        "rest": [point("00:00", 60)],
        "effort": [HealthSample(start: t("10:00"), end: t("11:00"), value: 1.5)],
        "hr": [("10:00", 70), ("10:02", 80), ("10:03", 82), ("10:05", 85), ("10:20", 70), ("10:30", 55), ("10:32", 54),
               ("10:34", 53), ("10:50", 70), ("12:02", 100), ("12:04", 101)].map { point($0.0, Double($0.1)) },
        "steps": [HealthSample(start: t("12:00"), end: t("12:05"), value: 600),
                  HealthSample(start: t("12:07"), end: t("12:10"), value: 300)],
        "hrv": [point("10:04", 30)],
    ]
    let hm = { (d: Date) -> String in
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }
    let got = Body.context(samples, calendar: calendar).map {
        "\($0.kind) \(hm($0.start)) \(hm($0.end)) \(hm($0.observedStart)) \(hm($0.observedEnd)) \($0.confidence) \($0.motionContext ?? "-")"
    }
    #expect(got == [
        "heartRateElevated 10:02 10:10 10:02 10:05 low sedentary",
        "stressElevated 10:03 10:10 10:02 10:05 low -",
        "stressLow 10:32 10:39 10:30 10:34 low -",
        "walking 12:00 12:10 12:00 12:10 low -",     // its raised heart rate (12:02–12:09) is part of the walk
    ])
    let stats = Body.statistics(samples, from: t("10:00"), to: t("11:00"))
    #expect(stats.map(\.metric) == ["heartRate", "hrvSDNN"])
    #expect(abs(stats[0].average - 68.778) < 0.001 && stats[0].minimum == 53 && stats[0].maximum == 85 && stats[0].sampleCount == 9)
    #expect(Body.within(Body.context(samples, calendar: calendar), from: t("10:05"), to: t("10:35")).map(\.kind)
            == ["heartRateElevated", "stressElevated", "stressLow"])
}

@Test func contextExtendsTheOwnersConversation() {
    // Me at 0 s; a 0.35 line 60 s later joins, and through it a 0.31 line 140 s in; a 0.32 line far
    // away, a 2 s line and a 0.10 line stay unlabelled.
    let got = Voice.extendByContext([
        (0, 5, 0.50, "Me"), (60, 5, 0.35, nil), (140, 4, 0.31, nil), (600, 5, 0.32, nil),
        (20, 2, 0.40, nil), (30, 5, 0.10, nil),
    ])
    #expect(got == ["Me", "Me*", "Me*", nil, nil, nil])
}
