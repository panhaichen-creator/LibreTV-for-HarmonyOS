import { avSession } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DlnaProbe } from './DlnaProbe';

// The shared controls used by both the system cast session and standard DLNA.
export interface CastControl {
  direct?: boolean;
  prepare(item: avSession.AVQueueItem): Promise<void>;
  start(item: avSession.AVQueueItem): Promise<void>;
  sendControlCommand(command: avSession.AVCastControlCommand): Promise<void>;
  getCurrentItem(): Promise<avSession.AVQueueItem>;
  getAVPlaybackState(): Promise<avSession.AVPlaybackState>;
  on(type: 'playbackStateChange', filter: 'all', callback: (state: avSession.AVPlaybackState) => void): void;
  on(type: 'error', callback: (error: BusinessError) => void): void;
  off(type: 'playbackStateChange'): void;
  off(type: 'error'): void;
}

export class DlnaControl implements CastControl {
  direct: boolean = true;
  private name: string;
  private uri: string;
  private asset: string;
  private callback: ((state: avSession.AVPlaybackState) => void) | null = null;
  private timer: number = -1;
  private epoch: number = 0;
  private failures: number = 0;
  private errorCallback: ((error: BusinessError) => void) | null = null;
  private lastPosition: number = 0;
  private lastDuration: number = 0;
  private commandChain: Promise<void> = Promise.resolve();

  constructor(name: string, uri: string, asset: string) { this.name = name; this.uri = uri; this.asset = asset; }

  async prepare(item: avSession.AVQueueItem): Promise<void> {
    if (item.description === undefined || !/^https?:\/\//i.test(item.description.mediaUri ?? '')) { throw new Error('无效视频地址'); }
  }

  async start(item: avSession.AVQueueItem): Promise<void> {
    await this.prepare(item);
    await this.commandChain.catch(() => {});
    const description = item.description!;
    this.lastPosition = 0;
    this.lastDuration = 0;
    await DlnaProbe.command(this.name, 'load', 0, description.mediaUri!);
    this.uri = description.mediaUri!;
    this.asset = description.assetId;
    await DlnaProbe.command(this.name, 'play');
  }

  async getCurrentItem(): Promise<avSession.AVQueueItem> {
    const remote = await DlnaProbe.read(this.name);
    return { itemId: 0, description: { assetId: remote.mediaUri === this.uri ? this.asset : '',
      mediaUri: remote.mediaUri, mediaType: 'VIDEO', duration: remote.state.duration } };
  }

  async getAVPlaybackState(): Promise<avSession.AVPlaybackState> {
    const remote = await DlnaProbe.read(this.name);
    if (remote.mediaUri !== this.uri) { throw new Error('电视正在播放其他内容'); }
    return remote.state;
  }

  async sendControlCommand(command: avSession.AVCastControlCommand): Promise<void> {
    // Recheck media identity before changing anything on a reattached television.
    const next = this.commandChain.catch(() => {}).then(async () => {
      await this.getAVPlaybackState();
      await DlnaProbe.command(this.name, command.command, Number(command.parameter ?? 0));
    });
    this.commandChain = next;
    return next;
  }

  on(type: 'playbackStateChange', filter: 'all', callback: (state: avSession.AVPlaybackState) => void): void;
  on(type: 'error', callback: (error: BusinessError) => void): void;
  on(type: string, filter: 'all' | ((error: BusinessError) => void), callback?: (state: avSession.AVPlaybackState) => void): void {
    if (type === 'playbackStateChange' && callback !== undefined) {
      this.callback = callback;
      this.failures = 0;
      this.poll(++this.epoch);
    } else if (type === 'error') { this.errorCallback = filter as (error: BusinessError) => void; }
  }

  off(type: 'playbackStateChange' | 'error'): void {
    if (type === 'error') { this.errorCallback = null; }
    if (type === 'playbackStateChange') {
      this.epoch++;
      this.callback = null;
      if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    }
  }

  private poll(epoch: number): void {
    this.timer = setTimeout(async () => {
      try {
        const state = await this.getAVPlaybackState();
        if (this.epoch === epoch) {
          this.failures = 0;
          if (state.state === avSession.PlaybackState.PLAYBACK_STATE_STOP && this.lastDuration > 0 && this.lastPosition >= this.lastDuration - 4000) {
            state.state = avSession.PlaybackState.PLAYBACK_STATE_COMPLETED;
            this.lastPosition = 0;
          } else {
            this.lastPosition = state.position?.elapsedTime ?? this.lastPosition;
            this.lastDuration = state.duration ?? this.lastDuration;
          }
          this.callback?.(state);
        }
      } catch (e) {
        if (this.epoch === epoch) {
          this.failures++;
          if (this.failures >= 3) {
            const notify = this.errorCallback;
            this.off('playbackStateChange');
            notify?.({ name: 'CastConnectionLost', message: '电视连接已丢失', code: 6600001 });
          }
        }
      }
      if (this.epoch === epoch && this.callback !== null) { this.poll(epoch); }
    }, 2500);
  }
}

export class NativeCastControl implements CastControl {
  private controller: avSession.AVCastController;
  constructor(controller: avSession.AVCastController) { this.controller = controller; }
  prepare(item: avSession.AVQueueItem): Promise<void> { return this.controller.prepare(item); }
  start(item: avSession.AVQueueItem): Promise<void> { return this.controller.start(item); }
  sendControlCommand(command: avSession.AVCastControlCommand): Promise<void> { return this.controller.sendControlCommand(command); }
  getCurrentItem(): Promise<avSession.AVQueueItem> { return this.controller.getCurrentItem(); }
  getAVPlaybackState(): Promise<avSession.AVPlaybackState> { return this.controller.getAVPlaybackState(); }
  on(type: 'playbackStateChange', filter: 'all', callback: (state: avSession.AVPlaybackState) => void): void;
  on(type: 'error', callback: (error: BusinessError) => void): void;
  on(type: string, filter: 'all' | ((error: BusinessError) => void), callback?: (state: avSession.AVPlaybackState) => void): void {
    if (type === 'playbackStateChange' && callback !== undefined) { this.controller.on('playbackStateChange', 'all', callback); }
    else if (type === 'error') { this.controller.on('error', filter as (error: BusinessError) => void); }
  }
  off(type: 'playbackStateChange' | 'error'): void {
    if (type === 'playbackStateChange') { this.controller.off('playbackStateChange'); }
    else { this.controller.off('error'); }
  }
}
