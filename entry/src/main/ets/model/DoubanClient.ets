/**
 * 豆瓣推荐（电影 / 电视剧分类浏览）
 *
 * 2026-11 起豆瓣把 movie.douban.com 的桌面 JSON 接口（j/search_subjects、
 * j/new_search_subjects、j/subject_suggest）与 HTML 榜单页全部封死（一律 403），
 * 桌面 UA、移动 UA、带 bid Cookie 都救不回来。
 * 现在全线改走 m.douban.com 的 rexxar App 接口：
 *   · 浏览/筛选  -> /rexxar/api/v2/{movie|tv}/recommend
 *   · 站内搜索   -> /rexxar/api/v2/search/subjects
 *   · 条目详情   -> /rexxar/api/v2/{movie|tv}/{id}
 *
 * rexxar 的坑（逐个实测，别删）：
 *   · 只认移动端 UA，桌面 UA 直接被判爬虫；
 *   · tags=热门 / tags=最新 是被下线的标签，返回 0 条；
 *     可用的有：电影 / 电视剧 / 综艺 / 纪录片 / 动漫 / 日本动画 / 经典 / 豆瓣高分；
  *   · sort 取值：T=综合排序 U=近期热度 R=首映时间 S=高分优先；
  *   · selected_categories 已被服务端整体忽略（类型/地区传了和不传结果一样，
  *     实测 2026-11），类型/地区/年份筛选只能拿条目自带的 card_subtitle
  *     （格式「年份 / 地区 / 类型 / 导演 / 主演」）在客户端过滤；
  *   · items 里混着片单（playlist）和广告（ad）卡片，只认 type=movie/tv 的条目；
  *   · 分页用 start（条目偏移）+ count（每页条数），浏览模式总量约 500。
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
 * 影人（celebrity）条目在联想里也很多，但点进去搜不到片，直接过滤掉。
 */
export interface SuggestItem {
  title: string;
  year: string;
  /** 电影 / 剧集 —— 面板右侧的小标签 */
  kind: string;
  /** 豆瓣条目 id，留给以后「直接进条目详情」用 */
  id: string;
}

/** 热播分页结果：items 为过滤后的条目；nextStart 为继续取数的原始偏移，-1 表示已取尽 */
export interface HotRecentPage {
  items: RecommendItem[];
  nextStart: number;
}

export class DoubanClient {
  /** rexxar（m.douban.com 的 App 接口）认移动端 UA，桌面 UA 容易被判爬虫 */
  private static readonly UA_MOBILE: string =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) ' +
      'Version/16.0 Mobile/15E148 Safari/604.1';

  /** rexxar 接口通用请求头 */
  private static rexxarHeaders(): Record<string, string> {
    return {
      'User-Agent': DoubanClient.UA_MOBILE,
      'Referer': 'https://m.douban.com/',
      'Accept': 'application/json'
    };
  }

  /**
   * rexxar 浏览核心：recommend / browse / top250 全部走这一个请求。
   *
   * @param kind    movie 或 tv（rexxar 的两类条目接口）
   * @param tags    分类标签（电影/电视剧/综艺/纪录片/动漫/经典/豆瓣高分…）
   * @param genre   类型筛选（剧情/喜剧/动作…），空串表示不限
   * @param country 地区筛选（中国大陆/美国…），空串表示不限
   * @param sort    T=综合 U=热度 R=首映时间 S=高分
   * @param start   条目偏移（分页）
   * @param count   每页条数
   */
  private static async rexxarRecommend(kind: string, tags: string, genre: string, country: string,
    sort: string, start: number, count: number): Promise<RecommendItem[]> {
    // selected_categories：键固定为「类型」「地区」，只放用户选了的项
    const cats: Record<string, string> = {};
    if (genre !== '') {
      cats['类型'] = genre;
    }
    if (country !== '') {
      cats['地区'] = country;
    }
    const url: string = 'https://m.douban.com/rexxar/api/v2/' + kind + '/recommend' +
      '?refresh=0&start=' + start + '&count=' + count +
      '&selected_categories=' + encodeURIComponent(JSON.stringify(cats)) +
      '&uncollect=false&tags=' + encodeURIComponent(tags) +
      '&sort=' + sort;
    const res = await HttpClient.getText(url, DoubanClient.rexxarHeaders(), 8000);
    if (!res.ok) {
      return [];
    }
    try {
      const data = JSON.parse(res.text) as Record<string, object>;
      const rawItems = data['items'];
      if (!Array.isArray(rawItems)) {
        return [];
      }
      const items: RecommendItem[] = [];
      for (const entry of rawItems as object[]) {
        const s = entry as Record<string, object>;
        // items 里混着片单（playlist）、广告（ad）等卡片，只取真实条目
        const type = DoubanClient.str(s['type']);
        if (type !== 'movie' && type !== 'tv') {
          continue;
        }
        const title = DoubanClient.str(s['title']);
        // 海报在 pic.normal / pic.large；部分卡片退化用 cover_url
        let cover = '';
        const pic = s['pic'] as Record<string, object>;
        if (pic !== undefined && pic !== null) {
          cover = DoubanClient.str(pic['normal']);
          if (cover === '') {
            cover = DoubanClient.str(pic['large']);
          }
        }
        if (cover === '') {
          cover = DoubanClient.str(s['cover_url']);
        }
        if (title === '' || cover === '') {
          continue;
        }
        // 评分在 rating.value；无评分（null / 0）不显示
        let rating: string | undefined = undefined;
        const r = s['rating'] as Record<string, object>;
        if (r !== undefined && r !== null) {
          const v = r['value'];
          let num: number = 0;
          if (typeof v === 'number') {
            num = v;
          } else if (typeof v === 'string') {
            num = Number.parseFloat(v);
          }
          if (!Number.isNaN(num) && num > 0) {
            rating = num.toFixed(1);
          }
        }
        items.push({
          id: DoubanClient.str(s['id']),
          title: title,
          cover: cover,
          rating: rating,
          isTv: type === 'tv',
          year: DoubanClient.str(s['year']),
          regions: DoubanClient.subtitlePart(s['card_subtitle'], 1),
          genres: DoubanClient.subtitlePart(s['card_subtitle'], 2)
        });
      }
      return items;
    } catch (e) {
      return [];
    }
  }

  static async recommend(type: string, tag: string, pageStart: number, pageSize: number): Promise<RecommendItem[]> {
    const kind: string = type === 'movie' ? 'movie' : 'tv';
    // 「热门」「最新」在 rexxar 上是被下线的标签（返回 0 条），换成空标签走默认浏览
    const tags: string = tag === '热门' || tag === '最新' ? '' : tag;
    return await DoubanClient.rexxarRecommend(kind, tags, '', '', 'R', pageStart, pageSize);
  }

  /**
   * 按「分类 + 类型 + 地区 + 排序」浏览。
   *
   * 参数含义（rexxar 实测）：
   *   tags     电影 / 电视剧 / 综艺 / 纪录片 / 动漫 —— 决定走 movie 还是 tv 接口
   *   genre    剧情 / 喜剧 / 动作 / 爱情 / 科幻 / 动画 / 悬疑 …  空串表示不限
   *   country  中国大陆 / 美国 / 中国香港 / 日本 / 韩国 …        空串表示不限
   *   sort     T=综合排序 U=近期热度 R=首映时间 S=高分优先
   *   start    条目偏移量，每页固定返回 20 条
   */
  static async browse(tags: string, genre: string, country: string, sort: string,
    start: number): Promise<RecommendItem[]> {
    const kind: string = tags === '电影' ? 'movie' : 'tv';
    return await DoubanClient.rexxarRecommend(kind, tags, genre, country, sort, start, 20);
  }

  /** 热播模式原始偏移上限：rexxar 浏览总量约 500，留一点余量收手 */
  private static readonly HOT_RAW_MAX: number = 480;

  /**
   * 客户端筛选浏览：翻 rexxar 原始页，逐条按「类型 / 地区 / 年份」过滤后攒够 want 条。
   *
   * 为什么在客户端过滤：rexxar 的 selected_categories 已被服务端整体忽略
   * （类型/地区传了和不传结果一样），年份参数（year_range / years）也全部无效，
   * 只能拿条目自带的 year + card_subtitle 解析结果自己滤。
   *
   * 年份规则：year 非空时按它精确匹配；否则 minYear > 0 时按 year >= minYear
   * 过滤（「热播近1年」模式）。类型/地区非空时按解析出的 genres/regions
   * 逐词匹配（card_subtitle 里合拍片是多地区空格分隔，如「英国 美国」）。
   *
   * 分页记账：rawStart 是「下一批的原始偏移」，nextStart 返回给调用方续取，
   * -1 表示触到 HOT_RAW_MAX 已取尽。过滤后一页 20 条通常要消耗 2~6 个原始页，
   * 内部循环翻页直到攒够 want 条；任何一原始页拉空（失败或取尽）就带着已有的先返回。
   */
  static async filterBrowse(tags: string, genre: string, country: string, sort: string,
    minYear: number, year: string, rawStart: number, want: number): Promise<HotRecentPage> {
    const kind: string = tags === '电影' ? 'movie' : 'tv';
    const exact: number = Number.parseInt(year);
    const out: RecommendItem[] = [];
    let start: number = rawStart >= 0 ? rawStart : 0;
    while (out.length < want && start < DoubanClient.HOT_RAW_MAX) {
      const page: RecommendItem[] =
        await DoubanClient.rexxarRecommend(kind, tags, '', '', sort, start, 20);
      if (page.length === 0) {
        break;
      }
      for (const it of page) {
        if (out.length >= want) {
          break;
        }
        if (genre !== '' && !DoubanClient.containsTag(it.genres, genre)) {
          continue;
        }
        if (country !== '' && !DoubanClient.containsTag(it.regions, country)) {
          continue;
        }
        const y: number = Number.parseInt(it.year !== undefined ? it.year : '');
        if (!Number.isNaN(exact)) {
          if (y !== exact) {
            continue;
          }
        } else if (minYear > 0 && (Number.isNaN(y) || y < minYear)) {
          continue;
        }
        out.push(it);
      }
      start += 20;
    }
    return { items: out, nextStart: start >= DoubanClient.HOT_RAW_MAX ? -1 : start };
  }

  /** 判断列表里是否含指定词条（genres/regions 的逐词精确匹配） */
  private static containsTag(list: string[] | undefined, tag: string): boolean {
    if (list === undefined) {
      return false;
    }
    for (const t of list) {
      if (t === tag) {
        return true;
      }
    }
    return false;
  }

  /**
   * 从 card_subtitle（格式「年份 / 地区 / 类型 / 导演 / 主演」，段间 ' / '，
   * 段内多值空格分隔）里取第 index 段并拆成词条数组。
   * index：0=年份 1=地区 2=类型；格式不符（段数不够 / 空段）返回 undefined，
   * 有筛选时这些条目会被自然过滤掉，不该拿残缺数据冒充筛选结果。
   */
  private static subtitlePart(raw: object, index: number): string[] | undefined {
    const s: string = DoubanClient.str(raw);
    if (s === '') {
      return undefined;
    }
    const parts: string[] = s.split(' / ');
    if (parts.length <= index) {
      return undefined;
    }
    const seg: string = parts[index].trim();
    if (seg === '') {
      return undefined;
    }
    const words: string[] = seg.split(' ');
    const out: string[] = [];
    for (const w of words) {
      const t: string = w.trim();
      if (t !== '') {
        out.push(t);
      }
    }
    return out.length > 0 ? out : undefined;
  }

  /**
   * 豆瓣高分榜（原 Top 250 排行榜的替代）。
   *
   * Top250 榜单页（HTML）与 j/* JSON 接口都被豆瓣封死（403），rexxar 也没有
   * 对应的榜单接口。改走「豆瓣高分」标签 + 高分优先排序，首屏即肖申克级别，
   * 体验与 Top250 相当；每页 25 条，start 为 25 的倍数。
   */
  static async top250(start: number): Promise<RecommendItem[]> {
    return await DoubanClient.rexxarRecommend('movie', '豆瓣高分', '', '', 'S', start, 25);
  }

  /**
   * 搜索联想：输入即出的候选片名。
   *
   * 原 j/subject_suggest 接口已被豆瓣封死（403），与慢接口 searchTitles
   * 一样改走 rexxar 站内搜索。它单字也能回真实片名，两段式（快/慢并行）
   * 的分工保留：这里超时给得宽一点，反正失败还有本地兜底。
   */
  static async suggest(key: string): Promise<SuggestItem[]> {
    const q: string = key.trim();
    if (q === '') {
      return [];
    }
    return await DoubanClient.searchRexxar(q, 4000, 12);
  }

  /**
   * 搜索联想（慢接口，专治「单字不出结果」）。
   *
   * rexxar 站内搜索单字能回 8~12 条**真实片名**，500~1000ms。
   *
   * 两个坑都实测过：
   *   · 不带 type：单字结果几乎全是图书（「流」20 条全图书），过滤完一场空；
   *   · type=tv：接口直接 HTTP 500（连「狂飙」都 500），不能用。
   * 所以固定 type=movie —— 但返回里 movie/tv 条目都有（按 target_type 区分），
   * 剧集照样能联想出来。
   */
  static async searchTitles(key: string): Promise<SuggestItem[]> {
    const q: string = key.trim();
    if (q === '') {
      return [];
    }
    return await DoubanClient.searchRexxar(q, 3000, 12);
  }

  /** rexxar 站内搜索实现：suggest（快）与 searchTitles（慢）共用 */
  private static async searchRexxar(q: string, timeoutMs: number, count: number): Promise<SuggestItem[]> {
    const url: string = 'https://m.douban.com/rexxar/api/v2/search/subjects?q=' + encodeURIComponent(q) +
      '&type=movie&start=0&count=' + count;
    const res = await HttpClient.getText(url, DoubanClient.rexxarHeaders(), timeoutMs);
    if (!res.ok || res.text === '') {
      return [];
    }
    try {
      const data = JSON.parse(res.text) as Record<string, object>;
      const subjects = data['subjects'] as Record<string, object>;
      if (subjects === undefined || subjects === null) {
        return [];
      }
      const rawItems = subjects['items'];
      if (!Array.isArray(rawItems)) {
        return [];
      }
      const out: SuggestItem[] = [];
      for (const entry of rawItems as object[]) {
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
   * 站内搜索是按热度排的，不重排经常把正主压到第二三位。
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
   *   1. rexxar 站内搜索 -> 候选条目（id / type / year，无评分）
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
    const res = await HttpClient.getText(api, DoubanClient.rexxarHeaders(), 8000);
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

  /**
   * 在站内搜索结果里挑最像的那一条。
   * 原走 j/subject_suggest（已 403），改走 rexxar 站内搜索后字段结构变了，
   * 挑选逻辑（同名同年 > 同名 > 互相包含）不变。
   */
  private static async pickSubject(key: string, year: string): Promise<DoubanSubject | null> {
    const url: string = 'https://m.douban.com/rexxar/api/v2/search/subjects?q=' + encodeURIComponent(key) +
      '&type=movie&start=0&count=20';
    const res = await HttpClient.getText(url, DoubanClient.rexxarHeaders(), 6000);
    if (!res.ok || res.text === '') {
      return null;
    }
    try {
      const data = JSON.parse(res.text) as Record<string, object>;
      const subjects = data['subjects'] as Record<string, object>;
      if (subjects === undefined || subjects === null) {
        return null;
      }
      const rawItems = subjects['items'];
      if (!Array.isArray(rawItems)) {
        return null;
      }
      let exact: DoubanSubject | null = null;
      let sameYear: DoubanSubject | null = null;
      let loose: DoubanSubject | null = null;
      for (const entry of rawItems as object[]) {
        const o = entry as Record<string, object>;
        const target = o['target'] as Record<string, object>;
        if (target === undefined || target === null) {
          continue;
        }
        const id = DoubanClient.str(target['id']);
        const name = DoubanClient.str(target['title']);
        const ttype = DoubanClient.str(o['target_type']);
        if (id === '' || name === '' || (ttype !== 'movie' && ttype !== 'tv')) {
          continue;
        }
        const cand: DoubanSubject = { id: id, type: ttype };
        if (name === key) {
          if (exact === null) {
            exact = cand;
          }
          if (year !== '' && DoubanClient.str(target['year']) === year) {
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
