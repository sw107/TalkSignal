# Windows 검증 범위

Windows 11 x64 대상 준비판입니다. 실제 카톡 감지용 어댑터는 구현하지 않았으며,
실제 수신/폰 읽음/창을 닫은 상태의 감지 성공을 주장하지 않습니다.

## 원격 검사

워크플로: `.github/workflows/windows.yml` (수동 실행, 제한 15분).
환경: GitHub-hosted Windows Server 2025 x64 VM. 실제 Windows 11 데스크톱 VM이 아닙니다.
Mac에는 VM, SDK, 런타임을 설치하지 않고 소스 작성/원격 실행/결과 다운로드만 합니다.

- 이름 정규화·완전 일치·중복 거부, 가상 수신→읽음 상태 전환.
- 연동 없음/조회 불가/오래된 값과 확인된 0의 구분.
- 설정 저장/재시작, 잘못된 설정 저장 시 기존 값 보존, 손상된 파일 오류.
- 게시된 단일 EXE의 자체 테스트 실행.
- 실제 WinForms 설정창 생성, 컨트롤 변경/저장, 빈 이름 거부, 화면 캡처.
- 모든 아이콘의 네이티브 자원 생성/정리, NotifyIcon 생성/Visible 설정/정리.
- VM 안의 테스트 창을 실제 Win32로 열거하여 정확한 제목 선택/접두사 거부.
- VM의 현재 사용자 Run 값 쓰기/확인/삭제 후 원래 값 복구. 실제 재부팅 검증은 아님.
- 표시 미리보기가 실제 감지 상태를 변경하지 않음.

테스트는 합성 이름과 데이터만 사용합니다. 개인 카톡 설치/로그인/DB 복사/메모리 덤프는 하지 않습니다.
트레이 컴포넌트 생성 검사는 Windows 11 작업표시줄에서의 실제 표시·클릭 검증과 구분합니다.

## 실제 Windows PC에서 남은 작업

- 카톡 버전과 메타데이터 접근 방법 확인 후 이름·안 읽은 수만 읽는 어댑터 개발.
- 창을 닫은 상태에서 수신과 폰 읽음 동기화 검증.
- 검색하지 않은 상태와 동명 방이 있는 경우에 안전한 대상 대화창 열기.
- 실제 Windows 11의 트레이 클릭/숨겨진 아이콘, 100~200% DPI, 재부팅 자동 실행.

## 참고

- [GitHub runner images](https://github.com/actions/runner-images): windows-2025는 Windows Server 2025입니다.
- [Microsoft notification area](https://learn.microsoft.com/en-us/windows/win32/shell/notification-area): 트레이 아이콘.
- [Microsoft single-file deployment](https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/): self-contained 배포.

원격 검사 실행 결과는 작업 완료 시 아래에 기록합니다.
