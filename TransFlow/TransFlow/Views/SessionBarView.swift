import SwiftUI

/// Fixed top bar displaying the current session filename and a button to create a new session.
struct SessionBarView: View {
    let sessionName: String
    let onNewSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()

                // Session filename in the center
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)

                    Text(sessionName)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // New session button on the right: creates immediately with a default name.
                Button {
                    onNewSession()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "session.new_session"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.background)

            // Subtle bottom border
            Rectangle()
                .fill(.separator)
                .frame(height: 0.5)
        }
    }
}
