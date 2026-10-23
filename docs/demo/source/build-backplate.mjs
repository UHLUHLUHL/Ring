import { createRequire } from 'node:module';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';

const require = createRequire(process.env.NODE_PATH ? resolve(process.env.NODE_PATH.split(':')[0], '../package.json') : import.meta.url);
const sharp = require('sharp');

const root = resolve(import.meta.dirname);
const out = resolve(root, 'backplate');
const photoPath = resolve(root, 'media/coast.png');
const iconPath = resolve(root, 'media/ring-icon.png');
const W = 1440;
const H = 960;
const apple = 'Apple SD Gothic Neo, SF Pro Display, sans-serif';
const esc = (value) => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

const photoData = existsSync(photoPath)
  ? `data:image/png;base64,${readFileSync(photoPath).toString('base64')}`
  : null;
const iconData = existsSync(iconPath)
  ? `data:image/png;base64,${readFileSync(iconPath).toString('base64')}`
  : null;

const svg = (body, transparent = false) => `
<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg">
  <style>
    text { font-family: '${apple}'; text-rendering: geometricPrecision; }
  </style>
  ${transparent ? '' : '<rect width="1440" height="960" fill="#101722"/>'}
  ${body}
</svg>`;

const text = (x, y, value, size, fill, weight = 400, anchor = 'start') =>
  `<text x="${x}" y="${y}" font-size="${size}" fill="${fill}" font-weight="${weight}" text-anchor="${anchor}">${esc(value)}</text>`;

const folder = (x, y, label, active = false) => `
  <g>
    <rect x="${x}" y="${y - 16}" width="150" height="34" rx="8" fill="${active ? '#33465d' : 'transparent'}"/>
    <path d="M${x + 14} ${y - 5}h10l3 3h12v12H${x + 14}z" fill="${active ? '#87aee0' : '#87929f'}" opacity=".92"/>
    ${text(x + 48, y + 7, label, 15, active ? '#eff5ff' : '#d6dce3', active ? 600 : 400)}
  </g>`;

const photoIcon = (cx, cy, name, kind = 'png') => {
  const x = cx - 55, y = cy - 33;
  const thumb = photoData
    ? `<image href="${photoData}" x="${x}" y="${y}" width="110" height="66" preserveAspectRatio="xMidYMid slice" clip-path="url(#thumbClip-${kind})"/>`
    : `<rect x="${x}" y="${y}" width="110" height="66" rx="5" fill="#475363"/><path d="M${x} ${y + 50}l27-27 19 17 22-25 42 38v13H${x}z" fill="#71859c"/>`;
  return `
    <g>
      <defs><clipPath id="thumbClip-${kind}"><rect x="${x}" y="${y}" width="110" height="66" rx="5"/></clipPath></defs>
      <g filter="url(#thumbShadow)">${thumb}<rect x="${x}" y="${y}" width="110" height="66" rx="5" fill="none" stroke="#f5f7fa" stroke-opacity=".84"/></g>
      ${kind === 'mp4' ? `<circle cx="${cx}" cy="${cy - 9}" r="14" fill="#101722" fill-opacity=".72"/><path d="M${cx - 4} ${cy - 16}l11 7-11 7z" fill="#fff"/><rect x="${x + 70}" y="${y + 45}" width="34" height="15" rx="7.5" fill="#111923" fill-opacity=".82"/>${text(x + 87, y + 57, '0:03', 10, '#fff', 600, 'middle')}` : ''}
      ${text(cx, cy + 57, name, 16, '#eef2f6', 500, 'middle')}
    </g>`;
};

const base = svg(`
  <defs>
    <radialGradient id="wall" cx="72%" cy="7%" r="95%"><stop stop-color="#243248"/><stop offset=".52" stop-color="#151e2c"/><stop offset="1" stop-color="#0c121b"/></radialGradient>
    <linearGradient id="glass" x1="0" x2="0" y2="1"><stop stop-color="#303b48"/><stop offset="1" stop-color="#1e2731"/></linearGradient>
    <filter id="windowShadow" x="-10%" y="-15%" width="120%" height="140%"><feDropShadow dx="0" dy="28" stdDeviation="28" flood-color="#000" flood-opacity=".55"/></filter>
    <filter id="thumbShadow" x="-20%" y="-30%" width="140%" height="160%"><feDropShadow dy="3" stdDeviation="3" flood-opacity=".42"/></filter>
  </defs>
  <rect width="1440" height="960" fill="url(#wall)"/>
  <circle cx="1190" cy="75" r="360" fill="#3f5780" opacity=".12"/>
  <circle cx="210" cy="900" r="390" fill="#486076" opacity=".1"/>
  <g opacity=".95">
    ${iconData ? `<image href="${iconData}" x="100" y="52" width="40" height="40"/>` : '<rect x="100" y="52" width="40" height="40" rx="9" fill="#8ee0c2"/>'}
    ${text(152, 78, 'Ring', 24, '#f1f5f8', 650)}
    ${text(152, 105, '파일에서 바로, 원하는 결과로.', 17, '#9faab8', 400)}
    ${text(1338, 78, 'macOS · 0.2.6', 16, '#b6c0cc', 500, 'end')}
  </g>
  <g filter="url(#windowShadow)">
    <rect x="100" y="160" width="1240" height="650" rx="17" fill="#202a35" stroke="#596676" stroke-opacity=".72"/>
    <path d="M117 160h1206a17 17 0 0 1 17 17v56H100v-56a17 17 0 0 1 17-17z" fill="url(#glass)"/>
    <path d="M280 233h1060v560a17 17 0 0 1-17 17H280z" fill="#1d2630"/>
    <path d="M100 233h180v560a17 17 0 0 1-17 17H117a17 17 0 0 1-17-17z" fill="#27323e"/>
    <path d="M280 233v577" stroke="#465260"/>
    <circle cx="130" cy="196" r="6.6" fill="#ff6157"/><circle cx="152" cy="196" r="6.6" fill="#ffbd2e"/><circle cx="174" cy="196" r="6.6" fill="#2acb42"/>
    <path d="M308 196h14m-7-7v14" stroke="#bec8d2" stroke-width="1.6" stroke-linecap="round"/>
    ${text(720, 202, 'Ring Demo', 17, '#edf1f5', 600, 'middle')}
    <path d="M1265 193h17m-17 7h17m-17 7h17" stroke="#b9c4ce" stroke-width="1.5" stroke-linecap="round"/>
    ${text(122, 271, '즐겨찾기', 13, '#8f9aa7', 600)}
    ${folder(113, 302, '데스크탑', true)}
    ${folder(113, 346, '다운로드')}
    ${folder(113, 390, '문서')}
    <path d="M310 252h996" stroke="#35414e"/>
    ${photoIcon(490, 375, 'coast.png')}
    ${photoIcon(490, 560, 'coast.mp4', 'mp4')}
  </g>
`);

const overlayFile = (name, cy, tone, icon) => {
  const x = 635, y = cy - 33;
  const thumb = photoData
    ? `<image href="${photoData}" x="${x}" y="${y}" width="110" height="66" preserveAspectRatio="xMidYMid slice" clip-path="url(#overlayClip)"/>`
    : `<rect x="${x}" y="${y}" width="110" height="66" rx="5" fill="#475363"/>`;
  return svg(`
    <defs>
      <clipPath id="overlayClip"><rect x="${x}" y="${y}" width="110" height="66" rx="5"/></clipPath>
      <filter id="softShadow" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dy="3" stdDeviation="3" flood-opacity=".42"/></filter>
    </defs>
    <g filter="url(#softShadow)">${thumb}<rect x="${x}" y="${y}" width="110" height="66" rx="5" fill="none" stroke="#f5f7fa" stroke-opacity=".84"/></g>
    <rect x="${x + 61}" y="${y + 43}" width="42" height="17" rx="8.5" fill="${tone}"/>
    ${text(x + 82, y + 56, icon.toUpperCase(), 10, '#13202a', 700, 'middle')}
    ${text(690, cy + 57, name, 16, '#f1f5f8', 500, 'middle')}
  `, true);
};

const caption = (n, title, secondary) => svg(`
  <g>
    <rect x="140" y="833" width="36" height="36" rx="18" fill="#a5e3ce"/>
    ${text(158, 858, String(n), 17, '#102019', 700, 'middle')}
    ${text(191, 858, title, 25, '#f4f7fa', 650)}
    ${text(191, 890, secondary, 17, '#aeb9c5', 400)}
  </g>
`, true);

const menu = svg(`
  <defs><filter id="menuShadow" x="-30%" y="-20%" width="160%" height="150%"><feDropShadow dy="12" stdDeviation="13" flood-opacity=".42"/></filter></defs>
  <g filter="url(#menuShadow)">
    <rect x="505" y="360" width="248" height="235" rx="11" fill="#2b3541" fill-opacity=".98" stroke="#617080" stroke-opacity=".8"/>
    ${text(527, 391, '열기', 15, '#eef3f7')}
    ${text(527, 422, '연결 프로그램', 15, '#eef3f7')}
    <path d="M729 416l5 6-5 6" fill="none" stroke="#c1cad3" stroke-width="1.5"/>
    <path d="M517 438h224" stroke="#536171"/>
    ${text(527, 468, '이름 변경', 15, '#eef3f7')}
    ${text(527, 499, '빠른 동작', 15, '#eef3f7')}
    <path d="M729 493l5 6-5 6" fill="none" stroke="#c1cad3" stroke-width="1.5"/>
    <rect x="514" y="513" width="230" height="31" rx="6" fill="#3f7fbd"/>
    <path d="M530 522l6-6 6 6-6 6z" fill="#c4f2df"/><path d="M534 519h4v4h-4z" fill="#316e60"/>
    ${text(551, 535, 'Ring으로 변환·편집', 15, '#fff', 600)}
    <path d="M517 558h224" stroke="#536171"/>
    ${text(527, 582, '휴지통으로 이동', 15, '#eef3f7')}
  </g>
`, true);

await mkdir(out, { recursive: true });
const writePng = async (file, markup) => sharp(Buffer.from(markup)).png({ compressionLevel: 9 }).toFile(resolve(out, file));
await Promise.all([
  writePng('background.png', base),
  writePng('jpg.png', overlayFile('coast.jpg', 375, '#e0a05c', 'jpg')),
  writePng('webp.png', overlayFile('coast.webp', 560, '#6fb9b4', 'webp')),
  writePng('caption-1.png', caption(1, '이미지를 JPG로', '파일 우클릭 → Ring으로 변환·편집 → JPG')),
  writePng('caption-2.png', caption(2, '영상을 WebP로', 'WEBP 선택 → 긴 변 480px로 변경 → 저장')),
  writePng('caption-3.png', caption(3, '원본 옆에 새 파일로', '원본은 그대로 두고, 결과만 따로 저장합니다.')),
  writePng('context-menu.png', menu),
]);

console.log(`Generated ${out} using ${photoData ? 'coast-source.png' : 'placeholder photo'}.`);
