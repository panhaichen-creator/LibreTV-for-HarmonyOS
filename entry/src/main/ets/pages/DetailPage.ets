/**
 * 视频详情页：简介 / 选集 / 播放 / 收藏 / 换源测速 / 下载
 */

import { CmsClient } from '../model/CmsClient';
import { DetailCache } from '../model/DetailCache';
import { SearchService } from '../model/SearchService';
import { SourceManager } from '../data/SourceManager';
import { HistoryStore } from '../data/HistoryStore';
import { SettingsStore } from '../data/SettingsStore';
import { DownloadManager } from '../data/DownloadManager';
import { VideoDetail, Episode, SpeedTestItem, PlayRecord, PlayLine } from '../model/Types';
import { Utils } from '../common/Utils';
import { LoadingView, TagText } from '../components/CommonWidgets';
import { pageBgGradient } from '../common/GlassTheme';
import { NetImage } from '../components/NetImage';
import { PlayerPageParam } from './PlayerPage';
import { latestNavParam } from '../common/NavParam';
import { SystemInsets } from '../common/SystemInsets';
import { BlurFade } from '../common/BlurFade';
import { DoubanClient } from '../model/DoubanClient';
import { ShareService } from '../common/ShareService';
import { ShareTarget } from '../common/ShareLink';
import { common } from '@kit.AbilityKit';
import { curves, display } from '@kit.ArkUI';

/** 封面尺寸（vp）：进度条要严格按这个宽度画，所以提成常量共用 */
const COVER_W: number = 112;
const COVER_H: number = 158;
/** 简介折叠线：超过这个行数才折叠（字号 15 / 行高 24 与渲染处保持一致） */
const DESC_MAX_LINES: number = 3;
const DESC_LINE_H: number = 24;
const DESC_FONT: number = 15;

export interface DetailPageParam {
  sourceKey: string;
  vodId: string;
  title: string;
}

@Component
export struct DetailPage {
  navPathStack: NavPathStack = new NavPathStack();
  sourceKey: string = '';
  vodId: string = '';
  title: string = '';

  @State loading: boolean = true;
  @State errorText: string = '';
  @State ready: boolean = false;
  @State infoTitle: string = '';
  @State infoCover: string = '';
  @State infoDesc: string = '';
  @State infoYear: string = '';
  @State infoArea: string = '';
  @State infoType: string = '';
  @State infoDirector: string = '';
  @State infoActor: string = '';
  @State infoRemarks: string = '';
  @State infoSourceName: string = '';
  @State episodes: Episode[] = [];
  /** 多线路（vod_play_from 按 $$$ 分组）；只有 1 条线路时不显示选择区 */
  @State lines: PlayLine[] = [];
  @State currentLine: number = 0;
  @State currentEp: number = 0;
  @State favorite: boolean = false;
  @State descExpanded: boolean = false;
  @State progress: PlayRecord | null = null;
  @State speedItems: SpeedTestItem[] = [];
  @State speedTesting: boolean = false;
  @State showSpeedPanel: boolean = false;
  /** 详情页评分：源站分数先顶上，豆瓣结果到了再覆盖 */
  @State infoScore: string = '';
  @State infoScoreFrom: string = '';
  /** 折叠态下简介是否真的超出 3 行（只有超了才给「展开」） */
  @State descOverflow: boolean = false;

  aboutToAppear(): void {
    this.favorite = HistoryStore.shared().isFavorite(this.sourceKey, this.vodId);
    this.loadDetail(this.sourceKey, this.vodId);
  }

  /** 缓存节点复用后换成了另一部影片：把上一部的内容清掉，别让它在加载期间露出来 */
  private resetForReentry(): void {
    this.ready = false;
    this.loading = true;
    this.errorText = '';
    this.infoTitle = this.title;
    this.infoCover = '';
    this.infoDesc = '';
    this.infoYear = '';
    this.infoArea = '';
    this.infoType = '';
    this.infoDirector = '';
    this.infoActor = '';
    this.infoRemarks = '';
    this.infoSourceName = '';
    this.episodes = [];
    this.lines = [];
    this.currentLine = 0;
    this.currentEp = 0;
    this.descExpanded = false;
    this.descOverflow = false;
    this.infoScore = '';
    this.infoScoreFrom = '';
    this.progress = null;
    this.speedItems = [];
    this.speedTesting = false;
    this.showSpeedPanel = false;
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private applyDetail(detail: VideoDetail): void {
    this.ready = true;
    this.errorText = '';
    // 写入缓存供播放页复用，避免播放页重复请求被源站限流
    DetailCache.put(this.sourceKey, this.vodId, detail);
    this.infoTitle = detail.info.title;
    this.infoCover = detail.info.cover !== undefined ? detail.info.cover : '';
    // 先把分享用的缩略图（<32KB 的 JPEG）在后台压好，
    // 点分享时直接命中缓存 —— 否则分享面板要等下载+解码，会出现「点了没反应」
    if (this.infoCover !== '') {
      ShareService.prefetch(this.infoCover);
    }
    // 顺手给历史记录补封面：用户从「继续观看」进来或直接搜进来都能覆盖到
    if (this.infoCover !== '') {
      HistoryStore.shared().setPicIfEmpty(this.sourceKey, this.vodId, this.infoCover);
    }
    // 源站简介是富文本（<p>&nbsp;…），直接显示会出现一堆非中文符号，必须清洗
    const desc = Utils.stripHtml(detail.info.desc !== undefined ? detail.info.desc : '');
    this.infoDesc = Utils.hasMeaningfulText(desc) ? desc : '';
    this.infoYear = detail.info.year !== undefined ? detail.info.year : '';
    this.infoArea = detail.info.area !== undefined ? detail.info.area : '';
    this.infoType = detail.info.typeName !== undefined ? detail.info.typeName : '';
    this.infoDirector = Utils.stripHtml(detail.info.director !== undefined ? detail.info.director : '');
    this.infoActor = Utils.stripHtml(detail.info.actor !== undefined ? detail.info.actor : '');
    this.infoRemarks = Utils.stripHtml(detail.info.remarks !== undefined ? detail.info.remarks : '');
    this.infoSourceName = detail.info.sourceName;
    this.episodes = detail.episodes;
    this.lines = detail.info.lines !== undefined ? detail.info.lines : [];
    this.currentLine = 0;
    // 换片必须把折叠态复位，否则上一部的「已展开」会带过来
    this.descExpanded = false;
    this.descOverflow = this.descOverflowFor(this.infoDesc);
    // 评分：源站分数当占位，豆瓣的异步结果到了再覆盖（豆瓣更权威）
    const rawScore = detail.info.score !== undefined ? detail.info.score.trim() : '';
    const parsed = Number.parseFloat(rawScore);
    if (rawScore !== '' && !Number.isNaN(parsed) && parsed > 0) {
      this.infoScore = rawScore;
      this.infoScoreFrom = '源站';
    } else {
      this.infoScore = '';
      this.infoScoreFrom = '';
    }
    this.fetchDoubanRating(detail.info.title, this.infoYear);
  }

  /** 静默拉豆瓣评分：失败就当没有，绝不 toast、不阻塞页面 */
  private async fetchDoubanRating(title: string, year: string): Promise<void> {
    const score = await DoubanClient.ratingOf(title, year);
    // 期间可能已经切到别的片子了，标题对不上就丢掉这次结果
    if (score !== '' && this.infoTitle === title) {
      this.infoScore = score;
      this.infoScoreFrom = '豆瓣';
    }
  }

  private async loadDetail(sourceKey: string, vodId: string): Promise<void> {
    const source = SourceManager.shared().getVodSource(sourceKey);
    if (source === null) {
      this.errorText = '视频源不存在，可能已被删除';
      this.loading = false;
      return;
    }
    this.loading = true;
    this.errorText = '';
    let detail: VideoDetail | null = null;
    try {
      detail = await CmsClient.detail(source, vodId);
    } catch (e) {
      detail = null;
    }
    if (detail === null || detail.episodes.length === 0) {
      // 接口无播放地址时爬详情页 HTML 兜底
      try {
        detail = await CmsClient.detailFromPage(source, vodId);
      } catch (e2) {
        detail = null;
      }
    }
    this.loading = false;
    if (detail === null || detail.episodes.length === 0) {
      this.ready = false;
      this.errorText = '获取详情失败，该源可能暂时不可用';
      return;
    }
    this.sourceKey = sourceKey;
    this.vodId = vodId;
    this.applyDetail(detail);
    const rec = HistoryStore.shared().getProgress(sourceKey, vodId);
    this.progress = rec;
    // 记忆了播放线路且该线路的集数仍有效：切换到该线路再恢复集数
    if (rec !== null && rec.lineIndex !== undefined && rec.lineIndex > 0 &&
        rec.lineIndex < this.lines.length && rec.episode >= 0 &&
        rec.episode < this.lines[rec.lineIndex].episodes.length) {
      this.currentLine = rec.lineIndex;
      this.episodes = this.lines[rec.lineIndex].episodes;
      this.currentEp = rec.episode;
    } else if (rec !== null && rec.episode >= 0 && rec.episode < this.episodes.length) {
      this.currentEp = rec.episode;
    } else {
      this.currentEp = 0;
    }
    SourceManager.shared().recordSuccess(sourceKey);
  }

  /** 切换播放线路：只换分集列表，不自动起播 */
  private selectLine(idx: number): void {
    if (idx < 0 || idx >= this.lines.length || idx === this.currentLine) {
      return;
    }
    this.currentLine = idx;
    this.episodes = this.lines[idx].episodes;
    this.currentEp = 0;
  }

  private playEpisode(idx: number): void {
    if (idx < 0 || idx >= this.episodes.length) {
      return;
    }
    let position = 0;
    if (this.progress !== null && this.progress.episode === idx) {
      position = this.progress.positionMs;
    }
    const p: PlayerPageParam = {
      sourceKey: this.sourceKey,
      vodId: this.vodId,
      episode: idx,
      episodeName: this.episodes[idx].name,
      title: this.infoTitle,
      positionMs: position,
      offlineDir: '',
      // 直接带上播放地址，播放器无需再次请求详情（避免被源站限流）
      episodeUrl: this.episodes[idx].url,
      lineIndex: this.currentLine,
      // 带上封面，播放页写历史记录时可直接用，首页「继续观看」才有图
      pic: this.infoCover
    };
    this.navPathStack.pushPath({ name: 'Player', param: p });
  }

  private toggleFav(): void {
    const now = HistoryStore.shared().toggleFavorite({
      sourceKey: this.sourceKey,
      vodId: this.vodId,
      name: this.infoTitle,
      pic: this.infoCover !== '' ? this.infoCover : undefined,
      sourceName: this.infoSourceName,
      createdAt: Date.now()
    });
    this.favorite = now;
    this.toast(now ? '已收藏' : '已取消收藏');
  }

  private async runSpeedTest(): Promise<void> {
    if (this.infoTitle === '') {
      return;
    }
    this.speedTesting = true;
    this.showSpeedPanel = true;
    const items = await SearchService.speedTest(this.infoTitle, this.sourceKey, SettingsStore.shared().get());
    this.speedItems = items;
    this.speedTesting = false;
  }

  private async switchSource(item: SpeedTestItem): Promise<void> {
    if (!item.ok) {
      this.toast('该源当前不可用');
      return;
    }
    if (item.vodId === undefined || item.vodId === '') {
      this.toast('无法获取该源的视频信息');
      return;
    }
    this.showSpeedPanel = false;
    this.toast('正在切换到「' + item.sourceName + '」');
    await this.loadDetail(item.sourceKey, item.vodId);
  }

  private downloadCurrent(): void {
    if (this.currentEp < 0 || this.currentEp >= this.episodes.length) {
      return;
    }
    const id = DownloadManager.shared().start(
      this.sourceKey,
      this.vodId,
      this.infoTitle,
      this.infoCover !== '' ? this.infoCover : undefined,
      this.infoSourceName,
      this.currentEp,
      this.episodes[this.currentEp].name,
      this.episodes[this.currentEp].url
    );
    if (id === '') {
      this.toast('该集已在下载列表中');
    } else {
      this.toast('已加入下载：' + this.episodes[this.currentEp].name);
    }
  }

  /**
   * 系统分享：把当前这部（当前这一集）分享出去。
   * 链接里带 sourceKey + vodId + 集下标 + 片名 + 封面，
   * 对方点开就直接全屏播放，不用再进详情页。
   */
  private shareMovie(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      this.toast('无法调起系统分享');
      return;
    }
    const epName: string = this.episodes.length > this.currentEp
      ? this.episodes[this.currentEp].name : '';
    const brand: string = ShareService.brandName(ctx);
    const t: ShareTarget = {
      sourceKey: this.sourceKey,
      vodId: this.vodId,
      episode: this.currentEp,
      episodeName: epName,
      title: this.infoTitle,
      pic: this.infoCover
    };
    const desc: string = epName !== ''
      ? ('正在看 ' + epName + (brand !== '' ? ' · 来自 ' + brand : ''))
      : brand;
    ShareService.shareMovie(ctx, t, desc).then((ok: boolean) => {
      if (!ok) {
        this.toast('当前系统不支持系统分享');
      }
    });
  }

  private progressPercent(): string {
    const rec = this.progress;
    if (rec === null || rec.durationMs <= 0 || rec.episode !== this.currentEp) {
      return '';
    }
    const pct = Math.floor((rec.positionMs / rec.durationMs) * 100);
    if (pct <= 0 || pct >= 100) {
      return '';
    }
    return pct + '%';
  }

  private epTextColor(ep: Episode): ResourceColor {
    if (ep.index === this.currentEp) {
      return Color.White;
    }
    return $r('app.color.color_text');
  }

  private epBgColor(ep: Episode): ResourceColor {
    if (ep.index === this.currentEp) {
      return $r('app.color.color_primary');
    }
    return $r('app.color.color_chip_bg');
  }

  private descMaxLines(): number {
    if (this.descExpanded) {
      return 100;
    }
    return DESC_MAX_LINES;
  }

  /**
   * 简介在折叠线内放得下吗？
   *
   * 这套 SDK 的 Text 没有 onTextLayout 之类的布局回调，量不到「到底折了几行」，
   * 所以用 measureTextSize 按真实可用宽度 + 真实字号/行高量一次：
   * 量出来不超过 3 行就完全不折叠，也不显示「展开」——短简介不该让人多点一次。
   * 任何一步失败都返回 true（保守折叠），保证长简介不会被截断且无处展开。
   */
  private descOverflowFor(text: string): boolean {
    if (text === '') {
      return false;
    }
    let width: number = 0;
    try {
      width = px2vp(display.getDefaultDisplaySync().width) - 32;
    } catch (e) {
      return true;
    }
    if (width <= 0) {
      return true;
    }
    try {
      const size = this.getUIContext().getMeasureUtils().measureTextSize({
        textContent: text,
        constraintWidth: width,
        fontSize: DESC_FONT,
        lineHeight: DESC_LINE_H
      });
      const hv = size.height;
      let h: number = 0;
      if (typeof hv === 'number') {
        h = hv;
      } else if (typeof hv === 'string') {
        h = Number.parseFloat(hv);
      }
      if (Number.isNaN(h) || h <= 0) {
        return true;
      }
      return h > DESC_LINE_H * DESC_MAX_LINES + 1;
    } catch (e) {
      return true;
    }
  }

  /** 简介够短就完全不折叠：只有真的超过 3 行才需要这个开关 */
  private descClamped(): boolean {
    return this.descOverflow;
  }

  private descToggleLabel(): string {
    if (this.descExpanded) {
      return '收起';
    }
    return '展开';
  }

  private errorLabel(): string {
    if (this.errorText !== '') {
      return this.errorText;
    }
    return '加载失败';
  }

  private navTitle(): string {
    if (this.infoTitle !== '') {
      return this.infoTitle;
    }
    return '详情';
  }

  private playLabel(): string {
    const rec = this.progress;
    if (rec !== null && rec.episode === this.currentEp && rec.positionMs > 5000) {
      return '续播 ' + Utils.formatTime(rec.positionMs);
    }
    return '播放';
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
            Stack({ alignContent: Alignment.Bottom }) {
        if (this.loading) {
          LoadingView()
        } else if (!this.ready) {
          Column({ space: 12 }) {
            Text(this.errorLabel())
              .fontSize(14)
              .fontColor($r('app.color.color_text_secondary'))
            Button('重试')
              .fontSize(14)
              .backgroundColor($r('app.color.color_primary'))
              .onClick(() => {
                this.loadDetail(this.sourceKey, this.vodId);
              })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          this.detailBody()
        }

        // 换源面板
        if (this.showSpeedPanel) {
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              Text('选择播放源')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.color_text'))
                .layoutWeight(1)
              Text('关闭')
                .fontSize(13)
                .fontColor($r('app.color.color_primary'))
                .onClick(() => {
                  this.showSpeedPanel = false;
                })
            }
            .width('100%')

            if (this.speedTesting) {
              LoadingView({ tipText: '正在测速…' }).height(120)
            } else if (this.speedItems.length === 0) {
              Text('没有其他可用源')
                .fontSize(13)
                .fontColor($r('app.color.color_text_secondary'))
            } else {
              List({ space: 8 }) {
                ForEach(this.speedItems, (item: SpeedTestItem) => {
                  ListItem() {
                    Row({ space: 8 }) {
                      Text(item.sourceName)
                        .fontSize(14)
                        .fontColor($r('app.color.color_text'))
                        .layoutWeight(1)
                        .maxLines(1)
                      if (item.ok) {
                        Text(item.latencyMs + ' ms')
                          .fontSize(12)
                          .fontColor($r('app.color.color_success'))
                        Text(item.episodeCount + ' 集')
                          .fontSize(12)
                          .fontColor($r('app.color.color_text_secondary'))
                      } else {
                        Text('不可用')
                          .fontSize(12)
                          .fontColor($r('app.color.color_warning'))
                      }
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                    .backgroundColor($r('app.color.color_chip_bg'))
                    .borderRadius(8)
                    .onClick(() => {
                      this.switchSource(item);
                    })
                  }
                }, (item: SpeedTestItem) => item.sourceKey)
              }
              .height(220)
              .scrollBar(BarState.Off)
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.color_panel_glass'))
          .backgroundEffect({ radius: 26, saturation: 1.5 })
          .border({ width: 1, color: $r('app.color.color_nav_border') })
          .borderRadius({ topLeft: 16, topRight: 16 })
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
        // 自绘标题栏：不能在 NavDestination 上用 .title()。窗口开启全屏布局后，
        // 框架把状态栏高度从标题栏高度里扣掉，实测 TitleBar 只剩 63px（196-133），
        // 文字与返回键被压扁并与状态栏重叠。故统一隐藏内置栏、自己画一条。
        Row({ space: 8 }) {
          Row() {
            Image($r('app.media.ic_back'))
              .width(20)
              .height(20)
          }
          .width(36)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.navPathStack.pop();
          })
          Text(this.navTitle())
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.color_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .height(48 + SystemInsets.top())
        .padding({ left: 8, right: 16, top: SystemInsets.top() })
        // 不加底色/磨砂/描边：标题栏和页面渐变同源，往下滚动的内容由上面的
        // BlurFade 虚化，这样顶部与内容区是同一块背景，看不到任何分界线。
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onShown(() => {
      // Navigation 会复用缓存的 NavDestination 节点：换一部影片再进来时，
      // 构造参数还是上一部的、页面也不会重建 —— 必须自己取最新参数重新加载，
      // 否则会出现「点 A 打开的是 B 的详情」。
      const raw: Object | null = latestNavParam(this.navPathStack, 'Detail');
      if (raw !== null) {
        const p: DetailPageParam = raw as DetailPageParam;
        if (p.vodId !== this.vodId || p.sourceKey !== this.sourceKey) {
          this.sourceKey = p.sourceKey;
          this.vodId = p.vodId;
          this.title = p.title;
          this.resetForReentry();
          this.loadDetail(this.sourceKey, this.vodId);
        }
      }
      // 从播放页返回时刷新进度与收藏态
      this.favorite = HistoryStore.shared().isFavorite(this.sourceKey, this.vodId);
      this.progress = HistoryStore.shared().getProgress(this.sourceKey, this.vodId);
    })
  }

  @Builder
  detailBody() {
    Scroll() {
      Column({ space: 12 }) {
        // 顶部占位：随内容滚走，让详情内容能从玻璃导航条背后滑过
        Column()
          .width('100%')
          .height(56 + SystemInsets.top())

        // 头部：海报 + 信息
        Row({ space: 12 }) {
          if (this.infoCover !== '') {
            Stack({ alignContent: Alignment.BottomStart }) {
              NetImage({ url: this.infoCover })
                .width(COVER_W)
                .height(COVER_H)
                .borderRadius(10)
              if (this.progressPercent() !== '') {
                // 进度条分两层：先铺满封面宽度的轨道，再按百分比盖一段进度。
                // 老写法是单个 Column 直接 .width('42%')，而它的父容器是「按内容撑开」的
                // Stack —— 百分比拿不到确定的参照宽度，实测长度和封面完全对不上
                // （进度一长就捅出封面右边界）。这里给 Stack 也给死宽度，比例才有意义。
                Stack({ alignContent: Alignment.Start }) {
                  Row()
                    .width('100%')
                    .height(3)
                    .backgroundColor('#4DFFFFFF')
                  Row()
                    .width(this.progressPercent())
                    .height(3)
                    .backgroundColor($r('app.color.color_primary'))
                }
                .width(COVER_W)
                .height(3)
              }
            }
            .width(COVER_W)
            .height(COVER_H)
            .borderRadius(10)
            // 裁掉溢出：进度条贴着封面下沿时，两个下圆角也要跟着圆
            .clip(true)
          } else {
            Column()
              .width(COVER_W)
              .height(COVER_H)
              .backgroundColor($r('app.color.color_chip_bg'))
              .borderRadius(10)
          }
          Column({ space: 6 }) {
            Text(this.infoTitle)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.color_text'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Start)
              .width('100%')
            if (this.infoScore !== '') {
              Row({ space: 3 }) {
                Text(this.infoScore)
                  .fontSize(19)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.color_primary'))
                Text('分')
                  .fontSize(11)
                  .fontColor($r('app.color.color_primary'))
                  .margin({ bottom: 2 })
                Text(this.infoScoreFrom)
                  .fontSize(11)
                  .fontColor($r('app.color.color_text_secondary'))
                  .margin({ left: 3, bottom: 2 })
              }
              .width('100%')
            }
            Row({ space: 6 }) {
              if (this.infoYear !== '') {
                TagText({ tagText: this.infoYear })
              }
              if (this.infoArea !== '') {
                TagText({ tagText: this.infoArea })
              }
              if (this.infoType !== '') {
                TagText({ tagText: this.infoType })
              }
            }
            if (this.infoRemarks !== '') {
              Text(this.infoRemarks)
                .fontSize(12)
                .fontColor($r('app.color.color_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            Text('来源：' + this.infoSourceName)
              .fontSize(12)
              .fontColor($r('app.color.color_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)
            if (this.infoDirector !== '') {
              Text('导演：' + this.infoDirector)
                .fontSize(12)
                .fontColor($r('app.color.color_text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            if (this.infoActor !== '') {
              Text('主演：' + this.infoActor)
                .fontSize(12)
                .fontColor($r('app.color.color_text_secondary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .textAlign(TextAlign.Start)
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })

        // 操作栏
        Row({ space: 8 }) {
          Button() {
            Row({ space: 6 }) {
              Image($r('app.media.ic_play'))
                .width(18)
                .height(18)
              Text(this.playLabel())
                .fontSize(15)
                .fontColor(Color.White)
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(42)
          .backgroundColor($r('app.color.color_primary'))
          .borderRadius(21)
          .onClick(() => {
            this.playEpisode(this.currentEp);
          })

          Button() {
            if (this.favorite) {
              Image($r('app.media.ic_star_filled'))
                .width(20)
                .height(20)
            } else {
              Image($r('app.media.ic_star'))
                .width(20)
                .height(20)
            }
          }
          .width(42)
          .height(42)
          .backgroundColor($r('app.color.color_glass'))
          .borderRadius(21)
          .onClick(() => {
            this.toggleFav();
          })

          Button() {
            Image($r('app.media.ic_refresh'))
              .width(20)
              .height(20)
          }
          .width(42)
          .height(42)
          .backgroundColor($r('app.color.color_glass'))
          .borderRadius(21)
          .onClick(() => {
            this.runSpeedTest();
          })

          // 分享：拉起系统分享面板（带封面缩略图的 libretv:// 链接）。
          // 面板里同时有「碰一碰」入口，对方的设备贴一下就过去了。
          Button() {
            Image($r('app.media.ic_share'))
              .width(20)
              .height(20)
          }
          .width(42)
          .height(42)
          .backgroundColor($r('app.color.color_glass'))
          .borderRadius(21)
          .onClick(() => {
            this.shareMovie();
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })

        // 简介
        if (this.infoDesc !== '') {
          Column({ space: 6 }) {
            Text(this.infoDesc)
              // 字号/行高必须和 descOverflowFor() 里的量尺一致，否则量出来的
              // 「放不放得下」和实际渲染对不上
              .fontSize(DESC_FONT)
              .lineHeight(DESC_LINE_H)
              .fontColor($r('app.color.color_text_secondary'))
              .maxLines(this.descMaxLines())
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Start)
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
            if (this.descClamped()) {
              Text(this.descToggleLabel())
                .fontSize(13)
                .fontColor($r('app.color.color_primary'))
                .width('100%')
                .textAlign(TextAlign.RIGHT)
                .onClick(() => {
                  this.descExpanded = !this.descExpanded;
                })
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .alignItems(HorizontalAlign.Start)
        }

        // 播放线路（源站返回多条线路时才显示）
        if (this.lines.length > 1) {
          Column({ space: 0 }) {
            Text('播放线路')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.color_text'))
              .textAlign(TextAlign.Start)
              .width('100%')
              // Flex 换行没有行间距属性，间距全靠按钮自己的 margin，
              // 标题这里补一格，别和第一排按钮贴死。
              .margin({ bottom: 8 })
            // 用换行 Flex 而不是横向 Scroll：Scroll 会把「内容比视口窄」的子节点
            // 居中摆（默认对齐是 Center），线路少的时候整排按钮就飘到中间去了。
            // Flex 换行天然左对齐，也不需要额外的对齐属性。
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.lines, (line: PlayLine, idx: number) => {
                Text(line.name)
                  .fontSize(13)
                  .height(36)
                  .borderRadius(8)
                  .padding({ left: 16, right: 16 })
                  .textAlign(TextAlign.Center)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor(idx === this.currentLine ? Color.White : $r('app.color.color_text'))
                  .backgroundColor(idx === this.currentLine
                    ? $r('app.color.color_primary')
                    : $r('app.color.color_chip_bg'))
                  .margin({ right: 8, bottom: 8 })
                  .onClick(() => {
                    this.selectLine(idx);
                  })
              }, (line: PlayLine, idx: number) => idx.toString() + '_' + line.name)
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .alignItems(HorizontalAlign.Start)
        }

        // 选集
        Column({ space: 8 }) {
          Text('选集（共 ' + this.episodes.length + ' 集）')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.color_text'))
            .textAlign(TextAlign.Start)
            .width('100%')

          Grid() {
            ForEach(this.episodes, (ep: Episode) => {
              GridItem() {
                Text(ep.name)
                  .fontSize(13)
                  .fontColor(this.epTextColor(ep))
                  .backgroundColor(this.epBgColor(ep))
                  .borderRadius(8)
                  .width('100%')
                  .height(36)
                  .textAlign(TextAlign.Center)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .onClick(() => {
                    this.currentEp = ep.index;
                    this.playEpisode(ep.index);
                  })
              }
            }, (ep: Episode) => ep.index.toString())
          }
          .columnsTemplate('1fr 1fr 1fr 1fr')
          .columnsGap(8)
          .rowsGap(8)
          .width('100%')
        }
        .padding({ left: 16, right: 16, bottom: 16 })
        .alignItems(HorizontalAlign.Start)

        // 下载单独一行，居中放在选集下方。
        // 尺寸/圆角/字号对齐上面的「续播」按钮（42 高 / 21 圆角 / 15sp 白字），
        // 只把底色换成蓝色 —— 红色是「立刻播」的主操作，下载是次要动作，
        // 靠颜色区分，别让两颗大红按钮抢视线。
        // 标题只留文字、不带图标：ic_download 那张图其实是「箭头朝上 + 底线」
        // 的上传图形，之前靠 rotate(180°) 硬凑成下载，越小越像上传，干脆去掉。
        // 宽度给死 160 而不是 layoutWeight(1)：居中的按钮撑满整行就不叫居中了。
        Row() {
          Button() {
            Text('下载离线观看')
              .fontSize(15)
              .fontColor(Color.White)
          }
          .width(160)
          .height(42)
          .backgroundColor($r('app.color.color_download'))
          .borderRadius(21)
          .onClick(() => {
            this.downloadCurrent();
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ left: 16, right: 16, top: 4, bottom: 28 })
      }
      .width('100%')
      // 关键：内容不满一屏时 Scroll 会把子内容垂直居中（实测 Column 落在 y=834，
      // 而 Scroll 视口顶部是 y=196，正好等于 (2652-1376)/2），表现为「顶部大片空白」。
      // minHeight 撑满视口即可强制顶对齐；内容超长时照常滚动。
      .constraintSize({ minHeight: '100%' })
    }
    .scrollBar(BarState.Off)
    // Scroll 直接嵌在 Stack 里：Stack 的子组件不支持 layoutWeight，
    // 必须显式给宽高，否则高度塌陷为内容高度，顶部留出大片空白。
    .width('100%')
    .height('100%')
  }
}
