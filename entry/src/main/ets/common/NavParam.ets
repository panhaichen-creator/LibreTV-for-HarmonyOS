/**
 * 取当前路由的**最新**参数。
 *
 * 为什么非要它：Navigation 会按路由名缓存 NavDestination 节点，pop 之后再 push
 * 同名路由时，框架直接复用缓存的节点 —— **组件实例不会重建**，构造时传进来的
 * 参数还停在上一次的值，aboutToAppear 也不会再执行。
 *
 * 症状就是「点 A 打开的是 B 的详情」「换台换不动」「再进播放页播的还是上一部」。
 * 凡是有参数的页面，都必须在 onShown 里用这个函数把参数重新取一遍。
 */
export function latestNavParam(stack: NavPathStack, name: string): Object | null {
  // SDK 把返回值声明成 Array<unknown>，而 ArkTS 不允许声明 unknown 类型
  // （arkts-no-any-unknown），只能先落到 Object 再断言成数组。
  const raw: Object = stack.getParamByName(name) as Object;
  const list: Object[] = raw as Object[];
  if (list.length === 0) {
    return null;
  }
  return list[list.length - 1];
}
