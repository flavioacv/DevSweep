import AppKit
import SwiftUI

struct StorageView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingHistory = false

    var body: some View {
        // Unmeasured targets (nil size) stay visible with a spinner; empty ones are hidden.
        let visible = model.targets.filter { (model.sizes[$0.id] ?? 1) > 0 || model.storageMeasurements[$0.id]?.state != .complete }
        let total = visible.reduce(0) { $0 + (model.sizes[$1.id] ?? 0) }
        let allSafeIDs = visible.filter { $0.risk == .safe && (model.sizes[$0.id] ?? 0) > 0 }.map(\.id)
        let allNonDestructiveIDs = visible.filter { $0.risk != .dataLoss && (model.sizes[$0.id] ?? 0) > 0 }.map(\.id)
        let stacks = Array(Set(visible.map(\.stack)))
            .sorted { stackTotal($0, visible) > stackTotal($1, visible) }
        let hasPartial = model.storageMeasurements.values.contains(where: { $0.state != .complete })

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                TechnicalCard(cornerRadius: 10, tint: .accentColor, padding: 11) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(summaryText(total: total))
                                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                if hasPartial {
                                    StatusBadge(text: tr("general.partial_badge"), color: .orange)
                                }
                            }
                            Text(scanCaption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Menu {
                            Button(tr("storage.clean_all_safe", ["count": allSafeIDs.count])) {
                                Task { await model.clean(targetIDs: allSafeIDs) }
                            }
                            .disabled(allSafeIDs.isEmpty || model.isScanningStorage || model.cleanupProgress != nil)
                            Button(tr("storage.clean_all_non_destructive", ["count": allNonDestructiveIDs.count])) {
                                Task { await model.clean(targetIDs: allNonDestructiveIDs) }
                            }
                            .disabled(allNonDestructiveIDs.isEmpty || model.isScanningStorage || model.cleanupProgress != nil)
                        } label: {
                            Label(tr("storage.quick_clean"), systemImage: "sparkles")
                        } primaryAction: {
                            Task { await model.clean(targetIDs: allSafeIDs.isEmpty ? allNonDestructiveIDs : allSafeIDs) }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(allNonDestructiveIDs.isEmpty || model.isScanningStorage || model.cleanupProgress != nil)
                        .help(tr("storage.quick_clean_help"))

                        Button { showingHistory = true } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(tr("cleanup.history"))
                    }
                }

                if model.targets.isEmpty && model.isScanningStorage {
                    ProgressView(tr("storage.searching"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
                ForEach(stacks) { stack in
                    StorageSection(stack: stack, targets: visible.filter { $0.stack == stack })
                }
            }
            .padding(12)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showingHistory) { CleanupHistoryView().environmentObject(model) }
    }

    private func summaryText(total: Int64) -> String {
        if model.storageMeasurements.values.contains(where: { $0.state != .complete }) {
            return tr("storage.summary_partial", ["size": Fmt.disk(total)])
        }
        return tr("storage.summary", ["size": Fmt.disk(total)])
    }

    private var scanCaption: String {
        if model.isScanningStorage { return tr("storage.measuring") }
        guard let date = model.lastStorageScan else { return tr("storage.not_scanned") }
        return tr("storage.scanned", ["when": Fmt.relative(date)])
    }

    private func stackTotal(_ stack: StackInfo, _ targets: [StorageTarget]) -> Int64 {
        targets.filter { $0.stack == stack }.reduce(0) { $0 + (model.sizes[$1.id] ?? 0) }
    }
}

private struct StorageSection: View {
    @EnvironmentObject private var model: AppModel
    let stack: StackInfo
    let targets: [StorageTarget]

    var body: some View {
        let sorted = targets.sorted { (model.sizes[$0.id] ?? 0) > (model.sizes[$1.id] ?? 0) }
        let total = targets.reduce(0) { $0 + (model.sizes[$1.id] ?? 0) }
        let maxStackBytes = sorted.compactMap { model.sizes[$0.id] }.max() ?? 0
        let safeIDs = targets.filter { $0.risk == .safe && (model.sizes[$0.id] ?? 0) > 0 }.map(\.id)
        let nonDestructiveIDs = targets.filter { $0.risk != .dataLoss && (model.sizes[$0.id] ?? 0) > 0 }.map(\.id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: stack.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(stack.name)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(Fmt.disk(total))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button(tr("storage.clean_non_destructive", ["count": nonDestructiveIDs.count])) {
                        Task { await model.clean(targetIDs: nonDestructiveIDs) }
                    }
                    .disabled(nonDestructiveIDs.isEmpty || model.isScanningStorage || model.cleanupProgress != nil)
                } label: {
                    Text(tr("storage.clean_safe"))
                } primaryAction: {
                    Task { await model.clean(targetIDs: safeIDs) }
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .disabled(nonDestructiveIDs.isEmpty || model.isScanningStorage || model.cleanupProgress != nil)
                .help(tr("storage.clean_safe_help"))
            }
            VStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, target in
                    if index > 0 { Divider().padding(.leading, 10) }
                    StorageRow(target: target, maxStackBytes: maxStackBytes)
                }
            }
            .technicalCard(cornerRadius: 10)
        }
    }
}

private struct StorageRow: View {
    @EnvironmentObject private var model: AppModel
    let target: StorageTarget
    let maxStackBytes: Int64
    @State private var showingReview = false

    var body: some View {
        let size = model.sizes[target.id] ?? 0
        let fraction = maxStackBytes > 0 ? Double(size) / Double(maxStackBytes) : 0

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(target.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    StatusBadge(text: target.risk.label, color: target.risk.color)
                    if !target.autoRecommend {
                        StatusBadge(text: tr("storage.manual"))
                    }
                }
                Text(target.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if maxStackBytes > 0, model.storageMeasurements[target.id]?.state == .complete {
                    ProportionalBar(fraction: fraction, tint: target.risk.color, height: 3)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 6)
            Button { showingReview = true } label: {
                Image(systemName: "list.bullet.indent")
            }
            .buttonStyle(.borderless)
            .help(tr("review.title"))
            if let measurement = model.storageMeasurements[target.id] {
                MeasurementLabel(measurement: measurement)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            } else {
                ProgressView().controlSize(.mini)
            }
            ActionButton(
                symbol: target.method.isTrash ? "arrow.up.trash" : "trash",
                confirm: target.risk == .dataLoss,
                busy: model.busy.contains(target.id),
                help: tr("storage.clean_item_help", ["name": target.title])
            ) {
                Task { await model.clean(targetIDs: [target.id]) }
            }
            .disabled(model.sizes[target.id] == nil || model.isScanningStorage || model.cleanupProgress != nil
                      || model.storageMeasurements[target.id]?.state != .complete)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .sheet(isPresented: $showingReview) { StorageReviewView(target: target).environmentObject(model) }
        .help(pathsHelp)
        .contextMenu {
            Button(tr("storage.show_in_finder")) {
                NSWorkspace.shared.activateFileViewerSelecting(Array(target.paths.prefix(30)))
            }
        }
    }

    private var pathsHelp: String {
        var lines = target.paths.prefix(8).map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        if target.paths.count > 8 { lines.append(tr("storage.more_paths", ["count": target.paths.count - 8])) }
        return lines.joined(separator: "\n")
    }
}

private extension CleanMethod {
    var isTrash: Bool {
        if case .trash = self { return true }
        return false
    }
}
