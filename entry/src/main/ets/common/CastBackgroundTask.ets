import { wantAgent, common } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

/** Keeps the casting timer alive while the player page is in the background. */
export class CastBackgroundTask {
  private static context: common.UIAbilityContext | null = null;
  private static pending: Promise<void> = Promise.resolve();

  static start(context: common.UIAbilityContext): Promise<void> {
    const task = CastBackgroundTask.pending.then(async () => {
      if (CastBackgroundTask.context !== null) { return; }
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(
        context, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      CastBackgroundTask.context = context;
    });
    CastBackgroundTask.pending = task.catch(() => {});
    return task;
  }

  static stop(): Promise<void> {
    const task = CastBackgroundTask.pending.then(async () => {
      const context = CastBackgroundTask.context;
      if (context === null) { return; }
      await backgroundTaskManager.stopBackgroundRunning(context);
      CastBackgroundTask.context = null;
    });
    CastBackgroundTask.pending = task.catch(() => {});
    return task;
  }
}
