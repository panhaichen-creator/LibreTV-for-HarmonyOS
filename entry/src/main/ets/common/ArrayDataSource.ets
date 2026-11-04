/**
 * 通用数组数据源：把普通数组包装成 IDataSource，供 LazyForEach 按需渲染。
 *
 * ForEach 会一次性创建全部子组件 —— 瀑布流滑到几百条时每张卡片都挂在树上，
 * 滚动帧里光布局计算就吃掉十几毫秒，肉眼就是掉帧。
 * LazyForEach 只创建可视区 + cachedCount 范围内的卡片，其余靠数据源按需供给。
 */
export class ArrayDataSource implements IDataSource {
  private items: Object[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): Object {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /** 全量替换并通知刷新 */
  setData(items: Object[]): void {
    this.items = items;
    this.listeners.forEach((l: DataChangeListener) => {
      l.onDataReloaded();
    });
  }
}
