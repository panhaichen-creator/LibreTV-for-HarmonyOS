#!/usr/bin/env node
/**
 * LibreTV HarmonyOS —— 版本号自动更迭
 * =====================================
 *
 * 规则：**源码有改动时，打包前把版本号末位 +1；每一位最大 9，超过就归零并向左进一位**
 *
 *   1.1.7 → 1.1.8 → 1.1.9 → 1.2.0 → 1.2.1 → … → 1.9.9 → 2.0.0
 *
 * 也就是像里程表一样逐位滚动，末位不会变成 1.1.10 这种两位数。
 * 注意：末位从 9 回到 0 时中间位 +1；中间位从 9 回到 0 时首位 +1。
 *
 * 为什么要判断「源码有没有改」：
 *   如果每次构建都无脑 +1，一天连打三次包就会变成 1.0.8，
 *   版本号就失去了「这一版改了什么」的意义。这里对 entry/src/main
 *   下的文件做内容哈希，只有和上次打包时不一样才递增。
 *
 * 唯一需要手写的版本号在 AppScope/app.json5：
 *   versionName  —— 用户看到的，如 1.0.5
 *   versionCode  —— 系统判断能否覆盖安装的整数，必须只增不减
 * 两个 oh-package.json5 里的 version 会跟着一起改，保持三处一致。
 *
 * 用法：
 *   node scripts/version.js           有改动就 +0.01（构建钩子自动调用这个）
 *   node scripts/version.js --print   只打印当前版本，不改文件
 *   node scripts/version.js --force   强制递增一位（不改源码也想出个新版本时用）
 *   node scripts/version.js --set 1.1.0   直接把版本号设成指定值并记下当前源码指纹
 *                                         （用于规整历史版本号，不会再多进一位）
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = path.resolve(__dirname, '..');
const APP_JSON = path.join(ROOT, 'AppScope', 'app.json5');
const STATE_FILE = path.join(__dirname, '.version-state.json');
const SCAN_DIR = path.join(ROOT, 'entry', 'src', 'main');

/** 递归收集文件（按路径排序，保证哈希稳定） */
function listFiles(dir, out) {
  if (!fs.existsSync(dir)) {
    return out;
  }
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    const stat = fs.statSync(full);
    if (stat.isDirectory()) {
      listFiles(full, out);
    } else if (stat.isFile()) {
      out.push(full);
    }
  }
  return out;
}

/**
 * 品牌词不参与哈希。
 *
 * scripts/brand.js 会在每次构建前把品牌文案改成公开品牌（LibreTV）或本地品牌
 * （名字取自 scripts/.brand-local.json，该文件不提交）。那只是「同一份源码的两种叫法」，
 * 不该被当成源码改动 —— 否则每切一次品牌就白涨一个版本号。
 * 两套文案是同一个模板拼出来的，除了品牌词本身完全一致，替换后才能等价。
 */
function brandWords() {
  const words = ['LibreTV'];
  try {
    const data = JSON.parse(fs.readFileSync(path.join(__dirname, '.brand-local.json'), 'utf8'));
    const local = typeof data.localBrand === 'string' ? data.localBrand.trim() : '';
    if (local.length > 0 && words.indexOf(local) < 0) {
      words.push(local);
    }
  } catch (e) {
    // 没有本地品牌文件：只屏蔽公开品牌词就够了
  }
  return words;
}

const BRAND_WORDS = new RegExp(brandWords().join('|'), 'g');
const TEXT_FILE = /\.(json|json5|ets|ts|js|md|txt)$/i;

/** 对源码目录做内容哈希：改一个字就会变，改文件名也会变（品牌词除外） */
function sourceHash() {
  const files = listFiles(SCAN_DIR, []).sort();
  const hash = crypto.createHash('sha1');
  for (const file of files) {
    hash.update(path.relative(ROOT, file).split(path.sep).join('/'));
    let buf = fs.readFileSync(file);
    if (TEXT_FILE.test(file)) {
      buf = Buffer.from(buf.toString('utf8').replace(BRAND_WORDS, '__BRAND__'), 'utf8');
    }
    hash.update(buf);
  }
  return hash.digest('hex');
}

function readAppJson() {
  return fs.readFileSync(APP_JSON, 'utf8');
}

function currentVersion() {
  const text = readAppJson();
  const nameMatch = text.match(/"versionName"\s*:\s*"([^"]+)"/);
  const codeMatch = text.match(/"versionCode"\s*:\s*(\d+)/);
  if (!nameMatch || !codeMatch) {
    throw new Error('AppScope/app.json5 里找不到 versionName / versionCode');
  }
  return { name: nameMatch[1], code: parseInt(codeMatch[1], 10) };
}

/** 把 "1.2.3" 拆成 [1,2,3]，并挡掉非数字的写法 */
function toDigits(name) {
  const parts = String(name).split('.');
  if (parts.length < 2) {
    throw new Error('versionName 至少要有两段，形如 1.2.3：' + name);
  }
  const digits = [];
  for (const part of parts) {
    if (!/^\d+$/.test(part)) {
      throw new Error('versionName 里有非数字段，形如 1.2.3：' + name);
    }
    digits.push(parseInt(part, 10));
  }
  return digits;
}

/**
 * 把越界的位（>9）压回 0 并向左进一位。
 * 正常递增不会产生越界位，这个方法只用于规整历史版本号（1.0.13 -> 1.1.0）。
 */
function normalizeDigits(digits) {
  for (let i = digits.length - 1; i > 0; i -= 1) {
    if (digits[i] > 9) {
      digits[i] = 0;
      digits[i - 1] += 1;
    }
  }
  return digits;
}

/** 规整后的版本号字符串：1.0.13 -> 1.1.0 */
function normalizeName(name) {
  return normalizeDigits(toDigits(name)).join('.');
}

/**
 * 里程表式递增：每一位最大 9，超过就归零并向左进一位。
 *   1.1.9 -> 1.2.0      1.9.9 -> 2.0.0
 * 首位是最高位，它没有更左的位可进 —— 三位全是 9 就到顶了，
 * 此时保持原值并告警：绕回 0.0.0 比「版本号不变」更像故障。
 */
function nextName(name) {
  const digits = normalizeDigits(toDigits(name));
  const atCeiling = digits.every((d) => d === 9);
  if (atCeiling) {
    console.warn('[version] 版本号已到上限 ' + digits.join('.') + '，不再递增');
    return digits.join('.');
  }
  for (let i = digits.length - 1; i >= 0; i -= 1) {
    digits[i] += 1;
    if (digits[i] <= 9) {
      break;
    }
    digits[i] = 0;
  }
  return digits.join('.');
}

/** 写回三处版本号，其余格式原样保留 */
function writeVersion(oldName, newName, newCode) {
  // 1) app.json5
  let text = readAppJson();
  text = text.replace(/"versionName"\s*:\s*"[^"]+"/, '"versionName": "' + newName + '"');
  text = text.replace(/"versionCode"\s*:\s*\d+/, '"versionCode": ' + newCode);
  fs.writeFileSync(APP_JSON, text, 'utf8');

  // 2) 两个 oh-package.json5（历史遗留会漂移的地方，一并跟上）
  const pkgFiles = [
    path.join(ROOT, 'oh-package.json5'),
    path.join(ROOT, 'entry', 'oh-package.json5'),
  ];
  for (const file of pkgFiles) {
    if (!fs.existsSync(file)) {
      continue;
    }
    const pkgText = fs.readFileSync(file, 'utf8');
    const updated = pkgText.replace(
      /"version"\s*:\s*"[^"]*"/,
      '"version": "' + newName + '"'
    );
    if (updated !== pkgText) {
      fs.writeFileSync(file, updated, 'utf8');
    }
  }
}

function readState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  } catch (e) {
    return null;
  }
}

function writeState(hash, version) {
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(
    STATE_FILE,
    JSON.stringify(
      {
        sourceHash: hash,
        versionName: version.name,
        versionCode: version.code,
        updatedAt: new Date().toISOString(),
      },
      null,
      2
    ) + '\n',
    'utf8'
  );
}

function main() {
  const args = process.argv.slice(2);
  const cur = currentVersion();

  if (args.includes('--print')) {
    console.log('[version] current: ' + cur.name + ' (versionCode ' + cur.code + ')');
    return;
  }

  // --set：直接把版本号设成指定值，并记下当前源码指纹（下次构建不会再多进一位）
  const setIdx = args.indexOf('--set');
  if (setIdx >= 0) {
    const want = args[setIdx + 1];
    if (!want) {
      throw new Error('--set 后面要跟版本号，例如 --set 1.1.0');
    }
    const normalized = normalizeName(want);
    const newCode = cur.code + 1;
    writeVersion(cur.name, normalized, newCode);
    writeState(sourceHash(), { name: normalized, code: newCode });
    console.log(
      '[version] set: ' + cur.name + ' -> ' + normalized +
      ' (versionCode ' + cur.code + ' -> ' + newCode + ')'
    );
    if (normalized !== want) {
      console.log(
        '[version] note: "' + want + '" 不合规（有某一位超过 9），已按进位规则规整为 ' + normalized
      );
    }
    return;
  }

  const hash = sourceHash();
  const state = readState();

  // 首次运行（新克隆的仓库）：只记基线，不递增，避免平白多一个版本
  if (!state) {
    writeState(hash, cur);
    console.log('[version] baseline recorded: ' + cur.name + ' (versionCode ' + cur.code + ')');
    return;
  }

  const forced = args.includes('--force');
  if (!forced && state.sourceHash === hash) {
    console.log('[version] source unchanged, keep ' + cur.name);
    return;
  }

  const newName = nextName(cur.name);
  const newCode = cur.code + 1;
  writeVersion(cur.name, newName, newCode);
  writeState(hash, { name: newName, code: newCode });
  console.log(
    '[version] source changed: ' + cur.name + ' -> ' + newName +
    ' (versionCode ' + cur.code + ' -> ' + newCode + ')'
  );
}

try {
  main();
} catch (e) {
  // 版本号递增失败绝不能影响打包，只提示
  console.error('[version] skip auto bump: ' + (e && e.message ? e.message : e));
  process.exit(0);
}
