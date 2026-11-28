import SwiftUI

extension Risk {
    var color: Color {
        switch self {
        case .safe: .green
        case .redownload: .orange
        case .dataLoss: .red
        }
    }
}

extension MemoryPressure {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// Technical card container respecting Light/Dark Mode, Reduce Transparency, and Increase Contrast.
struct TechnicalCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var cornerRadius: CGFloat = 10
    var tint: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fillOpacity: Double = reduceTransparency ? 1.0 : 0.65
        let borderColor = (tint ?? .primary).opacity(contrast == .increased ? 0.24 : (tint == nil ? 0.08 : 0.22))

        content
            .background(
                ZStack {
                    shape.fill(Color(nsColor: .controlBackgroundColor).opacity(fillOpacity))
                    if let tint {
                        shape.fill(tint.opacity(0.045))
                    }
                }
            )
            .overlay(
                shape.strokeBorder(borderColor, lineWidth: 1)
            )
    }
}

struct TechnicalCard<Content: View>: View {
    var cornerRadius: CGFloat = 10
    var tint: Color? = nil
    var padding: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .technicalCard(cornerRadius: cornerRadius, tint: tint)
    }
}

struct SectionHeaderView<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    var tint: Color = .accentColor
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension SectionHeaderView where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String, tint: Color = .accentColor) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint) {
            EmptyView()
        }
    }
}

struct StatusBadge: View {
    @Environment(\.colorSchemeContrast) private var contrast

    let text: String
    var systemImage: String? = nil
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 3.5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8.5, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(
            Capsule()
                .fill(color.opacity(contrast == .increased ? 0.20 : 0.13))
        )
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(contrast == .increased ? 0.40 : 0.22), lineWidth: 0.75)
        )
    }
}

struct MetricPill: View {
    let label: String
    let value: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint == .secondary ? .primary : tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }
}

struct TelemetryStatTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint == .secondary ? .primary : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .technicalCard(cornerRadius: 8)
    }
}

struct ProportionalBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 5

    private var clamped: Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                if clamped > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, proxy.size.width * clamped))
                }
            }
        }
        .frame(height: height)
    }
}

/// One-click button; items that lose data turn into a red "Confirm" on the first click.
struct ActionButton: View {
    var title: String?
    var symbol: String
    var confirm = false
    var busy = false
    var help: String?
    let action: () -> Void

    @State private var armed = false

    var body: some View {
        Button {
            if confirm && !armed {
                armed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { armed = false }
            } else {
                armed = false
                action()
            }
        } label: {
            Group {
                if busy {
                    ProgressView().controlSize(.mini).frame(minWidth: 16)
                } else if armed {
                    Text(tr("action.confirm")).fontWeight(.semibold)
                } else if let title {
                    Label(title, systemImage: symbol)
                } else {
                    Image(systemName: symbol)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(armed ? .red : nil)
        .disabled(busy)
        .help(armed ? tr("action.confirm_help") : (help ?? title ?? ""))
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        StatusBadge(text: text, color: color)
    }
}

struct MeterView: View {
    let title: String
    let fraction: Double
    let caption: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Text(caption).font(.caption.monospacedDigit().weight(.medium))
            }
            ProportionalBar(fraction: fraction, tint: tint, height: 5)
        }
        .frame(maxWidth: .infinity)
    }
}

struct BannerView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

extension View {
    func technicalCard(cornerRadius: CGFloat = 10, tint: Color? = nil) -> some View {
        modifier(TechnicalCardModifier(cornerRadius: cornerRadius, tint: tint))
    }

    func card() -> some View {
        technicalCard()
    }
}
