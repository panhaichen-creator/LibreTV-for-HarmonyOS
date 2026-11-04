/**
 * 详情缓存（内存，短时效）
 *
 * 背景：详情页与播放页都需要同一份 `VideoDetail`。若播放页再发一次请求，
 * 采集站常有频率限制（同一 id 连续请求第二次就超时/限流），于是详情页明明
 * 正常显示了片名与选集，进入播放页却拉不到集数，最终报「没有可用的播放地址」。
 *
 * 这里以 `sourceKey|vodId` 为键做一次短期缓存：详情页加载成功后写入，
 * 播放页优先读取，命中即可跳过网络请求；未命中或已过期再走原有请求逻辑。
 * 与电脑端 LibreTV 的 DETAIL_CACHE_TTL（60s）同思路。
 */

import { VideoDetail } from './Types';

/** 缓存有效期（毫秒）。仅需覆盖「详情页 → 播放页」这一次跳转，过长会拿到过期的播放地址 */
const TTL: number = 5 * 60 * 1000;
/** 最多缓存条目数，超出后整体清空，避免长期使用堆积 */
const MAX_ENTRIES: number = 40;

interface Entry {
  at: number;
  detail: VideoDetail;
}

export class DetailCache {
  private static readonly map: Map<string, Entry> = new Map<string, Entry>();

  private static key(sourceKey: string, vodId: string): string {
    return sourceKey + '|' + vodId;
  }

  /** 写入缓存 */
  static put(sourceKey: string, vodId: string, detail: VideoDetail): void {
    if (sourceKey === '' || vodId === '') {
      return;
    }
    if (DetailCache.map.size >= MAX_ENTRIES) {
      DetailCache.map.clear();
    }
    DetailCache.map.set(DetailCache.key(sourceKey, vodId), { at: Date.now(), detail: detail });
  }

  /** 读取缓存；不存在或已过期返回 null */
  static get(sourceKey: string, vodId: string): VideoDetail | null {
    const k = DetailCache.key(sourceKey, vodId);
    const hit = DetailCache.map.get(k);
    if (hit === undefined) {
      return null;
    }
    if (Date.now() - hit.at > TTL) {
      DetailCache.map.delete(k);
      return null;
    }
    return hit.detail;
  }

  /** 使指定条目失效（如换源测速后需要重新拉取） */
  static invalidate(sourceKey: string, vodId: string): void {
    DetailCache.map.delete(DetailCache.key(sourceKey, vodId));
  }
}