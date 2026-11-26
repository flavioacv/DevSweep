import AppKit
import Darwin
import SwiftUI

struct MeasurementLabel: View {
    let measurement: SizeMeasurement

    var body: some View {
        switch measurement.state {
        case .complete: Text(Fmt.disk(measurement.bytes))
        case .partial:
            Text(tr("storage.partial_size", ["size": Fmt.disk(measurement.bytes)]))
                .foregroundStyle(.orange)
                .help(tr("storage.partial_help"))
        case .unavailable:
            Text(tr("storage.unavailable"))
                .foregroundStyle(.orange)
                .help(tr("storage.partial_help"))
        }
    }
}

struct StorageReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: StorageTarget
    @State private var selected: Set<URL> = []
    @State private var measurements: [URL: SizeMeasurement] = [:]
    @State private var verdicts: [URL: CleanupGuardVerdict] = [:]
    @State private var search = ""
    @State private var measuring = true

    private var groups: [(root: URL, paths: [URL])] {
        let paths = Array(Set(target.paths)).filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) }
        return Dictionary(grouping: paths) { target.projectRootsByPath[$0.path] ?? $0.deletingLastPathComponent() }
            .map { (root: $0.key, paths: $0.value.sorted { $0.path < $1.path }) }
            .sorted { $0.root.path < $1.root.path }
    }

    private var eligible: Set<URL> {
        Set(measurements.filter { $0.value.state == .complete && $0.value.bytes > 0 && verdicts[$0.key] == .allowed }.map(\.key))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("review.title")).font(.headline)
                    Text(target.title).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(tr("review.close")) { dismiss() }
            }
            Tag(text: target.risk.label, color: target.risk.color)
            TextField(tr("review.search"), text: $search).textFieldStyle(.roundedBorder)
            if !target.method.supportsPathSelection {
                Text(tr("review.command_notice")).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button(tr("review.select_all")) { selected = eligible }
                    Button(tr("review.select_none")) { selected.removeAll() }
                    Spacer()
                    if measuring { ProgressView().controlSize(.small) }
                }
                .disabled(measuring)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups, id: \.root) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.root.lastPathComponent).font(.subheadline.weight(.semibold))
                            Text(group.root.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            ForEach(group.paths, id: \.self) { path in
                                HStack(alignment: .top, spacing: 8) {
                                    if target.method.supportsPathSelection {
                                        Toggle("", isOn: Binding(
                                            get: { selected.contains(path) },
                                            set: { if $0 { selected.insert(path) } else { selected.remove(path) } }
                                        ))
                                        .labelsHidden()
                                        .toggleStyle(.checkbox)
                                        .disabled(!eligible.contains(path) || measuring)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(path.path.replacingOccurrences(of: group.root.path + "/", with: ""))
                                            .font(.caption).textSelection(.enabled)
                                        if let verdict = verdicts[path], verdict != .allowed {
                                            Text(protectionLabel(verdict)).font(.caption2).foregroundStyle(.orange)
                                        }
                                        if let measurement = measurements[path], measurement.state != .complete {
                                            Text(tr("storage.partial_help")).font(.caption2).foregroundStyle(.orange)
                                            ForEach(Array(measurement.errors.prefix(2).enumerated()), id: \.offset) { _, error in
                                                Text(error).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                            }
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    if let measurement = measurements[path] {
                                        MeasurementLabel(measurement: measurement).font(.caption.monospacedDigit())
                                    } else {
                                        ProgressView().controlSize(.mini)
                                    }
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([path])
                                    } label: { Image(systemName: "folder") }
                                    .buttonStyle(.borderless)
                                    .help(tr("storage.show_in_finder"))
                                }
                            }
                        }
                        .padding(10).card()
                    }
                }
            }
            Divider()
            HStack {
                Text(tr("review.selected", ["count": selected.count,
                    "size": Fmt.disk(selected.reduce(0) { $0 + (measurements[$1]?.bytes ?? 0) })]))
                    .font(.caption)
                Spacer()
                if target.method.supportsPathSelection {
                    ActionButton(title: tr("review.clean_selected"), symbol: "trash", confirm: target.risk == .dataLoss) {
                        let paths = selected
                        dismiss()
                        Task { await model.clean(targetIDs: [target.id], selectedPaths: paths) }
                    }
                    .disabled(selected.isEmpty || measuring || model.cleanupProgress != nil || model.isScanningStorage)
                }
            }
        }
        .padding(16)
        .frame(width: 430, height: 540)
        .task { await measurePaths() }
    }

    private func protectionLabel(_ verdict: CleanupGuardVerdict) -> String {
        switch verdict {
        case .allowed: return ""
        case .inUse: return tr("review.in_use")
        case .tracked: return tr("review.tracked")
        case .recent: return tr("review.recent")
        case .unverified: return tr("review.unverified")
        }
    }

    private func measurePaths() async {
        let paths = Array(Set(target.paths)).sorted { $0.path < $1.path }
        // One read-only process snapshot per review; execution takes a fresh snapshot before deleting.
        let usage: ApplicationUsageSnapshot? = target.needsUsageCheck ? await Task.detached(priority: .utility) {
            ApplicationUsageSnapshot.capture(includeApplications: !target.requiresAppsClosed.isEmpty, includeTools: !target.requiresToolsIdle.isEmpty)
        }.value : nil
        await withTaskGroup(of: (URL, SizeMeasurement, CleanupGuardVerdict).self) { group in
            var pending = paths[...]
            func enqueue(_ path: URL) {
                group.addTask(priority: .utility) {
                    let measurement = SizeCalculator.measure([path])
                    let verdict = StorageSafety.check(path, target: target, usage: usage)
                    return (path, measurement, verdict)
                }
            }
            for _ in 0..<4 {
                guard let path = pending.popFirst() else { break }
                enqueue(path)
            }
            while let (path, measurement, verdict) = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); break }
                measurements[path] = measurement
                verdicts[path] = verdict
                if measurement.state == .complete && measurement.bytes > 0 && verdict == .allowed && target.risk != .dataLoss {
                    selected.insert(path)
                }
                if let next = pending.popFirst() { enqueue(next) }
            }
        }
        measuring = false
    }
}
