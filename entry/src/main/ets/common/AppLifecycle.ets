/**
 * 应用前后台状态。
 *
 * 为什么需要它：播放页要判断「现在是真的回桌面了，还是画中画已经接管了画面」。
 * 画中画由系统异步拉起（onBackground 先到、画中画随后才起来），
 * 所以播放页那边还要配一段宽限时间 —— 见 PlayerPage.handleAppBackground。
 *
 * 只保留一个回调字段而不是监听者数组：ArkTS 里把成员方法当回调传出去会丢 this，
 * 而每次现建一个箭头函数又无法反注册（页面反复进出会让数组无限增长）。
 * 真正关心前后台的只有播放页，一个槽位够用，用完置空即可。
 */
export class AppLifecycle {
  private static bg: boolean = false;

  /** 当前关心前后台变化的页面挂的回调（播放页），离开时置空 */
  static bgHandler: (background: boolean) => void = () => {};

  static isBackground(): boolean {
    return AppLifecycle.bg;
  }

  static setBackground(value: boolean): void {
    if (AppLifecycle.bg === value) {
      return;
    }
    AppLifecycle.bg = value;
    try {
      AppLifecycle.bgHandler(value);
    } catch (e) {
      // 回调里的异常不该影响生命周期流程
    }
  }
}
