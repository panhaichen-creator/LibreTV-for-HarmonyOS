/**
 * 下载管理页：缓存任务进度 / 离线播放 / 删除
 */

import { DownloadTaskRecord, PlayRecord } from '../model/Types';
import { DownloadManager } from '../data/DownloadManager';
import { HistoryStore } from '../data/HistoryStore';
import { EmptyView } from '../components/CommonWidgets';
import { NetImage } from '../components/NetImage';
import { PosterColor } from '../common/PosterColor';
import { pageBgGradient } from '../common/GlassTheme';
import { PlayerPageParam } from './PlayerPage';
import { SystemInsets } from '../common/SystemInsets';
import { BlurFade } from '../common/BlurFade';


@Component
export struct DownloadsPage {
  navPathStack: NavPathStack = new NavPathStack();

  @State tasks: DownloadTaskRecord[] = [];

  /** 进度轮询计时器：下载在后台线程推进，页面不刷新就会一直停在初始数字 */
  private tickTimer: number = -1;

  /**
   * 离线续播点缓存：key = task.id，value = 毫秒（0 表示从头播）。
   * 播放历史是一整段 JSON，每帧给每个列表项各解析一次太浪费，
   * 只在「重新拉任务快照」时算一遍。字段不是 @State —— 它只被 build 读取，
   * 真正触发刷新的是 tasks 重新赋值。
   */
  private resumeCache: Map<string, number> = new Map<string, number>();

  /**
   * 已看进度缓存：key = task.id，value = 百分比字符串（'0%' / '37%' / ''）。
   * 空串表示这一集没有观看记录、或进度小到不值得画 —— 封面就不叠进度条。
   * 与 resumeCache 同一趟算完，理由同上：历史记录是一整段 JSON，
   * 不能每帧给每个列表项各解析一次。
   */
  private watchCache: Map<string, string> = new Map<string, string>();

  aboutToAppear(): void {
    this.refreshTasks();
    this.startTick();
  }

  /** 拉一次任务快照，并同步重算离线续播点 */
  private refreshTasks(): void {
    this.tasks = DownloadManager.shared().getTasks();
    this.rebuildResumeCache();
  }

  aboutToDisappear(): void {
    this.stopTick();
  }

  /**
   * 开始轮询进度（幂等）。
   * 每 1s 拉一次：下载在后台线程推进，只在进入页面时读一次会让界面停在
   * "2/287" 不动。必须能被重复调用 —— Navigation 复用缓存节点时
   * aboutToAppear 不会再执行，重新进入只有 onShown 会来。
   */
  private startTick(): void {
    if (this.tickTimer >= 0) {
      return;
    }
    this.tickTimer = setInterval(() => {
      const next: DownloadTaskRecord[] = DownloadManager.shared().getTasks();
      if (DownloadManager.progressKey(next) !== DownloadManager.progressKey(this.tasks)) {
        this.tasks = next;
      }
    }, 1000);
  }

  /** 停止轮询（幂等）：离开页面、退到后台都要停 */
  private stopTick(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  /**
   * 离线续播点（毫秒）。0 表示从头播。
   *
   * 播放记录按「整部影片」存（sourceKey + vodId 唯一），同一部剧换集时会覆盖，
   * 所以必须核对集号 —— 集号对不上说明上次看的是别的集，把这个位置搬过来
   * 会表现成「一打开就跳到 20 分钟」。
   * 只剩最后 30 秒也不续播：那种时候用户要的是重看，不是接着看结尾。
   */
  private resumeMs(task: DownloadTaskRecord): number {
    const hit: number | undefined = this.resumeCache.get(task.id);
    return hit !== undefined ? hit : 0;
  }

  /** 重算续播点缓存（进页面 / 从播放页回来时各算一次） */
  private rebuildResumeCache(): void {
    const cache: Map<string, number> = new Map<string, number>();
    const watch: Map<string, string> = new Map<string, string>();
    const history: PlayRecord[] = HistoryStore.shared().getHistory();
    for (const task of this.tasks) {
      let ms: number = 0;
      let pct: string = '';
      for (const rec of history) {
        if (rec.sourceKey !== task.sourceKey || rec.vodId !== task.vodId) {
          continue;
        }
        // 同一部影片只会有一条记录（saveProgress 是覆盖写），命中即可停。
        // 集号必须一致：那是「这一集」的进度，套到别的集上就是错的。
        if (rec.episode === task.episode && rec.positionMs > 5000) {
          const almostDone: boolean = rec.durationMs > 0 && rec.positionMs >= rec.durationMs - 30000;
          ms = almostDone ? 0 : rec.positionMs;
          // 封面上的红条与首页「继续观看」卡片同一套算法（positionMs / durationMs）
          pct = this.watchPercentOf(rec.positionMs, rec.durationMs);
        }
        break;
      }
      cache.set(task.id, ms);
      watch.set(task.id, pct);
    }
    this.resumeCache = cache;
    this.watchCache = watch;
  }

  /**
   * 已看进度百分比。空串表示「不画」。
   * 掐掉 0 和过小的值：1% 的红条在海报上只有半个像素，看着像脏点。
   */
  private watchPercentOf(positionMs: number, durationMs: number): string {
    if (durationMs <= 0 || positionMs <= 0) {
      return '';
    }
    let pct: number = Math.floor((positionMs / durationMs) * 100);
    if (pct < 2) {
      return '';
    }
    if (pct > 100) {
      pct = 100;
    }
    return pct + '%';
  }

  /** 取某条任务的已看进度（空串 = 不画） */
  private watchPercent(task: DownloadTaskRecord): string {
    const hit: string | undefined = this.watchCache.get(task.id);
    return hit !== undefined ? hit : '';
  }

  private playOffline(task: DownloadTaskRecord): void {
    const p: PlayerPageParam = {
      sourceKey: task.sourceKey,
      vodId: task.vodId,
      episode: task.episode,
      episodeName: task.episodeName,
      title: task.name,
      // 从上次看到的地方接着放。以前这里写死 0，每次点都从头开始 ——
      // 下载页的离线播放因此等于「永远看前 5 分钟」。
      positionMs: this.resumeMs(task),
      offlineDir: task.dir
    };
    this.navPathStack.pushPath({ name: 'Player', param: p });
  }

  private statusText(task: DownloadTaskRecord): string {
    if (task.status === 'completed') {
      return '已完成';
    }
    if (task.status === 'downloading') {
      return task.done + '/' + task.total + ' 分片';
    }
    if (task.status === 'pending') {
      return '等待中';
    }
    if (task.status === 'paused') {
      return '已暂停 · ' + task.done + '/' + task.total;
    }
    if (task.status === 'merging') {
      // 分片下完还要拼成一个整文件才能播，这一步在长视频上要几十秒
      return '正在合并…';
    }
    if (task.error !== undefined && task.error !== '') {
      return task.error;
    }
    return '失败';
  }

  private statusColor(task: DownloadTaskRecord): ResourceColor {
    if (task.status === 'completed') {
      return $r('app.color.color_success');
    }
    if (task.status === 'failed') {
      return $r('app.color.color_warning');
    }
    return $r('app.color.color_text_secondary');
  }

  /**
   * 列表项 key 必须带上进度：ForEach 只在 key 变化时重建对应项。
   * 只写 task.id 的话，即便数组被换成新快照，数字变了也不会重绘。
   */
  private taskKey(task: DownloadTaskRecord): string {
    // 末尾要带上「有没有续播点」：续播点是在播放页里产生的，
    // 回到本页时任务本身一个字段都没变，key 不变的话 ForEach 直接复用旧节点，
    // 按钮还写着「离线播放」，和点下去的实际行为对不上。
    return task.id + '|' + task.status + '|' + task.done + '/' + task.total +
      '|' + (task.error !== undefined ? task.error : '') +
      '|' + (this.resumeMs(task) > 0 ? 'r' : 'f') +
      // 封面上的已看进度条也在这条 key 里：进度是播放页产生的，
      // 回到本页时任务字段没变，key 不带上它，ForEach 复用旧节点就画不出红条
      '|' + this.watchPercent(task);
  }

  /** 有进度可显示的状态：暂停时进度条留在原处，用户才知道续传从哪接 */
  private showProgress(task: DownloadTaskRecord): boolean {
    if (task.total <= 0) {
      return false;
    }
    return task.status === 'downloading' || task.status === 'pending' || task.status === 'paused';
  }

  private progressPercent(task: DownloadTaskRecord): string {
    if (task.total <= 0) {
      return '0%';
    }
    const pct = Math.floor((task.done / task.total) * 100);
    if (pct < 0) {
      return '0%';
    }
    if (pct > 100) {
      return '100%';
    }
    return pct + '%';
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        // 内容层铺满整屏：滚动内容会从下方玻璃导航条背后穿过
        Column({ space: 0 }) {

          if (this.tasks.length === 0) {
            EmptyView({ emptyText: '还没有下载任务，可在详情页下载' })
          } else {
            List({ space: 10 }) {
            // 顶部占位：随内容滚走，让列表能从玻璃导航条背后滑过
            ListItem() {
              Column()
                .width('100%')
                .height(56 + SystemInsets.top())
            }
              // 断点续传提示：放在「导航条之下、影片列表之上」那段空白里。
              // 它此前排在占位之前，等于整行都藏在浮层导航条背后，只露出半截。
              ListItem() {
                Text('退出应用后下载会暂停，重新打开会自动从断点续传')
                  .fontSize(11)
                  .fontColor($r('app.color.color_text_secondary'))
                  .width('100%')
                  .padding({ left: 2, top: 6, bottom: 2 })
                  .textAlign(TextAlign.Start)
              }
              ForEach(this.tasks, (task: DownloadTaskRecord, index: number) => {
                ListItem() {
                  Row({ space: 10 }) {
                    // 影片封面：尺寸与「观看历史」那一栏完全一致（80×110、圆角 8），
                    // 两处列表切换着看不会一大一小。
                    // 之前试过 alignSelf(Stretch) 让它跟着行高走，结果高度被算成 0、
                    // 整块被裁掉了 —— 这里的行高本来就是被右侧文字撑出来的，
                    // 拿它当封面高度既不稳定也没必要。
                    DownloadPoster({
                      posterUrl: task.pic !== undefined ? task.pic : '',
                      progress: this.watchPercent(task)
                    })
                      .width(80)
                      .height(110)

                    Column({ space: 8 }) {
                    Row({ space: 8 }) {
                      Text(task.name)
                        .fontSize(14)
                        .fontColor($r('app.color.color_text'))
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(this.statusText(task))
                        .fontSize(11)
                        .fontColor(this.statusColor(task))
                    }
                    .width('100%')
                    Text(task.episodeName + ' · ' + task.sourceName)
                      .fontSize(11)
                      .fontColor($r('app.color.color_text_secondary'))
                      .width('100%')
                      .textAlign(TextAlign.Start)
                    if (this.showProgress(task)) {
                      // 用 Stack 而不是 Column 嵌套：Stack 的 alignContent 是唯一
                      // 能确定「从左边开始长」的写法，Column 受默认交叉轴对齐影响，
                      // 在不同版本上会表现成从中间向两侧填充。
                      Stack({ alignContent: Alignment.Start }) {
                        Row()
                          .width('100%')
                          .height(4)
                          .backgroundColor($r('app.color.color_chip_bg'))
                          .borderRadius(2)
                        Row()
                          .width(this.progressPercent(task))
                          .height(4)
                          .backgroundColor($r('app.color.color_primary'))
                          .borderRadius(2)
                      }
                      .width('100%')
                      .height(4)
                      Text(this.progressPercent(task))
                        .fontSize(11)
                        .fontColor($r('app.color.color_text_secondary'))
                        .width('100%')
                        .textAlign(TextAlign.End)
                    }
                    // 之前这几个动作只有 12fp 纯文字、没有内边距，实测可点区域
                    // 只有 22×13vp（远小于 40vp 的推荐下限），平板上几乎点不中。
                    // 改成带底色的胶囊按钮：高约 36vp、左右各 16vp 内边距。
                    Blank()
                    Row({ space: 10 }) {
                      if (task.status === 'completed') {
                        // 播过的写「继续观看」：点下去确实是从上次的位置接上，
                        // 还叫「离线播放」的话用户会以为又要从头看一遍。
                        Text(this.resumeMs(task) > 0 ? '继续观看' : '离线播放')
                          .fontSize(13)
                          .fontColor($r('app.color.color_primary'))
                          .padding({ left: 18, right: 18, top: 13, bottom: 13 })
                          .borderRadius(22)
                          .backgroundColor($r('app.color.color_chip_bg'))
                          .onClick(() => {
                            this.playOffline(task);
                          })
                      }
                      if (task.status === 'downloading' || task.status === 'pending') {
                        Text('暂停')
                          .fontSize(13)
                          .fontColor($r('app.color.color_primary'))
                          .padding({ left: 18, right: 18, top: 13, bottom: 13 })
                          .borderRadius(22)
                          .backgroundColor($r('app.color.color_chip_bg'))
                          .onClick(() => {
                            DownloadManager.shared().pause(task.id);
                            this.tasks = DownloadManager.shared().getTasks();
                          })
                      }
                      if (task.status === 'paused' || task.status === 'failed') {
                        Text('继续')
                          .fontSize(13)
                          .fontColor($r('app.color.color_primary'))
                          .padding({ left: 18, right: 18, top: 13, bottom: 13 })
                          .borderRadius(22)
                          .backgroundColor($r('app.color.color_chip_bg'))
                          .onClick(() => {
                            if (DownloadManager.shared().resume(task.id)) {
                              this.toast('将从断点继续下载');
                            }
                            this.tasks = DownloadManager.shared().getTasks();
                          })
                      }
                      Text('删除')
                        .fontSize(13)
                        .fontColor($r('app.color.color_warning'))
                        .padding({ left: 18, right: 18, top: 13, bottom: 13 })
                        .borderRadius(22)
                        .backgroundColor($r('app.color.color_chip_bg'))
                        .onClick(() => {
                          DownloadManager.shared().remove(task.id);
                          this.tasks = DownloadManager.shared().getTasks();
                        })
                    }
                    // 与「播放历史」一致：两个胶囊靠底、靠右。
                    // 靠右 = justifyContent(End)；靠底 = 前面垫一个 Blank()，
                    // 由它吃掉信息栏剩余高度，把这一行压到与封面对齐的下沿。
                    .width('100%')
                    .justifyContent(FlexAlign.End)
                    .margin({ top: 2 })
                  }
                  .layoutWeight(1)
                  }
                  .alignItems(VerticalAlign.Top)
                  .width('100%')
                  .padding(12)
                  .backgroundColor($r('app.color.color_glass'))
                  .borderRadius(10)
                }
              }, (task: DownloadTaskRecord) => this.taskKey(task))
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .padding({ left: 16, right: 16, bottom: 16 })
          }
        }
        .width('100%')
        .height('100%')
        .linearGradient(pageBgGradient())
        // 底色必须铺进状态栏/手势条：二级页面的内容让出了安全区，
        // 这一层不扩的话，状态栏里透出的是窗口默认底色，
        // 和页面渐变叠成两层，状态栏文字直接看不清。
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        // 顶部磨砂渐隐：内容从状态栏下面滚过时被这一段虚化，

        // 并且往下越来越清，看不到过渡区的边缘。

        BlurFade({ edge: 'top', band: SystemInsets.top() + 58, fade: 34, radius: 26 })


        // 玻璃导航条（方案 A）：浮在内容之上，可隐约看到背后滚动内容
          Row({ space: 4 }) {
            Row() {
              Image($r('app.media.ic_back'))
                .width(20)
                .height(20)
            }
            .width(32)
            .height(40)
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.navPathStack.pop();
            })
            Text('下载管理')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.color_text'))
              .layoutWeight(1)
            if (this.hasCompletedTasks()) {
              Text('清除已完成')
                .fontSize(14)
                .fontColor($r('app.color.color_primary'))
                .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                .onClick(() => {
                  DownloadManager.shared().clearCompleted();
                  this.tasks = DownloadManager.shared().getTasks();
                  this.toast('已清除完成的缓存');
                })
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12 + SystemInsets.top(), bottom: 8 })
          // 纯文字导航：去掉底色 / 磨砂 / 描边，与页面背景融为一体
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onShown(() => {
      // 缓存节点复用不会重跑 aboutToAppear：重新开闸并立刻拉一次，
      // 免得用户看到上一次留下的旧进度。
      this.refreshTasks();
      this.startTick();
    })
    .onHidden(() => {
      this.stopTick();
    })
  }

  private hasCompletedTasks(): boolean {
    for (const t of this.tasks) {
      if (t.status === 'completed') {
        return true;
      }
    }
    return false;
  }
}

/**
 * 下载列表左侧的迷你海报。
 *
 * 造型完全照搬首页 VodCard：小圆角 + 裁切 + 普通落影 + 沿外沿一圈封面主色轮廓。
 * 之所以拆成独立 @Component，是因为主色采样结果要挂在各自的 @State 上 ——
 * 直接写在 DownloadsPage 的 ForEach 里没有地方存，也就没法逐条上色。
 *
 * 宽高由使用处给定（80×110，与观看历史栏一致），这里只负责铺满 + 造型。
 */
@Component
struct DownloadPoster {
  @Prop posterUrl: string = '';
  /** 已看进度（'0%'/'37%'/''）。空串 = 不画进度条 */
  @Prop progress: string = '';
  @State mainColor: string = '';

  aboutToAppear(): void {
    this.sample();
  }

  private async sample(): Promise<void> {
    if (this.posterUrl === '') {
      return;
    }
    const c: string = await PosterColor.dominant(this.posterUrl);
    if (c !== '') {
      this.mainColor = c;
    }
  }

  /** 轮廓光色：和首页卡片同一档（主色 0.55）；没采到色就退一层极淡的白边 */
  private rimColor(): ResourceColor {
    if (this.mainColor === '') {
      return '#1FFFFFFF';
    }
    const hex: string = this.mainColor.substring(1);
    const r: number = parseInt(hex.substring(0, 2), 16);
    const g: number = parseInt(hex.substring(2, 4), 16);
    const b: number = parseInt(hex.substring(4, 6), 16);
    return `rgba(${r}, ${g}, ${b}, 0.55)`;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.posterUrl !== '') {
        NetImage({ url: this.posterUrl })
          .width('100%')
          .height('100%')
      }
      // 已播放进度条：完全照搬首页「继续观看」卡片上的那一条
      // （3vp 高，半透明黑底压在海报上，填充走 color_primary），
      // 两处列表切换着看才不会一个有一条没有。
      if (this.progress !== '') {
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(3)
            .backgroundColor('#00000055')
          Row()
            .width(this.progress)
            .height(3)
            .backgroundColor($r('app.color.color_primary'))
        }
        .width('100%')
        .height(3)
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(8)
    .clip(true)
    .backgroundColor($r('app.color.color_chip_bg'))
    .shadow({ radius: 6, color: '#59000000', offsetY: 2 })
    .border({ width: 1, color: this.rimColor() })
  }
}
