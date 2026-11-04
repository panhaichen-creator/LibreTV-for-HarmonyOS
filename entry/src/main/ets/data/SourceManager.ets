/**
 * 视频源管理：点播源（Apple CMS V10）+ 直播源（M3U）
 * 含源健康度：连续失败按阶梯停用（30 分钟 → 24 小时 → 长期），与 LibreTV 对齐
 */

import { Store } from './Store';
import { VodSource, LiveSource } from '../model/Types';
import { EventBus, Events } from '../common/EventBus';
import { Utils } from '../common/Utils';
import { HttpClient } from '../net/HttpClient';
import { M3uParser } from '../model/M3uParser';

export class SourceManager {
  static readonly MAX_VOD = 50;
  static readonly MAX_LIVE = 20;
  private static readonly KEY_VOD = 'sources_vod';
  private static readonly KEY_LIVE = 'sources_live';
  /** 用户手动删除过的源 key（stableId(url)）：自动发现时永不重新加入 */
  private static readonly KEY_REMOVED = 'sources_removed_keys';

  private static inst: SourceManager | null = null;
  private vodSources: VodSource[] = [];
  private liveSources: LiveSource[] = [];
  private removedKeys: string[] = [];
  private loaded = false;

  static shared(): SourceManager {
    if (!SourceManager.inst) {
      SourceManager.inst = new SourceManager();
    }
    return SourceManager.inst;
  }

  load(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    this.vodSources = SourceManager.parseList(Store.shared().getJson(SourceManager.KEY_VOD));
    this.liveSources = SourceManager.parseList(Store.shared().getJson(SourceManager.KEY_LIVE));
    this.removedKeys = SourceManager.parseStringArray(Store.shared().getJson(SourceManager.KEY_REMOVED));
    // 存量迁移：早期版本未剥离查询串/子路径（如 `.../provide/vod/?ac=list`），
    // 请求时会二次追加路径导致 404/超时。此处统一归一化并回写一次。
    if (SourceManager.migrateVodUrls(this.vodSources)) {
      this.save();
    }
    this.ensureSeedLive();
  }

  /**
   * 内置一条「精选直播源」（中国大陆频道为主、自带台标）。
   * 背景：用户自带的直播订阅里，有的地址其实返回网页（解析不出频道），
   * 有的频道全在境外且大量失效，导致「点哪个台都播不了」。
   * 只在第一次升级时补一条，之后用户可以自行删除或替换。
   */
  private ensureSeedLive(): void {
    const flag: string = 'seeded_live_cn_v1';
    if (Store.shared().getBoolean(flag, false)) {
      return;
    }
    Store.shared().putBoolean(flag, true);
    const url: string = 'https://iptv-org.github.io/iptv/countries/cn.m3u';
    for (const s of this.liveSources) {
      if (s.url === url) {
        return;
      }
    }
    if (this.liveSources.length >= SourceManager.MAX_LIVE) {
      return;
    }
    this.liveSources.push({
      key: Utils.stableId(url),
      name: '精选直播（中国大陆）',
      url: url,
      enabled: true,
      failStreak: 0,
      disabledUntil: 0
    });
    this.save();
  }

  /** 把存量点播源的 URL 归一化；有任何改动返回 true */
  private static migrateVodUrls(list: VodSource[]): boolean {
    let changed = false;
    for (const s of list) {
      const fixed = SourceManager.normalizeApiUrl(s.url);
      if (fixed !== '' && fixed !== s.url) {
        s.url = fixed;
        s.key = Utils.stableId(fixed);
        changed = true;
      }
    }
    return changed;
  }

  private static parseList(json: string): VodSource[] {
    const out: VodSource[] = [];
    if (json === '') {
      return out;
    }
    try {
      const arr = JSON.parse(json) as object[];
      if (!Array.isArray(arr)) {
        return out;
      }
      for (const item of arr) {
        const rec = item as Record<string, object>;
        const url = SourceManager.str(rec['url']);
        if (url === '') {
          continue;
        }
        out.push({
          key: SourceManager.str(rec['key']) !== '' ? SourceManager.str(rec['key']) : Utils.stableId(url),
          name: SourceManager.str(rec['name']),
          url: url,
          detail: SourceManager.str(rec['detail']) !== '' ? SourceManager.str(rec['detail']) : undefined,
          enabled: SourceManager.bool(rec['enabled'], true),
          isAdult: SourceManager.bool(rec['isAdult'], false),
          failStreak: SourceManager.num(rec['failStreak'], 0),
          disabledUntil: SourceManager.num(rec['disabledUntil'], 0)
        });
      }
    } catch (e) {
      // 数据损坏时忽略
    }
    return out;
  }

  private save(): void {
    Store.shared().putJson(SourceManager.KEY_VOD, JSON.stringify(this.vodSources));
    Store.shared().putJson(SourceManager.KEY_LIVE, JSON.stringify(this.liveSources));
    EventBus.emit(Events.SOURCES_CHANGED);
  }

  getVodSources(): VodSource[] {
    this.load();
    return this.vodSources.slice();
  }

  getLiveSources(): LiveSource[] {
    this.load();
    return this.liveSources.slice();
  }

  getVodSource(key: string): VodSource | null {
    this.load();
    for (const s of this.vodSources) {
      if (s.key === key) {
        return s;
      }
    }
    return null;
  }

  getLiveSource(key: string): LiveSource | null {
    this.load();
    for (const s of this.liveSources) {
      if (s.key === key) {
        return s;
      }
    }
    return null;
  }

  /**
   * 归一化源地址：还原成「站点根地址」，使 CmsClient 能统一拼 `+ /api.php/provide/vod/?ac=...`。
   *
   * 订阅里的地址形态很杂，必须都归一到根，否则会二次追加路径导致 URL 失效：
   * - `https://x.com/api.php/provide/vod`      → `https://x.com`
   * - `https://x.com/api.php/provide/vod/`     → `https://x.com`
   * - `https://x.com/api.php/provide/vod/?ac=list`（带查询串）→ `https://x.com`
   * - `https://x.com/api.php/provide/vod?wd=xx`            → `https://x.com`
   * - `https://x.com/api.php/provide/vod/from/hym3u8`（子路径）→ `https://x.com`
   * 先砍掉 `?`/`#` 之后的部分，再砍掉结尾的 `/api.php/provide/vod`（可带子路径）。
   */
  static normalizeApiUrl(raw: string): string {
    let u = raw.trim();
    // 去掉查询串与片段：它们不属于路径，且会造成后续拼接错位
    const cut = u.search(/[?#]/);
    if (cut >= 0) {
      u = u.substring(0, cut);
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    const suffix = '/api.php/provide/vod';
    const low = u.toLowerCase();
    if (low.endsWith(suffix)) {
      u = u.substring(0, u.length - suffix.length);
    } else if (low.indexOf(suffix + '/') >= 0) {
      // `.../api.php/provide/vod/from/xxx` 之类：截断到该前缀之前
      u = u.substring(0, low.indexOf(suffix));
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  addVodSource(name: string, rawUrl: string, detail: string): VodSource | null {
    this.load();
    const url = SourceManager.normalizeApiUrl(rawUrl);
    if (url === '' || !url.startsWith('http://') && !url.startsWith('https://')) {
      return null;
    }
    for (const s of this.vodSources) {
      if (s.url === url) {
        return null;
      }
    }
    if (this.vodSources.length >= SourceManager.MAX_VOD) {
      return null;
    }
    const source: VodSource = {
      key: Utils.stableId(url),
      name: name.trim() !== '' ? name.trim() : Utils.hostnameOf(url),
      url: url,
      detail: detail.trim() !== '' ? detail.trim() : undefined,
      enabled: true,
      isAdult: false,
      failStreak: 0,
      disabledUntil: 0
    };
    this.vodSources.push(source);
    this.save();
    return source;
  }

  addVodSources(sources: VodSource[]): number {
    this.load();
    let added = 0;
    for (const s of sources) {
      let exists = false;
      for (const cur of this.vodSources) {
        if (cur.url === s.url) {
          exists = true;
          break;
        }
      }
      if (exists || this.vodSources.length >= SourceManager.MAX_VOD) {
        continue;
      }
      const source: VodSource = {
        key: Utils.stableId(s.url),
        name: s.name,
        url: s.url,
        detail: s.detail,
        enabled: s.enabled,
        isAdult: s.isAdult,
        failStreak: 0,
        disabledUntil: 0
      };
      this.vodSources.push(source);
      added++;
    }
    if (added > 0) {
      this.save();
    }
    return added;
  }

  removeVodSource(key: string): void {
    this.load();
    this.markRemoved(key);
    const next: VodSource[] = [];
    for (const s of this.vodSources) {
      if (s.key !== key) {
        next.push(s);
      }
    }
    this.vodSources = next;
    this.save();
  }

  /** 切换点播源启用状态，返回切换后的状态 */
  setVodEnabled(key: string, enabled: boolean): void {
    this.load();
    for (const s of this.vodSources) {
      if (s.key === key) {
        s.enabled = enabled;
        break;
      }
    }
    this.save();
  }

  /** 切换直播源启用状态 */
  setLiveEnabled(key: string, enabled: boolean): void {
    this.load();
    for (const s of this.liveSources) {
      if (s.key === key) {
        s.enabled = enabled;
        break;
      }
    }
    this.save();
  }

  addLiveSource(name: string, rawUrl: string, epg: string): LiveSource | null {
    this.load();
    const url = rawUrl.trim();
    while (url.endsWith('/') && url.length > 8) {
      // no-op, url is const-like
      break;
    }
    // file:// 允许本地导入的播放列表（粘贴内容 / 本地文件会先存进沙箱再引用）
    if (url === '' || !(url.startsWith('http://') || url.startsWith('https://') || url.startsWith('file://'))) {
      return null;
    }
    for (const s of this.liveSources) {
      if (s.url === url) {
        return null;
      }
    }
    if (this.liveSources.length >= SourceManager.MAX_LIVE) {
      return null;
    }
    const source: LiveSource = {
      key: Utils.stableId(url),
      name: name.trim() !== '' ? name.trim() : (url.startsWith('file://') ? '本地播放列表' : Utils.hostnameOf(url)),
      url: url,
      epg: epg.trim() !== '' ? epg.trim() : undefined,
      enabled: true,
      failStreak: 0,
      disabledUntil: 0
    };
    this.liveSources.push(source);
    this.save();
    return source;
  }

  addLiveSources(sources: LiveSource[]): number {
    this.load();
    let added = 0;
    for (const s of sources) {
      let exists = false;
      for (const cur of this.liveSources) {
        if (cur.url === s.url) {
          exists = true;
          break;
        }
      }
      if (exists || this.liveSources.length >= SourceManager.MAX_LIVE) {
        continue;
      }
      this.liveSources.push({
        key: Utils.stableId(s.url),
        name: s.name,
        url: s.url,
        epg: s.epg,
        enabled: s.enabled,
        failStreak: 0,
        disabledUntil: 0
      });
      added++;
    }
    if (added > 0) {
      this.save();
    }
    return added;
  }

  removeLiveSource(key: string): void {
    this.load();
    this.markRemoved(key);
    const next: LiveSource[] = [];
    for (const s of this.liveSources) {
      if (s.key !== key) {
        next.push(s);
      }
    }
    this.liveSources = next;
    this.save();
  }

  private markRemoved(key: string): void {
    if (key === '' || this.removedKeys.indexOf(key) >= 0) {
      return;
    }
    this.removedKeys.push(key);
    Store.shared().putJson(SourceManager.KEY_REMOVED, JSON.stringify(this.removedKeys));
  }

  /** 该 key 是否被用户手动删除过（自动发现用它过滤） */
  isRemovedKey(key: string): boolean {
    this.load();
    return this.removedKeys.indexOf(key) >= 0;
  }

  private static parseStringArray(json: string): string[] {
    const out: string[] = [];
    if (json === '') {
      return out;
    }
    try {
      const arr = JSON.parse(json) as object[];
      if (!Array.isArray(arr)) {
        return out;
      }
      for (const item of arr) {
        if (typeof item === 'string') {
          out.push(item as string);
        }
      }
    } catch (e) {
      // 数据损坏时忽略
    }
    return out;
  }

  /** 可参与搜索的点播源：启用、未停用；（开启成人过滤时排除成人源） */
  searchableVodSources(adultFilter: boolean): VodSource[] {
    this.load();
    const now = Date.now();
    const out: VodSource[] = [];
    for (const s of this.vodSources) {
      if (!s.enabled) {
        continue;
      }
      if (adultFilter && s.isAdult) {
        continue;
      }
      if (s.disabledUntil > now) {
        continue;
      }
      out.push(s);
    }
    return out;
  }

  enabledLiveSources(): LiveSource[] {
    this.load();
    const now = Date.now();
    const out: LiveSource[] = [];
    for (const s of this.liveSources) {
      if (s.enabled && s.disabledUntil <= now) {
        out.push(s);
      }
    }
    return out;
  }

  isDisabled(key: string): boolean {
    this.load();
    const now = Date.now();
    for (const s of this.vodSources) {
      if (s.key === key) {
        return s.disabledUntil > now;
      }
    }
    for (const s of this.liveSources) {
      if (s.key === key) {
        return s.disabledUntil > now;
      }
    }
    return false;
  }

  /** 停用截止描述 */
  disabledDesc(key: string): string {
    this.load();
    const now = Date.now();
    for (const s of this.vodSources) {
      if (s.key === key) {
        return SourceManager.desc(s.disabledUntil, now);
      }
    }
    for (const s of this.liveSources) {
      if (s.key === key) {
        return SourceManager.desc(s.disabledUntil, now);
      }
    }
    return '';
  }

  private static desc(until: number, now: number): string {
    if (until <= now) {
      return '';
    }
    const left = until - now;
    if (left > 300 * 24 * 3600 * 1000) {
      return '已长期停用';
    }
    if (left > 20 * 3600 * 1000) {
      return '停用至明天';
    }
    const min = Math.ceil(left / 60000);
    return '停用约 ' + min + ' 分钟';
  }

  recordFailure(key: string): void {
    this.load();
    const now = Date.now();
    let changed = false;
    for (const s of this.vodSources) {
      if (s.key === key) {
        s.failStreak += 1;
        if (s.failStreak >= 5) {
          s.disabledUntil = now + 365 * 24 * 3600 * 1000;
        } else if (s.failStreak >= 3) {
          s.disabledUntil = now + 24 * 3600 * 1000;
        } else if (s.failStreak >= 2) {
          s.disabledUntil = now + 30 * 60 * 1000;
        }
        changed = true;
        break;
      }
    }
    if (!changed) {
      for (const s of this.liveSources) {
        if (s.key === key) {
          s.failStreak += 1;
          if (s.failStreak >= 5) {
            s.disabledUntil = now + 365 * 24 * 3600 * 1000;
          } else if (s.failStreak >= 3) {
            s.disabledUntil = now + 24 * 3600 * 1000;
          } else if (s.failStreak >= 2) {
            s.disabledUntil = now + 30 * 60 * 1000;
          }
          changed = true;
          break;
        }
      }
    }
    if (changed) {
      this.save();
    }
  }

  recordSuccess(key: string): void {
    this.load();
    let changed = false;
    for (const s of this.vodSources) {
      if (s.key === key && (s.failStreak !== 0 || s.disabledUntil !== 0)) {
        s.failStreak = 0;
        s.disabledUntil = 0;
        changed = true;
        break;
      }
    }
    if (!changed) {
      for (const s of this.liveSources) {
        if (s.key === key && (s.failStreak !== 0 || s.disabledUntil !== 0)) {
          s.failStreak = 0;
          s.disabledUntil = 0;
          changed = true;
          break;
        }
      }
    }
    if (changed) {
      this.save();
    }
  }

  /** 一键恢复：重置所有源健康度 */
  resetAllHealth(): void {
    this.load();
    for (const s of this.vodSources) {
      s.failStreak = 0;
      s.disabledUntil = 0;
    }
    for (const s of this.liveSources) {
      s.failStreak = 0;
      s.disabledUntil = 0;
    }
    this.save();
  }

  private static autoRefreshStarted: boolean = false;

  /**
   * 定期自动探测点播源健康度。
   * 启动 8 秒后先探测一轮，之后每 30 分钟一轮；并发 4，避免弱网被打满。
   * 探测失败走 recordFailure 的退避停用（30 分钟 → 1 天 → 长期），
   * 相当于自动关闭坏源；用户手动停用（enabled=false）的源不参与探测。
   */
  startAutoRefresh(): void {
    if (SourceManager.autoRefreshStarted) {
      return;
    }
    SourceManager.autoRefreshStarted = true;
    setTimeout(() => {
      SourceManager.probeAllVod();
    }, 8000);
    setInterval(() => {
      SourceManager.probeAllVod();
    }, 30 * 60 * 1000);
  }

  private static async probeAllVod(): Promise<void> {
    const sm = SourceManager.shared();
    const all = sm.getVodSources();
    const enabled: VodSource[] = [];
    for (const s of all) {
      if (s.enabled) {
        enabled.push(s);
      }
    }
    const batch = 4;
    for (let i = 0; i < enabled.length; i += batch) {
      const chunk: VodSource[] = enabled.slice(i, i + batch);
      const tasks: Promise<void>[] = [];
      for (const s of chunk) {
        tasks.push(sm.probeVod(s));
      }
      await Promise.all(tasks);
    }
  }

  private async probeVod(s: VodSource): Promise<void> {
    try {
      const ok = await this.testVodSource(s);
      if (ok) {
        this.recordSuccess(s.key);
      } else {
        this.recordFailure(s.key);
      }
    } catch (e) {
      this.recordFailure(s.key);
    }
  }

  /** 探测点播源是否可用（地址已带 provide/vod 时不再重复拼接，见 CmsClient.apiBase） */
  async testVodSource(source: VodSource): Promise<boolean> {
    const base = source.url.replace(/\/+$/, '');
    const prefix = /provide\/vod$/i.test(base) ? base : base + '/api.php/provide/vod';
    const url = prefix + '/?ac=videolist&wd=test';
    const res = await HttpClient.getText(url, HttpClient.cmsHeaders(), 8000);
    if (!res.ok) {
      return false;
    }
    try {
      const data = JSON.parse(res.text) as Record<string, object>;
      return typeof data['code'] !== 'undefined';
    } catch (e) {
      return false;
    }
  }

  /** 探测直播源：返回频道数，失败返回 -1 */
  async testLiveSource(source: LiveSource): Promise<number> {
    const res = await HttpClient.getTextAny(source.url, { 'User-Agent': HttpClient.UA }, 10000);
    if (!res.ok || res.text === '') {
      return -1;
    }
    const channels = M3uParser.parse(res.text, source.url);
    return channels.length;
  }

  private static str(v: object): string {
    return typeof v === 'string' ? (v as string) : '';
  }

  private static bool(v: object, def: boolean): boolean {
    if (typeof v === 'boolean') {
      return v as boolean;
    }
    return def;
  }

  private static num(v: object, def: number): number {
    if (typeof v === 'number') {
      return v as number;
    }
    return def;
  }
}
