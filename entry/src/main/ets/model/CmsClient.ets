/**
 * Apple CMS V10 采集站客户端：搜索 / 详情 / 详情页 HTML 兜底解析
 * 与 LibreTV cms-parser.ts 逻辑对齐
 */

import { HttpClient } from '../net/HttpClient';
import { VodSource, SearchItem, VideoDetail, Episode, PlayLine } from './Types';

export class CmsClient {
  /**
   * 拼接采集接口的前缀。
   *
   * 绝大多数源的地址是站点根（`https://x.com`），要补 `/api.php/provide/vod`；
   * 但有些源把接口文件名也写进了地址（`http://ip:9981/jacloudapi.php/provide/vod`），
   * 这种地址本身已经是完整的接口前缀，再补一次就变成
   * `.../jacloudapi.php/provide/vod/api.php/provide/vod/` —— 必然 404，
   * 表现为「加进来就一直转圈、搜不到任何东西」。这里按结尾判断，两种形态都兼容。
   */
  private static apiBase(source: VodSource): string {
    const u = source.url.replace(/\/+$/, '');
    return /provide\/vod$/i.test(u) ? u : u + '/api.php/provide/vod';
  }

  /** 搜索：/api.php/provide/vod/?ac=videolist&wd=关键词 */
  static async search(source: VodSource, wd: string): Promise<SearchItem[]> {
    const url = CmsClient.apiBase(source) + '/?ac=videolist&wd=' + encodeURIComponent(wd);
    const res = await HttpClient.getText(url, HttpClient.cmsHeaders(), 8000);
    if (!res.ok) {
      throw new Error('源「' + source.name + '」请求失败');
    }
    return CmsClient.parseSearchList(res.text, source);
  }

  /**
   * 详情获取：优先标准接口 ac=detail（严格按 id 返回），再回退 ac=videolist。
   * 很多 CMS 克隆会忽略 ids 参数、直接返回最新列表，若盲取 list[0]
   * 就会出现「点任何影片都显示同一条」的问题，因此必须校验 vod_id。
   */
  static async detail(source: VodSource, ids: string): Promise<VideoDetail> {
    const byDetail = await CmsClient.tryDetail(source, ids, 'detail');
    if (byDetail !== null) {
      return byDetail;
    }
    const byList = await CmsClient.tryDetail(source, ids, 'videolist');
    if (byList !== null) {
      return byList;
    }
    throw new Error('详情获取失败');
  }

  private static async tryDetail(source: VodSource, ids: string, ac: string): Promise<VideoDetail | null> {
    const url = CmsClient.apiBase(source) + '/?ac=' + ac + '&ids=' + encodeURIComponent(ids);
    const res = await HttpClient.getText(url, HttpClient.cmsHeaders(), 8000);
    if (!res.ok) {
      return null;
    }
    try {
      return CmsClient.parseDetailById(res.text, source, ids);
    } catch (e) {
      return null;
    }
  }

  /** 详情接口无播放地址时，爬取详情页 HTML 提取 m3u8 */
  static async detailFromPage(source: VodSource, ids: string): Promise<VideoDetail> {
    const base = source.detail !== undefined && source.detail !== '' ? source.detail : source.url;
    const pageUrl = base.replace(/\/+$/, '') + '/index.php/vod/detail/id/' + ids + '.html';
    const res = await HttpClient.getText(pageUrl, {
      'User-Agent': HttpClient.UA,
      'Accept': 'text/html,application/xhtml+xml'
    }, 8000);
    if (!res.ok) {
      throw new Error('详情页请求失败');
    }
    return CmsClient.parseDetailPageHtml(res.text, source, ids);
  }

  // ---------- 解析 ----------

  static parseSearchList(json: string, source: VodSource): SearchItem[] {
    let data: object;
    try {
      data = JSON.parse(json) as object;
    } catch (e) {
      throw new Error('源「' + source.name + '」返回数据无效');
    }
    if (typeof data !== 'object' || data === null) {
      throw new Error('源「' + source.name + '」返回数据无效');
    }
    const rec = data as Record<string, object>;
    const list = rec['list'];
    const items: SearchItem[] = [];
    if (list === null || list === undefined) {
      return items;
    }
    if (!Array.isArray(list)) {
      throw new Error('源「' + source.name + '」返回数据无效');
    }
    for (const entry of list as object[]) {
      const vod = entry as Record<string, object>;
      items.push({
        sourceKey: source.key,
        sourceName: source.name,
        vodId: CmsClient.str(vod['vod_id']),
        name: CmsClient.str(vod['vod_name']),
        pic: CmsClient.optStr(vod['vod_pic']),
        typeName: CmsClient.optStr(vod['type_name']),
        year: CmsClient.optStr(vod['vod_year']),
        area: CmsClient.optStr(vod['vod_area']),
        remarks: CmsClient.optStr(vod['vod_remarks']),
        actor: CmsClient.optStr(vod['vod_actor']),
        director: CmsClient.optStr(vod['vod_director']),
        content: CmsClient.optStr(vod['vod_content']),
        playFrom: CmsClient.optStr(vod['vod_play_from']),
        playUrl: CmsClient.optStr(vod['vod_play_url'])
      });
    }
    return items;
  }

  static parseDetail(json: string, source: VodSource): VideoDetail {
    return CmsClient.parseDetailById(json, source, '');
  }

  /** 解析详情并按请求的 ids 校验 vod_id；匹配不到且列表仅一条时才取该条，否则抛错回退。 */
  static parseDetailById(json: string, source: VodSource, ids: string): VideoDetail {
    let data: object;
    try {
      data = JSON.parse(json) as object;
    } catch (e) {
      throw new Error('获取到的详情内容无效');
    }
    const rec = data as Record<string, object>;
    const list = rec['list'];
    if (!Array.isArray(list) || list.length === 0) {
      throw new Error('获取到的详情内容无效');
    }
    let vod: Record<string, object> = list[0] as Record<string, object>;
    if (ids !== '') {
      let matched: Record<string, object> | null = null;
      for (const entry of list as object[]) {
        const item = entry as Record<string, object>;
        if (CmsClient.str(item['vod_id']) === ids) {
          matched = item;
          break;
        }
      }
      if (matched !== null) {
        vod = matched;
      } else if (list.length > 1) {
        throw new Error('该源未按 id 返回对应详情');
      }
    }
    const lines = CmsClient.extractLineGroups(CmsClient.str(vod['vod_play_url']), CmsClient.str(vod['vod_play_from']));
    const defLine = CmsClient.pickDefaultLine(lines);
    let episodes: Episode[] = defLine !== null ? defLine.episodes : [];
    if (episodes.length === 0) {
      episodes = CmsClient.extractM3u8FromText(CmsClient.str(vod['vod_content'])).map((u: string, i: number): Episode => ({
        index: i,
        name: '第' + (i + 1) + '集',
        url: u
      }));
    }
    return {
      episodes: episodes,
      info: {
        title: CmsClient.str(vod['vod_name']),
        cover: CmsClient.optStr(vod['vod_pic']),
        desc: CmsClient.optStr(vod['vod_content']),
        typeName: CmsClient.optStr(vod['type_name']),
        year: CmsClient.optStr(vod['vod_year']),
        area: CmsClient.optStr(vod['vod_area']),
        director: CmsClient.optStr(vod['vod_director']),
        actor: CmsClient.optStr(vod['vod_actor']),
        remarks: CmsClient.optStr(vod['vod_remarks']),
        score: CmsClient.optStr(vod['vod_score']),
        sourceKey: source.key,
        sourceName: source.name,
        sourceUrl: source.url,
        lines: lines.length > 1 ? lines : undefined
      }
    };
  }

  static parseDetailPageHtml(html: string, source: VodSource, ids: string): VideoDetail {
    let matches = html.match(/\$(https?:\/\/[^"'\s]+?\.m3u8)/g);
    if (matches === null) {
      matches = html.match(/\$(https?:\/\/[^"'\s]+\/\d{8}\/\d+_[a-f0-9]+\/index\.m3u8)/g);
    }
    const urls: string[] = [];
    if (matches !== null) {
      for (const m of matches) {
        let u = m.substring(1);
        const paren = u.indexOf('(');
        if (paren > 0) {
          u = u.substring(0, paren);
        }
        let dup = false;
        for (const exist of urls) {
          if (exist === u) {
            dup = true;
            break;
          }
        }
        if (!dup) {
          urls.push(u);
        }
      }
    }
    const episodes: Episode[] = urls.map((u: string, i: number): Episode => ({ index: i, name: '第' + (i + 1) + '集', url: u }));
    const titleMatch = html.match(/<h1[^>]*>([^<]+)<\/h1>/);
    return {
      episodes: episodes,
      info: {
        title: titleMatch !== null ? titleMatch[1].trim() : '视频 ' + ids,
        cover: undefined,
        desc: undefined,
        sourceKey: source.key,
        sourceName: source.name,
        sourceUrl: source.url
      }
    };
  }

  /**
   * 从 vod_play_url 提取全部播放线路：源1$$$源2，集1$URL1#集2$URL2。
   * vod_play_from 与分址串按 $$$ 一一对应，作为线路名。
   */
  static extractLineGroups(playUrl: string, playFrom: string): PlayLine[] {
    const lines: PlayLine[] = [];
    if (playUrl === '') {
      return lines;
    }
    // $$$ 分隔多个播放来源组，组内 # 分集、名称与地址用 $ 分隔。
    // 必须保留源站给的集名（TC / HD / 正片 等），否则全部显示成「第N集」，
    // 多清晰度条目在选集面板里会显示成重名，看起来像只有一集。
    const fromNames = playFrom.split('$$$');
    const groups = playUrl.split('$$$');
    for (let gi = 0; gi < groups.length; gi++) {
      const eps: Episode[] = [];
      for (const ep of groups[gi].split('#')) {
        const idx = ep.indexOf('$');
        if (idx < 0) {
          continue;
        }
        const rawName = ep.substring(0, idx).trim();
        const url = ep.substring(idx + 1).trim();
        if (url.startsWith('http://') || url.startsWith('https://')) {
          eps.push({
            index: eps.length,
            name: rawName !== '' ? rawName : '第' + (eps.length + 1) + '集',
            url: url
          });
        }
      }
      if (eps.length === 0) {
        continue;
      }
      // 重新编号，保证 index 与数组下标一致（PlayerPage 依赖此前提取当前集）
      for (let i = 0; i < eps.length; i++) {
        eps[i].index = i;
      }
      const rawFrom = gi < fromNames.length ? fromNames[gi].trim() : '';
      lines.push({
        name: rawFrom !== '' ? rawFrom : '线路' + (lines.length + 1),
        episodes: eps
      });
    }
    return lines;
  }

  /** 默认线路：优先含 m3u8 直链的；均无 m3u8 时回退第一条 */
  static pickDefaultLine(lines: PlayLine[]): PlayLine | null {
    if (lines.length === 0) {
      return null;
    }
    for (const l of lines) {
      for (const e of l.episodes) {
        if (e.url.indexOf('.m3u8') >= 0) {
          return l;
        }
      }
    }
    return lines[0];
  }

  /** 兼容旧调用：只取默认线路的分集 */
  static extractEpisodes(playUrl: string): Episode[] {
    const line = CmsClient.pickDefaultLine(CmsClient.extractLineGroups(playUrl, ''));
    return line !== null ? line.episodes : [];
  }

  static extractM3u8FromText(text: string): string[] {
    if (text === '') {
      return [];
    }
    const matches = text.match(/\$https?:\/\/[^"'\s]+?\.m3u8/g);
    if (matches === null) {
      return [];
    }
    const out: string[] = [];
    for (const m of matches) {
      out.push(m.replace(/^\$/, ''));
    }
    return out;
  }

  // ---------- 过滤（与 LibreTV 对齐） ----------

  static readonly ADULT_KEYWORDS: string[] = [
    '伦理片', '福利', '倫理片', '福利片', '日本伦理', '日本福利', '日本福利片', '日本伦理片',
    '擦边短剧', '擦边', '韩国伦理', '里番动漫', '门事件', '萝莉少女', '制服诱惑', '国产传媒',
    'cosplay', '黑丝诱惑', '无码', '日本无码', '有码', '日本有码', 'SWAG',
    '网红主播', '色情片', '同性片', '福利视频', '无码高清', '有码高清', '91视频', '自拍偷拍',
    'mini传媒'
  ];

  static isAdultContent(typeName: string | undefined): boolean {
    if (typeName === undefined || typeName === '') {
      return false;
    }
    for (const k of CmsClient.ADULT_KEYWORDS) {
      if (typeName.indexOf(k) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 相关性判断：归一化标题包含归一化关键词（多词查询时每个词都命中） */
  static isRelevant(name: string, wd: string): boolean {
    const nName = CmsClient.norm(name);
    const nWd = CmsClient.norm(wd);
    if (nName === '' || nWd === '') {
      return true;
    }
    if (nName.indexOf(nWd) >= 0) {
      return true;
    }
    const tokens = wd.trim().split(/\s+/);
    if (tokens.length > 1) {
      for (const t of tokens) {
        const n = CmsClient.norm(t);
        if (n === '' || nName.indexOf(n) < 0) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  private static norm(s: string): string {
    return s.toLowerCase().replace(/[\s\u3000-\u303f\uff00-\uffef\u2000-\u206f!-\/:-@[-`{-~]/g, '');
  }

  /**
   * 安全取字符串。
   * 注意：Apple CMS 各站对 `vod_id` 的 JSON 类型不统一——有的是 `"vod_id": "1724"`（字符串），
   * 有的是 `"vod_id": 1724`（数字）。若非字符串一律返回 ''，会导致按 id 校验详情时永远匹配失败，
   * 进而在列表只有一条时误用 list[0]（表现为「点不同影片都显示同一部」）。故此处统一转字符串。
   */
  private static str(v: object): string {
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      return (v as number).toString();
    }
    return '';
  }

  private static optStr(v: object): string | undefined {
    const s = CmsClient.str(v);
    return s !== '' ? s : undefined;
  }
}
