# RightTime 첫 빌드 안내 (Mac 없이, 무료)

## 1. 현재 단계
개발 0단계: **빌드 파이프라인 점검**. 기능 개발 전에 "GitHub에서 빌드 → Windows에서 서명 → iPhone 15 Plus에 설치 → 실행"이 끝까지 되는지 확인한다.

## 2. 목적
- Mac 없이 iOS 앱을 설치할 수 있는지 실제로 확인한다.
- 알림 예약과 알림 탭 응답 시간 기록이 무료 서명 앱에서 동작하는지 확인한다. 이것이 자동 라벨링(Proposal 3.1)의 출발점이다.
- 이 단계가 통과하면 다음 단계로 센서 기록과 백그라운드 깨어남 점검(Feasibility)을 붙인다.

## 3. 필요한 파일
| 파일 | 역할 |
|---|---|
| `project.yml` | XcodeGen 설정. GitHub 빌드 서버가 이것으로 Xcode 프로젝트를 만든다 |
| `Sources/RightTimeApp.swift` | 앱 시작점, 알림 응답 처리 |
| `Sources/ContentView.swift` | 점검 화면 (권한 요청, 10초 뒤 시험 알림, 로그) |
| `Sources/LogStore.swift` | Xcode 콘솔 대신 앱 안에서 보는 로그 |
| `.github/workflows/build-ipa.yml` | GitHub Actions macOS 서버에서 서명 없는 `.ipa` 생성 |
| `.gitignore` | 생성 파일과 수집 데이터가 공개 저장소에 올라가지 않게 함 |

## 4. 코드
위 파일들이 전부다. 아직 Mac에서 빌드해 본 적이 없으므로, 첫 GitHub 빌드에서 오류가 나면 로그를 보고 고친다.

## 5. 실행 방법

**준비 (한 번만)**
1. 서명 전용 무료 Apple ID를 새로 하나 만든다(본 계정 비밀번호를 서드파티 도구에 넣지 않기 위해).
2. GitHub에서 **공개(Public)** 저장소 `RightTime`을 만든다. 공개여야 macOS 빌드가 무료다.
3. 이 폴더의 파일을 폴더 구조 그대로 저장소 `main` 브랜치에 올린다. (GitHub를 Claude에 연결하면 이 단계는 Claude가 대신 할 수 있다.)
4. Windows PC에 AltServer(AltStore 설치 도구)를 설치한다. 안내: https://faq.altstore.io
5. iPhone: 설정 > 개인정보 보호 및 보안 > 개발자 모드 켜기 (설치 시도 후에 메뉴가 나타날 수 있다).

**빌드와 설치 (코드 바꿀 때마다)**
1. `main`에 올리면 GitHub 저장소의 **Actions** 탭에서 `Build unsigned IPA`가 자동 실행된다(수동 실행도 가능).
2. 성공하면 실행 결과 페이지 아래 Artifacts에서 `RightTime-ipa`를 내려받아 압축을 풀면 `RightTime.ipa`가 나온다.
3. iPhone을 USB로 PC에 연결하고 AltServer(또는 AltStore)로 `RightTime.ipa`를 설치한다. 서명 전용 Apple ID로 로그인한다.
4. iPhone 설정에서 해당 개발자 앱을 신뢰하라는 안내가 나오면 따른다.

## 6. 예상 결과
1. 앱을 열면 로그에 `앱 실행`이 찍힌다.
2. `알림 권한 요청` → 허용 → `알림 권한: 허용`.
3. `10초 뒤 시험 알림 예약`을 누르고 홈 화면으로 나가면 10초 뒤 알림이 온다.
4. 알림을 탭하면 앱이 열리고 `알림 탭: 전달 후 N초`가 찍힌다.
5. 앱을 껐다 켜도 로그가 남아 있다.

## 7. 문제 확인 항목
- **GitHub 빌드 실패:** Actions 로그에서 빨간 단계의 마지막 오류 줄을 복사해 Claude에게 보낸다.
- **설치 실패:** AltServer 오류 문구, iPhone iOS 버전, 개발자 모드 상태를 확인한다.
- **앱이 안 열림:** 7일 서명이 만료됐는지 확인한다. AltStore에서 Refresh 하면 데이터는 유지된 채 다시 열린다.
- **알림이 안 옴:** iPhone 설정 > 알림 > RightTime 허용 여부, 집중 모드(방해 금지) 상태를 확인한다.
- **응답 시간이 기록되지 않음:** 알림을 지우지 않고 탭했는지 확인한다(지운 경우는 아직 기록하지 않는다).

## 주의
- 무료 서명 앱은 **7일마다 다시 서명**해야 한다. 데이터 수집 기간에는 갱신 날짜를 정해 두거나 AltStore 백그라운드 갱신을 켜 둔다.
- 기기당 사이드로드 앱은 3개까지다.
- 수집 데이터는 공개 저장소에 올리지 않는다.
