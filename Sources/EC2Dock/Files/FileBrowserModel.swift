import AppKit
import EC2DockCore
import Observation

/// 파일 탭 하나의 상태: 지금 보는 원격 폴더, 이동 기록, 진행 중인 전송.
/// 탭을 바꿔도 유지되도록 TerminalSessionStore가 보관한다.
@MainActor
@Observable
final class FileBrowserModel: Identifiable {
    struct Transfer: Identifiable, Equatable {
        enum Direction {
            case upload
            case download
        }

        enum Status: Equatable {
            case running
            case finished
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let direction: Direction
        let name: String
        let isDirectory: Bool
        let localURL: URL
        let remotePath: String
        /// 알 수 있을 때만 (폴더 올리기·내려받기는 전체 크기를 미리 모를 수 있다)
        let totalBytes: Int64?
        var transferredBytes: Int64?
        var status: Status = .running

        var fraction: Double? {
            guard let totalBytes, totalBytes > 0, let transferredBytes else { return nil }
            return min(1, Double(transferredBytes) / Double(totalBytes))
        }
    }

    nonisolated let id = UUID()
    let profileID: String
    /// 서버 이름
    let title: String
    /// 예: "ec2-user@203.0.113.25"
    let destination: String
    let isProduction: Bool
    @ObservationIgnored private let client: any SFTPClient

    /// 지금 보는 폴더. 처음 목록을 읽기 전에는 nil.
    private(set) var path: String?
    private(set) var entries: [RemoteFileEntry] = []
    private(set) var isLoading = false
    /// 처음 목록을 읽지 못한 오류 (목록 대신 안내를 보여준다)
    private(set) var loadError: (any Error)?
    /// 목록이 있는 상태에서 난 오류 (알림으로 보여주고 목록은 유지한다)
    var actionError: String?
    var showsHidden = false
    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []
    private(set) var transfers: [Transfer] = []
    /// "내리기"의 기본 위치
    var downloadDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser

    @ObservationIgnored private var transferTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var navigationID = 0

    init(profileID: String, title: String, destination: String, isProduction: Bool, client: any SFTPClient) {
        self.profileID = profileID
        self.title = title
        self.destination = destination
        self.isProduction = isProduction
        self.client = client
    }

    /// 폴더 먼저, 이름순 (Finder와 같은 자연 정렬)
    var visibleEntries: [RemoteFileEntry] {
        entries
            .filter { showsHidden || !$0.isHidden }
            .sorted { lhs, rhs in
                if lhs.isOpenable != rhs.isOpenable { return lhs.isOpenable }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var activeTransferCount: Int { transfers.filter { $0.status == .running }.count }
    var hasActiveTransfers: Bool { activeTransferCount > 0 }

    /// 호스트 키 문제는 터미널로 접속해 사용자가 직접 확인해야 풀린다.
    var needsTerminalForHostKey: Bool {
        guard let error = loadError as? SFTPError else { return false }
        return error == .hostKeyUnverified || error == .hostKeyChanged
    }

    // MARK: - 이동

    /// 처음 열 때: 홈 폴더를 연다.
    func start() async {
        guard path == nil, !isLoading else { return }
        isLoading = true
        loadError = nil
        do {
            let home = try await client.homeDirectory()
            isLoading = false
            await navigate(to: home, recordHistory: false)
        } catch {
            isLoading = false
            loadError = error
        }
    }

    /// 처음 불러오기에 실패한 뒤 다시 시도
    func retry() async {
        if let path {
            await navigate(to: path, recordHistory: false)
        } else {
            await start()
        }
    }

    func navigate(to newPath: String, recordHistory: Bool = true) async {
        navigationID += 1
        let current = navigationID
        isLoading = true
        do {
            let listed = try await client.list(newPath)
            // 더 나중에 시작한 이동이 있으면 이 결과는 버린다.
            guard current == navigationID else { return }
            if recordHistory, let path, path != newPath {
                backStack.append(path)
                forwardStack.removeAll()
            }
            path = newPath
            entries = listed
            loadError = nil
        } catch is CancellationError {
        } catch {
            guard current == navigationID else { return }
            if path == nil {
                loadError = error
            } else {
                actionError = TerminalErrorText.describe(error)
            }
        }
        if current == navigationID { isLoading = false }
    }

    func refresh() async {
        guard let path else { return await start() }
        await navigate(to: path, recordHistory: false)
    }

    func goBack() async {
        guard let previous = backStack.popLast(), let path else { return }
        forwardStack.append(path)
        await navigate(to: previous, recordHistory: false)
    }

    func goForward() async {
        guard let next = forwardStack.popLast(), let path else { return }
        backStack.append(path)
        await navigate(to: next, recordHistory: false)
    }

    func goUp() async {
        guard let path, path != "/" else { return }
        await navigate(to: RemotePath.parent(of: path))
    }

    /// 폴더(와 링크)는 열고, 파일은 내려받는다.
    func open(_ entry: RemoteFileEntry) async {
        guard let path else { return }
        if entry.isOpenable {
            await navigate(to: RemotePath.join(path, entry.name))
        } else {
            download([entry])
        }
    }

    func makeDirectory(named name: String) async -> Bool {
        guard let path else { return false }
        do {
            try RemotePath.validateName(name)
            try await client.makeDirectory(RemotePath.join(path, name))
            await navigate(to: path, recordHistory: false)
            return true
        } catch {
            actionError = TerminalErrorText.describe(error)
            return false
        }
    }

    // MARK: - 전송

    /// 이 Mac의 파일을 덮어쓰지 않도록 겹치지 않는 이름으로 내려받는다.
    func download(_ selected: [RemoteFileEntry], to directory: URL? = nil) {
        guard let path else { return }
        let folder = directory ?? downloadDirectory
        for entry in selected {
            let isDirectory = entry.kind == .directory
            let remotePath = RemotePath.join(path, entry.name)
            let localURL = LocalFileNaming.uniqueURL(for: entry.name, in: folder)
            let transfer = Transfer(direction: .download, name: entry.name, isDirectory: isDirectory, localURL: localURL,
                                    remotePath: remotePath, totalBytes: isDirectory ? nil : entry.size)
            let client = client
            start(transfer) {
                try await client.download(remotePath, isDirectory: isDirectory, to: localURL)
            } progress: {
                Self.localSize(of: localURL)
            }
        }
    }

    /// 지금 폴더로 올린다. 같은 이름 확인과 운영 서버 확인은 화면에서 먼저 한다.
    func upload(_ urls: [URL]) {
        guard let path else { return }
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let remotePath = RemotePath.join(path, url.lastPathComponent)
            let transfer = Transfer(direction: .upload, name: url.lastPathComponent, isDirectory: isDirectory, localURL: url,
                                    remotePath: remotePath, totalBytes: Self.localSize(of: url))
            let client = client
            start(transfer) {
                try await client.upload(url, isDirectory: isDirectory, to: remotePath)
            } progress: {
                // 파일은 서버에 쌓인 크기로 진행률을 본다 (연결 재사용으로 가볍게 확인).
                isDirectory ? nil : try? await client.size(of: remotePath)
            }
        }
    }

    func cancel(_ id: UUID) {
        transferTasks[id]?.cancel()
    }

    func cancelAllTransfers() {
        transferTasks.values.forEach { $0.cancel() }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.status != .running }
    }

    func revealInFinder(_ transfer: Transfer) {
        NSWorkspace.shared.activateFileViewerSelecting([transfer.localURL])
    }

    private func start(_ transfer: Transfer, work: @escaping @Sendable () async throws -> Void,
                       progress: @escaping @Sendable () async -> Int64?) {
        transfers.append(transfer)
        let id = transfer.id
        transferTasks[id] = Task { [weak self] in
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    if let bytes = await progress() { self?.update(id) { $0.transferredBytes = bytes } }
                }
            }
            let status: Transfer.Status
            do {
                try await work()
                status = .finished
            } catch {
                status = Task.isCancelled || error is CancellationError ? .cancelled : .failed(TerminalErrorText.describe(error))
            }
            poller.cancel()
            self?.finish(id, status: status)
        }
    }

    private func finish(_ id: UUID, status: Transfer.Status) {
        transferTasks[id] = nil
        guard let transfer = transfers.first(where: { $0.id == id }) else { return }
        update(id) { item in
            item.status = status
            if status == .finished, let total = item.totalBytes { item.transferredBytes = total }
        }
        switch (transfer.direction, status) {
        case (.download, .cancelled), (.download, .failed):
            // 새로 만든 이름으로 받던 것이므로 남은 조각만 지운다.
            try? FileManager.default.removeItem(at: transfer.localURL)
        case (.upload, .finished):
            // 지금 보고 있는 폴더에 올렸으면 목록을 새로 고친다.
            if let path, RemotePath.parent(of: transfer.remotePath) == path {
                Task { await navigate(to: path, recordHistory: false) }
            }
        default:
            break
        }
    }

    private func update(_ id: UUID, _ change: (inout Transfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    /// 파일 크기, 폴더면 안의 파일 크기 합
    nonisolated static func localSize(of url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        guard values.isDirectory == true else { return values.fileSize.map(Int64.init) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
