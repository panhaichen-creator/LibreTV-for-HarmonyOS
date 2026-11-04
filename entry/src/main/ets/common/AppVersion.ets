/**
 * 应用版本号：唯一可信来源是 `AppScope/app.json5`，运行时从包信息读取。
 *
 * 为什么要单独抽这个文件：
 * 早前「关于」页和「我的 → 关于」各写了一份字面量（'1.0.0' / 'v1.0.0'），
 * 发版时只改了 app.json5，界面上就出现「关于页 1.0.5、我的页 v1.0.0」的错位，
 * 而且这种错位没有任何报错，只有用户截图才能发现。
 *
 * 现在两个页面都调这里，版本号只有 app.json5 一处，
 * 打包时 scripts/version.js 会自动 +0.01（源码有改动才递增）。
 */

import { bundleManager } from '@kit.AbilityKit';

export class AppVersion {
  private static cache: string = '';

  /**
   * 形如 1.0.5；读取失败返回空串，由调用方决定怎么显示。
   * 注意：方法名不能叫 `name` —— ArkTS 会报
   * 「Static property 'name' conflicts with built-in property 'Function.name'」。
   */
  static value(): string {
    if (AppVersion.cache.length > 0) {
      return AppVersion.cache;
    }
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      AppVersion.cache = info.versionName;
    } catch (e) {
      // 取不到就保持空串，宁可不显示，也不显示一个假的版本号
      AppVersion.cache = '';
    }
    return AppVersion.cache;
  }

  /** 带 v 前缀，用于设置列表右侧展示；读取失败返回空串 */
  static display(): string {
    const v: string = AppVersion.value();
    return v.length > 0 ? 'v' + v : '';
  }
}
