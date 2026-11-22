import SwiftUI

// All file mutations share the same Yes/No confirmation and result alert.
extension View {
    func fileWriteConfirmation(request: Binding<FileWriteRequest?>, onSuccess: @escaping () -> Void = {}) -> some View {
        modifier(FileWriteConfirmationModifier(request: request, onSuccess: onSuccess))
    }
}

private struct FileWriteConfirmationModifier: ViewModifier {
    @Binding var request: FileWriteRequest?
    let onSuccess: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var running = false
    @State private var result: WriteAlert?

    private var alert: WriteAlert? {
        result ?? request.map { .confirmation($0) }
    }

    func body(content: Content) -> some View {
        content
            .disabled(running)
            .interactiveDismissDisabled(running)
            .overlay {
                if running {
                    ProgressView("書き込み中…")
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { presented in
                if !presented { request = nil; result = nil }
            }), presenting: alert) { alert in
                switch alert {
                case .confirmation(let request):
                    Button("Yes") { commit(request) }
                        .disabled(model.busy)
                    Button("No", role: .cancel) { cancel(request) }
                case .success, .failure:
                    Button("OK", role: .cancel) {}
                }
            } message: { alert in
                if case .failure(let message) = alert { Text(message) }
                if case .confirmation(let request) = alert {
                    Text([request.title, request.destinationPath ?? request.sourcePath, request.details].compactMap { $0 }.joined(separator: "\n\n"))
                }
            }
            .onDisappear { cancelPending() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { cancelPending() }
            }
    }

    private func cancel(_ request: FileWriteRequest) {
        Task { await model.accessManager.cancelWrite(request) }
    }

    private func cancelPending() {
        guard let request else { return }
        self.request = nil
        cancel(request)
    }

    private func commit(_ request: FileWriteRequest) {
        guard !running, !model.busy else { return }
        running = true
        model.run(request.title) {
            defer { running = false }
            do {
                let receipt = try await model.accessManager.commitWrite(request, userConsented: true)
                model.didWrite(receipt)
                onSuccess()
                result = .success
            } catch {
                result = .failure(error.localizedDescription)
                model.log(error.localizedDescription, error: true)
            }
        }
    }

    private enum WriteAlert {
        case confirmation(FileWriteRequest)
        case success
        case failure(String)

        var title: String {
            switch self {
            case .confirmation: L("変更を適用していいですか?")
            case .success: L("書き込みに成功しました")
            case .failure: L("書き込みに失敗しました")
            }
        }
    }
}
