# EC2Dock 배포 가이드 (Phase 6)

## 1. 배포 방식 결정

| 항목 | 결정 | 이유 |
|---|---|---|
| 배포 채널 | **Developer ID 서명 + 공증된 dmg** (GitHub Releases) | 일반 Mac 앱처럼 내려받아 바로 실행할 수 있다 |
| Mac App Store | 대상 아님 | App Sandbox에서는 `aws`·`ssh` 실행과 `~/.aws`, `~/.ssh` 접근이 불가능하다 |
| App Sandbox | 사용 안 함 | 위와 같음. 대신 Hardened Runtime을 켠다 |
| 지금 단계 | ad-hoc 서명 `.app` (이 Mac 전용) | Developer ID 인증서가 아직 없다 |

## 2. 지금 할 수 있는 것: 이 Mac에 설치

```bash
./scripts/build-app.sh
```

```bash
cp -R dist/EC2Dock.app /Applications/
```

- `dist/EC2Dock.app`은 ad-hoc 서명이라 **이 Mac에서만** 문제없이 열린다. 다른 Mac에 복사하거나 내려받으면 Gatekeeper가 막는다.
- 데이터 위치(`~/Library/Application Support/EC2Dock/`)는 `swift run`과 같으므로 기존 설정과 캐시를 그대로 쓴다.
- 처음 iTerm2/Terminal로 접속할 때 macOS가 "EC2Dock이(가) iTerm을 제어하려고 합니다"를 묻는다. Info.plist의 `NSAppleEventsUsageDescription` 문구가 함께 표시된다.

배포 파일(zip, dmg)까지 만들려면:

```bash
./scripts/package.sh
```

## 3. 스크립트와 설정 파일

| 파일 | 역할 |
|---|---|
| `scripts/build-app.sh` | 릴리스 빌드 → `.app` 번들 구성 → 코드 서명 → 검증 |
| `scripts/package.sh` | build-app.sh 실행 → zip, dmg 생성 → (조건 충족 시) 공증·스테이플 |
| `scripts/make-icon.sh` | `Packaging/AppIcon.icns` 재생성 (아이콘을 바꿀 때만) |
| `Packaging/Info.plist` | 번들 정보 템플릿 (버전·빌드 번호·번들 ID는 스크립트가 채움) |
| `Packaging/EC2Dock.entitlements` | Hardened Runtime 엔타이틀먼트 (Apple Events) |

환경 변수:

| 변수 | 기본값 | 설명 |
|---|---|---|
| `VERSION` | `0.1.0` | 표시 버전 (`CFBundleShortVersionString`) |
| `BUILD_NUMBER` | git 커밋 수 | 빌드 번호 (`CFBundleVersion`) |
| `BUNDLE_ID` | `io.github.kwakchangkyoung.ec2dock` | 번들 ID. Apple Developer에 등록할 App ID와 같아야 한다 |
| `SIGN_IDENTITY` | `-` (ad-hoc) | 서명 인증서 이름 |
| `NOTARY_PROFILE` | 없음 | 공증용 키체인 프로필 이름 |

## 4. Developer ID 서명과 공증 (다른 Mac에 배포할 때)

1. **Apple Developer Program 가입** (연 99달러).
2. **Developer ID Application 인증서 발급**
   - 키체인 접근 > 인증서 지원 > "인증 기관에서 인증서 요청"으로 CSR을 만든다.
   - developer.apple.com > Certificates에서 "Developer ID Application" 인증서를 만들고 내려받아 설치한다.
   - 설치 확인:
     ```bash
     security find-identity -v -p codesigning
     ```
3. **공증 자격 증명 저장** (본인이 직접 실행. 앱 전용 암호 또는 App Store Connect API 키 사용):
   ```bash
   xcrun notarytool store-credentials EC2DockNotary --apple-id <Apple ID> --team-id <TEAMID>
   ```
4. **서명·공증된 dmg 만들기**:
   ```bash
   SIGN_IDENTITY="Developer ID Application: <이름> (<TEAMID>)" NOTARY_PROFILE=EC2DockNotary VERSION=0.1.0 ./scripts/package.sh
   ```
5. **릴리스 게시**:
   ```bash
   gh release create v0.1.0 dist/EC2Dock-0.1.0.dmg --title "EC2Dock 0.1.0"
   ```

`notarytool`과 `stapler`는 Command Line Tools에도 들어 있어 Xcode 없이 공증할 수 있다.

## 5. iCloud 앱 전용 컨테이너로 이전 (Developer ID 준비 후)

지금은 사용자의 iCloud Drive 폴더(`iCloud Drive/EC2Dock/ServerProfiles.json`)를 쓴다. 설계서 9.2가 권장하는 앱 전용 컨테이너로 옮기려면:

1. Apple Developer에서 App ID(`BUNDLE_ID`)에 iCloud(iCloud Documents) 기능을 켜고, 컨테이너 `iCloud.<BUNDLE_ID>`를 만든다.
2. 그 App ID로 **Developer ID 프로비저닝 프로파일**을 만들어 `Contents/embedded.provisionprofile`로 번들에 넣는다.
3. 엔타이틀먼트에 추가: `com.apple.developer.icloud-container-identifiers`, `com.apple.developer.ubiquity-container-identifiers`, `com.apple.developer.icloud-services`(CloudDocuments), `com.apple.application-identifier`, `com.apple.developer.team-identifier`.
4. 코드: `ICloudDriveSyncService`의 저장 위치를 `FileManager.url(forUbiquityContainerIdentifier:)`로 바꾸고, 기존 iCloud Drive 파일이 있으면 한 번 옮긴다(저장 위치만 바꾸도록 이미 분리되어 있음).

> Developer ID 앱의 iCloud 사용 조건은 Apple 문서에서 최신 내용을 확인한 뒤 진행한다.

## 6. Xcode 설치 후 정리할 것

- `@ViewState` → `@State` 일괄 치환 후 `Sources/EC2Dock/ViewState.swift` 삭제
- 테스트 매크로 플러그인 경로 지정 없이 `swift test` 실행
- SwiftTerm을 최신 버전으로 올리기 (1.12.0+의 Metal 셰이더 빌드 가능)
- Apple Silicon + Intel 유니버설 바이너리 (현재는 arm64 전용)

## 7. Phase 6 완료 기준 점검

| 기준 | 상태 |
|---|---|
| 실제 집/회사 환경에서 테스트 | 진행 중 (실제 계정 조회, Direct/Bastion 접속 확인됨. 두 Mac 동기화는 미확인) |
| 로그에 비밀 정보가 노출되지 않음 | 앱은 로그 파일을 쓰지 않는다. AWS CLI 오류는 원문 대신 분류된 메시지와 비밀 값을 가린 요약만 표시한다 |
| 코드 서명과 배포 방법 결정 | 이 문서 1장 (Developer ID + 공증 dmg). 인증서 발급은 미완료 |
| 사용자 피드백 수집 | GitHub Issues 사용 예정 |
