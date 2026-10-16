import Foundation

public enum TerminalApp: String, Codable, CaseIterable, Identifiable, Sendable {
    case iTerm2 = "com.googlecode.iterm2"
    case terminal = "com.apple.Terminal"
    /// EC2Dock 창 안에서 실행하는 내장 터미널 (외부 앱 아님)
    case embedded = "ec2dock.embedded"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .iTerm2: "iTerm2"
        case .terminal: "Terminal"
        case .embedded: "내장 터미널"
        }
    }

    public var isExternal: Bool { self != .embedded }
}

/// 이 Mac에만 저장하는 접속 설정. iCloud 동기화 대상이 아니다.
/// SSH 개인키 자체나 AWS 비밀 키는 넣지 않는다.
public struct LocalConnectionSettings: Codable, Identifiable, Equatable, Sendable {
    public var id: String { profileID }

    public var profileID: String
    public var awsCLIProfileName: String
    public var sshKeyPath: String?
    public var terminalIdentifier: String
    public var connectTimeoutSeconds: Int

    public init(
        profileID: String,
        awsCLIProfileName: String,
        sshKeyPath: String? = nil,
        terminalIdentifier: String = TerminalApp.iTerm2.rawValue,
        connectTimeoutSeconds: Int = 10
    ) {
        self.profileID = profileID
        self.awsCLIProfileName = awsCLIProfileName
        self.sshKeyPath = sshKeyPath
        self.terminalIdentifier = terminalIdentifier
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }
}
