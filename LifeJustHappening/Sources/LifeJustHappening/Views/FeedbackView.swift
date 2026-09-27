import SwiftUI

/// One field, Send. Return sends, Shift+Return is a newline, Esc closes.
struct FeedbackView: View {
    let send: (String) -> FeedbackReporter.Result
    let close: () -> Void

    @State private var message = ""
    @State private var status: (text: String, ok: Bool?)?
    @State private var isSending = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's wrong, or what would make it better?")
                .font(.headline)
            TextEditor(text: $message)
                .font(.body)
                .focused($focused)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .disabled(isSending || !FeedbackReporter.isConfigured)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    submit()
                    return .handled
                }
            HStack {
                if let status {
                    Text(status.text)
                        .font(.callout)
                        .foregroundStyle(status.ok == false ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                } else {
                    Text("Sends the last few hundred log lines and app state along. No photos, no location.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Send", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !FeedbackReporter.isConfigured)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onExitCommand(perform: close)
        .onAppear {
            if FeedbackReporter.isConfigured {
                focused = true
            } else {
                status = ("Feedback isn't set up in this build.", false)
            }
        }
    }

    private func submit() {
        guard !isSending, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSending = true
        status = ("Sending…", nil)
        switch send(message) {
        case .notConfigured:
            status = ("Feedback isn't set up in this build.", false)
            isSending = false
        case .sent:
            status = ("Sent, thanks.", true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                message = ""
                status = nil
                isSending = false
                close()
            }
        }
    }
}
