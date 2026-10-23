# EC2Dock

macOS용 AWS EC2 서버 접속 관리 앱. 요구사항 기준 문서: `EC2Dock_설계서.md`

현재 상태: **Phase 3 + Phase 5(iCloud 동기화)**. AWS CLI로 실제 EC2 목록을 조회해 캐시하고, 접속 시 캐시된 IP로 바로 SSH 접속합니다(내장 터미널, iTerm2, Terminal). Direct SSH와 Bastion SSH를 지원하며, SSM은 아직 지원하지 않습니다.

## iCloud 동기화

- 설정(⌘,) > 동기화 탭에서 켭니다(기본값 꺼짐). 회사 정책상 계정 ID·서버 이름을 개인 iCloud에 저장해도 되는지 먼저 확인하세요.
- 저장 위치: `iCloud Drive/EC2Dock/ServerProfiles.json` (NSFileCoordinator로 접근). 앱 전용 iCloud 컨테이너는 코드 서명과 엔타이틀먼트가 필요해 앱 번들 배포(Phase 6) 때 옮길 예정입니다.
- 동기화: 서버 별칭, 계정 ID, 리전, 인스턴스 ID, 그룹, 환경, 즐겨찾기, 접속 방식, SSH 사용자명·포트, Bastion 참조
- 동기화하지 않음: SSH 키 경로와 개인키, AWS 자격 증명과 프로필 매핑, IP·상태 캐시, 앱 설정
- 마지막 동기화 시점을 기준으로 3-way 병합합니다. 양쪽에서 같은 서버를 다르게 수정하면 덮어쓰지 않고 충돌로 표시하며, "이 Mac 버전 / iCloud 버전" 중 고를 수 있습니다.
- 오프라인 파일 버전에 충돌이 있으면 모두 해결할 때까지 병합 저장을 보류하고 원본을 보존합니다. 일부만 해결한 뒤 앱을 다시 시작해도 선택은 유지되며, 병합을 완료한 버전만 해결 처리합니다.
- 프로필 변경 2초 후, 그리고 60초마다 동기화합니다. iCloud를 쓸 수 없으면 로컬 모드로 계속 동작합니다.
- 서버 삭제: 목록의 컨텍스트 메뉴나 상세 화면의 "서버 삭제" 버튼으로 프로필을 삭제합니다. 삭제 기록이 남아 새로고침해도 다시 추가되지 않고, iCloud 동기화로 다른 Mac에도 삭제가 전파됩니다. 설정 > 일반 > "삭제한 서버"에서 복원할 수 있습니다.
- 동기화 안전장치: 한쪽 목록에 없다는 것만으로는 삭제로 보지 않습니다(로컬 파일 읽기 실패, 아직 내려받지 않은 iCloud 파일, 오래된 오프라인 파일 버전이 서버를 지우지 않도록). 삭제는 삭제 기록으로만 전파되며, 삭제 후에 수정·복원한 값이 우선합니다. 저장 직전에 다른 Mac이 파일을 바꿨으면 덮어쓰지 않고 다시 읽어 병합합니다.
- Production 판별: Environment 태그를 단어로 나눠 `production`, `prod`, `prd`, `live`, `운영` 중 하나가 있으면 운영 서버로 보고 접속·SSH 명령 복사 전에 확인합니다.

## SSH 접속 동작

- 접속은 AWS를 호출하지 않고 마지막으로 조회한 캐시 IP로 바로 접속합니다. AWS 로그인이 만료돼도 접속할 수 있습니다.
- 재조회는 버튼을 누를 때만 합니다: 목록의 새로고침(전체), 서버 정보의 "다시 조회"(서버 한 대). 앱 시작 시에는 AWS를 호출하지 않습니다.
- 상세 화면과 Production 확인 창에 접속할 IP를 언제 조회했는지 표시합니다.

## AWS 로그인

- 새로고침이나 "다시 조회"가 자격 증명 만료/없음으로 실패하면 "AWS 로그인 (프로필)" 버튼이 나타납니다.
- 버튼을 누르면 메인 창 내장 터미널 탭에서 로그인 명령을 실행합니다. SSO 설정(`sso_session`/`sso_start_url`)이 있는 프로필은 `aws sso login --profile <p>`, 그 외는 `aws login --profile <p>`(AWS CLI 2.32.0 이상)입니다.
- 로그인이 성공하면(종료 코드 0) 탭이 자동으로 닫히고 원래 하려던 조회를 다시 시도합니다. 실패하면 탭에서 "로그인 다시 시도"를 할 수 있습니다.
- 앱은 자격 증명을 다루지 않습니다. 토큰은 AWS CLI가 `~/.aws` 아래에 직접 저장합니다.

## 여러 AWS 계정

- 각 AWS CLI 프로필이 하나의 계정에 대응하며, 사이드바 "AWS Accounts"에 계정별로 표시됩니다.
- 설정(⌘,) > AWS 탭 > **"AWS 계정 추가…"** (서버가 하나도 없을 때는 목록의 시작 체크리스트에서도 가능): 프로필 이름과 방식을 고르면 시트 안 내장 터미널에서 로그인을 진행합니다.
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

- 접속 방법: 목록에서 **더블클릭 또는 Return**, 상세 화면의 **접속** 버튼, 또는 목록 **우클릭 > 접속**. 서버별 접속 설정의 터미널로 열립니다(기본값 iTerm2, 설정 > 터미널에서 변경).
- 다른 방식으로 한 번만 열려면 접속 버튼 옆 화살표나 우클릭 > "다른 터미널로 접속"을 씁니다.
- 목록 우클릭 메뉴: 접속, 다른 터미널로 접속, 파일 열기(SFTP), 접속 설정…, 다시 조회, 공인/사설 IP·인스턴스 ID·SSH 명령 복사, 즐겨찾기, 삭제
- iTerm2는 설정에서 "열린 창의 새 탭으로 열기"를 켤 수 있습니다(기본은 새 창).
- 내장 터미널은 메인 창 상세 영역의 **탭**으로 열리며, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)으로 같은 `/usr/bin/ssh` 명령을 실행합니다. 셸을 거치지 않으며 호스트 키 검증도 동일합니다.
  - 탭 막대: `[서버 정보] [● 서버 이름 PROD ×]`. 서버를 바꾸거나 탭을 오가도 세션은 유지되고, 탭을 닫을 때만 종료됩니다(연결 중이면 확인).
  - 세션이 끝나면 하단에 "다시 연결"(캐시된 IP로 다시 접속)과 "탭 닫기"가 나타납니다.
  - 연결 중인 서버는 목록에 터미널 아이콘이 표시되고, 서버 정보 화면에서 "터미널로 이동"할 수 있습니다.

### 내장 터미널 분할과 단축키 (메뉴 막대 "터미널")

탭 하나를 여러 칸으로 나눌 수 있습니다. 분할하면 포커스된 칸의 서버로 새 ssh 연결을 하나 더 엽니다(Production 서버는 다시 확인). 칸 경계는 드래그로 크기를 바꾸고, 칸을 클릭하면 포커스가 옮겨집니다. 탭 막대 오른쪽 버튼으로도 찾기·분할·넓게 보기를 할 수 있습니다.

- **넓게 보기(집중 모드)**: 터미널 탭을 보는 동안 사이드바와 목록을 자동으로 접습니다(설정 > 터미널에서 끌 수 있음). ⇧⌘F로 언제든 켜고 끕니다.
- **세션 보호**: 연결 중인 세션이 있으면 앱 종료(⌘Q)와 창 닫기 전에 확인합니다. 터미널 탭에서 ⌘W는 창이 아니라 포커스된 칸을 닫습니다. (창 왼쪽 위 빨간 닫기 버튼은 아직 확인 없이 닫힙니다.)
- **모양**: 글자 크기와 테마(어두운/밝은/시스템 따르기)는 설정 > 터미널에서 바꿉니다.

| 동작 | 단축키 |
|---|---|
| 좌우로 분할 / 위아래로 분할 | ⌘D / ⇧⌘D |
| 이 칸 닫기 (연결 중이면 확인) | ⌘W (터미널 탭에서) 또는 ⌥⌘W |
| 터미널 넓게 보기 켜기/끄기 | ⇧⌘F |
| 터미널에서 찾기 / 다음 / 이전 | ⌘F / ⌘G / ⇧⌘G (찾기 막대에서 Return / ⇧Return, Esc로 닫기) |
| 글자 크게 / 작게 / 기본 크기 | ⌘+ / ⌘− / ⌥⌘0 |
| 다음 칸 / 이전 칸 | ⌘] / ⌘[ |
| 다음 탭 / 이전 탭 | ⌘→ / ⌘← (또는 ⇧⌘] / ⇧⌘[) |
| 터미널 탭 1~9 / 서버 정보 | ⌘1~⌘9 / ⌘0 |

## 서버 파일 올리기·내리기 (SFTP)

서버의 파일을 **파일 탭**에서 둘러보고 올리거나 내려받습니다. macOS 기본 `/usr/bin/sftp`를 쓰므로 따로 설치할 것이 없습니다.

- 여는 방법: 서버 정보의 **파일** 버튼, 목록 **우클릭 > 파일 열기 (SFTP)**, 터미널 탭 막대의 폴더 버튼. 같은 서버의 파일 탭이 이미 있으면 그 탭으로 갑니다. 파일 탭은 터미널 탭과 같은 탭 막대에 놓이며 ⌘숫자 이동·넓게 보기도 똑같이 동작합니다.
- 둘러보기: 처음에는 홈 폴더가 열립니다. 폴더 더블클릭/Return으로 들어가고, 뒤로·앞으로·상위 폴더(⌘↑), 경로 단계 클릭, **폴더로 이동(⌘L)**, 숨김 파일 보기, 새 폴더(⇧⌘N)를 쓸 수 있습니다.
- 올리기: **올리기…** 버튼이나 Finder에서 목록으로 끌어다 놓으면 지금 폴더로 올립니다(파일·폴더). 같은 이름이 있으면 덮어쓸지, 겹치는 항목만 건너뛸지 묻습니다.
- 내리기: 선택한 항목을 **내리기**로 다운로드 폴더에 받습니다(파일 더블클릭도 같음). 우클릭 > "다른 위치로 내리기…"로 폴더를 고를 수 있습니다. 이 Mac의 같은 이름 파일은 덮어쓰지 않고 `이름 (1).txt`처럼 새 이름으로 받습니다.
- 전송 막대: 진행률(파일 크기 기준)과 취소, 끝난 내려받기는 Finder에서 보기. 취소하거나 실패한 내려받기 조각은 지웁니다. 올리기를 취소하면 서버에 일부만 올라간 파일이 남을 수 있습니다.
- Production 서버: 파일 탭을 열 때와 올리기 전에 접속과 같은 확인을 거칩니다(설정 > 일반).
- 안전장치
  - ssh 접속과 같은 키·Bastion 경로·인스턴스 ID 기준 호스트 키 검증을 씁니다. `BatchMode=yes`라 호스트 키를 대신 승인하지 않습니다. 처음 보는 서버는 "터미널로 접속해 확인" 버튼으로 터미널에서 직접 확인하세요.
  - 암호가 걸린 키는 묻지 않고 실패하므로 `ssh-add --apple-use-keychain <키 경로>`로 먼저 등록합니다.
  - 명령은 셸을 거치지 않고 sftp 배치 파일(0600, 끝나면 삭제)로 실행합니다. 경로는 절대 경로만 받아 큰따옴표로 감싸며, 줄바꿈·역슬래시가 들어간 이름은 거부해 다른 명령이 끼어들 수 없습니다.
  - 폴더를 옮길 때마다 새로 인증하지 않도록 ssh 연결 재사용(ControlMaster, 60초 유지)을 씁니다. 소켓은 `/tmp/ec2dock-<uid>`(소유자·0700 확인, 아니면 재사용 끔)에 인스턴스 ID별로 두어, IP가 다른 인스턴스로 넘어가도 기존 연결을 쓰지 않습니다.
- 아직 지원하지 않음: SSM 접속 서버, 목록에서 Finder로 끌어내기, 원격 파일 이름 바꾸기·삭제.

서버 목록 새로고침은 ⌘R입니다. ⌘←/⌘→는 터미널 탭끼리만 돌고(끝에서는 처음으로), 서버 정보는 ⌘0으로 갑니다. 넓게 보기는 서버 정보 ↔ 터미널을 오갈 때만 자동으로 바뀌고, 터미널 탭끼리 바꿀 때는 지금 상태를 유지합니다. ⌘←/⌘→는 터미널 탭이 열려 있을 때만 탭 이동에 쓰입니다(그동안 검색창의 줄 처음/끝 이동 대신 동작합니다).

### 설계서 대비 변경 사항

**캐시 IP로 접속 (설계서 7.4, 2.2 시나리오 A 변경, 사용자 결정 2026-10-15)**

설계서는 "접속 직전 대상 인스턴스를 반드시 재조회하고, 최신 정보를 확인할 수 없으면 오래된 공인 IP로 접속하지 않는다"고 정했지만, 로그인 없이 빠르게 접속하기 위해 "캐시 IP로 접속, 재조회는 사용자가 버튼을 누를 때만"으로 바꿨습니다.

- 위험: 자동 할당 공인 IP는 인스턴스 중지 시 반납되어 다른 AWS 고객에게 재할당될 수 있습니다. 캐시 IP가 오래되면 다른 서버로 접속을 시도할 수 있습니다.
- 완화: 호스트 키를 인스턴스 ID 기준(`HostKeyAlias`)으로 검증하므로, 이미 접속한 적 있는 서버라면 IP 주인이 바뀌었을 때 ssh가 인증 전에 중단합니다. 처음 접속하는 서버에서 호스트 키 확인 질문이 나오면 IP가 최신인지 "다시 조회"로 확인한 뒤 수락하세요. 호스트 키 검증은 어떤 경우에도 끄지 않습니다.
- IP·상태 캐시는 iCloud로 동기화하지 않으므로, 새 Mac에서는 처음에 한 번 새로고침해야 접속할 수 있습니다.

**내장 터미널**

설계서 3.2는 "자체 터미널 에뮬레이터"를 MVP 제외 항목으로 두었지만, 사용자 결정(2026-10-15)으로 내장 터미널을 **선택 가능한 열기 방식**으로 추가했습니다. iTerm2 연동은 그대로 유지됩니다.

SwiftTerm은 1.11.2로 고정했습니다. 1.12.0부터 Metal 셰이더가 포함되어 Xcode의 `metal` 컴파일러가 필요하기 때문입니다. Xcode로 빌드하게 되면 최신 버전으로 올릴 수 있습니다.

## 앱으로 설치

```bash
./scripts/build-app.sh
```

```bash
cp -R dist/EC2Dock.app /Applications/
```

ad-hoc 서명이라 이 Mac 전용입니다. 다른 Mac에 배포하려면 Developer ID 서명과 공증이 필요합니다. 자세한 내용은 `docs/DEPLOYMENT.md`를 참고하세요.

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
Packaging/                Info.plist, 엔타이틀먼트, 앱 아이콘
scripts/                  .app 번들·zip·dmg 생성, 아이콘 생성
docs/DEPLOYMENT.md        서명·공증·배포·iCloud 컨테이너 이전 가이드
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

3. 앱을 실행하면 서버가 없을 때 **시작 체크리스트**가 나옵니다. 설정(⌘,) > AWS 탭에서 **조회할 계정(프로필)**과 **조회 리전**을 고른 뒤 새로고침(⌘R)합니다.

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
