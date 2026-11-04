/**
 * 路由相关的组件 id 常量。
 *
 * 只有一个用途：画中画的 navigationId 必须和主 Navigation 组件的 id 完全一致。
 * 系统在首次 setAutoStartEnabled(true) 时会把「这个 Navigation 的栈顶信息」缓存下来，
 * 从画中画恢复时靠它回到原来那一页。id 对不上，恢复后会回到首页而不是播放页。
 * 两处各写一个字符串迟早会漂移，所以抽到这里。
 */
export class NavIds {
  /** 主 Navigation 组件（IndexPage.build 里的 Navigation） */
  static readonly MAIN: string = 'mainNav';
}
