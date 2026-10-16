import SwiftUI

/// macOS 27 SDK에서 `@State`는 `SwiftUIMacros` 매크로로 해석되는데, 이 매크로 플러그인은
/// Xcode에만 포함되어 Command Line Tools만으로는 빌드할 수 없다.
/// 동일한 `SwiftUI.State` 프로퍼티 래퍼를 별칭으로 사용해 두 환경 모두에서 빌드되게 한다.
/// Xcode 빌드만 사용하게 되면 `@ViewState`를 `@State`로 일괄 치환하고 이 파일을 삭제해도 된다.
typealias ViewState<Value> = SwiftUI.State<Value>
