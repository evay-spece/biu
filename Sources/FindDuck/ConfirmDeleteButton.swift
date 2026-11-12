import SwiftUI

struct ConfirmDeleteButton<Label: View>: View {
    @Binding var isPresented: Bool
    @FocusState private var confirmFocused:Bool
    let delete: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(role: .destructive) { isPresented = true } label: { label() }
            .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                HStack(spacing: 10) {
                    Button("取消") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                    Button("确认", role: .destructive) {
                        isPresented = false
                        delete()
                    }
                    .keyboardShortcut(.defaultAction)
                    .focused($confirmFocused)
                    .buttonStyle(.borderedProminent).tint(.red)
                    .accessibilityLabel("确认删除")
                }
                .onAppear {confirmFocused=true}
                .controlSize(.small)
                .padding(10)
                .foregroundStyle(Color.primary)
                .onKeyPress(.space,phases:.down) { _ in isPresented=false;delete();return .handled }
                .onExitCommand { isPresented = false }
            }
            .onDisappear { if isPresented { isPresented = false } }
    }
}
