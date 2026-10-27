/**
 * 旋转策略（APP 需求：手机端不跟随设备旋转）：
 * - 折叠机（display.isFoldable）与宽屏设备（短边 >= 600vp，平板/阔直板）跟随系统旋转；
 * - 普通直板手机锁定竖屏。
 * 策略落在主窗口 preferredOrientation 上；播放页全屏期间会显式接管方向，
 * 此时置 suppressed 挂起自动纠正，避免 windowSizeChange 与播放页互相抢方向。
 */

import { display, window } from '@kit.ArkUI';

export class DevicePolicy {
  /** 宽屏阈值：短边 ≥ 600vp 视为平板/阔直板（平板实测约 672vp，手机约 360-420vp） */
  static readonly WIDE_MIN_VP: number = 600;
  private static bound: boolean = false;
  private static win: window.Window | null = null;
  /** 播放页全屏期间为 true：窗口尺寸变化不再自动纠正方向 */
  static suppressed: boolean = false;

  static bind(win: window.Window): void {
    if (DevicePolicy.bound) {
      return;
    }
    DevicePolicy.bound = true;
    DevicePolicy.win = win;
    DevicePolicy.applyDefault();
    // 折叠机展开/合上、分屏拖动都会触发 windowSizeChange，顺带重估形态
    win.on('windowSizeChange', () => {
      if (!DevicePolicy.suppressed) {
        DevicePolicy.applyDefault();
      }
    });
    try {
      display.on('foldStatusChange', () => {
        if (!DevicePolicy.suppressed) {
          DevicePolicy.applyDefault();
        }
      });
    } catch (e) {
      // 个别设备不支持折叠监听，忽略
    }
  }

  /**
   * 关掉「布局全屏」，让内容重新避开状态栏与底部导航条。
   *
   * 这里用缓存的主窗口对象，**不依赖 UIContext** —— 播放页销毁阶段
   * getUIContext() 可能已经拿不到，那条路一走空，窗口就一直停在全屏布局：
   * 回到主界面表现为「顶部压到状态栏底下、底部导航贴着屏幕边」，像被拉长了一样。
   */
  static restoreLayout(): void {
    const win = DevicePolicy.win;
    if (win === null) {
      return;
    }
    try {
      // 全应用都是沉浸式布局，这里「恢复」的应该是全屏，而不是退出全屏 ——
      // 早先写成 false，从播放页返回后主界面会突然退回安全区内，整页被下移 133px。
      win.setWindowLayoutFullScreen(true).catch(() => {
        // 个别系统版本/分屏场景会拒绝，忽略
      });
    } catch (e) {
      // ignore
    }
  }

  /** 按当前设备形态应用默认方向：宽设备跟随旋转，普通手机锁竖屏 */
  static applyDefault(): void {
    const win = DevicePolicy.win;
    if (win === null) {
      return;
    }
    const target = DevicePolicy.isWideDevice()
      ? window.Orientation.AUTO_ROTATION : window.Orientation.PORTRAIT;
    try {
      if (win.getPreferredOrientation() !== target) {
        win.setPreferredOrientation(target);
      }
    } catch (e) {
      // ignore
    }
  }

  /**
   * 是否按「宽屏」对待。
   * 关键：必须看**主窗口的实际尺寸**，而不是手机物理屏 ——
   * 超级桌面/车机给应用分配的是虚拟窗口（可能是 1920x1080 的横屏窗口），
   * 而手机物理屏仍是竖屏；按物理屏判断会把方向锁死为竖屏，
   * 车机上就渲染成一块手机比例的小窗（本次反馈的现象）。
   */
  /** 主窗口（EntryAbility 启动时 bind 进来）。量安全区、改方向都靠它 */
  static currentWindow(): window.Window | null {
    return DevicePolicy.win;
  }

  static isWideDevice(): boolean {
    try {
      if (display.isFoldable()) {
        return true;
      }
    } catch (e) {
      // ignore
    }
    let wPx = 0;
    let hPx = 0;
    let density = 1;
    let dispW = 0;
    try {
      const d = display.getDefaultDisplaySync();
      density = d.densityPixels > 0 ? d.densityPixels : 1;
      dispW = d.width;
      // 物理屏尺寸作为兜底
      wPx = d.width;
      hPx = d.height;
    } catch (e) {
      // ignore
    }
    const win = DevicePolicy.win;
    if (win !== null) {
      try {
        const rect = win.getWindowProperties().windowRect;
        if (rect.width > 0 && rect.height > 0) {
          wPx = rect.width;
          hPx = rect.height;
        }
      } catch (e) {
        // 拿不到窗口尺寸就退回物理屏
      }
    }
    // 窗口比手机物理屏还宽：超级桌面 / 车机 / 外接显示，按宽屏处理
    if (dispW > 0 && wPx > dispW + 40) {
      return true;
    }
    const minVp = Math.min(wPx, hPx) / density;
    return minVp >= DevicePolicy.WIDE_MIN_VP;
  }
}
