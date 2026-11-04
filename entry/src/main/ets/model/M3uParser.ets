/**
 * M3U / M3U8 直播播放列表解析（与 LibreTV m3u-parser.ts 对齐）
 * - 兼容标准 EXTINF 属性写法与非标准（属性写在标题后）写法
 * - 支持 #EXTGRP 补充分组
 * - 频道按 URL 去重，仅保留 http(s) 流地址
 */

import { LiveChannel } from './Types';
import { Utils } from '../common/Utils';

export class M3uParser {
  static parse(content: string, baseUrl: string): LiveChannel[] {
    const channels: LiveChannel[] = [];
    if (content === '') {
      return channels;
    }
    // TVBOX TXT 直播格式（`组名,#genre#` / `频道名,URL`）与 M3U 完全不同，先分流
    if (M3uParser.isTvboxTxt(content)) {
      return M3uParser.parseTvboxTxt(content);
    }
    // 有些订阅地址其实是个网页（返回 HTML），逐行当 URL 解析只会得到
    // `<!-- xxx -->`、`script>-->` 这类垃圾频道名，直接判为非播放列表。
    if (M3uParser.looksLikeHtml(content)) {
      return channels;
    }
    const seen = new Set<string>();
    const attrRe = /([a-zA-Z0-9_-]+)="([^"]*)"/g;
    const attrStripRe = /[a-zA-Z0-9_-]+="[^"]*"/g;
    let attrs: Record<string, string> = {};
    let title = '';
    let extGroup = '';
    const lines = content.split(/\r?\n/);
    for (const rawLine of lines) {
      const line = rawLine.trim();
      if (line === '') {
        continue;
      }
      const upper = line.toUpperCase();
      if (upper.startsWith('#EXTINF')) {
        attrs = {};
        attrRe.lastIndex = 0;
        let m = attrRe.exec(line);
        while (m !== null) {
          attrs[m[1].toLowerCase()] = m[2].trim();
          m = attrRe.exec(line);
        }
        const stripped = line.replace(attrStripRe, '').replace(/^#EXTINF\s*:\s*/i, '');
        const commaIdx = stripped.indexOf(',');
        title = (commaIdx >= 0 ? stripped.substring(commaIdx + 1) : stripped)
          .trim()
          .replace(/^"+|"+$/g, '');
        extGroup = '';
        continue;
      }
      if (upper.startsWith('#EXTGRP:')) {
        const g = line.substring(8).trim();
        if (g !== '' && !attrs['group-title']) {
          extGroup = g;
        }
        continue;
      }
      if (line.startsWith('#')) {
        continue;
      }
      const url = M3uParser.normalizeStreamUrl(line, baseUrl);
      const curTitle = title;
      const curAttrs = attrs;
      const curGroup = extGroup;
      title = '';
      attrs = {};
      extGroup = '';
      if (url === '' || seen.has(url)) {
        continue;
      }
      seen.add(url);
      const tvgId = curAttrs['tvg-id'] !== undefined ? curAttrs['tvg-id'] : '';
      const logoRaw = curAttrs['tvg-logo'] !== undefined ? curAttrs['tvg-logo'] : '';
      const logo = logoRaw !== '' ? M3uParser.normalizeStreamUrl(logoRaw, baseUrl) : '';
      const groupTitle = curAttrs['group-title'] !== undefined ? curAttrs['group-title'] : '';
      channels.push({
        id: tvgId !== '' ? tvgId : Utils.stableId(url),
        name: curTitle !== '' ? curTitle : M3uParser.nameFromUrl(url),
        url: url,
        logo: logo !== '' ? logo : undefined,
        group: groupTitle !== '' ? groupTitle : (curGroup !== '' ? curGroup : undefined),
        tvgId: tvgId !== '' ? tvgId : undefined
      });
    }
    return channels;
  }

  /** TVBOX TXT 直播格式识别：头部出现 `,#genre#` 分组标记 */
  static isTvboxTxt(content: string): boolean {
    return content.substring(0, 2048).toUpperCase().indexOf(',#GENRE#') >= 0;
  }

  /**
   * TVBOX TXT 直播解析：
   * `组名,#genre#` 声明分组；频道行 `频道名,URL`（分隔符兼容 $），仅保留 http(s) 地址。
   */
  static parseTvboxTxt(content: string): LiveChannel[] {
    const channels: LiveChannel[] = [];
    const seen = new Set<string>();
    let group = '';
    const lines = content.split(/\r?\n/);
    for (const rawLine of lines) {
      const line = rawLine.trim();
      if (line === '' || line.startsWith('#')) {
        continue;
      }
      const upper = line.toUpperCase();
      if (upper.endsWith(',#GENRE#')) {
        group = line.substring(0, line.length - 8).trim();
        continue;
      }
      const parts = M3uParser.splitTxtLine(line);
      if (parts === null) {
        continue;
      }
      let url = parts[1];
      // 有些列表会带 m3u8:// 前缀，剥掉后才是真实地址
      if (url.startsWith('m3u8://')) {
        url = url.substring(7).trim();
      }
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        continue;
      }
      if (seen.has(url)) {
        continue;
      }
      seen.add(url);
      channels.push({
        id: Utils.stableId(url),
        name: parts[0],
        url: url,
        logo: undefined,
        group: group !== '' ? group : undefined,
        tvgId: undefined
      });
    }
    return channels;
  }

  /** 频道行拆分：优先 $ 分隔；否则取「逗号后面像地址」的第一个逗号 */
  private static splitTxtLine(line: string): string[] | null {
    const dollar = line.indexOf('$');
    if (dollar > 0) {
      const name = line.substring(0, dollar).trim();
      const url = line.substring(dollar + 1).trim();
      if (name !== '' && M3uParser.looksLikeStreamUrl(url)) {
        return [name, url];
      }
    }
    let searchFrom = 0;
    while (searchFrom < line.length) {
      const c = line.indexOf(',', searchFrom);
      if (c < 0) {
        break;
      }
      const cand = line.substring(c + 1).trim();
      if (M3uParser.looksLikeStreamUrl(cand)) {
        const name = line.substring(0, c).trim();
        if (name !== '') {
          return [name, cand];
        }
        return null;
      }
      searchFrom = c + 1;
    }
    return null;
  }

  private static looksLikeStreamUrl(t: string): boolean {
    return t.startsWith('http://') || t.startsWith('https://') || t.startsWith('m3u8://') ||
      t.startsWith('rtp://') || t.startsWith('udp://');
  }

  /** 内容是否为网页（HTML）而非 M3U 播放列表 */
  static looksLikeHtml(content: string): boolean {
    const head = content.substring(0, 2048).toLowerCase();
    return head.indexOf('<!doctype') >= 0 || head.indexOf('<html') >= 0;
  }

  /** 仅放行 http(s) 地址，相对地址按订阅 URL 解析 */
  static normalizeStreamUrl(raw: string, baseUrl: string): string {
    const t = raw.trim();
    if (t === '') {
      return '';
    }
    if (t.startsWith('http://') || t.startsWith('https://')) {
      return t;
    }
    // rtp:// udp:// rtsp:// 等无法播放的协议直接丢弃
    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(t)) {
      return '';
    }
    if (baseUrl !== '') {
      return Utils.resolveUrl(baseUrl, t);
    }
    return '';
  }

  private static nameFromUrl(url: string): string {
    try {
      const protoEnd = url.indexOf('://');
      const rest = url.substring(protoEnd + 3);
      const slash = rest.indexOf('/');
      const host = slash >= 0 ? rest.substring(0, slash) : rest;
      const path = slash >= 0 ? rest.substring(slash) : '';
      const segments = path.split('/').filter((s: string) => s !== '');
      if (segments.length > 0) {
        const last = decodeURIComponent(segments[segments.length - 1]).replace(/\.(m3u8?|flv|ts|mp4)$/i, '');
        if (last !== '') {
          return last;
        }
      }
      return host;
    } catch (e) {
      return '未命名频道';
    }
  }
}
