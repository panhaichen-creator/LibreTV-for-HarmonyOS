import { SleepTimer } from './SleepTimer';
import { CastBackgroundTask } from './CastBackgroundTask';
import { BusinessError } from '@kit.BasicServicesKit';
import { CastControl } from './CastControl';
import { CastResume } from './CastResume';
import { avSession } from '@kit.AVSessionKit';
import { PlayRecord, Episode } from '../model/Types';
import { HistoryStore } from '../data/HistoryStore';
import { SettingsStore } from '../data/SettingsStore';
import { PlayUrlResolver } from '../player/PlayUrlResolver';

export interface ParkedCast {
  session: avSession.AVSession;
  controller: CastControl;
  device: avSession.OutputDeviceInfo;
  deviceName: string;
  record: PlayRecord;
  episodes: Episode[];
  playing: boolean;
  volume: number;
  landscape: boolean;
  rotationMode: string;
  mediaUri: string;
  assetId: string;
}

// Own the remote session only while its player page is closed.
export class CastHandoff {
  private static value: ParkedCast | null = null;
  private static savedAt: number = 0;
  private static advancing: boolean = false;

  static park(value: ParkedCast): void {
    CastHandoff.value = value;
    SleepTimer.action = async () => { await CastHandoff.stop(); };
    AppStorage.setOrCreate('activeCastLabel', value.deviceName);
    value.controller.off('playbackStateChange');
    value.controller.off('error');
    value.session.off('outputDeviceChange');
    value.controller.on('playbackStateChange', 'all', (state: avSession.AVPlaybackState) => {
      if (CastHandoff.value !== value) { return; }
      if (state.position !== undefined) { value.record.positionMs = state.position.elapsedTime; }
      if (state.duration !== undefined) { value.record.durationMs = state.duration; }
      if (state.volume !== undefined) { value.volume = state.volume; }
      if (state.state !== undefined) {
        value.playing = state.state === avSession.PlaybackState.PLAYBACK_STATE_PLAY;
        if (state.state === avSession.PlaybackState.PLAYBACK_STATE_COMPLETED) {
          if (!SleepTimer.completed()) { CastHandoff.next(value); }
        }
      }
      if (Date.now() - CastHandoff.savedAt > 5000) { CastHandoff.save(value); }
    });
    value.controller.on('error', (error: BusinessError) => {
      if (error.code !== 6600001) {
        if (CastHandoff.value === value) { AppStorage.setOrCreate('activeCastLabel', value.deviceName + ' · 播放异常'); }
        return;
      }
      if (CastHandoff.value !== value) { return; }
      CastHandoff.leaveRemotePlaying().catch(() => {});
    });
    value.session.on('outputDeviceChange', (state: avSession.ConnectionState, device: avSession.OutputDeviceInfo) => {
      if (value.controller.direct) { return; }
      const remote = device.devices.some((d: avSession.DeviceInfo) => d.castCategory === avSession.AVCastCategory.CATEGORY_REMOTE);
      if (CastHandoff.value === value && (state === avSession.ConnectionState.STATE_DISCONNECTED || !remote)) {
        CastHandoff.leaveRemotePlaying().catch(() => {});
      }
    });
    CastHandoff.save(value);
  }

  static peek(): ParkedCast | null { return CastHandoff.value; }

  static take(): ParkedCast | null {
    const value = CastHandoff.value;
    CastHandoff.value = null;
    AppStorage.setOrCreate('activeCastLabel', '');
    if (value !== null) {
      value.controller.off('playbackStateChange');
      value.controller.off('error');
      value.session.off('outputDeviceChange');
    }
    return value;
  }

  static async stop(): Promise<void> {
    const value = CastHandoff.value;
    if (value === null) { return; }
    try {
      await value.controller.sendControlCommand({ command: 'stop' });
      if (!value.controller.direct) { await value.session.stopCasting(); }
      SleepTimer.cancel();
      SleepTimer.action = null;
      if (CastHandoff.value === value) {
        CastHandoff.save(value);
        CastHandoff.take();
        CastResume.clear();
        await value.session.destroy();
      } else if (CastHandoff.value === null) { CastResume.clear(); }
    } finally {
      // A failed manual stop still owns its timer and must keep counting in the background.
      if (SleepTimer.selectedMinutes() === -999) { await CastBackgroundTask.stop(); }
    }
  }

  static async leaveRemotePlaying(): Promise<void> {
    const value = CastHandoff.value;
    if (value === null) { return; }
    CastHandoff.save(value);
    CastHandoff.take();
    SleepTimer.cancel();
    SleepTimer.action = null;
    try { await value.session.destroy(); }
    finally { await CastBackgroundTask.stop(); }
  }

  private static save(value: ParkedCast): void {
    CastHandoff.savedAt = Date.now();
    const device = value.device.devices.find((d: avSession.DeviceInfo) => d.castCategory === avSession.AVCastCategory.CATEGORY_REMOTE);
    if (device !== undefined && value.mediaUri) {
      CastResume.save({ deviceId: device.deviceId, deviceName: device.deviceName,
        record: value.record, mediaUri: value.mediaUri, assetId: value.assetId });
    }
    if (SettingsStore.shared().get().playHistoryEnabled) {
      value.record.updatedAt = Date.now();
      HistoryStore.shared().saveProgress(value.record);
    }
  }

  private static async next(value: ParkedCast): Promise<void> {
    if (CastHandoff.advancing) { return; }
    const index = value.record.episode + 1;
    if (!SettingsStore.shared().get().autoNext || index >= value.episodes.length) { return; }
    CastHandoff.advancing = true;
    try {
      const ep = value.episodes[index];
      const url = await PlayUrlResolver.resolveSharePage(ep.url);
      if (CastHandoff.value !== value || !/^https?:\/\//i.test(url)) { return; }
      const item: avSession.AVQueueItem = { itemId: index, description: {
        assetId: 'libretv:' + value.record.sourceKey + ':' + value.record.vodId + ':' + index, title: value.record.name,
        mediaUri: url, mediaType: 'VIDEO', startPosition: 0
      } };
      await value.controller.prepare(item);
      if (CastHandoff.value !== value) { return; }
      await value.controller.start(item);
      if (CastHandoff.value !== value) { return; }
      value.mediaUri = url;
      value.assetId = 'libretv:' + value.record.sourceKey + ':' + value.record.vodId + ':' + index;
      value.record.episode = index;
      value.record.episodeName = ep.name;
      value.record.playUrl = ep.url;
      value.record.positionMs = 0;
      value.record.durationMs = 0;
      CastHandoff.save(value);
    } catch (e) { console.error('[cast] parked next episode failed: ' + JSON.stringify(e)); }
    finally { CastHandoff.advancing = false; }
  }
}
