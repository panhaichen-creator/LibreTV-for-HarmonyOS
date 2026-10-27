/**
 * 播放页：全屏播放（点播 / 离线缓存）、进度续播、倍速、选集、换源、自动连播
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { window, PiPWindow, curves } from '@kit.ArkUI';
import { AvPlayerController, PlaybackSpeedOption } from '../player/AvPlayerController';
import { DevicePolicy } from '../common/DevicePolicy';
import { SystemInsets } from '../common/SystemInsets';
import { audio, AVVolumePanel } from '@kit.AudioKit';
import { AVCastPicker, AVCastPickerStyle, AVCastPickerColorMode, avSession } from '@kit.AVSessionKit';
import { ScreenKeeper } from '../common/ScreenKeeper';
import { PlayUrlResolver } from '../player/PlayUrlResolver';
import { VideoSurface } from '../player/VideoSurface';
import { CmsClient } from '../model/CmsClient';
import { DetailCache } from '../model/DetailCache';
import { SearchService } from '../model/SearchService';
import { SourceManager } from '../data/SourceManager';
import { HistoryStore } from '../data/HistoryStore';
import { SettingsStore } from '../data/SettingsStore';
import { DownloadManager } from '../data/DownloadManager';
import { Episode, SpeedTestItem, Settings, VideoDetail, PlayRecord } from '../model/Types';
import { Utils } from '../common/Utils';
import { LocalHttpServer } from '../common/LocalHttpServer';
import { NavIds } from '../common/NavIds';
import { AppLifecycle } from '../common/AppLifecycle';
import { Brand } from '../common/Brand';
import { latestNavParam } from '../common/NavParam';
import { ShareService } from '../common/ShareService';
import { ShareTarget } from '../common/ShareLink';
import { common } from '@kit.AbilityKit';

export interface PlayerPageParam {
  sourceKey: string;
  vodId: string;
  episode: number;
  episodeName: string;
  title: string;
  positionMs: number;
  /** 离线播放时传入下载目录；在线播放为空串 */
  offlineDir: string;
  /** 调用方已知的当前集播放地址；为空则由播放页自行加载分集 */
  episodeUrl?: string;
  /** 调用方已知的海报地址；用于给首页「继续观看」补封面 */
  pic?: string;
  /** 播放线路下标；详情页选了非默认线路时传入 */
  lineIndex?: number;
}

/** 竖屏时控制条与画面下沿之间留的空隙（vp） */
const PLAYER_BAR_GAP: number = 10;

@Component
export struct PlayerPage {
  navPathStack: NavPathStack = new NavPathStack();
  /**
   * 下面这四项会直接渲染到界面上（左上角片名、集名、源名、"离线缓存"标记），
   * 所以必须是 @State：Navigation 复用缓存节点时页面不会重建，
   * onPageShown 里改用新参数赋值时，普通字段不会触发重绘 ——
   * 症状就是「换了一部片子续播，左上角还挂着上一部的名字，
   * 要等起播后点一下屏幕才更新」。
   */
  @State sourceKey: string = '';
  vodId: string = '';
  episode: number = 0;
  @State episodeName: string = '';
  @State title: string = '';
  positionMs: number = 0;
  @State offlineDir: string = '';
  /** 调用方已知的当前集播放地址；优先使用，避免再次请求详情被源站限流 */
  episodeUrl: string = '';
  /** 调用方已知的海报地址；用于给「继续观看」补封面 */
  pic: string = '';
  /** 播放线路下标：优先取该线路的分集 */
  lineIndex: number = 0;

  private player: AvPlayerController = new AvPlayerController();
  private holderFile: fs.File | null = null;
  private cacheDir: string = '';
  private surfaceId: string = '';
  private lastSaveAt: number = 0;
  private hideTimer: number = -1;
  /** 加载圈延迟计时器：只有真的卡住才提示，避免正常播放时红圈乱闪 */
  private loadingTimer: number = -1;
  private settings: Settings = SettingsStore.shared().get();
  private starting: boolean = false;
  private released: boolean = false;
  /** 分集加载任务：startPlay 必须等它完成，否则 episodes 还是空数组 */
  private loadTask: Promise<void> | null = null;
  /** 倍速是否已应用：只能在真正进入 playing 后再调 setSpeed，提前调会报 5400102 */
  private speedApplied: boolean = false;
  /** startPlay 全流程进行中（含等待分集），避免重复触发 */
  private playPending: boolean = false;
  /** 起播进行中又收到换集/换源请求：本轮完成后自动重起一次 */
  private restartQueued: boolean = false;
  /** 上一轮 startPlay 是否真的跑过（false = 被守卫挡下、结果不可知） */
  private startRan: boolean = false;
  /** 上一轮 startPlay 的结果 */
  private startOk: boolean = false;

  @State episodes: Episode[] = [];
  @State currentEp: number = 0;
  @State playing: boolean = false;
  @State buffering: boolean = false;
  @State errorText: string = '';
  @State durationMs: number = 0;
  @State positionText: string = '00:00';
  @State durationText: string = '00:00';
  @State sliderValue: number = 0;
  @State sliderMax: number = 100;
  @State controlsVisible: boolean = true;
  /** 点播收藏态：顶部栏星标按钮的实/空心 */
  @State favorite: boolean = false;
  @State showEpisodes: boolean = false;
  @State showSpeeds: boolean = false;
  @State showSources: boolean = false;
  @State speedItems: SpeedTestItem[] = [];
  @State speedTesting: boolean = false;
  @State speedValue: number = 1.0;
  @State landscape: boolean = false;
  /**
   * 顶部操作栏的让位量（vp）。手机 42（状态栏 38 + 4），平板按实测放大，
   * 横屏无状态栏时回到 8。见 syncTopPad()。
   */
  @State topPadVp: number = SystemInsets.top() + 8;

  /** 视频真实分辨率（由 AVPlayer 的 videoSizeChange 上报） */
  @State videoW: number = 0;
  @State videoH: number = 0;
  /**
   * 底部控制条高度（vp）。初值给 66（24 的进度条 + 28 的按钮行 + 上下内边距），
   * 和实测基本一致；首帧就按这个值算抬升量，不会先跳一下再归位，
   * 之后由 onAreaChange 校正成真值。
   */
  @State barH: number = 66;
  /** 播放器可视区域（vp），由根容器 onAreaChange 实测得到 */
  @State canvasW: number = 0;
  @State canvasH: number = 0;
  /** 按原始比例算出的画面尺寸（vp）；居中显示，永不拉伸 */
  @State displayW: number = 0;
  @State displayH: number = 0;
  /** 画面铺满（裁切黑边）模式：车机/大屏上最大化利用屏幕，比例不变、仅裁掉超出部分 */
  @State fitCover: boolean = false;
  /** 系统媒体音量档位（由 AVVolumePanel 写入设备音量，不是播放器内部音量） */
  @State volumeLevel: number = 0;
  private volumeMaxLevel: number = 15;
  /** 投屏用的媒体会话：系统投屏列表只认有 AVSession 的应用 */
  private castSession: avSession.AVSession | null = null;
  /** 是否已经真正起播过（用于区分「首次加载」和「播放中抖动」） */
  @State hasStarted: boolean = false;
  /** 真正控制加载圈显隐，和 buffering 解耦，防止闪一下就没 */
  @State showLoading: boolean = false;
  /** 起播后真卡顿（进度停摆）时屏幕中央的加载圈 */
  @State stallLoading: boolean = false;
  private lastPosMs: number = 0;
  private lastPosAt: number = 0;
  private stallTimer: number = -1;
  /** 滑屏调节：'' 未激活 / 'volume' 音量 / 'brightness' 亮度 */
  @State adjustKind: string = '';
  /** 滑屏调节的当前值（0~1），浮层据此画进度条与百分比 */
  @State adjustValue: number = 0;
  /** 本次滑动开始时的基准值：整段手势都以它为原点，避免逐帧累积漂移 */
  private adjustBase: number = 0;
  /** 主窗口句柄：调亮度要用，提前取好，别在滑动过程里反复 getLastWindow */
  private win: window.Window | null = null;
  /** 浮层延迟消失的定时器 */
  private adjustTimer: number = -1;

  // ---------- 自动换源（加载超时 / 反复卡顿）----------
  /** 起播看门狗：起播后 12 秒仍没进入 playing，判定这一路加载失败 */
  private loadWatchdog: number = -1;
  /** 本次起播累计的真卡顿次数，达到阈值自动换源 */
  private stallCount: number = 0;
  /** 自动换源流程进行中：防止看门狗与卡顿判定同时触发导致连切 */
  private autoSwitching: boolean = false;
  /** 已经自动试过的源：避免在几个坏源之间来回跳 */
  private autoTried: string[] = [];
  /** 起播超时阈值（毫秒）。8 秒太激进：弱网下起播常要 10 秒左右，
   *  看门狗先触发、测速期间画面又起来了，就出现「刚播起来又跳走」 */
  private static readonly LOAD_TIMEOUT_MS: number = 12000;
  /** 最近一次「进度真正前进」的时间：判断播放是否已经恢复，比 playing 可靠
   *  （卡顿时 playing 仍是 true，只有进度停了） */
  private lastProgressAt: number = 0;
  /** 最近一次真卡顿的时间：用于「平稳播放 60 秒后把卡顿账清零」 */
  private lastStallAt: number = 0;
  /** 同一集卡顿多少次后自动换源 */
  private static readonly STALL_LIMIT: number = 3;
  /** 一次播放最多自动换几次源，超了就交回给用户 */
  private static readonly AUTO_SWITCH_MAX: number = 3;

  // ---------- 弱网自适应（网络越差，越晚才判「加载失败 / 该换源」）----------
  /**
   * 弱网档位：0 正常 / 1 偏弱 / 2 弱网。只升不降，
   * 直到「连续平稳播放 60 秒」才回落一档 —— 抖一下就永久放宽阈值，
   * 等于把正常的换源保护也一起废掉。
   */
  private netLevel: number = 0;
  /** 本轮起播的开始时刻（0 = 没在计时）：用来算「多久才出画面」 */
  private loadStartedAt: number = 0;
  /** 最近一次测到的起播耗时（ms），排查时看日志用 */
  private lastStartCostMs: number = 0;
  /** 弱网提示文案：起播期间给用户一句「为什么这么久」 */
  private static readonly WEAK_HINT: string = '网络较慢，正在加大缓冲等待…';
  /** 自动换源的过程提示：写在加载圈下面，不用 toast ——
   *  测速那几秒画面可能自己就恢复了，弹一条转瞬即逝的 toast 看着像误报 */
  @State loadingHint: string = '';

  // ---------- 长按加速 / 长按左右滑快进快退 ----------
  /** 长按已生效（正在加速播放） */
  @State pressSpeed: boolean = false;
  /** 长按后横向拖动：正在预览快进/快退目标位置 */
  @State seekPreviewing: boolean = false;
  /** 预览目标位置（ms） */
  @State seekPreviewMs: number = 0;
  /** 目标位置相对长按起点的偏移（ms），负数 = 快退 */
  @State seekDeltaMs: number = 0;
  /** 长按计时器 */
  private pressTimer: number = -1;
  /** 本次按下的起点（vp） */
  private pressDownX: number = 0;
  private pressDownY: number = 0;
  /** 长按生效瞬间的播放位置：快进/快退都以它为原点，整段手势不累积漂移 */
  private seekBaseMs: number = 0;
  /** 长按后是否已发生明显横向拖动 */
  private seekDragging: boolean = false;
  /** 长按后抬手要吃掉这次 click，否则会顺带把控制条呼出来 */
  private suppressTap: boolean = false;
  /** 长按加速的倍速 */
  private static readonly PRESS_SPEED: number = 2.0;
  /** 长按判定时长（毫秒）：太短会和"轻点唤出控制条"撞车 */
  private static readonly PRESS_DELAY_MS: number = 380;
  /** 横向滑满一屏对应的跳转时长（毫秒） */
  private static readonly SEEK_FULL_SPAN_MS: number = 300000;

  // ---------- 离线播放「声音在走、画面冻住」自愈 ----------
  /** 缓冲开始的时间点（0 = 当前不在缓冲） */
  private bufferStallAt: number = 0;
  /** 已自愈重同步的次数：治不了的源不该无限 seek */
  private resyncCount: number = 0;
  private resyncTimer: number = -1;
  private static readonly RESYNC_LIMIT: number = 5;
  private static readonly RESYNC_AFTER_MS: number = 4000;

  // ---------- 画中画（回桌面 / 开别的 App 时自动缩小）----------
  /** 交给 VideoSurface 的 XComponent 控制器：创建画中画必须把它传给 PiPWindow */
  private xController: XComponentController = new XComponentController();
  private pipController: PiPWindow.PiPController | null = null;
  /** 正在创建控制器：避免 onSurfaceReady 与 videoSizeChange 并发各建一个 */
  private pipCreating: boolean = false;
  /** 画中画窗口是否真的在显示（由 stateChange 维护） */
  private pipActive: boolean = false;
  /**
   * 小窗是「本页主动叫停」的（回前台恢复全屏 / 离开页面），不是用户关掉小窗。
   * 必须自己记：应用主动 stopPiP 时系统回报的 reason 也是 'requestDelete'，
   * 与「用户点小窗关闭」完全同义 —— 不区分就会在恢复全屏那一刻把播放暂停掉。
   */
  private pipStopBySelf: boolean = false;
  /** 停小窗之前是否正在播放：恢复全屏后要接着播，而不是停在那一帧等人再点一次 */
  private pipWasPlaying: boolean = false;
  /** 创建失败过就不再重试：不支持画中画的设备每次进播放页都试一遍纯属浪费 */
  private pipUnsupported: boolean = false;
  /** XComponent 是否已就绪过：用来区分「首次起播」和「画面重建」 */
  private surfaceReady: boolean = false;
  /** 回桌面后的宽限计时：等系统把画中画拉起来 */
  private bgTimer: number = -1;
  /** 屏幕常亮是否由本页持有：重复进出必须配对，否则会一直亮屏 */
  private screenHeld: boolean = false;

  aboutToAppear(): void {
    // 先把顶部栏的让位量校准（缓存节点复用时靠 onShown 里的再次调用）
    this.syncTopPad();
    // 播放页存活期间保持屏幕常亮：平板全屏播放时系统休眠计时一到会直接黑屏锁屏
    this.holdScreen();
    this.syncSystemVolume();
    this.initCastSession();
    const hostCtx = this.getUIContext().getHostContext();
    if (hostCtx !== undefined) {
      this.cacheDir = hostCtx.filesDir + '/play';
    }
    this.currentEp = this.episode;
    this.speedValue = this.settings.defaultSpeed;
    this.positionText = Utils.formatTime(this.positionMs);
    // 收藏态在构造参数注入后即可读取（详情页 / 历史页都已带 sourceKey+vodId）
    this.favorite = HistoryStore.shared().isFavorite(this.sourceKey, this.vodId);
    this.bindCallbacks();
    // 前后台变化回调：判断画中画有没有接管，没接管就得自己停住
    AppLifecycle.bgHandler = (background: boolean) => {
      this.handleAppBackground(background);
    };
    if (hostCtx !== undefined) {
      window.getLastWindow(hostCtx).then((win: window.Window) => {
        this.win = win;
      }).catch(() => {
        // ignore
      });
    }
    if (this.offlineDir === '') {
      this.loadTask = this.loadEpisodes();
    }
  }

  aboutToDisappear(): void {
    // 每一件清理都单独包一层：以前是一串裸调用，前面任何一步抛错，
    // 后面的「交还窗口布局」「释放播放器」就整段被跳过 ——
    // 症状正是「已经回到列表，界面却顶到状态栏底下、声音还在放」。
    this.safeStep('unbindLifecycle', () => {
      AppLifecycle.bgHandler = () => {
        // 页面已离开，不再关心前后台
      };
    });
    this.safeStep('screen', () => {
      this.dropScreen();
    });
    this.safeStep('cast', () => {
      this.releaseCastSession();
    });
    this.safeStep('stall', () => {
      this.clearStall();
    });
    this.safeStep('watchdog', () => {
      this.clearWatchdog();
    });
    this.safeStep('save', () => {
      this.saveProgress();
    });
    // 这两件最要紧：窗口状态必须交还，播放器必须释放
    this.safeStep('window', () => {
      this.restoreWindowState();
    });
    this.safeStep('brightness', () => {
      // 窗口亮度是「霸占式」的：不还原的话，控制中心里调系统亮度会一直失效
      this.restoreBrightness();
    });
    this.safeStep('adjust', () => {
      this.clearAdjustTimer();
    });
    this.safeStep('release', () => {
      this.release();
    });
    this.safeStep('offline', () => {
      // 离线播放用的本地服务只在这一页需要，离开就关掉，别一直占着端口
      if (this.offlineDir !== '') {
        LocalHttpServer.shared().stop();
      }
    });
  }

  /** 清理动作逐个隔离：一步失败不能连累后面的步骤 */
  private safeStep(name: string, step: () => void): void {
    try {
      step();
    } catch (e) {
      // 清理阶段拿不到 UIContext、会话已销毁之类都会走到这里，留一条便于定位
      console.warn('[player] cleanup failed at ' + name);
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
   * Navigation 按路由名缓存 NavDestination 节点，pop 之后再 push 同一个路由名，
   * 框架直接复用缓存节点 —— 组件实例不重建、aboutToAppear 不再执行、XComponent
   * 也不再 onLoad。上一次留下的东西全是死的：
   *   - released / playing 停在旧值 → 竖屏、画面停在最后一帧、中央挂着暂停按钮，
   *     点它还毫无反应（播放器早已释放，toggle() 直接返回）；
   *   - 参数还是上一部的 → 换一部片子进来播的还是上一部。
   * 这里把一次性状态归零，再用缓存节点上还活着的 Surface 重建播放器。
   *
   * 判据用 released：离开本页一定走 release()（back 与 aboutToDisappear 两条路都调），
   * 首次进入以及「从后台回前台」时 released 都是 false，不会被误判成再次进入。
   */
  private onPageShown(): void {
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
    const raw: Object | null = latestNavParam(this.navPathStack, 'Player');
    if (raw === null) {
      return;
    }
    const p: PlayerPageParam = raw as PlayerPageParam;
    this.sourceKey = p.sourceKey;
    this.vodId = p.vodId;
    this.episode = p.episode;
    this.episodeName = p.episodeName;
    this.title = p.title;
    this.positionMs = p.positionMs;
    this.offlineDir = p.offlineDir;
    this.episodeUrl = p.episodeUrl !== undefined ? p.episodeUrl : '';
    this.pic = p.pic !== undefined ? p.pic : '';
    this.lineIndex = p.lineIndex !== undefined ? p.lineIndex : 0;
    this.currentEp = p.episode;
    // 缓存节点复用时收藏态也要跟着新参数刷新
    this.favorite = HistoryStore.shared().isFavorite(this.sourceKey, this.vodId);
  }

  /** 把上一次留下的播放状态清干净（画面尺寸与 Surface id 保留，它们还有用） */
  private resetForReentry(): void {
    this.released = false;
    this.starting = false;
    this.playPending = false;
    this.restartQueued = false;
    this.speedApplied = false;
    this.playing = false;
    this.buffering = false;
    this.hasStarted = false;
    this.showLoading = true;
    this.stallLoading = false;
    this.errorText = '';
    this.loadingHint = '';
    this.durationMs = 0;
    this.durationText = '00:00';
    this.positionText = Utils.formatTime(this.positionMs);
    this.sliderValue = 0;
    this.sliderMax = 100;
    this.controlsVisible = true;
    this.showEpisodes = false;
    this.showSpeeds = false;
    this.showSources = false;
    this.speedItems = [];
    this.speedTesting = false;
    this.videoW = 0;
    this.videoH = 0;
    this.fitCover = false;
    this.adjustKind = '';
    this.autoSwitching = false;
    this.autoTried = [];
    this.stallCount = 0;
    this.episodes = [];
    this.loadTask = null;
    this.lastPosMs = 0;
    this.lastProgressAt = 0;
    this.clearStall();
    this.clearWatchdog();
    this.clearResync();
    this.clearLoadingTimer();
    this.clearBgTimer();
    this.clearAdjustTimer();
    // release() 里把常亮、投播会话、前后台回调都交还了，重新进入必须再拿回来
    this.holdScreen();
    this.settings = SettingsStore.shared().get();
    this.speedValue = this.settings.defaultSpeed;
    this.syncSystemVolume();
    this.initCastSession();
    AppLifecycle.bgHandler = (background: boolean) => {
      this.handleAppBackground(background);
    };
    if (this.offlineDir === '') {
      this.loadTask = this.loadEpisodes();
    }
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
      console.warn('[player] no surface after reentry, playback not started');
      return;
    }
    setTimeout(() => {
      this.resumePlayback(retries - 1);
    }, 120);
  }

  /**
   * 交还窗口状态：方向 + 布局全屏。
   * 两件都要做 —— 只交还方向不关布局全屏，主界面就会顶到状态栏下面、
   * 底部导航贴着屏幕边，看起来像整页被拉长。
   */
  private restoreWindowState(): void {
    this.restoreRotation();
    DevicePolicy.restoreLayout();
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private bindCallbacks(): void {
    this.player.onPrepared = (durationMs: number) => {
      this.durationMs = durationMs;
      this.durationText = Utils.formatTime(durationMs);
      this.sliderMax = durationMs > 0 ? Math.floor(durationMs / 1000) : 100;
      // 不要在这里 setSpeed：prepared 瞬间原生侧可能还没就绪，
      // 会异步抛 5400102「unsupport speed operation」，try/catch 拦不住，直接弹错误界面。
      // 真正的应用时机放到第一次 playing（见 onPlayStateChanged）。
      this.speedApplied = false;
    };
    this.player.onProgress = (positionMs: number, durationMs: number) => {
      // 持续记录当前位置：画中画进出或画面重建导致重新 create 时，
      // startPlay 会用它做续播点；不记的话会跳回进页面时的老位置。
      this.positionMs = positionMs;
      // 进度在推进 = 没有卡顿：取消预约的检查并收掉加载圈
      if (positionMs > this.lastPosMs) {
        this.lastPosMs = positionMs;
        this.lastProgressAt = Date.now();
        // 距上次卡顿已平稳播放 60 秒：旧账清零。
        // 否则一小时里零散卡三次也会被判成「反复卡顿」而换源。
        if (this.stallCount > 0 && this.lastStallAt > 0 && this.lastProgressAt - this.lastStallAt > 60000) {
          this.stallCount = 0;
          // 平稳一分钟：弱网档位退一档，别让阈值永久停在放宽状态
          if (this.netLevel > 0) {
            this.netLevel = this.netLevel - 1;
          }
        }
        if (this.stallTimer >= 0 || this.stallLoading) {
          this.clearStall();
        }
      }
      this.positionText = Utils.formatTime(positionMs);
      if (durationMs > 0) {
        this.sliderValue = Math.floor(positionMs / 1000);
      }
      this.maybeSaveProgress(positionMs, durationMs);
    };
    this.player.onPlayStateChanged = (playing: boolean) => {
      this.playing = playing;
      this.syncCastPlayback(playing);
      this.syncPiPControl(playing);
      this.buffering = false;
      // 一旦进入 playing，立刻收掉加载圈并标记已起播
      this.showLoading = false;
      this.clearLoadingTimer();
      if (playing) {
        // 结算起播耗时（必须在置 hasStarted 之前算，这里只是顺序清楚）
        if (this.loadStartedAt > 0) {
          this.noteStartCost(Date.now() - this.loadStartedAt);
          this.loadStartedAt = 0;
        }
        if (this.loadingHint === PlayerPage.WEAK_HINT) {
          this.loadingHint = '';
        }
        this.hasStarted = true;
        this.clearStall();
        this.clearWatchdog();
        this.scheduleHideControls();
        // 只有真正进入 playing 才应用倍速；1.0 倍速是默认值，不必调用，避免无谓报错
        if (!this.speedApplied) {
          this.speedApplied = true;
          if (this.speedValue !== 1) {
            this.player.setSpeed(this.speedValue);
          }
        }
      }
    };
    this.player.onCompleted = () => {
      this.saveProgress();
      if (this.settings.autoNext && this.currentEp + 1 < this.episodes.length) {
        this.currentEp = this.currentEp + 1;
        this.positionMs = 0;
        this.positionText = '00:00';
        this.sliderValue = 0;
        this.startPlay();
      } else {
        this.controlsVisible = true;
      }
    };
    this.player.onError = (message: string) => {
      this.errorText = message;
      this.buffering = false;
      this.clearStall();
      this.clearWatchdog();
    };
    this.player.onBuffering = (percent: number) => {
      this.buffering = percent < 100;
      if (percent >= 100) {
        this.clearLoadingTimer();
        this.showLoading = false;
        return;
      }
      if (!this.hasStarted) {
        this.showLoading = true;
        // 已经判定弱网：把话说清楚，否则用户只看得到转圈，以为是卡死
        if (this.netLevel > 0) {
          this.loadingHint = PlayerPage.WEAK_HINT;
        }
        return;
      }
      // 起播后的卡顿检测：缓冲事件只做「预约」，进度真的停住 ~1 秒才弹加载圈。
      // bufferingUpdate 在正常播放时也会频繁 <100%，直接弹会疯狂闪烁
      // （这是之前「起播后一律不弹」的原因 —— 改用进度停摆判定后可以安全恢复）。
      if (this.playing) {
        this.scheduleStallCheck();
      }
    };
    this.player.onVideoSize = (width: number, height: number) => {
      this.videoW = width;
      this.videoH = height;
      this.updateSurfaceSize();
      // 小窗比例要跟视频一致，否则 16:9 的片子会被塞进方框里
      const c = this.pipController;
      if (c !== null && width > 0 && height > 0) {
        try {
          c.updateContentSize(width, height);
        } catch (e) {
          // 非画中画态调用会抛错，忽略
        }
      }
    };
    this.player.onBufferState = (buffering: boolean) => {
      // 只对离线播放启用：本地读盘不该出现长时间缓冲，
      // 一旦 START 之后迟迟等不到 END，就是解码器/渲染器卡住的信号。
      if (this.offlineDir === '' || this.released) {
        return;
      }
      if (buffering) {
        if (this.bufferStallAt === 0) {
          this.bufferStallAt = Date.now();
          this.scheduleResync();
        }
      } else {
        this.bufferStallAt = 0;
        this.clearResync();
      }
    };
  }

  /**
   * 离线播放自愈。
   * 本地文件几乎瞬间就能读到数据，缓冲开始后 4 秒还没结束，说明画面已经冻住了
   * （声音走的是另一条渲染链路，所以用户听到声音正常）。
   * 以当前位置做一次精确 seek 会让解码器重新出帧 —— 这正是用户手动拖进度条的效果。
   */
  private scheduleResync(): void {
    if (this.resyncTimer >= 0 || this.released) {
      return;
    }
    this.resyncTimer = setTimeout(() => {
      this.resyncTimer = -1;
      if (this.released || this.offlineDir === '' || !this.playing) {
        return;
      }
      if (this.bufferStallAt === 0) {
        return;
      }
      if (Date.now() - this.bufferStallAt < PlayerPage.RESYNC_AFTER_MS) {
        this.scheduleResync();
        return;
      }
      if (this.resyncCount >= PlayerPage.RESYNC_LIMIT) {
        return;
      }
      this.resyncCount++;
      this.player.resyncAt(this.player.currentTime());
      // 重新计时，给这次 seek 一次生效机会；仍无起色就继续，直到上限
      this.bufferStallAt = Date.now();
      this.scheduleResync();
    }, PlayerPage.RESYNC_AFTER_MS + 200);
  }

  private clearResync(): void {
    if (this.resyncTimer >= 0) {
      clearTimeout(this.resyncTimer);
      this.resyncTimer = -1;
    }
  }

  /** 起播后卡顿：预约 1 秒后检查进度是否停摆，停摆才弹加载圈（只预约一次） */
  private scheduleStallCheck(): void {
    if (this.stallTimer >= 0 || this.released) {
      return;
    }
    this.lastPosAt = Date.now();
    this.stallTimer = setTimeout(() => {
      this.stallTimer = -1;
      if (this.released || !this.hasStarted) {
        return;
      }
      if (Date.now() - this.lastPosAt >= this.stallIdleMs()) {
        this.stallLoading = true;
        this.stallCount++;
        this.lastStallAt = Date.now();
        // 同一集卡到第二次：网络明显在抖，先把档位抬一档，
        // 后面几次的判定自然放宽（这一轮不会再触发换源）
        if (this.stallCount >= 2 && this.netLevel < 1) {
          this.netLevel = 1;
        }
        // 同一集反复卡到档位上限（3 / 4 / 6 次）：别再让用户盯着转圈，换延时最小的源
        if (this.stallCount >= this.stallLimit()) {
          this.onPlaybackHang();
        }
      }
    }, this.stallProbeDelayMs());
  }

  private clearStall(): void {
    if (this.stallTimer >= 0) {
      clearTimeout(this.stallTimer);
      this.stallTimer = -1;
    }
    this.stallLoading = false;
  }

  private async loadEpisodes(): Promise<void> {
    // 调用方已带来播放地址（如详情页点播放、历史记录续播）：
    // 直接用它拼成一集，跳过网络请求 —— 采集站对同一 id 的连续请求常有限流，
    // 重复请求失败会退化成空 URL，最终误报「没有可用的播放地址」。
    if (this.episodeUrl !== '') {
      this.episodes = [{
        index: this.currentEp,
        name: this.episodeName !== '' ? this.episodeName : '第1集',
        url: this.episodeUrl
      }];
      // 只有一集时选集/下一集按钮不显示；后台补拉完整分集列表（不打断当前播放）
      this.loadFullEpisodeListInBackground();
      return;
    }
    // 优先复用详情页已加载的集数
    const cached: VideoDetail | null = DetailCache.get(this.sourceKey, this.vodId);
    if (cached !== null && cached.episodes.length > 0) {
      // 指定了播放线路时取该线路的分集（详情页选了线路 2/3 等）
      if (this.lineIndex > 0 && cached.info.lines !== undefined && this.lineIndex < cached.info.lines.length) {
        this.episodes = cached.info.lines[this.lineIndex].episodes;
      } else {
        this.episodes = cached.episodes;
      }
      if (this.currentEp >= this.episodes.length) {
        this.currentEp = this.episodes.length - 1;
      }
      if (this.currentEp < 0) {
        this.currentEp = 0;
      }
      return;
    }
    const source = SourceManager.shared().getVodSource(this.sourceKey);
    if (source === null) {
      this.errorText = '视频源不存在';
      return;
    }
    let detail: VideoDetail | null = null;
    try {
      detail = await CmsClient.detail(source, this.vodId);
    } catch (e) {
      detail = null;
    }
    if (detail === null || detail.episodes.length === 0) {
      try {
        detail = await CmsClient.detailFromPage(source, this.vodId);
      } catch (e2) {
        detail = null;
      }
    }
    if (detail === null || detail.episodes.length === 0) {
      // 不要塞入 url 为空的占位集：那样 episodes.length > 0 会让上层误判「已加载完成」，
      // 最终仍然拿不到可播放地址。保持空数组，让调用方能识别失败并重试/换源。
      this.errorText = '获取分集列表失败，请重试或换源';
      this.episodes = [];
      return;
    }
    // 丢弃解析出空地址的分集，避免它们挤占列表并让选集面板出现不可点的项
    const valid: Episode[] = [];
    for (const ep of detail.episodes) {
      if (ep.url !== '') {
        valid.push(ep);
      }
    }
    if (valid.length === 0) {
      this.errorText = '该影片没有可播放的分集地址';
      this.episodes = [];
      return;
    }
    // 网络加载时同样尊重指定的播放线路
    if (this.lineIndex > 0 && detail.info.lines !== undefined && this.lineIndex < detail.info.lines.length) {
      const lineEps: Episode[] = [];
      for (const ep of detail.info.lines[this.lineIndex].episodes) {
        if (ep.url !== '') {
          lineEps.push(ep);
        }
      }
      if (lineEps.length > 0) {
        this.episodes = lineEps;
      } else {
        this.episodes = valid;
      }
    } else {
      this.episodes = valid;
    }
    DetailCache.put(this.sourceKey, this.vodId, detail);
    if (this.currentEp >= this.episodes.length) {
      this.currentEp = this.episodes.length - 1;
    }
    if (this.currentEp < 0) {
      this.currentEp = 0;
    }
  }

  /**
   * 详情页点播放会带 episodeUrl 直接起播（跳过网络请求，起播快），
   * 但 episodes 只有 1 条合成记录，选集/下一集按钮因此消失。
   * 起播后后台补拉完整分集列表：优先 DetailCache，未命中再走网络；
   * 拉到后原位替换，正在播的集按 URL 对位，不中断播放。
   */
  private async loadFullEpisodeListInBackground(): Promise<void> {
    let list: Episode[] = [];
    const cached: VideoDetail | null = DetailCache.get(this.sourceKey, this.vodId);
    if (cached !== null && cached.episodes.length > 0) {
      list = (this.lineIndex > 0 && cached.info.lines !== undefined && this.lineIndex < cached.info.lines.length)
        ? cached.info.lines[this.lineIndex].episodes : cached.episodes;
    } else {
      const source = SourceManager.shared().getVodSource(this.sourceKey);
      if (source === null) {
        return;
      }
      let detail: VideoDetail | null = null;
      try {
        detail = await CmsClient.detail(source, this.vodId);
      } catch (e) {
        detail = null;
      }
      if (detail === null || detail.episodes.length === 0) {
        try {
          detail = await CmsClient.detailFromPage(source, this.vodId);
        } catch (e2) {
          detail = null;
        }
      }
      if (detail === null) {
        return;
      }
      list = (this.lineIndex > 0 && detail.info.lines !== undefined && this.lineIndex < detail.info.lines.length)
        ? detail.info.lines[this.lineIndex].episodes : detail.episodes;
      DetailCache.put(this.sourceKey, this.vodId, detail);
    }
    const valid: Episode[] = [];
    for (const ep of list) {
      if (ep.url !== '') {
        const item: Episode = { index: valid.length, name: ep.name, url: ep.url };
        valid.push(item);
      }
    }
    if (this.released || valid.length <= 1) {
      return;
    }
    // 保持正在播的分集对位：优先按 URL 匹配；匹配不到保持原 currentEp
    let cur = this.currentEp;
    if (cur < 0 || cur >= valid.length || valid[cur].url !== this.episodeUrl) {
      let found = -1;
      for (let i = 0; i < valid.length; i++) {
        if (valid[i].url === this.episodeUrl) {
          found = i;
          break;
        }
      }
      if (found >= 0) {
        cur = found;
      }
    }
    if (cur >= valid.length) {
      cur = valid.length - 1;
    }
    this.currentEp = cur;
    this.episodes = valid;
  }

  private currentEpisode(): Episode | null {
    if (this.episodes.length === 0) {
      return null;
    }
    for (const ep of this.episodes) {
      if (ep.index === this.currentEp) {
        return ep;
      }
    }
    // 部分源的 Episode.index 并非从 0 连续递增（如直接用片源 id），
    // 按 index 匹配会落空；此时退化为按数组下标取值，避免误报「没有可用的播放地址」。
    if (this.currentEp >= 0 && this.currentEp < this.episodes.length) {
      return this.episodes[this.currentEp];
    }
    return this.episodes[0];
  }

  /** 取实际可播放的分集：当前集地址为空时回退到第一个非空地址的分集 */
  private playableEpisode(): Episode | null {
    const ep = this.currentEpisode();
    if (ep !== null && ep.url !== '') {
      return ep;
    }
    for (const item of this.episodes) {
      if (item.url !== '') {
        this.currentEp = item.index;
        return item;
      }
    }
    return ep;
  }

  /**
   * 起播。返回值只为「换源」这条链路服务：
   *  true  = 这一轮真的跑完了且成功
   *  false = 失败，或被守卫挡下（此时看 startRan 区分）
   */
  private async startPlay(): Promise<boolean> {
    if (this.starting || this.playPending || this.released) {
      // 起播进行中又来了换集/换源请求：记入队列，本轮完成后自动重起。
      // 静默丢弃会让用户以为「点了没反应」，还可能诱发交错起播的竞态。
      if (!this.released) {
        this.restartQueued = true;
      }
      return false;
    }
    this.playPending = true;
    try {
      this.startRan = true;
      this.startOk = await this.doStartPlay();
      return this.startOk;
    } finally {
      this.starting = false;
      this.playPending = false;
      if (this.restartQueued && !this.released) {
        this.restartQueued = false;
        this.startPlay();
      }
    }
  }

  private async doStartPlay(): Promise<boolean> {
    this.errorText = '';
    this.loadingHint = '';
    // 换集/换源/重试都是「重新起播」：回到未起播状态，加载圈立即出现，
    // 同时把旧的延迟计时清掉，避免上一次的计时器误触发。
    this.hasStarted = false;
    this.showLoading = true;
    this.clearLoadingTimer();
    this.clearStall();
    this.lastPosMs = 0;
    this.lastProgressAt = 0;
    this.stallCount = 0;
    this.lastStallAt = 0;
    this.bufferStallAt = 0;
    this.resyncCount = 0;
    this.clearResync();
    this.clearWatchdog();
    // 起播计时：到第一次 playing 时算差值，用来判断「这一路是不是本来就慢」
    this.loadStartedAt = Date.now();
    // 离线播放只有本地一份文件，没有别的源可换，不必起表
    if (this.offlineDir === '') {
      this.startWatchdog();
    }
    if (this.offlineDir !== '') {
      this.starting = true;
      // 离线缓存交付的是合并好的整文件 video.ts。
      // 播放器读不到沙箱文件，必须经本地回环 HTTP 喂给它。
      const media = DownloadManager.mediaPath(this.offlineDir);
      try {
        // 仅用于确认文件存在；关掉句柄，播放走本地 HTTP
        const probe = fs.openSync(media, fs.OpenMode.READ_ONLY);
        fs.closeSync(probe);
      } catch (e) {
        this.errorText = '离线文件缺失，请重新下载';
        return false;
      }
      const url: string = await LocalHttpServer.shared().mediaUrl(media);
      if (url === '') {
        this.errorText = '本地播放服务启动失败';
        return false;
      }
      return await this.player.playUrl(url, {}, this.positionMs);
    }
    // 关键：VideoSurface 的 onSurfaceReady 可能早于 aboutToAppear 里发起的分集请求返回，
    // 此时 episodes 仍为空数组，直接取集会误判成「没有可用的播放地址」。
    // 因此必须等分集加载任务结束再取播放地址。
    await this.ensureEpisodesLoaded();
    if (this.released) {
      return false;
    }
    const ep = this.playableEpisode();
    if (ep === null || ep.url === '') {
      this.errorText = this.episodes.length === 0 ? '获取分集列表失败，请重试或换源' : '没有可用的播放地址';
      return false;
    }
    this.starting = true;
    this.buffering = true;
    const resolved = await PlayUrlResolver.resolve(ep.url, this.settings.adFilter, this.cacheDir);
    this.holderFile = resolved.file;
    // 让用户看得见广告过滤在工作；为 0 时不打扰（该源本来就没插广告）
    if (resolved.filteredCount > 0) {
      this.toast('已过滤 ' + resolved.filteredCount + ' 个广告分片');
    }
    if (resolved.kind === 'fd') {
      return await this.player.playFd(resolved.url, resolved.headers, this.positionMs);
    }
    return await this.player.playUrl(resolved.url, resolved.headers, this.positionMs);
  }

  /** 等待分集加载完成；失败后允许重新拉取一次（源站限流时第二次往往能成功） */
  private async ensureEpisodesLoaded(): Promise<void> {
    if (this.offlineDir !== '') {
      return;
    }
    if (this.episodes.length > 0) {
      return;
    }
    if (this.loadTask === null) {
      this.loadTask = this.loadEpisodes();
    }
    try {
      await this.loadTask;
    } catch (e) {
      // 忽略，走下面的重试
    }
    this.loadTask = null;
    if (this.episodes.length > 0 || this.released) {
      return;
    }
    DetailCache.invalidate(this.sourceKey, this.vodId);
    this.loadTask = this.loadEpisodes();
    try {
      await this.loadTask;
    } catch (e) {
      // ignore
    }
    this.loadTask = null;
  }

  private maybeSaveProgress(positionMs: number, durationMs: number): void {
    const now = Date.now();
    if (now - this.lastSaveAt < 5000) {
      return;
    }
    this.lastSaveAt = now;
    this.saveProgress(positionMs, durationMs);
  }

  /**
   * 历史记录封面。
   * 之前这里写死 undefined，导致首页「继续观看」永远是空白灰块。
   * 优先取详情缓存（从详情页进播放页时一定有），其次沿用已有记录（从继续观看直接进播放页时）。
   */
  /** 系统分享：带封面缩略图 + libretv:// 链接，对方点开直接起播 */
  private shareMovie(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      this.toast('无法调起系统分享');
      return;
    }
    const brand: string = ShareService.brandName(ctx);
    const suffix: string = brand !== '' ? (' · 来自 ' + brand) : '';
    const pic: string | undefined = this.resolvePic();
    const t: ShareTarget = {
      sourceKey: this.sourceKey,
      vodId: this.vodId,
      episode: this.currentEp,
      episodeName: this.episodeName,
      title: this.title,
      pic: pic !== undefined ? pic : ''
    };
    ShareService.shareMovie(ctx, t,
      this.episodeName !== '' ? ('正在看 ' + this.episodeName + suffix) : brand)
      .then((ok: boolean) => {
        if (!ok) {
          this.toast('当前系统不支持系统分享');
        }
      });
  }

  private resolvePic(): string | undefined {
    if (this.pic !== '') {
      return this.pic;
    }
    const cached: VideoDetail | null = DetailCache.get(this.sourceKey, this.vodId);
    if (cached !== null && cached.info.cover !== undefined && cached.info.cover !== '') {
      return cached.info.cover;
    }
    const old: PlayRecord | null = HistoryStore.shared().getProgress(this.sourceKey, this.vodId);
    const oldPic: string | undefined = old !== null ? old.pic : undefined;
    if (oldPic !== undefined && oldPic !== '') {
      return oldPic;
    }
    return undefined;
  }

  private saveProgress(positionMs: number = -1, durationMs: number = -1): void {
    // 离线播放同样要记进度。
    // 这里原本是 `this.offlineDir !== '' ||`，等于把离线播放整条排除在播放历史之外 ——
    // "离线续播"因此永远没有起点，从下载页进去只能从 00:00 开始。
    // 记录字段（sourceKey/vodId/episode/positionMs）在线与离线共用一套，
    // 顺带让首页「继续观看」也能反映离线看到哪儿了。
    if (!this.settings.playHistoryEnabled) {
      return;
    }
    // 播放器已经释放时 currentTime() 恒为 0：back() 里刚存好的续播点会被
    // aboutToDisappear 这一轮再写一次冲成 00:00。没有播放器又没给明确位置就跳过。
    if (positionMs < 0 && !this.player.isCreated()) {
      return;
    }
    const pos = positionMs >= 0 ? positionMs : this.player.currentTime();
    const dur = durationMs >= 0 ? durationMs : this.player.duration();
    const ep = this.playableEpisode();
    HistoryStore.shared().saveProgress({
      sourceKey: this.sourceKey,
      vodId: this.vodId,
      name: this.title !== '' ? this.title : '未知视频',
      pic: this.resolvePic(),
      sourceName: SourceManager.shared().getVodSource(this.sourceKey)?.name ?? this.sourceKey,
      episode: this.currentEp,
      episodeName: ep !== null ? ep.name : this.episodeName,
      playUrl: ep !== null ? ep.url : undefined,
      lineIndex: this.lineIndex,
      positionMs: pos,
      durationMs: dur,
      updatedAt: Date.now()
    });
  }

  /** 控制条四角：横屏贴底只圆上沿，竖屏浮起来四角都圆 */
  private barRadius(): BorderRadiuses {
    if (this.landscape) {
      return { topLeft: 24, topRight: 24, bottomLeft: 0, bottomRight: 0 };
    }
    return { topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 20 };
  }

  /**
   * 底部控制条要离屏幕底边多远（vp）。
   *
   * 竖屏（非全屏）时画面是居中的一条，整块屏幕下半截都是黑的：控制条如果照旧
   * 贴底，既离画面老远，又正好压在最容易误触的手势条上。这里把它抬到
   * 「画面下沿再往下 PLAYER_BAR_GAP」—— 压不到画面，也不用伸到屏幕最底下。
   * 横屏画面铺满，算出来是负数，一律归零，保持原来贴底的全屏观感。
   */
  private playerBarLift(): number {
    if (this.landscape || this.canvasH <= 0 || this.displayH <= 0) {
      return 0;
    }
    const videoBottom: number = (this.canvasH + this.displayH) / 2;
    const lift: number = this.canvasH - videoBottom - PLAYER_BAR_GAP - this.barH;
    if (lift > 0) {
      return lift;
    }
    return 0;
  }

  /** onAreaChange 的尺寸可能是数字也可能是 '66.00vp' 这样的字符串 */
  private captureBarHeight(area: Area): void {
    const hv = area.height;
    let h: number = 0;
    if (typeof hv === 'number') {
      h = hv;
    } else if (typeof hv === 'string') {
      h = Number.parseFloat(hv);
    }
    if (!Number.isNaN(h) && h > 0 && Math.abs(h - this.barH) > 0.5) {
      this.barH = h;
    }
  }

  private release(): void {
    if (this.released) {
      return;
    }
    this.released = true;
    this.player.release();
    this.dropScreen();
    if (this.holderFile !== null) {
      try {
        fs.closeSync(this.holderFile.fd);
      } catch (e) {
        // ignore
      }
      this.holderFile = null;
    }
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    this.clearPressTimer();
    this.clearResync();
    this.clearBgTimer();
    this.releasePiP();
    AppLifecycle.bgHandler = () => {
      // 播放器已释放，不再响应前后台
    };
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

  private onSurfaceReady(surfaceId: string): void {
    if (surfaceId === '') {
      return;
    }
    // 先让内容区变成整屏，再切横屏：顺序反了会先按竖屏安全区算一次尺寸
    this.applyWindowFullScreen(true);
    // 一进入播放页就切横屏（视频类应用的标准行为），退出全屏再切回竖屏
    this.setLandscape(true);
    if (this.released) {
      // 已经在退场路上（release 之后面才回来）：不要再建播放器
      return;
    }
    if (surfaceId === this.surfaceId && this.player.isCreated()) {
      // 同一个画面又来一次（onLoad 重入 / 复用节点后主动补一次）：
      // 只校正窗口，绝不重建播放器 —— 重建会把进度冲回片头
      this.initPiP();
      return;
    }
    const firstReady: boolean = this.surfaceId === '';
    this.surfaceId = surfaceId;
    this.surfaceReady = true;
    if (!firstReady && this.player.isCreated() && this.player.rebindSurface(surfaceId)) {
      // 画面重建（进出画中画 / 分屏 / 折叠屏）：只换 Surface，不重建播放器。
      // 否则每进一次小窗都从头播一遍。
      this.initPiP();
      return;
    }
    this.player.create(surfaceId).then((ok: boolean) => {
      if (ok && !this.released) {
        // XComponent 的 surface 已经存在了才建控制器，否则小窗是黑的
        this.initPiP();
        this.startPlay();
      }
    });
  }

  private onSurfaceDestroy(): void {
    // 画面销毁时不释放播放器（页面生命周期统一管理）
  }

  private togglePlay(): void {
    this.player.toggle();
    this.controlsVisible = true;
    this.scheduleHideControls();
  }

  /** 点播收藏：与详情页 / 直播页同一套存储，收藏后立即进「我的收藏」 */
  private toggleFav(): void {
    if (this.vodId === '') {
      // 离线播放 / 未命中 vodId 时无法关联到详情，静默忽略，避免存进一条空记录
      return;
    }
    const now = HistoryStore.shared().toggleFavorite({
      sourceKey: this.sourceKey,
      vodId: this.vodId,
      name: this.title !== '' ? this.title : this.titleLabel(),
      pic: this.resolvePic(),
      sourceName: this.infoSourceName(),
      createdAt: Date.now()
    });
    this.favorite = now;
    this.toast(now ? '已收藏' : '已取消收藏');
  }

  private onSliderChange(value: number, mode: SliderChangeMode): void {
    if (mode === SliderChangeMode.End) {
      const target: number = value * 1000;
      this.player.seekTo(target);
      this.applySeekUi(target);
    }
  }

  /** seek 之后同步 UI 与卡顿判定基准 */
  private applySeekUi(ms: number): void {
    this.positionMs = ms;
    this.positionText = Utils.formatTime(ms);
    this.sliderValue = Math.floor(ms / 1000);
    // 关键：向后 seek 之后 lastPosMs 还停在旧的高位，进度要追很久才「超过」它，
    // 这段空窗会被 scheduleStallCheck 当成长时间卡住，进而误触发自动换源。
    this.lastPosMs = 0;
    this.lastProgressAt = Date.now();
    this.clearStall();
  }

  private selectEpisode(idx: number): void {
    if (idx === this.currentEp) {
      this.showEpisodes = false;
      return;
    }
    this.currentEp = idx;
    this.positionMs = 0;
    this.positionText = '00:00';
    this.sliderValue = 0;
    this.showEpisodes = false;
    this.startPlay();
  }

  private selectSpeed(speed: number): void {
    this.speedValue = speed;
    this.player.setSpeed(speed);
    this.showSpeeds = false;
  }

  private async runSpeedTest(): Promise<void> {
    if (this.title === '') {
      return;
    }
    this.speedTesting = true;
    this.showSources = true;
    const items = await SearchService.speedTest(this.title, this.sourceKey, this.settings);
    this.speedItems = items;
    this.speedTesting = false;
  }

  private async switchSource(item: SpeedTestItem): Promise<void> {
    const done: boolean = await this.applySource(item, false);
    if (done) {
      // 手动换源是用户的主动选择：给自动换源重新记一份预算
      this.autoTried = [];
      this.stallCount = 0;
    }
  }

  /** 真正执行换源；fromAuto=true 时失败不弹 toast，由自动流程自己给文案 */
  private async applySource(item: SpeedTestItem, fromAuto: boolean): Promise<boolean> {
    if (!item.ok || item.vodId === undefined || item.vodId === '') {
      if (!fromAuto) {
        this.toast('该源当前不可用');
      }
      return false;
    }
    const source = SourceManager.shared().getVodSource(item.sourceKey);
    if (source === null) {
      if (!fromAuto) {
        this.toast('该源已被删除');
      }
      return false;
    }
    let detail: VideoDetail | null = null;
    try {
      detail = await CmsClient.detail(source, item.vodId);
    } catch (e) {
      detail = null;
    }
    if (detail === null || detail.episodes.length === 0) {
      if (!fromAuto) {
        this.toast('切换失败：该源没有分集信息');
      }
      return false;
    }
    // 记住当前源：新源起不来时原地回滚，绝不能把用户丢在错误页上
    const prevKey: string = this.sourceKey;
    const prevVodId: string = this.vodId;
    const prevEpisodes: Episode[] = this.episodes;
    const prevEp: number = this.currentEp;
    // 换源后从当前进度继续播放：把现在的播放位置带入新源，
    // AvPlayerController 会在新源 prepared 后自动 seek 过去
    const pos = this.player.currentTime();
    this.showSources = false;
    this.sourceKey = item.sourceKey;
    this.vodId = item.vodId;
    this.episodes = detail.episodes;
    DetailCache.put(this.sourceKey, this.vodId, detail);
    if (this.currentEp >= this.episodes.length) {
      this.currentEp = this.episodes.length - 1;
    }
    this.positionMs = pos > 0 ? pos : 0;
    this.positionText = Utils.formatTime(this.positionMs);
    this.sliderValue = Math.floor(this.positionMs / 1000);
    this.startRan = false;
    const played: boolean = await this.startPlay();
    if (!this.startRan) {
      // 被守卫排队了（上一轮起播还没结束）：新源会在本轮结束后自动起播，不算失败
      return true;
    }
    if (played) {
      return true;
    }
    // 新源没起来：清掉错误态、原地回滚到旧源，用户至少还能接着看
    this.errorText = '';
    this.restartQueued = false;
    this.sourceKey = prevKey;
    this.vodId = prevVodId;
    this.episodes = prevEpisodes;
    this.currentEp = prevEp;
    this.startRan = false;
    await this.startPlay();
    this.errorText = '';
    return false;
  }

  /**
   * 起播超时：弱网下 12 秒根本不够。
   * 实测弱 4G 起播常在 15~25 秒；按 12 秒判死会「明明能播却一直换源」，
   * 而每换一次都要重新拉详情 + 测速 + 解析地址，用户看到的是无休止的转圈。
   */
  private loadTimeoutMs(): number {
    if (this.netLevel >= 2) {
      return 32000;
    }
    if (this.netLevel === 1) {
      return 20000;
    }
    return PlayerPage.LOAD_TIMEOUT_MS;
  }

  /** 卡顿探针等多久再查进度：先给缓冲一点时间，别拿正常的缓冲尖峰当卡顿 */
  private stallProbeDelayMs(): number {
    if (this.netLevel >= 2) {
      return 2200;
    }
    if (this.netLevel === 1) {
      return 1600;
    }
    return 1000;
  }

  /** 进度停摆多久才算真的卡住（弱网下进度本来就是一顿一顿的） */
  private stallIdleMs(): number {
    if (this.netLevel >= 2) {
      return 2000;
    }
    if (this.netLevel === 1) {
      return 1400;
    }
    return 900;
  }

  /** 同一集卡几次才自动换源：弱网下把账放宽，别卡两下就跳走 */
  private stallLimit(): number {
    if (this.netLevel >= 2) {
      return 6;
    }
    if (this.netLevel === 1) {
      return 4;
    }
    return PlayerPage.STALL_LIMIT;
  }

  /**
   * 「进度刚刚还在走」的判定窗。
   * onPlaybackHang 里三处都用它：窗口内还动过，就不许换源。
   * 弱网下进度天生一跳一跳（缓冲一段走一段），窗口必须比正常宽，
   * 否则每次都在「刚缓过来」的瞬间被判成卡死。
   */
  private healthyWindowMs(): number {
    if (this.netLevel >= 2) {
      return 8000;
    }
    if (this.netLevel === 1) {
      return 5000;
    }
    return 3000;
  }

  /** 记录一次真实起播耗时，据此抬高弱网档位 */
  private noteStartCost(costMs: number): void {
    this.lastStartCostMs = costMs;
    if (costMs >= 12000) {
      this.netLevel = 2;
    } else if (costMs >= 6000 && this.netLevel < 1) {
      this.netLevel = 1;
    }
  }

  /** 起播看门狗：默认 12 秒，弱网按档位放宽到 20 / 32 秒 */
  private startWatchdog(): void {
    this.clearWatchdog();
    this.loadWatchdog = setTimeout(() => {
      this.loadWatchdog = -1;
      if (this.released || this.hasStarted || this.errorText !== '') {
        return;
      }
      this.onPlaybackHang();
    }, this.loadTimeoutMs());
  }

  private clearWatchdog(): void {
    if (this.loadWatchdog >= 0) {
      clearTimeout(this.loadWatchdog);
      this.loadWatchdog = -1;
    }
  }

  /**
   * 播放不畅的统一入口：加载超时（12 秒没画面）或同一集真卡顿 3 次。
   * 处理方式是自动换到「延时最小的其他点播源」，并从当前进度续播。
   */
  private onPlaybackHang(): void {
    if (this.released || this.autoSwitching) {
      return;
    }
    // 近 3 秒内进度还在走 = 播放正常，别换源。
    // 判据用「进度」而不是 playing：卡顿时 playing 依然为 true。
    // 1.5 秒太短：缓冲刚恢复的那一下进度会跳一格，还是会被判成「已经卡住」。
    if (this.lastProgressAt > 0 && Date.now() - this.lastProgressAt < this.healthyWindowMs()) {
      return;
    }
    this.showLoading = false;
    this.clearStall();
    if (this.offlineDir !== '') {
      // 离线只有本地一份文件，换不了源
      if (this.errorText === '') {
        this.errorText = '本地文件播放失败，请重新下载';
      }
      return;
    }
    this.autoSwitchSource();
  }

  private async autoSwitchSource(): Promise<void> {
    if (this.autoSwitching || this.released) {
      return;
    }
    if (this.title === '') {
      this.errorText = '播放失败，请稍后重试';
      return;
    }
    if (this.autoTried.length >= PlayerPage.AUTO_SWITCH_MAX) {
      this.errorText = '已自动尝试多个片源仍无法播放，请手动换源';
      return;
    }
    this.autoSwitching = true;
    this.clearWatchdog();
    this.showLoading = true;
    // 提示走加载圈下面的小字，不再一上来就 toast：
    // 测速要好几秒，这期间画面很可能自己缓过来了，此时若已经弹过
    // 「正在自动切换片源」，用户看到的就是「提示刚出现，画面已正常」。
    this.loadingHint = '正在寻找更快的片源…';
    try {
      // 返回结果已按延迟升序排列：靠前的就是延时最小的
      const items: SpeedTestItem[] = await SearchService.speedTest(this.title, this.sourceKey, this.settings);
      if (this.released) {
        return;
      }
      // 测速期间画面已恢复就不再切：这一步是「误切」唯一的拦截点
      if (this.lastProgressAt > 0 && Date.now() - this.lastProgressAt < this.healthyWindowMs()) {
        this.loadingHint = '';
        this.showLoading = false;
        return;
      }
      const candidates: SpeedTestItem[] = [];
      for (const it of items) {
        if (!it.ok || it.vodId === undefined || it.vodId === '') {
          continue;
        }
        if (it.sourceKey === this.sourceKey || this.autoTried.indexOf(it.sourceKey) >= 0) {
          continue;
        }
        candidates.push(it);
        // 最多连试 2 个：再多用户就要盯着加载圈了，不如早点交回手动换源
        if (candidates.length >= 2) {
          break;
        }
      }
      if (candidates.length === 0) {
        this.loadingHint = '';
        this.showLoading = false;
        this.errorText = '没有找到可用的备用片源，请手动换源';
        return;
      }
      let switchedName: string = '';
      for (const c of candidates) {
        // 每个候选源动手前再确认一次——找源、拉详情都已花掉好几秒
        if (this.lastProgressAt > 0 && Date.now() - this.lastProgressAt < this.healthyWindowMs()) {
          this.loadingHint = '';
          this.showLoading = false;
          return;
        }
        this.autoTried.push(c.sourceKey);
        const done: boolean = await this.applySource(c, true);
        if (done) {
          switchedName = c.sourceName;
          break;
        }
        // applySource 内部已回滚到旧源并清掉错误态，这里继续试下一个候选
      }
      this.loadingHint = '';
      if (switchedName !== '') {
        this.showLoading = false;
        this.toast('已切换到「' + switchedName + '」');
      } else {
        this.showLoading = false;
        this.errorText = '备用片源也无法播放，请手动换源';
      }
    } catch (e) {
      this.loadingHint = '';
      this.showLoading = false;
      this.errorText = '自动换源失败，请手动换源';
    } finally {
      this.autoSwitching = false;
      this.loadingHint = '';
    }
  }

  /** Area 里的 Length 可能是 number 也可能是字符串，统一取数值（vp） */
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
   * 一次「划过约 60% 屏高」覆盖 0→100%。
   * 屏幕越大越难一划到底，所以按实测高度取比例，而不是写死一个 vp 值。
   */
  private adjustRange(): number {
    const h: number = this.canvasH > 0 ? this.canvasH : 640;
    return h * 0.6;
  }

  private clearAdjustTimer(): void {
    if (this.adjustTimer >= 0) {
      clearTimeout(this.adjustTimer);
      this.adjustTimer = -1;
    }
  }

  /** 建立投屏会话：AVCastPicker 只对创建了 AVSession 的应用展示可投设备 */
  private async initCastSession(): Promise<void> {
    if (this.castSession !== null) {
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    try {
      const s = await avSession.createAVSession(ctx, 'libretv_player', 'video');
      this.castSession = s;
      await s.activate();
      const md: avSession.AVMetadata = {
        assetId: this.vodId !== '' ? this.vodId : 'unknown',
        title: this.title !== '' ? this.title : Brand.displayName(this.getUIContext())
      };
      await s.setAVMetadata(md);
      // 关键：声明需要「url 投播」能力，投播列表才会出现智慧屏 / DLNA 等设备；
      // 不声明时系统按普通音频会话处理，列表只剩音频输出设备（本次反馈的现象）
      const extras: Record<string, Object> = { 'requireAbilityList': ['url-cast'] };
      await s.setExtras(extras);
    } catch (e) {
      this.castSession = null;
    }
  }

  private releaseCastSession(): void {
    const s = this.castSession;
    this.castSession = null;
    if (s !== null) {
      s.destroy().catch(() => {
        // 忽略
      });
    }
  }

  /** 把播放状态同步给投播会话：播控中心/远端设备靠它显示与控制 */
  private syncCastPlayback(playing: boolean): void {
    const s = this.castSession;
    if (s === null) {
      return;
    }
    try {
      const pos: avSession.PlaybackPosition = { elapsedTime: this.positionMs, updateTime: Date.now() };
      const st: avSession.AVPlaybackState = {
        state: playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
          : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        position: pos
      };
      s.setAVPlaybackState(st).catch(() => {
        // 忽略
      });
    } catch (e) {
      // 忽略
    }
  }

  /**
   * 读取当前系统媒体音量（0..max）。
   * 注意：第三方应用没有系统音量写权限，唯一的合法通道是系统提供的
   * AVVolumePanel 组件（它的 volumeLevel 会写到设备音量），见 build 里的音量浮层。
   */
  private syncSystemVolume(): void {
    try {
      const vm = audio.getAudioManager().getVolumeManager();
      const max: number = vm.getMaxVolumeByStream(audio.StreamUsage.STREAM_USAGE_MOVIE);
      if (max > 0) {
        this.volumeMaxLevel = max;
      }
      this.volumeLevel = vm.getVolumeByStream(audio.StreamUsage.STREAM_USAGE_MOVIE);
    } catch (e) {
      // 个别设备/版本取不到，沿用上次值
    }
  }

  /** 开始滑动：按落点左右分出调音量还是调亮度，并记下基准值 */
  private beginAdjust(x: number): void {
    const half: number = this.canvasW > 0 ? this.canvasW / 2 : 0;
    const kind: string = x > half ? 'brightness' : 'volume';
    this.clearAdjustTimer();
    // 右半屏 = 亮度，左半屏 = 音量
    if (kind === 'volume') {
      // 音量基准取系统当前值：之前调的是播放器内部音量，
      // 上限被手机预先设定的系统音量卡死，怎么滑都不会更响。
      this.syncSystemVolume();
      this.adjustBase = this.volumeMaxLevel > 0 ? this.volumeLevel / this.volumeMaxLevel : 0;
    } else {
      this.adjustBase = this.currentBrightness();
    }
    this.adjustKind = kind;
    this.adjustValue = this.adjustBase;
  }

  /** 滑动中：offsetY 往上滑是负的，取反后「往上」= 变大 */
  private updateAdjust(offsetY: number): void {
    if (this.adjustKind === '') {
      return;
    }
    const range: number = this.adjustRange();
    if (range <= 0) {
      return;
    }
    let v: number = this.adjustBase + (-offsetY / range);
    if (v < 0) {
      v = 0;
    }
    if (v > 1) {
      v = 1;
    }
    this.adjustValue = v;
    if (this.adjustKind === 'volume') {
      // 写系统音量档位（AVVolumePanel 的 volumeLevel 会落到设备音量）
      const lv: number = Math.round(v * this.volumeMaxLevel);
      if (lv !== this.volumeLevel) {
        this.volumeLevel = lv;
      }
    } else {
      this.applyBrightness(v);
    }
  }

  /** 抬手：浮层再留 500ms 让人看清最终值 */
  private endAdjust(): void {
    this.clearAdjustTimer();
    this.adjustTimer = setTimeout(() => {
      this.adjustKind = '';
    }, 500);
  }

  /**
   * 当前窗口亮度（0~1）。
   * getWindowProperties().brightness 返回 -1 表示「跟随系统」，此时拿不到真实值，
   * 只能给个中位起点 —— 第一次滑动会跳一下，之后都由我们自己写死，不再依赖系统。
   */
  private currentBrightness(): number {
    const win = this.win;
    if (win !== null) {
      const b: number = win.getWindowProperties().brightness;
      if (b >= 0) {
        return b > 1 ? 1 : b;
      }
    }
    return 0.5;
  }

  private applyBrightness(v: number): void {
    const win = this.win;
    if (win === null) {
      return;
    }
    win.setWindowBrightness(v).catch(() => {
      // 分屏、投屏等场景可能被拒绝，忽略即可
    });
  }

  /** -1 = 交还系统亮度 */
  private restoreBrightness(): void {
    const win = this.win;
    if (win === null) {
      return;
    }
    win.setWindowBrightness(-1).catch(() => {
      // ignore
    });
  }

  /**
   * 按「视频原始宽高比」算显示尺寸：
   * 取可视区与视频比例中更受限制的一边，等比缩放后居中，多余部分留黑边。
   * 绝不让 Surface 铺满容器 —— 那样等于把画面拉扁。
   */
  private updateSurfaceSize(): void {
    if (this.canvasW <= 0 || this.canvasH <= 0) {
      return;
    }
    if (this.videoW <= 0 || this.videoH <= 0) {
      // 尺寸未知（刚起播）先铺满，拿到 videoSizeChange 后会立刻纠正
      this.displayW = this.canvasW;
      this.displayH = this.canvasH;
      return;
    }
    const videoRatio: number = this.videoW / this.videoH;
    const canvasRatio: number = this.canvasW / this.canvasH;
    if (this.fitCover) {
      // 铺满（裁切）：保持比例取较大缩放，超出的部分被窗口裁掉。
      // 画面不变形，只是左右或上下有少量内容出画 —— 车机等大屏上用这个最大化画面。
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
      // 视频更宽：以宽为准，上下留黑边
      this.displayW = this.canvasW;
      this.displayH = this.canvasW / videoRatio;
    } else {
      // 视频更高：以高为准，左右留黑边
      this.displayH = this.canvasH;
      this.displayW = this.canvasH * videoRatio;
    }
  }

  /**
   * 切换横竖屏（真实屏幕方向，不是旋转画面）。
   * 横屏用 AUTO_ROTATION_LANDSCAPE，允许左右两个横屏方向，横屏时用手机左右翻转都能正立。
   */
  /**
   * 播放页专用：把窗口切成「布局全屏」，内容区才真正等于整屏（含状态栏/导航条区域）。
   * 只在本页开启，离开立刻复原 —— 首页/其它页仍走系统默认安全区，不受影响。
   */
  private applyWindowFullScreen(on: boolean): void {
    // 优先用进页面时就缓存好的主窗口：会话期间 getLastWindow 可能拿不到，
    // 而窗口布局一旦没设上，整页内容就会画到状态栏与导航条底下。
    const cached: window.Window | null = this.win;
    if (cached !== null) {
      try {
        cached.setWindowLayoutFullScreen(on).catch(() => {
          // 个别系统版本/分屏场景会拒绝，忽略即可，不影响播放
        });
        return;
      } catch (e) {
        // 拿不到就退回下面那条路
      }
    }
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
        // 退出全屏必须**强制竖屏**，不能交给系统自动判断：
        // 平板横着拿的时候，AUTO_ROTATION 的目标方向仍然是横屏，
        // 点下去画面一点变化都没有，按钮看起来就像失效了。
        win.setPreferredOrientation(window.Orientation.PORTRAIT);
      }
    }).catch(() => {
      // 忽略窗口操作失败
    });
  }

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

  /**
   * 离开播放页时把屏幕方向交还给系统。
   * setPreferredOrientation 作用在**主窗口**上，是全局且跨页面持久的：
   * 只要这里锁了 PORTRAIT，回到首页后整个 APP 就不再跟随平板旋转，
   * 只能杀进程重开 —— 之前"退出全屏后转不动"的根因就在这里。
   */
  private restoreRotation(): void {
    // 交还给「设备策略默认方向」：普通手机回竖屏，平板/折叠机回跟随旋转
    DevicePolicy.suppressed = false;
    DevicePolicy.applyDefault();
  }

  private back(): void {
    this.saveProgress();
    // 先停播、交还窗口状态，再 pop。
    // 只靠 aboutToDisappear 不够稳：页面销毁由框架调度，万一它没跑到，
    // 用户就会看到「列表页面被拉长、视频声音还在响」。
    this.restoreWindowState();
    // 亮度是霸占式的（setWindowBrightness 作用于主窗口）：不还原的话，
    // 回到列表后控制中心调系统亮度会一直没反应。
    this.restoreBrightness();
    this.clearAdjustTimer();
    this.release();
    this.navPathStack.pop();
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Center }) {
        // ── 指光：跟着手指走的柔光 ──────────────────────────────────────
        // 系统材质对页面内容区的按钮不生效（作用域限制），
        // 这层光是自己画的：按下哪个按钮，光就落在那儿并跟着手走。
        // 视频画面：尺寸由 updateSurfaceSize 按原始宽高比算出，Stack 负责居中
        VideoSurface({
          // 控制器由页面持有：创建画中画时必须把它交给 PiPWindow，
          // 组件内部自己 new 的话页面就够不着了
          controller: this.xController,
          surfaceWidth: this.displayW,
          surfaceHeight: this.displayH,
          onSurfaceReady: (surfaceId: string) => {
            this.onSurfaceReady(surfaceId);
          },
          onSurfaceDestroy: () => {
            this.onSurfaceDestroy();
          }
        })

        // 点击层：轻点画面显示/隐藏控制条（置于控制层之下，避免事件冒泡误触）。
        // 长按加速 / 长按左右滑快进快退也挂在这一层：它铺满全屏、又是直接命中目标，
        // 控制条隐藏时必定收得到 Touch；控制条可见时处理函数里直接让位，
        // 保证按钮和进度条不被抢。
        Column()
          .width('100%')
          .height('100%')
          .onTouch((event: TouchEvent) => {
            this.handlePressTouch(event);
          })
          .onClick(() => {
            // 长按后抬手不该顺带把控制条呼出来
            if (this.suppressTap) {
              this.suppressTap = false;
              return;
            }
            if (!this.controlsVisible) {
              this.controlsVisible = true;
              this.scheduleHideControls();
            } else {
              this.controlsVisible = false;
            }
          })

        // 加载 / 错误态
        if ((this.showLoading || this.stallLoading) && this.errorText === '') {
          Column({ space: 10 }) {
            // 播放器背景是黑的，用白色圈；用主题红在暗背景上非常扎眼
            LoadingProgress()
              .width(44)
              .height(44)
              .color(Color.White)
              .opacity(0.9)
            if (this.loadingHint !== '') {
              Text(this.loadingHint)
                .fontSize(12)
                .fontColor('#CCCCCC')
                .maxLines(1)
            }
          }
          .hitTestBehavior(HitTestMode.None)
        }

        // 长按加速 / 长按左右滑的状态浮层
        if (this.pressSpeed) {
          Column({ space: 6 }) {
            if (this.seekPreviewing) {
              Text(this.seekDeltaText())
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
              Text(Utils.formatTime(this.seekPreviewMs) + ' / ' +
                (this.durationMs > 0 ? this.durationText : '--:--'))
                .fontSize(12)
                .fontColor('#DDDDDD')
            } else {
              Text(this.pressSpeedLabel())
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
              Text('左右滑动可快进 / 快退')
                .fontSize(11)
                .fontColor('#BBBBBB')
            }
          }
          .padding({ left: 20, right: 20, top: 14, bottom: 14 })
          .borderRadius(14)
          .backgroundColor('#B3000000')
          .hitTestBehavior(HitTestMode.None)
        }
        if (this.errorText !== '') {
          Column({ space: 12 }) {
            Text(this.errorText)
              .fontSize(14)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .maxLines(3)
            // 「返回」让用户能退出重试循环：源坏了时只给重试会陷入
            // 重试 -> 瞬间失败 -> 再弹窗 的死循环，回详情页才能换源/换集
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

        // 控制层
        if (this.controlsVisible && this.errorText === '') {
          Column({ space: 0 }) {
            // 顶部栏
            Row({ space: 10 }) {
              // 这些图标原来是纯黑 PNG，深色主题下贴在黑背景上等于隐形。
              // 换成可染色的 SVG，统一取 color_text（与主题相反的明暗），
              // 再垫一层同色系半透明圆底，压在亮画面上也不会糊。
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
                Text(this.titleLabel())
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.offlineDir !== '') {
                  Text('离线缓存 · ' + this.episodeName)
                    .fontSize(11)
                    .fontColor('#CCCCCC')
                } else {
                  Text(this.episodeName + ' · ' + this.infoSourceName())
                    .fontSize(11)
                    .fontColor('#CCCCCC')
                    .maxLines(1)
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              // 收藏星标：点播播放页内即可收藏/取消，与详情页、直播页同款。
              Stack({ alignContent: Alignment.Center }) {
                Image(this.favorite ? $r('app.media.ic_player_star_filled') : $r('app.media.ic_player_star'))
                  .width(20)
                  .height(20)
                  .fillColor(this.favorite ? $r('app.color.color_primary') : $r('app.color.color_text'))
              }
              .width(34)
              .height(34)
              .borderRadius(17)
              .backgroundColor($r('app.color.color_player_scrim'))
              .onClick(() => {
                this.toggleFav();
              })
              // 分享：与详情页同一个入口，但带上「当前这一集 + 播放中」的信息
              Stack({ alignContent: Alignment.Center }) {
                Image($r('app.media.ic_share'))
                  .width(20)
                  .height(20)
                  .fillColor($r('app.color.color_text'))
              }
              .width(34)
              .height(34)
              .borderRadius(17)
              .backgroundColor($r('app.color.color_player_scrim'))
              .onClick(() => {
                this.shareMovie();
              })
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
                // 横屏 -> 竖屏（退出全屏）；竖屏 -> 横屏（重新全屏）
                // 画面会随容器尺寸重新等比计算并居中，不会拉伸
                this.setLandscape(!this.landscape);
              })
            }
            .width('100%')
            // 横屏：贴屏幕物理顶边（留白会让画面顶部多出一块，看着不像全屏）。
            // 竖屏：进播放页同样会切窗口全屏（applyWindowFullScreen(true)），
            // 页面从 y=0 开始画，状态栏是透明浮在上面的 —— 这里必须让开
            // 一个状态栏的高度，否则片名和返回键直接压在时间/电量上。
            .padding({ left: 20, right: 20, top: this.topPadVp, bottom: 4 })
            // 方案 D：顶部操作栏同样是玻璃，但底色要压得比底部重 ——
            // 它压在最亮的画面上，纯玻璃会让白字糊掉；下沿圆角是为了
            // 让"这是一块玻璃"这件事在实机上一眼看得出来（通栏矩形太像旧版）。
            .backgroundColor('#66000000')
            .backgroundEffect({ radius: 20, saturation: 1.4 })
            .borderRadius({ bottomLeft: 22, bottomRight: 22 })

            // 这里只留空白撑高，把底部控制条顶到最下面。
            // 播放/暂停按钮不能留在这条 Column 里：竖屏时控制条会被抬到画面下方，
            // 靠 layoutWeight 居中的按钮会跟着被挤到画面上三分之一处。
            // 它现在挂在 Stack 上单独居中（见下面的「中部播放按钮」）。
            Blank()

            // 底部控制条
            // 进度条与功能按钮之间不再留 4vp 的气口：Slider 自身在 OutSet 样式下
            // 有一圈透明包围盒（轨道只在中间一条），再叠上 Column 间距，视觉上就有
            // 一条明显空档。这里把 Slider 的高度收到 24vp、间距收到 0，
            // 让「滑块 -> 按钮」贴到一起。
            Column({ space: 0 }) {
              Slider({
                value: this.sliderValue,
                min: 0,
                max: this.sliderMaxValue(),
                style: SliderStyle.OutSet
              })
                .width('100%')
                .blockColor($r('app.color.color_primary'))
                .selectedColor($r('app.color.color_primary'))
                .trackColor('#333333')
                // 控制条整体压扁一档：滑块瘦一圈、轨道细一点，画面少压一条
                .blockSize({ width: 14, height: 14 })
                .trackThickness(3)
                // 高度压到 24：OutSet 样式的滑块默认占 40vp，轨道居中后
                // 下方会空出约 13vp，和功能按钮之间显得空隙很大
                .height(24)
                .onChange((value: number, mode: SliderChangeMode) => {
                  this.onSliderChange(value, mode);
                })

              Row({ space: 8 }) {
                // 时间合成一条，把宽度留给右侧按钮（竖屏可用宽度只有 392vp）
                Text(this.timeLabel())
                  .fontSize(11)
                  .fontColor('#CCCCCC')
                  .maxLines(1)
                  .layoutWeight(1)
                Row({ space: 6 }) {
                  // 原来是无内边距的 12sp 纯文字，手指很难点中；
                  // 改成 34vp 高的胶囊按钮，点选区域和视觉层次都更清楚。
                  Text(this.speedLabel())
                    .fontSize(12)
                    .fontColor('#FFFFFF')
                    .backgroundColor('#26FFFFFF')
                    .borderRadius(14)
                    .height(28)
                    .padding({ left: 11, right: 11 })
                    .textAlign(TextAlign.Center)
                    .maxLines(1)
                    .onClick(() => {
                      this.showSpeeds = !this.showSpeeds;
                    })
                  if (this.episodes.length > 1) {
                    Text('选集')
                      .fontSize(12)
                      .fontColor('#FFFFFF')
                      .backgroundColor('#26FFFFFF')
                      .borderRadius(14)
                      .height(28)
                      .padding({ left: 11, right: 11 })
                      .textAlign(TextAlign.Center)
                      .maxLines(1)
                      .onClick(() => {
                        this.showEpisodes = !this.showEpisodes;
                      })
                  }
                  if (this.currentEp + 1 < this.episodes.length) {
                    Text('下一集')
                      .fontSize(12)
                      .fontColor('#FFFFFF')
                      .backgroundColor('#26FFFFFF')
                      .borderRadius(14)
                      .height(28)
                      .padding({ left: 11, right: 11 })
                      .textAlign(TextAlign.Center)
                      .maxLines(1)
                      .onClick(() => {
                        this.selectEpisode(this.currentEp + 1);
                      })
                  }
                  // 投屏：系统提供的投屏图标，点按拉起系统投屏设备列表
                  Row() {
                    AVCastPicker({
                      normalColor: '#FFFFFF',
                      activeColor: Color.White,
                      pickerStyle: AVCastPickerStyle.STYLE_MENU,
                      colorMode: AVCastPickerColorMode.AUTO,
                      sessionType: 'video'
                    })
                      .width(24)
                      .height(24)
                  }
                  .height(28)
                  .padding({ left: 5, right: 5 })
                  .backgroundColor('#26FFFFFF')
                  .borderRadius(14)
                  .justifyContent(FlexAlign.Center)

                  // 横屏/大屏下补一个「铺满屏/适应屏」切换：车机等大屏可去掉黑边最大化画面
                  if (this.canvasW > this.canvasH && this.offlineDir === '') {
                    Text(this.fitCover ? '适应屏' : '铺满屏')
                      .fontSize(12)
                      .fontColor('#FFFFFF')
                      .backgroundColor('#26FFFFFF')
                      .borderRadius(14)
                      .height(28)
                      .padding({ left: 11, right: 11 })
                      .textAlign(TextAlign.Center)
                      .maxLines(1)
                      .onClick(() => {
                        this.fitCover = !this.fitCover;
                        this.updateSurfaceSize();
                      })
                  }
                  if (this.offlineDir === '') {
                    Text('换源')
                      .fontSize(12)
                      .fontColor('#FFFFFF')
                      .backgroundColor('#26FFFFFF')
                      .borderRadius(14)
                      .height(28)
                      .padding({ left: 11, right: 11 })
                      .textAlign(TextAlign.Center)
                      .maxLines(1)
                      .onClick(() => {
                        this.runSpeedTest();
                      })
                  }
                }
                .justifyContent(FlexAlign.End)
              }
              .width('100%')
            }
            .width('100%')
            // bottom 只留 10：这块玻璃要一直铺到屏幕底边。
            // 早先 18 + 外层 22 = 40vp 的透明留白，底下露出页面黑底，
            // 看着就是"控制条浮在半空、下面还有一条安全区"。
            .padding({ left: 16, right: 16, top: 6, bottom: 8 })
            // 方案 D：播放页控制条用液态玻璃（薄材质 + 自动互补色 + 按压形变 + 光随指动）
            // 底色不能用 color_panel_glass：那是跟随主题的"浅玻璃"，深色主题下是 20% 白，
            // 压到画面上会把画面提亮，白字反而更糊。播放页永远压着视频，固定用深色底。
            // 竖屏（非全屏）时这块玻璃会被抬到画面下方，悬在黑底上 ——
            // 35% 黑在纯黑背景里等于隐形，所以换成一档浅一点的深灰；
            // 横屏画面铺满、控制条贴底，仍用原来那条压暗玻璃。
            .backgroundColor(this.landscape ? '#4D000000' : '#26FFFFFF')
            .backgroundEffect({ radius: 26, saturation: 1.5 })
            // 上沿大圆角：通栏色带在实机上和旧版的黑色压暗条几乎分不出来，
            // 圆角边界才能被眼睛抓到，玻璃块感才立得住。
            // 不画描边：这条玻璃已经贴到屏幕底边，四边描边会在下方多出一条
            // 横线（用户明确要求去掉），只靠圆角 + 亮度差表达边界。
            .borderRadius(this.barRadius())
            // 竖屏：抬起来当独立卡片 —— 左右留边、四角全圆、描边 + 投影托住
            .margin({
              left: this.landscape ? 0 : 12,
              right: this.landscape ? 0 : 12,
              bottom: this.playerBarLift()
            })
            .border({ width: this.landscape ? 0 : 1, color: '#1FFFFFFF' })
            .shadow({
              radius: this.landscape ? 0 : 22,
              color: this.landscape ? '#00000000' : '#66000000',
              offsetY: this.landscape ? 0 : 6
            })
            // 量一次自身高度：抬多高要用它反算（见 playerBarLift）
            .onAreaChange((oldArea: Area, newArea: Area) => {
              this.captureBarHeight(newArea);
            })
          }
          .width('100%')
          .height('100%')
          // 全屏播放：控制层铺满整屏，上下都不再留安全区留白。
          // 早先 top 26 / bottom 22 是为了避开状态栏和手势条，代价是顶部影片信息
          // 栏和底部控制条都"浮在离边一段距离的地方"，看着不像是全屏。
          .padding({ top: 0, bottom: 0 })
        }

        // 中部播放按钮：只在「已经起播过」时出现（加载阶段不该有三角，
        // 否则看着像没自动播放）。放在 Stack 上由 alignContent 居中，
        // 正好落在画面正中 —— 与底部控制条的位置解耦。
        if (this.controlsVisible && this.errorText === '' && this.hasStarted) {
          Stack({ alignContent: Alignment.Center }) {
            Image(this.playing ? $r('app.media.ic_player_pause') : $r('app.media.ic_player_play'))
              .width(30)
              .height(30)
              .fillColor($r('app.color.color_text'))
              .margin({ left: this.playing ? 0 : 4 })
          }
          .width(62)
          .height(62)
          .borderRadius(31)
          .backgroundColor($r('app.color.color_player_scrim'))
          .onClick(() => {
            this.togglePlay();
          })
        }

        // 滑屏调节的浮层提示（音量改由系统音量面板呈现，这里只留亮度）
        if (this.adjustKind === 'brightness') {
          Column({ space: 10 }) {
            Text('亮度')
              .fontSize(14)
              .fontColor(Color.White)
            Stack({ alignContent: Alignment.Start }) {
              Row()
                .width('100%')
                .height(4)
                .borderRadius(2)
                .backgroundColor('#4DFFFFFF')
              Row()
                .width(this.adjustValue * 140)
                .height(4)
                .borderRadius(2)
                .backgroundColor(Color.White)
            }
            .width(140)
            .height(4)
            Text(Math.round(this.adjustValue * 100).toString() + '%')
              .fontSize(13)
              .fontColor('#DDDDDD')
          }
          .padding({ left: 22, right: 22, top: 16, bottom: 16 })
          .borderRadius(14)
          .backgroundColor('#B3000000')
          // 浮层绝不参与命中测试：滑动时手指很可能压在它正上方，
          // 一旦吃掉事件，手势会当场中断 —— 表现为「动一下就停」。
          .hitTestBehavior(HitTestMode.None)
        }

        // 音量调节浮层：用系统 AVVolumePanel 才有权限改设备音量，
        // 只显示不拦截触摸（滑动手指还在屏幕上）
        if (this.adjustKind === 'volume') {
          Stack({ alignContent: Alignment.End }) {
            AVVolumePanel({ volumeLevel: this.volumeLevel })
          }
          .width('100%')
          .height('100%')
          .padding({ right: 12 })
          .hitTestBehavior(HitTestMode.None)
        }

        // 选集面板：贴底弹出，避免挡住画面中心
        if (this.showEpisodes) {
          Column() {
            Column({ space: 8 }) {
            Row() {
              Text('选集')
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.color_text'))
                .layoutWeight(1)
              Text('关闭')
                .fontSize(13)
                .fontColor($r('app.color.color_primary'))
                .onClick(() => {
                  this.showEpisodes = false;
                })
            }
            .width('100%')
            Grid() {
              ForEach(this.episodes, (ep: Episode) => {
                GridItem() {
                  Text(ep.name)
                    .fontSize(13)
                    .fontColor(this.epTextColor(ep))
                    .backgroundColor(this.epBgColor(ep))
                    .borderRadius(8)
                    .height(36)
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .maxLines(1)
                    .onClick(() => {
                      this.selectEpisode(ep.index);
                    })
                }
              }, (ep: Episode) => 'ep_' + ep.index.toString())
            }
            .columnsTemplate('1fr 1fr 1fr 1fr')
            .columnsGap(8)
            .rowsGap(8)
          }
            .width('100%')
            .height(260)
            .padding(16)
            .backgroundColor($r('app.color.color_card'))
            .borderRadius({ topLeft: 16, topRight: 16 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.End)
          // 自身不参与命中测试，视频的「点击唤出控制条」不会被挡住
          .hitTestBehavior(HitTestMode.None)
          .padding({ bottom: 18 })
        }

        // 倍速面板：贴底弹出
        if (this.showSpeeds) {
          Column() {
            Row({ space: 10 }) {
            ForEach(AvPlayerController.SPEEDS, (opt: PlaybackSpeedOption) => {
              Text(opt.label)
                .fontSize(13)
                .fontColor(this.speedTextColor(opt))
                .backgroundColor(this.speedBgColor(opt))
                .borderRadius(16)
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .onClick(() => {
                  this.selectSpeed(opt.value);
                })
            }, (opt: PlaybackSpeedOption) => opt.label)
          }
              .padding(10)
              .backgroundColor($r('app.color.color_card'))
              .borderRadius(20)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.End)
            .hitTestBehavior(HitTestMode.None)
            .padding({ bottom: 18 })
        }

        // 换源面板：右下角小浮层。
        // 横屏时面板若铺满整宽、水平居中，会把整部片子挡住；
        // 这里固定 264vp 宽、列表最多约 3 行滚动，贴在右下角，
        // 既能完成换源，又几乎不影响看画面。
        if (this.showSources) {
          Column() {
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Text('选择播放源')
                  .fontSize(12)
                  .fontColor($r('app.color.color_text_secondary'))
                  .layoutWeight(1)
                  .maxLines(1)
                Text('关闭')
                  .fontSize(11)
                  .fontColor($r('app.color.color_primary'))
                  .onClick(() => {
                    this.showSources = false;
                  })
              }
              .width('100%')

              if (this.speedTesting) {
                Row({ space: 8 }) {
                  LoadingProgress()
                    .width(18)
                    .height(18)
                    .color($r('app.color.color_primary'))
                  Text('正在测速…')
                    .fontSize(12)
                    .fontColor($r('app.color.color_text_secondary'))
                }
                .width('100%')
                .height(44)
                .justifyContent(FlexAlign.Center)
              } else if (this.speedItems.length === 0) {
                Text('没有其他可用源')
                  .fontSize(12)
                  .fontColor($r('app.color.color_text_secondary'))
                  .width('100%')
                  .height(34)
                  .textAlign(TextAlign.Center)
              } else {
                List({ space: 4 }) {
                  ForEach(this.speedItems, (item: SpeedTestItem) => {
                    ListItem() {
                      Row({ space: 8 }) {
                        Text(item.sourceName)
                          .fontSize(12)
                          .fontColor($r('app.color.color_text'))
                          .layoutWeight(1)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        if (item.ok) {
                          Text(item.latencyMs + 'ms')
                            .fontSize(11)
                            .fontColor($r('app.color.color_success'))
                        } else {
                          Text('不可用')
                            .fontSize(11)
                            .fontColor($r('app.color.color_warning'))
                        }
                      }
                      .width('100%')
                      .padding({ left: 8, right: 8, top: 7, bottom: 7 })
                      .backgroundColor($r('app.color.color_chip_bg'))
                      .borderRadius(6)
                      .onClick(() => {
                        this.switchSource(item);
                      })
                    }
                  }, (item: SpeedTestItem) => item.sourceKey)
                }
                .width('100%')
                // 最多约 3 条，再多就滚动 —— 面板要保持"小"
                .constraintSize({ maxHeight: 150 })
                .scrollBar(BarState.Off)
              }
            }
            .width(264)
            .padding(10)
            .backgroundColor($r('app.color.color_card'))
            .borderRadius(12)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.End)
          .alignItems(HorizontalAlign.End)
          // 自身不参与命中测试，别挡住视频的「点击唤出控制条」
          .hitTestBehavior(HitTestMode.None)
          .padding({ right: 16, bottom: 16 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      // 记录播放器可视区尺寸：横竖屏切换、分屏、折叠屏都会触发，
      // 每次变化都按视频原始比例重新算一次画面尺寸，保证始终等比且居中。
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const w: number = this.areaNumber(newValue.width);
        const h: number = this.areaNumber(newValue.height);
        if (w > 0 && h > 0 && (w !== this.canvasW || h !== this.canvasH)) {
          this.canvasW = w;
          this.canvasH = h;
          // 切回竖屏必须退出「铺满」：16:9 的流铺进竖屏会被裁到只剩中间一条，
          // 而竖屏下「铺满屏」按钮是隐藏的，用户没有退路。
          if (this.fitCover && w <= h) {
            this.fitCover = false;
          }
          this.updateSurfaceSize();
        }
      })
      // 上下滑调音量 / 亮度：左半屏音量、右半屏亮度，往上滑变大。
      // 挂在根容器上而不是点击层：控制条显示时它铺满全屏，
      // 挂在点击层会被它挡住（Slider / 按钮自己有手势，仍然优先响应）。
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.Vertical })
          .onActionStart((event: GestureEvent) => {
            const fingers = event.fingerList;
            if (fingers.length > 0) {
              // globalX 是相对窗口的，最贴近「屏幕左右半边」的直觉；
              // 取不到（贴左边 = 0）时退回 localX。
              const x: number = fingers[0].globalX > 0 ? fingers[0].globalX : fingers[0].localX;
              this.beginAdjust(x);
            }
          })
          .onActionUpdate((event: GestureEvent) => {
            this.updateAdjust(event.offsetY);
          })
          .onActionEnd(() => {
            this.endAdjust();
          })
      )
    }
    .hideTitleBar(true)
    .hideBackButton(true)
    .onShown(() => {
      this.onPageShown();
      this.syncTopPad();
    })
    .onBackPressed(() => {
      this.back();
      return true;
    })
  }

  private clearBgTimer(): void {
    if (this.bgTimer >= 0) {
      clearTimeout(this.bgTimer);
      this.bgTimer = -1;
    }
  }

  /**
   * 初始化画中画控制器。
   *
   * 时机：XComponent 的 onLoad 之后（Surface 已经存在）才能 create，
   * 否则 componentController 拿不到有效 Surface，小窗是黑的。
   *
   * 核心是 setAutoStartEnabled(true)：主窗退到后台（回桌面、开别的 App）时
   * 系统自动把画面接进画中画小窗。不开这一项，画面被挂到后台、声音照放 ——
   * 正是用户反馈的现象。
   */
  private async initPiP(): Promise<void> {
    if (this.pipController !== null || this.pipCreating || this.pipUnsupported || this.released) {
      return;
    }
    if (!PiPWindow.isPiPEnabled()) {
      // 系统「设置 → 系统 → 智慧多窗 → 自动启动画中画」关着，或设备不支持
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
        // 必须与 IndexPage 里 Navigation 的 id 完全一致：
        // 系统靠它缓存栈顶信息，从画中画恢复时才回得到播放页而不是首页
        navigationId: NavIds.MAIN,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
        // 单位是 px，必须是大于 0 的整数；未知时先按 16:9 给个基准
        contentWidth: this.videoW > 0 ? this.videoW : 1920,
        contentHeight: this.videoH > 0 ? this.videoH : 1080
      };
      const controller: PiPWindow.PiPController = await PiPWindow.create(config);
      if (this.released) {
        controller.stopPiP().catch(() => {
          // 已释放，停不掉也无所谓
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
      // 401 参数错误 / 801 设备不支持：降级为「不进画中画」，
      // 不弹窗打扰用户；但要留一条日志，否则排查时完全无从下手
      console.warn('[pip] create failed: ' + JSON.stringify(e));
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
      // 小窗里不该再盖着一层控制条 / 长按浮层
      this.controlsVisible = false;
      this.clearPressTimer();
      this.pressSpeed = false;
      this.seekPreviewing = false;
      return;
    }
    if (state === PiPWindow.PiPState.ABOUT_TO_STOP) {
      this.pressSpeed = false;
      this.seekPreviewing = false;
      // 记住「停小窗之前是不是在播」：系统会在停窗过程中把播放器暂停，
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
        // 本页为了让画面收回全屏而叫停的，不是用户要关小窗：绝不能暂停，
        // 否则回到全屏画面是停住的，还得再点一次播放。
        this.resumeAfterPiPRestore();
        return;
      }
      if (reason === 'panelActionRestore') {
        // 用户点了小窗上的「全屏 / 恢复」按钮：应用已被拉回前台，接着播
        this.resumeAfterPiPRestore();
        return;
      }
      // reason 只有新系统才给真实值（旧版本恒为 '0'，此时不动，避免误停播）。
      // 这三种都是「用户主动关掉小窗」，必须暂停 —— 否则声音会一直在后台响。
      if (reason === 'panelActionDelete' || reason === 'dragDelete' || reason === 'requestDelete') {
        this.pipWasPlaying = false;
        this.player.pause();
        this.saveProgress();
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
    // 不看 status：各版本对它的语义（当前状态 / 目标动作）不一致。
    // 直接按播放器真实状态取反，行为一定是对的。
    if (this.player.isPlaying()) {
      this.player.pause();
    } else {
      this.player.play();
    }
  }

  /** 把小窗里的播放/暂停按钮状态跟实际播放状态对齐 */
  private syncPiPControl(playing: boolean): void {
    const c = this.pipController;
    if (c === null) {
      return;
    }
    try {
      // status 表示「这个按钮接下来会做什么」：正在播就显示成暂停按钮
      c.updatePiPControlStatus(PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
        playing ? PiPWindow.PiPControlStatus.PAUSE : PiPWindow.PiPControlStatus.PLAY);
    } catch (e) {
      // 非画中画态调用会抛错，忽略
    }
  }

  /**
   * 回到桌面 / 打开其他 App。
   * 画中画由系统异步拉起，onBackground 先到、小窗随后才出现，所以先给 1.2 秒宽限；
   * 到点还没有小窗，说明这台设备或系统开关不支持，那就必须自己暂停 ——
   * 否则声音会在后台一直响下去（用户最初报的就是这个）。
   */
  private handleAppBackground(background: boolean): void {
    this.clearBgTimer();
    if (this.released) {
      return;
    }
    if (!background) {
      // 回到前台。此时小窗还挂着，说明用户是点应用图标进来的 ——
      // 他要的是接着全屏看，不是继续缩在角落。主动关掉小窗，画面收回本页。
      this.restoreFromPiP();
      return;
    }
    this.bgTimer = setTimeout(() => {
      this.bgTimer = -1;
      if (this.released || !AppLifecycle.isBackground() || this.pipActive) {
        return;
      }
      this.player.pause();
      this.saveProgress();
    }, 1200);
  }

  /**
   * 从画中画收回页面（应用回到前台时调用）。
   * 关掉小窗后画面会重新挂回本页的 XComponent，走 onSurfaceReady 的「重建」分支，
   * 只换 Surface 不重建播放器 —— 进度和播放状态都不丢。
   */
  private restoreFromPiP(): void {
    if (!this.pipActive) {
      return;
    }
    const c = this.pipController;
    if (c === null) {
      return;
    }
    // 先置位，避免 stateChange 回来之前又触发一次 stopPiP
    this.pipActive = false;
    // 停窗前先记住是不是在播：系统会在停窗过程中暂停播放器，之后再读就晚了
    this.pipWasPlaying = this.player.isPlaying();
    // 打上「是自己叫停」的标记 —— 否则系统回报的 requestDelete 会被当成
    // 「用户关掉了小窗」，恢复全屏时直接暂停（本函数的调用方正是回前台）
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


  private clearPressTimer(): void {
    if (this.pressTimer >= 0) {
      clearTimeout(this.pressTimer);
      this.pressTimer = -1;
    }
  }

  /**
   * 长按加速 + 长按后左右滑快进/快退。
   *
   * 为什么手写 onTouch 而不用 LongPressGesture + PanGesture：
   * 长按识别成功之后，同一根手指再起 Pan 在 ArkUI 里并不可靠（手势流已被长按吃掉）；
   * 而 GestureGroup 的 parallel 模式又会让「上下滑调音量/亮度」被误判成横滑。
   * 自己算时序最稳：按住 380ms 进加速 → 之后横移换算成跳转量 → 抬手才真正 seek。
   */
  private handlePressTouch(event: TouchEvent): void {
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.endPress();
      return;
    }
    const touches = event.touches;
    if (touches.length === 0) {
      return;
    }
    const x: number = touches[0].x;
    const y: number = touches[0].y;
    if (event.type === TouchType.Down) {
      // 控制条可见时不接管：按钮和进度条就压在画面上，抢事件会让它们点不动
      if (this.controlsVisible || this.errorText !== '') {
        return;
      }
      this.clearPressTimer();
      this.pressDownX = x;
      this.pressDownY = y;
      this.suppressTap = false;
      this.pressTimer = setTimeout(() => {
        this.pressTimer = -1;
        if (this.released) {
          return;
        }
        this.pressSpeed = true;
        this.seekDragging = false;
        this.seekPreviewing = false;
        this.seekBaseMs = this.player.currentTime();
        this.seekPreviewMs = this.seekBaseMs;
        this.seekDeltaMs = 0;
        // 暂停态改速度会被播放器拒绝；恢复播放时会按 speedValue 重新应用
        if (this.playing) {
          this.player.setSpeed(PlayerPage.PRESS_SPEED);
        }
      }, PlayerPage.PRESS_DELAY_MS);
      return;
    }
    // 剩下的是 Move
    if (this.pressTimer >= 0) {
      // 还没到长按时长就动了：让位给上下滑调音量/亮度
      if (Math.abs(x - this.pressDownX) > 12 || Math.abs(y - this.pressDownY) > 12) {
        this.clearPressTimer();
      }
      return;
    }
    if (!this.pressSpeed) {
      return;
    }
    const dx: number = x - this.pressDownX;
    if (Math.abs(dx) < 16) {
      return;
    }
    this.seekDragging = true;
    const width: number = this.canvasW > 0 ? this.canvasW : 640;
    let target: number = this.seekBaseMs + (dx / width) * PlayerPage.SEEK_FULL_SPAN_MS;
    if (target < 0) {
      target = 0;
    }
    if (this.durationMs > 0 && target > this.durationMs) {
      target = this.durationMs;
    }
    this.seekPreviewMs = target;
    this.seekDeltaMs = target - this.seekBaseMs;
    this.seekPreviewing = true;
  }

  /** 抬手：恢复用户自己选的倍速；发生过横移才真正跳转 */
  private endPress(): void {
    this.clearPressTimer();
    if (!this.pressSpeed) {
      return;
    }
    const target: number = this.seekPreviewMs;
    const jumped: boolean = this.seekDragging && this.seekPreviewing;
    this.pressSpeed = false;
    this.seekDragging = false;
    this.seekPreviewing = false;
    this.suppressTap = jumped;
    // 恢复到设置里选的倍速（不一定是 1.0）
    this.player.setSpeed(this.speedValue);
    if (jumped) {
      this.player.seekTo(target);
      this.applySeekUi(target);
    }
  }

  private pressSpeedLabel(): string {
    return PlayerPage.PRESS_SPEED.toFixed(1) + 'x 加速中';
  }

  private seekDeltaText(): string {
    const d: number = this.seekDeltaMs;
    const abs: string = Utils.formatTime(Math.abs(d));
    return d >= 0 ? '快进 +' + abs : '快退 -' + abs;
  }

  private infoSourceName(): string {
    const source = SourceManager.shared().getVodSource(this.sourceKey);
    if (source === null) {
      return '';
    }
    return source.name;
  }

  private titleLabel(): string {
    if (this.title !== '') {
      return this.title;
    }
    return '播放中';
  }

  private sliderMaxValue(): number {
    if (this.sliderMax > 0) {
      return this.sliderMax;
    }
    return 100;
  }

  private epTextColor(ep: Episode): ResourceColor {
    if (ep.index === this.currentEp) {
      return Color.White;
    }
    return $r('app.color.color_text');
  }

  private epBgColor(ep: Episode): ResourceColor {
    if (ep.index === this.currentEp) {
      return $r('app.color.color_primary');
    }
    return $r('app.color.color_chip_bg');
  }

  private speedTextColor(opt: PlaybackSpeedOption): ResourceColor {
    if (opt.value === this.speedValue) {
      return Color.White;
    }
    return $r('app.color.color_text');
  }

  private speedBgColor(opt: PlaybackSpeedOption): ResourceColor {
    if (opt.value === this.speedValue) {
      return $r('app.color.color_primary');
    }
    return $r('app.color.color_chip_bg');
  }

  private timeLabel(): string {
    // 这个页面只放点播；时长要等 AVPlayer 报上来才准，那之前显示占位符，
    // 不要写「直播」——起播瞬间看到「01:07 / 直播」很容易误判成播错了源。
    const total: string = this.durationMs > 0 ? this.durationText : '--:--';
    return this.positionText + ' / ' + total;
  }

  private speedLabel(): string {
    for (const opt of AvPlayerController.SPEEDS) {
      if (opt.value === this.speedValue) {
        return '倍速 ' + opt.label;
      }
    }
    return '倍速 1.0x';
  }
}
