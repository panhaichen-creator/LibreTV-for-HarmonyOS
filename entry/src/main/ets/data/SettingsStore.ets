/**
 * 应用设置持久化 —— 对应 LibreTV Web 版的 settings store
 */

import { Store } from './Store';
import { Settings, DEFAULT_SETTINGS } from '../model/Types';
import { EventBus, Events } from '../common/EventBus';

export class SettingsStore {
  private static readonly KEY = 'app_settings';

  private static inst: SettingsStore | null = null;
  private settings: Settings = DEFAULT_SETTINGS;
  private loaded = false;

  static shared(): SettingsStore {
    if (!SettingsStore.inst) {
      SettingsStore.inst = new SettingsStore();
    }
    return SettingsStore.inst;
  }

  get(): Settings {
    this.load();
    return this.settings;
  }

  update(patch: Partial<Settings>): void {
    this.load();
    const s = this.settings;
    if (patch.adFilter !== undefined) {
      s.adFilter = patch.adFilter;
    }
    if (patch.autoNext !== undefined) {
      s.autoNext = patch.autoNext;
    }
    if (patch.adultFilter !== undefined) {
      s.adultFilter = patch.adultFilter;
    }
    if (patch.themeMode !== undefined) {
      s.themeMode = patch.themeMode;
    }
    if (patch.recommendSource !== undefined) {
      s.recommendSource = patch.recommendSource;
    }
    if (patch.defaultSpeed !== undefined) {
      s.defaultSpeed = patch.defaultSpeed;
    }
    if (patch.playHistoryEnabled !== undefined) {
      s.playHistoryEnabled = patch.playHistoryEnabled;
    }
    if (patch.autoDiscover !== undefined) {
      s.autoDiscover = patch.autoDiscover;
    }
    this.save();
  }

  private load(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    const json = Store.shared().getJson(SettingsStore.KEY);
    if (json === '') {
      return;
    }
    try {
      const rec = JSON.parse(json) as Record<string, object>;
      const adFilter = SettingsStore.str(rec['adFilter']);
      if (adFilter !== '') {
        this.settings.adFilter = adFilter;
      }
      this.settings.autoNext = SettingsStore.bool(rec['autoNext'], this.settings.autoNext);
      this.settings.adultFilter = SettingsStore.bool(rec['adultFilter'], this.settings.adultFilter);
      const themeMode = SettingsStore.str(rec['themeMode']);
      if (themeMode !== '') {
        this.settings.themeMode = themeMode;
      }
      const recommendSource = SettingsStore.str(rec['recommendSource']);
      if (recommendSource !== '') {
        // 「豆瓣热播电视剧（近1年）」与电影版内容重复，已合并为「豆瓣热播」：
        // 旧存量值 douban_tv 统一迁移到 douban_movie，否则设置页会显示空标签
        this.settings.recommendSource =
          recommendSource === 'douban_tv' ? 'douban_movie' : recommendSource;
      }
      const speed = SettingsStore.num(rec['defaultSpeed'], 0);
      if (speed > 0) {
        this.settings.defaultSpeed = speed;
      }
      this.settings.playHistoryEnabled = SettingsStore.bool(rec['playHistoryEnabled'], this.settings.playHistoryEnabled);
      this.settings.autoDiscover = SettingsStore.bool(rec['autoDiscover'], this.settings.autoDiscover);
    } catch (e) {
      // 数据损坏时用默认值
    }
  }

  private save(): void {
    Store.shared().putJson(SettingsStore.KEY, JSON.stringify(this.settings));
    EventBus.emit(Events.SETTINGS_CHANGED);
  }

  private static str(v: object): string {
    return typeof v === 'string' ? (v as string) : '';
  }

  private static bool(v: object, def: boolean): boolean {
    return typeof v === 'boolean' ? (v as boolean) : def;
  }

  private static num(v: object, def: number): number {
    return typeof v === 'number' ? (v as number) : def;
  }
}
