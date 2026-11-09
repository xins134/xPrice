import SwiftUI
import Combine
import UniformTypeIdentifiers

struct WatchlistBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(backup: WatchlistBackup) throws { data = try backup.encode() }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw WatchlistBackupError.invalidFormat }
        self.data = try WatchlistBackup.decode(data).encode()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
private final class BackupScreenState: ObservableObject {
    @Published var showsExporter = false
    @Published var showsImporter = false
    @Published var document: WatchlistBackupDocument?
    @Published var filename = "xPrice-自选备份"
    @Published var pendingBackup: WatchlistBackup?
    @Published var importMode = BackupImportMode.merge
    @Published var includesSettings = false
    @Published var confirmsReplacement = false
    @Published var message: String?
    @Published var errorMessage: String?
}

struct WatchlistBackupView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var ui = BackupScreenState()

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let previewTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        confirmationScreen
            .alert("备份操作未完成", isPresented: presentsError) {
                Button("好") { ui.errorMessage = nil }
                    .tint(store.settings.buttonTheme.color)
            } message: {
                Text(ui.errorMessage ?? "")
            }
    }

    private var confirmationScreen: some View {
        fileScreen
            .confirmationDialog("替换现有自选和行情栏？", isPresented: $ui.confirmsReplacement,
                                titleVisibility: .visible) {
                Button("替换现有列表", role: .destructive) { applyImport() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前列表中未出现在备份里的证券会被移除。\(ui.includesSettings ? "同时恢复备份中的设置。" : "保留当前设置。")")
            }
    }

    private var fileScreen: some View {
        contentForm
            .tint(.accentColor)
            .navigationTitle("自选备份")
            .navigationBarTitleDisplayMode(.inline)
            .fileExporter(isPresented: $ui.showsExporter, document: ui.document, contentType: .json,
                          defaultFilename: ui.filename, onCompletion: handleExport)
            .fileImporter(isPresented: $ui.showsImporter, allowedContentTypes: [.json],
                          allowsMultipleSelection: false, onCompletion: handleImport)
    }

    private var contentForm: some View {
        Form {
            fileControlsSection
            if let backup = ui.pendingBackup { importPreviewSection(backup) }
            if let message = ui.message {
                Section {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.subheadline)
                }
            }
        }
    }

    private var fileControlsSection: some View {
        Section {
            Button("导出备份", systemImage: "square.and.arrow.up") { prepareExport() }
                .tint(store.settings.buttonTheme.color)
            Button("选择备份文件", systemImage: "square.and.arrow.down") { ui.showsImporter = true }
                .tint(store.settings.buttonTheme.color)
        } footer: {
            Text("备份包含自选、行情栏和设置，保存为 JSON 文件。不包含缓存报价或同步记录。")
        }
    }

    private func importPreviewSection(_ backup: WatchlistBackup) -> some View {
        let result = previewResult(for: backup)
        let canImport: Bool
        if case .success = result { canImport = true }
        else { canImport = false }
        return Section {
            backupSummary(backup)
            importOptions
            importResultSummary(result)
            importButtons(canImport: canImport)
        } header: {
            Text("导入预览")
        } footer: {
            Text(ui.importMode == .merge
                 ? "合并会保留现有排序和证券信息，只添加尚未加入的证券。设置默认保留当前选择。"
                 : "替换会按备份重建自选和行情栏，并在下一步再次确认。未勾选恢复设置时，保留当前设置。")
        }
    }

    private func backupSummary(_ backup: WatchlistBackup) -> some View {
        Group {
            LabeledContent("备份时间", value: Self.previewTimeFormatter.string(from: backup.exportedAt))
            LabeledContent("备份自选", value: "\(backup.watchlist.count) 只")
            LabeledContent("备份行情栏", value: "\(backup.overviewInstruments.count) 只")
        }
    }

    private var importOptions: some View {
        Group {
            Picker("导入方式", selection: $ui.importMode) {
                ForEach(BackupImportMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.navigationLink)
            Toggle("同时恢复设置", isOn: $ui.includesSettings)
        }
    }

    @ViewBuilder
    private func importResultSummary(_ result: Result<CacheSnapshot, Error>) -> some View {
        switch result {
        case .success(let result): previewCounts(result)
        case .failure(let error):
            Text(error.localizedDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func previewCounts(_ snapshot: CacheSnapshot) -> some View {
        let watchlistCount = "\(snapshot.watchlist.count) 只"
        let overviewCount = "\(snapshot.overviewInstruments.count) 只"
        return Group {
            LabeledContent("导入后自选", value: watchlistCount)
            LabeledContent("导入后行情栏", value: overviewCount)
        }
    }

    private func importButtons(canImport: Bool) -> some View {
        Group {
            Button(ui.importMode == .merge ? "确认合并导入" : "继续替换导入") {
                if ui.importMode == .replace { ui.confirmsReplacement = true }
                else { applyImport() }
            }
            .tint(store.settings.buttonTheme.color)
            .disabled(!canImport)
            Button("取消本次导入") { ui.pendingBackup = nil }
                .tint(store.settings.buttonTheme.color)
        }
    }

    private var presentsError: Binding<Bool> {
        Binding(get: { ui.errorMessage != nil }, set: { if !$0 { ui.errorMessage = nil } })
    }

    private func handleExport(_ result: Result<URL, Error>) {
        switch result {
        case .success: ui.message = "备份已保存，可随时从文件中恢复。"
        case .failure(let error): ui.errorMessage = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            try loadBackup(from: url)
        } catch {
            ui.errorMessage = error.localizedDescription
        }
    }

    private func previewResult(for backup: WatchlistBackup) -> Result<CacheSnapshot, Error> {
        Result {
            let local = store.exportBackup()
            let snapshot = CacheSnapshot(watchlist: local.watchlist, quotes: [:], settings: local.settings,
                                         overviewInstruments: local.overviewInstruments)
            return try backup.preview(to: snapshot, mode: ui.importMode, includeSettings: ui.includesSettings)
        }
    }

    private func prepareExport() {
        do {
            let backup = store.exportBackup()
            ui.document = try WatchlistBackupDocument(backup: backup)
            ui.filename = "xPrice-自选备份-\(Self.filenameFormatter.string(from: backup.exportedAt))"
            ui.message = nil
            ui.showsExporter = true
        } catch {
            ui.errorMessage = error.localizedDescription
        }
    }

    private func loadBackup(from url: URL) throws {
        let accessible = url.startAccessingSecurityScopedResource()
        defer { if accessible { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: WatchlistBackup.maximumBytes + 1) ?? Data()
        ui.pendingBackup = try WatchlistBackup.decode(data)
        ui.importMode = .merge
        ui.includesSettings = false
        ui.message = nil
    }

    private func applyImport() {
        guard let backup = ui.pendingBackup else { return }
        do {
            try store.importBackup(backup, mode: ui.importMode, includeSettings: ui.includesSettings)
            ui.pendingBackup = nil
            ui.message = "备份已导入，最新自选将同步到配对手表。"
        } catch {
            ui.errorMessage = error.localizedDescription
        }
    }
}
