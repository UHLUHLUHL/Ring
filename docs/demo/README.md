# Ring 사용 예시

Ring **0.2.6**, 커밋 `4f3ae6d6937f29bbd41c0b7844ecf3666ddc61ec` 기준입니다. 제작 당시 로컬 HEAD와 GitHub `main`이 같은 커밋임을 확인했습니다.

- `ring-demo.webp`: GitHub README에 넣는 1440×960, 24초 반복 애니메이션.
- `ring-demo.json`: 이미지가 포함된 독립 Lottie 원본, 30fps. 외부 이미지·폰트 없이 재생됩니다.
- `index.html`: 로컬에서 바로 열 수 있는 Lottie 미리보기. 일시정지·다시 재생·구간 탐색을 지원합니다.
- `animation-data.js`: `file://`에서도 미리보기를 열 수 있도록 동일 JSON을 담은 스크립트입니다.

첫 장면은 파일 우클릭 → **Ring으로 변환·편집** → **JPG** 선택입니다. 두 번째는 영상 우클릭 → **WEBP** → 긴 변 **640 → 480px** → **저장**입니다. 마우스 이동, 클릭 표시, 완료 체크와 원본 옆 결과 파일을 보여줍니다.

변환 대기는 설명을 위해 압축했으며, 영상 처리 장면에 **처리 구간 빠르게 재생**을 표시합니다. 실제 처리 속도를 측정한 영상은 아닙니다.

## 화면과 샘플

링과 WebP 설정 패널은 해당 커밋의 `Sources/App` 뷰를 그대로 사용하는 별도 문서용 캡처 창에서 가져왔습니다. 설정에서 480px 프리셋을 실제로 클릭했고, 원본 엔진으로 480×270, 72프레임, 약 3초의 WebP 출력도 확인했습니다. Finder 배경, 파일 아이콘, 마우스와 시간 편집은 설명을 위한 구성입니다. 앱 소스·설치된 앱은 변경하지 않았습니다.

`source/captures`는 네이티브 화면, `source/backplate`는 설명 배경과 자막입니다. 문서용 캡처 창의 상태 버튼은 최종 화면에서 잘라냈습니다. 사진은 built-in image_gen으로 생성했고, 영상은 그 사진에 느린 카메라 확대를 적용한 샘플입니다. 개인 파일은 포함하지 않았습니다. 생성 프롬프트는 [MEDIA.md](source/MEDIA.md)에 기록했습니다.

## 다시 만들기

이 도구들은 문서 제작에만 사용하며 Ring 앱의 실행 의존성이 아닙니다. Node.js에서 `sharp`, `playwright`를 찾을 수 있어야 하며, WebP 인코딩에는 `img2webp`가 필요합니다. 패키지가 별도 디렉터리에 있으면 `NODE_PATH`를 지정할 수 있습니다. Chrome 경로는 `RING_DEMO_CHROME`으로 바꿀 수 있습니다.

```sh
node docs/demo/source/build-backplate.mjs
node docs/demo/source/build-animation.mjs
node docs/demo/source/render-webp.mjs
```

캡처를 새로 하려면 macOS 26 / Apple Silicon에서 `zsh docs/demo/source/build-capture.sh`로 별도 캡처 앱을 만들고, `.work/usage-demo/`에 `coast.png`, `coast.mp4`를 둡니다. 이 앱을 열어 상태 1~5와 상태 6의 640px·480px 패널을 캡처합니다. 배경색과 크롭 좌표는 `build-animation.mjs`에 있습니다. 생산 앱을 빌드·설치하는 과정은 필요하지 않습니다.

프레임 렌더와 인코딩 중간 파일은 Git에서 제외된 `.work/usage-demo/frames`에 저장합니다. Lottie 플레이어는 `lottie-web` **5.13.0**, MIT 라이선스이며 [라이선스 원문](vendor/LOTTIE-LICENSE.md)을 포함했습니다.
