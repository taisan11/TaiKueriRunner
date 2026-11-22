import SwiftUI

@main
struct TaiKueriRunnerApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView(selection: $model.selectedTab) {
                NavigationStack { HomeView() }
                    .tabItem { Label(AppTab.home.title, systemImage: AppTab.home.systemImage) }
                    .tag(AppTab.home)

                NavigationStack { ApplicationsView() }
                    .tabItem { Label(AppTab.applications.title, systemImage: AppTab.applications.systemImage) }
                    .tag(AppTab.applications)

                NavigationStack { FileBrowserView(path: $model.browserPath) }
                    .tabItem { Label(AppTab.files.title, systemImage: AppTab.files.systemImage) }
                    .tag(AppTab.files)

                NavigationStack { UtilitiesView() }
                    .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
                    .tag(AppTab.settings)
            }
            .tint(.teal)
            .environment(model)
            .alert("操作できませんでした", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { Task { await model.endAccessSessions() } }
            }
        }
    }
}
