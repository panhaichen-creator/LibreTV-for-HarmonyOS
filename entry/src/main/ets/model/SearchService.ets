/**
 * 聚合搜索服务：并行请求所有可用源 → 过滤 → 跨源同名合并
 * 另提供换源测速（与 LibreTV 换源逻辑对齐）
 */

import { CmsClient } from './CmsClient';
import { SourceManager } from '../data/SourceManager';
import { Settings, VodSource, SearchItem, MergedVideo, SpeedTestItem } from './Types';
import { HttpClient } from '../net/HttpClient';
import { Utils } from '../common/Utils';

interface AggregateResult {
  merged: MergedVideo[];
  failedCount: number;
}

interface SourceSearchResult {
  ok: boolean;
  source: VodSource;
  items: SearchItem[];
}

export class SearchService {
  /** 聚合搜索 */
  static async aggregate(wd: string, settings: Settings): Promise<AggregateResult> {
    const sm = SourceManager.shared();
    const sources = sm.searchableVodSources(settings.adultFilter);
    const results: SearchItem[] = [];
    let failed = 0;
    const wrapped: Promise<SourceSearchResult>[] = [];
    for (const s of sources) {
      wrapped.push(
        CmsClient.search(s, wd)
          .then((items: SearchItem[]): SourceSearchResult => ({ ok: true, source: s, items: items }))
          .catch((): SourceSearchResult => ({ ok: false, source: s, items: [] as SearchItem[] }))
      );
    }
    const settled = await Promise.all(wrapped);
    for (const r of settled) {
      if (r.ok) {
        sm.recordSuccess(r.source.key);
        for (const item of r.items) {
          results.push(item);
        }
      } else {
        sm.recordFailure(r.source.key);
        failed++;
      }
    }
    // 过滤：成人分类 + 相关性
    const filtered: SearchItem[] = [];
    for (const item of results) {
      if (settings.adultFilter && CmsClient.isAdultContent(item.typeName)) {
        continue;
      }
      if (!CmsClient.isRelevant(item.name, wd)) {
        continue;
      }
      filtered.push(item);
    }
    // 跨源同名合并
    const groups: MergedVideo[] = [];
    const index = new Map<string, MergedVideo>();
    for (const item of filtered) {
      const year = item.year !== undefined ? item.year : '';
      const key = Utils.normalizeTitle(item.name) + '|' + year;
      let g = index.get(key);
      if (g === undefined) {
        g = {
          name: item.name,
          year: item.year,
          pic: item.pic,
          typeName: item.typeName,
          remarks: item.remarks,
          area: item.area,
          items: []
        };
        index.set(key, g);
        groups.push(g);
      }
      g.items.push(item);
    }
    return { merged: groups, failedCount: failed };
  }

  /**
   * 换源测速：在各源搜索同名影片，取首个分片地址拉取播放列表计时。
   * 返回按延迟升序的可用源列表。
   */
  static async speedTest(name: string, excludeKey: string, settings: Settings): Promise<SpeedTestItem[]> {
    const sm = SourceManager.shared();
    const all = sm.searchableVodSources(settings.adultFilter);
    const sources: VodSource[] = [];
    for (const s of all) {
      if (s.key !== excludeKey) {
        sources.push(s);
      }
    }
    if (sources.length > 8) {
      sources.splice(8);
    }
    const wrapped: Promise<SpeedTestItem>[] = [];
    for (const s of sources) {
      wrapped.push(SearchService.probeSource(s, name));
    }
    const settled = await Promise.all(wrapped);
    const ok: SpeedTestItem[] = [];
    const bad: SpeedTestItem[] = [];
    for (const r of settled) {
      if (r.ok) {
        ok.push(r);
      } else {
        bad.push(r);
      }
    }
    ok.sort((a, b) => a.latencyMs - b.latencyMs);
    for (const b of bad) {
      ok.push(b);
    }
    return ok;
  }

  private static async probeSource(s: VodSource, name: string): Promise<SpeedTestItem> {
    const miss: SpeedTestItem = {
      sourceKey: s.key,
      sourceName: s.name,
      episodeUrl: '',
      latencyMs: 0,
      ok: false,
      episodeCount: 0
    };
    try {
      const items = await CmsClient.search(s, name);
      let best: SearchItem | null = null;
      for (const it of items) {
        if (CmsClient.isRelevant(it.name, name)) {
          best = it;
          break;
        }
      }
      if (best === null) {
        return miss;
      }
      let url = '';
      let count = 0;
      if (best.playUrl !== undefined && best.playUrl !== '') {
        const eps = CmsClient.extractEpisodes(best.playUrl);
        count = eps.length;
        if (eps.length > 0) {
          url = eps[0].url;
        }
      }
      if (url === '') {
        const detail = await CmsClient.detail(s, best.vodId);
        count = detail.episodes.length;
        if (detail.episodes.length > 0) {
          url = detail.episodes[0].url;
        }
      }
      if (url === '') {
        return miss;
      }
      const t0 = Date.now();
      const res = await HttpClient.getText(url, HttpClient.cmsHeaders(), 6000);
      const latency = Date.now() - t0;
      const playable = res.ok && (res.text.indexOf('#EXTINF') >= 0 || res.text.indexOf('#EXT-X-STREAM-INF') >= 0);
      return {
        sourceKey: s.key,
        sourceName: s.name,
        vodId: best.vodId,
        episodeUrl: url,
        latencyMs: latency,
        ok: playable,
        episodeCount: count
      };
    } catch (e) {
      return miss;
    }
  }
}
