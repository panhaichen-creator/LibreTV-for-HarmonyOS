/**
 * 屏幕常亮管理（计数制）。
 *
 * 两类场景需要常亮：
 * 1. 下载期间 —— 设备自动休眠后应用线程被冻结，正在跑的 HttpRequest 回调
 *    不再回来，下载任务停在某个分片号上不动（acquire/release，DownloadManager 用）；
 * 2. 播放页存活期间 —— 平板全屏播放时系统休眠计时一到会直接黑屏锁屏
 *    （acquirePlayback/releasePlayback，PlayerPage / LivePlayerPage 用）。
 *
 * 这里只做一层很薄的桥：EntryAbility 把「真正去设置窗口属性」的
 * 函数注入进来，两个模块不用互相 import。计数制保证两类需求互不覆盖：
 * 播放页退出时不会把下载的常亮关掉，反之亦然。
 */
export class ScreenKeeper {
  private static apply: ((on: boolean) => void) | null = null;
  private static wanted: boolean = false;
  /** 下载计数 */
  private static count: number = 0;
  /** 播放页计数 */
  private static playCount: number = 0;

  /** 由 EntryAbility 在窗口创建后注入 */
  static bind(fn: (on: boolean) => void): void {
    ScreenKeeper.apply = fn;
    const a = ScreenKeeper.apply;
    if (a !== null) {
      a(ScreenKeeper.wanted);
    }
  }

  /** 有下载开始 */
  static acquire(): void {
    ScreenKeeper.count = ScreenKeeper.count + 1;
    ScreenKeeper.refresh();
  }

  /** 有下载结束（含失败/取消） */
  static release(): void {
    ScreenKeeper.count = ScreenKeeper.count > 0 ? ScreenKeeper.count - 1 : 0;
    ScreenKeeper.refresh();
  }

  /** 播放页进入（aboutToAppear） */
  static acquirePlayback(): void {
    ScreenKeeper.playCount = ScreenKeeper.playCount + 1;
    ScreenKeeper.refresh();
  }

  /** 播放页离开（aboutToDisappear） */
  static releasePlayback(): void {
    ScreenKeeper.playCount = ScreenKeeper.playCount > 0 ? ScreenKeeper.playCount - 1 : 0;
    ScreenKeeper.refresh();
  }

  private static refresh(): void {
    ScreenKeeper.set(ScreenKeeper.count > 0 || ScreenKeeper.playCount > 0);
  }

  private static set(on: boolean): void {
    ScreenKeeper.wanted = on;
    const a = ScreenKeeper.apply;
    if (a !== null) {
      a(on);
    }
  }
}
