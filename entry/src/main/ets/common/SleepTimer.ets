// Session-only timer. Never restore a stale stop request after restarting the app.
export class SleepTimer {
  static action: (() => Promise<void>) | null = null;
  private static deadline: number = 0;
  private static endOfEpisode: boolean = false;
  private static durationMinutes: number = 0;
  private static timer: number = -1;

  static label(): string {
    if (SleepTimer.endOfEpisode) { return '本集结束后停止'; }
    if (SleepTimer.deadline > 0) { return Math.max(1, Math.ceil((SleepTimer.deadline - Date.now()) / 60000)) + ' 分钟后停止'; }
    return '未开启';
  }

  static set(minutes: number): void {
    SleepTimer.cancel();
    SleepTimer.endOfEpisode = minutes === -1;
    SleepTimer.durationMinutes = minutes;
    if (minutes > 0) {
      SleepTimer.deadline = Date.now() + minutes * 60000;
      SleepTimer.timer = setTimeout(() => { SleepTimer.check(); }, minutes * 60000);
    }
    AppStorage.setOrCreate('sleepTimerLabel', SleepTimer.label());
  }

  static cancel(): void {
    if (SleepTimer.timer >= 0) { clearTimeout(SleepTimer.timer); SleepTimer.timer = -1; }
    SleepTimer.deadline = 0;
    SleepTimer.endOfEpisode = false;
    SleepTimer.durationMinutes = 0;
    AppStorage.setOrCreate('sleepTimerLabel', '未开启');
  }

  static selectedMinutes(): number {
    return SleepTimer.deadline > 0 || SleepTimer.endOfEpisode ? SleepTimer.durationMinutes : -999;
  }

  static check(): void {
    if (SleepTimer.deadline > 0 && Date.now() >= SleepTimer.deadline) { SleepTimer.fire(); }
  }

  static completed(): boolean {
    if (!SleepTimer.endOfEpisode) { return false; }
    SleepTimer.fire();
    return true;
  }

  private static fire(): void {
    const action = SleepTimer.action;
    SleepTimer.cancel();
    if (action !== null) {
      action().catch(() => { AppStorage.setOrCreate('sleepTimerLabel', '停止失败，请返回遥控重试'); });
    }
  }
}
