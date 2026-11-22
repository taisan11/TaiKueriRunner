import SwiftUI

struct ApplicationsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    private var catalog: ApplicationCatalogModel { model.applicationCatalog }
    @State private var search = ""
    @State private var searchScope = ApplicationSearchScope.name
    @State private var kind = ApplicationKind.application
    @State private var publisher = 0
    @State private var freshSearch = false
    @State private var visible = false
    @State private var paused = false
    @State private var reloadID = UUID()
    @State private var forceRefresh = false

    private struct LoadRequest: Equatable {
        let active: Bool
        let reload: UUID
    }
    private var loadRequest: LoadRequest {
        LoadRequest(active: visible && scenePhase == .active && model.selectedTab == .applications &&
                    !model.busy && model.canAcquireAccess && !paused,
                    reload: reloadID)
    }

    private var visibleApplications: [CatalogApplication] {
        (catalog.snapshot?.catalog.applications ?? []).filter {
            $0.kind == kind && (publisher == 0 || (publisher == 1 ? !$0.isApple : $0.isApple)) &&
            searchScope.matches($0, query: search)
        }
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    AppGroupsView()
                } label: {
                    Label("App Groupsをスキャン", systemImage: "folder.badge.person.crop")
                }
            }
            if catalog.loading {
                Section {
                    HStack(spacing: 12) { ProgressView(); Text(catalog.status).font(.subheadline) }
                    Button("中止", role: .destructive) { paused = true }
                }
            } else if let snapshot = catalog.snapshot {
                Section {
                    Picker("提供元", selection: $publisher) {
                        Text("すべて").tag(0)
                        Text("ユーザー").tag(1)
                        Text("Apple").tag(2)
                    }.pickerStyle(.segmented)
                }
                Section("\(String(describing: kind.title)) · \(String(describing: visibleApplications.count))件") {
                    if visibleApplications.isEmpty {
                        ContentUnavailableView("該当する\(String(describing: kind.title))はありません", systemImage: "magnifyingglass", description: Text("表示条件や検索語を変更してください。"))
                    }
                    ForEach(visibleApplications) { app in
                        NavigationLink {
                            ApplicationDetailView(application: app, snapshot: snapshot)
                        } label: {
                            HStack(spacing: 12) {
                                ApplicationTile(application: app)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name).lineLimit(2)
                                    Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }.padding(.vertical, 3)
                        }
                        .contextMenu {
                            Button("Bundle IDをコピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = app.bundleID }
                            if let path = app.containerPaths.first {
                                Button("コンテナパスをコピー", systemImage: "folder") { UIPasteboard.general.string = path }
                            }
                        }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView {
                        Label(catalog.errorMessage == nil ? L("端末のアプリを調べる") : L("一覧を読み込めません"), systemImage: "square.grid.2x2")
                    } description: {
                        if let error = catalog.errorMessage { Text(error) }
                    } actions: {
                        Button("自動検出して読み込む") { requestLoad(fresh: false) }
                            .buttonStyle(.borderedProminent).disabled(!model.canAcquireAccess || model.busy)
                        if !model.canAcquireAccess {
                            Button("実行環境と設定を確認") { model.selectedTab = .settings }
                        }
                    }
                } footer: {
                    if !model.canAcquireAccess {
                        Text("DBの探索には実行許可範囲のOS（\(String(describing: RuntimeSupport.allowedVersionRange))）と有効なApp Groupが必要です。アクセス設定を確認してください。")
                    } else if catalog.status == L("中止しました。") { Text(catalog.status) }
                }
            }
        }
        .navigationTitle("アプリ")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "アプリ名・Bundle IDで絞り込み")
        .searchScopes($searchScope) {
            ForEach(ApplicationSearchScope.allCases) { Text($0.title).tag($0) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("表示する種類", selection: $kind) {
                        ForEach(ApplicationKind.allCases) { Text($0.title).tag($0) }
                    }
                    Button("一覧を更新", systemImage: "arrow.clockwise") { requestLoad(fresh: false) }
                        .disabled(!model.canAcquireAccess || model.busy)
                    Button("DBを再検索", systemImage: "magnifyingglass") { requestLoad(fresh: true) }
                        .disabled(!model.canAcquireAccess || model.busy)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("アプリ一覧の表示と読み込み")
                .disabled(catalog.loading)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: loadRequest, priority: .utility) {
            let request = loadRequest
            guard !Task.isCancelled, request.active else { return }
            // A completed session snapshot is reused as-is. Re-read only when
            // there is no cached list or the user explicitly refreshed.
            guard catalog.snapshot == nil || forceRefresh else { return }
            await loadDeviceCatalog()
        }
    }

    private func requestLoad(fresh: Bool) {
        guard !catalog.loading, !model.busy, model.canAcquireAccess else { return }
        freshSearch = fresh
        forceRefresh = true
        paused = false
        reloadID = UUID()
    }

    private func loadDeviceCatalog() async {
        let force = forceRefresh, fresh = freshSearch && forceRefresh
        await catalog.load { progress in
            if force {
                try await model.refreshApplications(freshSearch: fresh, progress: progress)
            } else {
                try await model.loadApplications(progress: progress)
            }
        }
        guard !Task.isCancelled else { return }
        forceRefresh = false
        freshSearch = false
        if let snapshot = catalog.snapshot {
            model.log(L("LaunchServices DB一覧: \(String(describing: snapshot.sourcePath)) / layout \(String(describing: snapshot.catalog.layout)) / \(String(describing: snapshot.catalog.applications.count))件"))
        } else if let error = catalog.errorMessage { model.log(L("アプリ一覧: \(String(describing: error))"), error: true) }
    }

}

struct ApplicationTile: View {
    let application: CatalogApplication
    var body: some View {
        Image(systemName: application.kind == .appExtension ? "puzzlepiece.extension" : "app.dashed")
            .font(.title3).foregroundStyle(application.isApple ? .blue : .teal)
            .frame(width: 42, height: 42)
            .background((application.isApple ? Color.blue : Color.teal).opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }
}
