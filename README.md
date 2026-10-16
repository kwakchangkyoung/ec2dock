# EC2Dock

macOS용 AWS EC2 서버 접속 관리 앱. 요구사항 기준 문서: `EC2Dock_설계서.md`

현재 상태: **Phase 3 + Phase 5(iCloud 동기화)**. AWS CLI로 실제 EC2 목록을 조회해 캐시하고, Connect 시 캐시된 IP로 바로 SSH 접속합니다(내장 터미널, iTerm2, Terminal). Direct SSH와 Bastion SSH를 지원하며, SSM은 아직 지원하지 않습니다.

## iCloud 동기화

- Settings > 동기화에서 켭니다(기본값 꺼짐). 회사 정책상 계정 ID·서버 이름을 개인 iCloud에 저장해도 되는지 먼저 확인하세요.
- 저장 위치: `iCloud Drive/EC2Dock/ServerProfiles.json` (NSFileCoordinator로 접근). 앱 전용 iCloud 컨테이너는 코드 서명과 엔타이틀먼트가 필요해 앱 번들 배포(Phase 6) 때 옮길 예정입니다.
- 동기화: 서버 별칭, 계정 ID, 리전, 인스턴스 ID, 그룹, 환경, 즐겨찾기, 접속 방식, SSH 사용자명·포트, Bastion 참조
- 동기화하지 않음: SSH 키 경로와 개인키, AWS 자격 증명과 프로필 매핑, IP·상태 캐시, 앱 설정
- 마지막 동기화 시점을 기준으로 3-way 병합합니다. 양쪽에서 같은 서버를 다르게 수정하면 덮어쓰지 않고 충돌로 표시하며, "이 Mac 버전 / iCloud 버전" 중 고를 수 있습니다.
- 프로필 변경 2초 후, 그리고 60초마다 동기화합니다. iCloud를 쓸 수 없으면 로컬 모드로 계속 동작합니다.
- 제한: 서버 삭제 기능이 아직 없어 삭제는 동기화되지 않습니다.

## SSH 접속 동작

- Connect는 AWS를 호출하지 않고 마지막으로 조회한 캐시 IP로 바로 접속합니다. AWS 로그인이 만료돼도 접속할 수 있습니다.
- 재조회는 버튼을 누를 때만 합니다: 목록의 새로고침(전체), 서버 정보의 "다시 조회"(서버 한 대). 앱 시작 시에는 AWS를 호출하지 않습니다.
- 상세 화면과 Production 확인 창에 접속할 IP를 언제 조회했는지 표시합니다.

## AWS 로그인

- 새로고침이나 "다시 조회"가 자격 증명 만료/없음으로 실패하면 "AWS 로그인 (프로필)" 버튼이 나타납니다.
- 버튼을 누르면 메인 창 내장 터미널 탭에서 로그인 명령을 실행합니다. SSO 설정(`sso_session`/`sso_start_url`)이 있는 프로필은 `aws sso login --profile <p>`, 그 외는 `aws login --profile <p>`(AWS CLI 2.32.0 이상)입니다.
- 로그인이 성공하면(종료 코드 0) 탭이 자동으로 닫히고 원래 하려던 조회를 다시 시도합니다. 실패하면 탭에서 "로그인 다시 시도"를 할 수 있습니다.
- 앱은 자격 증명을 다루지 않습니다. 토큰은 AWS CLI가 `~/.aws` 아래에 직접 저장합니다.

## 여러 AWS 계정

- 각 AWS CLI 프로필이 하나의 계정에 대응하며, 사이드바 "AWS Accounts"에 계정별로 표시됩니다.
- Settings > "조회할 AWS CLI 프로필" > **"AWS 계정 추가…"**: 프로필 이름과 방식을 고르면 시트 안 내장 터미널에서 로그인을 진행합니다.
  - AWS 콘솔 로그인: `aws login --profile <이름>` (AWS CLI 2.32.0 이상, IAM 사용자는 `SignInLocalDevelopmentAccess` 정책 필요)
  - IAM Identity Center(SSO): `aws configure sso --profile <이름>`
  - 장기 액세스 키를 만드는 `aws configure`는 제공하지 않습니다.
- 로그인에 성공하면 조회 대상에 자동으로 추가하고 새로고침합니다. 이미 있는 프로필 이름이면 다시 로그인만 합니다.
- 실행 명령 예: `/usr/bin/ssh -i <키> -o IdentitiesOnly=yes -o ConnectTimeout=10 -o HostKeyAlias=<인스턴스 ID> -p 22 -- ec2-user@<IP>`
- 호스트 키 검증은 끄지 않습니다. `HostKeyAlias`로 known_hosts를 인스턴스 ID 기준으로 기록하므로, IP가 바뀌어도 같은 서버는 같은 키로 검증됩니다.
- 키 파일은 존재 여부와 권한(600)만 확인하며 내용은 읽지 않습니다.
- 처음 접속할 때 macOS가 iTerm2 자동화 권한을 묻습니다. 거부했다면 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 허용하세요.
- iTerm2 실행에 실패하면 상세 화면에서 "내장 터미널로 열기", "Terminal로 열기", "명령 복사"를 사용할 수 있습니다.

## Bastion SSH (점프 서버 경유)

- 대상 서버의 "접속 설정 편집"에서 접속 방식을 Bastion SSH로 바꾸고 Bastion 서버를 고릅니다.
- Bastion 후보는 같은 계정의 다른 서버 중 공인 IP가 있는 서버이며, VPC를 알면 같은 VPC로 좁힙니다(VPC 정보는 새로고침 때 저장).
- 각 구간은 자기 서버의 사용자명·포트·키 설정을 씁니다. 예를 들어 `ssh -i ~/.ssh/id_rsa -J ec2-user@<Bastion IP> ec2-user@<사설 IP>`는 다음처럼 실행됩니다.

  ```
  /usr/bin/ssh -i ~/.ssh/id_rsa -o IdentitiesOnly=yes -o ConnectTimeout=10 -o HostKeyAlias=<대상 인스턴스 ID> -p 22
    -o "ProxyCommand=/usr/bin/ssh -o ConnectTimeout=10 -o HostKeyAlias=<Bastion 인스턴스 ID> -p 22 -W <사설 IP>:22 -- ec2-user@<Bastion IP>"
    -- ec2-user@<사설 IP>
  ```

- `-J` 대신 `ProxyCommand ... -W`를 쓰는 이유: 구간마다 다른 키를 쓸 수 있고, 두 구간 모두 인스턴스 ID 기준으로 호스트 키를 검증합니다(Bastion IP도 캐시 값을 쓰므로 필요).
- ProxyCommand는 ssh가 셸로 실행하는 문자열이므로 모든 값을 검증·인용하고 `%`를 이스케이프합니다. `%h`/`%p` 토큰 대신 검증된 대상 주소를 직접 넣습니다.

## 열기 방식: 내장 터미널 / iTerm2 / Terminal

- Connect 버튼을 누르면 서버별 접속 설정의 터미널로 열립니다(기본값 iTerm2, Settings에서 변경 가능).
- Connect 버튼 옆 화살표 메뉴로 이번 접속만 다른 방식으로 열 수 있습니다.
- 내장 터미널은 메인 창 상세 영역의 **탭**으로 열리며, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)으로 같은 `/usr/bin/ssh` 명령을 실행합니다. 셸을 거치지 않으며 호스트 키 검증도 동일합니다.
  - 탭 막대: `[서버 정보] [● 서버 이름 PROD ×]`. 서버를 바꾸거나 탭을 오가도 세션은 유지되고, 탭을 닫을 때만 종료됩니다(연결 중이면 확인).
  - 세션이 끝나면 하단에 "다시 연결"(캐시된 IP로 다시 접속)과 "탭 닫기"가 나타납니다.
  - 연결 중인 서버는 목록에 터미널 아이콘이 표시되고, 서버 정보 화면에서 "터미널로 이동"할 수 있습니다.

### 설계서 대비 변경 사항

**캐시 IP로 접속 (설계서 7.4, 2.2 시나리오 A 변경, 사용자 결정 2026-10-15)**

설계서는 "접속 직전 대상 인스턴스를 반드시 재조회하고, 최신 정보를 확인할 수 없으면 오래된 공인 IP로 접속하지 않는다"고 정했지만, 로그인 없이 빠르게 접속하기 위해 "캐시 IP로 접속, 재조회는 사용자가 버튼을 누를 때만"으로 바꿨습니다.

- 위험: 자동 할당 공인 IP는 인스턴스 중지 시 반납되어 다른 AWS 고객에게 재할당될 수 있습니다. 캐시 IP가 오래되면 다른 서버로 접속을 시도할 수 있습니다.
- 완화: 호스트 키를 인스턴스 ID 기준(`HostKeyAlias`)으로 검증하므로, 이미 접속한 적 있는 서버라면 IP 주인이 바뀌었을 때 ssh가 인증 전에 중단합니다. 처음 접속하는 서버에서 호스트 키 확인 질문이 나오면 IP가 최신인지 "다시 조회"로 확인한 뒤 수락하세요. 호스트 키 검증은 어떤 경우에도 끄지 않습니다.
- IP·상태 캐시는 iCloud로 동기화하지 않으므로, 새 Mac에서는 처음에 한 번 새로고침해야 접속할 수 있습니다.

**내장 터미널**

설계서 3.2는 "자체 터미널 에뮬레이터"를 MVP 제외 항목으로 두었지만, 사용자 결정(2026-10-15)으로 내장 터미널을 **선택 가능한 열기 방식**으로 추가했습니다. iTerm2 연동은 그대로 유지됩니다.

SwiftTerm은 1.11.2로 고정했습니다. 1.12.0부터 Metal 셰이더가 포함되어 Xcode의 `metal` 컴파일러가 필요하기 때문입니다. Xcode로 빌드하게 되면 최신 버전으로 올릴 수 있습니다.

## 구조

```
Package.swift
Sources/EC2DockCore/      UI 의존성 없는 계층
  Models/                 ServerProfile, EC2Instance, LocalConnectionSettings, AppPreferences, 검색/필터
  Validation/             인스턴스 ID·리전·사용자명·포트 등 형식 검증
  Services/               AWS CLI 조회, 프로세스 실행, 로컬 저장소, 서비스 프로토콜
  Mocks/                  Mock 구현과 샘플 데이터
  AppState.swift          화면이 관찰하는 상태 (서비스는 주입)
Sources/EC2Dock/          SwiftUI 앱 (Dashboard, ServerDetail, ConnectionSettings, Preferences)
Tests/EC2DockCoreTests/   Swift Testing 단위/통합 테스트
```

## 실제 AWS 계정 연동

1. AWS CLI v2를 설치합니다.

   ```bash
   brew install awscli
   ```

2. 터미널에서 프로필을 설정합니다. IAM Identity Center(SSO)를 권장합니다. 앱은 자격 증명을 직접 받거나 저장하지 않습니다.

   ```bash
   aws configure sso --profile my-profile
   ```

3. 앱을 실행하고 Settings에서 **조회할 AWS CLI 프로필**과 **조회 리전**을 선택한 뒤 새로고침합니다.

필요한 권한은 `ec2:DescribeInstances` 읽기 권한뿐입니다(`sts:GetCallerIdentity`는 별도 권한이 필요 없습니다). 앱이 실행하는 명령은 다음 세 가지입니다.

- `aws configure list-profiles`
- `aws sts get-caller-identity --profile <p>`
- `aws ec2 describe-instances --profile <p> --region <r>`

조회 결과와 설정은 `~/Library/Application Support/EC2Dock/`에 저장됩니다. 디렉터리 권한은 0700, 파일 권한은 0600이며 비밀 값은 저장하지 않습니다.

## 빌드, 테스트, 실행

Xcode에서는 `Package.swift`를 열어 `EC2Dock` 스킴을 실행하면 됩니다.

Command Line Tools만 있는 환경에서는:

```bash
swift build
```

```bash
swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

```bash
swift run EC2Dock
```

AWS 없이 샘플 데이터와 Mock으로 실행하려면:

```bash
swift run EC2Dock --sample-data
```

실제 계정에 읽기 전용 통합 테스트를 실행하려면(출력에는 개수만 기록):

```bash
EC2DOCK_INTEGRATION_PROFILE=my-profile EC2DOCK_INTEGRATION_REGION=ap-northeast-2 swift test --filter "AWS integration" -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

- CLT의 빌드 시스템이 Swift Testing 매크로 플러그인을 자동으로 불러오지 못해 위처럼 경로를 지정합니다.
- macOS 27 SDK의 `@State` 매크로 플러그인이 CLT에 없어서 UI 코드는 `@ViewState`(같은 `SwiftUI.State` 래퍼의 별칭)를 사용합니다. 자세한 내용은 `Sources/EC2Dock/ViewState.swift`에 있습니다.
