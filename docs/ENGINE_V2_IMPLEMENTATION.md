# Ring Engine v2 구현 안내

구현 범위는 이미지, PDF 페이지 처리·이미지 압축, PDF → DOCX, DOCX/Markdown/HTML/RTF 렌더링, 비디오 트림·목표 용량 압축·GIF/WebP다. 청사진의 추가 오디오 편집, XLSX/PPTX/EPUB, AI 마스킹 등은 이번 범위에 포함하지 않는다.

## 호출 경로

모든 최종 출력은 `RingEngine.shared.run(EngineJob(...))`으로 실행한다. 엔진 내부의 `to:` 함수는 트랜잭션의 임시 경로를 받는 구현 함수다. 기존 원형 메뉴에 이미지·PDF·문서·영상 작업을 연결했으며, 아래의 설정 패널을 거쳐 같은 트랜잭션 API를 호출한다.

## 앱에서 사용하기

- Finder의 **Ring으로 변환·편집**, 기존 사용자 단축키 또는 홈 화면의 **파일 열기…**로 연다. PDF 여러 개를 선택하면 병합 패널에서 순서를 바꾸고 파일을 추가·제거할 수 있다.
- 이미지 편집의 **압축**에서 무손실·목표 용량·품질을 선택한다. **크기 조절**은 픽셀/배율, **메타데이터**는 위치만/전체 촬영 정보를 제공한다. 기존 자르기의 종횡비와 JPEG MCU 안내를 유지한다.
- PDF 편집에 이미지 최적화 압축·병합·페이지 정리·분할을 제공한다. 페이지 번호는 UI에서 **1부터 시작**하며 엔진에 전달할 때만 0부터로 변환한다. 쉼표는 분할 파일 경계이고, 페이지 정리에서는 출력 순서다.
- 일반 문서의 변환 메뉴에서 PDF/PNG/JPEG/WebP를 고른 뒤 용지·여백·이미지 해상도를 지정한다. 영상의 편집 메뉴에서 트림/목표 용량 압축, 변환 메뉴에서 GIF/WebP와 구간·FPS·최대 변·목표 용량을 지정한다.
- 작업 중에는 진행률과 **작업 취소**를 표시한다. 검증·저장이 끝나면 같은 원의 중앙에서 초록 체크를 왼쪽 위 → 아래 꼭짓점 → 오른쪽 위 순서로 0.55초 동안 그린다. 별도 완료 패널 없이 약 0.8초 유지 후 링의 닫기 모션으로 사라진다. 원본 옆에 이름 충돌을 피한 새 결과를 저장한다.
- 범위·시간·용량 입력은 저장 전에 검사한다. 파일 선택창이 열려 있는 동안 링의 Esc 단축키를 해제해 선택창의 취소 동작에 맡긴다.

| EngineOperation | 입력·설정 | 출력 |
|---|---|---|
| `.encodeImage(format:intent:)` | JPEG/WebP/HEIC의 `.quality(0...1)` 또는 `.targetBytes(Int64)`; PNG는 무손실 크기 검사 | 파일 |
| `.cleanMetadata` | JPEG/PNG/WebP/HEIC/AVIF | 동일 포맷 파일 |
| `.edit(.resize(width:height:))` | 표시 방향 기준 픽셀 크기 | PNG |
| `.edit(.resizeScale(0.5))` | 표시 방향 기준 배율 | PNG |
| `.edit(.cropAspect(width:16,height:9))` | 중앙 종횡비 크롭 | PNG |
| `.edit(.crop(CGRect(...)))` | 0~1 정규화된 영역; JPEG는 MCU 밖으로 스냅 | JPEG 또는 PNG |
| `.convert(.pdf/.png/.jpg/.webp)` | 일반 문서는 확장자로 자동 라우팅; PDF → 이미지는 페이지별 300dpi | PDF 또는 페이지 폴더 |
| `.convert(.docx)` | PDF에 원본 페이지 보기와 Vision 표·문단/편집 텍스트 포함 | DOCX |
| `.pdfMerge(sources:uniformWidth:)` | 배열 순서대로 병합; nil=원래 폭, 0=선택 페이지 중 최대 폭, 양수=지정 폭(pt) | PDF |
| `.pdfPages([2,0,2])` | **0부터 시작**, 출력 순서; 중복·생략 허용 | PDF |
| `.pdfSplit([0...2,3...5])` | **0부터 시작**, 양 끝 포함 | PDF 폴더 |
| `.pdfSmartCompress(.init(...))` | 기본 이미지 최대 변 2000px, JPEG 품질 0.82 | PDF |
| `.renderDocument(format:options:)` | A4 기본, 여백 36pt, 이미지 200dpi; 설정 변경 가능 | PDF 또는 이미지 폴더 |
| `.video(.trim(start:end:))` | 초 단위 구간 | MOV |
| `.video(.compress(targetBytes:codec:))` | HEVC/H.264 선택 | MP4 |
| `.video(.animation(AnimationOptions(...)))` | GIF/WebP, FPS·최대 변·시작·길이·목표 바이트 | GIF/WebP |

```swift
let result = try await RingEngine.shared.run(.init(
    source: sourceURL,
    operation: .encodeImage(format: .webp, intent: .targetBytes(300_000))
))
```

## 보존·검증 방식

- **원자적 저장**: 목적 볼륨의 0700 `StagingWorkspace`에서 작업하고 검증 후 배타적 link/rename으로 게시한다. 이름 충돌 시 번호를 붙이며 원본을 교체하지 않는다. 실패·취소 시 작업 폴더를 정리한다. 빈 파일·심볼릭 링크·빈 결과 폴더를 게시하지 않는다.
- **목표 이미지 용량**: C `jpeg_mem_dest`, `WebPMemoryWriter`+`WebPMux`, ImageIO 메모리 버퍼에서 탐색한다. WebP는 `target_size` 6패스를 먼저 시도하고 최종 컨테이너 크기로 다시 검사한다. 품질 탐색 중 파일 쓰기는 없다. 충족 불가능한 목표는 오류로 종료한다.
- **메타데이터**: JPEG의 모든 스캔을 따라 EXIF/XMP/IPTC/주석을 제거하고 DCT 계수를 검사한다. PNG는 메타데이터 청크를 제거하고 IDAT 해시를 비교한다. WebP는 EXIF/XMP와 해당 VP8X 플래그를 제거하고 압축 페이로드를 비교한다. ICC와 색 해석용 마커는 유지한다.
- **HEIF**: iinf/iloc/iref/ipma를 패치하고 원래 슬롯에 `free`를 넣는다. Exif/XMP extent는 실제 바이트까지 0으로 소거한다. 파일 길이·idat/mdat 위치 및 남은 이미지 extent의 해시를 보존한다. 메타데이터가 mdat에 함께 있으면 전체 mdat 해시는 달라져야 하므로 **이미지 extent 해시**로 검증한다.
- **리사이즈**: vImage 고품질 8/16비트 리샘플링, 원래 RGB ICC/알파 유지. 자르기 후 JPEG는 DCT·양자화표를 검증한다.
- **PDF**: qpdf Page Helper로 상속 페이지 속성을 명시화하고 스트림을 보존한다. 일반 주석의 appearance 스트림을 유지하고 복제 페이지에는 주석 사전을 복사한다. 스마트 압축은 지원되는 큰 Image XObject만 수정한다. 다른 스트림(페이지 명령·글꼴·벡터 등)은 쓰기 전후 바이트 집합을 비교하고 텍스트·페이지 수·qpdf 구조 검사를 수행한다.
- **문서**: ZIP32 stored/DEFLATE·CRC와 OpenXML 파싱은 네이티브 코드로 처리한다. 비영구 WKWebView, 전체 URL 차단 규칙, CSP, 페이지 스크립트 비활성화, 탐색 차단을 사용한다. 엔진의 격리된 JavaScript만 문단을 이진 탐색하고 표 행·반복 머리글을 페이지별로 나눈다. WebKit 벡터 PDF를 만든 뒤 이미지 출력은 페이지별로 래스터화한다.
- **비디오**: 트림은 passthrough export를 사용한다. 압축은 오디오 96kbps와 컨테이너 여유를 제외한 비디오 비트레이트, 480p/720p/1080p 상한, VideoToolbox **하드웨어 필수** 설정을 사용한다. 초과 시 한 번 보정한다. 파일 크기·isPlayable·트랙·해상도·길이 오차(<0.1초)와 실제 한 프레임 디코딩을 확인한다.
- **움짤**: 프레임은 한 장씩 추출하고 vImage로 축소한다. GIF는 네이티브 RGB 히스토그램/median-cut 256색 팔레트와 Floyd–Steinberg 디더링을 사용한다. WebP는 libwebp 애니메이션 API를 직접 호출한다. 목표 초과 시 FPS·크기·품질을 제한된 횟수로 조정한다. 모든 출력 프레임의 디코딩·크기·재생 길이를 검사한다.
- **발열**: 매 작업 진입, 코덱 호출, 프레임 처리 시 현재 상태를 읽는다. 정상 상태는 전체 작업 최대 2개, 그 외·저전력은 1개다. 코덱 스레드는 정상 최대 4, fair/serious 2, critical/저전력 1이며 뜨거운 상태의 vImage 타일 병렬화도 제한한다. 상태를 강제로 바꾼 온도 실험은 수행하지 않았다.

## 지원 경계

- JPEG/HEIC는 손실 형식이다. `.lossless`로 다른 형식에서 이 포맷으로 인코딩하지 않는다. 명시적 `.quality`/`.targetBytes`를 사용한다. JPEG의 투명도는 흰색으로 합성한다. 목표 용량 때문에 해상도를 몰래 변경하지 않는다.
- WebP/JPEG 목표 인코딩은 RGB 8비트 입력을 받는다. 16비트 입력을 조용히 8비트로 낮추지 않는다. 리사이즈는 RGB 8/16비트를 지원한다. 기존 엔진의 HDR/게인맵·CMYK·다중 프레임 이미지 제한을 유지한다.
- 전체 EXIF 소거 시 JPEG/PNG에 저장된 방향 태그도 제거될 수 있다. 압축 픽셀은 그대로이며 결과 설명에 방향 태그 제거를 표시한다. 기존 `.removeLocation`은 방향 보존이 필요한 GPS 제거 경로로 남아 있다.
- HEIF는 외부 참조, construction method 2, 안전하게 패딩할 수 없는 레코드를 거부한다. 검증되지 않은 컨테이너를 추측해서 수정하지 않는다.
- PDF 폭 변경은 주석이 없는 페이지에 적용한다. 페이지 편집의 보존 범위는 선택한 페이지·리소스·스트림이다. 여러 문서의 책갈피·문서 수준 동작 등 모든 카탈로그 구조의 통합을 보장하지 않는다. qpdf가 잘못된 스트림 길이를 복구하면서 표시가 달라지는 PDF는 검증 실패로 게시하지 않는다.
- PDF 스마트 압축은 8비트 DeviceRGB/DeviceGray/ICCBased RGB의 JPEG/Flate 이미지 중 설정 크기를 넘는 항목을 대상으로 한다. 마스크·Decode 변환·CMYK·복잡한 필터·고비트 이미지는 원형을 유지한다. 인코딩된 이미지가 실제로 작아질 때만 교체하며 파일 전체가 커지면 원본을 복사한다.
- DOCX는 문단·기본 글꼴/강조·표·포함 이미지를 흐름 레이아웃으로 렌더링한다. Word의 모든 수식·차트·떠 있는 개체·변경 이력·정확한 페이지 조판을 재현하는 엔진은 아니다. Markdown은 제목·문단·강조·코드·목록을 지원한다. HTML 원격 리소스와 실행 콘텐츠는 제외한다. 한 페이지보다 큰 표 행/분할 불가능한 개체는 잘라 버리지 않고 오류로 종료한다.
- 문서 예산은 DOCX 64MB/펼친 크기 128MB, DOM 100,000노드/1,000페이지다. 결과 이미지에는 기존 52MP 버퍼 한도가 적용된다. 렌더링·OCR은 입력 구조와 Vision 인식 결과에 따라 재배치된다.
- 비디오 압축은 비디오 1개·오디오 최대 1개(모노/스테레오)를 처리한다. HDR은 명시적 톤 매핑 경로가 없으므로 거부한다. 하드웨어 인코더가 없으면 오류를 반환한다. passthrough 트림은 키프레임·샘플과 편집 목록을 사용하며 프레임 정밀 재인코딩 트림을 약속하지 않는다.
- GIF는 256색 형식이므로 모든 색/장면에서 밴딩이 전혀 없다고 보장할 수 없다. 애니메이션은 최대 1,800프레임·60fps·1920px이다. GIF는 누적 시각을 10ms 단위로 양자화해 프레임별 반올림에 따른 재생 길이 누적 오차를 막는다. 60fps GIF는 일부 뷰어의 짧은 지연 제한으로 느리게 재생될 수 있다.

## 검증 명령

```sh
zsh Tools/test-engine-v2.sh                 # 독립 생성 fixture로 전체 통합 검사
zsh Tools/test-engine-v2.sh image pdf       # 기능군 선택
zsh Tools/test-engine-v2.sh document media
zsh Tools/test-app-routing.sh              # 파일 분류, UI 범위/시간/용량 입력
zsh Tools/test-engine.sh .work/v2-regression --quick
zsh build.sh                               # arm64 + x86_64, 설치하지 않음
git diff --check
```

테스트·빌드 도구는 개발 환경에서만 사용한다. 앱 런타임은 macOS 프레임워크와 기존 정적 라이브러리뿐이며 FFmpeg/JRE/Perl/코덱 CLI를 추가하지 않는다.

## 확인한 결과 (2026-10-20)

실행 환경: arm64, macOS 27.0.1, Swift 6.2, macOS SDK 26.0. 수치는 합성 fixture 결과이며 일반적인 성능·압축률을 뜻하지 않는다.

- `Tools/test-engine-v2.sh` 전체 통합 검사 통과. JPEG/WebP/HEIC 32,000바이트 목표에서 각각 **31,825 / 30,412 / 30,059바이트**. 알파, 16비트 방향 보정 리사이즈, 5개 형식 메타데이터, JPEG MCU/DCT, 불가능 목표 롤백 검사 포함.
- PDF 병합·중복·재정렬·범위 분할·지정/자동 폭·주석 보존·WebP·Vision DOCX 검사 통과. RGB ICC 이미지 1개를 압축한 합성 PDF는 **12,160,105바이트 절감**했고 비이미지 스트림은 동일했다.
- HTML 긴 문단의 1,500개 단어를 모두 유지한 **15페이지** 페이지 분할, 표 헤더 반복·마지막 행, 스크립트 비실행, Markdown PNG, RTF, 독립 DEFLATE DOCX 검사를 통과했다. 렌더링된 PDF의 첫/마지막 페이지도 이미지로 확인했다.
- 2초 오디오 포함 영상의 1.1초 트림을 재생·길이·트랙으로 검증했고 출력 압축 샘플 해시가 원본에 포함됨을 확인했다. 80,000바이트 목표에서 H.264 **53,256**, HEVC **54,093바이트**. 1초 160×120/10fps GIF **125,902**, WebP **19,346바이트**. 즉시/10ms/50ms 취소 후 출력·staging 잔여 없음.
- 회전 페이지의 폭 균일화 보정 후 `Tools/test-engine-v2.sh pdf`를 추가 실행해 통과했다. 회전 90도 페이지는 출력 400×500pt 종횡비를 확인했다.
- 기존 `EngineTests --quick` 회귀 검사 통과: PNG/TIFF/JPEG/HEIC/BMP, GPS 제거, 8/16비트·방향·알파, 손상 입력 거부, 원본 보존.
- `build.sh` arm64/x86_64 유니버설 앱 빌드·서명 검증 통과. 이후 UI 이식을 포함한 0.2.0을 `/Applications/Ring.app`에 설치하고 Finder 확장도 등록했다. 커밋·푸시는 수행하지 않았다.

엔진 로그는 `.work/v2-final.log`, `.work/v2-pdf-final.log`, `.work/v2-regression.log`, `.work/v2-build.log`에 있다. 실행 중 취소에서 발견한 AVFoundation 시작/강제 취소 경쟁은 협력적 취소로 수정하고 재검증했다.

## 앱 이식·설치 검증 (2026-10-20)

- `Tools/test-app-routing.sh` 통과: 문서/영상 분류, 8칸 이하 메뉴, 다중 PDF 선택, 1-based 페이지 범위·역순/빈 값 거부, 용량·시간 입력 검사. 최종 UI 변경 후 유니버설 빌드·서명 검증을 다시 통과했다.
- 설치된 앱을 실제 조작해 이미지 32KB 목표 압축·320×240 리사이즈·전체 촬영 정보 삭제, Finder에서 PDF 2개 전달·병합 순서 변경·폭 균일화·페이지 `2,1,2`·`1,2` 분할을 확인했다. 잘못된 페이지 `0`은 인라인에서 거부했다.
- PDF 추가 선택창을 시트로 표시하고 Esc 취소/파일 추가 후 목록이 유지됨을 확인했다. 도구와 작업 진행 중 화면은 앱이 포커스를 잃어도 작업 내용을 유지하며, 링을 새로 열면 홈 창은 숨긴다.
- Markdown → A4 벡터 PDF 및 100dpi PNG를 확인했다. 2초 영상의 0.3~1.4초 트림, HEVC 80KB 목표, GIF 150KB 목표, 애니메이션 WebP를 저장했다. 영상 압축 결과는 54,093바이트, 10fps/160×120 GIF는 125,902바이트, WebP는 19,346바이트였다.
- GIF 처리 중 Esc 취소 안내, 충족 불가능한 영상 목표의 오류 안내 및 복귀를 확인했다. `.work/ui-verify.swift`로 원본 SHA-256, 출력 픽셀, PDF 순서·폭·분할 끝점, 한글 추출, 영상 isPlayable/한 프레임 디코딩·길이, GIF 디코딩·WebP 프레임 수, 취소/실패 후 잔여 없음까지 통과했다.
- 빌드본과 설치본 실행 파일의 SHA-256이 같으며 앱·Finder 확장 모두 arm64/x86_64다. 기존 단축키/자동 실행/힌트 설정을 유지했다. Finder 우클릭·홈 파일 선택은 실행 확인했고, 전역 단축키의 실제 키보드 입력은 이번 UI 자동화의 확인 범위에 포함하지 않는다.
- 이전 설치본은 `.work/installed-backups/20261020-213040-64471/Ring.app`에, UI 선택창 수정 전 0.2.0은 `.work/installed-backups/20261020-214121-66808/Ring.app`에 보관했다.

앱 검증 로그는 `.work/ui-routing.log`, `.work/ui-build.log`, `.work/ui-install.log`, `.work/ui-output-verification.log`에 있다. 합성 테스트 입력/결과만 `.work/ui-smoke`에 저장했으며 사용자의 실제 문서는 변환하지 않았다.

완료 UX 변경 후 유니버설 빌드·서명·설치를 다시 검증했다. 설치본에서 합성 PNG → JPEG 변환을 실행해, 같은 허브 안의 초록 체크가 짧은 선에서 오른쪽 위까지 이어지는 4개 프레임과 자동 닫힘을 확인했다. 완료 시 썸네일·진행률·취소 버튼이 사라지며 별도 결과 패널은 생성하지 않는다. 타이밍은 체크 그리기 0.55초, 완료 표시 전체 1.35초 후 기존 닫기 모션이다. 최신 빌드·설치 로그는 `.work/ui-check-build.log`, `.work/ui-check-install.log`다.
