/**
 * 自动发现视频源（方案 A：设置开关，默认关闭）。
 *
 * 原理：不做「全网搜索」——内置少量社区聚合仓库的订阅地址（每个带多镜像回退，
 * 因为 raw.githubusercontent.com 国内直连基本不通），开启开关后：
 *   启动后台静默拉取（每天最多一次）→ 解析 TVBox 订阅 → 逐个验活 → 只把测通的入库。
 * 聚合仓库本身由 GitHub Actions 每日更新，相当于「源列表自动续命」。
 *
 * 关键约束：
 * - 用户手动删过的源（removedKeys）永远不会被自动加回来；
 * - 每次最多验活 24 个点播候选 + 2 个直播候选，全部后台并发 4，不阻塞 UI；
 * - 所有镜像都拉不到时不动「今日已完成」标记，下次启动重试。
 */

import { VodSource, LiveSource } from './Types';
import { SourceManager } from '../data/SourceManager';
import { SubscriptionParser, SubscriptionResult } from './SubscriptionParser';
import { HttpClient } from '../net/HttpClient';
import { SettingsStore } from '../data/SettingsStore';
import { Store } from '../data/Store';
import { Utils } from '../common/Utils';

interface BootstrapEntry {
  name: string;
  /** 按顺序尝试的镜像地址，第一个返回非空文本的生效 */
  mirrors: string[];
}

export class BootstrapSources {
  /** 单次运行最多验活的点播候选数（并发 6，约 10 轮；后台静默执行，不影响前台） */
  private static readonly MAX_TEST = 60;
  /** 多仓（storeHouse / urls）格式下最多展开的子配置数 */
  private static readonly MAX_SUBS = 5;
  private static readonly KEY_LAST_DATE = 'discover_last_date';
  private static running = false;

  /**
   * 内置聚合订阅（2026-10 调研，均为 GitHub Actions 每日自动更新的活跃仓库）：
   * - Lightconer/tvbox-ysc-config：影视仓配置聚合，每日 10:00/22:00 更新；
   *   「单仓聚合.json」是所有源 sites 合并后的单文件，最稳。
   * - wzh15802/tvbox：自用多仓源（storeHouse 格式），带自有域名备用直链。
   */
  private static readonly ENTRIES: BootstrapEntry[] = [
    {
      name: '聚合·单仓',
      mirrors: [
        'https://cdn.jsdelivr.net/gh/Lightconer/tvbox-ysc-config@main/output/%E5%8D%95%E4%BB%93%E8%81%9A%E5%90%88.json',
        'https://gh-proxy.com/https://raw.githubusercontent.com/Lightconer/tvbox-ysc-config/main/output/%E5%8D%95%E4%BB%93%E8%81%9A%E5%90%88.json',
        'https://raw.githubusercontent.com/Lightconer/tvbox-ysc-config/main/output/%E5%8D%95%E4%BB%93%E8%81%9A%E5%90%88.json'
      ]
    },
    {
      name: '肥猫',
      mirrors: [
        'https://cdn.jsdelivr.net/gh/Lightconer/tvbox-ysc-config@main/output/feimao.json',
        'https://gh-proxy.com/https://raw.githubusercontent.com/Lightconer/tvbox-ysc-config/main/output/feimao.json',
        'https://raw.githubusercontent.com/Lightconer/tvbox-ysc-config/main/output/feimao.json'
      ]
    },
    {
      name: '饭太硬',
      mirrors: [
        'https://cdn.jsdelivr.net/gh/Lightconer/tvbox-ysc-config@main/output/wangerxiao.json',
        'https://gh-proxy.com/https://raw.githubusercontent.com/Lightconer/tvbox-ysc-config/main/output/wangerxiao.json',
        'https://raw.githubusercontent.com/Lightconer/tvbox-ysc-config/main/output/wangerxiao.json'
      ]
    },
    {
      name: 'wzh多仓',
      mirrors: [
        'https://gh-proxy.com/https://raw.githubusercontent.com/wzh15802/tvbox/main/tv.json',
        'https://ghproxy.cxkpro.top/https://raw.githubusercontent.com/wzh15802/tvbox/main/tv.json',
        'https://www.imwzh.com/tv.json'
      ]
    },
    // 以下 4 个为 2026-10-19 实测有可导入 CMS 源的聚合配置（实测可导入数见注释）
    {
      name: '老刘备', // 15 个 CMS
      mirrors: [
        'https://cdn.jsdelivr.net/gh/Lightconer/tvbox-ysc-config@main/output/laoliubei.json',
        'https://gh-proxy.com/https://raw.githubusercontent.com/Lightconer/tvbox-ysc-config/main/output/laoliubei.json',
        'https://raw.githubusercontent.com/Lightconer/tvbox-ysc-config/main/output/laoliubei.json'
      ]
    },
    {
      name: '小马', // 15 个 CMS
      mirrors: [
        'https://cdn.jsdelivr.net/gh/Lightconer/tvbox-ysc-config@main/output/xiaoma.json',
        'https://gh-proxy.com/https://raw.githubusercontent.com/Lightconer/tvbox-ysc-config/main/output/xiaoma.json',
        'https://raw.githubusercontent.com/Lightconer/tvbox-ysc-config/main/output/xiaoma.json'
      ]
    },
    {
      name: '4K小盒子', // 9 个 CMS
      mirrors: [
        'https://cdn.jsdelivr.net/gh/Lightconer/tvbox-ysc-config@main/output/4k.json',
        'https://gh-proxy.com/https://raw.githubusercontent.com/Lightconer/tvbox-ysc-config/main/output/4k.json',
        'https://raw.githubusercontent.com/Lightconer/tvbox-ysc-config/main/output/4k.json'
      ]
    },
    {
      name: '高天流云', // 5 个 CMS（独立仓库，聚合仓失效时仍有冗余）
      mirrors: [
        'https://cdn.jsdelivr.net/gh/gaotianliuyun/gao@master/0821.json',
        'https://gh-proxy.com/https://raw.githubusercontent.com/gaotianliuyun/gao/master/0821.json',
        'https://raw.githubusercontent.com/gaotianliuyun/gao/master/0821.json'
      ]
    }
  ];

  /** 启动路径：延迟 3 秒错开首屏加载，静默执行，不打扰用户 */
  static maybeRunOnLaunch(): void {
    setTimeout(() => {
      BootstrapSources.run(false)
        .then((_s: string) => {
          // 启动路径不弹提示，结果直接体现在源列表里
        })
        .catch((_e: object) => {
        });
    }, 3000);
  }

  /**
   * 执行一次发现。manual=true（设置页手动触发）绕过开关与每日频控。
   * 返回给用户的摘要；启动路径返回空串表示本次无事发生。
   */
  static async run(manual: boolean): Promise<string> {
    if (BootstrapSources.running) {
      return '发现任务正在进行中，请稍候';
    }
    if (!manual) {
      if (!SettingsStore.shared().get().autoDiscover) {
        return '';
      }
      if (Store.shared().getString(BootstrapSources.KEY_LAST_DATE, '') === BootstrapSources.today()) {
        return '';
      }
    }
    BootstrapSources.running = true;
    try {
      const vodCand: VodSource[] = [];
      const liveCand: LiveSource[] = [];
      let fetched = false;
      for (const entry of BootstrapSources.ENTRIES) {
        const text = await BootstrapSources.fetchAny(entry.mirrors);
        if (text === '') {
          continue;
        }
        fetched = true;
        await BootstrapSources.collect(text, vodCand, liveCand, 0);
        if (vodCand.length >= BootstrapSources.MAX_TEST) {
          break;
        }
      }
      // 至少一个订阅拉到了才记「今日已完成」；全失败留给下次启动重试
      if (fetched) {
        Store.shared().putString(BootstrapSources.KEY_LAST_DATE, BootstrapSources.today());
      }
      if (!fetched) {
        return manual ? '发现失败：所有订阅地址都无法访问' : '';
      }

      const sm = SourceManager.shared();
      // 过滤：候选间去重 + 用户手动删过（removedKeys）+ 已存在
      const existingVod = sm.getVodSources();
      const toTest: VodSource[] = [];
      for (const c of vodCand) {
        if (toTest.length >= BootstrapSources.MAX_TEST) {
          break;
        }
        let dup = false;
        for (const t of toTest) {
          if (t.url === c.url) {
            dup = true;
            break;
          }
        }
        if (dup || sm.isRemovedKey(Utils.stableId(c.url))) {
          continue;
        }
        let exists = false;
        for (const e of existingVod) {
          if (e.url === c.url) {
            exists = true;
            break;
          }
        }
        if (!exists) {
          toTest.push(c);
        }
      }

      // 并发 6 逐个验活，只把测通的入库
      let addedVod = 0;
      const batch = 6;
      for (let i = 0; i < toTest.length; i += batch) {
        const chunk = toTest.slice(i, i + batch);
        const tasks: Promise<boolean>[] = [];
        for (const c of chunk) {
          tasks.push((async (): Promise<boolean> => {
            try {
              if (await sm.testVodSource(c)) {
                return sm.addVodSource(c.name, c.url, '') !== null;
              }
            } catch (e) {
              // 验活失败即放弃该候选
            }
            return false;
          })());
        }
        const results = await Promise.all(tasks);
        for (const ok of results) {
          if (ok) {
            addedVod++;
          }
        }
      }

      // 直播候选最多试 4 个（验活要拉整份 m3u，控制流量）
      let addedLive = 0;
      let liveTried = 0;
      const existingLive = sm.getLiveSources();
      for (const c of liveCand) {
        if (liveTried >= 4) {
          break;
        }
        if (sm.isRemovedKey(Utils.stableId(c.url))) {
          continue;
        }
        let exists = false;
        for (const e of existingLive) {
          if (e.url === c.url) {
            exists = true;
            break;
          }
        }
        if (exists) {
          continue;
        }
        liveTried++;
        try {
          const n = await sm.testLiveSource(c);
          if (n > 0 && sm.addLiveSource(c.name, c.url, '') !== null) {
            addedLive++;
          }
        } catch (e) {
          // 忽略
        }
      }

      if (addedVod === 0 && addedLive === 0) {
        return manual ? '本次没有发现新的可用源' : '';
      }
      return '自动发现：新增点播源 ' + addedVod + ' 个' + (addedLive > 0 ? '、直播源 ' + addedLive + ' 个' : '');
    } finally {
      BootstrapSources.running = false;
    }
  }

  /** 依次尝试镜像，返回第一个非空文本；全失败返回空串 */
  private static async fetchAny(mirrors: string[]): Promise<string> {
    for (const url of mirrors) {
      try {
        const res = await HttpClient.getText(url, HttpClient.cmsHeaders(), 12000);
        if (res.ok && res.text.trim() !== '') {
          return res.text;
        }
      } catch (e) {
        // 换下一个镜像
      }
    }
    return '';
  }

  /**
   * 解析订阅文本，把可导入的源收进候选列表。
   * 单仓配置直接走 SubscriptionParser.parse（TVBox 格式，spider/XML 已自动剔除）；
   * 多仓格式（storeHouse / urls）则展开子配置递归解析，最多 MAX_SUBS 个、两层深。
   */
  private static async collect(text: string, vodOut: VodSource[], liveOut: LiveSource[], depth: number): Promise<void> {
    if (vodOut.length >= BootstrapSources.MAX_TEST) {
      return;
    }
    try {
      const r: SubscriptionResult = SubscriptionParser.parse(text);
      for (const v of r.vod) {
        if (vodOut.length >= BootstrapSources.MAX_TEST) {
          break;
        }
        vodOut.push(v);
      }
      for (const l of r.live) {
        liveOut.push(l);
      }
      return;
    } catch (e) {
      // 不是单仓格式，尝试按多仓展开
    }
    if (depth >= 2) {
      return;
    }
    const subUrls: string[] = [];
    try {
      const json = SubscriptionParser.parseJson(text);
      const rec = json as Record<string, object>;
      if (Array.isArray(rec['storeHouse'])) {
        for (const item of rec['storeHouse'] as object[]) {
          if (item === null || typeof item !== 'object' || Array.isArray(item)) {
            continue;
          }
          const u = BootstrapSources.str((item as Record<string, object>)['sourceUrl']);
          if (u.startsWith('http://') || u.startsWith('https://')) {
            subUrls.push(u);
          }
        }
      }
      if (Array.isArray(rec['urls'])) {
        for (const item of rec['urls'] as object[]) {
          let u = '';
          if (typeof item === 'string') {
            u = item as string;
          } else if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
            u = BootstrapSources.str((item as Record<string, object>)['url']);
          }
          if (u.startsWith('http://') || u.startsWith('https://')) {
            subUrls.push(u);
          }
        }
      }
    } catch (e) {
      return;
    }
    if (subUrls.length === 0) {
      return;
    }
    const limited = subUrls.length > BootstrapSources.MAX_SUBS
      ? subUrls.slice(0, BootstrapSources.MAX_SUBS) : subUrls;
    for (const su of limited) {
      if (vodOut.length >= BootstrapSources.MAX_TEST) {
        break;
      }
      const t = await BootstrapSources.fetchAny([su]);
      if (t !== '') {
        await BootstrapSources.collect(t, vodOut, liveOut, depth + 1);
      }
    }
  }

  private static today(): string {
    const d = new Date();
    const m = d.getMonth() + 1;
    const day = d.getDate();
    return d.getFullYear() + '-' + (m < 10 ? '0' + m : '' + m) + '-' + (day < 10 ? '0' + day : '' + day);
  }

  private static str(v: object): string {
    return typeof v === 'string' ? (v as string) : '';
  }
}
