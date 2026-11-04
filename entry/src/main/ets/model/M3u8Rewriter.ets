/**
 * M3U8 播放列表重写器 —— LibreTV 自定义 HLS Loader（广告过滤）的鸿蒙原生等价实现
 *
 * Web 版通过 hls.js 自定义 loader 在内存里改写 m3u8；
 * 原生端没有等价注入点，改为：自行拉取播放列表 → 过滤广告分片 → 相对地址绝对化
 *   → 写入应用沙箱 → AVPlayer 通过 fd:// + APPLICATION_M3U8 播放本地列表。
 *
 * 广告判定（与 LibreTV「严格 / 宽松」两档对齐）：
 * - loose：丢弃被 #EXT-X-DISCONTINUITY 包裹、且整组均为短分片(<5s)的区间（典型广告插槽）；
 *          无 DISCONTINUITY 时退化为丢弃 <1s 的极小分片
 * - strict：丢弃所有 <3s 的分片
 */

import { HttpClient } from '../net/HttpClient';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Utils } from '../common/Utils';

export interface MediaPlaylistResult {
  content: string;
  segmentCount: number;
  filteredCount: number;
}

export interface RewriteOutcome {
  ok: boolean;
  localPath: string;
  /** 必须持有不关闭，供 fd:// 播放使用 */
  file: fs.File | null;
  segmentCount: number;
  filteredCount: number;
  error: string;
}

interface Segment {
  tags: string[];
  uri: string;
  dur: number;
}

export class M3u8Rewriter {
  /** 整组短分片视为广告组的阈值（秒） */
  static readonly AD_RUN_MAX_DUR = 5.0;
  /** strict 模式单分片阈值（秒） */
  static readonly AD_SEG_MAX_DUR = 3.0;
  /** 无 DISCONTINUITY 时的极小分片阈值（秒） */
  static readonly TINY_SEG_DUR = 1.0;
  /**
   * 广告 URI 关键词：命中即判广告。大量采集站把广告插成与正片同长的分片，
   * 时长启发式判不出来，但地址特征很明显（独立广告路径 / 广告联盟域名）。
   */
  static readonly AD_URI_KEYWORDS: string[] = [
    '/ads/', '/ad/', '/adv/', '/ad-', 'advert', 'adshow', 'adplayer',
    'adcreative', 'admaster', 'doubleclick', '/guanggao', '/gg/'
  ];

  static async rewrite(url: string, headers: Record<string, string>, mode: string, outDir: string): Promise<RewriteOutcome> {
    try {
      // 1) 逐级解析主播放列表，选最高码率变体
      let currentUrl = url;
      let text = '';
      for (let depth = 0; depth < 4; depth++) {
        // 与下载链路保持一致：按 Referer 逐级放宽，避免 CDN 防盗链直接 403
        const res = await HttpClient.getTextResilient(currentUrl, 12000);
        if (!res.ok || res.text === '') {
          return M3u8Rewriter.fail('播放列表请求失败: ' + res.error);
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
        return M3u8Rewriter.fail('播放列表为空');
      }
      // 2) 重写媒体播放列表
      const rewritten = M3u8Rewriter.rewriteMediaPlaylist(text, currentUrl, mode);
      if (rewritten.segmentCount === 0) {
        return M3u8Rewriter.fail('播放列表中没有可分片的播放地址');
      }
      // 3) 写入沙箱（文件句柄保持打开，供 fd:// 播放）
      fs.mkdirSync(outDir, true);
      const localPath = outDir + '/index.m3u8';
      const file = fs.openSync(localPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const encoder = util.TextEncoder.create('utf-8');
      const bytes = encoder.encodeInto(rewritten.content);
      fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      return {
        ok: true,
        localPath: localPath,
        file: file,
        segmentCount: rewritten.segmentCount,
        filteredCount: rewritten.filteredCount,
        error: ''
      };
    } catch (e) {
      return M3u8Rewriter.fail('重写播放列表失败: ' + e);
    }
  }

  private static fail(msg: string): RewriteOutcome {
    return { ok: false, localPath: '', file: null, segmentCount: 0, filteredCount: 0, error: msg };
  }

  /** 主播放列表：选 BANDWIDTH 最大的变体 */
  static pickVariant(content: string, baseUrl: string): string {
    const lines = content.split(/\r?\n/);
    let bestUrl = '';
    let bestBw = -1;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        const m = line.match(/BANDWIDTH=(\d+)/);
        const bw = m !== null ? Number(m[1]) : 0;
        for (let j = i + 1; j < lines.length; j++) {
          const u = lines[j].trim();
          if (u !== '' && !u.startsWith('#')) {
            if (bw > bestBw) {
              bestBw = bw;
              bestUrl = Utils.resolveUrl(baseUrl, u);
            }
            break;
          }
        }
      }
    }
    return bestUrl;
  }

  static rewriteMediaPlaylist(content: string, baseUrl: string, mode: string): MediaPlaylistResult {
    const lines = content.split(/\r?\n/);
    const header: string[] = [];
    const segs: Segment[] = [];
    let pending: string[] = [];
    let pendingDur = 0;
    let sawSegment = false;
    let hadEndList = false;
    for (const rawLine of lines) {
      const line = rawLine.trim();
      if (line === '') {
        continue;
      }
      if (line === '#EXTM3U') {
        if (!sawSegment) {
          header.push(line);
        }
        continue;
      }
      if (line.startsWith('#')) {
        if (line.startsWith('#EXTINF:')) {
          const m = line.match(/#EXTINF:\s*([\d.]+)/);
          pendingDur = m !== null ? Number(m[1]) : 0;
          pending.push(line);
        } else if (line.startsWith('#EXT-X-ENDLIST')) {
          hadEndList = true;
        } else if (!sawSegment) {
          header.push(line);
        } else {
          pending.push(line);
        }
        continue;
      }
      segs.push({ tags: pending, uri: line, dur: pendingDur });
      pending = [];
      pendingDur = 0;
      sawSegment = true;
    }

    // 广告过滤
    const dropFlags: boolean[] = [];
    for (let i = 0; i < segs.length; i++) {
      dropFlags.push(false);
    }
    let filtered = 0;
    if (mode === 'loose' || mode === 'strict') {
      // 分片归属统计：出现最多的 host 视为正片源。不少采集站把广告插成
      // 与正片同长的分片，时长启发式判不出来，但广告分片几乎总是来自
      // 不同的 host 或带广告特征路径 —— 整组 DISCONTINUITY 区间全部
      // 外源 / 命中广告关键词时按广告组丢弃。
      const segHosts: string[] = [];
      const hostCount: Record<string, number> = {};
      for (const s of segs) {
        const h = Utils.hostnameOf(s.uri);
        segHosts.push(h);
        const c = hostCount[h];
        hostCount[h] = (c !== undefined ? c : 0) + 1;
      }
      let mainHost = '';
      let mainCount = 0;
      const hostKeys = Object.keys(hostCount);
      for (const h of hostKeys) {
        if (hostCount[h] > mainCount) {
          mainCount = hostCount[h];
          mainHost = h;
        }
      }
      const isAdUri = (uri: string): boolean => {
        const low = uri.toLowerCase();
        for (const k of M3u8Rewriter.AD_URI_KEYWORDS) {
          if (low.indexOf(k) >= 0) {
            return true;
          }
        }
        return false;
      };

      // 按 DISCONTINUITY 切 run
      const runRanges: number[][] = [];
      let runStart = 0;
      for (let i = 1; i < segs.length; i++) {
        let hasDisc = false;
        for (const t of segs[i].tags) {
          if (t.startsWith('#EXT-X-DISCONTINUITY')) {
            hasDisc = true;
            break;
          }
        }
        if (hasDisc) {
          runRanges.push([runStart, i]);
          runStart = i;
        }
      }
      runRanges.push([runStart, segs.length]);

      if (mode === 'loose') {
        if (runRanges.length > 1) {
          for (const r of runRanges) {
            let allShort = true;
            // host 多样性足够（mainCount>=3）时才启用外源判定，
            // 避免只有两三个分片的小列表误杀正片
            let allForeign = mainCount >= 3;
            let hasAdUri = false;
            for (let i = r[0]; i < r[1]; i++) {
              if (segs[i].dur >= M3u8Rewriter.AD_RUN_MAX_DUR) {
                allShort = false;
              }
              if (segHosts[i] === mainHost) {
                allForeign = false;
              }
              if (isAdUri(segs[i].uri)) {
                hasAdUri = true;
              }
            }
            if (allShort || allForeign || hasAdUri) {
              for (let i = r[0]; i < r[1]; i++) {
                dropFlags[i] = true;
              }
            }
          }
        } else {
          for (let i = 0; i < segs.length; i++) {
            if (segs[i].dur < M3u8Rewriter.TINY_SEG_DUR || isAdUri(segs[i].uri)) {
              dropFlags[i] = true;
            }
          }
        }
      } else {
        for (let i = 0; i < segs.length; i++) {
          if (segs[i].dur < M3u8Rewriter.AD_SEG_MAX_DUR || isAdUri(segs[i].uri)) {
            dropFlags[i] = true;
          }
        }
        // strict：整组外源的 DIS 区间也丢
        if (runRanges.length > 1 && mainCount >= 3) {
          for (const r of runRanges) {
            let allForeign = true;
            for (let i = r[0]; i < r[1]; i++) {
              if (segHosts[i] === mainHost) {
                allForeign = false;
                break;
              }
            }
            if (allForeign) {
              for (let i = r[0]; i < r[1]; i++) {
                dropFlags[i] = true;
              }
            }
          }
        }
      }
      // 兜底：全丢时保留全部
      let keptCount = 0;
      for (const d of dropFlags) {
        if (!d) {
          keptCount++;
        }
      }
      if (keptCount === 0) {
        for (let i = 0; i < dropFlags.length; i++) {
          dropFlags[i] = false;
        }
      }
      for (const d of dropFlags) {
        if (d) {
          filtered++;
        }
      }
    }

    // 输出
    const out: string[] = header.slice();
    let lastKey = '';
    let lastMap = '';
    let kept = 0;
    for (let i = 0; i < segs.length; i++) {
      const s = segs[i];
      // 更新加密状态（即使分片被丢弃，后续分片仍沿用其 KEY/MAP）
      for (const t of s.tags) {
        if (t.startsWith('#EXT-X-KEY')) {
          lastKey = t;
        } else if (t.startsWith('#EXT-X-MAP')) {
          lastMap = t;
        }
      }
      if (dropFlags[i]) {
        continue;
      }
      let keyEmitted = false;
      let mapEmitted = false;
      for (const t of s.tags) {
        if (t.startsWith('#EXT-X-KEY')) {
          out.push(M3u8Rewriter.rewriteUriAttr(t, baseUrl));
          keyEmitted = true;
        } else if (t.startsWith('#EXT-X-MAP')) {
          out.push(M3u8Rewriter.rewriteUriAttr(t, baseUrl));
          mapEmitted = true;
        } else if (t.startsWith('#EXT-X-DISCONTINUITY')) {
          // 丢弃广告组后不再保留其 DISCONTINUITY 标记
          if (i === 0) {
            out.push(t);
          }
        } else {
          out.push(t);
        }
      }
      if (!keyEmitted && lastKey !== '') {
        out.push(M3u8Rewriter.rewriteUriAttr(lastKey, baseUrl));
      }
      if (!mapEmitted && lastMap !== '') {
        out.push(M3u8Rewriter.rewriteUriAttr(lastMap, baseUrl));
      }
      out.push(Utils.resolveUrl(baseUrl, s.uri));
      kept++;
    }
    if (hadEndList) {
      out.push('#EXT-X-ENDLIST');
    }
    return { content: out.join('\n'), segmentCount: kept, filteredCount: filtered };
  }

  /** 重写标签中的 URI="..." 为绝对地址 */
  static rewriteUriAttr(line: string, baseUrl: string): string {
    const marker = 'URI="';
    let result = line;
    let searchFrom = 0;
    for (;;) {
      const idx = result.indexOf(marker, searchFrom);
      if (idx < 0) {
        break;
      }
      const start = idx + marker.length;
      const end = result.indexOf('"', start);
      if (end < 0) {
        break;
      }
      const uri = result.substring(start, end);
      const abs = Utils.resolveUrl(baseUrl, uri);
      result = result.substring(0, start) + abs + result.substring(end);
      searchFrom = start + abs.length;
    }
    return result;
  }
}
