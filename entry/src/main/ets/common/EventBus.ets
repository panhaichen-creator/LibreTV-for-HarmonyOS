/**
 * 轻量事件总线：跨页面数据变更通知（替代 Web 版的全局 store 订阅）
 */

export class EventBus {
  private static listeners: Map<string, Array<() => void>> = new Map();

  static on(event: string, cb: () => void): void {
    let list = EventBus.listeners.get(event);
    if (!list) {
      list = [];
      EventBus.listeners.set(event, list);
    }
    list.push(cb);
  }

  static off(event: string, cb: () => void): void {
    const list = EventBus.listeners.get(event);
    if (!list) {
      return;
    }
    const idx = list.indexOf(cb);
    if (idx >= 0) {
      list.splice(idx, 1);
    }
  }

  static emit(event: string): void {
    const list = EventBus.listeners.get(event);
    if (!list) {
      return;
    }
    const copy = list.slice();
    for (const cb of copy) {
      cb();
    }
  }
}

/** 事件名常量 */
export class Events {
  static readonly HISTORY_CHANGED = 'history_changed';
  static readonly SOURCES_CHANGED = 'sources_changed';
  static readonly SETTINGS_CHANGED = 'settings_changed';
  static readonly DOWNLOADS_CHANGED = 'downloads_changed';
  static readonly LIVE_FAV_CHANGED = 'live_fav_changed';
}
