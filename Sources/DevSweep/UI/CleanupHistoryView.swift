import SwiftUI

struct CleanupStatusView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingHistory = false

    var body: some View {
        Group {
            if let progress = model.cleanupProgress {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(progress.isRefreshing ? tr("cleanup.refreshing") : tr("cleanup.progress", ["completed": progress.completed, "total": progress.total]))
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button(model.cleanupCancellationRequested ? tr("cleanup.cancelling") : tr("cleanup.cancel")) {
                            model.cancelCleanup()
                        }
                        .controlSize(.small)
                        .disabled(model.cleanupCancellationRequested || progress.isRefreshing)
                    }
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                    Text(progress.currentPath).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(tr("cleanup.cancel_help")).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(12)
            } else if let summary = model.cleanupSummary {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.cancelled ? tr("cleanup.cancelled") : tr("cleanup.finished"))
                            .font(.caption.weight(.semibold))
                        Text(tr("cleanup.result", ["completed": summary.completed, "total": summary.total,
                                                   "size": Fmt.disk(summary.freed), "errors": summary.errors.count]))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(tr("cleanup.history")) { showingHistory = true }.controlSize(.small)
                }
                .padding(12)
            }
        }
        .sheet(isPresented: $showingHistory) { CleanupHistoryView().environmentObject(model) }
    }
}

struct CleanupHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("cleanup.history")).font(.headline)
                Spacer()
                Button(tr("review.close")) { dismiss() }
            }
            Text(tr("cleanup.history_help")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.cleanupHistory.isEmpty {
                        Text(tr("cleanup.history_empty")).foregroundStyle(.secondary).padding()
                    }
                    ForEach(Array(model.cleanupHistory.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top) {
                                if entry.method == "session" {
                                    Text(entry.cancelled == true ? tr("cleanup.cancelled") : tr("cleanup.finished"))
                                        .font(.subheadline.weight(.semibold))
                                } else {
                                    Text(entry.title ?? entry.item).font(.subheadline.weight(.semibold))
                                }
                                Spacer()
                                Text(entry.date, format: .dateTime.day().month().hour().minute())
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if let completed = entry.completedItems, let total = entry.totalItems {
                                Text(tr("cleanup.result", ["completed": completed, "total": total,
                                    "size": Fmt.disk(entry.freedBytes ?? 0), "errors": entry.errors.count]))
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(entry.errors.isEmpty ? tr("cleanup.item_finished") : tr("cleanup.item_errors"))
                                    .font(.caption).foregroundStyle(entry.errors.isEmpty ? Color.secondary : .orange)
                            }
                            ForEach(Array(entry.paths.enumerated()), id: \.offset) { _, path in
                                Text(path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            ForEach(Array(entry.errors.enumerated()), id: \.offset) { _, error in
                                Text(error).font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
                            }
                        }
                        .padding(10).card()
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 430, height: 540)
        .task { await model.loadCleanupHistory() }
    }
}
