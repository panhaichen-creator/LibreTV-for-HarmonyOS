/**
 * 应用入口：初始化本地存储、源管理与下载管理器
 */

import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Store } from '../data/Store';
import { SourceManager } from '../data/SourceManager';
import { DownloadManager } from '../data/DownloadManager';
import { SettingsStore } from '../data/SettingsStore';
import { ScreenKeeper } from '../common/ScreenKeeper';
import { DevicePolicy } from '../common/DevicePolicy';
import { AppLifecycle } from '../common/AppLifecycle';
import { SystemInsets } from '../common/SystemInsets';
import { DeepLink, ShareLink } from '../common/ShareLink';

export default class EntryAbility extends UIAbility {
  /** 主窗口句柄：状态栏着色 / 主题切换后重涂都靠它 */
  private win: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0001, 'LibreTV', 'EntryAbility onCreate');
    Store.shared().init(this.context);
    // 冷启动可能正是被分享链接拉起来的：先收下，等首页挂载后由 DeepLink 补发
    this.handleSharedLink(want);
    // 预热各单例，避免首屏读取竞态
    SourceManager.shared().load();
    DownloadManager.shared().init(this.context);
    // 应用主题：跟随系统 / 固定浅色 / 固定深色
    const mode = SettingsStore.shared().get().themeMode;
    try {
      if (mode === 'light') {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (mode === 'dark') {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    } catch (e) {
      hilog.error(0x0001, 'LibreTV', 'setColorMode failed');
    }
  }

  /**
   * 应用已在后台时点开分享链接：走 onNewWant（onCreate 不会再跑）。
   * 冷启动那条走 onCreate —— 那里页面还没挂载，DeepLink 会先存着，
   * 等 IndexPage 就位再补发。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleSharedLink(want);
  }

  /** 从 want.uri 里取分享链接；不是本应用的链接直接忽略 */
  private handleSharedLink(want: Want): void {
    const uri: string = want.uri !== undefined ? want.uri : '';
    if (uri === '' || ShareLink.parse(uri) === null) {
      return;
    }
    hilog.info(0x0001, 'LibreTV', 'shared link received');
    DeepLink.push(uri);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0001, 'LibreTV', 'onWindowStageCreate');
    // 开启窗口全屏布局（沉浸式）。
    //
    // 历史坑：早先只开窗口全屏、却不控制 Navigation 的安全区行为，框架会把
    // Navigation 主内容下移到 y=133，而 push 出来的 NavDestination 从 y=0 排，
    // 两套坐标系打架，子页标题栏必然压到状态栏上。
    // 解法不是关掉全屏（那样内容永远进不了状态栏），而是让 Navigation 明确
    // 「忽略安全区」（见 IndexPage 里的 ignoreLayoutSafeArea），
    // 然后由页面自己用 SystemInsets 让位 —— 坐标系统一，内容也真的铺到屏幕边缘。
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      // 旋转策略：普通手机锁竖屏，平板/折叠机/宽屏跟随系统（播放页可临时接管）
      DevicePolicy.bind(win);
      win.setWindowLayoutFullScreen(true).catch((e: BusinessError) => {
        hilog.error(0x0001, 'LibreTV', 'setWindowLayoutFullScreen failed: %{public}s',
          e.message ?? 'unknown');
      });
      // 状态栏 / 窗口底色着色。
      // 关键：不要用 themeMode 字符串或 config.colorMode 枚举判断深浅 ——
      //   · themeMode='system' 时 themeMode 本身不等于 'light'，会误判成深色；
      //   · onCreate 里 setColorMode(COLOR_MODE_NOT_SET) 之后，context.config.colorMode
      //     返回的正是 NOT_SET（既不等于 LIGHT 也不等于 DARK），同样会误判成深色 ——
      //     这就是「浅色主题下状态栏还是黑的」的根因。
      // 改为直接读当前配置下 color_bg_top 的「真实 RGB」，按亮度判深浅：
      // 资源管理器给出的就是这个主题实际渲染的颜色，深浅永远不会判反。
      this.win = win;
      this.measureInsets();
      this.applySystemBars();
      // 下载期间保持常亮：休眠会冻结应用线程，下载链路直接断在半路
      ScreenKeeper.bind((on: boolean) => {
        win.setWindowKeepScreenOn(on).catch(() => {});
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0001, 'LibreTV', 'getMainWindowSync failed: %{public}s', err.message ?? 'unknown');
    }
    windowStage.loadContent('pages/IndexPage', (err) => {
      if (err) {
        // 实测这里会回一个空 message 的错误码，但页面内容其实已经正常挂载，
        // 所以不能 return —— 否则沉浸式那段永远不执行，状态栏那一条永远是窗口底色。
        hilog.error(0x0001, 'LibreTV', 'loadContent err code=%{public}d msg=%{public}s',
          err.code, err.message ?? '');
      }
      // 关键：窗口全屏布局必须在 loadContent **之后**再设一次。
      // 在 loadContent 之前设会被内容加载流程覆盖 —— 现象是布局树里页面 root
      // 从 y=133（状态栏高度）开始，状态栏那一条永远只显示窗口底色，
      // 滚动内容怎么都进不去。
      this.enterImmersive();
    });
  }

  /**
   * 判断当前是否深色主题 —— 直接读真实颜色，不看任何枚举/字符串。
   *
   * 为什么不能用 themeMode 或 config.colorMode：
   *   · themeMode='system' 时字符串是 'system'，`!== 'light'` 会误判深色；
   *   · setColorMode(COLOR_MODE_NOT_SET) 后 config.colorMode 返回 NOT_SET，也会误判深色。
   * 这里取 color_bg_top 在当前配置下解析出的 ARGB，按感知亮度分界（128）。
   * 浅色 #DCE3F1 → 亮度≈226（>128，判浅色）；深色 #191922 → 亮度≈26（<128，判深色）。
   */
  /**
   * 量一次状态栏 / 手势条高度，写进 SystemInsets 给页面用。
   * 单位换算用 display 的 densityPixels，而不是已废弃的全局 px2vp()。
   */
  /**
   * 打开沉浸式：全屏布局 -> 重新量安全区 -> 重涂状态栏 -> 打一行诊断。
   * 之所以能重复调用：全屏布局被内容加载覆盖后，只有再设一次才真正生效。
   */
  private enterImmersive(): void {
    const win = this.win;
    if (win === null) {
      return;
    }
    win.setWindowLayoutFullScreen(true).then(() => {
      this.measureInsets();
      this.applySystemBars();
      this.logWindowState();
    }).catch((e: BusinessError) => {
      hilog.error(0x0001, 'LibreTV', 'setWindowLayoutFullScreen failed: %{public}s', e.message ?? 'x');
    });
  }

  /** 诊断：全屏布局标志 + 状态栏/手势条实际高度（px），排查沉浸式失效用 */
  private logWindowState(): void {
    const win = this.win;
    if (win === null) {
      return;
    }
    try {
      const full: boolean = win.getWindowProperties().isLayoutFullScreen;
      const sysTop: number = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
      const navBottom: number =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
      hilog.info(0x0001, 'LibreTV', 'layoutFull=%{public}d sysTopPx=%{public}d indPx=%{public}d',
        full ? 1 : 0, sysTop, navBottom);
    } catch (e) {
      hilog.error(0x0001, 'LibreTV', 'logWindowState failed');
    }
  }

  private measureInsets(): void {
    const win = this.win;
    if (win === null) {
      return;
    }
    try {
      const density: number = display.getDefaultDisplaySync().densityPixels;
      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicator: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const topVp: number = density > 0 ? sys.topRect.height / density : 0;
      const bottomVp: number = density > 0 ? indicator.bottomRect.height / density : 0;
      SystemInsets.set(topVp, bottomVp);
      hilog.info(0x0001, 'LibreTV', 'insets top=%{public}d bottom=%{public}d',
        Math.round(topVp), Math.round(bottomVp));
    } catch (e) {
      hilog.error(0x0001, 'LibreTV', 'measureInsets failed');
    }
  }

  private computeIsDark(): boolean {
    try {
      const argb: number = this.context.resourceManager.getColorByNameSync('color_bg_top');
      const r: number = (argb >>> 16) & 0xFF;
      const g: number = (argb >>> 8) & 0xFF;
      const b: number = argb & 0xFF;
      const lum: number = 0.299 * r + 0.587 * g + 0.114 * b;
      return lum < 128;
    } catch (e) {
      // 资源读不到时退化为「只有明确设成 dark 才算深色」
      return SettingsStore.shared().get().themeMode === 'dark';
    }
  }

  /**
   * 按当前实际主题给状态栏 / 窗口底边着色。
   *
   * 为什么状态栏要涂成颜色而不是透明：窗口没开全屏布局
   * （setWindowLayoutFullScreen(false)），内容从安全区下沿（y≈133）才开始画，
   * expandSafeArea 也画不进状态栏那一条 —— 透明状态栏透出的是窗口底色，
   * 与页面渐变之间会有一道硬割裂。直接把状态栏涂成渐变顶部色即可融为一体。
   */
  private applySystemBars(): void {
    const win = this.win;
    if (win === null) {
      return;
    }
    const isDark: boolean = this.computeIsDark();
    win.setWindowSystemBarProperties({
      // 透明：内容已经铺到状态栏背后，再用一层模糊+渐变收边，
      // 涂成实色就等于把内容盖死了。
      statusBarColor: '#00000000',
      statusBarContentColor: isDark ? '#FFFFFF' : '#1A1A1E',
      navigationBarColor: '#00000000',
      navigationBarContentColor: isDark ? '#FFFFFF' : '#1A1A1E'
    }).catch((e: BusinessError) => {
      hilog.error(0x0001, 'LibreTV', 'setWindowSystemBarProperties failed: %{public}s',
        e.message ?? 'unknown');
    });
    // 窗口背景同步成渐变顶部色：内容未覆盖到的边角（分屏、过渡动画）不会闪黑。
    try {
      win.setWindowBackgroundColor(isDark ? '#191922' : '#DCE3F1');
    } catch (e) {
      hilog.error(0x0001, 'LibreTV', 'setWindowBackgroundColor failed');
    }
  }

  /**
   * 系统深浅色切换、或用户在「设置」里改了主题后，重涂一次状态栏。
   * 少了这一步，应用在前台时切主题不会被感知 —— 状态栏颜色会停在旧值上。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    this.applySystemBars();
  }

  onForeground(): void {
    AppLifecycle.setBackground(false);
    // 回到前台立刻重挂中断的下载。
    // 后台期间系统会冻结应用线程，HttpRequest 的回调可能再也回不来；
    // 只靠 60s 看门狗太慢，用户看到的就是「进度条一直不动」。
    // 已经在跑的任务会被 active 标记挡掉，重复调用无副作用。
    DownloadManager.shared().resumeInterrupted();
  }

  onBackground(): void {
    // 播放页用它决定「要不要自己停住」：画中画能接管就继续播，接管不了就得暂停，
    // 否则声音会在后台一直响（用户最初报的就是这个现象）。
    AppLifecycle.setBackground(true);
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0001, 'LibreTV', 'onWindowStageDestroy');
  }
}
