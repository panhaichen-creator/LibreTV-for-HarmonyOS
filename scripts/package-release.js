#!/usr/bin/env node
/**
 * 发布三件套 → 桌面
 *
 * 每次版本更新后执行一次，把「可上传 GitHub Release」的东西放到桌面：
 *   1. LibreTV-HarmonyOS-v<版本>-unsigned.hap       脱敏安装包（未签名）
 *   2. LibreTV-HarmonyOS-v<版本>-unsigned.hap.sha256 校验值
 *   3. v<版本>-Release说明.md                       版本说明（取自 docs/release-notes-v<版本>.md）
 *
 * 用法：
 *   node scripts/package-release.js
 *   node scripts/package-release.js --desktop "C:\Users\<你的用户名>\Desktop"
 *
 * 前置：必须已经在「公开 / 脱敏」配置下构建过 —— 脚本会先自检，不合规直接中止：
 *   - build-profile.json5 里 signingConfigs 必须为空（不能带本机证书路径）
 *   - 资源里的应用名不能是本地品牌（scripts/.brand-local.json 里那个）
 *   - 产物 HAP 字节里不能出现本地品牌字样
 */
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { execSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const APP_NAME = 'LibreTV-HarmonyOS';
const HAP_PATH = path.join(ROOT, 'entry', 'build', 'default', 'outputs', 'default',
  'entry-default-unsigned.hap');

function die(msg, hint) {
  console.error('[release] ✗ ' + msg);
  if (hint) {
    console.error('           ' + hint);
  }
  process.exit(1);
}

/** 读取当前版本号（AppScope/app.json5 是唯一事实来源） */
function readVersion() {
  const p = path.join(ROOT, 'AppScope', 'app.json5');
  const text = fs.readFileSync(p, 'utf8');
  const m = /"versionName"\s*:\s*"([^"]+)"/.exec(text);
  if (m === null) {
    die('AppScope/app.json5 里找不到 versionName');
  }
  return m[1];
}

/** 本地品牌名：文件不存在就是纯公开仓库，没有可泄露的名字 */
function readLocalBrand() {
  const p = path.join(__dirname, '.brand-local.json');
  try {
    const data = JSON.parse(fs.readFileSync(p, 'utf8'));
    const name = typeof data.localBrand === 'string' ? data.localBrand.trim() : '';
    return name;
  } catch (e) {
    return '';
  }
}

/** 自检 1：构建配置必须是脱敏那份（没有证书路径） */
function assertOpenSourceProfile() {
  const p = path.join(ROOT, 'build-profile.json5');
  const text = fs.readFileSync(p, 'utf8');
  // 去掉注释再判断，注释里本来就有示例配置
  const stripped = text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  if (!/"signingConfigs"\s*:\s*\[\s*\]/.test(stripped)) {
    die('build-profile.json5 还带着签名配置，这是「签名版」不是在脱敏状态',
      '先在桌面跑「LibreTV-上传前脱敏.cmd」，或在 DevEco 里清空 signingConfigs 再构建');
  }
  if (/"storeFile"|"keyPassword"|\.p12/.test(stripped)) {
    die('build-profile.json5 里仍有证书材料，拒绝打包');
  }
}

/** 自检 2：资源里的应用名必须是公开品牌 */
function assertPublicBrand(localBrand) {
  const p = path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'string.json');
  const text = fs.readFileSync(p, 'utf8');
  if (localBrand !== '' && text.indexOf(localBrand) >= 0) {
    die('资源文件里还是本地品牌「' + localBrand + '」，不是脱敏状态',
      '执行 node scripts/brand.js LibreTV 后再重新构建');
  }
}

/** 自检 3：产物字节里不能有本地品牌（HAP 是二进制，按 latin1 扫一遍兜底） */
function assertHapClean(file, localBrand) {
  if (localBrand === '') {
    return;
  }
  const buf = fs.readFileSync(file);
  if (buf.toString('latin1').indexOf(localBrand) >= 0) {
    die('构建产物里含有本地品牌「' + localBrand + '」',
      '这份包不能上传：切到 LibreTV 品牌重新构建一次');
  }
}

/**
 * 桌面路径，按优先级依次尝试：
 *   1. --desktop "<路径>"
 *   2. 环境变量 RELEASE_DESKTOP
 *   3. scripts/.release-desktop.json（本机配置，不进仓库）
 *      桌面被重定向到别的盘时用它最省事 ——
 *      USERPROFILE\Desktop 根本不存在，而读注册表要调 reg.exe，未必允许
 *   4. 常见的 Desktop / OneDrive\Desktop
 *   5. 注册表里的真实位置（reg.exe 被禁时会失败，失败就报错让用户显式指定）
 */
function resolveDesktop(argv) {
  const idx = argv.indexOf('--desktop');
  if (idx >= 0 && argv[idx + 1]) {
    return argv[idx + 1];
  }
  if (process.env.RELEASE_DESKTOP) {
    return process.env.RELEASE_DESKTOP;
  }
  try {
    const conf = JSON.parse(fs.readFileSync(path.join(__dirname, '.release-desktop.json'), 'utf8'));
    const dir = typeof conf.desktop === 'string' ? conf.desktop.trim() : '';
    if (dir !== '' && fs.existsSync(dir)) {
      return dir;
    }
  } catch (e) {
    // 没有本地配置就继续往后找
  }
  const home = os.homedir();
  const candidates = [path.join(home, 'Desktop'), path.join(home, 'OneDrive', 'Desktop')];
  for (const c of candidates) {
    if (fs.existsSync(c)) {
      return c;
    }
  }
  // 桌面被重定向到别的盘（USERPROFILE\Desktop 不存在）：问注册表
  try {
    const out = execSync(
      'reg query "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders" /v Desktop',
      { encoding: 'utf8' });
    const m = /Desktop\s+REG_(?:EXPAND_)?SZ\s+(.+)/.exec(out);
    if (m !== null) {
      const resolved = m[1].trim().replace(/%USERPROFILE%/gi, home);
      if (fs.existsSync(resolved)) {
        return resolved;
      }
    }
  } catch (e) {
    // 注册表读不到就继续往下报错
  }
  die('找不到桌面目录', '用 --desktop "<路径>" 显式指定');
}

function fileSizeText(bytes) {
  return (bytes / 1024 / 1024).toFixed(2) + ' MB';
}

function main() {
  const version = readVersion();
  const desktop = resolveDesktop(process.argv);
  const localBrand = readLocalBrand();

  console.log('[release] 版本 ' + version + '，桌面 ' + desktop);
  console.log('[release] 本地品牌：' + (localBrand === '' ? '（无，纯公开仓库）' : localBrand));

  assertOpenSourceProfile();
  console.log('[release] ✓ 构建配置为脱敏状态');

  assertPublicBrand(localBrand);
  console.log('[release] ✓ 资源文案为公开品牌');

  if (!fs.existsSync(HAP_PATH)) {
    die('找不到产物 ' + path.relative(ROOT, HAP_PATH),
      '先在脱敏配置下构建：hvigorw assembleHap --mode module -p product=default -p buildMode=debug');
  }
  assertHapClean(HAP_PATH, localBrand);
  console.log('[release] ✓ 产物内无本地品牌字样');

  const hapName = APP_NAME + '-v' + version + '-unsigned.hap';
  const hapDst = path.join(desktop, hapName);
  fs.copyFileSync(HAP_PATH, hapDst);
  const size = fs.statSync(hapDst).size;

  const hash = crypto.createHash('sha256').update(fs.readFileSync(hapDst)).digest('hex');
  const hashName = hapName + '.sha256';
  fs.writeFileSync(path.join(desktop, hashName), hash + '  ' + hapName + '\n', 'utf8');

  const notesSrc = path.join(ROOT, 'docs', 'release-notes-v' + version + '.md');
  const notesName = 'v' + version + '-Release说明.md';
  let notesCopied = false;
  if (fs.existsSync(notesSrc)) {
    fs.copyFileSync(notesSrc, path.join(desktop, notesName));
    notesCopied = true;
  }

  console.log('');
  console.log('[release] 已放到桌面：');
  console.log('  ' + hapName + '  (' + fileSizeText(size) + ')');
  console.log('  ' + hashName);
  console.log('    ' + hash);
  if (notesCopied) {
    console.log('  ' + notesName);
  } else {
    console.log('  [注意] 缺少 docs/release-notes-v' + version + '.md，版本说明没有复制');
    console.log('         补好这个文件后再跑一次本脚本即可');
  }
}

main();
