import AppKit
import MountainCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: UploadViewModel
  @State private var draft = SavedR2Settings.load()
  @State private var secret = ""
  @State private var message: Feedback?
  @State private var saving = false
  @State private var confirmDelete = false

  private struct Feedback: Equatable {
    let text: String
    let succeeded: Bool
  }

  var body: some View {
    Form {
      Section {
        TextField("アカウント ID", text: $draft.accountID, prompt: Text("32文字の英数字"))
          .disabled(model.hasPendingJobs)
        TextField("バケット", text: $draft.bucket, prompt: Text("例：drive"))
          .disabled(model.hasPendingJobs)
        Picker("管轄", selection: $draft.jurisdiction) {
          Text("標準").tag(R2Configuration.Jurisdiction.standard)
          Text("EU").tag(R2Configuration.Jurisdiction.eu)
        }
        .disabled(model.hasPendingJobs)
      } header: {
        Text("接続先")
      } footer: {
        if model.hasPendingJobs {
          Text("未完了の転送があるため、接続先は変更できません。")
            .foregroundStyle(.secondary)
        }
      }

      Section {
        TextField("アクセスキー ID", text: $draft.accessKeyID, prompt: Text("32文字の英数字"))
          .disabled(model.hasRunningTransfers)
        SecureField(
          "シークレット", text: $secret,
          prompt: Text(usesSavedSecret ? "保存済み（変更するときだけ入力）" : "シークレットアクセスキー")
        )
        .disabled(model.hasRunningTransfers)
        LabeledContent("接続テスト") {
          HStack(spacing: 10) {
            if let status = connectionStatus {
              Label(
                status.text,
                systemImage: status.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill"
              )
              .foregroundStyle(status.succeeded ? .green : .red)
              .lineLimit(2)
            }
            Button {
              message = nil
              Task { await model.testConnection(settings: normalizedDraft, secret: secret) }
            } label: {
              if model.isTestingConnection {
                ProgressView().controlSize(.small)
              } else {
                Text("テスト")
              }
            }
            .disabled(model.isTestingConnection || saving)
          }
        }
      } header: {
        Text("認証情報")
      } footer: {
        Text(
          "Cloudflare の R2 API トークン作成時に表示される「アクセスキー ID」と「シークレットアクセスキー」です。シークレットは Keychain に保存します。"
        )
        .foregroundStyle(.secondary)
      }

      Section("通知") {
        LabeledContent("完了と失敗を通知") {
          Button("許可する…") {
            Task {
              let allowed = await model.enableNotifications()
              message =
                allowed
                ? Feedback(text: "通知を有効にしました。", succeeded: true)
                : Feedback(text: "通知はシステム設定の「通知」から変更できます。", succeeded: false)
            }
          }
        }
      }

      if model.hasSavedSecret {
        Section {
          Button("保存済みのシークレットを削除…", role: .destructive) { confirmDelete = true }
            .disabled(model.hasPendingJobs)
        }
      }
    }
    .formStyle(.grouped)
    .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    .frame(width: 520, height: 700)
    .onAppear {
      draft = model.settings
      secret = ""
    }
    .onDisappear { secret = "" }
    // A test result only describes the values it was run with.
    .onChange(of: draft) { model.clearConnectionResult() }
    .onChange(of: secret) { model.clearConnectionResult() }
    .confirmationDialog("保存済みのシークレットを削除しますか？", isPresented: $confirmDelete) {
      Button("削除", role: .destructive) {
        Task {
          do {
            try await model.deleteSavedSecret()
            secret = ""
          } catch {
            message = Feedback(text: UploadViewModel.userMessage(for: error), succeeded: false)
          }
        }
      }
    } message: {
      Text("次のアップロードには、シークレットの再入力が必要になります。")
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      if let message {
        Label(
          message.text,
          systemImage: message.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .foregroundStyle(message.succeeded ? .green : .orange)
        .lineLimit(2)
      } else if model.hasRunningTransfers {
        Text("転送を一時停止すると設定を変更できます。")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        save()
      } label: {
        if saving { ProgressView().controlSize(.small) } else { Text("保存") }
      }
      .buttonStyle(.glassProminent)
      .controlSize(.large)
      .keyboardShortcut(.defaultAction)
      .disabled(saving || model.hasRunningTransfers || model.isTestingConnection)
    }
    .font(.callout)
    .padding(.horizontal, 20)
    .padding(.bottom, 18)
    .padding(.top, 4)
  }

  private var usesSavedSecret: Bool {
    model.hasSavedSecret && draft.accountID == model.settings.accountID
      && draft.accessKeyID == model.settings.accessKeyID
  }

  private var connectionStatus: Feedback? {
    guard let text = model.connectionMessage, !model.isTestingConnection else { return nil }
    return Feedback(text: text, succeeded: model.connectionSucceeded)
  }

  private var normalizedDraft: SavedR2Settings {
    var result = draft
    result.accountID = result.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    result.accessKeyID = result.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
    result.bucket = result.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
    return result
  }

  private func save() {
    saving = true
    message = nil
    Task {
      do {
        try await model.saveSettings(normalizedDraft, secret: secret)
        secret = ""
        draft = model.settings
        message = Feedback(text: "保存しました。", succeeded: true)
      } catch {
        message = Feedback(text: UploadViewModel.userMessage(for: error), succeeded: false)
      }
      saving = false
    }
  }
}
