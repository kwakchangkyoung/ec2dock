# EC2Dock --- macOS 전용 AWS 서버 접속 관리 앱

## 제품 요구사항 및 개발 설계서

-   문서 버전: 1.0
-   작성일: 2026-10-15
-   상태: 개발 착수용 설계 초안
-   대상 개발 환경: macOS, Xcode, Swift/SwiftUI
-   대상 개발자 도구: Codex, Claude Code, Cursor 등

------------------------------------------------------------------------

## 1. 프로젝트 개요

### 1.1 제품 한 줄 설명

EC2Dock은 AWS EC2 인스턴스를 자동으로 검색하고, IP 변경에 대응하며,
Direct SSH / Bastion(ProxyJump) / AWS Systems Manager Session
Manager(SSM) 접속을 하나의 macOS 네이티브 앱에서 관리하는 개발자용
도구다.

### 1.2 해결하려는 문제

현재 사용자는 AWS EC2 서버에 SSH로 자주 접속하며, 다음과 같은 불편을
겪는다.

1.  EC2 인스턴스를 중지했다가 다시 시작하면 자동 할당된 공인 IP가 바뀔
    수 있다.
2.  IP를 바꿀 때 iTerm2 프로필이나 SSH 설정을 수동으로 수정해야 한다.
3.  집과 회사의 Mac에서 서버 목록과 접속 설정을 각각 관리해야 한다.
4.  공개 서브넷의 서버, Bastion을 통한 사설 서버, SSM 접속 대상이
    혼재되어 있다.
5.  서버가 늘어날수록 계정, 리전, 사용자명, SSH 키, 포트, 점프 서버를
    관리하기 번거롭다.

### 1.3 제품 목표

-   AWS 계정 및 리전별 EC2 목록 자동 조회
-   AWS 인스턴스 ID를 기준으로 서버를 식별하여 IP 변경에 대응
-   접속 직전에 현재 인스턴스 상태와 IP를 재확인
-   Direct SSH, Bastion SSH, SSM을 공통 UI에서 실행
-   기존 iTerm2 사용 경험 유지
-   집과 회사 Mac 사이에 서버 프로필 및 사용자 설정 동기화
-   AWS 인증 정보와 SSH 개인키는 동기화 대상에서 제외
-   최소 권한과 호스트 키 검증 등 안전한 접속 기본값 제공

### 1.4 제품 범위 원칙

첫 버전은 AWS 운영 플랫폼 전체를 구현하지 않는다. 핵심 가치는 **서버를
찾아 접속하는 데 드는 반복 작업을 줄이는 것**이다.

우선순위: 1. AWS 인스턴스 자동 조회 2. 서버 검색 및 즐겨찾기 3. 접속
직전 최신 정보 확인 4. iTerm2를 통한 SSH 접속 5. 로컬 접속 설정 저장 6.
iCloud Drive 설정 동기화 7. Bastion 및 SSM 지원 강화

------------------------------------------------------------------------

## 2. 사용자 및 주요 사용 시나리오

### 2.1 주요 사용자

-   AWS EC2를 자주 사용하는 백엔드/인프라 개발자
-   여러 AWS 계정 및 리전을 관리하는 개발자
-   집과 회사 등 여러 Mac을 사용하는 개발자
-   SSH 직접 접속과 사설망 접속을 혼합해서 사용하는 운영자

### 2.2 시나리오 A: IP가 바뀐 EC2 접속

1.  사용자가 EC2Dock을 연다.
2.  앱은 캐시된 서버 목록을 즉시 표시한다.
3.  백그라운드에서 AWS 인스턴스 정보를 새로 조회한다.
4.  사용자가 서버를 선택하고 Connect를 누른다.
5.  앱은 계정 ID, 리전, 인스턴스 ID를 기준으로 해당 인스턴스를 다시
    조회한다.
6.  인스턴스가 실행 중인지, 필요한 IP가 있는지 확인한다.
7.  현재 IP로 SSH 명령을 구성하고 iTerm2에서 실행한다.
8.  이전 IP를 계속 사용하지 않는다.

### 2.3 시나리오 B: Bastion을 통한 사설 EC2 접속

1.  사용자가 사설 인스턴스를 선택한다.
2.  프로필에 연결된 Bastion 프로필을 확인한다.
3.  Bastion 및 대상 인스턴스의 현재 접속 정보를 조회한다.
4.  SSH `ProxyJump` 설정을 구성한다.
5.  대상 인스턴스의 사설 IP로 접속한다.
6.  각 홉에 필요한 사용자명과 키 설정을 각각 적용한다.

### 2.4 시나리오 C: SSM 접속

1.  사용자가 SSM 접속 프로필을 선택한다.
2.  앱은 인스턴스 ID, AWS 프로필, 리전을 확인한다.
3.  AWS CLI 및 Session Manager Plugin의 사용 가능 여부를 확인한다.
4.  사용자 권한과 대상 인스턴스의 SSM 사전 설정이 충족되어 있으면 세션을
    시작한다.
5.  조건이 충족되지 않으면 구체적인 오류 원인과 점검 항목을 표시한다.

### 2.5 시나리오 D: 집과 회사 Mac 사이 동기화

1.  사용자가 두 Mac에서 동일한 iCloud 계정을 사용한다.
2.  EC2Dock은 iCloud 컨테이너의 서버 프로필 데이터를 읽고 쓴다.
3.  서버 별칭, 그룹, 즐겨찾기, 논리적 접속 설정을 공유한다.
4.  각 Mac의 SSH 키 파일 경로와 로컬 AWS CLI 프로필 연결은 로컬에 따로
    저장한다.
5.  동시에 수정된 데이터는 자동으로 조용히 덮어쓰지 않고 충돌로
    처리한다.

------------------------------------------------------------------------

## 3. 제품 요구사항

### 3.1 MVP 필수 기능

  -----------------------------------------------------------------------------------
  ID                기능              설명                          우선순위
  ----------------- ----------------- ----------------------------- -----------------
  FR-001            AWS 프로필 선택   로컬 AWS CLI 프로필 선택      P0

  FR-002            계정 확인         `sts get-caller-identity`로   P0
                                      계정 ID 확인                  

  FR-003            EC2 목록 조회     지정 리전의 인스턴스 및 태그  P0
                                      조회                          

  FR-004            서버 검색         이름, 인스턴스 ID, 태그로     P0
                                      검색                          

  FR-005            즐겨찾기          자주 쓰는 서버 표시           P0

  FR-006            최신 IP 조회      Connect 직전에 대상 인스턴스  P0
                                      재조회                        

  FR-007            Direct SSH        현재 공인 IP 또는 설정된      P0
                                      호스트로 접속                 

  FR-008            iTerm2 연동       새 창/탭에서 SSH 명령 실행    P0

  FR-009            로컬 설정         사용자명, 키 경로, 포트 등    P0
                                      저장                          

  FR-010            오류 안내         중지 상태, IP 없음, 인증 실패 P0
                                      등 안내                       

  FR-011            iCloud 동기화     서버 프로필과 사용자 설정     P1
                                      동기화                        

  FR-012            Bastion SSH       `ProxyJump`로 사설 서버 접속  P1

  FR-013            SSM               AWS CLI로 Session Manager     P1
                                      세션 시작                     

  FR-014            환경 보호         Production 접속 전 확인       P1

  FR-015            Terminal 대체     iTerm2 미설치/실패 시         P2
                    지원              Terminal 또는 명령 복사       
  -----------------------------------------------------------------------------------

### 3.2 MVP에서 제외할 기능

초기 버전에서 아래 기능은 구현하지 않는다.

-   EC2 생성/중지/재부팅/종료 등 변경 작업
-   보안 그룹 및 IAM 정책 수정
-   자체 터미널 에뮬레이터
-   SSH 개인키를 iCloud로 동기화
-   앱 서버를 통한 AWS 자격 증명 중계
-   팀 전체의 인증 정보 공유
-   자동으로 호스트 키 검증을 비활성화하는 기능
-   AI 기반 장애 진단
-   Windows 버전

------------------------------------------------------------------------

## 4. 기술 스택 및 아키텍처

### 4.1 권장 기술

-   언어: Swift
-   UI: SwiftUI
-   비동기 작업: Swift Concurrency (`async/await`)
-   AWS 초기 연동: AWS CLI subprocess
-   AWS 장기 대안: AWS SDK for Swift
-   SSH: macOS에 설치된 OpenSSH 실행
-   SSH 점프: OpenSSH `ProxyJump`
-   SSM: AWS CLI `ssm start-session` + Session Manager Plugin
-   터미널: iTerm2 AppleScript 우선, macOS Terminal 대체 지원
-   보안 비밀 저장: macOS Keychain
-   동기화: iCloud Drive 앱 전용 컨테이너
-   로컬 캐시: SQLite 또는 SwiftData
-   설정 직렬화: Codable JSON

### 4.2 아키텍처 개요

``` text
EC2DockApp
  └── AppState
      ├── AWSDiscoveryService
      │   ├── AWS CLI profile discovery
      │   ├── Caller identity verification
      │   ├── EC2 instance discovery
      │   └── Region discovery (optional)
      ├── ConnectionManager
      │   ├── DirectSSHConnectionService
      │   ├── BastionSSHConnectionService
      │   ├── SSMConnectionService
      │   └── TerminalLauncher
      ├── ServerProfileStore
      ├── LocalSettingsStore
      ├── KeychainService
      └── SyncService
```

### 4.3 모듈 책임

#### AWSDiscoveryService

-   AWS CLI 프로필을 선택해 호출한다.
-   현재 AWS 계정 ID를 확인한다.
-   지정 리전의 인스턴스 목록을 조회한다.
-   응답을 도메인 모델로 변환한다.
-   API 오류, 자격 증명 만료, 권한 부족을 구분해 전달한다.
-   페이지네이션 및 여러 리전 조회를 지원할 수 있게 설계한다.

#### ConnectionManager

-   접속 방식에 따라 알맞은 연결 서비스로 위임한다.
-   Connect 직전에 인스턴스 상태 및 접속 주소를 검증한다.
-   Production 서버 접속 전 확인 정책을 적용한다.
-   접속 로그에는 비밀 값이나 전체 인증 명령을 기록하지 않는다.

#### TerminalLauncher

-   iTerm2 실행 여부를 확인한다.
-   안전하게 구성된 명령을 새 세션에서 실행한다.
-   AppleScript 실행 실패 또는 Automation 권한 거부를 처리한다.
-   대체로 Terminal 실행 또는 명령 복사를 제공한다.

#### SyncService

-   iCloud 컨테이너의 프로필 파일을 읽고 쓴다.
-   파일 접근을 `NSFileCoordinator` 등으로 조정한다.
-   파일 버전과 수정 시각을 관리한다.
-   충돌이 생기면 조용히 덮어쓰지 않고 사용자에게 해결 방법을 제시한다.

#### LocalSettingsStore

-   Mac마다 다른 AWS CLI 프로필 매핑과 SSH 키 경로를 저장한다.
-   iCloud 동기화 파일과 분리한다.
-   로컬 캐시와 사용자 설정을 구분한다.

------------------------------------------------------------------------

## 5. SwiftUI 화면 설계

### 5.1 메인 창

권장 레이아웃: `NavigationSplitView`

-   사이드바
    -   All Servers
    -   Favorites
    -   Production
    -   Development
    -   AWS Accounts
    -   Settings
-   서버 목록
    -   이름
    -   실행 상태
    -   계정 별칭 및 리전
    -   환경 태그
    -   접속 방식
-   상세 패널
    -   인스턴스 ID
    -   현재 공인/사설 IP
    -   인스턴스 상태
    -   마지막 조회 시간
    -   Connect 버튼
    -   접속 설정 편집

### 5.2 화면별 요구사항

#### DashboardView

-   로컬 캐시를 먼저 보여준다.
-   AWS 새로고침 상태를 표시한다.
-   검색과 필터를 제공한다.
-   인스턴스가 종료/중지된 경우 시각적으로 구분한다.
-   IP가 없을 경우 Direct SSH 접속을 비활성화한다.

#### ServerDetailView

-   AWS에서 가져온 정보와 사용자가 직접 지정한 정보를 시각적으로
    구분한다.
-   Connect 클릭 시 최신 정보를 조회한다.
-   Production 서버 접속 시 서버 이름과 환경을 다시 확인할 수 있다.
-   접속 실패 시 원인과 다음 점검 단계를 표시한다.

#### ConnectionSettingsView

-   접속 방식: Direct SSH / Bastion SSH / SSM
-   SSH 사용자명
-   SSH 포트
-   키 프로필 별칭
-   Bastion 프로필 선택
-   AWS 프로필 매핑
-   터미널 선택
-   연결 타임아웃

#### PreferencesView

-   기본 AWS CLI 프로필
-   기본 리전 및 리전 목록
-   기본 터미널
-   자동 새로고침 간격
-   Production 접속 확인
-   iCloud 동기화 상태
-   로그 수준(비밀 정보 제외)

------------------------------------------------------------------------

## 6. 데이터 모델

### 6.1 식별자 원칙

인스턴스의 이름 태그는 변경 또는 중복될 수 있다. 서버의 안정적인
식별자는 다음 조합으로 정의한다.

`AWS account ID + region + instance ID`

### 6.2 ServerProfile.swift

``` swift
import Foundation

enum ConnectionType: String, Codable {
    case directSSH
    case bastionSSH
    case ssm
}

struct ServerProfile: Codable, Identifiable, Equatable {
    var id: String {
        "\(accountID):\(region):\(instanceID)"
    }

    var accountID: String
    var accountAlias: String
    var region: String
    var instanceID: String

    var displayName: String
    var environment: String
    var groupName: String
    var isFavorite: Bool

    var connectionType: ConnectionType
    var sshUsername: String
    var sshPort: Int
    var bastionProfileID: String?

    var createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int
}
```

### 6.3 EC2Instance.swift

AWS에서 조회한 실시간 상태는 사용자 설정과 별도의 모델로 둔다.

``` swift
import Foundation

struct EC2Instance: Identifiable, Equatable {
    var id: String { "\(accountID):\(region):\(instanceID)" }

    var accountID: String
    var region: String
    var instanceID: String
    var name: String?

    var state: String
    var publicIPAddress: String?
    var privateIPAddress: String?
    var availabilityZone: String?
    var instanceType: String?
    var tags: [String: String]

    var lastFetchedAt: Date
}
```

AWS가 반환하는 현재 상태와 IP는 캐시 가능한 관측 데이터다. 사용자가
설정한 별칭, 즐겨찾기, 접속 방식과 같은 설정 값과 섞어 저장하지 않는다.

### 6.4 LocalConnectionSettings.swift

``` swift
import Foundation

struct LocalConnectionSettings: Codable, Identifiable {
    var id: String { profileID }

    var profileID: String
    var awsCLIProfileName: String
    var sshKeyPath: String?
    var terminalIdentifier: String
    var connectTimeoutSeconds: Int
}
```

이 데이터는 로컬에만 저장한다. SSH 개인키 자체나 AWS 비밀 키는 이 모델에
넣지 않는다. 키 파일 경로도 다른 Mac에서 유효하지 않을 수 있으므로
iCloud 동기화 대상에서 제외한다.

### 6.5 저장 위치

  데이터                                  저장 위치
  --------------------------------------- ---------------------------------
  서버 별칭, 계정 ID, 리전, 인스턴스 ID   iCloud Drive
  즐겨찾기, 그룹, 논리적 접속 방식        iCloud Drive
  Bastion 프로필 참조                     iCloud Drive
  AWS CLI 프로필의 로컬 매핑              로컬 설정
  SSH 키 파일 경로                        로컬 설정
  SSH 개인키                              기존 로컬 키 파일
  AWS 인증 정보                           AWS CLI 인증 체계 또는 Keychain
  현재 IP/상태 캐시                       로컬 SQLite/SwiftData

------------------------------------------------------------------------

## 7. AWS 인스턴스 자동 조회

### 7.1 조회 흐름

1.  사용자가 AWS CLI 프로필을 선택한다.
2.  `sts get-caller-identity`로 현재 계정 ID를 확인한다.
3.  허용된 리전 목록을 순회한다.
4.  `ec2 describe-instances`로 인스턴스를 조회한다.
5.  응답을 `EC2Instance` 모델로 변환한다.
6.  서버 프로필과 조합해 UI를 갱신한다.
7.  Connect 클릭 시 대상 인스턴스를 다시 조회한다.

### 7.2 CLI 예시

``` bash
aws sts get-caller-identity \
  --profile production \
  --output json
```

``` bash
aws ec2 describe-instances \
  --profile production \
  --region ap-northeast-2 \
  --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{
    InstanceId:InstanceId,
    Name:Tags[?Key==`Name`]|[0].Value,
    PublicIP:PublicIpAddress,
    PrivateIP:PrivateIpAddress,
    State:State.Name,
    InstanceType:InstanceType,
    AZ:Placement.AvailabilityZone,
    Tags:Tags
  }' \
  --output json
```

### 7.3 AWS 호출 구현 주의사항

-   Swift에서 `Process`를 사용해 AWS CLI를 실행할 수 있다.
-   인자 배열을 사용하고, 사용자 입력값을 shell 문자열에 이어 붙여
    실행하지 않는다.
-   stdout과 stderr를 별도로 수집한다.
-   종료 코드, 타임아웃, 취소 처리를 구현한다.
-   출력 JSON 파싱 실패를 사용자에게 이해 가능한 오류로 변환한다.
-   `aws` 실행 파일 경로는 고정 가정하지 말고 설정 또는 안전한 경로
    탐색을 제공한다.
-   자격 증명 만료와 권한 부족을 구분한다.
-   여러 리전 조회 시 호출을 제한하고 취소 가능한 작업으로 구현한다.
-   AWS CLI가 설치되어 있지 않으면 설치 안내를 표시한다.
-   계정 ID가 예상과 다르면 접속 전에 경고한다.

### 7.4 캐시 정책

-   앱 시작 시 로컬 캐시를 즉시 표시한다.
-   백그라운드에서 AWS 데이터를 갱신한다.
-   사용자가 새로고침을 요청하면 재조회한다.
-   접속 직전에는 대상 인스턴스를 반드시 재조회한다.
-   AWS 조회에 실패하면 캐시 데이터의 시각을 표시한다.
-   최신 정보를 확인할 수 없을 때 오래된 공인 IP로 무조건 접속하지
    않는다.

------------------------------------------------------------------------

## 8. SSH 및 iTerm2 연동

### 8.1 Direct SSH

접속 직전에 최신 공인 IP를 조회하고 아래와 같은 인자를 구성한다.

``` text
ssh
-i
/path/to/key.pem
-o
IdentitiesOnly=yes
-o
ConnectTimeout=10
-p
22
ec2-user@CURRENT_PUBLIC_IP
```

실제 구현에서는 `Process.arguments`와 같이 인자 배열을 사용한다. shell
문자열로 합쳐 `sh -c`에 전달하는 방식은 피한다.

### 8.2 Bastion / ProxyJump

개념적인 예:

``` bash
ssh \
  -i ~/.ssh/target.pem \
  -J ec2-user@bastion.example.com \
  ec2-user@10.0.12.34
```

실제 구현에서는 다음을 고려한다.

-   Bastion과 대상 서버의 사용자명이 다를 수 있다.
-   각 홉에서 서로 다른 키를 사용해야 할 수 있다.
-   `ProxyJump`를 지원하는 OpenSSH 버전을 확인한다.
-   Bastion도 별도의 서버 프로필로 관리한다.
-   사설 IP는 인터넷에서 직접 접근할 수 없으므로 경유 연결을 사용한다.
-   접속 경로가 잘못 설정된 경우 명확한 오류를 표시한다.

키가 서로 다른 Bastion/대상 서버 조합은 명령행 옵션만으로 복잡해질 수
있다. 필요하면 앱 전용 SSH config 파일을 생성해 `Host`, `IdentityFile`,
`ProxyJump`를 관리하되, 파일 권한을 제한하고 민감 정보가 들어가지 않도록
한다.

### 8.3 SSM

예시:

``` bash
aws ssm start-session \
  --target i-0123456789abcdef0 \
  --profile production \
  --region ap-northeast-2
```

사전 조건: - 인스턴스에서 SSM Agent가 정상 동작 - 적절한 인스턴스 역할
및 SSM 권한 - 네트워크 연결 및 필요한 엔드포인트 접근 - 로컬 AWS CLI와
Session Manager Plugin 사용 가능 - 호출 사용자에게 해당 인스턴스의
세션을 시작할 권한 부여

SSM 세션은 일반 SSH와 다른 방식이다. 첫 버전에서는 iTerm2에서 AWS CLI
명령을 실행하는 형태로 지원하고, 별도 SSH-over-SSM 설정은 후속 버전에서
검토한다.

### 8.4 iTerm2 연동

가능한 방식: - AppleScript로 iTerm2를 활성화하고 새 창/탭을 만든다. -
명령은 검증된 인자에서 구성한다. - 사용자 입력을 shell 명령 문자열에
직접 삽입하지 않는다. - AppleScript 자동화 권한 거부 및 앱 미설치 상태를
처리한다. - 실패 시 macOS Terminal 또는 명령 복사를 대안으로 제공한다.

개념적인 AppleScript 예:

``` applescript
tell application "iTerm2"
    activate
    create window with default profile
    tell current session of current window
        write text "ssh ec2-user@203.0.113.10"
    end tell
end tell
```

위 예시는 연동 아이디어를 보여주기 위한 것이다. 실제 앱에서는 주소와
명령을 안전하게 인코딩해야 하며, 사용자 입력으로 AppleScript를 조립할
때는 명령 삽입 취약점을 방지해야 한다.

### 8.5 SSH 호스트 키 검증

-   `StrictHostKeyChecking=no`를 기본값으로 사용하지 않는다.
-   `known_hosts` 검증을 유지한다.
-   IP 변경 후 호스트 키 불일치가 생기면 경고한다.
-   호스트 키 불일치를 자동으로 삭제하거나 무시하지 않는다.
-   가능하면 DNS 이름 또는 SSM처럼 IP에 덜 의존하는 접속 방식을
    제공한다.

------------------------------------------------------------------------

## 9. iCloud Drive 동기화 설계

### 9.1 동기화 대상

동기화할 데이터: - 서버 별칭 - 계정 ID 및 논리적 계정 별칭 - 리전과
인스턴스 ID - 그룹, 환경, 즐겨찾기 - 접속 방식과 Bastion 프로필 참조 -
사용자 지정 SSH 사용자명/포트 등 비밀이 아닌 설정

동기화하지 않을 데이터: - AWS Secret Access Key - 세션 토큰 - SSH
개인키 - Keychain 내용 - 로컬 키 파일 경로 - 로컬 AWS CLI 인증 캐시 -
기기별 경로 및 상태 캐시

회사 정책에 따라 계정 ID, 내부 IP, 서버 이름도 민감한 운영 정보일 수
있다. iCloud 동기화가 허용되는지 먼저 확인한다.

### 9.2 저장 방식

MVP는 앱 전용 iCloud 컨테이너 내 JSON 파일 하나로 시작할 수 있다.

예시 구조:

``` text
iCloud Drive/
└── EC2Dock/
    └── ServerProfiles.json
```

실제 앱에서는 앱의 iCloud 컨테이너를 사용한다. 파일 접근은
`NSFileCoordinator`로 조정하고, iCloud 파일의 다운로드/업로드 상태와
오류를 처리한다.

### 9.3 충돌 처리

각 프로필에 다음 필드를 포함한다. - `schemaVersion` - `createdAt` -
`updatedAt` - 가능하면 변경 식별자

두 Mac이 동시에 같은 프로필을 변경하면 수정 시각만 비교해 조용히
덮어쓰지 않는다. MVP에서는 충돌된 항목을 표시하고 다음 중 하나를
선택하도록 한다. - 현재 Mac의 변경 사용 - iCloud 버전 사용 - 두 버전을
비교한 후 수동 병합

JSON 파일이 커지거나 충돌이 빈번해지면 프로필별 파일 또는 CloudKit 기반
저장으로 확장할 수 있다.

------------------------------------------------------------------------

## 10. 보안 요구사항

### 10.1 인증 및 권한

-   우선 기존 AWS CLI 인증을 사용한다.
-   가능하면 IAM Identity Center 또는 역할 기반 임시 자격 증명을
    지원한다.
-   EC2 조회 권한은 읽기 전용으로 제한한다.
-   SSM 접속 권한은 별도 정책으로 분리한다.
-   앱이 불필요한 EC2 변경 권한을 요구하지 않는다.
-   AWS 계정 ID와 선택한 프로필이 일치하는지 확인한다.

### 10.2 비밀 정보

-   SSH 개인키를 앱 번들, iCloud 파일, 로그에 넣지 않는다.
-   AWS 비밀 키를 JSON 설정에 저장하지 않는다.
-   Keychain은 앱 자체의 민감한 설정 저장에 사용한다.
-   기존 SSH 키 파일의 권한을 확인한다.
-   명령행, 로그, 오류 보고서에 자격 증명이 노출되지 않도록 한다.

### 10.3 명령 실행 보안

-   `Process`에 인자 배열을 전달한다.
-   `sh -c`에 사용자 입력을 조합하지 않는다.
-   인스턴스 ID, 리전, 사용자명, 포트 형식을 검증한다.
-   AppleScript 문자열 이스케이프를 안전하게 처리한다.
-   연결 타임아웃과 프로세스 취소를 지원한다.
-   외부 명령의 stdout/stderr에서 비밀 값을 필터링한다.

### 10.4 Production 보호

-   Production 환경 접속 시 확인 창을 제공한다.
-   확인 창에 서버 이름, AWS 계정 별칭, 리전, 인스턴스 ID를 표시한다.
-   운영 서버 접속 이력은 비밀 값을 제외하고 로컬에 기록할 수 있다.
-   서버 중지/종료/보안 그룹 변경 같은 쓰기 작업은 MVP에 포함하지
    않는다.

------------------------------------------------------------------------

## 11. 오류 처리 및 사용자 경험

  상황                   앱 동작
  ---------------------- ----------------------------------------
  AWS CLI 없음           설치 또는 경로 설정 안내
  AWS 자격 증명 만료     재인증 방법 안내
  권한 부족              필요한 API/권한 이름 안내
  인스턴스 중지          접속 버튼 비활성화, 상태 표시
  공인 IP 없음           Bastion 또는 SSM 설정 안내
  IP 변경                최신 IP로 접속 구성
  iTerm2 없음            Terminal 또는 명령 복사 대안
  Automation 권한 거부   macOS 개인정보 보호 설정 안내
  SSH 키 파일 없음       로컬 키 경로 설정 요청
  SSH 인증 실패          사용자명/키/권한 점검 안내
  Host key mismatch      접속 중단 및 안전한 검증 안내
  Bastion 연결 실패      Bastion 상태와 네트워크 경로 점검 안내
  SSM 세션 실패          Agent, IAM, 네트워크, Plugin 점검 안내
  iCloud 동기화 실패     로컬 모드로 계속 사용하고 상태 표시
  동기화 충돌            충돌 해결 UI 제공

------------------------------------------------------------------------

## 12. 테스트 계획

### 12.1 단위 테스트

-   AWS CLI JSON 응답 파싱
-   태그에서 Name 및 Environment 추출
-   서버 프로필 ID 생성
-   IP가 없는 인스턴스 처리
-   접속 방식에 따른 명령 인자 생성
-   사용자명, 포트, 리전 유효성 검사
-   동기화 파일 버전 및 충돌 판단

### 12.2 통합 테스트

-   AWS CLI 프로필 선택 및 계정 ID 확인
-   여러 리전의 EC2 목록 조회
-   공인 IP가 바뀐 후 접속 정보 갱신
-   iTerm2 새 세션 생성
-   Bastion ProxyJump 연결
-   SSM 세션 실행
-   iCloud 파일 동기화 및 재실행 후 복구

### 12.3 보안 테스트

-   명령 삽입 시도 문자열 처리
-   AWS 자격 증명이 로그에 남지 않는지 확인
-   SSH 호스트 키 검증 유지
-   개인키가 iCloud 데이터에 포함되지 않는지 확인
-   Production 접속 확인이 우회되지 않는지 확인
-   계정/리전이 다른 동명 인스턴스를 혼동하지 않는지 확인

### 12.4 수동 테스트 환경

-   로컬 또는 개발용 EC2
-   공인 IP가 있는 테스트 인스턴스
-   Bastion과 사설 EC2가 있는 VPC
-   SSM Agent와 IAM 역할이 구성된 테스트 인스턴스
-   iTerm2 설치/미설치 환경
-   iCloud 동기화가 켜진 Mac 두 대

------------------------------------------------------------------------

## 13. 개발 단계 및 완료 기준

### Phase 1 --- 앱 골격 및 로컬 모델

완료 기준: - SwiftUI 앱이 실행된다. - 서버 목록/상세/설정 화면이 있다. -
샘플 서버 데이터를 표시한다. - 즐겨찾기와 검색이 동작한다.

### Phase 2 --- AWS 조회

완료 기준: - AWS CLI 프로필을 선택할 수 있다. - 계정 ID를 확인할 수
있다. - 선택한 리전의 EC2 목록이 표시된다. - 조회 실패 원인이 사용자에게
표시된다. - 마지막 조회 결과를 캐시로 보여준다.

### Phase 3 --- Direct SSH 및 iTerm2

완료 기준: - 접속 직전에 인스턴스를 재조회한다. - 현재 IP와 상태를
기준으로 명령을 구성한다. - iTerm2에서 새 세션이 열린다. - 키 파일
경로와 사용자명을 서버별로 설정할 수 있다. - 호스트 키 검증을
비활성화하지 않는다.

### Phase 4 --- Bastion 및 SSM

완료 기준: - Bastion 프로필을 참조해 ProxyJump 접속이 가능하다. - SSM
세션을 시작할 수 있다. - 각 방식의 사전 조건과 오류가 안내된다.

### Phase 5 --- iCloud 동기화

완료 기준: - 서버 별칭, 그룹, 즐겨찾기가 두 Mac에서 공유된다. - 개인키와
AWS 인증 정보는 동기화되지 않는다. - 파일 접근 충돌과 동기화 오류가
처리된다. - iCloud 사용 불가 시 로컬 모드로 작동한다.

### Phase 6 --- 베타 배포

완료 기준: - 실제 집/회사 환경에서 테스트했다. - 로그에 비밀 정보가
노출되지 않는다. - 코드 서명과 배포 방법을 결정했다. - 사용자 피드백을
수집할 수 있다.

대략적인 일정은 개인 개발 기준 6\~7주로 잡되, AWS 환경 구성과 iCloud
동기화 문제에 따라 조정한다.

------------------------------------------------------------------------

## 14. 향후 유료화 방향

무료 도구와 차별화하려면 단순히 EC2 목록을 표시하는 데 그치지 않고, 실제
운영자의 반복 작업을 줄여야 한다.

가능한 유료 기능: - 여러 AWS 계정 및 리전 통합 관리 - 복잡한 Bastion
체인 관리 - 프로필 동기화 및 백업 - 서버 그룹과 환경별 정책 - 접속 오류
진단 도우미 - 고급 검색과 단축키 - SSM 세션 관리 - 팀용 프로필 공유(인증
정보는 별도 보안 설계 필요)

초기에는 개인용 무료 버전으로 사용성을 검증하고, 고급 프로필 관리와 다중
계정 기능을 유료 기능으로 실험한다. 가격은 실제 사용자 인터뷰와 결제
의사 검증 후 결정한다.

------------------------------------------------------------------------

## 15. Codex 등 AI 코딩 도구에 전달할 작업 지침

아래 내용을 프로젝트의 `AGENTS.md` 또는 첫 번째 Codex 작업 프롬프트로
사용할 수 있다.

### 개발 지침

1.  이 문서를 제품 요구사항의 기준으로 삼는다.
2.  구현 전 현재 저장소 구조와 Xcode 프로젝트 설정을 확인한다.
3.  한 번에 모든 기능을 구현하지 않는다. Phase 1부터 단계적으로
    진행한다.
4.  SwiftUI UI와 AWS/SSH/iCloud 서비스 계층을 분리한다.
5.  실제 AWS 계정이 없어도 테스트할 수 있도록 샘플 데이터와 mock
    서비스를 만든다.
6.  외부 명령 실행은 인자 배열을 사용하며 사용자 입력을 shell 문자열로
    이어 붙이지 않는다.
7.  SSH 호스트 키 검증을 끄지 않는다.
8.  AWS 인증 정보와 SSH 개인키를 iCloud 동기화 파일에 넣지 않는다.
9.  실제 AWS 리소스 변경 작업을 구현하지 않는다.
10. 각 단계에서 빌드와 테스트를 실행하고, 변경 사항과 미완료 항목을
    요약한다.
11. 존재하지 않는 API나 라이브러리를 가정하지 말고 공식 문서와 현재 SDK
    버전을 확인한다.
12. 비밀 값, 계정 자격 증명, 전체 환경 변수를 로그로 출력하지 않는다.

### 첫 번째 Codex 작업 요청

> 이 설계서를 읽고 Phase 1만 구현해줘.
>
> 먼저 저장소와 Xcode 프로젝트 구조를 확인하고, 필요한 경우 프로젝트
> 초기 구성을 제안해줘. SwiftUI 기반으로 Dashboard, Server Detail,
> Preferences 화면을 만들고, `ServerProfile` 및 `EC2Instance` 모델을
> 구현해줘. AWS 호출, SSH 실행, iCloud 동기화는 아직 실제로 구현하지
> 말고 프로토콜과 mock 구현으로 분리해줘. 샘플 서버 목록, 검색,
> 즐겨찾기가 동작하도록 하고, 빌드 및 테스트 결과와 다음 단계 계획을
> 보고해줘.

------------------------------------------------------------------------

## 16. 공식 문서 참고 링크

구현 시 아래 공식 문서를 확인한다.

-   AWS CLI `describe-instances`:
    https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instances.html
-   AWS CLI `get-caller-identity`:
    https://docs.aws.amazon.com/cli/latest/reference/sts/get-caller-identity.html
-   AWS Systems Manager Session Manager:
    https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html
-   AWS SDK for Swift:
    https://docs.aws.amazon.com/sdk-for-swift/latest/developer-guide/
-   Apple SwiftUI: https://developer.apple.com/xcode/swiftui/
-   Apple File Coordination:
    https://developer.apple.com/documentation/foundation/filecoordination
-   Apple Keychain Services:
    https://developer.apple.com/documentation/security/keychain_services
-   iTerm2 AppleScript: https://iterm2.com/documentation-scripting.html
-   OpenSSH `ssh_config`: https://man.openbsd.org/ssh_config

------------------------------------------------------------------------

## 17. 최종 MVP 정의

EC2Dock MVP는 다음 사용자 흐름을 안정적으로 제공하면 성공으로 본다.

1.  AWS CLI 프로필을 선택한다.
2.  EC2 인스턴스 목록이 자동으로 표시된다.
3.  서버를 검색하거나 즐겨찾기에서 선택한다.
4.  앱이 접속 직전에 인스턴스의 최신 상태와 IP를 조회한다.
5.  설정된 Direct SSH, Bastion 또는 SSM 방식으로 접속한다.
6.  SSH 접속은 iTerm2에서 열리며 기존 호스트 키 검증을 유지한다.
7.  집과 회사 Mac에서 서버 메타데이터가 iCloud로 동기화된다.
8.  AWS 인증 정보와 SSH 개인키는 동기화되지 않는다.

**가장 먼저 구현할 범위는 AWS 조회 + 서버 목록 + Direct SSH + iTerm2
연동이다.** 이 흐름을 완성한 뒤 Bastion, SSM, iCloud 동기화를 추가한다.
