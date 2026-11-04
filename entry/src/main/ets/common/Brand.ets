/**
 * 应用显示名。
 *
 * 名字不再是代码里的字面量，而是资源 app.string.brand_name ——
 * scripts/brand.js 会在每次构建前按构建配置写入对应品牌
 * （公开构建用 LibreTV，签名构建用本地品牌），界面这边一行都不用动。
 *
 * 只有拿不到 UIContext 的地方才需要它（Text($r('app.string.brand_name')) 直接就能用）；
 * 目前用在 AVSession 的兜底标题和源列表导出名这类「必须是字符串」的位置。
 */

import { UIContext } from '@kit.ArkUI';

export class Brand {
  private static cache: string = '';

  static displayName(ui: UIContext): string {
    if (Brand.cache !== '') {
      return Brand.cache;
    }
    try {
      const ctx = ui.getHostContext();
      if (ctx !== undefined) {
        // 按资源名取，不用 $r：$r 只能在声明式 UI 里用
        Brand.cache = ctx.resourceManager.getStringByNameSync('brand_name');
      }
    } catch (e) {
      Brand.cache = '';
    }
    return Brand.cache;
  }

  /** 切换品牌后缓存会过期，构建产物每次都是新的进程，正常用不到这个方法 */
  static reset(): void {
    Brand.cache = '';
  }
}
