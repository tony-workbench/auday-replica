import AVFoundation
import SwiftUI

enum Page: Hashable {
    case hour(String, Int)
    case reflection(String)
    case memory
}

/// Pushed pages share one destination table, so Days, Chat and Search reach them the same way.
struct PageDestination: View {
    let page: Page
    let log: DayLog
    let store: LocalStore
    let transcriber: LocalTranscriber

    var body: some View {
        switch page {
        case .hour(let date, let hour): HourView(date: date, hour: hour, log: log, store: store, transcriber: transcriber)
        case .reflection(let date): ReflectionView(date: date, log: log, store: store)
        case .memory: MemoryView(store: store)
        }
    }
}

// MARK: - Highlight card

/// A Highlight as on Auday's hour and reflection pages: time range in mono, serif title, the
/// reading, context chips, and "Open this hour".
struct HighlightCard: View {
    let highlight: Highlight
    var fullReading = false
    var openHour: (() -> Void)?
    var play: (() -> Void)?
    /// Auday's "Original transcript ›": the lines this Highlight was read from.
    var originalTranscript: (() -> Void)?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("✦  \(Format.english("HH:mm:ss", highlight.start))–\(Format.english("HH:mm:ss", highlight.end))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                Spacer()
                if let play {
                    Button(action: play) {
                        Image(systemName: "play.fill").font(.system(size: 9))
                            .frame(width: 26, height: 26).overlay(Circle().stroke(Theme.muted, lineWidth: 1.2))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).accessibilityLabel("Play")
                }
            }
            Text(highlight.title).font(Theme.serif(fullReading ? 34 : 28, .regular)).lineSpacing(2)
            if !fullReading {
                Text(highlight.reading).font(.system(size: 18)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            if highlight.signals.contains(where: { $0.kind != .conversation }) || highlight.marked {   // Auday shows body and place signals, not Conversation
                FlowLayout(spacing: 8) {
                    ForEach(highlight.signals.filter { $0.kind != .conversation }, id: \.self) { SignalChip(signal: $0) }
                    if highlight.marked { SignalChip(signal: Signal(kind: .other, label: "Marked")) }
                }
            }
            if fullReading {
                Text(highlight.reading).font(.system(size: 21)).foregroundStyle(Theme.muted).lineSpacing(4)
                    .lineLimit(expanded ? nil : 6)
                if highlight.reading.count > 200 {       // Auday folds a long reading: "Show more ⌄"
                    Button { withAnimation { expanded.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? "Show less" : "Show more")
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                        }
                        .font(.system(size: 19)).foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                }
                if let originalTranscript {
                    Divider()
                    Button(action: originalTranscript) {
                        HStack(spacing: 10) {
                            Image(systemName: "text.quote")
                            Text("Original transcript")
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        }
                        .font(.system(size: 19)).foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let openHour {
                Button(action: openHour) {
                    HStack(spacing: 4) { Text("Open this hour"); Image(systemName: "arrow.up.right").font(.system(size: 10)) }
                        .font(.system(size: 19)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .card()
    }
}

// MARK: - Daily Reflection

struct ReflectionView: View {
    let date: String
    let log: DayLog
    let store: LocalStore
    @Environment(\.navigate) private var navigate
    private var pipeline: Pipeline { AppDelegate.pipeline }

    var body: some View {
        let r = store.reflection(date)
        let highlights = store.highlights(date)
        let recorded = ReplicaClient.local(date, log: log).recordedSeconds
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let r {
                    ReflectionCard(reflection: .init(id: "reflection-\(date)", title: r.title, highlights: highlights.count),
                                   recorded: recorded, full: true)
                        .padding(.top, 8)
                    heading("Summary")
                    Text(r.summary).font(.system(size: 21)).lineSpacing(5)
                    heading("Reflection")
                    Text(r.text).font(.system(size: 21)).lineSpacing(5)
                    heading("Daily Memory")
                    Text("Review and edit today’s\nselected memories.").font(.system(size: 17)).foregroundStyle(Theme.muted)
                        .padding(.bottom, 16)
                    let memories = r.memoryIDs.compactMap { id in store.contents.memories.first { $0.id == id } }
                    VStack(spacing: 12) {
                        ForEach(Array(memories.enumerated()), id: \.element.id) { i, m in
                            Button { navigate(.memory) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(String(format: "%02d", i + 1)).font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.muted)
                                        .padding(.top, 2)
                                    Text(m.content).font(.system(size: 20)).multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.right").font(.system(size: 14)).foregroundStyle(Theme.muted)
                                }
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading).card(Theme.panel, radius: 14)
                            }
                            .buttonStyle(.plain)
                        }
                        if memories.isEmpty { Text("No memories were selected this day.").foregroundStyle(Theme.muted) }
                    }
                } else {
                    Text("No reflection for \(Format.english("MMM d", Format.ymd.date(from: date) ?? Date())) yet.")
                        .font(Theme.serif(26, .regular)).padding(.top, 30)
                    // No manual generation: Auday writes the reflection after the Reflection Time.
                    Text(AIConfig.configured
                         ? "Auday writes it after your Reflection Time (\(Format.english("HH:mm", AIConfig.reflectionTime)))."
                         : "Auday writes it after your Reflection Time once your AI is set up in Settings › AI settings.")
                        .foregroundStyle(Theme.muted).padding(.top, 8)
                    progress.padding(.top, 12)
                }
                HStack(alignment: .firstTextBaseline) {
                    heading("Highlights")
                    Spacer()
                    Text(Format.plural(highlights.count, "highlight")).font(.system(size: 17)).foregroundStyle(Theme.muted)
                }
                VStack(spacing: 16) {
                    ForEach(highlights) { h in
                        HighlightCard(highlight: h, openHour: { navigate(.hour(date, Calendar.current.component(.hour, from: h.start))) })
                    }
                }
                if let r {
                    Text("Updated \(Format.english("MMM d · HH:mm", r.updatedAt))").font(.system(size: 17)).foregroundStyle(Theme.muted)
                        .padding(.top, 36)
                    // Generated once, so no "Generate again". A resumed run only shows its progress.
                    progress.padding(.top, 12)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 60)
        }
        .background(Theme.bg)
        .navigationTitle("Daily Reflection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let r {
                ToolbarItem(placement: .topBarTrailing) {
                    // Auday exports the reflection as one long picture; the text stays available too.
                    Menu {
                        if let poster {
                            ShareLink(item: Image(uiImage: poster), preview: SharePreview(r.title, image: Image(uiImage: poster))) {
                                Label("Share as image", systemImage: "photo")
                            }
                        }
                        ShareLink(item: "\(r.title)\n\n\(r.summary)\n\n\(r.text)") { Label("Share as text", systemImage: "text.alignleft") }
                    } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .task(id: r?.updatedAt) { poster = r.flatMap { renderPoster($0, highlights: highlights, recorded: recorded) } }
    }

    @State private var poster: UIImage?

    /// The whole reflection as one tall picture (light theme, phone width, 3x).
    private func renderPoster(_ r: Reflection, highlights: [Highlight], recorded: Double) -> UIImage? {
        let memories = r.memoryIDs.compactMap { id in store.contents.memories.first { $0.id == id } }
        let renderer = ImageRenderer(content: ReflectionPoster(date: date, reflection: r, highlights: highlights,
                                                               memories: memories, recorded: recorded)
            .frame(width: 390).environment(\.colorScheme, .light))
        renderer.scale = 3
        return renderer.uiImage
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(Theme.serif(32, .regular)).padding(.top, 34).padding(.bottom, 12)
    }

    /// The automatic run's progress, or a real problem from it.
    @ViewBuilder private var progress: some View {
        if pipeline.busy {
            HStack(spacing: 10) {
                ProgressView()
                Text(pipeline.status ?? "Writing the reflection…")
            }
            .font(.system(size: 17)).foregroundStyle(Theme.muted)
        } else if let problem = pipeline.problem {
            Text(problem).font(.system(size: 14)).foregroundStyle(Theme.red)
        }
    }
}

/// The daily reflection laid out for export as one long image.
struct ReflectionPoster: View {
    let date: String
    let reflection: Reflection
    let highlights: [Highlight]
    let memories: [Memory]
    let recorded: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AudayLogo(size: 18)
                Text("Auday").font(Theme.serif(22, .regular))
                Spacer()
                Text(Format.english("EEEE, MMM d, yyyy", Format.ymd.date(from: date) ?? Date()))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ReflectionCard(reflection: .init(id: "poster-\(date)", title: reflection.title, highlights: highlights.count),
                           recorded: recorded, full: true)
                .padding(.top, 18)
            section("Summary")
            Text(reflection.summary).font(.system(size: 17)).lineSpacing(4)
            section("Reflection")
            Text(reflection.text).font(.system(size: 17)).lineSpacing(4)
            if !highlights.isEmpty {
                section("Highlights")
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(highlights) { h in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("✦  " + Format.english("HH:mm", h.start)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                            Text(h.title).font(Theme.serif(19, .regular))
                        }
                    }
                }
            }
            if !memories.isEmpty {
                section("Daily Memory")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(memories.enumerated()), id: \.element.id) { i, m in
                        HStack(alignment: .top, spacing: 10) {
                            Text(String(format: "%02d", i + 1)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.muted)
                            Text(m.content).font(.system(size: 16))
                        }
                    }
                }
            }
            Text("Recorded with Auday Replica · stored on your device")
                .font(.system(size: 11)).foregroundStyle(Theme.faint).padding(.top, 34)
        }
        .padding(24)
        .background(Theme.bg)
    }

    private func section(_ text: String) -> some View {
        Text(text).font(Theme.serif(26, .regular)).padding(.top, 28).padding(.bottom, 10)
    }
}

// MARK: - Hour

/// An hour, laid out like Auday's: "ONE HOUR OF YOUR DAY", the hour in serif, how much was
/// recorded, then Transcript / Highlights / Summary tabs and the floating "Saved audio" player.
struct HourView: View {
    let date: String
    let hour: Int
    let log: DayLog
    let store: LocalStore
    let transcriber: LocalTranscriber
    @State private var player = HourPlayer()
    @State private var tab = Tab.transcript
    @State private var refreshing = false
    @State private var original: Highlight?
    @State private var audioFile: URL?

    enum Tab: String, CaseIterable { case transcript = "Transcript", highlights = "Highlights", summary = "Summary" }

    var body: some View {
        let day = Format.ymd.date(from: date) ?? Date()
        let entries = log.entries(on: day).filter { Calendar.current.component(.hour, from: $0.start) == hour }
        let recordings = entries.filter { !$0.mark }
        let summary = store.summary(date, hour)
        let highlights = store.highlights(date, hour: hour)
        let seconds = recordings.reduce(0) { $0 + $1.duration }
        let hasAudio = recordings.contains { FileManager.default.fileExists(atPath: DayLog.audioURL(for: $0).path) }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("One hour of your day").padding(.top, 8)
                Text("\(Format.hour(hour))–\(Format.hour(hour + 1))").font(Theme.serif(40, .regular))
                Text(recordings.isEmpty ? "Nothing captured" : "\(Format.duration(seconds)) · \(hasAudio ? "Audio preserved" : "Audio not kept")")
                    .font(.system(size: 19)).foregroundStyle(Theme.muted)
                HStack(spacing: 0) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Button { tab = t } label: {
                            VStack(spacing: 10) {
                                Text(t.rawValue).font(.system(size: 22, weight: tab == t ? .semibold : .regular))
                                    .foregroundStyle(tab == t ? Theme.text : Theme.faint)
                                Rectangle().fill(tab == t ? Theme.text : .clear).frame(height: 2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                .sensoryFeedback(.selection, trigger: tab)
                switch tab {
                case .transcript:
                    let marks = entries.filter(\.mark)
                    if !marks.isEmpty {     // Replica improvement: the moments you marked
                        Text("👉 " + marks.map { clock($0.start) }.joined(separator: " · "))
                            .font(.system(size: 15)).foregroundStyle(Theme.muted)
                    }
                    // Auday puts the hour's place above the transcript (📍 Place · Street).
                    if PhoneLink.locationData, let start = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) {
                        let names = AppDelegate.places.labels(from: start, to: start.addingTimeInterval(3600)).compactMap(\.name)
                        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                        if !unique.isEmpty {
                            Label(unique.joined(separator: " · "), systemImage: "mappin")
                                .font(.system(size: 17)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    if recordings.isEmpty {
                        Text("Nothing captured.").font(.system(size: 18)).foregroundStyle(Theme.muted)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(recordings, id: \.id) { entry in transcript(entry) }
                        }
                        .padding(.top, 6)
                    }
                case .highlights:
                    if highlights.isEmpty {
                        Text(AIConfig.configured ? "No Highlights in this hour." : "Add your AI in Settings › AI settings to get Highlights.")
                            .font(.system(size: 18)).foregroundStyle(Theme.muted)
                    }
                    ForEach(highlights) { h in
                        HighlightCard(highlight: h, fullReading: true, play: { player.play(entries: recordings, from: h.start) },
                                      originalTranscript: { original = h })
                    }
                case .summary:
                    if let summary {
                        Text(summary.title).font(Theme.serif(28, .regular)).lineSpacing(2)
                        if !summary.text.isEmpty { Text(summary.text).font(.system(size: 19)).foregroundStyle(Theme.muted).lineSpacing(3) }
                        let density = DayHour(hour: hour, density: summary.density).densityLabel
                        if let density { Chip(text: density) }
                        if let attention = summary.attention, !attention.isEmpty {
                            Text("Things to note").font(Theme.serif(24, .regular)).padding(.top, 10)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(attention, id: \.self) { Text("·  " + $0).font(.system(size: 18)) }
                            }
                        }
                        if let updated = summary.updated {
                            Text("Updated " + Format.english("MMM d · HH:mm", updated))
                                .font(.system(size: 16)).foregroundStyle(Theme.muted).padding(.top, 6)
                        }
                        Divider().padding(.vertical, 8)
                        NavigationLink(value: Page.memory) {
                            HStack {
                                Text("Daily memory\ncandidates").font(Theme.serif(24, .regular)).multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(AIConfig.configured ? "This hour is summarized after it ends." : "Add your AI in Settings › AI settings to get a summary.")
                            .font(.system(size: 18)).foregroundStyle(Theme.muted)
                    }
                    if !recordings.isEmpty {
                        Button {
                            refreshing = true
                            Task { try? await AppDelegate.pipeline.summarize(date, hour); refreshing = false }
                        } label: {
                            HStack {
                                Text(refreshing ? "Refreshing Highlights & Summary…" : "Refresh Highlights & Summary")
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "sparkle")
                            }
                            .font(.system(size: 17)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 50)
                            .background(Theme.faint, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain).disabled(refreshing || !AIConfig.configured).padding(.top, 8)
                        Text("AI features use your chosen provider. These AI features use text, not audio.")
                            .font(.system(size: 16)).foregroundStyle(Theme.muted)
                        Divider().padding(.vertical, 8)
                        Text("Use your current transcription model to replace this hour’s transcript and refresh Highlights and Summary.")
                            .font(.system(size: 16)).foregroundStyle(Theme.muted)
                        Button {
                            log.retranscribe(recordings.map(\.id))
                            Task { await transcriber.run(force: true) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.clockwise")
                                Text("Transcribe again")
                                Spacer()
                                // Replica improvement: the mode it will use.
                                Text(LocalTranscriber.mode == .accurate ? "Local accurate" : "Local efficient")
                                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                            }
                            .font(.system(size: 18))
                            .padding(.horizontal, 16).frame(height: 50)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain).disabled(transcriber.busy)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, recordings.isEmpty ? 40 : 190)
        }
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            if !recordings.isEmpty { AudioBar(player: player, hour: hour, entries: recordings).padding(.horizontal, 16) }
        }
        .navigationTitle(Format.english("MMM d, yyyy", day))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Auday exports an hour's Notes and Audio as separate files.
                Menu {
                    if let url = HourExport.notes(date: date, hour: hour, summary: summary, highlights: highlights, entries: recordings) {
                        ShareLink(item: url) { Label("Export Notes", systemImage: "doc.text") }
                    }
                    if let audioFile {
                        ShareLink(item: audioFile) { Label("Export Audio", systemImage: "waveform") }
                    } else if hasAudio {
                        Label("Preparing audio…", systemImage: "hourglass")
                    }
                } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onDisappear { player.stop() }
        .task(id: recordings.map(\.id)) { audioFile = await HourExport.audio(date: date, hour: hour, entries: recordings) }
        .sheet(item: $original) { h in originalSheet(h, entries: recordings) }
    }

    /// The transcript lines a Highlight covers, as Auday's "Original transcript".
    private func originalSheet(_ h: Highlight, entries: [DayLog.Entry]) -> some View {
        let lines = entries.flatMap { e in (e.segments ?? []).map { (e, $0, e.start.addingTimeInterval($0.start)) } }
            .filter { $0.2 >= h.start.addingTimeInterval(-1) && $0.2 <= h.end }
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(h.title).font(Theme.serif(26, .regular)).padding(.bottom, 4)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, item in
                        Button { player.play(entries: [item.0], from: item.2) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(clock(item.2)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.faint)
                                    .frame(width: 44, alignment: .leading)
                                speech(item.1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("Original transcript").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { original = nil } } }
        }
    }

    /// Minutes and seconds into the hour, as Auday prints them (45:21).
    private func clock(_ date: Date) -> String {
        let s = Int(date.timeIntervalSince(Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    @ViewBuilder private func transcript(_ entry: DayLog.Entry) -> some View {
        switch entry.status ?? .waiting {
        case .done:
            ForEach(Array((entry.segments ?? []).enumerated()), id: \.offset) { _, seg in
                let at = entry.start.addingTimeInterval(seg.start)
                Button { player.play(entries: [entry], from: at) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(clock(at)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.faint).frame(width: 44, alignment: .leading)
                        speech(seg)
                    }
                }
                .buttonStyle(.plain)
            }
        case .silent:
            EmptyView()                 // Auday leaves quiet stretches out of the transcript
        case .failed where entry.failure == LocalTranscriber.TranscriptionError.unreadable.errorDescription:
            EmptyView()                 // nothing to read in it; Recent transcriptions still lists it
        case .failed:
            line(entry, entry.failure ?? "Could not transcribe.")
        case .waiting:
            line(entry, transcriber.busy ? "Transcribing…" : "Waiting for transcription.")
        }
    }

    /// "Me*: text" with the label on a light green highlight, the words in serif.
    private func speech(_ seg: Segment) -> some View {
        var text = AttributedString(seg.text)
        text.font = Theme.serif(21, .regular)
        if let me = seg.me, VoiceModel.enabled {
            var tag = AttributedString(me + ":")
            tag.font = .system(size: 20, weight: .semibold)
            tag.backgroundColor = Theme.meHighlight
            text = tag + AttributedString(" ") + text
        }
        return Text(text).multilineTextAlignment(.leading).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ entry: DayLog.Entry, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(clock(entry.start)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.faint).frame(width: 44, alignment: .leading)
            Text(text).font(.system(size: 18)).foregroundStyle(Theme.muted)
        }
    }
}

/// Plays an hour's recordings in order; positions are minutes into the hour, as on Auday's bar.
@MainActor @Observable
final class HourPlayer {
    private(set) var playing = false
    private(set) var position: Double = 0          // seconds into the hour
    var rate: Float = 1
    private var player: AVQueuePlayer?
    private var starts: [Double] = []
    private var timer: Timer?
    private var hourStart = Date()

    func play(entries: [DayLog.Entry], from: Date? = nil) {
        stop()
        guard let first = entries.first else { return }
        hourStart = Calendar.current.dateInterval(of: .hour, for: first.start)?.start ?? first.start
        let target = from ?? first.start
        let startIndex = entries.lastIndex { $0.start <= target } ?? 0
        let chosen = Array(entries[startIndex...])
        starts = chosen.map { $0.start.timeIntervalSince(hourStart) }
        let items = chosen.map { AVPlayerItem(url: DayLog.audioURL(for: $0)) }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let player = AVQueuePlayer(items: items)
        let offset = max(0, target.timeIntervalSince(chosen[0].start))
        player.seek(to: CMTime(seconds: offset, preferredTimescale: 600))
        player.playImmediately(atRate: rate)
        self.player = player
        playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
    }

    private func tick() {
        guard let player else { return }
        guard let item = player.currentItem else { stop(); return }
        let index = (player.items().count > 0) ? starts.count - player.items().count : 0
        position = (starts.indices.contains(index) ? starts[index] : 0) + item.currentTime().seconds
        playing = player.rate > 0
    }

    func toggle(entries: [DayLog.Entry]) {
        if let player, playing { player.pause(); playing = false }
        else if let player, player.currentItem != nil { player.playImmediately(atRate: rate); playing = true }
        else { play(entries: entries, from: hourStart.addingTimeInterval(position)) }
    }

    func skip(_ seconds: Double, entries: [DayLog.Entry]) {
        let target = hourStart.addingTimeInterval(max(0, position + seconds))
        play(entries: entries, from: target)
    }

    func seek(to seconds: Double, entries: [DayLog.Entry]) {
        if let first = entries.first {
            hourStart = Calendar.current.dateInterval(of: .hour, for: first.start)?.start ?? first.start
        }
        position = seconds
        play(entries: entries, from: hourStart.addingTimeInterval(seconds))
    }

    func cycleRate() {
        rate = rate == 1 ? 1.5 : rate == 1.5 ? 2 : 1
        if playing { player?.rate = rate }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.pause()
        player = nil
        playing = false
    }
}

/// Auday's floating "Saved audio" bar: play, the hour, ±15 s, speed, and a 60-minute scrubber.
struct AudioBar: View {
    let player: HourPlayer
    let hour: Int
    let entries: [DayLog.Entry]
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button { player.toggle(entries: entries) } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 20))
                        .foregroundStyle(Theme.onInk).frame(width: 54, height: 54).background(Theme.ink, in: Circle())
                }
                .accessibilityLabel(player.playing ? "Pause" : "Play")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved audio").font(.system(size: 20, weight: .semibold)).lineLimit(1).fixedSize()
                    Text("\(Format.hour(hour)) – \(Format.hour(hour + 1))").font(.system(size: 17)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer()
                Button { player.skip(-15, entries: entries) } label: { Image(systemName: "gobackward.15").font(.system(size: 22)) }
                    .accessibilityLabel("Back 15 seconds")
                Button { player.skip(15, entries: entries) } label: { Image(systemName: "goforward.15").font(.system(size: 22)) }
                    .accessibilityLabel("Forward 15 seconds")
                Button { player.cycleRate() } label: {
                    Text(player.rate == 1 ? "1×" : player.rate == 1.5 ? "1.5×" : "2×").font(.system(size: 13, weight: .medium))
                }
                .frame(minWidth: 30)
            }
            .buttonStyle(.plain)
            Slider(value: Binding(get: { scrub ?? player.position }, set: { scrub = $0 }), in: 0...3600) { editing in
                if !editing, let value = scrub {
                    player.seek(to: value, entries: entries)
                    scrub = nil
                }
            }
            .tint(Theme.muted)
            HStack {
                Text(clock(scrub ?? player.position))
                Spacer()
                Text("60:00")
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.line))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 6)
        .padding(.bottom, 8)
        .sensoryFeedback(.impact(weight: .light), trigger: player.playing)
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

// MARK: - Your memory

struct MemoryView: View {
    let store: LocalStore
    @State private var tab = Memory.Status.review
    @State private var editing: String?
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("What stays\nwith you.").font(Theme.serif(42, .regular)).lineSpacing(0).padding(.top, 16)
                SegmentedPill(selection: $tab, items: [(.review, "Review"), (.saved, "Saved"), (.inactive, "Inactive")])
                    .padding(.top, 22)
                Text(note).font(.system(size: 20)).foregroundStyle(Theme.muted).padding(.top, 22)
                Divider().padding(.top, 22)
                let list = store.memories(tab)
                if list.isEmpty {
                    Text("Nothing here yet.").font(.system(size: 19)).foregroundStyle(Theme.muted).padding(.top, 24)
                }
                ForEach(list) { m in item(m); Divider() }
            }
            .padding(.horizontal, 24).padding(.bottom, 60)
        }
        .background(Theme.bg)
        .navigationTitle("Your memory")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: tab)
    }

    private var note: String {
        switch tab {
        case .review: "Saved automatically if\nunreviewed for 5 days."
        case .saved: "These memories help Auday AI understand you."
        case .inactive: "These memories are no longer used by AI."
        }
    }

    @ViewBuilder private func item(_ m: Memory) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(meta(m)).font(.system(size: 18)).foregroundStyle(Theme.muted)
            if editing == m.id {
                TextField("Memory", text: $draft, axis: .vertical).font(.system(size: 23))
                    .padding(10).card(Theme.raised, radius: 10)
                HStack(spacing: 22) {
                    Button("Save") {
                        store.editMemory(m.id, content: draft)
                        editing = nil
                    }
                    .font(.system(size: 18, weight: .semibold))
                    Button("Cancel") { editing = nil }.foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            } else {
                Text(m.content).font(.system(size: 23)).lineSpacing(3)
                if m.edited && m.status == .saved { Text("Edited by you.").font(.system(size: 18)).foregroundStyle(Theme.muted) }
                switch m.status {
                case .review:
                    Button("This is about me") { store.setMemory(m.id, status: .saved) }
                        .font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.onInk)
                        .padding(.horizontal, 16).padding(.vertical, 9).background(Theme.ink, in: Capsule())
                        .buttonStyle(.plain)
                    textButton("Edit") { draft = m.content; editing = m.id }
                    textButton("Ignore", muted: true) { store.setMemory(m.id, status: .inactive) }
                case .saved:
                    textButton("Edit") { draft = m.content; editing = m.id }
                    textButton("Deactivate", muted: true) { store.setMemory(m.id, status: .inactive) }
                case .inactive:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 22)
        .sensoryFeedback(.success, trigger: m.status)
    }

    private func textButton(_ title: String, muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action).font(.system(size: 19)).foregroundStyle(muted ? Theme.muted : Theme.text)
            .buttonStyle(.plain).padding(.top, 6)
    }

    private func meta(_ m: Memory) -> String {
        let from = m.sourceDate.flatMap(Format.ymd.date).map { " · From \(Format.english("MMM d", $0))" } ?? ""
        switch m.status {
        case .review: return "Added \(Format.when(m.addedAt))"
        case .saved: return "Saved \(Format.when(m.savedAt ?? m.addedAt))\(from)"
        case .inactive: return "Inactive \(Format.when(m.inactiveAt ?? m.addedAt))\(from)"
        }
    }
}

/// Auday's small segmented control: a grey track with the chosen item on a white pill.
struct SegmentedPill<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(Value, String)]
    @Namespace private var space

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { value, title in
                Button { withAnimation(.snappy(duration: 0.25)) { selection = value } } label: {
                    Text(title).font(.system(size: 14, weight: selection == value ? .semibold : .regular))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background {
                            if selection == value {
                                Capsule().fill(Theme.raised).shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: space)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.panel2, in: Capsule())
    }
}

private struct NavigateKey: EnvironmentKey {
    static let defaultValue: (Page) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Pushes a page on the current tab's navigation stack.
    var navigate: (Page) -> Void {
        get { self[NavigateKey.self] }
        set { self[NavigateKey.self] = newValue }
    }
}
