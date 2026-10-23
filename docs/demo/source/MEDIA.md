# 샘플 미디어

개인 사진 대신 built-in `image_gen`으로 만든 사진을 사용했습니다.

생성 프롬프트:

> Use case: photorealistic-natural; Asset type: source media for a macOS image conversion demo; Primary request: photorealistic natural wide 16:9 coastal landscape, turquoise sea with small white surf, rocky sunlit shoreline in the foreground, distant blue mountains, late afternoon light. Scene/backdrop: open natural coastline. Style/medium: crisp DSLR photograph, realistic color and detail. Composition/framing: simple visually clear wide landscape composition, no UI. Lighting/mood: warm late-afternoon sun with natural contrast. Constraints: no people, no buildings, no text, no watermark, no logos.

`media/coast.png`: 생성된 원본 1672×941 PNG.

`media/coast.mp4`: 위 사진에 느린 확대를 적용한 1280×720 / 24fps / 3초 샘플. 영상 제작에만 FFmpeg를 사용했고, Ring의 실제 WebP 변환은 Ring의 네이티브 엔진에서 실행했습니다.

사진 SHA-256: `23dda03981eb2f79dd58c9836355d7033dc5569d98acb382cb302d9c57d3cd21`.
