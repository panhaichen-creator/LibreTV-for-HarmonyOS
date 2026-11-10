import { CastControl } from './CastControl';
import { DlnaProbe } from './DlnaProbe';
import { avSession } from '@kit.AVSessionKit';
import { PlayRecord } from '../model/Types';
import { Store } from '../data/Store';

export interface CastSnapshot {
  deviceId: string;
  deviceName: string;
  record: PlayRecord;
  mediaUri: string;
  assetId: string;
}

// Persist only media identity and progress, never a live session/controller.
export class CastResume {
  private static savedHere: boolean = false;

  static isFromPreviousRun(): boolean { return !CastResume.savedHere && CastResume.load() !== null; }
  static load(): CastSnapshot | null {
    try {
      const value = JSON.parse(Store.shared().getJson('last_cast')) as CastSnapshot;
      if (!value || !value.record || !value.deviceId || !value.mediaUri || !value.record.sourceKey || !value.record.vodId) { return null; }
      return value;
    } catch (e) { return null; }
  }

  static save(value: CastSnapshot): void {
    CastResume.savedHere = true;
    Store.shared().putJson('last_cast', JSON.stringify(value));
    AppStorage.setOrCreate('lastCastLabel', value.deviceName);
  }

  static clear(): void {
    Store.shared().remove('last_cast');
    AppStorage.setOrCreate('lastCastLabel', '');
  }

  static async read(controller: CastControl, value: CastSnapshot, deviceId: string, deviceName: string = ''): Promise<avSession.AVPlaybackState> {
    if (value.deviceId !== deviceId && (!deviceName || deviceName !== value.deviceName)) { throw new Error('请选择原来的电视'); }
    return await CastResume.current(controller, value.mediaUri, value.assetId, value.deviceName);
  }

  static async current(controller: CastControl, mediaUri: string, assetId: string, deviceName: string): Promise<avSession.AVPlaybackState> {
    let timer: number = -1;
    try {
      const query = async (): Promise<avSession.AVPlaybackState> => {
        let state: avSession.AVPlaybackState;
        let wrongContent = false;
        try {
          const item = await controller.getCurrentItem();
          const description = item.description;
          if (description === undefined) { throw new Error('资源信息不可用'); }
          if (description.mediaUri !== mediaUri && (!assetId || description.assetId !== assetId)) {
            wrongContent = true;
            throw new Error('电视正在播放其他内容');
          }
          state = await controller.getAVPlaybackState();
          if (!state.duration && description.duration) { state.duration = description.duration; }
          if (!state.duration || state.position === undefined) { throw new Error('系统未返回完整进度'); }
        } catch (e) {
          if (wrongContent) { throw new Error('电视正在播放其他内容'); }
          console.info('[cast] using read-only DLNA state fallback');
          const remote = await DlnaProbe.read(deviceName);
          if (remote.mediaUri !== mediaUri) { throw new Error('电视正在播放其他内容'); }
          state = remote.state;
        }
        if (state.position === undefined || state.position.elapsedTime < 0 ||
          (state.state !== avSession.PlaybackState.PLAYBACK_STATE_PLAY && state.state !== avSession.PlaybackState.PLAYBACK_STATE_PAUSE)) {
          throw new Error('电视未返回有效播放状态');
        }
        console.info('[cast] remote state position=' + state.position.elapsedTime + ' duration=' + (state.duration ?? 0));
        return state;
      };
      const timeout = new Promise<avSession.AVPlaybackState>((resolve, reject) => {
        timer = setTimeout(() => { reject(new Error('读取电视状态超时')); }, 10000);
      });
      return await Promise.race([query(), timeout]);
    } finally { if (timer >= 0) { clearTimeout(timer); } }
  }
  static async synchronize(controller: CastControl, mediaUri: string, assetId: string, deviceName: string,
    targetMs: number | null, alive: () => boolean, keepResuming: () => boolean = () => true, onSeek: () => void = () => {}): Promise<avSession.AVPlaybackState | null> {
    let latest: avSession.AVPlaybackState | null = null;
    let seeks = 0;
    let lastPosition = -1;
    let advancingSamples = 0;
    let lastSeekAttempt = -6;
    const deadline = Date.now() + 25000;
    for (let attempt = 0; attempt < 40 && alive() && Date.now() < deadline; attempt++) {
      try {
        latest = await CastResume.current(controller, mediaUri, assetId, deviceName);
        if (!alive()) { return null; }
        if (!keepResuming()) { return latest; }
        const position = latest.position?.elapsedTime ?? 0;
        if (targetMs !== null && targetMs > 0 && (position < targetMs - 3000 || position > targetMs + 15000) && seeks < 2) {
          // 加载阶段的 0 和 seek 缓存值不代表实际起播；等时钟前进再校正。
          const ready = lastPosition >= 0 && position > lastPosition ||
            latest.state === avSession.PlaybackState.PLAYBACK_STATE_PAUSE && attempt >= 4;
          if (ready && attempt - lastSeekAttempt >= 6) {
            onSeek();
            console.info('[cast] correcting start position target=' + targetMs + ' actual=' + position);
            await controller.sendControlCommand({ command: 'seek', parameter: targetMs });
            seeks++;
            lastSeekAttempt = attempt;
          }
          advancingSamples = 0;
          lastPosition = lastSeekAttempt === attempt ? -1 : position;
        } else if ((latest.duration ?? 0) > 0) {
          if (targetMs === null || targetMs <= 0) { return latest; }
          // 系统可能先回报 seek 的缓存值，电视加载完成后才重置到 0。
          // 连续确认播放进度在前进，不能把第一次回报当作续播成功。
          if (position >= targetMs - 3000 && position <= targetMs + 15000) {
            if (lastPosition >= 0 && position > lastPosition) { advancingSamples++; }
            if (advancingSamples >= 2) { return latest; }
          } else { advancingSamples = 0; }
          lastPosition = position;
        }
      } catch (e) { console.warn('[cast] state sync retry=' + attempt); }
      await new Promise<void>((resolve) => { setTimeout(resolve, 500); });
    }
    return alive() ? latest : null;
  }

}
