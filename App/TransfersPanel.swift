import AppKit
import MountainCore
import SwiftUI

/// Full transfer list shown in the main window inspector.
struct TransfersPanel: View {
  @ObservedObject var model: UploadViewModel

  var body: some View {
    let summary = model.summary
    VStack(alignment: .leading, spacing: 0) {
      TransferSummaryHeader(summary: summary, onClearFinished: model.clearFinished)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
      if model.jobs.isEmpty {
        ContentUnavailableView {
          Label("転送はありません", systemImage: "arrow.up.circle")
        } description: {
          Text("ファイルをウィンドウにドロップするか、［アップロード］から選ぶと、ここに進捗が表示されます。")
        }
      } else {
        List {
          ForEach(TransferOrdering.sorted(model.jobs)) { job in
            TransferRow(job: job, model: model)
              .padding(.vertical, 6)
          }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
      }
    }
  }
}

struct TransferSummaryHeader: View {
  let summary: TransferSummary
  var onClearFinished: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(summary.headline)
          .font(.headline)
        Spacer()
        if summary.totalCount > 0 {
          Text("\(summary.completedCount) / \(summary.totalCount) 完了")
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
      if summary.activeCount > 0, let progress = summary.overallProgress {
        ProgressView(value: progress)
          .accessibilityLabel("全体の進捗")
      }
      if let onClearFinished, summary.hasFinished {
        Button("完了した項目を消去", action: onClearFinished)
          .buttonStyle(.glass)
          .controlSize(.small)
      }
    }
  }
}

struct TransferRow: View {
  let job: UploadJob
  @ObservedObject var model: UploadViewModel
  var compact = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let item = TransferPresentation(job: job, now: context.date)
      HStack(alignment: .top, spacing: 10) {
        Image(nsImage: FileIcons.icon(forName: item.title))
          .resizable()
          .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.title)
              .font(.body.weight(.medium))
              .lineLimit(1)
              .truncationMode(.middle)
              .help(job.relativePath)
            Spacer(minLength: 4)
            actions(item)
          }
          if let progress = item.progress, job.state != .completed {
            ProgressView(value: progress)
              .controlSize(.small)
              .tint(item.tone == .attention ? .orange : .accentColor)
              .accessibilityLabel("\(item.title) の進捗")
          }
          HStack(spacing: 5) {
            Image(systemName: item.symbolName)
              .foregroundStyle(color(for: item.tone))
              .accessibilityHidden(true)
            Text(item.statusText)
              .foregroundStyle(item.tone == .attention ? Color.orange : Color.secondary)
            Text("·").foregroundStyle(.tertiary)
            Text(item.bytesText).foregroundStyle(.secondary).monospacedDigit()
          }
          .font(.callout)
          .lineLimit(1)
          if let line = speedLine(item) {
            Text(line)
              .font(.callout)
              .foregroundStyle(.secondary)
              .monospacedDigit()
              .lineLimit(1)
          }
          if !compact {
            Label(item.destination, systemImage: "arrow.turn.down.right")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
              .help(item.destination)
          }
          if let error = item.errorText {
            Text(error)
              .font(.callout)
              .foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .contextMenu {
      if model.canShowDestination(job) {
        Button("保存先のフォルダを開く") { model.showDestination(job) }
      }
      Button("Finder で元のファイルを表示") { model.revealSource(job) }
      Divider()
      Button("キーをコピー") { model.copyKey(job) }
    }
  }

  @ViewBuilder private func actions(_ item: TransferPresentation) -> some View {
    HStack(spacing: 2) {
      if item.canPause {
        iconButton("pause.fill", help: "一時停止", label: "\(item.title) を一時停止") {
          model.pause(job)
        }
      }
      if item.canResume {
        iconButton("play.fill", help: "再開", label: "\(item.title) を再開") { model.resume(job) }
      }
      if item.canCancel {
        iconButton("xmark", help: "キャンセル", label: "\(item.title) をキャンセル") {
          model.cancel(job)
        }
      } else if job.state == .completed && model.canShowDestination(job) {
        iconButton("magnifyingglass", help: "保存先を表示", label: "\(item.title) の保存先を表示") {
          model.showDestination(job)
        }
      }
    }
  }

  private func iconButton(
    _ systemImage: String, help: String, label: String, action: @escaping () -> Void
  )
    -> some View
  {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 22, height: 22)
        .contentShape(Circle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .help(help)
    .accessibilityLabel(label)
  }

  private func speedLine(_ item: TransferPresentation) -> String? {
    let parts = [item.rateText, item.remainingText].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func color(for tone: TransferTone) -> Color {
    switch tone {
    case .neutral: .secondary
    case .active: .accentColor
    case .success: .green
    case .attention: .orange
    }
  }
}
