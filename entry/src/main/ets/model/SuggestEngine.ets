/**
 * 搜索联想引擎（首页与搜索结果页共用）。
 *
 * 为什么不是「页面里写一段 onChange + 一个请求」：
 *   1. 防抖 / 序号作废 / 本地兜底 / 两段式补全 这几件事都是踩出来的，
 *      两个页面各抄一遍必然走样；
 *   2. 它是一个**普通类**，不持有 @State —— 页面只把两个回调接上去，
 *      状态仍然留在页面的 @State 里，渲染链路和以前完全一致。
 *
 * 两段式的原因（实测结论，别删）：
 *   · 豆瓣 subject_suggest 很快（200~600ms），但**很多单个汉字直接返回 0 条**
 *     （「流」「三」「星」都是空），所以用户会感觉「打第一个字没反应，
 *     打第二个字才跳结果」；
 *   · rexxar 站内搜索（DoubanClient.searchTitles）单字能回 8~12 条真实片名，
 *     但要 500~1000ms。
 *   于是两个**并行**发出：快的先显示，慢的补齐，首字也有结果。
 */
import { DoubanClient, SuggestItem } from './DoubanClient';

/** 少于这个条数就认为「没填满」，值得再用慢接口补一次 */
const SUGGEST_ENOUGH: number = 4;
/** 面板最多显示 6 条：再多会盖住半屏内容 */
const SUGGEST_MAX: number = 6;
/** 从第二个字起才防抖：连续打字没必要每个字都打一次豆瓣 */
const SUGGEST_DEBOUNCE_MS: number = 220;

/** 结果出口：页面把这两个回调接到自己的 @State 上 */
export interface SuggestSink {
  /** items = 当前要显示的候选；loading = 还有一阶段在路上 */
  onUpdate: (items: SuggestItem[], loading: boolean) => void;
  /** 输入被清空，面板应当收起 */
  onClose: () => void;
}

export class SuggestEngine {
  /**
   * 只认最后一次输入。
   * 打「流」「流浪」「流浪地球」会各发一次请求，先发的可能后到 ——
   * 不作废就会出现「输入框里已经是流浪地球，面板里还挂着『流』的候选」。
   */
  private seq: number = 0;
  /** 防抖定时器（-1 = 没在等） */
  private timer: number = -1;
  /** 本地兜底池：首页的推荐片名、搜索页的历史词，纯内存过滤，不发请求 */
  private pool: string[] = [];
  /** 上一次给出去的候选：下一次按键先原样亮着，避免面板闪一下变空 */
  private last: SuggestItem[] = [];

  setPool(titles: string[]): void {
    this.pool = titles.slice(0, 300);
  }

  input(raw: string, sink: SuggestSink): void {
    this.dropTimer();
    const kw: string = raw.trim();
    if (kw === '') {
      this.seq++;
      this.last = [];
      sink.onClose();
      return;
    }
    const seq: number = ++this.seq;
    // 立刻亮加载态：打了字就必须有反应，不能等网络
    sink.onUpdate(this.last, true);
    if (kw.length <= 1) {
      // 首字不防抖：立刻发，配合慢接口把「一个字也出片名」做出来
      this.run(kw, seq, sink);
      return;
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.run(kw, seq, sink);
    }, SUGGEST_DEBOUNCE_MS);
  }

  /** 点中候选、提交搜索、切 Tab 时调用 */
  close(sink: SuggestSink): void {
    this.seq++;
    this.last = [];
    this.dropTimer();
    sink.onClose();
  }

  private dropTimer(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private async run(kw: string, seq: number, sink: SuggestSink): Promise<void> {
    // 慢接口与快接口**并行**：慢的自己会跑完，即使中途被丢弃也不会泄漏异常
    const slow: Promise<SuggestItem[]> = this.loadTitles(kw);
    let quick: SuggestItem[] = [];
    try {
      quick = await DoubanClient.suggest(kw);
    } catch (e) {
      quick = [];
    }
    if (seq !== this.seq) {
      return;
    }
    let items: SuggestItem[] = quick.length > 0 ? quick : this.localSuggest(kw);
    this.last = items;
    const needMore: boolean = items.length < SUGGEST_ENOUGH;
    sink.onUpdate(items, needMore);
    if (!needMore) {
      return;
    }
    let more: SuggestItem[] = [];
    try {
      more = await slow;
    } catch (e) {
      more = [];
    }
    if (seq !== this.seq) {
      return;
    }
    const merged: SuggestItem[] = this.merge(items, more);
    this.last = merged.length > 0 ? merged : items;
    sink.onUpdate(this.last, false);
  }

  private async loadTitles(kw: string): Promise<SuggestItem[]> {
    try {
      return await DoubanClient.searchTitles(kw);
    } catch (e) {
      return [];
    }
  }

  /** 本地兜底联想：已加载过的片名，纯内存过滤 */
  private localSuggest(kw: string): SuggestItem[] {
    const out: SuggestItem[] = [];
    for (const title of this.pool) {
      if (title.indexOf(kw) < 0) {
        continue;
      }
      this.pushUnique(out, { title: title, year: '', kind: '本机', id: '' });
      if (out.length >= SUGGEST_MAX) {
        break;
      }
    }
    return out;
  }

  /** 合并两批候选：按片名去重，前缀命中的排前面（打「流浪」先出《流浪地球》） */
  private merge(a: SuggestItem[], b: SuggestItem[]): SuggestItem[] {
    const out: SuggestItem[] = [];
    for (const it of a) {
      this.pushUnique(out, it);
    }
    for (const it of b) {
      this.pushUnique(out, it);
    }
    return out.slice(0, SUGGEST_MAX);
  }

  private pushUnique(list: SuggestItem[], it: SuggestItem): void {
    for (const o of list) {
      if (o.title === it.title) {
        return;
      }
    }
    list.push(it);
  }
}
