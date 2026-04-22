import SwiftUI

struct UpdateAlertView: View {
    @Bindable var updateChecker: UpdateChecker
    @Bindable var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    private var version: String {
        if case .updateAvailable(let v, _) = updateChecker.status { return v }
        return ""
    }

    private var releaseNotes: String {
        if case .updateAvailable(_, let notes) = updateChecker.status { return notes }
        return ""
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                Text("update_alert.title \(version)")
                    .font(.headline)

                Text("update_alert.message")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)

            if !releaseNotes.isEmpty {
                ScrollView {
                    Text(releaseNotes)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 140)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }

            HStack(spacing: 12) {
                Button("update_alert.skip_version") {
                    settings.skippedUpdateVersion = version
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

                Spacer()

                Button("update_alert.cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("update_alert.update") {
                    updateChecker.downloadUpdate()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 400)
    }
}
