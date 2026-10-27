/**
 * 直播播放页：M3U/FLV 直播流播放、节目单（EPG）、收藏
 * 直播流由 AVPlayer 原生刷新播放列表，不做本地重写
 */

import { window, PiPWindow, curves } from '@kit.ArkUI';
import { DevicePolicy } from '../common/DevicePolicy';
import { SystemInsets } from '../common/SystemInsets';
import { ScreenKeeper } from '../common/ScreenKeeper';
import { AvPlayerController } from '../player/AvPlayerController';
import { PlayUrlResolver } from '../player/PlayUrlResolver';
import { VideoSurface } from '../player/VideoSurface';
import { SourceManager } from '../data/SourceManager';
import { HistoryStore } from '../data/HistoryStore';
import { HttpClient } from '../net/HttpClient';
import { XmltvParser } from '../model/XmltvParser';
import { EpgProgramme } from '../model/Types';
import { Utils } from '../common/Utils';
import { LoadingView } from '../components/CommonWidgets';
import { NavIds } from '../common/NavIds';
import { AppLifecycle } from '../common/AppLifecycle';
import { latestNavParam } from '../common/NavParam';

export interface LivePlayerPageParam {
  channelUrl: string;
  channelName: string;
  sourceKey: string;
  sourceName: string;
  logo: string;
  tvgId: string;
}

@Component
export struct LivePlayerPage {
  navPathStack: NavPathStack = new NavPathStack();
  channelUrl: string = '';
  /**
   * 这两项直接渲染在顶部（频道名、源名）。必须是 @State：
   * Navigation 复用缓存节点时页面不重建，换台后普通字段赋值不会重绘，
   * 标题会一直停在上一个频道，直到别的 @State 变化才被顺带刷出来。
   */
  @State channelName: string = '';
  sourceKey: string = '';
  @State sourceName: string = '';
  logo: string = '';
  tvgId: string = '';

  private player: AvPlayerController = new AvPlayerController();
  private hideTimer: number = -1;
  private starting: boolean = false;
  private released: boolean = false;
  /**
   * 当前绑定的 Surface id。
   * Navigation 复用缓存节点时 XComponent 不会再走一次 onLoad，只能靠主动取它
   * 把画面接回来；同时也靠它区分「同一个画面又来了一次」和「真的换了画面」。
   */
  private surfaceId: string = '';
  /** 屏幕常亮是否由本页持有：重复进出必须配对，否则会一直亮屏 */
  private screenHeld: boolean = false;

  // ---------- 画中画（回桌面 / 开别的 App 时自动缩小）----------
  /** 交给 VideoSurface 的 XComponent 控制器：创建画中画必须把它传给 PiPWindow */
  private xController: XComponentController = new XComponentController();
  private pipController: PiPWindow.PiPController | null = null;
  private pipCreating: boolean = false;
  /** 小窗是否真的在显示（由 stateChange 维护） */
  private pipActive: boolean = false;
  /**
   * 小窗是「本页主动叫停」的（回前台恢复全屏 / 离开页面），不是用户关掉小窗。
   * 必须自己记：应用主动 stopPiP 时系统回报的 reason 也是 'requestDelete'，
   * 与「用户点小窗关闭」完全同义 —— 不区分就会在恢复全屏那一刻把播放暂停掉。
   */
  private pipStopBySelf: boolean = false;
  /** 停小窗之前是否正在播放：恢复全屏后要接着播，而不是停在那一帧等人再点一次 */
  private pipWasPlaying: boolean = false;
  private pipUnsupported: boolean = false;
  /** XComponent 是否已就绪过：区分「首次起播」和「画面重建」 */
  private surfaceReady: boolean = false;
  /** 回桌面后的宽限计时：等系统把画中画拉起来 */
  private bgTimer: number = -1;
  /** 加载圈延迟计时器，避免直播流抖动时红圈乱闪 */
  private loadingTimer: number = -1;
  private programmes: EpgProgramme[] = [];
  private channelIds: Map<string, string> = new Map<string, string>();

  @State playing: boolean = false;
  @State errorText: string = '';
  /** 连续重试失败次数：点两次仍失败就退回列表，不再让用户干点第三次 */
  private retryCount: number = 0;
  /** 已经在退回列表的路上：播放器一次失败可能连发多个 onError，防重复弹窗/重复 pop */
  private leaving: boolean = false;
  private static readonly RETRY_LIMIT: number = 2;
  @State favorite: boolean = false;
  @State controlsVisible: boolean = true;
  @State epgNow: string = '';
  @State epgNext: string = '';
  @State landscape: boolean = false;
  /**
   * 顶部操作栏的让位量（vp）。手机 42（状态栏 38 + 4），平板按实测放大，
   * 横屏无状态栏时回到 8。见 syncTopPad()。
   */
  @State topPadVp: number = SystemInsets.top() + 8;

  /** 直播流真实分辨率（AVPlayer videoSizeChange 上报） */
  @State videoW: number = 0;
  @State videoH: number = 0;
  /** 播放器可视区（vp），随横竖屏变化 */
  @State canvasW: number = 0;
  @State canvasH: number = 0;
  /** 按原始比例算出的画面尺寸（vp），居中显示不拉伸 */
  @State displayW: number = 0;
  @State displayH: number = 0;
  /**
   * 画面铺满（裁切黑边）模式，与点播页同一套语义：
   * 保持比例、取较大的缩放，超出容器的部分出画，不变形。
   * 直播流常见 16:9，在更宽的平板/车机上会有左右黑边，铺满后能去掉。
   */
  @State fitCover: boolean = false;
  @State hasStarted: boolean = false;
  @State showLoading: boolean = true;
  /** 起播后真卡顿（缓冲持续超过 1.2 秒）时屏幕中央的加载圈 */
  @State stallLoading: boolean = false;
  private stallTimer: number = -1;
  /** 直播流播放进度采样：卡顿判定只看「进度是否还在前进」 */
  private lastPosMs: number = 0;
  private lastProgressAt: number = 0;
  /** 是否收到过进度回调；一次都没有的流无法判断卡顿，宁可不弹圈 */
  private progressSeen: boolean = false;

  aboutToAppear(): void {
    // 顶部栏让位量按窗口实测（平板状态栏比手机高，写死 42 会压住时间/电量）
    this.syncTopPad();
    // 播放页存活期间保持屏幕常亮：平板全屏播放时系统休眠计时一到会直接黑屏锁屏
    this.holdScreen();
    this.favorite = HistoryStore.shared().isLiveFavorite(this.channelUrl);
    this.loadEpg();
    this.bindCallbacks();
    AppLifecycle.bgHandler = (background: boolean) => {
      this.handleAppBackground(background);
    };
  }

  aboutToDisappear(): void {
    // 逐项隔离：任何一步抛错都不能把「交还窗口布局」「释放播放器」带过去，
    // 否则回到频道列表后直播还在响、界面还会被拉长。
    this.safeStep('screen', () => {
      this.dropScreen();
    });
    this.safeStep('stall', () => {
      this.clearStall();
    });
    // 不管从哪个入口离开都要把方向交还给系统、复原窗口布局。
    // 不能用 setLandscape(false)：那会把主窗口锁死在 PORTRAIT，
    // 回到首页后整个 APP 不再跟随平板旋转（"偶尔转不动"的根因）。
    this.safeStep('window', () => {
      this.landscape = false;
      this.restoreWindowState();
    });
    this.safeStep('release', () => {
      this.release();
    });
  }

  /** 清理动作逐个隔离：一步失败不能连累后面的步骤 */
  private safeStep(name: string, step: () => void): void {
    try {
      step();
    } catch (e) {
      console.warn('[live] cleanup failed at ' + name);
    }
  }

  /** 持有屏幕常亮（幂等）：本例只持有一份，重复调用不会把系统计数堆起来 */
  private holdScreen(): void {
    if (this.screenHeld) {
      return;
    }
    this.screenHeld = true;
    ScreenKeeper.acquirePlayback();
  }

  /** 交还屏幕常亮（幂等） */
  private dropScreen(): void {
    if (!this.screenHeld) {
      return;
    }
    this.screenHeld = false;
    ScreenKeeper.releasePlayback();
  }

  /**
   * NavDestination 的 onShown：**只处理「缓存节点被再次复用」这一种情况**。
   *
   * Navigation 会按路由名缓存 NavDestination 节点：pop 之后再 push 同一个路由，
   * 框架直接复用缓存的节点 —— 组件实例不会重建，aboutToAppear 不再执行，
   * XComponent 也不会重新 onLoad。上一次留下的东西全是死的：
   *   - released 仍是 true → startPlay 的守卫直接挡掉，画面永远停在「缓冲中」；
   *   - 参数还是上一次的   → 点任何频道播的都是最早打开的那一路；
   *   - 竖屏没切回来       → 切横屏写在 onSurfaceReady 里，而它不会再触发。
   * 所以这里把一次性状态全部归零，再用缓存节点上还活着的 Surface 重建播放器。
   *
   * 判据用 released：离开本页一定走 release()（back 与 aboutToDisappear 两条路都调），
   * 首次进入以及「从后台回前台」时 released 都是 false，不会被误判成再次进入。
   */
  /**
   * 顶部操作栏让位：读窗口真实的状态栏占位，不再写死 42vp。
   *
   * 写死 42 只在手机上对（状态栏 38 + 4）；平板状态栏更高，
   * 全屏播放时收藏、分享这一排会压在时间与电量上。横屏时系统若把状态栏
   * 收起来（实测 0），退到 8，与改之前的表现一致。
   */
  private syncTopPad(): void {
    const measured: number = SystemInsets.measureTopVp(DevicePolicy.currentWindow());
    if (measured < 0) {
      return;
    }
    // 20vp 以下有两种情况：横屏时是真的没有状态栏（贴边 8 即可）；
    // 竖屏则多半是窗口刚创建、量到的是半个值 —— 退回旧的保守值 42，
    // 宁可多留一点也不要把时间、电量压在图标底下。
    let pad: number = this.landscape ? 8 : 48;
    if (measured >= 20) {
      pad = measured + 8;
    }
    if (pad !== this.topPadVp) {
      this.topPadVp = pad;
    }
  }

  private onPageShown(): void {
    // 缓存节点复用：进页面时的实测值可能已经过期（比如刚从横屏回来）
    this.syncTopPad();
    if (!this.released) {
      return;
    }
    this.applyParamFromStack();
    this.resetForReentry();
    // 缓存节点复用时 onSurfaceReady 不会再触发，窗口这两件事必须自己补上
    this.applyWindowFullScreen(true);
    this.setLandscape(true);
    this.resumePlayback(3);
  }

  /** 从路由栈取最新参数：缓存节点复用后，构造时传入的字段还是旧的 */
  private applyParamFromStack(): void {
    const raw: Object | null = latestNavParam(this.navPathStack, 'LivePlayer');
    if (raw === null) {
      return;
    }
    const p: LivePlayerPageParam = raw as LivePlayerPageParam;
    this.channelUrl = p.channelUrl;
    this.channelName = p.channelName;
    this.sourceKey = p.sourceKey;
    this.sourceName = p.sourceName;
    this.logo = p.logo;
    this.tvgId = p.tvgId;
  }

  /** 把上一次留下的状态清干净（画面尺寸与 Surface id 保留，它们还有用） */
  private resetForReentry(): void {
    this.released = false;
    this.surfaceReady = false;
    this.starting = false;
    this.leaving = false;
    this.retryCount = 0;
    this.playing = false;
    this.hasStarted = false;
    this.showLoading = true;
    this.stallLoading = false;
    this.errorText = '';
    this.controlsVisible = true;
    this.lastPosMs = 0;
    this.lastProgressAt = 0;
    this.progressSeen = false;
    this.clearStall();
    this.clearLoadingTimer();
    this.clearBgTimer();
    // release() 里把常亮和前后台回调都交还了，重新进入必须再拿回来
    this.holdScreen();
    AppLifecycle.bgHandler = (background: boolean) => {
      this.handleAppBackground(background);
    };
    this.favorite = HistoryStore.shared().isLiveFavorite(this.channelUrl);
    this.programmes = [];
    this.channelIds = new Map<string, string>();
    this.epgNow = '';
    this.epgNext = '';
    this.loadEpg();
  }

  /**
   * 用缓存节点上仍然有效的 Surface 把播放器接回来。
   * 复用节点时 XComponent 的 onLoad 不会再来一次，只能主动取 surfaceId；
   * 取不到就隔 120ms 再试 —— 节点重新挂载偶尔比 onShown 晚一拍。
   */
  private resumePlayback(retries: number): void {
    const sid: string = this.xController.getXComponentSurfaceId();
    if (sid !== '') {
      this.onSurfaceReady(sid);
      return;
    }
    if (retries <= 0) {
      console.warn('[live] no surface after reentry, playback not started');
      return;
    }
    setTimeout(() => {
      this.resumePlayback(retries - 1);
    }, 120);
  }

  /** 交还窗口状态：方向 + 布局全屏（用缓存的主窗口，不依赖 UIContext） */
  private restoreWindowState(): void {
    this.restoreRotation();
    DevicePolicy.restoreLayout();
  }

  /**
   * 起播后卡顿判定：只在「播放进度连续 1 秒没有前进」时才弹加载圈。
   *
   * 早期版本判据是 `this.buffering`，直播必然误报：直播是滑动窗口，
   * BUFFERING_PERCENT 几乎永远到不了 100，于是任何一次 bufferingUpdate
   * 都会让 1.2 秒后弹出「缓冲中」；而直播页又没有进度回调去清它、
   * 播放状态也不再变化 —— 加载圈从此一直挂着。
   * 症状正是「画面正常播放，中央却一直转圈」。
   *
   * 改为采样进度后，只要 timeUpdate 还在前进就会立刻收圈（见 onProgress），
   * 真卡住才会留下。
   */
  private scheduleStallCheck(): void {
    if (this.stallTimer >= 0 || this.released) {
      return;
    }
    // 一次进度都没收到过（个别流不报 timeUpdate）：无法判断，不出圈更安全
    if (!this.progressSeen) {
      return;
    }
    this.stallTimer = setTimeout(() => {
      this.stallTimer = -1;
      if (this.released || !this.hasStarted) {
        return;
      }
      // 距离上次进度前进已超过 1 秒 = 真的卡住了
      if (Date.now() - this.lastProgressAt >= 1000) {
        this.stallLoading = true;
      }
    }, 1200);
  }

  private clearStall(): void {
    if (this.stallTimer >= 0) {
      clearTimeout(this.stallTimer);
      this.stallTimer = -1;
    }
    this.stallLoading = false;
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private bindCallbacks(): void {
    // 直播流同样会上报 timeUpdate。进度在走就说明画面在正常播放，
    // 这是「缓冲中」误显示的唯一可靠解药：只要进度前进，立刻收圈并取消预约检查。
    this.player.onProgress = (positionMs: number) => {
      if (positionMs <= this.lastPosMs) {
        return;
      }
      this.lastPosMs = positionMs;
      this.lastProgressAt = Date.now();
      this.progressSeen = true;
      // 进度都动了，必然已起播：兜住个别机型不发 playing 状态的情况
      this.hasStarted = true;
      if (this.showLoading) {
        this.showLoading = false;
        this.clearLoadingTimer();
      }
      if (this.stallTimer >= 0 || this.stallLoading) {
        this.clearStall();
      }
    };
    this.player.onPlayStateChanged = (playing: boolean) => {
      this.syncPiPControl(playing);
      this.playing = playing;
      this.showLoading = false;
      this.clearLoadingTimer();
      // 播放状态已经明确变化（含用户手动暂停）：旧的卡顿判定作废，
      // 否则「卡顿中按暂停」会让加载圈一直挂着不走。
      this.clearStall();
      if (playing) {
        this.hasStarted = true;
        this.retryCount = 0;
        this.scheduleHideControls();
      }
    };
    this.player.onError = (message: string) => {
      // 播放器内核给出的是通用文案，这里转成直播语境、用户能看懂的说法
      if (message.indexOf('获取失败') >= 0) {
        this.errorText = '直播源数据获取超时，请稍后重试';
      } else if (message.indexOf('格式不支持') >= 0) {
        this.errorText = '该频道的直播流无法播放，请换台';
      } else if (message.indexOf('暂时无法播放') >= 0) {
        this.errorText = '该频道数据暂不可用，请稍后重试';
      } else {
        this.errorText = message;
      }
      this.showLoading = false;
      this.clearLoadingTimer();
      this.clearStall();
      // 点过两次重试还是起不来：这个频道基本可以判死刑，
      // 直接退回频道列表，比让用户继续点第三次更体面
      if (this.retryCount >= LivePlayerPage.RETRY_LIMIT) {
        this.returnToListWithHint();
      }
    };
    this.player.onBuffering = (percent: number) => {
      if (percent >= 100) {
        this.clearLoadingTimer();
        this.showLoading = false;
        return;
      }
      if (!this.hasStarted) {
        this.showLoading = true;
        return;
      }
      // 直播流水位几乎永远 <100%，绝不能按水位直接弹圈 ——
      // 那正是「画面正常播放，中央一直转圈」的成因。
      // 这里只做「预约」，真正的判据是播放进度是否停摆（见 scheduleStallCheck）。
      if (this.playing) {
        this.scheduleStallCheck();
      }
    };
    // 拿到直播流真实分辨率后重算等比尺寸，避免画面被拉扁
    this.player.onVideoSize = (width: number, height: number) => {
      this.videoW = width;
      this.videoH = height;
      this.updateSurfaceSize();
      const c = this.pipController;
      if (c !== null && width > 0 && height > 0) {
        try {
          c.updateContentSize(width, height);
        } catch (e) {
          // 非画中画态调用会抛错，忽略
        }
      }
    };
  }

  private async loadEpg(): Promise<void> {
    const source = SourceManager.shared().getLiveSource(this.sourceKey);
    if (source === null || source.epg === undefined || source.epg === '') {
      return;
    }
    const res = await HttpClient.getBytes(source.epg, { 'User-Agent': HttpClient.UA }, 12000);
    if (!res.ok || res.text === '') {
      return;
    }
    const parsed = XmltvParser.parse(res.text);
    this.programmes = parsed.programmes;
    this.channelIds = parsed.channels;
    this.refreshEpgText();
  }

  private refreshEpgText(): void {
    const id = XmltvParser.matchChannelId(this.channelIds, this.tvgId, this.channelName);
    if (id === '') {
      return;
    }
    const nn = XmltvParser.nowNext(this.programmes, id, Date.now());
    if (nn.current !== undefined) {
      this.epgNow = nn.current.title + '（' + Utils.formatTime(nn.current.start) + ' - ' + Utils.formatTime(nn.current.stop) + '）';
    }
    if (nn.next !== undefined) {
      this.epgNext = '即将播放：' + nn.next.title;
    }
  }

  private onSurfaceReady(surfaceId: string): void {
    if (surfaceId === '') {
      return;
    }
    // 与点播页一致：先让内容区变成整屏，再切横屏。
    // 这两件事只写在这里是不行的：节点复用后本函数不会再触发，所以 onPageShown
    // 也会各调一次。
    this.applyWindowFullScreen(true);
    this.setLandscape(true);
    if (this.released) {
      // 已经在退场路上（release 之后面才回来）：不要再建播放器
      return;
    }
    if (surfaceId === this.surfaceId && this.player.isCreated()) {
      // 同一个画面又来一次（onLoad 重入 / 复用节点后主动补一次）：
      // 只校正窗口，绝不重建播放器 —— 重建会从头拉流
      this.initPiP();
      return;
    }
    const firstReady: boolean = this.surfaceId === '';
    this.surfaceId = surfaceId;
    this.surfaceReady = true;
    if (!firstReady && this.player.isCreated() && this.player.rebindSurface(surfaceId)) {
      // 画面重建（进出画中画 / 分屏）：只换 Surface，不重起播，
      // 否则每进一次小窗都得重新拉一次流，画面必然黑一下
      this.initPiP();
      return;
    }
    this.player.create(surfaceId).then((ok: boolean) => {
      if (ok && !this.released) {
        this.initPiP();
        this.startPlay();
      }
    });
  }

  private async startPlay(): Promise<void> {
    if (this.starting || this.released) {
      return;
    }
    this.starting = true;
    this.errorText = '';
    this.hasStarted = false;
    this.showLoading = true;
    this.clearLoadingTimer();
    // 换台/重试：进度采样归零。否则上一路流已经跑到的较大进度会让新流的
    // 小进度永远不满足「比上次大」，卡顿检测与收圈路径全部失效。
    this.lastPosMs = 0;
    this.lastProgressAt = 0;
    this.progressSeen = false;
    this.clearStall();
    const headers = PlayUrlResolver.headersFor(this.channelUrl);
    await this.player.playUrl(this.channelUrl, headers, 0);
    this.starting = false;
  }

  private togglePlay(): void {
    this.player.toggle();
    this.controlsVisible = true;
    this.scheduleHideControls();
  }

  private toggleFav(): void {
    const now = HistoryStore.shared().toggleLiveFavorite({
      url: this.channelUrl,
      name: this.channelName,
      logo: this.logo !== '' ? this.logo : undefined,
      sourceKey: this.sourceKey,
      sourceName: this.sourceName,
      createdAt: Date.now()
    });
    this.favorite = now;
    this.toast(now ? '已收藏该频道' : '已取消收藏');
  }

  private clearLoadingTimer(): void {
    if (this.loadingTimer >= 0) {
      clearTimeout(this.loadingTimer);
      this.loadingTimer = -1;
    }
  }

  private scheduleHideControls(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
    }
    this.hideTimer = setTimeout(() => {
      if (this.playing) {
        this.controlsVisible = false;
      }
    }, 4000);
  }

  private release(): void {
    if (this.released) {
      return;
    }
    this.released = true;
    this.player.release();
    this.dropScreen();
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    this.clearBgTimer();
    this.releasePiP();
    AppLifecycle.bgHandler = () => {
      // 页面已释放，不再响应前后台
    };
  }

  private clearBgTimer(): void {
    if (this.bgTimer >= 0) {
      clearTimeout(this.bgTimer);
      this.bgTimer = -1;
    }
  }

  /**
   * 初始化画中画控制器（直播）。
   * 与点播页同一套逻辑：XComponent 的 Surface 就绪后 create，
   * 再 setAutoStartEnabled(true) 让「主窗退后台」自动转成画中画小窗。
   */
  private async initPiP(): Promise<void> {
    if (this.pipController !== null || this.pipCreating || this.pipUnsupported || this.released) {
      return;
    }
    if (!PiPWindow.isPiPEnabled()) {
      this.pipUnsupported = true;
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    this.pipCreating = true;
    try {
      const config: PiPWindow.PiPConfiguration = {
        context: ctx,
        componentController: this.xController,
        navigationId: NavIds.MAIN,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
        contentWidth: this.videoW > 0 ? this.videoW : 1920,
        contentHeight: this.videoH > 0 ? this.videoH : 1080
      };
      const controller: PiPWindow.PiPController = await PiPWindow.create(config);
      if (this.released) {
        controller.stopPiP().catch(() => {
          // 已释放
        });
        return;
      }
      this.pipController = controller;
      controller.setAutoStartEnabled(true);
      controller.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
        this.onPiPStateChange(state, reason);
      });
      controller.on('controlEvent', (param: PiPWindow.ControlEventParam) => {
        this.onPiPControlEvent(param);
      });
    } catch (e) {
      console.warn('[pip] live create failed: ' + JSON.stringify(e));
      this.pipUnsupported = true;
      this.pipController = null;
    } finally {
      this.pipCreating = false;
    }
  }

  private releasePiP(): void {
    const c = this.pipController;
    this.pipController = null;
    this.pipActive = false;
    if (c === null) {
      return;
    }
    try {
      c.off('stateChange');
    } catch (e) {
      // ignore
    }
    try {
      c.off('controlEvent');
    } catch (e) {
      // ignore
    }
    c.stopPiP().catch(() => {
      // 没在显示时会抛 1300012，忽略
    });
  }

  private onPiPStateChange(state: PiPWindow.PiPState, reason: string): void {
    if (state === PiPWindow.PiPState.STARTED) {
      this.pipActive = true;
      this.controlsVisible = false;
      return;
    }
    if (state === PiPWindow.PiPState.ABOUT_TO_STOP) {
      // 记住「停小窗之前是不是在播」：系统会在停窗过程中暂停播放器，
      // 等 STOPPED 再读就已经是 false 了。
      if (!this.pipStopBySelf) {
        this.pipWasPlaying = this.player.isPlaying();
      }
      return;
    }
    if (state === PiPWindow.PiPState.STOPPED) {
      this.pipActive = false;
      const bySelf: boolean = this.pipStopBySelf;
      this.pipStopBySelf = false;
      if (bySelf) {
        // 本页为了让画面收回全屏而叫停的，不是用户要关小窗：
        // 绝不能暂停，否则回到全屏还得再点一次播放。
        this.resumeAfterPiPRestore();
        return;
      }
      if (reason === 'panelActionRestore') {
        // 用户点了小窗上的「全屏 / 恢复」按钮：应用已被拉回前台，接着播
        this.resumeAfterPiPRestore();
        return;
      }
      // 用户主动关掉小窗：必须停播，否则声音会在后台一直响
      if (reason === 'panelActionDelete' || reason === 'dragDelete' || reason === 'requestDelete') {
        this.pipWasPlaying = false;
        this.player.pause();
      }
      return;
    }
    if (state === PiPWindow.PiPState.ERROR) {
      this.pipActive = false;
    }
  }

  private onPiPControlEvent(param: PiPWindow.ControlEventParam): void {
    if (param.controlType !== PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE) {
      return;
    }
    // 不看 status，直接按播放器真实状态取反，避免不同版本语义差异
    if (this.player.isPlaying()) {
      this.player.pause();
    } else {
      this.player.play();
    }
  }

  private syncPiPControl(playing: boolean): void {
    const c = this.pipController;
    if (c === null) {
      return;
    }
    try {
      c.updatePiPControlStatus(PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
        playing ? PiPWindow.PiPControlStatus.PAUSE : PiPWindow.PiPControlStatus.PLAY);
    } catch (e) {
      // 非画中画态调用会抛错，忽略
    }
  }

  /**
   * 回到桌面 / 打开其他 App。画中画是系统异步拉起的，
   * 给 1.2 秒宽限；到点还没有小窗就自己暂停，否则直播声音会在后台一直响。
   */
  private handleAppBackground(background: boolean): void {
    this.clearBgTimer();
    if (this.released) {
      return;
    }
    if (!background) {
      // 回到前台：小窗还挂着就是点应用图标进来的，收回全屏
      this.restoreFromPiP();
      return;
    }
    this.bgTimer = setTimeout(() => {
      this.bgTimer = -1;
      if (this.released || !AppLifecycle.isBackground() || this.pipActive) {
        return;
      }
      this.player.pause();
    }, 1200);
  }

  /** 从画中画收回页面：关掉小窗，画面重新挂回本页的 XComponent */
  private restoreFromPiP(): void {
    if (!this.pipActive) {
      return;
    }
    const c = this.pipController;
    if (c === null) {
      return;
    }
    this.pipActive = false;
    // 停窗前先记住是不是在播：系统会在停窗过程中暂停播放器，之后再读就晚了
    this.pipWasPlaying = this.player.isPlaying();
    // 打上「是自己叫停」的标记 —— 否则系统回报的 requestDelete 会被当成
    // 「用户关掉了小窗」，恢复全屏时直接暂停。注意直播流即便被暂停，
    // 用户也看不出来「卡住了」，只会以为画面冻住，必须靠这里保活。
    this.pipStopBySelf = true;
    try {
      c.stopPiP().catch(() => {
        // 已经不在小窗态会抛 1300012，忽略
      });
    } catch (e) {
      // ignore
    }
  }

  /**
   * 从画中画收回全屏后接着播。
   * 系统停掉小窗时会把播放器暂停，而恢复全屏恰恰是「接着看」的场景，
   * 不该让用户再点一次播放键 —— 除非他本来就是暂停状态下进的小窗。
   */
  private resumeAfterPiPRestore(): void {
    if (!this.pipWasPlaying) {
      return;
    }
    this.pipWasPlaying = false;
    this.nudgePlay(2);
  }

  /**
   * 补播：立刻试一次，没起来再隔 300ms 试一次。
   * 收回全屏时 XComponent 的 Surface 会重新挂回来，onSurfaceReady 里可能要把
   * 播放器重建一遍 —— 比 STOPPED 回调慢一拍，所以不能只试一次。
   */
  private nudgePlay(retries: number): void {
    if (this.released) {
      return;
    }
    this.player.play();
    if (retries <= 0) {
      return;
    }
    setTimeout(() => {
      if (this.released) {
        return;
      }
      if (!this.player.isPlaying()) {
        this.nudgePlay(retries - 1);
      }
    }, 300);
  }


  private areaNumber(v: Length): number {
    if (typeof v === 'number') {
      return v;
    }
    if (typeof v === 'string') {
      const n: number = parseFloat(v);
      return isNaN(n) ? 0 : n;
    }
    return 0;
  }

  /**
   * 按直播流原始宽高比，在可视区内算出「最大且不变形」的画面尺寸。
   * AVPlayer 直接把画面渲染到 XComponent 的 Surface 上，Surface 比例和视频不一致就会拉伸，
   * 所以必须由这里控制 Surface 尺寸，再由外层 Stack 居中。
   */
  private updateSurfaceSize(): void {
    if (this.canvasW <= 0 || this.canvasH <= 0) {
      return;
    }
    if (this.videoW <= 0 || this.videoH <= 0) {
      this.displayW = this.canvasW;
      this.displayH = this.canvasH;
      return;
    }
    const videoRatio: number = this.videoW / this.videoH;
    const canvasRatio: number = this.canvasW / this.canvasH;
    if (this.fitCover) {
      // 铺满（裁切）：保持比例取较大缩放，超出容器的部分出画。
      // 画面不变形，只是左右或上下裁掉一点 —— 与点播页 PlayerPage 算法一致。
      if (videoRatio > canvasRatio) {
        this.displayH = this.canvasH;
        this.displayW = this.canvasH * videoRatio;
      } else {
        this.displayW = this.canvasW;
        this.displayH = this.canvasW / videoRatio;
      }
      return;
    }
    if (videoRatio > canvasRatio) {
      this.displayW = this.canvasW;
      this.displayH = this.canvasW / videoRatio;
    } else {
      this.displayH = this.canvasH;
      this.displayW = this.canvasH * videoRatio;
    }
  }

  /**
   * 播放页专用：把窗口切成「布局全屏」，内容区才真正等于整屏（含状态栏/导航条区域）。
   * 只在本页开启，离开立刻复原 —— 首页/其它页仍走系统默认安全区，不受影响。
   */
  private applyWindowFullScreen(on: boolean): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    window.getLastWindow(context).then((win: window.Window) => {
      win.setWindowLayoutFullScreen(on).catch(() => {
        // 个别系统版本/分屏场景会拒绝，忽略即可，不影响播放
      });
    }).catch(() => {
      // ignore
    });
  }

  private setLandscape(on: boolean): void {
    this.landscape = on;
    // 方向一变，状态栏可能整条出现或收起：先测一次，转完（系统异步）再补一次
    this.syncTopPad();
    setTimeout(() => {
      this.syncTopPad();
    }, 500);
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    window.getLastWindow(context).then((win: window.Window) => {
      if (on) {
        // 播放页显式接管方向：挂起 DevicePolicy 的窗口尺寸自动纠正，避免互抢
        DevicePolicy.suppressed = true;
        win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE);
      } else {
        win.setPreferredOrientation(window.Orientation.PORTRAIT);
      }
    }).catch(() => {
      // ignore
    });
  }

  /**
   * 离开播放页时把屏幕方向交还给系统。
   * setPreferredOrientation 作用在主窗口上，是全局且跨页面持久的：
   * 只要这里锁了 PORTRAIT，回到首页后整个 APP 就不再跟随平板旋转，
   * 只能杀进程重开 —— 与点播 PlayerPage 同一条纪律。
   */
  private restoreRotation(): void {
    // 交还给「设备策略默认方向」：普通手机回竖屏，平板/折叠机回跟随旋转
    DevicePolicy.suppressed = false;
    DevicePolicy.applyDefault();
  }

  private back(): void {
    // 返回键属于「离开页面」：把方向交还系统，而不是锁竖屏。
    // 同时必须**当场停播**：只靠 aboutToDisappear 不够稳，它没跑到的话，
    // 回到频道列表声音还在响，再点别的频道也会被这个残留的播放器占住（起不来新流）。
    this.restoreWindowState();
    this.release();
    this.navPathStack.pop();
  }

  /**
   * 连续两次重试仍失败：提示后自动退回频道列表。
   * 留 260ms 再 pop，是为了让 toast 先挂上去 —— 立刻 pop 会把提示一起带走。
   */
  private returnToListWithHint(): void {
    if (this.leaving) {
      return;
    }
    this.leaving = true;
    this.getUIContext().getPromptAction().showToast({
      message: '该频道当前不可用，请尝试其他频道',
      duration: 2600
    });
    setTimeout(() => {
      this.back();
    }, 260);
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Center }) {
        // ── 指光：跟着手指走的柔光 ──────────────────────────────────────
        // 系统材质对页面内容区的按钮不生效（作用域限制），
        // 这层光是自己画的：按下哪个按钮，光就落在那儿并跟着手走。
        // 画面尺寸由 updateSurfaceSize 按原始宽高比算出，居中的事交给外层 Stack
        VideoSurface({
          // 控制器由页面持有，创建画中画时要交给 PiPWindow
          controller: this.xController,
          surfaceWidth: this.displayW,
          surfaceHeight: this.displayH,
          onSurfaceReady: (surfaceId: string) => {
            this.onSurfaceReady(surfaceId);
          },
          onSurfaceDestroy: () => {}
        })

        Column()
          .width('100%')
          .height('100%')
          .onClick(() => {
            if (!this.controlsVisible) {
              this.controlsVisible = true;
              this.scheduleHideControls();
            } else {
              this.controlsVisible = false;
            }
          })

        if ((this.showLoading || this.stallLoading) && this.errorText === '') {
          // 黑底上用白色圈，别用主题红
          Column({ space: 10 }) {
            LoadingProgress()
              .width(40)
              .height(40)
              .color(Color.White)
              .opacity(0.9)
            Text('缓冲中…')
              .fontSize(12)
              .fontColor('#CCCCCC')
          }
        }
        if (this.errorText !== '') {
          Column({ space: 12 }) {
            Text(this.errorText)
              .fontSize(14)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .maxLines(3)
            // 「返回」让用户能退出重试循环：频道挂了时只给重试会陷入
            // 重试 -> 瞬间失败 -> 再弹窗 的死循环
            Row({ space: 12 }) {
              Button('返回')
                .fontSize(14)
                .fontColor(Color.White)
                .backgroundColor('#40FFFFFF')
                .onClick(() => {
                  this.back();
                })
              Button('重试')
                .fontSize(14)
                .backgroundColor($r('app.color.color_primary'))
                .onClick(() => {
                  this.retryCount++;
                  this.errorText = '';
                  this.startPlay();
                })
            }
          }
          .alignItems(HorizontalAlign.Center)
          .constraintSize({ maxWidth: '82%' })
          .padding({ left: 20, right: 20, top: 16, bottom: 16 })
          .borderRadius(14)
          .backgroundColor('#B3000000')
        }

        if (this.controlsVisible && this.errorText === '') {
          Column({ space: 0 }) {
            Row({ space: 10 }) {
              Stack({ alignContent: Alignment.Center }) {
                Image($r('app.media.ic_player_back'))
                  .width(20)
                  .height(20)
                  .fillColor($r('app.color.color_text'))
              }
              .width(34)
              .height(34)
              .borderRadius(17)
              .backgroundColor($r('app.color.color_player_scrim'))
              .onClick(() => {
                this.back();
              })
              Column({ space: 2 }) {
                Text(this.channelName)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
                  .maxLines(1)
                Text(this.sourceName)
                  .fontSize(11)
                  .fontColor('#CCCCCC')
                  .maxLines(1)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Stack({ alignContent: Alignment.Center }) {
                Image(this.favorite ? $r('app.media.ic_player_star_filled') : $r('app.media.ic_player_star'))
                  .width(19)
                  .height(19)
                  .fillColor(this.favorite ? $r('app.color.color_primary') : $r('app.color.color_text'))
              }
              .width(34)
              .height(34)
              .borderRadius(17)
              .backgroundColor($r('app.color.color_player_scrim'))
              .onClick(() => {
                this.toggleFav();
              })
              Stack({ alignContent: Alignment.Center }) {
                Image($r('app.media.ic_player_refresh'))
                  .width(19)
                  .height(19)
                  .fillColor($r('app.color.color_text'))
              }
              .width(34)
              .height(34)
              .borderRadius(17)
              .backgroundColor($r('app.color.color_player_scrim'))
              .onClick(() => {
                this.startPlay();
              })
              // 与点播页一致：横屏下提供「铺满屏 / 适应屏」切换，
              // 16:9 直播流在更宽的平板上会留左右黑边，铺满后能去掉
              if (this.canvasW > this.canvasH) {
                Text(this.fitCover ? '适应屏' : '铺满屏')
                  .fontSize(13)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#26FFFFFF')
                  .borderRadius(17)
                  .height(34)
                  .padding({ left: 13, right: 13 })
                  .textAlign(TextAlign.Center)
                  .maxLines(1)
                  .onClick(() => {
                    this.fitCover = !this.fitCover;
                    this.updateSurfaceSize();
                  })
              }
              Stack({ alignContent: Alignment.Center }) {
                Image($r('app.media.ic_player_fullscreen'))
                  .width(18)
                  .height(18)
                  .fillColor($r('app.color.color_text'))
                  .opacity(this.landscape ? 1 : 0.85)
              }
              .width(34)
              .height(34)
              .borderRadius(17)
              .backgroundColor($r('app.color.color_player_scrim'))
              .onClick(() => {
                this.setLandscape(!this.landscape);
              })
            }
            .width('100%')
            // 顶部栏位置与点播全屏页保持一致：横屏贴屏幕边缘 8vp
            // （原来固定 14 + 外层 26 = 40vp，横屏全屏下离顶边太远，比点播页低一大截）
            .padding({ left: 20, right: 20, top: this.topPadVp, bottom: 4 })

            // 中部按钮：加载阶段不显示三角，只有「起播过且当前暂停」才出现
            Row() {
              if (this.playing) {
                Stack({ alignContent: Alignment.Center }) {
                  Image($r('app.media.ic_player_pause'))
                    .width(30)
                    .height(30)
                    .fillColor($r('app.color.color_text'))
                }
                .width(62)
                .height(62)
                .borderRadius(31)
                .backgroundColor($r('app.color.color_player_scrim'))
                .onClick(() => {
                  this.togglePlay();
                })
              } else if (this.hasStarted && this.errorText === '') {
                Stack({ alignContent: Alignment.Center }) {
                  Image($r('app.media.ic_player_play'))
                    .width(30)
                    .height(30)
                    .fillColor($r('app.color.color_text'))
                    .margin({ left: 4 })
                }
                .width(62)
                .height(62)
                .borderRadius(31)
                .backgroundColor($r('app.color.color_player_scrim'))
                .onClick(() => {
                  this.togglePlay();
                })
              }
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)

            Column({ space: 4 }) {
              if (this.epgNow !== '') {
                Text('正在播放：' + this.epgNow)
                  .fontSize(12)
                  .fontColor('#EEEEEE')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .textAlign(TextAlign.Start)
              }
              if (this.epgNext !== '') {
                Text(this.epgNext)
                  .fontSize(11)
                  .fontColor('#BBBBBB')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .textAlign(TextAlign.Start)
              }
              Text(this.favorite ? '已收藏' : '点击 ☆ 收藏频道')
                .fontSize(11)
                .fontColor('#BBBBBB')
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 20 })
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#00000099')
          // 上沿不再额外让 26：让位交给顶部栏自己的 padding 控制，
          // 否则横屏下顶部栏会被推到 40vp —— 比点播页低 32vp
          .padding({ top: 0, bottom: 22 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      // 横竖屏切换会改变可视区，每次都按原始比例重算一次
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const w: number = this.areaNumber(newValue.width);
        const h: number = this.areaNumber(newValue.height);
        if (w > 0 && h > 0 && (w !== this.canvasW || h !== this.canvasH)) {
          this.canvasW = w;
          this.canvasH = h;
          // 切回竖屏必须退出「铺满」：16:9 的流铺进竖屏会被裁到只剩中间一条，
          // 而竖屏下按钮是隐藏的，用户没有退路。
          if (this.fitCover && w <= h) {
            this.fitCover = false;
          }
          this.updateSurfaceSize();
        }
      })
    }
    .hideTitleBar(true)
    .hideBackButton(true)
    .onShown(() => {
      this.onPageShown();
    })
    .onBackPressed(() => {
      this.back();
      return true;
    })
  }
}
