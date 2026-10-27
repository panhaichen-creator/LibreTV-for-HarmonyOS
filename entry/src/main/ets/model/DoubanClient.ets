/**
 * 豆瓣推荐（电影 / 电视剧分类浏览）
 * 与 LibreTV douban.ts 使用同一接口
 */

import { HttpClient } from '../net/HttpClient';
import { RecommendItem } from './Types';

/** 豆瓣 suggest 接口里我们只关心这两个字段 */
interface DoubanSubject {
  id: string;
  type: string;
}

/**
 * 搜索联想条目。
 *
 * 只保留「片名 + 年份 + 类型」三样：联想面板一行放不下更多，
 * 而这三个字段正好够用户判断「是不是我要的那部」。
 * 影人（celebrity）条目在 suggest 里也很多，但点进去搜不到片，直接过滤掉。
 */
export interface SuggestItem {
  title: string;
  year: string;
  /** 电影 / 剧集 —— 面板右侧的小标签 */
  kind: string;
  /** 豆瓣条目 id，留给以后「直接进条目详情」用 */
  id: string;
}

export class DoubanClient {
  /** rexxar（m.douban.com 的 App 接口）认移动端 UA，桌面 UA 容易被判爬虫 */
  private static readonly UA_MOBILE: string =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) ' +
      'Version/16.0 Mobile/15E148 Safari/604.1';

  static async recommend(type: string, tag: string, pageStart: number, pageSize: number): Promise<RecommendItem[]> {
    const url = 'https://movie.douban.com/j/search_subjects?type=' + type +
      '&tag=' + encodeURIComponent(tag) +
      '&sort=recommend&page_limit=' + pageSize + '&page_start=' + pageStart;
    const res = await HttpClient.getText(url, {
      'User-Agent': HttpClient.UA,
      'Referer': 'https://movie.douban.com/',
      'Accept': 'application/json'
    }, 8000);
    if (!res.ok) {
      return [];
    }
    try {
      const data = JSON.parse(res.text) as Record<string, object>;
      const subjects = data['subjects'];
      if (!Array.isArray(subjects)) {
        return [];
      }
      const items: RecommendItem[] = [];
      for (const entry of subjects as object[]) {
        const s = entry as Record<string, object>;
        const title = DoubanClient.str(s['title']);
        const cover = DoubanClient.str(s['cover']);
        if (title === '' || cover === '') {
          continue;
        }
        const rate = DoubanClient.str(s['rate']);
        items.push({
          id: DoubanClient.str(s['id']),
          title: title,
          cover: cover,
          rating: rate !== '' && rate !== '0' ? rate : undefined,
          isTv: type === 'tv'
        });
      }
      return items;
    } catch (e) {
      return [];
    }
  }

  /**
   * 按「分类 + 类型 + 地区 + 排序」浏览。
   *
   * 与 recommend() 走的是两个不同接口：
   *   · recommend  -> j/search_subjects    只支持 tag 白名单，无法组合筛选
   *   · browse     -> j/new_search_subjects 支持 tags / genres / countries / sort
   *
   * 参数含义（均已实测）：
   *   tags     电影 / 电视剧 / 综艺 / 纪录片 / 动漫
   *   genres   剧情 / 喜剧 / 动作 / 爱情 / 科幻 / 动画 / 悬疑 …  空串表示不限
   *   countries 中国大陆 / 美国 / 中国香港 / 日本 / 韩国 …        空串表示不限
   *   sort     T=标记最多(综合)  R=最近上映(发行时间从近到远)  S=评分从高到低
   *   range    评分区间，'0,10' 表示不限；带下限会滤掉无评分条目
   *   start    偏移量，每页固定返回 20 条
   *
   * 注意 1：sort=R 的头部是一批「刚建条目、还没人打分」的新片 —— 占位标题、
   *   网络短剧、维密秀录像之类，rate 为空。直接展示会让人以为接口坏了，
   *   所以 R 先按 range=5,10 取；若过滤后一条不剩再退回 range=0,10 兜底，
   *   保证「最新」永远有内容可显示。
   * 注意 2：该接口偶发返回空 data（疑似频控），调用方必须准备回退方案。
   */
  static async browse(tags: string, genre: string, country: string, sort: string,
    start: number): Promise<RecommendItem[]> {
    const ranges: string[] = sort === 'R' ? ['5,10', '0,10'] : ['0,10'];
    for (const range of ranges) {
      const got: RecommendItem[] =
        await DoubanClient.browseOnce(tags, genre, country, sort, range, start);
      if (got.length > 0) {
        return got;
      }
    }
    return [];
  }

  /** browse() 的单次请求实现，range 由调用方决定 */
  private static async browseOnce(tags: string, genre: string, country: string, sort: string,
    range: string, start: number): Promise<RecommendItem[]> {
    let url: string = 'https://movie.douban.com/j/new_search_subjects?sort=' + sort +
      '&range=' + range + '&start=' + start + '&tags=' + encodeURIComponent(tags);
    if (genre !== '') {
      url += '&genres=' + encodeURIComponent(genre);
    }
    if (country !== '') {
      url += '&countries=' + encodeURIComponent(country);
    }
    const res = await HttpClient.getText(url, {
      'User-Agent': HttpClient.UA,
      'Referer': 'https://movie.douban.com/',
      'Accept': 'application/json'
    }, 8000);
    if (!res.ok) {
      return [];
    }
    try {
      const data = JSON.parse(res.text) as Record<string, object>;
      const subjects = data['data'];
      if (!Array.isArray(subjects)) {
        return [];
      }
      const items: RecommendItem[] = [];
      for (const entry of subjects as object[]) {
        const s = entry as Record<string, object>;
        const title = DoubanClient.str(s['title']);
        const cover = DoubanClient.str(s['cover']);
        if (title === '' || cover === '') {
          continue;
        }
        const rate = DoubanClient.str(s['rate']);
        items.push({
          id: DoubanClient.str(s['id']),
          title: title,
          cover: cover,
          rating: rate !== '' && rate !== '0' ? rate : undefined,
          isTv: tags === '电视剧'
        });
      }
      return items;
    } catch (e) {
      return [];
    }
  }

  /**
   * 豆瓣电影 Top 250 排行榜。
   * 榜单没有官方 JSON 接口，解析 HTML 榜单页；每页固定 25 条，start 为 25 的倍数。
   * 页面被反爬拦截时返回空数组，由调用方兜底。
   */
  static async top250(start: number): Promise<RecommendItem[]> {
    const url = 'https://movie.douban.com/top250?start=' + start;
    const res = await HttpClient.getText(url, {
      'User-Agent': HttpClient.UA,
      'Referer': 'https://movie.douban.com/',
      'Accept': 'text/html,application/xhtml+xml'
    }, 10000);
    if (!res.ok || res.text === '') {
      return [];
    }
    const html = res.text;
    const items: RecommendItem[] = [];
    const chunks = html.split('<div class="item">');
    for (let i = 1; i < chunks.length; i++) {
      const block = chunks[i];
      const idM = block.match(/subject\/(\d+)\//);
      const titleM = block.match(/<span property="v:itemreviewed">([^<]+)<\/span>/);
      const imgM = block.match(/<img src="([^"]+)"/);
      const rateM = block.match(/<span class="rating_num"[^>]*>([\d.]+)<\/span>/);
      if (titleM === null || imgM === null) {
        continue;
      }
      const rate = rateM !== null ? rateM[1] : '';
      items.push({
        id: idM !== null ? idM[1] : 'top250_' + (start + i),
        title: titleM[1].trim(),
        cover: imgM[1],
        rating: rate !== '' && rate !== '0' ? rate : undefined,
        isTv: false
      });
    }
    return items;
  }

  /**
   * 搜索联想：输入即出的候选片名。
   *
   * 用豆瓣的 subject_suggest，而不是拿关键词去采集站搜一遍：
   *   · suggest 是「输入即出」的轻接口，首字就有结果，通常 200~600ms；
   *   · 采集站搜索要走「多个源并发 + 解析 + 排序」，1~3 秒起步，
   *     拿来做成输入联想会把输入框拖死。
   * 超时压到 4 秒：联想是「锦上添花」，宁可空着回落本地筛选，也不能拖住输入。
   */
  static async suggest(key: string): Promise<SuggestItem[]> {
    const q: string = key.trim();
    if (q === '') {
      return [];
    }
    const url = 'https://movie.douban.com/j/subject_suggest?q=' + encodeURIComponent(q);
    const res = await HttpClient.getText(url, {
      'User-Agent': HttpClient.UA,
      'Referer': 'https://movie.douban.com/',
      'Accept': 'application/json'
    }, 4000);
    if (!res.ok || res.text === '') {
      return [];
    }
    try {
      const arr = JSON.parse(res.text) as object;
      if (!Array.isArray(arr)) {
        return [];
      }
      const out: SuggestItem[] = [];
      for (const entry of arr as object[]) {
        const o = entry as Record<string, object>;
        const title = DoubanClient.str(o['title']);
        const type = DoubanClient.str(o['type']);
        if (title === '' || (type !== 'movie' && type !== 'tv')) {
          continue;
        }
        DoubanClient.pushUnique(out, {
          title: title,
          year: DoubanClient.str(o['year']),
          kind: type === 'tv' ? '剧集' : '电影',
          id: DoubanClient.str(o['id'])
        });
      }
      return DoubanClient.rank(out, q, 6);
    } catch (e) {
      return [];
    }
  }

  /**
   * 搜索联想（慢接口，专治「单字不出结果」）。
   *
   * subject_suggest 对单个汉字几乎不工作（实测「流 / 三 / 星」都是 0 条），
   * 用户看到的就是「打第一个字没反应，打第二个字才跳结果」。
   * 这里换成豆瓣 App 的站内搜索接口，单字能回 8~12 条**真实片名**，500~1000ms。
   *
   * 两个坑都实测过：
   *   · 不带 type：单字结果几乎全是图书（「流」20 条全图书），过滤完一场空；
   *   · type=tv：接口直接 HTTP 500（连「狂飙」都 500），不能用。
   * 所以固定 type=movie；剧集名交给 subject_suggest（≥2 字它覆盖得不错）。
   */
  static async searchTitles(key: string): Promise<SuggestItem[]> {
    const q: string = key.trim();
    if (q === '') {
      return [];
    }
    const url = 'https://m.douban.com/rexxar/api/v2/search/subjects?q=' + encodeURIComponent(q) +
      '&type=movie&start=0&count=12';
    const res = await HttpClient.getText(url, {
      'User-Agent': DoubanClient.UA_MOBILE,
      'Referer': 'https://m.douban.com/',
      'Accept': 'application/json'
    }, 3000);
    if (!res.ok || res.text === '') {
      return [];
    }
    try {
      const data = JSON.parse(res.text) as Record<string, object>;
      const subjects = data['subjects'] as Record<string, object>;
      if (subjects === undefined || subjects === null) {
        return [];
      }
      const items = subjects['items'];
      if (!Array.isArray(items)) {
        return [];
      }
      const out: SuggestItem[] = [];
      for (const entry of items as object[]) {
        const o = entry as Record<string, object>;
        const target = o['target'] as Record<string, object>;
        if (target === undefined || target === null) {
          continue;
        }
        const title = DoubanClient.str(target['title']);
        const ttype = DoubanClient.str(o['target_type']);
        if (title === '' || (ttype !== 'movie' && ttype !== 'tv')) {
          continue;
        }
        DoubanClient.pushUnique(out, {
          title: title,
          year: DoubanClient.str(target['year']),
          kind: ttype === 'tv' ? '剧集' : '电影',
          id: DoubanClient.str(target['id'])
        });
      }
      return DoubanClient.rank(out, q, 6);
    } catch (e) {
      return [];
    }
  }

  /**
   * 前缀命中排前面。
   * 打「流浪」时，《流浪地球》应该排在《XX流浪汉》前面 ——
   * subject_suggest 是按热度排的，不重排经常把正主压到第二三位。
   */
  private static rank(items: SuggestItem[], kw: string, cap: number): SuggestItem[] {
    const head: SuggestItem[] = [];
    const tail: SuggestItem[] = [];
    for (const it of items) {
      if (it.title.indexOf(kw) === 0) {
        head.push(it);
      } else {
        tail.push(it);
      }
    }
    const out: SuggestItem[] = [];
    for (const it of head) {
      if (out.length >= cap) {
        break;
      }
      DoubanClient.pushUnique(out, it);
    }
    for (const it of tail) {
      if (out.length >= cap) {
        break;
      }
      DoubanClient.pushUnique(out, it);
    }
    return out;
  }

  private static pushUnique(list: SuggestItem[], it: SuggestItem): void {
    for (const o of list) {
      if (o.title === it.title) {
        return;
      }
    }
    list.push(it);
  }

  /**
   * 单片评分（详情页用）。
   *
   * 豆瓣没有「按标题直接给评分」的接口，只能两步：
   *   1. j/subject_suggest?q=标题  -> 候选条目（id / type / year，无评分）
   *   2. m.douban.com/rexxar/api/v2/{movie|tv}/{id} -> rating.value
   *
   * 选条目：同名且年份一致 > 同名 > 标题互相包含 > 放弃。
   * 任何一步失败都返回空串 —— 详情页拿不到评分就不显示，绝不能因为豆瓣抖动
   * 拖慢或搞坏整个详情页。
   */
  static async ratingOf(title: string, year: string): Promise<string> {
    const key = DoubanClient.cleanTitle(title);
    if (key === '') {
      return '';
    }
    const hit = await DoubanClient.pickSubject(key, year);
    if (hit === null) {
      return '';
    }
    const api: string = 'https://m.douban.com/rexxar/api/v2/' +
      (hit.type === 'tv' ? 'tv' : 'movie') + '/' + hit.id;
    const res = await HttpClient.getText(api, {
      'User-Agent': HttpClient.UA,
      'Referer': 'https://m.douban.com/',
      'Accept': 'application/json'
    }, 8000);
    if (!res.ok || res.text === '') {
      return '';
    }
    try {
      const data = JSON.parse(res.text) as Record<string, object>;
      const rating = data['rating'];
      if (rating === undefined || rating === null) {
        return '';
      }
      const v = (rating as Record<string, object>)['value'];
      let num: number = 0;
      if (typeof v === 'number') {
        num = v;
      } else if (typeof v === 'string') {
        num = Number.parseFloat(v);
      }
      if (Number.isNaN(num) || num <= 0) {
        return '';
      }
      return num.toFixed(1);
    } catch (e) {
      return '';
    }
  }

  /** 清洗标题：去掉书名号/引号这些源站常见的装饰符，豆瓣标题里不会有 */
  private static cleanTitle(title: string): string {
    return title.replace(/[《》「」【】]/g, '').trim();
  }

  /** 在 suggest 结果里挑最像的那一条 */
  private static async pickSubject(key: string, year: string): Promise<DoubanSubject | null> {
    const url = 'https://movie.douban.com/j/subject_suggest?q=' + encodeURIComponent(key);
    const res = await HttpClient.getText(url, {
      'User-Agent': HttpClient.UA,
      'Referer': 'https://movie.douban.com/',
      'Accept': 'application/json'
    }, 6000);
    if (!res.ok || res.text === '') {
      return null;
    }
    try {
      const arr = JSON.parse(res.text) as object;
      if (!Array.isArray(arr)) {
        return null;
      }
      let exact: DoubanSubject | null = null;
      let sameYear: DoubanSubject | null = null;
      let loose: DoubanSubject | null = null;
      for (const entry of arr as object[]) {
        const o = entry as Record<string, object>;
        const id = DoubanClient.str(o['id']);
        const name = DoubanClient.str(o['title']);
        if (id === '' || name === '') {
          continue;
        }
        const cand: DoubanSubject = { id: id, type: DoubanClient.str(o['type']) };
        if (name === key) {
          if (exact === null) {
            exact = cand;
          }
          if (year !== '' && DoubanClient.str(o['year']) === year) {
            sameYear = cand;
            break;
          }
        } else if (loose === null && (name.indexOf(key) >= 0 || key.indexOf(name) >= 0)) {
          loose = cand;
        }
      }
      if (sameYear !== null) {
        return sameYear;
      }
      if (exact !== null) {
        return exact;
      }
      return loose;
    } catch (e) {
      return null;
    }
  }

  private static str(v: object): string {
    return typeof v === 'string' ? v : '';
  }
}
