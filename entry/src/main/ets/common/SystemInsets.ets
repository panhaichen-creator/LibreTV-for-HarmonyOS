/**
 * 系统栏占位尺寸（vp）。
 *
 * 为什么要有这个东西：
 * 应用要让内容「铺满整屏 + 顶部/底部安全区用模糊过渡」，状态栏和手势条那两条
 * 就必须由页面自己让位 —— 框架只保证窗口本身是全屏的，具体让多少得问系统。
 * EntryAbility 在窗口创建后把实测值写进来，页面读它来做内边距，
 * 避免每个页面各写一个魔数（换机器/换分辨率立刻错位）。
 *
 * 注意：这是普通静态字段而不是 @State —— 它在首帧之前就已经写好，
 * 页面读取时不需要响应式更新；写成状态反而会在启动阶段触发一次无谓重排。
 */
import { display, window } from '@kit.ArkUI';

export class SystemInsets {
  /** 状态栏高度（vp）。取不到时给一个保守值，宁可多留一点也不压字 */
  private static topVp: number = 38;
  /** 底部手势条高度（vp）。默认按常见值给 28，量不到时也不至于把胶囊压进手势区 */
  private static bottomVp: number = 28;

  /**
   * 写入实测值。只接受「合理区间」内的数字：
   * 窗口刚创建时 avoidArea 可能返回 0 或半个值（实测出现过 8vp），
   * 照单全收会把搜索栏顶进状态栏里，比不更新更糟。
   */
  static set(topVp: number, bottomVp: number): void {
    if (topVp >= 20 && topVp <= 80) {
      SystemInsets.topVp = topVp;
    }
    if (bottomVp >= 8 && bottomVp <= 60) {
      SystemInsets.bottomVp = bottomVp;
    }
  }

  static top(): number {
    return SystemInsets.topVp;
  }

  /**
   * 量一次「状态栏占了多少 vp」。
   *
   * 返回 -1 表示取不到窗口或密度（调用方应保持原值，别拿坏值冲掉已知的正确值）；
   * 返回 0 是**有效值**——横屏全屏时系统会把状态栏收起来，此时顶部栏贴边即可。
   *
   * 为什么不能只用 set() 的那套：set() 会把 20 以下的数当成「量坏了」丢掉，
   * 于是横屏的 0 永远写不进去，页面只能靠 landscape 分支猜。
   */
  static measureTopVp(win: window.Window | null): number {
    if (win === null) {
      return -1;
    }
    try {
      const density: number = display.getDefaultDisplaySync().densityPixels;
      if (density <= 0) {
        return -1;
      }
      const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      return area.topRect.height / density;
    } catch (e) {
      return -1;
    }
  }

  static bottom(): number {
    return SystemInsets.bottomVp;
  }
}
