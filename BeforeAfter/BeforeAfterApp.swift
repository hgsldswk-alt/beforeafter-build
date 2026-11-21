import SwiftUI
import PhotosUI
import StoreKit
import QuickLook

@main
@MainActor
struct BeforeAfterApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

@MainActor
struct RootView: View {
    @StateObject private var model = AppModel()
    @StateObject private var purchases = Purchases(testing: Launch.testing)
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        Group {
            if model.ready {
                switch model.screen {
                case .home: HomeScreen()
                case .editor: EditorScreen()
                case .card: ShareCardScreen()
                }
            } else if model.startupFailed {
                VStack(spacing: 16) {
                    Text(L.t("error.startup")).multilineTextAlignment(.center)
                    PrimaryButton("action.retry", id: "startup.retry") { Task { await model.start() } }
                }
                .padding(24)
            } else {
                ProgressView(L.t("app.loading"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .tint(Theme.green)
        .preferredColorScheme(.light)
        .environmentObject(model)
        .environmentObject(purchases)
        .task {
            await purchases.start()
            await model.start()
        }
        .task(id: scenePhase) {
            if scenePhase == .active {
                if model.ready {
                    model.visit()
                    await purchases.foreground()
                }
            }
        }
        .task(id: canCheckReview) {
            guard canCheckReview else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled, model.checkReview() { requestReview() }
        }
        .onOpenURL { url in model.openDocument(url, hasPro: { purchases.hasPro }) }
        .quickLookPreview($model.previewURL)
        .photosPicker(isPresented: $model.pickerOpen, selection: $selection,
                      maxSelectionCount: model.selectionLimit, selectionBehavior: .ordered,
                      matching: .images, preferredItemEncoding: .current)
        .onChange(of: selection) { _, picks in
            guard !picks.isEmpty else { return }
            model.receivePhotos(picks)
            selection = []
        }
        .fileImporter(isPresented: $model.pickingFiles, allowedContentTypes: [.beforeAfterPreset]) { response in
            switch response {
            case .success(let url): model.useDocument(url, hasPro: purchases.hasPro)
            case .failure: model.show("preset.invalid")
            }
        }
        .sheet(item: $model.panel, onDismiss: model.panelDidDismiss) { panel in
            panelView(panel)
                .environmentObject(model)
                .environmentObject(purchases)
                .tint(Theme.green)
        }
        .sheet(item: $model.outputShare) { export in
            if export.fileOnly { SaveToFiles(url: export.url) { model.outputShare = nil } }
            else { ActivitySheet(url: export.url) { model.outputShare = nil } }
        }
        .sheet(isPresented: $model.fixtureOpen) {
            FixturePicker(limit: model.selectionLimit) { model.receiveFixture($0) }
        }
        .sheet(isPresented: deferredPresetBinding, onDismiss: model.presetDidDismiss) {
            if let preset = model.deferredPreset {
                DeferredPresetScreen(preset: preset)
                    .environmentObject(model)
            }
        }
    }

    private var canCheckReview: Bool {
        scenePhase == .active && model.ready && model.screen == .home && model.panel == nil && !model.busy
            && !model.pickerOpen && model.outputShare == nil && model.deferredPreset == nil
    }

    private var deferredPresetBinding: Binding<Bool> {
        Binding(get: { model.deferredPreset != nil }, set: { if !$0 { model.finishDeferredPreset(useBasic: false) } })
    }

    @ViewBuilder private func panelView(_ panel: Panel) -> some View {
        switch panel {
        case .settings: SettingsScreen()
        case .history: HistoryScreen()
        case .sizes: SizesScreen()
        case .paywall: PaywallScreen()
        case .importPreset: PresetImportScreen()
        case .milestonePhotos: HistoryScreen(forMilestone: true)
        case .existingExports: ExistingExportsScreen()
        case .privacy: PrivacyScreen()
        }
    }
}
