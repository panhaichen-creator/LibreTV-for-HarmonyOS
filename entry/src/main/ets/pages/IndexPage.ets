/**
 * 主页面：底部三 Tab（首页 / 直播 / 我的）+ 顶部搜索
 * 作为 Navigation 根页面承载全部子页面路由
 */

import { display } from '@kit.ArkUI';
import { RecommendItem, PlayRecord, LiveChannel, EpgProgramme, VideoDetail } from '../model/Types';
import { HistoryStore } from '../data/HistoryStore';
import { SourceManager } from '../data/SourceManager';
import { SettingsStore } from '../data/SettingsStore';
import { DownloadManager } from '../data/DownloadManager';
import { EventBus, Events } from '../common/EventBus';
import { DoubanClient, SuggestItem } from '../model/DoubanClient';
import { SuggestEngine, SuggestSink } from '../model/SuggestEngine';
import { BangumiClient } from '../model/BangumiClient';
import { HttpClient } from '../net/HttpClient';
import { M3uParser } from '../model/M3uParser';
import { CmsClient } from '../model/CmsClient';
import { BootstrapSources } from '../model/BootstrapSources';
import { DetailCache } from '../model/DetailCache';
import { NetImage } from '../components/NetImage';
import { XmltvParser } from '../model/XmltvParser';
import { Utils } from '../common/Utils';
import { AppVersion } from '../common/AppVersion';
import { NavIds } from '../common/NavIds';
import { EmptyView, LoadingView, SectionHeader, VodCard, SettingsRow } from '../components/CommonWidgets';
import { SearchResultPage } from './SearchResultPage';
import { SearchPageParam } from './SearchResultPage';
import { DetailPage } from './DetailPage';
import { DetailPageParam } from './DetailPage';
import { PlayerPage } from './PlayerPage';
import { PlayerPageParam } from './PlayerPage';
import { LivePlayerPage } from './LivePlayerPage';
import { LivePlayerPageParam } from './LivePlayerPage';
import { HistoryPage } from './HistoryPage';
import { HistoryPageParam } from './HistoryPage';
import { SourcesPage } from './SourcesPage';
import { DownloadsPage } from './DownloadsPage';
import { SettingsPage } from './SettingsPage';
import { AboutPage } from './AboutPage';
import { SystemInsets } from '../common/SystemInsets';
import { BlurFade } from '../common/BlurFade';
import { DeepLink, ShareLink, ShareTarget } from '../common/ShareLink';
import { SearchService } from '../model/SearchService';
import { ArrayDataSource } from '../common/ArrayDataSource';


@Observed
class LiveGroupState {
  sourceKey: string = '';
  sourceName: string = '';
  epgUrl: string = '';
  channels: LiveChannel[] = [];
  expanded: boolean = false;
  loading: boolean = false;
  loaded: boolean = false;
  error: string = '';
  epgProgrammes: EpgProgramme[] = [];
  epgChannelIds: Map<string, string> = new Map<string, string>();
  epgLoaded: boolean = false;
  epgTextMap: Map<string, string> = new Map<string, string>();
}

interface RecCat {
  key: string;
  label: string;
  type: string;
  tag: string;
  /** 豆瓣 new_search_subjects 的 tags 取值，组合筛选时用它限定分类 */
  tags: string;
}

const REC_CATS: RecCat[] = [
  { key: 'movie', label: '电影', type: 'movie', tag: '热门', tags: '电影' },
  { key: 'tv', label: '剧集', type: 'tv', tag: '热门', tags: '电视剧' },
  { key: 'variety', label: '综艺', type: 'tv', tag: '综艺', tags: '综艺' },
  { key: 'doc', label: '纪录片', type: 'tv', tag: '纪录片', tags: '纪录片' },
  { key: 'anime', label: '动漫', type: 'tv', tag: '日本动画', tags: '动漫' }
];

/** 排序方式：key 是豆瓣的 sort 参数，label 给用户看 */
interface RecSort {
  key: string;
  label: string;
}

const REC_SORTS: RecSort[] = [
  { key: 'R', label: '最新' },
  { key: 'T', label: '综合推荐' },
  { key: 'S', label: '评分最高' }
];

/**
 * 默认排序 = REC_SORTS 首项「最新」。
 * 不做持久化：每次重新打开 APP，首页推荐都从最新发行的内容开始。
 */
const REC_SORT_DEFAULT: string = 'R';

/** 豆瓣每页固定返回 20 条，瀑布流据此判断是否还有下一页 */
const REC_PAGE_SIZE: number = 20;
/** 瀑布流累加到这个起点就收手：再往后服务端基本只返回空 */
const REC_PAGE_MAX_START: number = 380;

/**
 * 悬浮「返回顶部」的出现阈值（屏）。
 * 最初按「50 行卡片」实现，但一行 ≈ 220vp（海报 172 + 标题 34 + 行距 14），
 * 50 行 ≈ 11000vp ≈ 15 屏 —— 手指要划十几屏按钮才冒出来，等于没有。
 * 改成按屏数计：滚过 2 屏（约 6-7 行）就出现。
 */
const BACK_TOP_SCREENS: number = 2;
/** 拉到顶时的小提示 */
const PULL_TOP_HINT: string = '别拉了，我到顶了！';
/** 判定为「下拉」所需的最小纵向位移（vp） */
const PULL_MIN_DY: number = 44;
/**
 * 判定为「下拉」时，纵向位移至少要是横向位移的这么多倍（≈58°）。
 *
 * 首页顶部那几条横向列表（继续观看 / 分类 / 直播）用的是内层横向 Scroll，
 * 手势会继续冒泡到外层竖向 Scroll 的 onTouch 上。横划到尽头时手指会自然收势下坠，
 * 只看 dy 的话很容易越过 44vp，被当成「往下拉」而弹出提示。
 * 加上这个比值，横划（dx 远大于 dy）就再也进不来，而真正往下的拉拽（dx 很小）不受影响。
 */
const PULL_VERTICAL_RATIO: number = 1.6;

/** 影片类型（豆瓣 genres 取值，逐个实测可用）；首项表示不限 */
const REC_GENRE_OPTS: string[] = [
  '全部', '剧情', '喜剧', '动作', '爱情', '科幻', '动画', '悬疑',
  '惊悚', '犯罪', '恐怖', '战争', '奇幻', '冒险', '历史'
];

/** 发行地区（豆瓣 countries 取值，逐个实测可用）；首项表示不限 */
const REC_COUNTRY_OPTS: string[] = [
  '全部', '中国大陆', '美国', '中国香港', '中国台湾', '日本', '韩国',
  '英国', '法国', '德国', '印度', '泰国', '意大利', '西班牙',
  '加拿大', '澳大利亚'
];

/** 「不限」的显示文案，同时作为筛选状态的哨兵值 */
const REC_FILTER_ALL: string = '全部';

/**
 * 直播频道展开超过多少行就认为「超过两屏」。
 * 一行约 46vp（台标 30 + 上下 padding 10 + 行间距 6），
 * 手机可用高度约 890vp，两屏 ≈ 38 行，取 36 作为阈值。
 */
const LIVE_COLLAPSE_ROWS: number = 36;

/**
 * 展开的直播源卡片底部额外留白（vp），给「收起频道列表」浮层让位。
 *
 * 为什么不交给 List 的 padding 一次做完：
 * ArkUI 的 List 把列表项**裁剪在内容盒（padding box）边缘**，padding 区永远露出
 * 页面底色，列表项再怎么高也压不过去（这就是「展开界面没有最大化」的成因）。
 * 所以 List 的 padding 只负责「让卡片底边停在胶囊之上」（LIVE_EXPAND_BOTTOM），
 * 卡片内部的这段留白则由卡片自己的下内边距承担 —— 滚到末尾时最后一行频道
 * 才不会被浮层压住点不到。
 * 取值：卡片底边距内容区底 76vp，收起按钮上沿距内容区底 144vp（见 LIVE_COLLAPSE_LIFT），
 * 差 68vp，再留 16 缓冲 → 84。
 */
const LIVE_EXPAND_TAIL: number = 84;

/**
 * 展开「长频道」源时，List 的底部留白（vp）。
 * 内容区底边 = 屏幕内容底（y≈2743），底部胶囊占据最下面 66vp（y≈2512 起），
 * 取 76 → 卡片下沿落在 y≈2477，稳稳停在胶囊上方，且仍在「收起」按钮之下。
 */
const LIVE_EXPAND_BOTTOM: number = 76;

/**
 * 直播源卡片的尺寸（vp）。照参考图：收起时每张卡只露出标题条，
 * 下一张压住上一张一截，叠成一摞纸；展开才长成整块。
 */
const LIVE_HEADER_H: number = 58;
/** 收起态卡片总高：比标题条高，最下面那张不会被压住，看得出是「一叠」 */
const LIVE_CARD_H: number = 96;
/** 收起时下一张压住上一张多少 —— 这个重叠就是立体叠卡的来源 */
const LIVE_STACK_OVERLAP: number = 46;
/** 相邻两张卡展开时的间距 */
const LIVE_CARD_GAP: number = 10;
/**
 * 频道列表最多铺多少行。
 * 有的源 1000+ 个频道，一次性把几百行（每行一个 NetImage）挂到树上，
 * 展开那一下要卡将近 1 秒 —— 所以按「先铺一屏，滚到再补」的方式分页渲染。
 */
const LIVE_MAX_ROWS: number = 300;
/** 展开时先铺出来的行数：一屏多，够把「卡片长出来」的动画撑住 */
const LIVE_FIRST_ROWS: number = 24;
/** 滑到底部再补多少行 */
const LIVE_MORE_ROWS: number = 48;
/**
 * 卡片配色套数：淡紫 / 青柠 / 石墨 / 杏橙 / 钢蓝 / 玫瑰 / 薄荷（按源顺序循环）。
 *
 * 色值本身不在这里 —— 放在 resources/base|dark/element/color.json 的
 * color_live_card_1..7 里，深浅主题各存一份。原因：
 * EntryAbility 里设了 setColorMode(COLOR_MODE_NOT_SET)，之后 config.colorMode
 * 返回 NOT_SET，靠运行时判断主题会误判；只有资源限定目录（dark）是可靠的。
 * 浅色主题：那摞淡彩色卡，叠在一起层次最清楚；
 * 深色主题：同样的七个色相压成低饱和暗彩，比页面底 #191922 亮一档但不刺眼。
 */
const LIVE_CARD_PALETTE: number = 7;

@Entry
@Component
struct IndexPage {
  private navStack: NavPathStack = new NavPathStack();
  /** 推荐翻页起点：豆瓣按 page_start 分页，固定传 0 就会永远返回同一批「换一换」内容 */
  private recPageStart: number = 0;

  /**
   * 联想引擎：防抖 / 序号作废 / 本地兜底 / 两段式补全都在里面，
   * 搜索结果页复用同一个类，两边的行为不会走样。
   */
  private suggestEngine: SuggestEngine = new SuggestEngine();
  /**
   * 程序化回填的输入值。
   * `$$` 双向绑定在代码赋值时会回抛一次**等值** onChange；把它记下来，
   * 等那次 onChange 到了就认出来「这不是用户在打字」，不再触发联想。
   */
  private quietValue: string = '';
  /** 历史封面回填是否已跑过，避免每次刷新重复请求 */
  private backfillStarted: boolean = false;
  private historyCb: () => void = () => {};
  private sourcesCb: () => void = () => {};
  private downloadsCb: () => void = () => {};
  private liveFavCb: () => void = () => {};

  @State activeTab: number = 0;

  // ---------- 底部导航的白色流光 ----------
  /**
   * 光带（主体）当前停在哪一颗。
   *
   * 初始值刻意给 1（中间那颗「直播」）—— 用户第一次点两侧的按钮时，
   * 光是从中间移过去的，而不是「凭空出现在要点的位置上」。
   * 但首帧并不点亮它（navGlowAlpha 为 0），否则一进 APP 就有一团白光
   * 停在没被选中的「直播」上，看起来像个 bug。
   */
  @State navGlowIndex: number = 1;
  /** 拖尾层的目标位置：比主体慢半拍，移动过程里才看得出「光流过去」 */
  @State navGlowLag: number = 1;
  /** 光带整体亮度：0 = 还没点亮过；第一次点击后升到 NAV_GLOW_ALPHA */
  @State navGlowAlpha: number = 0;
  /** 手指正按住的项（-1 = 没按）：按下时那一颗自己亮一圈，抬起立刻熄 */
  @State navPressIndex: number = -1;
  /** 胶囊内导航排的实测宽度（vp）：算三项中心点用，旋转/分屏都会变，必须实测 */
  @State navRowW: number = 0;

  // ---------- 首页搜索联想 ----------
  @State searchValue: string = '';
  /** 联想候选：最多 6 条，够一屏看，再多面板就要盖住半屏内容 */
  @State suggestItems: SuggestItem[] = [];
  /** 联想请求在飞：面板里先显示一行「正在联想」 */
  @State suggestLoading: boolean = false;
  /** 面板是否展开：只在「有输入」时展开，清空输入立即收起 */
  @State suggestOpen: boolean = false;
  @State homeHistory: PlayRecord[] = [];
  @State recommendItems: RecommendItem[] = [];
  /** LazyForEach 数据源：与 recommendItems 同步，避免一次性创建全部卡片 */
  private recDataSource: ArrayDataSource = new ArrayDataSource();
  @State recommendLoading: boolean = false;
  /**
   * 分类切换 / 换一换期间的轻量提示开关。
   * 只用来降 Grid 的不透明度 —— 千万不要在这个过程中把内容换成 LoadingView：
   * 30 条卡片的网格高度有几千 vp，换成 260vp 的加载占位后内容高度骤降，
   * 外层 Scroll 的偏移量会被夹回 0，表现就是「点一下分类，页面自己弹回顶部」。
   */
  @State recSwitching: boolean = false;
  /** 瀑布流：还有下一页可加载 */
  @State recHasMore: boolean = true;
  /** 瀑布流：正在追加下一页（底部转圈） */
  @State recLoadingMore: boolean = false;
  /**
   * 首页可用宽度（vp），由 homeContent 上的 onAreaChange 实测。
   * 不在启动时一次性取 display：分屏、横竖屏旋转、折叠屏展开都会改变实际可用宽度，
   * 只有实测值能跟着变。
   */
  @State homeWidth: number = 0;
  @State recCatKey: string = 'movie';
  /** 豆瓣排行（Top250）模式：推荐来源选 douban_rank 时生效，分类/筛选条不适用 */
  @State recRank: boolean = false;
  /** 影片类型筛选，空串表示不限 */
  @State recGenre: string = '';
  /** 发行地区筛选，空串表示不限 */
  @State recCountry: string = '';
  /** 排序方式：R=最新(按发行时间从近到远) T=综合推荐 S=评分最高 */
  @State recSort: string = REC_SORT_DEFAULT;
  /** 当前展开的筛选面板：'' 收起 / sort / genre / country */
  @State filterPanel: string = '';
  /**
   * 请求序号。快速连点筛选时只让最后一次生效 ——
   * 否则慢的那个请求后到，会把界面刷回上一组筛选结果。
   */
  private recSeq: number = 0;
  /** 瀑布流翻页闸门，用普通字段而非 @State */
  private recPaging: boolean = false;
  @State liveGroups: LiveGroupState[] = [];
  /** 直播列表的滚动控制器：收起长频道列表后要滚回该源的分组标题 */
  private liveScroller: Scroller = new Scroller();
  /** 首页主滚动容器：内容上方区块高度变化时用它补偿偏移 */
  private homeScroller: Scroller = new Scroller();
  /** 是否已经量到过「继续观看」区块的高度（首帧不补偿滚动，见 onAreaChange 注释） */
  private historyBlockMeasured: boolean = false;
  /** 「继续观看」区块当前高度（vp），用于算增量 */
  private historyBlockH: number = 0;
  /** 用户最后一次滚动到的位置：播放页会把屏幕转横再转回，
   *  首页在后台经历重排，滚动偏移会被布局夹掉 —— 回来时用这个值恢复 */
  private homeOffset: number = 0;
  /** 上滑超过 BACK_TOP_ROWS 行后浮现的「返回顶部」 */
  @State showBackTop: boolean = false;
  /** 拉到顶时的小提示，1.4 秒后自动消失 */
  @State pullTopHint: boolean = false;
  /** 提示消隐定时器句柄，-1 表示没有在跑 */
  private pullHintTimer: number = -1;
  /** 本次手势按下的纵坐标（windowY），用来区分「下拉」与「上滑」 */
  private touchStartY: number = 0;
  /**
   * 本次手势按下的横坐标（windowX）。
   * 光有纵向位移分不清「下拉」和「横划时手指下坠」，必须同时看横向位移才能判别方向。
   */
  private touchStartX: number = 0;
  /** 本次手势里提示是否已经弹过，避免一个手势反复弹 */
  private pullHintFired: boolean = false;
  /**
   * 频道数预取令牌。刷新/重进时自增，正在跑的那一轮看到令牌变了就自己退出，
   * 避免两次预取叠加在一起互相覆盖 group 状态。
   */
  private countToken: number = 0;
  @State liveLoading: boolean = false;
  @State vodCount: number = 0;
  @State liveCount: number = 0;
  @State favCount: number = 0;
  @State downloadCount: number = 0;

  aboutToAppear(): void {
    // 先用屏幕宽度给个初值，避免首帧按手机 3 列画完再跳成 8 列的闪烁；
    // 真正的值由 homeContent 上的 onAreaChange 实测覆盖。
    try {
      this.homeWidth = px2vp(display.getDefaultDisplaySync().width);
    } catch (e) {
      this.homeWidth = 0;
    }
    this.refreshHome();
    this.refreshCounts();
    this.initRecCat();
    // 源健康度定期自动探测：失败源按退避自动停用（= 自动关闭），坏源不再拖慢搜索
    SourceManager.shared().startAutoRefresh();
    // 自动发现源（设置开关默认关）：延迟 3 秒后台拉取聚合订阅并验活入库
    BootstrapSources.maybeRunOnLaunch();
    this.loadRecommend();
    this.refreshLiveGroups();
    this.historyCb = () => {
      this.refreshHome();
      this.refreshCounts();
      // 播放页退出会保存进度并触发本回调；此时屏幕刚从横屏转回竖屏，
      // 首页布局被重排过 —— 在这里恢复用户原来的滚动位置
      this.restoreHomeOffset();
    };
    this.sourcesCb = () => {
      this.refreshCounts();
      this.refreshLiveGroups();
    };
    this.downloadsCb = () => {
      this.refreshCounts();
    };
    this.liveFavCb = () => {
      // 直播收藏变化（直播页收藏/取消频道）：刷新「我的」页收藏计数
      this.refreshCounts();
    };
    // 分享链接的落点：必须用箭头函数（成员方法当回调会丢 this）
    DeepLink.attach((link: string) => {
      this.onSharedLink(link);
    });
    EventBus.on(Events.HISTORY_CHANGED, this.historyCb);
    EventBus.on(Events.SOURCES_CHANGED, this.sourcesCb);
    EventBus.on(Events.DOWNLOADS_CHANGED, this.downloadsCb);
    EventBus.on(Events.LIVE_FAV_CHANGED, this.liveFavCb);
  }

  aboutToDisappear(): void {
    if (this.pullHintTimer !== -1) {
      clearTimeout(this.pullHintTimer);
      this.pullHintTimer = -1;
    }
    EventBus.off(Events.HISTORY_CHANGED, this.historyCb);
    EventBus.off(Events.SOURCES_CHANGED, this.sourcesCb);
    EventBus.off(Events.DOWNLOADS_CHANGED, this.downloadsCb);
    EventBus.off(Events.LIVE_FAV_CHANGED, this.liveFavCb);
    DeepLink.detach();
  }

  /**
   * 别人分享过来的链接：直接起播，不绕详情页。
   *
   * 延迟 400ms 再 push：冷启动时本方法是在 aboutToAppear 里被同步调到的，
   * 那一刻 Navigation 的节点还没构建完，pushPath 会被吞掉（表现为"点了链接没反应，
   * 但要等一会儿"）。等首帧画完再压栈才稳。
   */
  private onSharedLink(link: string): void {
    const t: ShareTarget | null = ShareLink.parse(link);
    if (t === null) {
      return;
    }
    setTimeout(() => {
      this.openSharedTarget(t);
    }, 400);
  }

  private async openSharedTarget(t: ShareTarget): Promise<void> {
    let useSource: string = t.sourceKey;
    let useVod: string = t.vodId;
    // 对方装的是别的源（每个人的源列表都不一样）→ 按片名在本机各源里找一部同名的
    let matched: boolean = false;
    for (const s of SourceManager.shared().getVodSources()) {
      if (s.key === t.sourceKey) {
        matched = true;
        break;
      }
    }
    if (!matched && t.title !== '') {
      this.toast('本机没有分享的片源，正在自动匹配同名影片');
      try {
        const res = await SearchService.aggregate(t.title, SettingsStore.shared().get());
        let pick: number = -1;
        // 先找同名，找不到再退而求其次取第一条有片源的
        for (let i = 0; i < res.merged.length; i++) {
          if (res.merged[i].items.length > 0 && res.merged[i].name === t.title) {
            pick = i;
            break;
          }
        }
        if (pick < 0) {
          for (let i = 0; i < res.merged.length; i++) {
            if (res.merged[i].items.length > 0) {
              pick = i;
              break;
            }
          }
        }
        if (pick >= 0) {
          useSource = res.merged[pick].items[0].sourceKey;
          useVod = res.merged[pick].items[0].vodId;
        }
      } catch (e) {
        // 搜索失败就按原链接试：源可能只是被停用，播放页仍能拉到详情
      }
    }
    const p: PlayerPageParam = {
      sourceKey: useSource,
      vodId: useVod,
      episode: t.episode,
      episodeName: t.episodeName,
      title: t.title,
      positionMs: 0,
      offlineDir: '',
      pic: t.pic
    };
    this.navStack.pushPath({ name: 'Player', param: p });
  }

  onPageShow(): void {
    this.refreshHome();
    this.refreshCounts();
    this.restoreHomeOffset();
  }

  /**
   * 恢复首页滚动位置。
   * 播放页一进入就强制横屏，返回时再转回竖屏：首页在后台经历横→竖重排，
   * 瀑布流列数变化、内容高度变化，滚动偏移会被布局夹掉（表现就是「位置跳变」）。
   * 旋转后的布局要一两帧才稳定，所以两次校正。
   */
  private restoreHomeOffset(): void {
    const target: number = this.homeOffset;
    if (target <= 0) {
      return;
    }
    const apply = (): void => {
      try {
        this.homeScroller.scrollTo({ xOffset: 0, yOffset: target, animation: false });
        // scrollTo 不一定会触发 onDidScroll，这里手动对齐一次悬浮按钮状态
        this.syncBackTop(target);
      } catch (e) {
        // Scroller 未绑定时忽略
      }
    };
    setTimeout(apply, 80);
    setTimeout(apply, 350);
  }

  /** 「滚过 BACK_TOP_SCREENS 屏」换算成具体滚动距离（vp） */
  private backTopThreshold(): number {
    let screenH: number = 760;
    try {
      // 物理屏高换成 vp；横屏/分屏时它不会变，但首页本身也只会滚动这一个方向，
      // 这里只用来给「滚了多远」定个量级，不必精确到视口高度。
      screenH = px2vp(display.getDefaultDisplaySync().height);
    } catch (e) {
      // 取不到就用兜底值
    }
    if (screenH <= 0) {
      screenH = 760;
    }
    return screenH * BACK_TOP_SCREENS;
  }

  /** 滚动位置变化时决定悬浮按钮显隐，状态没变就不写，避免每帧触发重绘 */
  private syncBackTop(y: number): void {
    const show: boolean = y >= this.backTopThreshold();
    if (show !== this.showBackTop) {
      this.showBackTop = show;
    }
  }

  /** 是否已经贴在最顶上（留 2vp 容差，避免亚像素误差） */
  private homeAtTop(): boolean {
    try {
      return this.homeScroller.currentOffset().yOffset <= 2;
    } catch (e) {
      return false;
    }
  }

  /** 拉到顶：弹小提示，1.4 秒后自动收（连续拉会重新计时，不会闪一下就没） */
  private flashPullHint(): void {
    this.pullTopHint = true;
    if (this.pullHintTimer !== -1) {
      clearTimeout(this.pullHintTimer);
    }
    // 这个定时器只管提示文案，页面销毁时在 aboutToDisappear 里清掉
    this.pullHintTimer = setTimeout(() => {
      this.pullTopHint = false;
      this.pullHintTimer = -1;
    }, 1400);
  }

  /** 点悬浮按钮回顶：带一段缓动，不要瞬移 */
  private backToTop(): void {
    this.homeOffset = 0;
    this.showBackTop = false;
    try {
      this.homeScroller.scrollTo({
        xOffset: 0,
        yOffset: 0,
        animation: { duration: 320, curve: Curve.EaseOut }
      });
    } catch (e) {
      // Scroller 未绑定
    }
  }

  private refreshHome(): void {
    this.homeHistory = HistoryStore.shared().getHistory().slice(0, 12);
    this.backfillHistoryPics();
  }

  private refreshCounts(): void {
    this.vodCount = SourceManager.shared().getVodSources().length;
    this.liveCount = SourceManager.shared().getLiveSources().length;
    // 收藏数 = 点播收藏 + 直播收藏（结构化记录，旧版裸 URL 空名不计）
    let favTotal = HistoryStore.shared().getFavorites().length;
    for (const v of HistoryStore.shared().getLiveFavorites()) {
      if (v.name !== '') {
        favTotal++;
      }
    }
    this.favCount = favTotal;
    this.downloadCount = DownloadManager.shared().getTasks().length;
  }

  private initRecCat(): void {
    const src = SettingsStore.shared().get().recommendSource;
    this.recRank = src === 'douban_rank';
    if (src === 'douban_tv') {
      this.recCatKey = 'tv';
    } else if (src === 'bangumi') {
      this.recCatKey = 'anime';
    } else {
      this.recCatKey = 'movie';
    }
  }

  /** 首次加载 / 换一批 / 改筛选：整页替换 */
  private async loadRecommend(): Promise<void> {
    await this.fetchRecommend(false);
  }

  /**
   * 瀑布流：滑到底时追加下一页。
   * recPaging 是普通字段而不是 @State —— 状态写入是异步的，拿它当闸门挡不住
   * 边沿事件在同一帧里的连击，结果就是同一页被请求两次、列表里冒出重复卡片。
   */
  private loadMoreRecommend(): void {
    if (this.recPaging || this.recommendLoading || this.recSwitching) {
      return;
    }
    if (!this.recHasMore || this.recommendItems.length === 0) {
      return;
    }
    this.fetchRecommend(true);
  }

  /**
   * 拉推荐数据。
   *   append=false 整页替换（首次加载 / 换一批 / 改筛选）
   *   append=true  在现有列表后面追加下一页（瀑布流）
   */
  private async fetchRecommend(append: boolean): Promise<void> {
    if (append) {
      this.recPaging = true;
      this.recLoadingMore = true;
    } else {
      // 已有内容时走「原地替换」：保留旧列表、只降不透明度，
      // 新数据回来再整体换掉。这样内容高度不会塌陷，Scroll 偏移量得以保留，
      // 用户滚到哪儿就还停在哪儿。只有首次加载（列表为空）才显示 LoadingView。
      this.recLoadingMore = false;
      this.recHasMore = true;
      if (this.recommendItems.length > 0) {
        this.recSwitching = true;
      } else {
        this.recommendLoading = true;
      }
    }
    this.recSeq++;
    const seq: number = this.recSeq;
    // Top250 榜单页每页固定 25 条，其余接口每页 20 条
    const pageSize: number = this.recRank ? 25 : REC_PAGE_SIZE;
    let start: number = this.recPageStart;
    if (append) {
      start = this.recPageStart + pageSize;
    }
    let fallback: boolean = false;
    try {
      let items: RecommendItem[] = [];
      if (this.recRank) {
        // 豆瓣排行：Top250 HTML 榜单页，分类/筛选条不适用
        items = await DoubanClient.top250(start);
        if (items.length === 0 && start > 0 && !append) {
          start = 0;
          this.recPageStart = 0;
          items = await DoubanClient.top250(0);
        }
        if (items.length === 0) {
          // 榜单页被反爬拦截时退回「评分最高」浏览接口兜底
          items = await DoubanClient.browse('电影', '', '', 'S', 0);
          fallback = true;
        }
      } else {
        const cat: RecCat = this.currentCat();
        // 统一走 new_search_subjects：它同时支持分类(tags) + 类型(genres)
        // + 地区(countries) + 排序(sort)，一条链路就能覆盖「默认浏览」和「组合筛选」，
        // 不必为筛选再造一套分页逻辑。
        items =
          await DoubanClient.browse(cat.tags, this.recGenre, this.recCountry, this.recSort, start);
        if (items.length === 0 && start > 0 && !append) {
          // 翻页翻过头了（或筛选后总量不足一页），回到第一页再取一次
          start = 0;
          this.recPageStart = 0;
          items = await DoubanClient.browse(cat.tags, this.recGenre, this.recCountry, this.recSort, 0);
        }
        if (items.length === 0 && !append && this.recGenre === '' && this.recCountry === '') {
          // 浏览接口偶发返回空 data（疑似频控）。没加筛选时回退到老接口，
          // 至少首页不至于整块空白；加了筛选就老实显示空态 —— 拿不相关的片
          // 去冒充「筛选结果」比空白更糟。
          items = await DoubanClient.recommend(cat.type, cat.tag, 0, 30);
          fallback = true;
        }
        if (items.length === 0 && !append && cat.key === 'anime') {
          items = await BangumiClient.calendar();
          fallback = true;
        }
      }
      // 一次取两页：单页只有 5-7 行，首屏和每次触底都显得太少。
      // 第二页失败就只用第一页，不影响可用性。
      let fetchedPages: number = 1;
      if (!fallback && items.length >= pageSize) {
        try {
          let more: RecommendItem[] = [];
          if (this.recRank) {
            more = await DoubanClient.top250(start + pageSize);
          } else {
            const cat2: RecCat = this.currentCat();
            more = await DoubanClient.browse(cat2.tags, this.recGenre, this.recCountry, this.recSort, start + pageSize);
          }
          if (more.length > 0) {
            items = items.concat(more);
            fetchedPages = 2;
          }
        } catch (e2) {
          // 第二页失败忽略，保留第一页
        }
      }

      if (seq !== this.recSeq) {
        // 期间又点了别的筛选，这批结果已经过时，直接丢弃
        return;
      }
      if (append) {
        const before: number = this.recommendItems.length;
        // 新一页单独过一遍排序（综合推荐要洗牌），已经滑过的卡片位置不动 ——
        // 整体重排会让用户觉得界面自己跳了一下。
        const merged: RecommendItem[] = this.mergeItems(this.recommendItems, this.orderItems(items));
        this.recommendItems = merged;
        this.recDataSource.setData(merged);
        if (items.length === 0) {
          this.recHasMore = false;
        } else {
          const lastStart: number = start + (fetchedPages - 1) * pageSize;
          this.recPageStart = lastStart;
          // 服务端给了整页、去重后却一条都没多 —— 说明后面全是重复的，
          // 再往下翻只会空转，直接判到底。
          this.recHasMore = items.length >= pageSize && merged.length > before
            && lastStart + pageSize <= (this.recRank ? 250 : REC_PAGE_MAX_START);
        }
      } else {
        this.recommendItems = this.orderItems(items);
        this.recDataSource.setData(this.recommendItems);
        if (!fallback) {
          // 记成「已取到的最后一页起点」，append 时从它的下一页开始
          this.recPageStart = start + (fetchedPages - 1) * pageSize;
        }
        // 走了兜底接口就没有可续的分页了，别让瀑布流接着翻出另一套数据
        this.recHasMore = !fallback && items.length >= pageSize;
      }
    } catch (e) {
      // 网络异常时保留旧列表，不要让页面变成空白。
    } finally {
      // 异常也要复位，否则加载态会永远卡住。
      if (append) {
        // recPaging 必须无条件放开：这次请求被打断时也要把闸门打开，
        // 否则「加载更多」会永久失效。
        this.recPaging = false;
        if (seq === this.recSeq) {
          this.recLoadingMore = false;
        }
      } else if (seq === this.recSeq) {
        // 只有「最后一次请求」才有资格收尾，否则会把新一轮的转场态提前关掉。
        this.recommendLoading = false;
        this.recSwitching = false;
      }
    }
  }

  /** 去重合并：翻页时服务端偶尔重复给同一条，id 撞了 ForEach 会出问题 */
  private mergeItems(base: RecommendItem[], add: RecommendItem[]): RecommendItem[] {
    const seen: Set<string> = new Set<string>();
    for (const it of base) {
      seen.add(it.id);
    }
    const out: RecommendItem[] = base.slice();
    for (const it of add) {
      if (!seen.has(it.id)) {
        seen.add(it.id);
        out.push(it);
      }
    }
    return out;
  }

  /** 换一批：推进分页起点后重新加载（浏览接口每页 20 条，Top250 每页 25 条） */
  private nextRecommend(): void {
    const pageSize: number = this.recRank ? 25 : REC_PAGE_SIZE;
    const wrapAt: number = this.recRank ? 225 : 180;
    this.recPageStart = this.recPageStart >= wrapAt ? 0 : this.recPageStart + pageSize;
    this.loadRecommend();
  }

  /**
   * 排序整理。
   * 「评分最高」「最新」必须保持服务端给的降序 —— 再洗牌就把「按评分/按时间排序」
   * 这个承诺毁了；「综合推荐」则洗牌，保证每次「换一批」看到的顺序不一样。
   */
  private orderItems(src: RecommendItem[]): RecommendItem[] {
    const arr: RecommendItem[] = src.slice();
    if (this.recRank) {
      // Top250 是榜单排名，顺序就是承诺，不洗牌
      return arr;
    }
    if (this.recSort === 'S') {
      arr.sort((a: RecommendItem, b: RecommendItem): number => {
        return this.rateOf(b) - this.rateOf(a);
      });
      return arr;
    }
    if (this.recSort === 'R') {
      // 服务端已是按上映时间倒序返回，本地再洗牌就把「最新」这个承诺毁了
      return arr;
    }
    for (let i = arr.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const tmp: RecommendItem = arr[i];
      arr[i] = arr[j];
      arr[j] = tmp;
    }
    return arr;
  }

  /** 把 "9.4" 这样的字符串评分转成数字；缺失或非法按 0 处理 */
  private rateOf(item: RecommendItem): number {
    const s: string = item.rating !== undefined ? item.rating : '';
    if (s === '') {
      return 0;
    }
    const v: number = Number.parseFloat(s);
    return Number.isNaN(v) ? 0 : v;
  }

  private currentCat(): RecCat {
    for (const c of REC_CATS) {
      if (c.key === this.recCatKey) {
        return c;
      }
    }
    return REC_CATS[0];
  }

  /** 是否有任何非默认的筛选/排序生效（决定要不要显示「重置」） */
  private hasFilter(): boolean {
    return this.recGenre !== '' || this.recCountry !== '' || this.recSort !== REC_SORT_DEFAULT;
  }

  /** 当前排序的中文名 */
  private currentSortLabel(): string {
    for (const s of REC_SORTS) {
      if (s.key === this.recSort) {
        return s.label;
      }
    }
    return REC_SORTS[0].label;
  }

  /** 筛选条上那一枚 chip 显示什么 */
  private filterLabel(kind: string): string {
    if (kind === 'sort') {
      return this.currentSortLabel();
    }
    if (kind === 'genre') {
      return this.recGenre === '' ? '类型' : this.recGenre;
    }
    return this.recCountry === '' ? '地区' : this.recCountry;
  }

  /** chip 是否处于「已设置」状态（用主色高亮） */
  private filterActive(kind: string): boolean {
    if (kind === 'sort') {
      return this.recSort !== REC_SORT_DEFAULT;
    }
    if (kind === 'genre') {
      return this.recGenre !== '';
    }
    return this.recCountry !== '';
  }

  private filterPanelTitle(): string {
    if (this.filterPanel === 'sort') {
      return '排序方式';
    }
    if (this.filterPanel === 'genre') {
      return '影片类型';
    }
    return '发行地区';
  }

  /** 当前面板的可选项 */
  private filterOptions(): string[] {
    if (this.filterPanel === 'sort') {
      const labels: string[] = [];
      for (const s of REC_SORTS) {
        labels.push(s.label);
      }
      return labels;
    }
    if (this.filterPanel === 'genre') {
      return REC_GENRE_OPTS;
    }
    return REC_COUNTRY_OPTS;
  }

  private isOptionSelected(opt: string): boolean {
    if (this.filterPanel === 'sort') {
      return opt === this.currentSortLabel();
    }
    if (this.filterPanel === 'genre') {
      const curGenre: string = this.recGenre === '' ? REC_FILTER_ALL : this.recGenre;
      return opt === curGenre;
    }
    const curCountry: string = this.recCountry === '' ? REC_FILTER_ALL : this.recCountry;
    return opt === curCountry;
  }

  /** 选中某个选项：写回状态、收起面板、回到第一页重新拉取 */
  private pickOption(opt: string): void {
    let changed: boolean = false;
    if (this.filterPanel === 'sort') {
      let key: string = this.recSort;
      for (const s of REC_SORTS) {
        if (s.label === opt) {
          key = s.key;
          break;
        }
      }
      if (key !== this.recSort) {
        this.recSort = key;
        changed = true;
      }
    } else if (this.filterPanel === 'genre') {
      const gv: string = opt === REC_FILTER_ALL ? '' : opt;
      if (gv !== this.recGenre) {
        this.recGenre = gv;
        changed = true;
      }
    } else {
      const cv: string = opt === REC_FILTER_ALL ? '' : opt;
      if (cv !== this.recCountry) {
        this.recCountry = cv;
        changed = true;
      }
    }
    this.filterPanel = '';
    if (changed) {
      this.recPageStart = 0;
      this.loadRecommend();
    }
  }

  /** 一键清空所有筛选与排序 */
  private clearFilter(): void {
    this.filterPanel = '';
    if (!this.hasFilter()) {
      return;
    }
    this.recGenre = '';
    this.recCountry = '';
    this.recSort = REC_SORT_DEFAULT;
    this.recPageStart = 0;
    this.loadRecommend();
  }

  /**
   * 回填历史记录的封面。
   * 早期版本保存播放记录时没写 pic，导致首页「继续观看」全是空白灰块。
   * 这里对缺封面的记录按需补一次（最多 8 条、串行+间隔，避免打爆采集站）。
   */
  private async backfillHistoryPics(): Promise<void> {
    if (this.backfillStarted) {
      return;
    }
    this.backfillStarted = true;
    const missing: PlayRecord[] = [];
    for (const r of this.homeHistory) {
      if (r.pic === undefined || r.pic === '') {
        missing.push(r);
      }
    }
    let done: number = 0;
    for (const r of missing) {
      if (done >= 8) {
        break;
      }
      const cached: VideoDetail | null = DetailCache.get(r.sourceKey, r.vodId);
      if (cached !== null && cached.info.cover !== undefined && cached.info.cover !== '') {
        HistoryStore.shared().setPicIfEmpty(r.sourceKey, r.vodId, cached.info.cover);
        done++;
        continue;
      }
      const src = SourceManager.shared().getVodSource(r.sourceKey);
      if (src === null) {
        continue;
      }
      try {
        const detail: VideoDetail | null = await CmsClient.detail(src, r.vodId);
        if (detail !== null && detail.info.cover !== undefined && detail.info.cover !== '') {
          DetailCache.put(r.sourceKey, r.vodId, detail);
          HistoryStore.shared().setPicIfEmpty(r.sourceKey, r.vodId, detail.info.cover);
          done++;
        }
      } catch (e) {
        // 单条失败不影响其它记录
      }
    }
    // homeHistory 是 getHistory() 的快照副本，store 内部改了它并不知道，
    // 这里重新取一次把补好的封面同步到界面上。
    if (done > 0) {
      this.homeHistory = HistoryStore.shared().getHistory().slice(0, 12);
    }
  }

  private refreshLiveGroups(): void {
    const sources = SourceManager.shared().enabledLiveSources();
    const groups: LiveGroupState[] = [];
    for (const s of sources) {
      const existing = this.findGroup(s.key);
      if (existing !== null) {
        // 必须原地复用同一个实例。
        // ForEach 的 key 稳定（只有 sourceKey）时不会重新生成子项，子组件捕获的
        // group 引用就固定在第一次渲染的那个对象上；这里若换成 new 出来的新对象，
        // 外部拿到的状态变了，卡片内部却永远读不到 expanded，
        // 表现就是「点一下没反应、展不开频道」。
        existing.sourceName = s.name;
        existing.epgUrl = s.epg !== undefined ? s.epg : '';
        groups.push(existing);
        continue;
      }
      const g: LiveGroupState = new LiveGroupState();
      g.sourceKey = s.key;
      g.sourceName = s.name;
      g.epgUrl = s.epg !== undefined ? s.epg : '';
      groups.push(g);
    }
    this.liveGroups = groups;
  }

  /**
   * 依次拉取每个直播源，把频道数直接显示在分组标题上。
   *
   * 为什么串行：订阅里有 1000+ 频道的源，十几个并发下载会互相抢带宽，
   * 解析上万条 #EXTINF 还会把主线程顶住；串行时数字一个个冒出来，
   * 观感就是「正在统计」，也不会让首页推荐请求被挤掉。
   *
   * force=false：只补还没统计过的源（进入直播页时用，省流量）；
   * force=true ：全部重拉（点刷新时用），旧数字会一直留着直到新数字到位。
   */
  private async prefetchLiveCounts(force: boolean): Promise<void> {
    this.countToken++;
    const token: number = this.countToken;
    for (const g of this.liveGroups) {
      if (token !== this.countToken) {
        return;
      }
      if (g.loading) {
        continue;
      }
      if (g.loaded && !force) {
        continue;
      }
      await this.loadLiveGroup(g.sourceKey);
    }
  }

  private findGroup(key: string): LiveGroupState | null {
    for (const g of this.liveGroups) {
      if (g.sourceKey === key) {
        return g;
      }
    }
    return null;
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private onSearchSubmit(): void {
    const wd = this.searchValue.trim();
    if (wd === '') {
      this.toast('请输入搜索关键词');
      return;
    }
    this.closeSuggest();
    const p: SearchPageParam = { keyword: wd };
    this.navStack.pushPath({ name: 'Search', param: p });
  }

  // ---------- 搜索联想 ----------

  /**
   * 输入变化 -> 联想。
   *
   * 这里只负责「开/关面板」和把引擎的出口接上去，
   * 防抖、作废、两段式补全都交给 SuggestEngine（搜索结果页共用同一套）。
   */
  /** 程序化回填输入框：记下值，等那次等值 onChange 到来时忽略它 */
  private setSearchQuiet(v: string): void {
    this.quietValue = v;
    this.searchValue = v;
  }

  private onSearchInput(value: string): void {
    // 回填的回声：值没变，说明不是用户输入 —— 吞掉。
    // 不吞的话，首页点候选跳转后，回写输入框会把联想面板重新撑开。
    if (value === this.quietValue) {
      this.quietValue = '';
      return;
    }
    this.quietValue = '';
    this.suggestOpen = value.trim() !== '';
    this.suggestEngine.setPool(this.suggestPool());
    this.suggestEngine.input(value, this.suggestSink());
  }

  /** 引擎出口 -> 页面 @State（对象每次新建，闭包里的 this 指向本页面） */
  private suggestSink(): SuggestSink {
    return {
      onUpdate: (items: SuggestItem[], loading: boolean): void => {
        this.suggestItems = items;
        this.suggestLoading = loading;
      },
      onClose: (): void => {
        this.suggestItems = [];
        this.suggestLoading = false;
        this.suggestOpen = false;
      }
    };
  }

  /** 本地兜底池：首页已加载的推荐片名 + 播放历史 */
  private suggestPool(): string[] {
    const pool: string[] = [];
    for (const it of this.recommendItems) {
      pool.push(it.title);
    }
    for (const rec of this.homeHistory) {
      pool.push(rec.name);
    }
    return pool;
  }

  private closeSuggest(): void {
    this.suggestEngine.close(this.suggestSink());
  }

  /** 点中一条候选：回填输入框，直接走搜索（用户要的是片子，不是豆瓣条目页） */
  private pickSuggest(item: SuggestItem): void {
    this.setSearchQuiet(item.title);
    this.closeSuggest();
    const p: SearchPageParam = { keyword: item.title };
    this.navStack.pushPath({ name: 'Search', param: p });
  }

  private openRecommend(item: RecommendItem): void {
    const p: SearchPageParam = { keyword: item.title };
    this.navStack.pushPath({ name: 'Search', param: p });
  }

  private openDetail(sourceKey: string, vodId: string, name: string): void {
    const p: DetailPageParam = {
      sourceKey: sourceKey,
      vodId: vodId,
      title: name
    };
    this.navStack.pushPath({ name: 'Detail', param: p });
  }

  private continuePlay(rec: PlayRecord): void {
    const p: PlayerPageParam = {
      sourceKey: rec.sourceKey,
      vodId: rec.vodId,
      episode: rec.episode,
      episodeName: rec.episodeName !== undefined ? rec.episodeName : '',
      title: rec.name,
      positionMs: rec.positionMs,
      offlineDir: '',
      // 历史记录里存有上次的播放地址，直接复用，避免播放页再次请求详情被限流
      episodeUrl: rec.playUrl !== undefined ? rec.playUrl : '',
      pic: rec.pic !== undefined ? rec.pic : '',
      lineIndex: rec.lineIndex !== undefined ? rec.lineIndex : 0
    };
    this.navStack.pushPath({ name: 'Player', param: p });
  }

  private progressWidth(rec: PlayRecord): string {
    if (rec.durationMs <= 0) {
      return '0%';
    }
    const pct = Math.floor((rec.positionMs / rec.durationMs) * 100);
    if (pct <= 0) {
      return '0%';
    }
    if (pct > 100) {
      return '100%';
    }
    return pct + '%';
  }

  private toggleLiveGroup(key: string): void {
    for (let i = 0; i < this.liveGroups.length; i++) {
      if (this.liveGroups[i].sourceKey === key) {
        const expanded = !this.liveGroups[i].expanded;
        // 放在 animateTo 里：卡片高度从「一条标题」长成整页频道，
        // 下面的卡跟着平滑下移（收起时上移），而不是瞬间跳。
        this.getUIContext().animateTo({ duration: 320, curve: Curve.FastOutSlowIn }, () => {
          this.liveGroups[i].expanded = expanded;
          this.liveGroups = this.liveGroups.slice();
        });
        if (expanded && !this.liveGroups[i].loaded && !this.liveGroups[i].loading) {
          this.loadLiveGroup(key);
        }
        return;
      }
    }
  }

  /**
   * 当前展开着、且频道数超过约两屏的源。
   * 有它才需要底部那个「收起频道列表」入口；短列表本来就一屏看完，不必打扰。
   */
  private longExpandedGroup(): LiveGroupState | null {
    for (const g of this.liveGroups) {
      if (g.expanded && g.channels.length > LIVE_COLLAPSE_ROWS) {
        return g;
      }
    }
    return null;
  }

  /**
   * 展开卡片底部要额外留出的空白（vp）。
   * 只对「长频道」源（就是会弹出『收起频道列表』浮层的那一个）生效 ——
   * 这时 List 的 padding-bottom 被归零让卡片压到底，让位空间就由卡片自己承担，
   * 否则滚到末尾时最后几行频道会被浮层和导航坞压住点不到。
   */
  private liveCardTail(group: LiveGroupState): number {
    return (group.expanded && group.channels.length > LIVE_COLLAPSE_ROWS) ? LIVE_EXPAND_TAIL : 0;
  }

  /**
   * 收起所有展开着的源卡（浮层「收起频道」用）。
   * 高度变化放在 animateTo 里，下面的卡跟着平滑上移。
   */
  private collapseAllGroups(): void {
    let any: boolean = false;
    for (let i = 0; i < this.liveGroups.length; i++) {
      if (this.liveGroups[i].expanded) {
        any = true;
      }
    }
    if (!any) {
      return;
    }
    this.getUIContext().animateTo({ duration: 320, curve: Curve.FastOutSlowIn }, () => {
      for (let i = 0; i < this.liveGroups.length; i++) {
        this.liveGroups[i].expanded = false;
      }
      this.liveGroups = this.liveGroups.slice();
    });
  }

  private async loadLiveGroup(key: string): Promise<void> {
    let idx = -1;
    for (let i = 0; i < this.liveGroups.length; i++) {
      if (this.liveGroups[i].sourceKey === key) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      return;
    }
    this.liveGroups[idx].loading = true;
    this.liveGroups[idx].error = '';
    this.liveGroups = this.liveGroups.slice();
    const source = SourceManager.shared().getLiveSource(key);
    if (source === null) {
      this.liveGroups[idx].loading = false;
      this.liveGroups[idx].error = '源已被删除';
      this.liveGroups = this.liveGroups.slice();
      return;
    }
    const res = await HttpClient.getTextAny(source.url, { 'User-Agent': HttpClient.UA }, 10000);
    if (res.ok && res.text !== '') {
      this.liveGroups[idx].channels = M3uParser.parse(res.text, source.url);
      this.liveGroups[idx].loaded = true;
      this.liveGroups[idx].error = this.liveGroups[idx].channels.length === 0
        ? (M3uParser.looksLikeHtml(res.text)
          ? '该源返回的是网页，不是 M3U 播放列表，请在「视频源管理」替换订阅地址'
          : '未解析到频道，请检查订阅地址')
        : '';
      SourceManager.shared().recordSuccess(key);
      if (source.epg !== undefined && source.epg !== '') {
        const epgRes = await HttpClient.getBytes(source.epg, { 'User-Agent': HttpClient.UA }, 12000);
        if (epgRes.ok && epgRes.text !== '') {
          const parsed = XmltvParser.parse(epgRes.text);
          this.liveGroups[idx].epgProgrammes = parsed.programmes;
          this.liveGroups[idx].epgChannelIds = parsed.channels;
          this.liveGroups[idx].epgLoaded = true;
          this.buildEpgTextMap(idx);
        }
      }
    } else {
      this.liveGroups[idx].error = '播放列表拉取失败';
      SourceManager.shared().recordFailure(key);
    }
    this.liveGroups[idx].loading = false;
    this.liveGroups = this.liveGroups.slice();
  }

  private buildEpgTextMap(idx: number): void {
    const group = this.liveGroups[idx];
    const map = new Map<string, string>();
    const now = Date.now();
    for (const ch of group.channels) {
      const id = XmltvParser.matchChannelId(group.epgChannelIds, ch.tvgId !== undefined ? ch.tvgId : '', ch.name);
      if (id === '') {
        continue;
      }
      const nn = XmltvParser.nowNext(group.epgProgrammes, id, now);
      let text = '';
      if (nn.current !== undefined) {
        text = nn.current.title;
      }
      if (nn.next !== undefined) {
        if (text !== '') {
          text = text + ' / ';
        }
        text = text + '接下来：' + nn.next.title;
      }
      if (text !== '') {
        map.set(ch.id, text);
      }
    }
    this.liveGroups[idx].epgTextMap = map;
  }

  private epgTextFor(group: LiveGroupState, ch: LiveChannel): string {
    const text = group.epgTextMap.get(ch.id);
    if (text === undefined) {
      return '';
    }
    return text;
  }

  private openLive(group: LiveGroupState, ch: LiveChannel): void {
    const p: LivePlayerPageParam = {
      channelUrl: ch.url,
      channelName: ch.name,
      sourceKey: group.sourceKey,
      sourceName: group.sourceName,
      logo: ch.logo !== undefined ? ch.logo : '',
      tvgId: ch.tvgId !== undefined ? ch.tvgId : ''
    };
    this.navStack.pushPath({ name: 'LivePlayer', param: p });
  }

  private pushHistory(): void {
    const p: HistoryPageParam = { mode: 'history' };
    this.navStack.pushPath({ name: 'History', param: p });
  }

  private pushFavorites(): void {
    const p: HistoryPageParam = { mode: 'favorites' };
    this.navStack.pushPath({ name: 'History', param: p });
  }

  private pushSources(): void {
    this.navStack.pushPath({ name: 'Sources' });
  }

  private pushDownloads(): void {
    this.navStack.pushPath({ name: 'Downloads' });
  }

  private pushSettings(): void {
    this.navStack.pushPath({ name: 'Settings' });
  }

  private pushAbout(): void {
    this.navStack.pushPath({ name: 'About' });
  }

  /**
   * 页面背景。
   *
   * 曾经是「顶部淡蓝 → 中段底色 → 底部淡青」的三段竖向渐变 + 两团彩色光斑。
   * 在平板上必然翻车：深色主题两端差 21 级色阶，8bit 输出就是 21 条横向色带；
   * 中段 color_bg 又比顶部更暗，剖面变成「亮→暗→亮」，看着像两块底色拼接。
   * 渐变本身是矢量的、没有分辨率概念，加色标也不会让色带变细 —— 只能压平。
   * 所以这里改成纯色，层次交给内容卡片与玻璃条。
   */
  private pageBgGradient(): LinearGradientOptions {
    const colors: Array<[ResourceColor, number]> = [
      [$r('app.color.color_page_bg'), 0],
      [$r('app.color.color_page_bg'), 1]
    ];
    const opt: LinearGradientOptions = {
      direction: GradientDirection.Bottom,
      colors: colors
    };
    return opt;
  }

  build() {
    Navigation(this.navStack) {
      Stack({ alignContent: Alignment.TopStart }) {
        // 背景铺满全屏（含状态栏与底部导航条）。
        // 纯色而非渐变：整屏渐变在 8bit 输出上必有横向色带，平板尤其明显。
        // 两团「环境光斑」也已删除 —— 它们从彩色淡到 #00FFFFFF 时 RGB 会被
        // 一起插值到白，在深色底上留下一圈发白的粉环，也就是用户看到的
        // 「红色圆圈」。要淡出必须同 RGB 只把 alpha 置 0（见 BlurFade 的注释）。
        Column()
          .width('100%')
          .height('100%')
          .linearGradient(this.pageBgGradient())
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        Column({ space: 0 }) {
        // Tabs 保留原生 tabBar。
        // 血的教训 —— 以下任一作法都会让 Tabs 内容区整块塌陷（页面只剩搜索栏 + 纯黑底）：
        //   · .ignoreLayoutSafeArea(...)
        //   · .expandSafeArea([], [])
        //   · .barHeight(0)
        //   · barHeight 用任何依赖 @State 的表达式（会触发 Tabs 重算失败）
        // 因此 barHeight 必须是纯常量；底部留白在窗口层用 setWindowLayoutFullScreen 根治。
        Tabs({ barPosition: BarPosition.End, index: this.activeTab }) {
          TabContent() {
            this.homeContent()
          }
          .tabBar(this.blankTabBar())

          TabContent() {
            this.liveContent()
          }
          .tabBar(this.blankTabBar())

          TabContent() {
            this.mineContent()
          }
          .tabBar(this.blankTabBar())
        }
        .barHeight(IndexPage.NAV_BAND_H)
        // 带子（原生 tabBar 区域）本身是空的（胶囊是页面浮层，见 bottomNavBar()）。
        // 目标：让这条带子**完全透明**，背后直接透出根 Stack 那层全屏页面渐变
        // —— 于是胶囊背后就是 APP 界面底色，没有任何「长方形」。
        //
        // 关键坑：barOverlap(true) 会**强制**给 tabBar 套一层
        // BlurStyle.COMPONENT_THICK 的厚材质（见 SDK 中 barOverlap 的注释），
        // 这层材质盖在 barBackgroundColor 之上，barBackgroundBlurStyle(NONE)
        // 也压不住它 —— 用户反复看到的「长方形」就是这层通栏磨砂。
        // 而内容本来就被 TabContent 视口裁在带子上沿（不会真的透进带子里），
        // 所以索性关掉 overlap，让带子回归纯透明 → 直接露根渐变：
        .barBackgroundColor(Color.Transparent)
        .barBackgroundBlurStyle(BlurStyle.NONE)
        .barOverlap(false)
        // Tabs 自己铺进手势条那一条：带子底边要落在屏幕物理底边（2848），
        // 胶囊的「底部留白 30vp」才有确定的参照物。
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        .animationDuration(0)
        .onChange((index: number) => {
          this.activeTab = index;
          if (index === 1) {
            // 进直播页就把各源的频道数补上，省得用户以为「列表里没有频道」
            this.prefetchLiveCounts(false);
          }
        })
        .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        // 这里不能再铺不透明底色：会把背后的渐变与光斑整块盖掉。
        // 也**不要**再 expandSafeArea 到底部：一旦扩进安全区，Tabs 的底边就
        // 变成屏幕物理底边，导航带子整体下移 28vp，胶囊又会被挤到屏幕外。
        // 底部安全区那一条由 Stack 最底层那面积渐变负责铺满，与这里无关。

        // 顶部安全区过渡罩（状态栏那一条）。
        //
        // 为什么必须靠 expandSafeArea 往上长：窗口没开全屏布局
        // （EntryAbility 里有说明：开全屏会让 Navigation 与 NavDestination
        // 的坐标系错位），普通子节点会被裁在安全区之下，只有 expandSafeArea
        // 能把这一层画进状态栏区域。
        // 效果：状态栏那一条不再是硬邦邦的纯色，而是「磨砂 + 向上加深」的过渡，
        // 和页面顶部自然接上（参考图里安全区的处理方式）。
        // 总高 = band + fade = 88vp，正好等于 topInset()：过渡区在「继续观看」上沿
        // 归零，一个像素都不压住首屏内容。
        BlurFade({ edge: 'top', band: SystemInsets.top() + 36, fade: 14, radius: 26 })

        // 顶部玻璃浮层：压在 Tabs 内容之上（不在 Column 流里），
        // 所以三个 Tab 的滚动内容都会从它「背后」滚过，被 backgroundBlurStyle 磨开。
        // 这就是「导航栏能隐约看到滚动内容」的顶部版本。
        // 代价：内容起点被浮层盖住，所以三个 Tab 的内容都要留出 topInset() 的顶部留白。
        Column() {
          Row({ space: 8 }) {
            Search({
              placeholder: '搜索电影 / 电视剧 / 主播',
              value: $$this.searchValue
            })
              .layoutWeight(1)
              .height(this.wide() ? 44 : 36)
              // 沉浸光感：半透明底 + 背景模糊做兜底，支持沉浸材质的设备上再由系统接管
              // （THIN 是薄材质，按压时会有轻微形变和光随指动的反馈）
              .backgroundColor($r('app.color.color_glass'))
              .borderRadius(this.wide() ? 22 : 18)
              .backgroundEffect({ radius: 18, saturation: 1.6 })
              // 细描边：深色主题下玻璃只比背景亮一点点，没边仍像「没有容器」；
              // 浅色主题下白玻璃压在近白渐变上同理。
              .border({ width: 1, color: $r('app.color.color_nav_border') })
              .shadow({ radius: 18, color: $r('app.color.color_glass_shadow'), offsetY: 6 })
              .searchButton('搜索', { fontSize: 14, fontColor: $r('app.color.color_primary') })
              .onSubmit((value: string) => {
                this.onSearchSubmit();
              })
              // 输入即联想：一个字就出候选（见 onSearchInput 里的分级防抖）
              .onChange((value: string) => {
                this.onSearchInput(value);
              })
          }
          .width('100%')
          // Row 必须显式给高度：不给的话，外层 Column 被 expandSafeArea 撑到
          // 整个安全区那么高，Row 作为唯一子节点跟着被撑满，搜索胶囊在 Row 里
          // 垂直居中 —— 结果胶囊离状态栏空出 20vp，看着像"没贴上去"。
          // 高度必须**等于内容总高**：`padding.top + 胶囊 + 6`。
          // 踩过的两个坑都在这两个值上，别再动：
          //   ① padding.top 必须是 SystemInsets.top() —— 这一层是**唯一**给状态栏
          //      让位的地方，改小（试过 8vp）搜索胶囊就直接顶进状态栏；
          //   ② height 写死 40vp 时，padding(38) + 胶囊(36) + 6 已经超过盒高，
          //      ArkUI 会把 padding 悄悄截断，盒子只剩 21px；联想面板按盒子底边
          //      往下排、不参与截断，于是整块上移压在胶囊上。
          // 现在盒子正好等于内容总高，底边落在「胶囊底边 + 6vp」，面板自然贴下方。
          .height(SystemInsets.top() + (this.wide() ? 44 : 36) + 6)
          .padding({
            left: this.wide() ? 16 : 12,
            right: this.wide() ? 16 : 12,
            // 全屏后浮层从 y=0 起排，搜索栏自己让开状态栏
            top: SystemInsets.top(),
            bottom: this.wide() ? 6 : 6
          })
          .alignItems(VerticalAlign.Top)

          // 联想面板：和搜索胶囊同宽、同左右内收，紧贴它下沿。
          // 它挂在顶部浮层这个 Column 里，而浮层本身压在 Tabs 内容之上，
          // 所以面板天然盖住首屏内容，不需要额外做定位或层级。
          if (this.suggestOpen && (this.suggestItems.length > 0 || this.suggestLoading)) {
            this.suggestPanel()
          }
        }
        .width('100%')
        // 这一层刻意「不铺底」。
        // 它的实测盒子是 [0,133][1276,364]，比搜索胶囊本身（196~322）高出一大截，
        // 一旦给它半透明底色（早先是 color_glass_bar + 模糊），多出来的那段就会
        // 盖住下面第一个区块标题 —— 表现为「继续观看 / 查看全部」只剩下半截，
        // 而且因为是一层浅玻璃，字是被"洗白"而不是被遮住，看着像渲染错了。
        // 玻璃感交给搜索胶囊自己（它已经有底色 + 模糊 + 描边），
        // 这也正是要的效果：卡片从胶囊两侧和下方透出来。
        // 往上延伸进状态栏区域：让状态栏也是玻璃，而不是一块不透明的系统底色。
        // 内容本身进不了状态栏区域（窗口没开全屏），所以状态栏里透出的是页面渐变；
        // 「看到滚动内容」这件事由搜索栏这一段玻璃负责 —— 内容从它下面滚过去。
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

        // 底部安全区过渡罩（手势条那一条）：与顶部同一套做法，
        // 内容从它背后滚过时被虚化。放在胶囊之前，胶囊才浮在它上面。
        Stack({ alignContent: Alignment.Bottom }) {
          // 页面底色在压平渐变时已统一成纯色 color_page_bg（浅 #DCE3F1 / 深 #191922），
          // 所以底部罩子必须用**同一个 RGB**，只让 alpha 从 0 走到近不透明；
          // 用别的颜色（哪怕只差一点暖度）都会在胶囊周围留出一条看得见的色差带——
          // 浅色主题下最明显，因为罩子的 alpha 底色与页面底是两块可比的浅色。
          BlurFade({
            edge: 'bottom',
            band: SystemInsets.bottom() + 68,
            fade: 30,
            radius: 28,
            soft: $r('app.color.color_veil_b_soft'),
            deep: $r('app.color.color_veil_b_deep'),
            clear: $r('app.color.color_veil_b_clear')
          })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)

        // 底部导航胶囊（浮层）：压在滚动内容之上，靠容器 justifyContent(End) 贴底。
        // 必须写在 Stack 的**花括号里面**。
        // 之前写在 Stack 的右括号之后，成了 builder 里的一条游离语句，
        // 节点被挂到 Navigation 内容上、位置完全不受控 ——
        // 表现就是胶囊大半截跑到屏幕底边之外（v23），或者干脆不出现（v22/v25）。
        this.bottomNavBar()
      }
      .width('100%')
      .height('100%')

    }
    .width('100%')
    .height('100%')
    // 根 Stack 必须自己铺进底部安全区。
    // 不铺的话布局底边停在安全区上沿（实测 y=2750），底下的 28vp 里
    // 没有任何子节点能落脚 —— 导航坞要么够不到屏幕底边（露出一条纯色），
    // 要么靠 expandSafeArea 硬顶、结果整块被平移出屏幕（胶囊被裁掉那一版）。
    // 关键一步：把 Navigation 自己的盒子铺进状态栏与手势条。
    // 实测窗口的 UI 根节点被框架下移到 y=133，普通子节点全部跟着下移；
    // 只有 expandSafeArea 能把根节点往上顶到 y=0，内容才真的会从状态栏背后滚过。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // 让 Navigation 连安全区一起忽略。
    // 不加这句时框架会把主内容下移 133px、却把 NavDestination 放在 y=0 ——
    // 两套坐标系打架，这正是此前「状态栏那一条永远进不去内容」的真正原因。
    // 忽略之后所有页面统一从 y=0 起排，安全区让位交给页面用 SystemInsets 处理。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    // 实测：页面根与 Navigation 都是 [0,133][1276,2848]（已全屏），
    // 但内部 NavBarContent 只到 2456，差的 392px 正是「底部悬空」。
    // 那是 Navigation 为自带标题栏/工具栏预留的空间，必须全部关掉。
    .hideTitleBar(true)
    .hideToolBar(true)
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.pageMap)
    // 画中画的 navigationId 必须和这个 id 一致：系统首次 setAutoStartEnabled(true) 时
    // 会缓存这个 Navigation 的栈顶信息，从画中画恢复时靠它回到播放页而不是首页。
    .id(NavIds.MAIN)
  }



  // ---------- 路由表 ----------

  @Builder
  pageMap(name: string, param: Object) {
    if (name === 'Search') {
      SearchResultPage({
        navPathStack: this.navStack,
        keyword: (param as SearchPageParam).keyword
      })
    } else if (name === 'Detail') {
      DetailPage({
        navPathStack: this.navStack,
        sourceKey: (param as DetailPageParam).sourceKey,
        vodId: (param as DetailPageParam).vodId,
        title: (param as DetailPageParam).title
      })
    } else if (name === 'Player') {
      PlayerPage({
        navPathStack: this.navStack,
        sourceKey: (param as PlayerPageParam).sourceKey,
        vodId: (param as PlayerPageParam).vodId,
        episode: (param as PlayerPageParam).episode,
        episodeName: (param as PlayerPageParam).episodeName,
        title: (param as PlayerPageParam).title,
        positionMs: (param as PlayerPageParam).positionMs,
        offlineDir: (param as PlayerPageParam).offlineDir,
        episodeUrl: (param as PlayerPageParam).episodeUrl !== undefined ? (param as PlayerPageParam).episodeUrl : '',
        pic: (param as PlayerPageParam).pic !== undefined ? (param as PlayerPageParam).pic : '',
        lineIndex: (param as PlayerPageParam).lineIndex !== undefined ? (param as PlayerPageParam).lineIndex : 0
      })
    } else if (name === 'LivePlayer') {
      LivePlayerPage({
        navPathStack: this.navStack,
        channelUrl: (param as LivePlayerPageParam).channelUrl,
        channelName: (param as LivePlayerPageParam).channelName,
        sourceKey: (param as LivePlayerPageParam).sourceKey,
        sourceName: (param as LivePlayerPageParam).sourceName,
        logo: (param as LivePlayerPageParam).logo,
        tvgId: (param as LivePlayerPageParam).tvgId
      })
    } else if (name === 'History') {
      HistoryPage({
        navPathStack: this.navStack,
        mode: (param as HistoryPageParam).mode
      })
    } else if (name === 'Sources') {
      SourcesPage({ navPathStack: this.navStack })
    } else if (name === 'Downloads') {
      DownloadsPage({ navPathStack: this.navStack })
    } else if (name === 'Settings') {
      SettingsPage({ navPathStack: this.navStack })
    } else if (name === 'About') {
      AboutPage({ navPathStack: this.navStack })
    }
  }

  // ---------- Tab 栏 ----------

  /**
   * 原生 tabBar 的空壳：只负责给内容区算一条底部带子（barHeight），
   * 视觉全部交给 bottomNavBar() 那颗浮层胶囊。
   * barHeight **不能撤**，取 0 会让 Tabs 内容区整块塌陷。
   */
  @Builder
  blankTabBar() {
    Column()
      .width('100%')
      .height('100%')
  }

  /**
   * 搜索联想面板。
   *
   * 只用玻璃色 + 细描边，不加不透明底：背后是滚动中的海报墙，
   * 磨开一点才像「从搜索栏里掉出来的一层」，而不是贴了张白纸。
   * 高度由行数撑，最多 6 行（200vp 出头），不会把首屏盖死。
   */
  @Builder
  suggestPanel() {
    Column() {
      Column() {
        if (this.suggestItems.length === 0) {
          Row({ space: 8 }) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color($r('app.color.color_text_secondary'))
            Text('正在联想片名…')
              .fontSize(13)
              .fontColor($r('app.color.color_text_secondary'))
          }
          .width('100%')
          .height(44)
          .padding({ left: 14, right: 14 })
          .alignItems(VerticalAlign.Center)
        } else {
          ForEach(this.suggestItems, (item: SuggestItem) => {
            Row({ space: 8 }) {
              Text(item.title)
                .fontSize(14)
                .fontColor($r('app.color.color_text'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (item.year !== '') {
                Text(item.year)
                  .fontSize(11)
                  .fontColor($r('app.color.color_text_secondary'))
                  .maxLines(1)
              }
              Text(item.kind)
                .fontSize(10)
                .fontColor($r('app.color.color_text_secondary'))
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(6)
                .backgroundColor($r('app.color.color_caption_glass'))
            }
            .width('100%')
            .height(42)
            .padding({ left: 14, right: 14 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.pickSuggest(item);
            })
          }, (item: SuggestItem) => item.title + '|' + item.year + '|' + item.kind)
        }
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor($r('app.color.color_panel_glass'))
      .backgroundEffect({ radius: 18, saturation: 1.6 })
      .borderRadius(16)
      .border({ width: 1, color: $r('app.color.color_nav_border') })
      .shadow({ radius: 18, color: $r('app.color.color_glass_shadow'), offsetY: 6 })
    }
    .width('100%')
    // 与搜索胶囊同左右内收，视觉上才能对齐成一条竖线。
    // top 留 0：上一行 Row 的 bottom padding 已经把面板推到胶囊下方 6vp，
    // 这里再加一份就会变成 12vp，面板看着离搜索框"飘"起来了。
    .padding({ left: this.wide() ? 16 : 12, right: this.wide() ? 16 : 12, top: 0 })
  }

  /**
   * 底部导航胶囊（浮层）。
   *
   * 位置：容器铺满整页、靠 justifyContent(FlexAlign.End) 把胶囊压到容器底边，
   * 再由 padding.bottom 抬起一点点。根 Stack 的盒子实测是 [0,133][1276,2750]，
   * 底边 2750 就是手势条安全区上沿 —— 参考图里胶囊底边也在屏高 96.5% 处，
   * 两者对得上，所以底部留白只需 2vp 的呼吸位。
   *
   * 为什么不用 .align(Alignment.Bottom)：
   * 实测那样挂会被推到屏幕底边之外（顶边 y≈2745，整颗看不见）。
   * 为什么不用 tabBar：每个 TabContent 的 tabBar 是「一个 tab 项」，
   * Tabs 会把三项横排，屏幕上会出现三颗各占 1/3 宽的胶囊。
   */
  @Builder
  bottomNavBar() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 只留一颗胶囊：带子已经靠 Tabs 的 barBackgroundEffect 做成全透明，
      // 背后直接透出滚动的 TabContent，所以这里**不再需要**实心覆盖层
      // （之前那块 color_bg_bottom 实心底就是滚动时看到的「长方形」）。
      //
      // 位置：带子已收到 NAV_BAND_H(2vp)，内容区一直铺到导航坞底边，
      // 胶囊靠 padding.bottom = NAV_PILL_GAP 抬离底边（见常量注释）。
      // 胶囊 = 一层「磨砂」+ 一层「图标文字」，两层叠进同一个圆角框。
      //
      // 为什么磨砂要单独做一层子节点，而不是直接挂在圆角 Row 上：
      // backgroundEffect 画出来的是一块**直角矩形**包围盒，不跟随 borderRadius 裁剪，
      // 直接标在圆角 Row 上，四角之外就会多出一块方形磨砂（那圈「长方形」的来源之一）。
      // 拆成子层后，由外层 Stack 的 clip(true) 按胶囊圆角统一裁掉，效果和
      // 顶部搜索栏（同一个 backgroundEffect 参数）完全一致。
      // 外层 Column 只负责定位与收边（左右内收 + 底部留白），
      // 里面那颗 Stack 才是真正的胶囊 —— 圆角、描边、落影都挂在它身上，
      // 否则 backgroundEffect 的直角包围盒会比胶囊宽出一圈。
      Column() {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor($r('app.color.color_nav_dock'))
            // 与顶部搜索栏同档：radius 18 / saturation 1.6
            .backgroundEffect({ radius: 18, saturation: 1.6 })

          // ---------- 白色流光（整条移动，不是每颗各亮各的）----------
          // 两层都要**在图标之下**：光只负责照亮「这一格」，片子名得始终读得清。
          //
          // 为什么是「一层 + translate」而不是「三颗各挂一团」：
          // 各挂一团的写法只能原地扩散/淡出，看起来是三次独立的闪光；
          // 只有同一团光在舱内平移，才是用户说的「从上一次点的按钮移到这一次」。
          // 位移 = 项宽 ×（index - 1），项宽由下面的 onAreaChange 实测得到。
          //
          // 拖尾层：更宽、更淡、慢 180ms 到 —— 移动过程里它是主体的「尾巴」，
          // 停稳之后两层重合，看上去就只是被照亮的一格。
          //
          // 渐变必须是**实心光斑**（中心亮 -> 向外淡出）。
          // 早先写成 `0 -> 8% -> 0` 的环形，在浅色底上就是一圈椭圆描边，
          // 和下面那层 shadow 叠在一起正好是用户看到的「椭圆形边沿」。
          Column()
            .width(150)
            .height(48)
            .borderRadius(24)
            .radialGradient({
              center: ['50%', '50%'],
              radius: 75,
              colors: [
                [$r('app.color.color_nav_glow_soft'), 0],
                [$r('app.color.color_nav_glow_clear'), 1]
              ]
            })
            .opacity(this.navGlowAlpha)
            .translate({ x: (this.navGlowLag - 1) * this.navCellW() })

          // 主体层：96×52 的一团白光，中心也不给高不透明度
          // （给到 0.5 以上，深色主题下白字会糊在白底上读不出来）。
          //
          // **不要加 .shadow / 描边**：浅色主题下白光照不亮浅灰胶囊，
          // 能看见的只有那圈阴影 —— 就是「多出来的椭圆形边沿」。
          // 光晕颜色走资源：深色 = 白光，浅色 = 全透明（浅色下干脆不画）。
          Column()
            .width(96)
            .height(52)
            .borderRadius(26)
            .radialGradient({
              center: ['50%', '50%'],
              radius: 48,
              colors: [
                [$r('app.color.color_nav_glow_core'), 0],
                [$r('app.color.color_nav_glow_mid'), 0.45],
                [$r('app.color.color_nav_glow_clear'), 1]
              ]
            })
            .opacity(this.navGlowAlpha)
            .translate({ x: (this.navGlowIndex - 1) * this.navCellW() })

          Row() {
            this.navItem($r('app.media.ic_home'), '首页', 0)
            this.navItem($r('app.media.ic_nav_live'), '直播', 1)
            this.navItem($r('app.media.ic_nav_mine'), '我的', 2)
          }
          .width('100%')
          .height('100%')
          // 量宽度：三项是 layoutWeight(1) 三等分，项宽 =（宽度 - 左右各 12）/ 3。
          // 不能写死：手机/平板/横屏三态差得远，写死那条流光会跑到格子外。
          .onAreaChange((oldArea: Area, newArea: Area) => {
            const w: number = newArea.width as number;
            if (Math.abs(w - this.navRowW) > 0.5) {
              this.navRowW = w;
            }
          })
          // 内收 12：图里三枚图标中心只占 495px（舱宽 794px），比三等分窄一圈，
          // 所以整排要从胶囊边缘再退一点，不然最左/最右的图标会顶到圆角上。
          .padding({ left: 12, right: 12 })
        }
        .width('100%')
        .height(IndexPage.NAV_PILL_H)
        // 四角全圆：图里两端都是半圆，radius 取高度一半
        .borderRadius(IndexPage.NAV_PILL_H / 2)
        // clip 必须开：磨砂层是直角矩形，靠它收成胶囊形；
        // 顺带把导航项的「光追」光斑也限制在胶囊内部。
        .clip(true)
        // 描边只留 0.5vp 的极细边，勾勒出玻璃轮廓而不至于像「包了一圈黑框」。
        .border({ width: 0.5, color: $r('app.color.color_nav_border') })
        // 与搜索栏同一档落影：胶囊才像浮在内容之上，而不是贴了一张纸。
        .shadow({ radius: 18, color: $r('app.color.color_glass_shadow'), offsetY: 6 })
      }
      .width('100%')
      .padding({
        left: this.navSidePad(),
        right: this.navSidePad(),
        // 胶囊底边要落在手势条之上（全屏后容器已经铺到屏幕物理底边）
        bottom: IndexPage.NAV_PILL_GAP + SystemInsets.bottom()
      })
    }
    .width('100%')
    .height('100%')
    // 容器只是定位壳，别让它挡住滚动：Transparent 下自身不吃手势，
    // 子节点（三个导航项）的 onClick 仍然正常。
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 胶囊里的单个导航项。
   *
   * 高亮判断必须写在函数体里直接读 this.activeTab，不能靠入参传布尔值：
   * @Builder 的参数是「按值传递」，状态变化不会触发 builder 内部刷新。
   * 之前传 active: boolean，值被钉在首帧（activeTab=0），
   * 于是无论切到直播还是我的，只有「首页」保持标红。
   */
  @Builder
  navItem(icon: Resource, label: string, tabIndex: number) {
    Stack({ alignContent: Alignment.Center }) {
      // 按下反馈：手指压在哪一颗，哪一颗自己亮一圈。
      // 声明式驱动（直接读 navPressIndex），不靠 setTimeout —— 按下即亮、
      // 抬起即灭，中间不会出现「先灭一下再亮」的拖尾。
      // 这层是「按下」的光，和下面那条会移动的光带互不干扰：
      // 光带表示「我现在在哪」，这一圈表示「我正按着这里」。
      Column()
        .width(62)
        .height(62)
        .borderRadius(31)
        .radialGradient({
          center: ['50%', '50%'],
          radius: 31,
          colors: [['#7AFFFFFF', 0], ['#26FFFFFF', 0.6], ['#00FFFFFF', 1]]
        })
        .opacity(this.navPressIndex === tabIndex ? 1 : 0)
        .scale({
          x: this.navPressIndex === tabIndex ? 1 : 0.68,
          y: this.navPressIndex === tabIndex ? 1 : 0.68
        })
        .animation({ duration: 180, curve: Curve.EaseOut })

      Column({ space: 4 }) {
        Image(icon)
          .width(this.tabIconSize())
          .height(this.tabIconSize())
          // 三个图标画在同一张 56 单位画布上，尺寸一致才不会一大一小
          .objectFit(ImageFit.Contain)
          // 图标不做染色，只改透明度。参考图里未选中项仍接近白（不是深灰），
          // 0.45 真机上显得发闷，提到 0.6，区分度靠「实心 / 描边」的图形差异。
          .opacity(this.activeTab === tabIndex ? 1 : 0.6)
          // 按下时轻微回缩：给「点亮」一个按下去的前奏，松手弹回
          .scale({
            x: this.navPressIndex === tabIndex ? 0.9 : 1,
            y: this.navPressIndex === tabIndex ? 0.9 : 1
          })
          .animation({ duration: 140, curve: Curve.EaseOut })
        Text(label)
          .fontSize(IndexPage.NAV_LABEL_SIZE)
          .fontWeight(this.activeTab === tabIndex ? FontWeight.Medium : FontWeight.Normal)
          // 单色而不是品牌红：图里选中项是白色，整条导航看起来才干净
          .fontColor(this.activeTab === tabIndex
            ? $r('app.color.color_text') : $r('app.color.color_text_secondary'))
      }
    }
    .layoutWeight(1)
    .height('100%')
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.navPressIndex = tabIndex;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.navPressIndex = -1;
      }
    })
    .onClick(() => {
      this.moveNavGlow(tabIndex);
      this.selectTab(tabIndex);
    })
  }

  /** 每一项的宽度（vp）：胶囊内宽减掉左右各 12 的内收，再三等分 */
  private navCellW(): number {
    const w: number = this.navRowW - 24;
    return w > 0 ? w / 3 : 0;
  }

  /**
   * 白色光带移到某一颗。
   *
   * 两层各用**不同时长**（主体 380ms / 拖尾 560ms）分别 animateTo：
   * 时长一样的话两层完全重合，视觉上只是一个光斑在平移；
   * 拖尾慢下来之后，移动过程里能看到「光先到、尾巴随后收拢」，才有流光的味道。
   *
   * 第一次调用（navGlowAlpha 还是 0）额外把亮度从 0 升上来：
   * 光带在中间那颗「浮现」，然后滑向被点的那一颗 ——
   * 这正是「点击两侧按钮时，光影默认从中间按钮移过去」。
   */
  private moveNavGlow(index: number): void {
    if (this.navGlowAlpha <= 0) {
      this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
        this.navGlowAlpha = 1;
      });
    }
    if (this.navGlowIndex === index && this.navGlowLag === index) {
      return;
    }
    this.getUIContext().animateTo({ duration: 380, curve: Curve.FastOutSlowIn }, () => {
      this.navGlowIndex = index;
    });
    this.getUIContext().animateTo({ duration: 560, curve: Curve.FastOutSlowIn }, () => {
      this.navGlowLag = index;
    });
  }

  /**
   * 切换 tab。
   *
   * 胶囊已经不吃 Tabs 的 onChange 了（它不在 tabBar 里），
   * 所以直播页的频道数预取要在这里补一次；onChange 若再触发一次也无妨，
   * 那个方法是幂等的（已加载的源会直接跳过）。
   */
  private selectTab(index: number): void {
    // 联想面板是全局浮层，不收起的话切到直播/我的还会挂在上面
    this.closeSuggest();
    if (this.activeTab === index) {
      return;
    }
    this.activeTab = index;
    if (index === 1) {
      this.prefetchLiveCounts(false);
    }
  }

  // ---------- 首页 ----------

  /**
   * 推荐网格的卡片目标宽度（vp）。
   * 手机 3 列时约 120vp；平板沿用同一密度，否则列数一多封面又被拉大，
   * 「一屏看到更多片」就没有意义了。
   */
  private static readonly REC_CARD_W: number = 120;
  /** 网格左右内边距合计（16 + 16） */
  private static readonly REC_SIDE_PAD: number = 32;
  /** 网格列间距 */
  private static readonly REC_COL_GAP: number = 10;

  /** 宽屏判定：≥600vp 视为平板 / 折叠展开 / 2in1 */
  private wide(): boolean {
    return this.homeWidth >= 600;
  }

  /**
   * 顶部玻璃浮层占掉的高度（vp）。
   * 浮层是压在内容之上的，所以三个 Tab 的内容都要先空出这么多，
   * 否则首屏会被搜索栏盖住。搜索栏本身要能点，所以浮层不吃触摸的地方不能挡。
   */
  private topInset(): number {
    const searchH: number = this.wide() ? 44 : 36;
    const padTop: number = this.wide() ? 4 : 10;
    const padBottom: number = this.wide() ? 6 : 4;
    // 状态栏那一条也要算：内容从 y=0 起排，框架不再替页面让位
    return SystemInsets.top() + searchH + padTop + padBottom;
  }

  /**
   * 底部导航图标尺寸。平板上一律 25vp 会显得又小又空，放大到 28vp
   * 仍然塞得进 70vp 的胶囊高度（NAV_PILL_H）。
   * 注意 barHeight 必须保持纯常量 —— 它一旦依赖状态，Tabs 内容区会整块塌陷。
   */
  private tabIconSize(): number {
    // 56 单位的画布渲染成 22vp：房子在画布里占 48 单位 → 墨迹约 18.9vp。
    // 参考图图标墨迹 46px / 屏高 1920，折到本机 813.7vp 约 19.5vp，与之吻合。
    return this.wide() ? 25 : 22;
  }

  /**
   * 「收起频道列表」浮层距**内容区底边**的距离（vp）。
   *
   * 底部磨砂带是按屏幕物理底边算的：SystemInsets.bottom()(28) + 磨砂 68 + 羽化 30
   * = 126vp；而 Tabs 内容区的底边停在手势条上沿（屏幕底 - 28vp），
   * 所以过渡带顶端距内容区底边只剩 126 - 28 = 98vp。
   * 浮层高约 38vp，取 106 → 上下沿分别落在 106 / 144vp，整块都在过渡带之上，
   * 既不会被罩子洗白，也不会压到胶囊。
   */
  private static readonly LIVE_COLLAPSE_LIFT: number = 106;

  /**
   * 导航胶囊高度（vp）。
   * 参考图实测 155 / 1920 = 屏高 8.07%，本机可用高 813.7vp → 65.7。
   * 一开始取 66，但胶囊比带子（NAV_BAND_H=64）还高，会上下各探出一点；
   * 现收紧到 56，正好能**居中**放进 64vp 的带子里（见 NAV_PILL_GAP）。
   */
  private static readonly NAV_PILL_H: number = 56;

  /** 胶囊上方留 6vp 呼吸位（浮层靠 justifyContent 贴底，这个值只用于文档对齐） */
  private static readonly NAV_PILL_TOP: number = 6;

  /**
   * 胶囊底边距容器底（= 带子底边）的呼吸位（vp）。
   * 用来把胶囊**居中**放进带子：带子高 NAV_BAND_H(64vp)，中心距底 32vp，
   * 故 bottom = 32 - NAV_PILL_H/2 = 32 - 28 = 4。
   */
  private static readonly NAV_PILL_GAP: number = 4;

  /** 导航项文字字号（vp）：参考图 26px / 屏高 1920 → 约 12vp */
  private static readonly NAV_LABEL_SIZE: number = 12;

  /**
   * tabBar 带子的高度（vp）。带子本身是空的（胶囊是浮层），
   * 唯一作用是给 Tabs 内容区「扣掉」这么多高度。
   *
   * 关键：barOverlap(false) 下内容区高度 = 屏高 - 安全区 - barHeight。
   * 之前取 64 时内容只画到 y≈2526（导航坞上方就断了），导致
   * 直播页展开的频道卡片 / 首页列表都在导航坞上方留出一大片空白 ——
   * 用户反馈的「频道展开界面没有最大化」就是这个。
   * 现在压到 2vp：内容一直铺到导航坞底边（y≈2743），
   * 展开的频道卡自然延伸到「收起频道列表」按钮下方。
   * 不能取 0（会让 Tabs 内容区整块塌陷），2 足够且安全。
   */
  private static readonly NAV_BAND_H: number = 2;

  /**
   * 三个 Tab 的滚动内容底部要额外留出的高度（vp）。
   * 胶囊是浮在内容之上的（内容从它背后穿过），不留这一截的话
   * 列表滚到底时最后一行永远被胶囊压住、看不全。
   * = 胶囊 56 + 底距 ~30 + 余量
   */
  private static readonly NAV_CONTENT_PAD: number = 110;

  /** 胶囊左右留白：手机 14vp（参考图 33/860 = 3.84%），平板 22vp */
  private navSidePad(): number {
    return this.wide() ? 22 : 14;
  }

  /** 推荐网格列数：按可用宽度推算，手机 3 列、平板最多 8 列 */
  private recColumns(): number {
    const w: number = this.homeWidth > 0 ? this.homeWidth : 411;
    const span: number = IndexPage.REC_CARD_W + IndexPage.REC_COL_GAP;
    let n: number = Math.round((w - IndexPage.REC_SIDE_PAD + IndexPage.REC_COL_GAP) / span);
    if (n < 3) {
      n = 3;
    }
    if (n > 8) {
      n = 8;
    }
    return n;
  }

  /** Grid 的 columnsTemplate，形如 "1fr 1fr 1fr …" */
  private recColumnsTemplate(): string {
    const n: number = this.recColumns();
    let tpl: string = '1fr';
    for (let i = 1; i < n; i++) {
      tpl += ' 1fr';
    }
    return tpl;
  }

  // 分类标签在平板上按比例放大，手机上保持原样。
  private chipFont(): number {
    return this.wide() ? 16 : 13;
  }

  private chipPadH(): number {
    return this.wide() ? 18 : 14;
  }

  private chipPadV(): number {
    return this.wide() ? 9 : 6;
  }

  private chipRadius(): number {
    return this.wide() ? 18 : 14;
  }

  private chipGap(): number {
    // 标签按钮之间收紧一档：10/8 时整排看着松散，和下面筛选条的视觉联系也弱
    return this.wide() ? 7 : 6;
  }

  /** 横向标签行的固定高度：文字 13fp + 上下 padding 12vp ≈ 30vp，留余量 */
  private chipRowH(): number {
    return this.wide() ? 44 : 36;
  }

  /**
   * 筛选条是「二级」控件，字号和留白都比分类标签收一档。
   * 两排用同样尺寸时，「综合推荐」这种四字标签会把视觉重量压过「电影/剧集」，
   * 一眼看过去像是分类按钮变小了。
   */
  private filterFont(): number {
    // 平板 16→14；手机 13→12（再小就难认了）
    return this.wide() ? this.chipFont() - 2 : this.chipFont() - 1;
  }

  private filterPadH(): number {
    return this.chipPadH() - 4;
  }

  private filterPadV(): number {
    // 平板 9→7；手机保持 6，别把可点高度压到 22vp 以下
    return this.wide() ? this.chipPadV() - 2 : this.chipPadV();
  }

  @Builder
  homeContent() {
    // 外层 Stack 只为了叠两个浮层（顶部提示 / 返回顶部按钮）。
    // 不用 layoutWeight 之外的技巧包 Scroll：Tabs 内容区一旦塌陷整页就只剩搜索栏。
    Stack({ alignContent: Alignment.BottomEnd }) {
      Scroll(this.homeScroller) {
      // space 从 12 收到 8：推荐标题、分类标签排、快速筛选条原本各隔 12vp，
      // 三段读起来像三个互不相干的区块；收紧后它们更像一组「找片工具」。
      Column({ space: 8 }) {
        // 继续观看（外层 Column 恒定存在，只为量这块高度：
        // 播放后会凭空多出这一块，把下面的推荐整体顶下去 —— 用高度增量补偿滚动偏移）
        Column() {
        if (this.homeHistory.length > 0) {
          SectionHeader({
            headerText: '继续观看',
            headerAction: '查看全部',
            onActionClick: () => {
              this.pushHistory();
            }
          })
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.homeHistory, (rec: PlayRecord) => {
                VodCard({
                  cardTitle: rec.name,
                  cardPic: rec.pic !== undefined ? rec.pic : '',
                  cardRemarks: rec.episodeName !== undefined ? rec.episodeName : '',
                  cardSource: '',
                  cardProgress: this.progressWidth(rec),
                  cardCompact: true,
                  // 这一排卡片数量少（最多几条），采样开销可以接受；
                  // 不开的话它们永远拿不到主色，片名条只能退回死板的深色
                  cardGlow: true,
                  onCardClick: () => {
                    this.continuePlay(rec);
                  }
                })
                // 封面只要推荐卡的一半大：原来 134vp 宽的海报连标题条要占 220vp，
                // 一条「继续观看」就把首屏压掉了近三分之一。
                .width(this.wide() ? 68 : 60)
              // key 必须拼上 pic：封面是后来回填的，key 不变 ArkUI 就不会重建这一项，
                // 表现就是数据已写好、界面仍是一块灰底。
              }, (rec: PlayRecord) => rec.sourceKey + '_' + rec.vodId + '_'
                + (rec.pic !== undefined ? rec.pic : ''))
            }
            .padding({ left: 16, right: 16 })
            // 横向 Scroll 里的内容比视口窄时会被居中，看起来像整排"漂"在屏幕中间。
            // minWidth 100% 让 Row 至少撑满视口（从左边开始排），
            // 内容更宽时又允许它自然增长，滚动不受影响。
            .constraintSize({ minWidth: '100%' })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
        }
        }
        .width('100%')
        .onAreaChange((oldArea: Area, newArea: Area) => {
          const h: number = newArea.height as number;
          const delta: number = h - this.historyBlockH;
          this.historyBlockH = h;
          // 首次量到高度（0 -> 实际值）只是「这一块第一次布局」，不是运行中的增减。
          // 早期这里照样做补偿，结果是一进首页就被 scrollTo 往下推一截：
          // 「继续观看 / 查看全部」那一行正好被视口上沿切掉一半 ——
          // 表现为启动后标题缺了上半截，而手动滑一下又恢复正常。必须跳过首帧。
          if (!this.historyBlockMeasured) {
            this.historyBlockMeasured = h > 0;
            return;
          }
          // 高度变化（继续观看出现/消失）时把滚动偏移加回同样的量，
          // 视口内容就不会被顶动 —— 否则表现为「播放后返回首页位置变了」。
          if (Math.abs(delta) > 1 && Math.abs(delta) < 400) {
            try {
              const off: number = this.homeScroller.currentOffset().yOffset;
              // 停在顶部时不需要补偿：off≈0 说明用户还没往下看，
              // 任何"补偿"都只会把首屏往下推（表现为一进首页标题就被切掉半截）。
              if (off <= 1) {
                return;
              }
              const target: number = off + delta;
              this.homeScroller.scrollTo({ xOffset: 0, yOffset: target > 0 ? target : 0, animation: false });
            } catch (e) {
              // Scroller 尚未绑定（首帧）时忽略
            }
          }
        })

        // 推荐
        SectionHeader({
          headerText: '推荐',
          // 原来是「换一换」，但它实际是翻到下一页（每页 20 条），
          // 叫「换一批」才对得上，用户不会以为只是把当前这批重新排个序。
          headerAction: '换一批',
          onActionClick: () => {
            this.nextRecommend();
          }
        })

        // 内容分类标签（豆瓣排行是榜单，没有分类/筛选概念，两排 chip 一起隐藏）
        if (!this.recRank) {
        Scroll() {
          Row({ space: this.chipGap() }) {
            ForEach(REC_CATS, (cat: RecCat) => {
              this.recChip(cat)
            }, (cat: RecCat) => cat.key)
          }
          .padding({ left: 16, right: 16 })
          .constraintSize({ minWidth: '100%' })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        // 横向 Scroll 不给高度时高度靠内容撑，嵌在纵向 Scroll 里容易算出 0
        // （上一版在平板上「推荐」标题和这排标签会整行不显示）。
        // 显式给高度，任何屏宽下都稳定占位。
        .height(this.chipRowH())
        // 负 margin：行高是给布局兜底的（内容只有 40vp，行高 44vp），
        // 多出来的部分会把标题和标签、标签和筛选条之间的空隙撑大。
        // 真正控制观感间距的是这里，不是外层 Column 的 space。
        .margin({ top: -6 })
        }

        // 筛选 / 排序：在分类之下再做一层「排序 · 类型 · 地区」细分
        // 左侧固定「快速筛选：」说明标签（不随横向滚动移出视野），
        // 颜色走 color_text_secondary，base/dark 两套资源自动适配深浅主题。
        if (!this.recRank) {
        Row({ space: this.chipGap() }) {
          Text('快速筛选：')
            .fontSize(this.filterFont())
            .fontColor($r('app.color.color_text_secondary'))
            .maxLines(1)
          Scroll() {
            Row({ space: this.chipGap() }) {
              this.filterChip('sort')
              this.filterChip('genre')
              this.filterChip('country')
              if (this.hasFilter()) {
                this.resetFilterChip()
              }
            }
            .padding({ right: 16 })
            .constraintSize({ minWidth: '100%' })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .layoutWeight(1)
        }
        .padding({ left: 16 })
        .width('100%')
        .height(this.chipRowH())
        .alignItems(VerticalAlign.Center)
        .margin({ top: -6 })
        }

        if (this.filterPanel !== '') {
          this.filterPanelView()
        }

        if (this.recommendItems.length === 0) {
          if (this.recommendLoading) {
            LoadingView().height(260)
          } else {
            EmptyView({
              emptyText: this.hasFilter()
                ? '当前筛选没有结果，试试放宽条件或点「重置」'
                : '暂无推荐，请检查网络或切换推荐来源'
            })
          }
        } else {
          Grid() {
            LazyForEach(this.recDataSource, (item: RecommendItem) => {
              GridItem() {
                VodCard({
                  cardTitle: item.title,
                  cardPic: item.cover,
                  // 评分走海报下沿横幅样式；无评分（空/0）不显示，免得满屏「评分： 0」
                  cardRemarks: '',
                  cardRating: item.rating !== undefined && item.rating !== '' && item.rating !== '0'
                    ? '评分： ' + item.rating : '',
                  cardSource: '',
                  // 方案 B「光从内容来」：采样海报主色，卡片向页面洒出同色光晕。
                  // 只在推荐区开 —— 采样要额外解码一次，长列表里没必要每张都做。
                  cardGlow: true,
                  onCardClick: () => {
                    this.openRecommend(item);
                  }
                })
              }
            }, (item: RecommendItem) => item.id)
          }
          .columnsTemplate(this.recColumnsTemplate())
          .columnsGap(IndexPage.REC_COL_GAP)
          .rowsGap(this.wide() ? 16 : 14)
          .padding({ left: 16, right: 16 })
          .width('100%')
          .opacity(this.recSwitching ? 0.45 : 1)
          .cachedCount(6)
        }

        if (this.recommendItems.length > 0) {
          this.loadMoreFooter()
        }
      }
      .width('100%')
      // bottom 里那 96vp 是给导航坞让位：坞是浮在内容上的，
      // 不留这一截的话滚到底时最后一行永远被它压住。
      .padding({ top: this.topInset(), bottom: 20 + IndexPage.NAV_CONTENT_PAD })
      // 实测首页可用宽度：旋转、分屏、折叠展开都会改变它，所以不能只在启动时取一次。
      // 阈值 1vp 防止亚像素抖动引发无谓重排。
      .onAreaChange((oldArea: Area, newArea: Area) => {
        const w: number = newArea.width as number;
        if (w > 0 && Math.abs(w - this.homeWidth) > 1) {
          this.homeWidth = w;
        }
      })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      // 拉到顶/底都有一手回弹；alwaysEnabled 让内容不满一屏时也能拉出弹簧
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      // 只在「用户滚动结束」时记录位置：横竖屏重排引起的偏移夹取不会触发 onScrollStop，
      // 不会把被夹后的错误偏移当成用户的真实位置
      .onScrollStop(() => {
        try {
          this.homeOffset = this.homeScroller.currentOffset().yOffset;
        } catch (e) {
          // Scroller 未绑定
        }
      })
      // 瀑布流：滑到底自动追加下一页
      .onScrollEdge((side: Edge) => {
        if (side === Edge.Bottom) {
          this.loadMoreRecommend();
        }
      })
      // 惯性滚动不会逐帧回调 onScroll，onDidScroll 才是全程都有的；
      // 偏移量直接问 Scroller 要绝对值，比累加回调里的增量稳妥。
      .onDidScroll(() => {
        try {
          this.syncBackTop(this.homeScroller.currentOffset().yOffset);
        } catch (e) {
          // Scroller 未绑定
        }
      })
      // 弹簧效果本身是系统行为，这里只在「已经贴顶还继续往下拽」时弹提示。
      // 用 touch 而不是 onScrollEdge：后者在贴顶时再拉不会重复触发。
      .onTouch((e: TouchEvent) => {
        if (e.type === TouchType.Down) {
          if (e.touches.length > 0) {
            this.touchStartX = e.touches[0].windowX;
            this.touchStartY = e.touches[0].windowY;
          } else {
            this.touchStartX = 0;
            this.touchStartY = 0;
          }
          this.pullHintFired = false;
        } else if (e.type === TouchType.Move) {
          if (!this.pullHintFired && e.touches.length > 0) {
            const dy: number = e.touches[0].windowY - this.touchStartY;
            const dx: number = e.touches[0].windowX - this.touchStartX;
            // 三个条件缺一不可：
            //   1. 确实是往下走（不是上滑）
            //   2. 纵向位移明显压过横向位移 —— 否则用户其实在横划顶部那几条列表，
            //      手指收势时的下坠不该被当成下拉
            //   3. 页面本来就贴在顶端（在下面下拉没有「到顶」可言）
            if (dy > PULL_MIN_DY && dy > Math.abs(dx) * PULL_VERTICAL_RATIO && this.homeAtTop()) {
              this.pullHintFired = true;
              this.flashPullHint();
            }
          }
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          // 抬手/取消都要把「本次手势已弹过」清掉，否则下一次下拉会哑火
          this.pullHintFired = false;
        }
      })

      // 顶部提示层：整屏透明、不吃触摸，只在最上方居中挂一条小胶囊
      Column() {
        if (this.pullTopHint) {
          Row() {
            Text(PULL_TOP_HINT)
              .fontSize(this.wide() ? 14 : 12)
              .fontColor($r('app.color.color_text'))
              .maxLines(1)
          }
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor($r('app.color.color_chip_bg'))
          .borderRadius(16)
          .border({ width: 1, color: $r('app.color.color_divider') })
          .shadow({ radius: 12, color: '#26000000', offsetX: 0, offsetY: 2 })
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -12 }))
            .animation({ duration: 180, curve: Curve.EaseOut }))
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 10 })
      .hitTestBehavior(HitTestMode.None)

      // 返回顶部：滚过 50 行才出现，浮在右下角（TabBar 之上）
      if (this.showBackTop) {
        Column() {
          Image($r('app.media.ic_back_top'))
            .width(22)
            .height(22)
            // SVG 才能染色，两套主题共用一份资源
            .fillColor($r('app.color.color_text'))
        }
        .width(46)
        .height(46)
        .borderRadius(23)
        .backgroundColor($r('app.color.color_card'))
        .border({ width: 1, color: $r('app.color.color_divider') })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .shadow({ radius: 14, color: '#33000000', offsetX: 0, offsetY: 3 })
        .margin({ right: 16, bottom: 20 })
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.85, y: 0.85 }))
          .animation({ duration: 180, curve: Curve.EaseOut }))
        .onClick(() => {
          this.backToTop();
        })
      }
    }
    .width('100%')
    .height('100%')
    .layoutWeight(1)
  }

  @Builder
  recChip(cat: RecCat) {
    Text(cat.label)
      .fontSize(this.chipFont())
      .fontColor(this.recCatKey === cat.key ? Color.White : $r('app.color.color_text'))
      .backgroundColor(this.recCatKey === cat.key ? $r('app.color.color_primary') : $r('app.color.color_chip_bg'))
      .borderRadius(this.chipRadius())
      .padding({ left: this.chipPadH(), right: this.chipPadH(), top: this.chipPadV(), bottom: this.chipPadV() })
      .onClick(() => {
        if (this.recCatKey !== cat.key) {
          this.recCatKey = cat.key;
          this.recPageStart = 0;
          this.loadRecommend();
        }
      })
  }

  /**
   * 瀑布流底部提示，三态互斥：正在加载 / 还有更多 / 到底了。
   * 「还有更多」做成可点 —— 部分机型上 onScrollEdge 不触发，
   * 留一个手动入口才不会把用户卡在这儿。
   */
  @Builder
  loadMoreFooter() {
    Row() {
      if (this.recLoadingMore) {
        LoadingView({ tipText: '正在加载更多…' })
      } else if (this.recHasMore) {
        Text('上滑或点击加载更多')
          .fontSize(13)
          .fontColor($r('app.color.color_text_secondary'))
      } else {
        Text('已经到底了')
          .fontSize(13)
          .fontColor($r('app.color.color_text_secondary'))
          .opacity(0.7)
      }
    }
    .width('100%')
    .height(this.recLoadingMore ? 84 : 56)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.loadMoreRecommend();
    })
  }

  /**
   * 筛选 chip。
   * 只传恒定的 kind，文案与高亮都在函数体里读 this.xxx ——
   * @Builder 的参数是按值传的，把 label / active 当参数传进来会被固定在首帧，
   * 点选后界面不会变（底部导航踩过同一个坑）。
   */
  @Builder
  filterChip(kind: string) {
    Text(this.filterLabel(kind))
      .fontSize(this.filterFont())
      .fontColor(this.filterActive(kind) ? Color.White : $r('app.color.color_text_secondary'))
      .backgroundColor(this.filterActive(kind) ? $r('app.color.color_primary') : $r('app.color.color_chip_bg'))
      .borderRadius(this.filterPadV() + this.filterFont())
      .padding({ left: this.filterPadH(), right: this.filterPadH(), top: this.filterPadV(), bottom: this.filterPadV() })
      .onClick(() => {
        this.filterPanel = this.filterPanel === kind ? '' : kind;
      })
  }

  @Builder
  resetFilterChip() {
    Text('重置')
      .fontSize(this.filterFont())
      .fontColor($r('app.color.color_text_secondary'))
      .backgroundColor($r('app.color.color_chip_bg'))
      .borderRadius(this.filterPadV() + this.filterFont())
      .padding({ left: this.filterPadH(), right: this.filterPadH(), top: this.filterPadV(), bottom: this.filterPadV() })
      .onClick(() => {
        this.clearFilter();
      })
  }

  /** 展开的筛选面板：标题 + 自动换行的选项 chip */
  @Builder
  filterPanelView() {
    // 左右留白放在外层 Column 的 padding 上，而不是给卡片加 margin ——
    // 卡片本身 .width('100%')，再叠横向 margin 会撑出屏外 32vp。
    Column() {
      Column({ space: 10 }) {
        Row() {
          Text(this.filterPanelTitle())
            .fontSize(12)
            .fontColor($r('app.color.color_text_secondary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
          Text('收起')
            .fontSize(12)
            .fontColor($r('app.color.color_primary'))
            .padding({ left: 10, right: 2, top: 2, bottom: 2 })
            .onClick(() => {
              this.filterPanel = '';
            })
        }
        .width('100%')

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.filterOptions(), (opt: string) => {
            this.filterOptionChip(opt)
          }, (opt: string) => this.filterPanel + '|' + opt + '|' + (this.isOptionSelected(opt) ? '1' : '0'))
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 4 })
      .backgroundColor($r('app.color.color_glass'))
      .borderRadius(10)
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  @Builder
  filterOptionChip(opt: string) {
    Text(opt)
      .fontSize(this.chipFont() - 1)
      .fontColor(this.isOptionSelected(opt) ? Color.White : $r('app.color.color_text'))
      .backgroundColor(this.isOptionSelected(opt) ? $r('app.color.color_primary') : $r('app.color.color_chip_bg'))
      .borderRadius(this.chipRadius() - 2)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.pickOption(opt);
      })
  }

  // ---------- 直播 ----------

  /**
   * 直播源叠卡视图：多张源卡先叠成一摞，点一下由前到后铺开。
   *
   * 这里只画每张卡的标题行 —— 叠着的时候不展开频道，
   * 卡片高度固定 LIVE_CARD_H，才能和列表里的卡片一一对齐（换容器不跳）。
   * 立体感来自三处：逐层向上的错位（LIVE_PILE_STEP）、逐层变小的缩放、
   * 以及每张卡自己的投影（shadow 不能用状态色，深色底上会糊成一团）。
   */

  @Builder
  liveContent() {
    // 外层 Stack 只为了在底部叠一个「收起」入口：
    // 频道多的源展开后能滚出两屏以上，分组标题早被顶出视野，
    // 想换源就得一路滑回去 —— 给个常驻底部的收起按钮省掉这段路。
    Stack({ alignContent: Alignment.Bottom }) {
      Column({ space: 0 }) {
        Row({ space: 8 }) {
          Text('直播')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.color_text'))
            .layoutWeight(1)
          Text('刷新')
            .fontSize(14)
            .fontColor($r('app.color.color_primary'))
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .onClick(() => {
              this.refreshLiveGroups();
              // 刷新后立刻开始统计各源频道数，不用等用户逐个展开才看得到
              this.prefetchLiveCounts(true);
              this.toast('正在刷新各直播源的频道数');
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: this.topInset(), bottom: 8 })

        if (this.liveGroups.length === 0) {
          EmptyView({ emptyText: '暂无直播源，请前往「我的 → 视频源管理」添加' })
        } else {
          List({ space: 0, scroller: this.liveScroller }) {
            ForEach(this.liveGroups, (group: LiveGroupState, i: number) => {
              ListItem() {
                LiveSourceCard({
                  group: group,
                  colorIndex: i % LIVE_CARD_PALETTE,
                  firstInDeck: i === 0,
                  onToggle: (key: string) => {
                    this.toggleLiveGroup(key);
                  },
                  onPlay: (g: LiveGroupState, ch: LiveChannel) => {
                    this.openLive(g, ch);
                  },
                  epgText: (g: LiveGroupState, ch: LiveChannel) => this.epgTextFor(g, ch)
                })
              }
              // 后一张永远压在前一张之上：叠边只吃上一张的底边，
              // 所以展开的卡天然不会被上一张盖住标题 —— 不必再按 expanded
              // 去抬 zIndex（那个判断只要没跟上状态，就会表现为「展开的卡被压住」）。
              .zIndex(i)
            }, (group: LiveGroupState) => group.sourceKey)
          }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        // 展开「长频道」源时底部留白收到 LIVE_EXPAND_BOTTOM（76vp）：
        // List 只把列表项画到内容盒（padding box）边缘，padding-bottom 那段永远是
        // 页面底色 —— 之前留 182vp，卡片底下就空出一条空白带（「没有最大化」）；
        // 归零又会让卡片一路压到胶囊背后（下沿太靠下）。76 正好让卡片下沿
        // 停在胶囊上方，同时仍在「收起频道列表」浮层之下；
        // 浮层那一段让位空间由卡片下内边距承担（LIVE_EXPAND_TAIL）。
        .padding({
          left: 16,
          right: 16,
          // 收起态仍要给导航坞让位
          bottom: this.longExpandedGroup() !== null ? LIVE_EXPAND_BOTTOM : 16 + IndexPage.NAV_CONTENT_PAD
        })
      }
      }
      .width('100%')
      .height('100%')

      if (this.longExpandedGroup() !== null) {
        Row({ space: 8 }) {
          Text('收起频道')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.color_live_collapse_fg'))
          // 箭头必须用可染色的 SVG：原来的 ic_arrow_up_white 是 PNG，
          // fillColor 对 PNG 无效 —— 浅色主题（深胶囊配白箭头）能用，
          // 深色主题换成浅胶囊时就成了白底白箭头。
          Image($r('app.media.ic_chevron_up'))
            .width(14)
            .height(14)
            .fillColor($r('app.color.color_live_collapse_fg'))
        }
        .padding({ left: 18, right: 18, top: 10, bottom: 10 })
        // 胶囊与卡面「反着走」：浅色主题是深胶囊、深色主题是浅胶囊。
        // 七种卡面色再怎么换，按钮永远是画面上对比最强的那一块 —— 不会再出现
        // 「深卡 + 深胶囊」糊成一片的情况。
        .backgroundColor($r('app.color.color_live_collapse_bg'))
        .borderRadius(22)
        .shadow({
          radius: 16,
          color: $r('app.color.color_live_collapse_shadow'),
          offsetY: 5
        })
        // 必须整体落在底部磨砂过渡带**之上**（见 LIVE_COLLAPSE_LIFT）。
        // 之前贴 88vp，浮层下沿正好压在羽化段里 —— 那一段罩子已有 30% 上下的
        // 不透明度，表现为按钮下半截被"洗"进背景，看着像被过渡区遮住了。
        .margin({ bottom: IndexPage.LIVE_COLLAPSE_LIFT })
        .onClick(() => {
          this.collapseAllGroups();
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  // ---------- 我的 ----------

  @Builder
  mineContent() {
    Scroll() {
      Column({ space: 10 }) {
        Column({ space: 4 }) {
          Text($r('app.string.brand_name'))
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.color_text'))
            .width('100%')
            .textAlign(TextAlign.Start)
          Text('多源聚合影视播放器 · 点播 / 直播 / 离线下载')
            .fontSize(12)
            .fontColor($r('app.color.color_text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .padding({
          left: 16,
          right: 16,
          top: this.topInset() + 12,
          // 品牌区是页面顶部元素，这里绝不能用 NAV_CONTENT_PAD（那是给滚到底
          // 避让胶囊用的），否则「品牌区 ↔ 设置菜单」之间会凭空空出 100+ vp。
          bottom: 12
        })

        // 设置项整组做成一张圆角卡：外层只负责左右留白，内层上白底 + 20 圆角 +
        // clip，行与行之间塞一条 0.5 的细分隔线（Column 没有 divider 属性，
        // 只能自己插 Divider）。
        Column() {
          Column({ space: 0 }) {
          SettingsRow({
            rowTitle: '播放历史',
            rowValue: this.homeHistory.length > 0 ? this.homeHistory.length + ' 条' : '',
            onRowClick: () => {
              this.pushHistory();
            }
          })
          Divider()
            .strokeWidth(0.5)
            .color($r('app.color.color_divider'))
            .margin({ left: 18, right: 18 })
          SettingsRow({
            rowTitle: '我的收藏',
            rowValue: this.favCount > 0 ? this.favCount + ' 个' : '',
            onRowClick: () => {
              this.pushFavorites();
            }
          })
          Divider()
            .strokeWidth(0.5)
            .color($r('app.color.color_divider'))
            .margin({ left: 18, right: 18 })
          SettingsRow({
            rowTitle: '视频源管理',
            rowValue: this.vodCount + ' 点播 / ' + this.liveCount + ' 直播',
            onRowClick: () => {
              this.pushSources();
            }
          })
          Divider()
            .strokeWidth(0.5)
            .color($r('app.color.color_divider'))
            .margin({ left: 18, right: 18 })
          SettingsRow({
            rowTitle: '下载管理',
            rowValue: this.downloadCount > 0 ? this.downloadCount + ' 个任务' : '',
            onRowClick: () => {
              this.pushDownloads();
            }
          })
          Divider()
            .strokeWidth(0.5)
            .color($r('app.color.color_divider'))
            .margin({ left: 18, right: 18 })
          SettingsRow({
            rowTitle: '设置',
            rowValue: '',
            onRowClick: () => {
              this.pushSettings();
            }
          })
          // 版本号运行时读取（common/AppVersion），不要再写死字面量：
          // 写死过 'v1.0.0'，结果「关于」页改了、这一行忘了改
          SettingsRow({
            rowTitle: '关于',
            rowValue: AppVersion.display(),
            onRowClick: () => {
              this.pushAbout();
            }
          })
          }
          .width('100%')
          // 深色主题下页面底色是纯色 #191922，而 color_card 是 #1C1C22 ——
          // 每通道只差 3 级，整张卡（尤其下边框）直接糊进背景，看着像没有边界。
          // 所以卡面改用「抬升一档」的 color_card_raised（浅色仍是纯白，
          // 深色换成 #23232B），再加一根 0.5vp 发丝描边把轮廓定住；
          // 浅色主题的描边是全透明，和原来像素一致。
          .backgroundColor($r('app.color.color_card_raised'))
          .border({ width: 0.5, color: $r('app.color.color_card_raised_border') })
          .borderRadius(20)
          .clip(true)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })

        Text('仅供个人学习研究使用 · 详见上方「关于」')
          .fontSize(11)
          .fontColor($r('app.color.color_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          // 底部留白放在滚动内容的末尾，让最后一行能滚过胶囊、不被压住
          .padding({ top: 16, bottom: 24 + IndexPage.NAV_CONTENT_PAD })
      }
      .width('100%')
      // 同详情页：内容不满一屏时 Scroll 会把子内容垂直居中，顶部凭空多出大片空白。
      // 用 minHeight 撑满视口强制顶对齐。
      .constraintSize({ minHeight: '100%' })
    }
    .scrollBar(BarState.Off)
    .layoutWeight(1)
  }
}


/**
 * 直播源卡片：一块整色卡，收起时只露标题条，展开时长出频道列表。
 *
 * 为什么必须是独立 @Component + @ObjectLink：
 * 写在 ForEach 里内联渲染时，expanded 一变整项会被重建（key 变了），
 * 高度是瞬间跳的、animateTo 吃不到；独立组件靠 @ObjectLink 原地重排，
 * 卡片高度和下面卡片的位移才是真正连续的动画。
 *
 * 配色是一整摞彩色浅卡：浅底 + 近黑字。原来第一张是墨黑，展开后底部
 * 「收起频道」黑色浮层压在黑卡上完全看不清，现在全套浅色，浮层恒定可辨。
 */
@Component
struct LiveSourceCard {
  @ObjectLink @Watch('onGroupChanged') group: LiveGroupState;
  /** 用第几套配色（按源顺序循环） */
  @Prop colorIndex: number = 0;
  /** 是不是这一摞的第一张：第一张不用留上间距 */
  @Prop firstInDeck: boolean = false;
  /** 当前已经铺出来的频道行数（分页渲染，见 LIVE_FIRST_ROWS） */
  @State visibleRows: number = 0;
  onToggle: (key: string) => void = (key: string) => {};
  onPlay: (g: LiveGroupState, ch: LiveChannel) => void = (g: LiveGroupState, ch: LiveChannel) => {};
  epgText: (g: LiveGroupState, ch: LiveChannel) => string = (g: LiveGroupState, ch: LiveChannel) => '';

  /**
   * 卡面底色（第 colorIndex 套）。
   *
   * 必须走 $r 资源：浅色主题是淡彩卡，深色主题是低饱和暗彩卡，
   * 两套色值分别在 base / dark 的 color.json 里，切系统深色时整摞卡自动换。
   * 写成 switch 而不是数组下标，是因为 Resource 对象不能在文件级常量里初始化。
   */
  private cardBg(): ResourceColor {
    switch (this.colorIndex % LIVE_CARD_PALETTE) {
      case 1: return $r('app.color.color_live_card_2');
      case 2: return $r('app.color.color_live_card_3');
      case 3: return $r('app.color.color_live_card_4');
      case 4: return $r('app.color.color_live_card_5');
      case 5: return $r('app.color.color_live_card_6');
      case 6: return $r('app.color.color_live_card_7');
      default: return $r('app.color.color_live_card_1');
    }
  }

  /** 卡面前景色：浅色主题近黑字、深色主题近白字 */
  private fg(): ResourceColor {
    return $r('app.color.color_live_card_fg');
  }

  /** 台标底板：浅卡用深色半透明、暗卡用浅色半透明 */
  private plate(): ResourceColor {
    return $r('app.color.color_live_card_plate');
  }

  aboutToAppear(): void {
    // 组件也可能是在「已展开」状态下被创建出来的（列表重建、返回页面），
    // 这时 @Watch 不会触发，得自己铺一次首屏行数。
    this.onGroupChanged();
  }

  /** expanded / loading / channels 任何一个变了都会进来 */
  onGroupChanged(): void {
    const cap = this.rowsCap();
    if (!this.group.expanded) {
      this.visibleRows = 0;
      return;
    }
    if (this.visibleRows === 0 || this.visibleRows > cap) {
      this.visibleRows = Math.min(LIVE_FIRST_ROWS, cap);
    }
  }

  /** 实际要铺的行数上限（1022 个频道的源也只铺前 300 行） */
  private rowsCap(): number {
    const n: number = this.group.channels.length;
    return n > LIVE_MAX_ROWS ? LIVE_MAX_ROWS : n;
  }

  /** 滑到底再补一批 */
  private appendRows(): void {
    const cap = this.rowsCap();
    if (this.visibleRows < cap) {
      this.visibleRows = Math.min(cap, this.visibleRows + LIVE_MORE_ROWS);
    }
  }

  build() {
    Column() {
      // 标题行 —— 叠起来时露出来的就是这一条
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text(this.group.sourceName)
            .fontSize(21)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.fg())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          if (this.group.expanded) {
            Text(this.group.channels.length.toString() + ' 个频道 · 点频道直接播放')
              .fontSize(11)
              .fontColor(this.fg())
              .opacity(0.55)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.group.loading) {
          Text('统计中')
            .fontSize(13)
            .fontColor(this.fg())
            .opacity(0.6)
        } else {
          Text(this.group.loaded ? this.group.channels.length.toString() : '—')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.fg())
            .opacity(0.8)
        }
      }
      .width('100%')
      .height(LIVE_HEADER_H)
      .onClick(() => {
        this.onToggle(this.group.sourceKey);
      })

      if (this.group.expanded) {
        if (this.group.loading) {
          LoadingView({ tipText: '加载频道…' }).height(90)
        } else if (this.group.error !== '') {
          Text(this.group.error)
            .fontSize(12)
            .fontColor(this.fg())
            .opacity(0.7)
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ bottom: 16 })
        } else if (this.group.channels.length === 0) {
          Text('未获取到频道')
            .fontSize(12)
            .fontColor(this.fg())
            .opacity(0.7)
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ bottom: 16 })
        } else {
          Column() {
            // 只铺 visibleRows 行：1000+ 频道的源如果一次建 300 行（每行还带
            // 一个 NetImage 子组件），展开那一下要卡近 1 秒，看着就是「点了没反应」。
            // 现在先铺 24 行让卡片立刻长出来，剩下的滑到底部再补齐。
            ForEach(this.group.channels.slice(0, this.visibleRows), (ch: LiveChannel) => {
              // 频道行以台标为主视觉：左台标 + 右侧频道名/节目单
              Row({ space: 12 }) {
                Stack({ alignContent: Alignment.Center }) {
                  if (ch.logo !== undefined && ch.logo !== '') {
                    NetImage({ url: ch.logo, boxWidth: 200, boxHeight: 200, fit: ImageFit.Contain })
                      .width(64)
                      .height(44)
                      .borderRadius(6)
                  } else {
                    Text(ch.name.length > 0 ? ch.name.substring(0, 1) : '?')
                      .fontSize(20)
                      .fontColor(this.fg())
                      .opacity(0.75)
                  }
                }
                .width(64)
                .height(44)
                .backgroundColor(this.plate())
                .borderRadius(8)
                .clip(true)

                Column({ space: 3 }) {
                  Text(ch.name)
                    .fontSize(15)
                    .fontColor(this.fg())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Start)
                  if (this.epgText(this.group, ch) !== '') {
                    Text(this.epgText(this.group, ch))
                      .fontSize(12)
                      .fontColor(this.fg())
                      .opacity(0.55)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                      .textAlign(TextAlign.Start)
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding({ left: 2, right: 2, top: 9, bottom: 9 })
              .onClick(() => {
                this.onPlay(this.group, ch);
              })
            }, (ch: LiveChannel) => ch.id)

            // 底部哨兵：真正出现在可视区里才补下一批。
            // 用 onVisibleAreaChange 而不是 onAppear —— Column 里的节点是一次性
            // 全建出来的，onAppear 一挂上就立刻触发，等于没分页。
            if (this.visibleRows < this.rowsCap()) {
              Text('继续上滑加载（还有 ' + (this.rowsCap() - this.visibleRows).toString() + ' 个频道）')
                .fontSize(12)
                .fontColor(this.fg())
                .opacity(0.45)
                .width('100%')
                .height(44)
                .textAlign(TextAlign.Center)
                .onVisibleAreaChange([0.0, 0.01], (isVisible: boolean, currentRatio: number) => {
                  if (isVisible && currentRatio > 0) {
                    this.appendRows();
                  }
                })
            }
          }
          .width('100%')
          .padding({ bottom: 14 })
        }
      }
    }
    .width('100%')
    .padding({ left: 18, right: 18 })
    .backgroundColor(this.cardBg())
    .borderRadius(20)
    .clip(true)
    // 叠边全靠「自己这一张」的状态决定：收起的卡把下一张往上拉一个重叠量，
    // 展开的卡不拉。不再由外面算好间距再传进来 —— 之前那套在切换深浅主题后
    // 会算错（外面认为还是收起的），结果就是展开的卡压住下一张的标题。
    .margin({
      top: this.firstInDeck ? 0 : LIVE_CARD_GAP,
      bottom: this.group.expanded ? 0 : -LIVE_STACK_OVERLAP
    })
    // 收起态固定成一个「标题条 + 一点余量」的高度；展开后交给内容撑
    .constraintSize({ minHeight: this.group.expanded ? 0 : LIVE_CARD_H })
  }
}
