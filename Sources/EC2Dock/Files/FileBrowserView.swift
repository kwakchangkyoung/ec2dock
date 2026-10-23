import AppKit
import EC2DockCore
import SwiftUI
import UniformTypeIdentifiers

/// 파일 탭: 서버의 폴더를 둘러보고 파일을 올리고 내린다 (SFTP).
/// - 더블클릭/Return: 폴더 열기, 파일 내려받기
/// - Finder에서 끌어다 놓으면 지금 폴더로 올린다
/// - 아래 전송 막대에서 진행률을 보고 취소한다
struct FileBrowserView: View {
    @Environment(AppState.self) private var state
    @Environment(TerminalSessionStore.self) private var terminals
    @Environment(ConnectionCoordinator.self) private var connections
    let model: FileBrowserModel

    @ViewState private var selection = Set<String>()
    @ViewState private var isDropTargeted = false
    @ViewState private var showsGoToFolder = false
    @ViewState private var goToPath = ""
    @ViewState private var showsNewFolder = false
    @ViewState private var newFolderName = ""
    /// 같은 이름이 이미 있는 올리기
    @ViewState private var uploadConflict: UploadConflict?
    /// 운영 서버에 올리기 전 확인
    @ViewState private var pendingProductionUpload: [URL]?

    private struct UploadConflict {
        let urls: [URL]
        let conflicting: [String]
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            content
            if !model.transfers.isEmpty {
                Divider()
                TransferListView(model: model)
            }
            Divider()
            statusBar
        }
        .navigationTitle("\(model.title) — 파일")
        .task { await model.start() }
        .alert("파일 작업을 하지 못했습니다",
               isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .alert("같은 이름의 항목이 이미 있습니다",
               isPresented: Binding(get: { uploadConflict != nil }, set: { if !$0 { uploadConflict = nil } }),
               presenting: uploadConflict) { conflict in
            Button("덮어쓰기", role: .destructive) { confirmProductionThenUpload(conflict.urls) }
            if conflict.conflicting.count < conflict.urls.count {
                Button("겹치는 항목 건너뛰기") {
                    confirmProductionThenUpload(conflict.urls.filter { !conflict.conflicting.contains($0.lastPathComponent) })
                }
            }
            Button("취소", role: .cancel) {}
        } message: { conflict in
            Text("\(Self.summary(conflict.conflicting))\n덮어쓰면 서버의 파일이 바뀝니다. 폴더는 안의 같은 이름 파일을 덮어씁니다.")
        }
        .alert("Production 서버에 올립니다",
               isPresented: Binding(get: { pendingProductionUpload != nil }, set: { if !$0 { pendingProductionUpload = nil } }),
               presenting: pendingProductionUpload) { urls in
            Button("올리기", role: .destructive) { model.upload(urls) }
            Button("취소", role: .cancel) {}
        } message: { urls in
            Text("서버: \(model.title)\n위치: \(model.path ?? "")\n항목: \(Self.summary(urls.map(\.lastPathComponent)))")
        }
        .alert(
            "진행 중인 파일 전송을 취소할까요?",
            isPresented: Binding(get: { terminals.pendingClosePaneID == model.id },
                                 set: { if !$0 && terminals.pendingClosePaneID == model.id { terminals.pendingClosePaneID = nil } })
        ) {
            Button("탭 닫기", role: .destructive) { terminals.close(id: model.id) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 탭의 파일 전송 \(model.activeTransferCount)개가 중단됩니다.")
        }
    }

    // MARK: - 경로 막대

    private var pathBar: some View {
        HStack(spacing: 6) {
            Group {
                Button { Task { await model.goBack() } } label: { Image(systemName: "chevron.left") }
                    .disabled(model.backStack.isEmpty)
                    .help("뒤로")
                    .accessibilityLabel("뒤로")
                Button { Task { await model.goForward() } } label: { Image(systemName: "chevron.right") }
                    .disabled(model.forwardStack.isEmpty)
                    .help("앞으로")
                    .accessibilityLabel("앞으로")
                Button { Task { await model.goUp() } } label: { Image(systemName: "arrow.up") }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.path == nil || model.path == "/")
                    .help("상위 폴더 (⌘↑)")
                    .accessibilityLabel("상위 폴더")
            }
            .buttonStyle(.borderless)

            breadcrumbs
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isLoading && model.path != nil {
                ProgressView().controlSize(.small)
            }

            Group {
                Button { model.showsHidden.toggle() } label: {
                    Image(systemName: model.showsHidden ? "eye" : "eye.slash")
                }
                .help(model.showsHidden ? "숨김 파일 감추기" : "숨김 파일 보기")
                .accessibilityLabel(model.showsHidden ? "숨김 파일 감추기" : "숨김 파일 보기")
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("새로 고침")
                    .accessibilityLabel("새로 고침")
                Button { newFolderName = ""; showsNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("새 폴더 (⇧⌘N)")
                    .accessibilityLabel("새 폴더")
                    .popover(isPresented: $showsNewFolder, arrowEdge: .bottom) { newFolderPopover }
            }
            .buttonStyle(.borderless)
            .disabled(model.path == nil)

            Button { chooseFilesToUpload() } label: { Label("올리기…", systemImage: "arrow.up.doc") }
                .disabled(model.path == nil)
                .help("이 Mac의 파일이나 폴더를 지금 폴더로 올립니다 (Finder에서 끌어다 놓아도 됩니다)")
            Button { model.download(selectedEntries) } label: { Label("내리기", systemImage: "arrow.down.doc") }
                .disabled(selectedEntries.isEmpty)
                .help("선택한 항목을 \(model.downloadDirectory.lastPathComponent) 폴더로 내려받습니다")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// 경로 단계를 눌러 상위 폴더로 바로 간다. 화살표 버튼(⌘L)으로 경로를 직접 입력할 수 있다.
    /// (⇧⌘G는 터미널 메뉴의 "이전 찾기"가 쓰므로 피한다.)
    private var breadcrumbs: some View {
        HStack(spacing: 2) {
            if let path = model.path {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        let crumbs = RemotePath.breadcrumbs(of: path)
                        ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                            if index > 1 {
                                Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                            }
                            Button(crumb.name) { Task { await model.navigate(to: crumb.path) } }
                                .buttonStyle(.borderless)
                                .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                                .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
                        }
                    }
                }
                .defaultScrollAnchor(.trailing)
            } else {
                Text(model.destination).foregroundStyle(.secondary)
            }
            Button { goToPath = model.path ?? ""; showsGoToFolder = true } label: {
                Image(systemName: "arrow.right.circle")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("l", modifiers: .command)
            .disabled(model.path == nil)
            .help("폴더로 이동… (⌘L)")
            .accessibilityLabel("폴더로 이동")
            .popover(isPresented: $showsGoToFolder, arrowEdge: .bottom) { goToFolderPopover }
        }
    }

    private var goToFolderPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("폴더로 이동").font(.headline)
            TextField("경로", text: $goToPath, prompt: Text("/var/log"))
                .frame(width: 320)
                .onSubmit(goToFolder)
            HStack {
                Spacer()
                Button("취소", role: .cancel) { showsGoToFolder = false }
                Button("이동", action: goToFolder)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!goToPath.hasPrefix("/"))
            }
        }
        .padding(14)
    }

    private var newFolderPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("새 폴더").font(.headline)
            TextField("이름", text: $newFolderName, prompt: Text("새 폴더"))
                .frame(width: 260)
                .onSubmit(createFolder)
            HStack {
                Spacer()
                Button("취소", role: .cancel) { showsNewFolder = false }
                Button("만들기", action: createFolder)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    // MARK: - 목록

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError {
            loadFailure(error)
        } else if model.path == nil {
            ProgressView("\(model.destination)에 연결하는 중…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            fileTable
        }
    }

    private var fileTable: some View {
        let entries = model.visibleEntries
        return Table(entries, selection: $selection) {
            TableColumn("이름") { entry in
                Label {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: Self.icon(for: entry))
                        .foregroundStyle(entry.isOpenable ? Color.accentColor : .secondary)
                }
                .opacity(entry.isHidden ? 0.6 : 1)
            }
            .width(min: 140, ideal: 260)
            TableColumn("크기") { entry in
                Text(entry.kind == .file ? entry.size.formatted(.byteCount(style: .file)) : "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("수정한 날짜") { entry in
                Text(entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140)
            TableColumn("권한") { entry in
                Text(entry.permissions)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 76, ideal: 84)
        }
        .contextMenu(forSelectionType: String.self) { names in
            rowMenu(for: model.entries.filter { names.contains($0.name) })
        } primaryAction: { names in
            let chosen = model.entries.filter { names.contains($0.name) }
            if chosen.count == 1 {
                Task { await model.open(chosen[0]) }
            } else {
                model.download(chosen.filter { !$0.isOpenable })
            }
        }
        .onChange(of: model.path) { selection = [] }
        .overlay {
            if entries.isEmpty && !model.isLoading {
                ContentUnavailableView {
                    Label("빈 폴더", systemImage: "folder")
                } description: {
                    Text(model.entries.isEmpty ? "Finder에서 파일을 끌어다 놓으면 이 폴더로 올립니다."
                         : "숨김 파일만 있습니다. 눈 모양 버튼으로 숨김 파일을 볼 수 있습니다.")
                }
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        Label("\(model.path ?? "")에 올리기", systemImage: "arrow.up.doc")
                            .font(.headline)
                            .padding(10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            requestUpload(files)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    @ViewBuilder
    private func rowMenu(for chosen: [RemoteFileEntry]) -> some View {
        if chosen.count == 1, chosen[0].isOpenable {
            Button("열기") { Task { await model.open(chosen[0]) } }
            Divider()
        }
        if !chosen.isEmpty {
            Button("내리기 (\(model.downloadDirectory.lastPathComponent))") { model.download(chosen) }
            Button("다른 위치로 내리기…") { chooseDownloadFolder(for: chosen) }
            Divider()
            Button("경로 복사") {
                ConnectionCoordinator.copy(chosen.map { RemotePath.join(model.path ?? "/", $0.name) }.joined(separator: "\n"))
            }
        } else {
            Button("이 폴더로 올리기…") { chooseFilesToUpload() }
            Button("새 폴더…") { newFolderName = ""; showsNewFolder = true }
        }
    }

    private func loadFailure(_ error: any Error) -> some View {
        ContentUnavailableView {
            Label("파일 목록을 불러오지 못했습니다", systemImage: "exclamationmark.triangle")
        } description: {
            Text(TerminalErrorText.describe(error))
        } actions: {
            HStack {
                Button("다시 시도") { Task { await model.retry() } }
                if model.needsTerminalForHostKey {
                    Button("터미널로 접속해 확인") {
                        Task { await connections.connect(profileID: model.profileID, terminal: .embedded, source: .detail) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("접속 설정…") { connections.editingProfileID = model.profileID }
            }
        }
    }

    private var statusBar: some View {
        HStack {
            if model.path != nil {
                let hiddenCount = model.showsHidden ? 0 : model.entries.filter(\.isHidden).count
                Text("항목 \(model.visibleEntries.count)개" + (hiddenCount > 0 ? " · 숨김 \(hiddenCount)개" : "")
                     + (selection.isEmpty ? "" : " · \(selection.count)개 선택"))
            }
            Spacer()
            if model.isProduction {
                Text("PROD").font(.caption2.weight(.bold)).foregroundStyle(.red)
            }
            Text(model.destination)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - 동작

    private var selectedEntries: [RemoteFileEntry] {
        model.entries.filter { selection.contains($0.name) }
    }

    private func goToFolder() {
        let target = goToPath.trimmingCharacters(in: .whitespaces)
        guard target.hasPrefix("/") else { return }
        showsGoToFolder = false
        Task { await model.navigate(to: target) }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        showsNewFolder = false
        Task { await model.makeDirectory(named: name) }
    }

    private func chooseFilesToUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "올리기"
        panel.message = "\(model.title)의 \(model.path ?? "")에 올릴 파일이나 폴더를 고르세요."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        requestUpload(panel.urls)
    }

    private func chooseDownloadFolder(for entries: [RemoteFileEntry]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.downloadDirectory
        panel.prompt = "여기로 내리기"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.downloadDirectory = folder
        model.download(entries, to: folder)
    }

    /// 같은 이름 확인 → 운영 서버 확인 → 올리기
    private func requestUpload(_ urls: [URL]) {
        guard model.path != nil else { return }
        let existing = Set(model.entries.map(\.name))
        let conflicting = urls.map(\.lastPathComponent).filter(existing.contains)
        if conflicting.isEmpty {
            confirmProductionThenUpload(urls)
        } else {
            uploadConflict = UploadConflict(urls: urls, conflicting: conflicting)
        }
    }

    private func confirmProductionThenUpload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if model.isProduction && state.preferences.confirmProductionConnections {
            pendingProductionUpload = urls
        } else {
            model.upload(urls)
        }
    }

    private static func summary(_ names: [String]) -> String {
        let shown = names.prefix(5).joined(separator: ", ")
        return names.count > 5 ? "\(shown) 외 \(names.count - 5)개" : shown
    }

    private static func icon(for entry: RemoteFileEntry) -> String {
        switch entry.kind {
        case .directory: "folder.fill"
        case .symlink: "arrowshape.turn.up.right"
        case .other: "questionmark.square.dashed"
        case .file:
            switch (entry.name as NSString).pathExtension.lowercased() {
            case "log", "txt", "md", "conf", "cfg", "ini", "yml", "yaml", "json", "xml", "properties", "env": "doc.text"
            case "sh", "py", "rb", "js", "ts", "java", "go", "rs", "php", "pl": "chevron.left.forwardslash.chevron.right"
            case "zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "jar", "war": "doc.zipper"
            case "png", "jpg", "jpeg", "gif", "svg", "webp": "photo"
            case "pem", "key", "crt", "cer", "pub": "key"
            default: "doc"
            }
        }
    }
}

// MARK: - 전송 막대

private struct TransferListView: View {
    let model: FileBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.hasActiveTransfers ? "전송 중 \(model.activeTransferCount)개" : "전송 완료")
                    .font(.caption.weight(.semibold))
                Spacer()
                if model.transfers.contains(where: { $0.status != .running }) {
                    Button("완료 항목 지우기") { model.clearFinishedTransfers() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.transfers.reversed()) { transfer in
                        TransferRow(model: model, transfer: transfer)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 132)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct TransferRow: View {
    let model: FileBrowserModel
    let transfer: FileBrowserModel.Transfer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: transfer.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(transfer.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(detail).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption)
                if transfer.status == .running {
                    if let fraction = transfer.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
            switch transfer.status {
            case .running:
                Button { model.cancel(transfer.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("전송 취소")
                    .accessibilityLabel("\(transfer.name) 전송 취소")
            case .finished where transfer.direction == .download:
                Button { model.revealInFinder(transfer) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless)
                    .help("Finder에서 보기")
                    .accessibilityLabel("Finder에서 보기")
            default:
                EmptyView()
            }
        }
    }

    private var iconColor: Color {
        switch transfer.status {
        case .running: .accentColor
        case .finished: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    private var detail: String {
        let total = transfer.totalBytes?.formatted(.byteCount(style: .file))
        let done = transfer.transferredBytes?.formatted(.byteCount(style: .file))
        let verb = transfer.direction == .upload ? "올리는" : "내려받는"
        switch transfer.status {
        case .running:
            if let done, let total { return "\(done) / \(total)" }
            if let done { return "\(verb) 중 · \(done)" }
            return total.map { "\(verb) 중 · \($0)" } ?? "\(verb) 중"
        case .finished:
            return transfer.direction == .upload ? "올림 · \(transfer.remotePath)" : "받음 · \(transfer.localURL.lastPathComponent)"
        case .failed(let message):
            return message.components(separatedBy: "\n").first ?? message
        case .cancelled:
            return transfer.direction == .upload ? "취소됨 · 서버에 일부만 올라간 파일이 남았을 수 있습니다" : "취소됨"
        }
    }
}
