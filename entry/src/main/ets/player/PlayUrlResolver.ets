/**
 * 播放地址解析 —— 决定「网络直链」还是「本地重写后的 m3u8（fd://）」
 * 与 LibreTV 播放链路对齐：m3u8 走广告过滤重写，其余协议（mp4/flv 等）直链播放
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { HttpClient } from '../net/HttpClient';
import { M3u8Rewriter } from '../model/M3u8Rewriter';
import { Utils } from '../common/Utils';

export interface SegmentList {
  urls: string[];
  error: string;
}

export interface ResolvedPlayUrl {
  /** url：网络直链；fd：本地重写后的播放列表 */
  kind: string;
  url: string;
  headers: Record<string, string>;
  /** fd 模式下必须持有不关闭，供播放器读取 */
  file: fs.File | null;
  /** 过滤掉的分片数（仅 m3u8） */
  filteredCount: number;
  error: string;
  /** 远端设备（电视）可直接拉流的地址。
   *  fd:// 只有本机读得到，投屏不能用 —— 这种情况下回落到原始 m3u8
   *  （电视端不过滤广告，但至少投得出去、投屏按钮不再消失）。 */
  castUrl: string;
}

export class PlayUrlResolver {
  /** 播放防盗链头（与 LibreTV 一致：桌面 UA + 站点 Referer） */
  static headersFor(url: string): Record<string, string> {
    const referer = PlayUrlResolver.originOf(url);
    const headers: Record<string, string> = {
      'User-Agent': HttpClient.UA,
      'Referer': referer
    };
    return headers;
  }

  /** 精简显示 url（去掉协议、截断），用于错误提示 */
  static shortUrl(url: string): string {
    let out: string = url;
    const i: number = out.indexOf('://');
    if (i >= 0) {
      out = out.substring(i + 3);
    }
    if (out.length > 70) {
      out = out.substring(0, 70) + '…';
    }
    return out;
  }

  static originOf(url: string): string {
    const protoEnd = url.indexOf('://');
    if (protoEnd < 0) {
      return url;
    }
    const proto = url.substring(0, protoEnd + 3);
    const rest = url.substring(protoEnd + 3);
    const slash = rest.indexOf('/');
    const host = slash >= 0 ? rest.substring(0, slash) : rest;
    return proto + host + '/';
  }

  /** 已知的媒体直链后缀：命中这些就不再当成"网页"去抓 */
  private static readonly MEDIA_EXT: string[] = [
    '.m3u8', '.mp4', '.ts', '.flv', '.mkv', '.mp3', '.m4a', '.avi', '.mov', '.webm'
  ];

  /** 该地址是否可能是"播放页/分享页"（不是媒体直链） */
  static isLikelyPage(url: string): boolean {
    const lower: string = url.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    for (const ext of PlayUrlResolver.MEDIA_EXT) {
      if (lower.indexOf(ext) >= 0) {
        return false;
      }
    }
    return true;
  }

  /**
   * 把"分享页"解析成真实 m3u8 直链。
   * 采集站常见的 share/xxx 页面里会写 const url = "/path/index.m3u8?sign=..."，
   * 抓到后按页面地址转绝对地址；解析不出来就原样返回，交给后续流程。
   */
  static async resolveSharePage(url: string): Promise<string> {
    if (!PlayUrlResolver.isLikelyPage(url)) {
      return url;
    }
    const res = await HttpClient.getTextResilient(url, 12000);
    if (!res.ok || res.text === '') {
      return url;
    }
    const text: string = res.text;
    const patterns: RegExp[] = [
      /const\s+url\s*=\s*["']([^"']+)["']/,
      /var\s+url\s*=\s*["']([^"']+)["']/,
      /sourceUrl\s*[:=]\s*["']([^"']+)["']/,
      /videoUrl\s*[:=]\s*["']([^"']+)["']/,
      /"url"\s*:\s*"([^"]+)"/,
      /url\s*:\s*["']([^"']+)["']/
    ];
    for (const p of patterns) {
      const m = text.match(p);
      if (m !== null && m.length > 1) {
        const candidate: string = m[1] !== undefined ? m[1] : '';
        if (candidate.indexOf('.m3u8') >= 0) {
          return Utils.resolveUrl(url, candidate);
        }
      }
    }
    // 兜底：页面里出现的第一条 .m3u8 链接（手写扫描，避免复杂正则）
    const idx: number = text.indexOf('.m3u8');
    if (idx >= 0) {
      const start: number = text.lastIndexOf('http', idx);
      if (start >= 0) {
        let end: number = idx + 5;
        while (end < text.length) {
          const ch: string = text.charAt(end);
          if (ch === '"' || ch === "'" || ch === ' ' || ch === ')' || ch === '<' || ch === '\n' || ch === '\t') {
            break;
          }
          end++;
        }
        return text.substring(start, end);
      }
    }
    return url;
  }

  static isM3u8(url: string): boolean {
    const lower = url.toLowerCase();
    return lower.indexOf('.m3u8') >= 0;
  }

  /**
   * 解析播放地址。
   * @param adFilter off / loose / strict
   * @param outDir   重写后 m3u8 的沙箱目录
   */
  static async resolve(rawUrl: string, adFilter: string, outDir: string): Promise<ResolvedPlayUrl> {
    // 采集站可能给分享页而不是直链，先转换一次；不是页面会原样返回
    const url: string = await PlayUrlResolver.resolveSharePage(rawUrl);
    const headers = PlayUrlResolver.headersFor(url);
    const fail = (msg: string): ResolvedPlayUrl => ({
      kind: 'url', url: url, headers: headers, file: null, filteredCount: 0, error: msg,
      castUrl: url
    });
    if (!PlayUrlResolver.isM3u8(url)) {
      return { kind: 'url', url: url, headers: headers, file: null, filteredCount: 0, error: '', castUrl: url };
    }
    if (adFilter === 'off') {
      return { kind: 'url', url: url, headers: headers, file: null, filteredCount: 0, error: '', castUrl: url };
    }
    const outcome = await M3u8Rewriter.rewrite(url, headers, adFilter, outDir);
    if (!outcome.ok || outcome.file === null) {
      // 重写失败时退化为直链播放（不阻断观看）
      return fail(outcome.error);
    }
    let size = 0;
    try {
      size = fs.statSync(outcome.localPath).size;
    } catch (e) {
      size = 0;
    }
    const fdUrl = 'fd://' + outcome.file.fd.toString() + '?offset=0&size=' + size.toString();
    return {
      kind: 'fd',
      url: fdUrl,
      headers: headers,
      file: outcome.file,
      filteredCount: outcome.filteredCount,
      error: '',
      // 本机走 fd（广告已过滤），电视够不到沙箱文件：投屏回落到原始 m3u8
      castUrl: url
    };
  }

  /** 供下载使用：拉取播放列表并返回（重写后的）分片绝对地址 */
  static async fetchSegments(rawUrl: string, adFilter: string): Promise<SegmentList> {
    // 与播放一致：分集地址可能是分享页，先换成真实 m3u8 再取分片
    const url: string = await PlayUrlResolver.resolveSharePage(rawUrl);
    const headers = PlayUrlResolver.headersFor(url);
    try {
      let currentUrl = url;
      let text = '';
      for (let depth = 0; depth < 4; depth++) {
        // 用容错请求：很多 CDN 会按 Referer 防盗链，单靠一种请求头会稳定 403
        const res = await HttpClient.getTextResilient(currentUrl, 12000);
        if (!res.ok || res.text === '') {
          // 把状态码和具体地址都带上，否则只看到「请求失败」没法定位是哪一层挂了
          const detail: string = res.status > 0 ? ('HTTP ' + res.status) : res.error;
          return {
            urls: [],
            error: '播放列表请求失败（' + detail + ' · ' + PlayUrlResolver.shortUrl(currentUrl) + '）'
          };
        }
        text = res.text;
        if (text.indexOf('#EXT-X-STREAM-INF') < 0) {
          break;
        }
        const variant = M3u8Rewriter.pickVariant(text, currentUrl);
        if (variant === '') {
          break;
        }
        currentUrl = variant;
      }
      if (text === '') {
        return { urls: [], error: '播放列表为空' };
      }
      const mode = adFilter === 'off' ? 'off' : adFilter;
      const rewritten = M3u8Rewriter.rewriteMediaPlaylist(text, currentUrl, mode);
      const urls: string[] = [];
      const lines = rewritten.content.split('\n');
      for (const line of lines) {
        const t = line.trim();
        if (t === '' || t.startsWith('#')) {
          continue;
        }
        urls.push(t);
      }
      if (urls.length === 0) {
        return { urls: [], error: '播放列表中没有分片' };
      }
      return { urls: urls, error: '' };
    } catch (e) {
      return { urls: [], error: '解析播放列表失败' };
    }
  }

  /** 分片文件名：seg_000000.ts */
  static segName(i: number): string {
    const s = '' + i;
    let out = '';
    for (let k = 0; k < 6 - s.length; k++) {
      out += '0';
    }
    return out + s;
  }

  /**
   * 生成离线播放用的本地 m3u8。
   *
   * 分片必须写成**绝对 file:// URI**，不能写相对文件名：
   * 播放时这份播放列表是通过 fd:// 交给 AVPlayer 的，没有「所在目录」
   * 这个概念，相对名无从解析 → 播放列表能读、分片全 404。
   */
  static buildLocalPlaylist(segCount: number, dir: string): string {
    const lines: string[] = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:10', '#EXT-X-MEDIA-SEQUENCE:0'];
    for (let i = 0; i < segCount; i++) {
      lines.push('#EXTINF:10.0,');
      lines.push('file://' + dir + '/seg_' + PlayUrlResolver.segName(i) + '.ts');
    }
    lines.push('#EXT-X-ENDLIST');
    return lines.join('\n');
  }
}
