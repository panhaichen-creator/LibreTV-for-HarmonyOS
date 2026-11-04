/**
 * 订阅解析：LibreTV-SourceList JSON 与 TVBOX 配置
 * 与 LibreTV tvbox-parser.ts / source-list.ts 逻辑对齐
 */

import { VodSource, LiveSource, LiveChannel } from './Types';
import { SourceManager } from '../data/SourceManager';
import { M3uParser } from './M3uParser';

/** 弹性导入结果：订阅 JSON 或直播播放列表 */
export interface FlexibleParseResult {
  /** 'json' = 订阅配置；'playlist' = M3U / TXT 播放列表 */
  kind: string;
  sub?: SubscriptionResult;
  channels: LiveChannel[];
}

export interface SubscriptionResult {
  name: string;
  /** libretv / tvbox */
  format: string;
  vod: VodSource[];
  live: LiveSource[];
  skipped: number;
  skipDesc: string;
}

export class SubscriptionParser {
  static parse(text: string): SubscriptionResult {
    const json = SubscriptionParser.parseJson(text);
    if (SubscriptionParser.isTvboxPayload(json)) {
      return SubscriptionParser.parseTvbox(json);
    }
    return SubscriptionParser.parseSourceList(json);
  }

  /**
   * 弹性导入：自动识别订阅 JSON（LibreTV / TVBOX）或直播播放列表（M3U / TXT）。
   */
  static parseFlexible(text: string): FlexibleParseResult {
    const trimmed = text.replace(/^\uFEFF/, '').trim();
    if (trimmed === '') {
      throw new Error('内容为空');
    }
    if (!SubscriptionParser.isLivePlaylistText(trimmed)) {
      try {
        const sub = SubscriptionParser.parse(trimmed);
        return { kind: 'json', sub: sub, channels: [] };
      } catch (e) {
        // 不是 JSON，继续按播放列表解析
      }
    }
    const channels = M3uParser.parse(trimmed, '');
    if (channels.length === 0) {
      throw new Error('无法识别的内容：不是订阅 JSON，也不是 M3U / TXT 播放列表');
    }
    return { kind: 'playlist', channels: channels };
  }

  /** 内容是否为直播播放列表文本（M3U 头或 TVBOX TXT 分组标记） */
  static isLivePlaylistText(text: string): boolean {
    const head = text.substring(0, 2048).toUpperCase();
    return head.indexOf('#EXTM3U') >= 0 || head.indexOf(',#GENRE#') >= 0;
  }

  static parseJson(text: string): object {
    let t = text.replace(/^\uFEFF/, '');
    t = SubscriptionParser.stripJsonArtifacts(t);
    try {
      return JSON.parse(t) as object;
    } catch (e) {
      throw new Error('订阅内容不是合法的 JSON');
    }
  }

  private static stripJsonArtifacts(text: string): string {
    return SubscriptionParser.stripTrailingCommas(SubscriptionParser.stripComments(text));
  }

  /** 剥离字符串外部的行注释与块注释（字符串内 // 不受影响） */
  private static stripComments(text: string): string {
    let out = '';
    let inString = false;
    let inLineComment = false;
    let inBlockComment = false;
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      const next = i + 1 < text.length ? text[i + 1] : '';
      if (inLineComment) {
        if (ch === '\n' || ch === '\r') {
          inLineComment = false;
          out += ch;
        }
        continue;
      }
      if (inBlockComment) {
        if (ch === '*' && next === '/') {
          inBlockComment = false;
          i += 1;
        }
        continue;
      }
      if (inString) {
        out += ch;
        if (ch === '\\') {
          out += next;
          i += 1;
        } else if (ch === '"') {
          inString = false;
        }
        continue;
      }
      if (ch === '"') {
        inString = true;
        out += ch;
        continue;
      }
      if (ch === '/' && next === '/') {
        inLineComment = true;
        i += 1;
        continue;
      }
      if (ch === '/' && next === '*') {
        inBlockComment = true;
        i += 1;
        continue;
      }
      out += ch;
    }
    return out;
  }

  /** 剥离尾随逗号 */
  private static stripTrailingCommas(text: string): string {
    let out = '';
    let inString = false;
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (inString) {
        out += ch;
        if (ch === '\\') {
          if (i + 1 < text.length) {
            out += text[i + 1];
            i += 1;
          }
        } else if (ch === '"') {
          inString = false;
        }
        continue;
      }
      if (ch === '"') {
        inString = true;
        out += ch;
        continue;
      }
      if (ch === ',') {
        let j = i + 1;
        while (j < text.length && /\s/.test(text[j])) {
          j++;
        }
        if (j < text.length && (text[j] === '}' || text[j] === ']')) {
          continue;
        }
      }
      out += ch;
    }
    return out;
  }

  static isTvboxPayload(json: object): boolean {
    if (json === null || typeof json !== 'object' || Array.isArray(json)) {
      return false;
    }
    const rec = json as Record<string, object>;
    return Array.isArray(rec['sites']) || Array.isArray(rec['lives']);
  }

  static parseSourceList(json: object): SubscriptionResult {
    const rec = (json ?? {}) as Record<string, object>;
    const rawSources = Array.isArray(rec['sources']) ? rec['sources'] as object[] : [];
    const rawLives = Array.isArray(rec['liveSources']) ? rec['liveSources'] as object[] : [];
    const vod: VodSource[] = [];
    const live: LiveSource[] = [];
    let skipped = 0;
    for (const raw of rawSources) {
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
        continue;
      }
      const site = raw as Record<string, object>;
      const url = SubscriptionParser.normalizeUrl(SubscriptionParser.str(site['api'] !== undefined ? site['api'] : site['url']), true);
      if (url === '') {
        skipped++;
        continue;
      }
      let dup = false;
      for (const v of vod) {
        if (v.url === url) {
          dup = true;
          break;
        }
      }
      if (dup) {
        continue;
      }
      if (vod.length >= SourceManager.MAX_VOD) {
        skipped++;
        continue;
      }
      vod.push({
        key: '',
        name: SubscriptionParser.str(site['name']) !== '' ? SubscriptionParser.str(site['name']) : url,
        url: url,
        detail: undefined,
        enabled: true,
        isAdult: SubscriptionParser.bool(site['isAdult'], false),
        failStreak: 0,
        disabledUntil: 0
      });
    }
    for (const raw of rawLives) {
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
        continue;
      }
      const site = raw as Record<string, object>;
      const url = SubscriptionParser.normalizeUrl(SubscriptionParser.str(site['url']), false);
      if (url === '') {
        skipped++;
        continue;
      }
      if (live.length >= SourceManager.MAX_LIVE) {
        skipped++;
        continue;
      }
      live.push({
        key: '',
        name: SubscriptionParser.str(site['name']) !== '' ? SubscriptionParser.str(site['name']) : url,
        url: url,
        epg: SubscriptionParser.str(site['epg']) !== '' ? SubscriptionParser.str(site['epg']) : undefined,
        enabled: true,
        failStreak: 0,
        disabledUntil: 0
      });
    }
    return {
      name: SubscriptionParser.str(rec['name']),
      format: 'libretv',
      vod: vod,
      live: live,
      skipped: skipped,
      skipDesc: ''
    };
  }

  static parseTvbox(json: object): SubscriptionResult {
    const rec = (json ?? {}) as Record<string, object>;
    const rawSites = Array.isArray(rec['sites']) ? rec['sites'] as object[] : [];
    const rawLives = Array.isArray(rec['lives']) ? rec['lives'] as object[] : [];
    const vod: VodSource[] = [];
    const live: LiveSource[] = [];
    let skipped = 0;
    const skipReasons: Record<string, number> = {};
    const markSkip = (reason: string): void => {
      skipped++;
      const cur = skipReasons[reason];
      skipReasons[reason] = (cur !== undefined ? cur : 0) + 1;
    };
    for (const raw of rawSites) {
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
        continue;
      }
      const site = raw as Record<string, object>;
      const name = SubscriptionParser.str(site['name']);
      const api = SubscriptionParser.str(site['api']);
      const type = SubscriptionParser.num(site['type'], -1);
      if (api === '') {
        markSkip('地址不可用');
        continue;
      }
      if (type === 3 || /^csp_|\.(?:jar|js|py)(?:[?#].*)?$/i.test(api)) {
        markSkip('Spider 引擎');
        continue;
      }
      if (!api.startsWith('http://') && !api.startsWith('https://')) {
        markSkip('地址不可用');
        continue;
      }
      if (SubscriptionParser.num(site['searchable'], 1) === 0) {
        markSkip('不支持搜索');
        continue;
      }
      const importable = type === 1 ||
        ((type === -1 || type === 0 || type === 4) && /\/api\.php\/provide\/vod(?![^?#]*\/at\/xml)(?:[/?#]|$)/i.test(api));
      if (!importable) {
        markSkip(type === 4 ? 'Spider 引擎' : 'XML 接口');
        continue;
      }
      const url = SubscriptionParser.normalizeUrl(api, true);
      if (url === '') {
        markSkip('地址不可用');
        continue;
      }
      let dup = false;
      for (const v of vod) {
        if (v.url === url) {
          dup = true;
          break;
        }
      }
      if (dup) {
        continue;
      }
      if (vod.length >= SourceManager.MAX_VOD) {
        skipped++;
        continue;
      }
      vod.push({
        key: '',
        name: name !== '' ? name : url,
        url: url,
        detail: undefined,
        enabled: true,
        isAdult: false,
        failStreak: 0,
        disabledUntil: 0
      });
    }
    for (const raw of rawLives) {
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
        continue;
      }
      const site = raw as Record<string, object>;
      const name = SubscriptionParser.str(site['name']);
      const url = SubscriptionParser.normalizeUrl(SubscriptionParser.str(site['url']), false);
      if (url === '') {
        markSkip('地址不可用');
        continue;
      }
      const type = SubscriptionParser.num(site['type'], 0);
      if (type !== 0 || (!/\.m3u8?(?:[?#].*)?$/i.test(url) && /\.txt(?:[?#].*)?$/i.test(url))) {
        markSkip('非 M3U 直播');
        continue;
      }
      if (live.length >= SourceManager.MAX_LIVE) {
        skipped++;
        continue;
      }
      live.push({
        key: '',
        name: name !== '' ? name : url,
        url: url,
        epg: SubscriptionParser.str(site['epg']) !== '' ? SubscriptionParser.str(site['epg']) : undefined,
        enabled: true,
        failStreak: 0,
        disabledUntil: 0
      });
    }
    if (vod.length === 0 && live.length === 0) {
      throw new Error(skipped > 0
        ? '配置中没有可直接导入的源：已跳过 ' + skipped + ' 个条目'
        : '配置中没有可用的站点（sites / lives 均为空）');
    }
    let skipDesc = '';
    if (skipped > 0) {
      const parts: string[] = [];
      for (const k of ['Spider 引擎', 'XML 接口', '不支持搜索', '非 M3U 直播', '地址不可用']) {
        const c = skipReasons[k];
        if (c !== undefined && c > 0) {
          parts.push(k + ' ' + c);
        }
      }
      skipDesc = '跳过 ' + skipped + ' 个不可用条目' + (parts.length > 0 ? '（' + parts.join('、') + '）' : '');
    }
    return {
      name: SubscriptionParser.str(rec['name']),
      format: 'tvbox',
      vod: vod,
      live: live,
      skipped: skipped,
      skipDesc: skipDesc
    };
  }

  private static normalizeUrl(raw: string, isVod: boolean): string {
    let u = raw.trim();
    if (u === '') {
      return '';
    }
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      return '';
    }
    if (isVod) {
      u = SourceManager.normalizeApiUrl(u);
    }
    return u;
  }

  private static str(v: object): string {
    return typeof v === 'string' ? (v as string) : '';
  }

  private static bool(v: object, def: boolean): boolean {
    return typeof v === 'boolean' ? (v as boolean) : def;
  }

  private static num(v: object, def: number): number {
    if (typeof v === 'number') {
      return v as number;
    }
    if (typeof v === 'string' && (v as string).trim() !== '' && !isNaN(Number(v as string))) {
      return Number(v as string);
    }
    return def;
  }
}
