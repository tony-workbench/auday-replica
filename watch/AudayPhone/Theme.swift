import SwiftUI
import UIKit

/// Auday's look (docs/AUDAY_UI.md; the same tokens as app/static/style.css): warm light
/// background, serif headings, rounded cards, a dark mode.
enum Theme {
    static let bg = dynamic(0xF8F8F6, 0x131210)
    static let panel = dynamic(0xF0EFEC, 0x1E1D1A)
    static let panel2 = dynamic(0xE6E5E1, 0x282622)
    static let raised = dynamic(0xFFFFFF, 0x24221F)
    static let line = dynamic(0xE3E2DE, 0x2F2D29)
    static let text = dynamic(0x171614, 0xEFECE6)
    static let muted = dynamic(0x6F6B64, 0xA29D94)
    static let faint = dynamic(0xA19C93, 0x6F6A62)
    static let ink = dynamic(0x171614, 0xEFECE6)
    /// The light green behind "Me:" / "Me*:" in a transcript.
    static let meHighlight = dynamic(0xE3EDDF, 0x2C3A2A)
    static let onInk = dynamic(0xF6F4EF, 0x131210)
    static let night = dynamic(0x1B1A18, 0x23211E)
    static let nightText = Color(hex: 0xF2EFE8)
    static let nightMuted = Color(hex: 0xA8A399)
    static let red = dynamic(0xE5483B, 0xFF5F50)
    static let warn = dynamic(0xB07A1F, 0xE2A947)
    static let accentSoft = dynamic(0xF6E3DC, 0x3A231E)

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(UIColor(hex: hex)) }
}

/// "TODAY", "DAILY REFLECTION": small, spaced capitals.
struct Eyebrow: View {
    let text: String
    var color = Theme.muted
    init(_ text: String, color: Color = Theme.muted) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(1.4).foregroundStyle(color)
    }
}

/// The round 40 pt buttons of the top bar.
struct RoundIcon: View {
    let systemName: String
    var dot = false
    var tint = Theme.text
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(Theme.raised, in: Circle())
                .overlay(Circle().stroke(Theme.line))
            if dot {
                Circle().fill(Theme.red).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Theme.raised, lineWidth: 2)).offset(x: -5, y: 5)
            }
        }
    }
}

/// Auday's waveform mark: five rounded bars.
struct AudayLogo: View {
    var size: CGFloat = 22
    var body: some View {
        HStack(alignment: .center, spacing: size * 0.12) {
            ForEach([0.45, 0.8, 1.0, 0.65, 0.4], id: \.self) { h in
                Capsule().frame(width: size * 0.11, height: size * h)
            }
        }
        .frame(width: size, height: size)
    }
}

struct Chip: View {
    let text: String
    var accent = false
    var body: some View {
        Text(text).font(.system(size: 12.5)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .foregroundStyle(accent ? Theme.red : Theme.muted)
            .background(accent ? Theme.accentSoft : Theme.panel2, in: Capsule())
    }
}

/// A Highlight's context chip: Conversation, place, heart rate, stress, walk.
struct SignalChip: View {
    let signal: Signal
    var body: some View {
        let alert = signal.kind == .stress
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(signal.label).lineLimit(1)
        }
        .font(.system(size: 15))
        .padding(.horizontal, 11).padding(.vertical, 5)
        .foregroundStyle(alert ? Color(hex: 0x9A4A44) : Theme.muted)
        .background(alert ? Color(hex: 0xF3E1DF) : Theme.panel, in: Capsule())
    }

    private var icon: String {
        switch signal.kind {
        case .conversation: "text.alignleft"
        case .place: "mappin"
        case .heart: "heart"
        case .stress: "waveform"
        case .walk: "figure.walk"
        case .other: "circle"
        }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Auday's grey "card" surfaces and the white ones used for Highlights.
extension View {
    func card(_ color: Color = Theme.raised, radius: CGFloat = 20) -> some View {
        background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Seeded 1-bit "dither" artwork like Auday's reflection covers: smooth noise (or, with `wave`,
/// a shaded ribbon across the frame) through 4×4 ordered dithering.
struct DitherArt: View {
    let seed: UInt64
    var color = Theme.nightText
    var wave = false

    var body: some View {
        Canvas { context, size in
            var x = seed == 0 ? 1 : seed
            func rand() -> Double {
                x ^= x << 13; x ^= x >> 7; x ^= x << 17
                return Double(x % 10000) / 10000
            }
            let px = max(3, (size.width / 170).rounded())
            let waves = (0..<4).map { _ in (rand() * 0.04 + 0.006, rand() * 0.05 + 0.008, rand() * 6.28, rand()) }
            let phase = rand() * 6.28, tilt = rand() * 0.6 - 0.3, freq = 1.6 + rand() * 1.4
            let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
            var path = Path()
            let cols = Int(size.width / px), rows = Int(size.height / px)
            for j in 0..<rows {
                for i in 0..<cols {
                    var v: Double
                    if wave {
                        // A ribbon: distance from a wavy centre line, thicker in the middle, with folds.
                        let u = Double(i) / Double(cols), w = Double(j) / Double(rows)
                        let centre = 0.55 + 0.22 * sin(u * freq * .pi + phase) + tilt * (u - 0.5)
                        let thickness = 0.16 + 0.1 * sin(u * .pi)
                        let d = abs(w - centre) / thickness
                        let fold = 0.5 + 0.5 * sin(u * 38 + w * 9 + phase)
                        v = max(0, 1 - d * d) * (0.55 + 0.45 * fold)
                    } else {
                        var sum = 0.0, total = 0.0
                        for (fx, fy, ph, amp) in waves {
                            sum += (amp + 0.3) * sin(Double(i) * fx * px + Double(j) * fy * px + ph)
                            total += amp + 0.3
                        }
                        v = 0.5 + 0.5 * sum / total
                        v = v * v * (3 - 2 * v)
                    }
                    if v > (bayer[j % 4][i % 4] + 0.5) / 16 {
                        path.addRect(CGRect(x: Double(i) * px, y: Double(j) * px, width: px - 1, height: px - 1))
                    }
                }
            }
            context.fill(path, with: .color(color))
        }
    }

    static func seed(_ text: String) -> UInt64 {
        text.unicodeScalars.reduce(UInt64(7)) { ($0 &* 131 &+ UInt64($1.value)) % (1 << 60) }
    }
}

enum Format {
    /// 4s, 50m, 1h 0m — as on Auday's hour list.
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(Int((Double(s) / 60).rounded()))m" }
        return "\(s / 3600)h \(Int((Double(s % 3600) / 60).rounded()))m"
    }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : many ?? one + "s")"
    }

    static func hour(_ h: Int) -> String { String(format: "%02d:00", h % 24) }

    /// "yyyy-MM-dd" in the phone's current time zone; remade when the time zone changes (travel).
    static var ymd: DateFormatter {
        if let f = cachedYMD, f.timeZone == TimeZone.current { return f }
        let f = DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        f.calendar = calendar
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        cachedYMD = f
        return f
    }
    nonisolated(unsafe) private static var cachedYMD: DateFormatter?

    /// "Oct 26, 16:08"
    static func when(_ date: Date) -> String { english("MMM d, HH:mm", date) }

    static func english(_ format: String, _ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = .current
        f.dateFormat = format
        return f.string(from: date)
    }
}
