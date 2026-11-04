/**
 * 本地持久化存储：基于 @kit.ArkData 用户首选项（Preferences）
 * 对应 Web 版 localStorage / IndexedDB 的角色
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

export class Store {
  private static inst: Store | null = null;
  private prefs: preferences.Preferences | null = null;

  static shared(): Store {
    if (!Store.inst) {
      Store.inst = new Store();
    }
    return Store.inst;
  }

  init(context: common.Context): void {
    if (this.prefs) {
      return;
    }
    try {
      this.prefs = preferences.getPreferencesSync(context, { name: 'libretv_store' });
    } catch (e) {
      this.prefs = null;
    }
  }

  getString(key: string, def: string): string {
    if (!this.prefs) {
      return def;
    }
    try {
      return this.prefs.getSync(key, def) as string;
    } catch (e) {
      return def;
    }
  }

  putString(key: string, value: string): void {
    if (!this.prefs) {
      return;
    }
    try {
      this.prefs.putSync(key, value);
      this.prefs.flush();
    } catch (e) {
      // ignore
    }
  }

  getBoolean(key: string, def: boolean): boolean {
    if (!this.prefs) {
      return def;
    }
    try {
      return this.prefs.getSync(key, def) as boolean;
    } catch (e) {
      return def;
    }
  }

  putBoolean(key: string, value: boolean): void {
    this.putString(key, value ? '1' : '0');
  }

  /** 读取 JSON 字符串；不存在返回空串 */
  getJson(key: string): string {
    return this.getString(key, '');
  }

  putJson(key: string, value: string): void {
    this.putString(key, value);
  }

  remove(key: string): void {
    if (!this.prefs) {
      return;
    }
    try {
      this.prefs.deleteSync(key);
      this.prefs.flush();
    } catch (e) {
      // ignore
    }
  }
}
