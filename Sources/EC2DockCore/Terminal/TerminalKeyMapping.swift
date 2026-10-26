import Foundation

/// 내장 터미널이 그냥 넘기지 않는 이동 키를 원격 프로그램(vim, less 등)에 보낼 바이트로 바꾼다.
/// macOS 키보드의 fn+← / fn+→ / fn+↑ / fn+↓ 는 Home / End / Page Up / Page Down 이다.
/// SwiftTerm은 Home/End를 macOS 문서 스크롤 명령으로 바꿔 버려 서버에 아무것도 보내지 않는다.
public enum TerminalKeyMapping {
    public enum Key: Sendable {
        case home
        case end
        case pageUp
        case pageDown
    }

    /// 보낼 바이트. nil이면 터미널의 기본 동작을 그대로 둔다.
    /// - `applicationCursor`: 프로그램이 커서 키 응용 모드(DECCKM)를 켰는지. vim 등은 켠다.
    /// - `alternateScreen`: 전체 화면 프로그램(vim, less, top)이 대체 화면을 쓰는 중인지.
    ///   Page Up/Down은 대체 화면에서만 프로그램에 보내고, 평소에는 지난 출력 스크롤(기본 동작)로 둔다.
    public static func bytes(for key: Key, applicationCursor: Bool, alternateScreen: Bool) -> [UInt8]? {
        switch key {
        case .home: applicationCursor ? [0x1b, 0x4f, 0x48] : [0x1b, 0x5b, 0x48]   // ESC O H / ESC [ H
        case .end: applicationCursor ? [0x1b, 0x4f, 0x46] : [0x1b, 0x5b, 0x46]    // ESC O F / ESC [ F
        case .pageUp: alternateScreen ? [0x1b, 0x5b, 0x35, 0x7e] : nil              // ESC [ 5 ~
        case .pageDown: alternateScreen ? [0x1b, 0x5b, 0x36, 0x7e] : nil            // ESC [ 6 ~
        }
    }
}
