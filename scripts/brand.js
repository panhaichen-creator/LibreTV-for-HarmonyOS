/**
 * 品牌名同步脚本。
 *
 * 应用显示名不写死在界面代码里，构建前由本脚本按构建配置写进资源：
 *   - 脱敏构建（build-profile.json5 里 signingConfigs 为空，上传公开仓库）→ LibreTV
 *   - 签名构建（装自己的手机 / 平板）                                    → 读本地品牌文件
 *
 * 本地品牌名放在 scripts/.brand-local.json，这个文件在 .gitignore 里，不会被提交。
 * 文件不存在时一律按 LibreTV 处理 —— 公开仓库里既看不到这个名字，也不需要它：
 * clone 下来直接构建出来的就是 LibreTV。
 *
 * 用法：
 *   node scripts/brand.js            按 build-profile.json5 自动判断（构建时由 hvigorfile 调用）
 *   node scripts/brand.js LibreTV    强制指定
 *   node scripts/brand.js <本地品牌>  强制指定（名字取自 .brand-local.json）
 *   node scripts/brand.js --print    只打印当前品牌，不写文件
 *
 * 只改 5 个资源值，不碰任何 .ets：
 *   AppScope/.../string.json          app_name
 *   entry/.../string.json             EntryAbility_label / brand_name / brand_about_title / brand_disclaimer
 *
 * 界面里 `Text($r('app.string.brand_name'))` 之类会在运行时自动取到新值，
 * 所以换品牌不需要改一行界面代码。
 *
 * 注意：两套文案是同一个模板拼出来的，**只允许品牌词本身不同**，
 * 否则 scripts/version.js 的「源码指纹」会在换品牌时误判成源码改动、白涨一个版本号。
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const APP_STRINGS = path.join(ROOT, 'AppScope', 'resources', 'base', 'element', 'string.json');
const ENTRY_STRINGS = path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'string.json');
const BUILD_PROFILE = path.join(ROOT, 'build-profile.json5');
const LOCAL_BRAND_FILE = path.join(__dirname, '.brand-local.json');

/** 公开构建用的品牌名。公开仓库里只会出现这一个。 */
const PUBLIC_BRAND = 'LibreTV';

/** 读本地品牌名；文件缺失、字段缺失、内容为空都返回空串 */
function readLocalBrand() {
  try {
    const data = JSON.parse(fs.readFileSync(LOCAL_BRAND_FILE, 'utf8'));
    const name = typeof data.localBrand === 'string' ? data.localBrand.trim() : '';
    return name;
  } catch (e) {
    return '';
  }
}

const LOCAL_BRAND = readLocalBrand();

/**
 * 按模板拼出一整套品牌文案。
 * 两套文案只差品牌词，所以切品牌时源码指纹（屏蔽品牌词后）保持等价。
 */
function buildConf(name) {
  return {
    app_name: name,
    EntryAbility_label: name,
    brand_name: name,
    brand_about_title: name + ' 鸿蒙原生客户端',
    brand_disclaimer: '本应用仅提供网络视频播放能力，不内置、不提供、不推荐任何视频内容或片源；' +
      '所有播放地址均由用户自行添加，内容来源与版权责任由用户自负。' +
      '本应用与任何电视台、影视平台及内容服务商均无关联，亦未获其授权或认可。'
  };
}

/** 可用的品牌名 → 文案。本地品牌文件缺失时只有公开品牌一项。 */
const BRANDS = {};
BRANDS[PUBLIC_BRAND] = buildConf(PUBLIC_BRAND);
if (LOCAL_BRAND !== '' && LOCAL_BRAND !== PUBLIC_BRAND) {
  BRANDS[LOCAL_BRAND] = buildConf(LOCAL_BRAND);
}

/**
 * build-profile.json5 里 signingConfigs 为空数组 = 脱敏版。
 *
 * 必须先剥掉注释再判：这个文件顶部有一段「怎么填签名配置」的示例注释，
 * 里面原样写着 `"signingConfigs": [{ ... }]`。不剥注释的话正则会先命中注释，
 * 永远判成「有签名」—— 于是脱敏构建出来还是本地品牌，白脱敏。
 */
function detectBrand() {
  try {
    const raw = fs.readFileSync(BUILD_PROFILE, 'utf8');
    const text = raw
      .replace(/\/\*[\s\S]*?\*\//g, '')       // 块注释
      .replace(/(^|[^:])\/\/.*$/gm, '$1');    // 行注释（[^:] 避开 http://）
    const m = text.match(/"signingConfigs"\s*:\s*\[([\s\S]*?)\]/);
    if (!m) {
      return PUBLIC_BRAND;
    }
    const signed = m[1].trim().length > 0;
    if (signed && LOCAL_BRAND !== '') {
      return LOCAL_BRAND;
    }
    return PUBLIC_BRAND;
  } catch (e) {
    return PUBLIC_BRAND;
  }
}

function setValue(file, key, value) {
  const raw = fs.readFileSync(file, 'utf8');
  const data = JSON.parse(raw);
  if (!Array.isArray(data.string)) {
    throw new Error('unexpected string.json shape: ' + file);
  }
  let hit = false;
  for (const item of data.string) {
    if (item.name === key) {
      item.value = value;
      hit = true;
      break;
    }
  }
  if (!hit) {
    data.string.push({ name: key, value: value });
  }
  // 统一用 2 空格缩进 + 末尾换行，与仓库现有格式一致
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n', 'utf8');
  return hit;
}

function readValue(file, key) {
  try {
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    for (const item of data.string) {
      if (item.name === key) {
        return item.value;
      }
    }
  } catch (e) {
    // ignore
  }
  return '';
}

/** 签名构建但没本地品牌文件时，说明一句原因，免得以为是脚本坏了 */
function warnMissingLocalBrand() {
  if (LOCAL_BRAND !== '') {
    return;
  }
  try {
    const raw = fs.readFileSync(BUILD_PROFILE, 'utf8');
    const text = raw
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/(^|[^:])\/\/.*$/gm, '$1');
    const m = text.match(/"signingConfigs"\s*:\s*\[([\s\S]*?)\]/);
    if (m && m[1].trim().length > 0) {
      console.log('[brand] signed build but no scripts/.brand-local.json, fall back to ' + PUBLIC_BRAND);
    }
  } catch (e) {
    // ignore
  }
}

function main() {
  const args = process.argv.slice(2);

  if (args.indexOf('--print') >= 0) {
    console.log('[brand] current: ' + readValue(APP_STRINGS, 'app_name') +
      ' (build-profile => ' + detectBrand() + ', local brand ' +
      (LOCAL_BRAND === '' ? 'absent' : 'loaded') + ')');
    warnMissingLocalBrand();
    return;
  }

  let target = '';
  for (const a of args) {
    if (BRANDS[a]) {
      target = a;
      break;
    }
  }
  const forced = target !== '';
  if (!forced) {
    target = detectBrand();
  }

  const conf = BRANDS[target];

  if (readValue(APP_STRINGS, 'app_name') === conf.app_name &&
    readValue(ENTRY_STRINGS, 'brand_name') === conf.brand_name) {
    console.log('[brand] unchanged: ' + target);
    warnMissingLocalBrand();
    return;
  }

  setValue(APP_STRINGS, 'app_name', conf.app_name);
  setValue(ENTRY_STRINGS, 'EntryAbility_label', conf.EntryAbility_label);
  setValue(ENTRY_STRINGS, 'brand_name', conf.brand_name);
  setValue(ENTRY_STRINGS, 'brand_about_title', conf.brand_about_title);
  setValue(ENTRY_STRINGS, 'brand_disclaimer', conf.brand_disclaimer);

  console.log('[brand] set to ' + target + (forced ? ' (explicit)' : ' (from build-profile)'));
  warnMissingLocalBrand();
}

try {
  main();
} catch (e) {
  // 品牌切换失败不能阻断构建，只提示
  console.warn('[brand] skipped: ' + (e && e.message ? e.message : e));
}
