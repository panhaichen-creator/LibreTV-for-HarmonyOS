/**
 * 历史页：播放历史（续播）/ 我的收藏
 */

import { PlayRecord, FavoriteItem, LiveFavoriteItem } from '../model/Types';
import { HistoryStore } from '../data/HistoryStore';
import { Utils } from '../common/Utils';
import { LiquidDialog } from '../common/LiquidDialog';
import { pageBgGradient } from '../common/GlassTheme';
import { EmptyView } from '../components/CommonWidgets';
import { DetailPageParam } from './DetailPage';
import { PlayerPageParam } from './PlayerPage';
import { LivePlayerPageParam } from './LivePlayerPage';
import { latestNavParam } from '../common/NavParam';
import { SystemInsets } from '../common/SystemInsets';
import { BlurFade } from '../common/BlurFade';


export interface HistoryPageParam {
  /** history / favorites */
  mode: string;
}

@Component
export struct HistoryPage {
  navPathStack: NavPathStack = new NavPathStack();
  mode: string = 'history';

  @State records: PlayRecord[] = [];
  @State favorites: FavoriteItem[] = [];
  @State liveFavorites: LiveFavoriteItem[] = [];

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.records = HistoryStore.shared().getHistory();
    this.favorites = HistoryStore.shared().getFavorites();
    // 只保留带频道名的结构化记录；旧版裸 URL 记录（name 为空）不展示，避免空行
    const lives: LiveFavoriteItem[] = [];
    for (const v of HistoryStore.shared().getLiveFavorites()) {
      if (v.name !== '') {
        lives.push(v);
      }
    }
    this.liveFavorites = lives;
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private openDetail(sourceKey: string, vodId: string, title: string): void {
    const p: DetailPageParam = {
      sourceKey: sourceKey,
      vodId: vodId,
      title: title
    };
    this.navPathStack.pushPath({ name: 'Detail', param: p });
  }

  /** 从「我的收藏」点击直播频道，直接进直播播放 */
  private openLive(item: LiveFavoriteItem): void {
    const p: LivePlayerPageParam = {
      channelUrl: item.url,
      channelName: item.name,
      sourceKey: item.sourceKey,
      sourceName: item.sourceName,
      logo: item.logo !== undefined ? item.logo : '',
      tvgId: ''
    };
    this.navPathStack.pushPath({ name: 'LivePlayer', param: p });
  }

  /**
   * 封面上的「已播放」进度条宽度（百分比字符串）。
   * 与首页「继续观看」栏同一套算法；0% 与过小的值直接不画 ——
   * 1% 的红条在 80vp 宽的海报上只有半个像素，看着像脏点。
   */
  private watchPercent(rec: PlayRecord): string {
    if (rec.durationMs <= 0 || rec.positionMs <= 0) {
      return '';
    }
    let pct: number = Math.floor((rec.positionMs / rec.durationMs) * 100);
    if (pct < 2) {
      return '';
    }
    if (pct > 100) {
      pct = 100;
    }
    return pct + '%';
  }

  private continuePlay(rec: PlayRecord): void {
    const p: PlayerPageParam = {
      sourceKey: rec.sourceKey,
      vodId: rec.vodId,
      episode: rec.episode,
      episodeName: rec.episodeName !== undefined ? rec.episodeName : '',
      title: rec.name,
      positionMs: rec.positionMs,
      offlineDir: '',
      episodeUrl: rec.playUrl !== undefined ? rec.playUrl : '',
      lineIndex: rec.lineIndex !== undefined ? rec.lineIndex : 0
    };
    this.navPathStack.pushPath({ name: 'Player', param: p });
  }

  /**
   * 弹窗 controller 必须是成员变量。
   * 写成函数里的 `const ctl = ...` 时，函数一返回这个对象就没有引用了，
   * 弹窗还能弹出来（它自己持有视图），但按钮里 `this.controller?.close()`
   * 关不掉它 —— 表现就是「点取消没反应 / 清空完了窗口还杵在那儿」。
   */
  private dlgCtl: CustomDialogController | undefined = undefined;

  private confirmClear(): void {
    // 方案 D：自绘液态玻璃弹窗（系统 showAlertDialog 由系统进程绘制，套不上材质）
    this.dlgCtl = new CustomDialogController({
      // 遮罩：不加的话弹窗和背后的列表糊成一片，看不出「这是个模态」
      maskColor: '#66000000',
      customStyle: true,
      builder: LiquidDialog({
        message: this.mode === 'history' ? '确定清空播放历史吗？' : '确定清空收藏吗？',
        confirmText: '确定清空',
        danger: true,
        onConfirm: () => {
          // 双保险：即使 @CustomDialog 的 controller 没被注入，这里也能关掉
          this.dlgCtl?.close();
          if (this.mode === 'history') {
            HistoryStore.shared().clearHistory();
          } else {
            HistoryStore.shared().clearFavorites();
          }
          this.refresh();
          this.toast('已清空');
        }
      })
    });
    this.dlgCtl.open();
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        // 内容层铺满整屏：滚动内容会从下方玻璃导航条背后穿过
        Column({ space: 0 }) {

          if (this.mode === 'history') {
            if (this.records.length === 0) {
              EmptyView({ emptyText: '还没有播放记录' })
            } else {
              List({ space: 10 }) {
            // 顶部占位：随内容滚走，让列表能从玻璃导航条背后滑过
            ListItem() {
              Column()
                .width('100%')
                .height(56 + SystemInsets.top())
            }
                ForEach(this.records, (rec: PlayRecord, index: number) => {
                  ListItem() {
                    Row({ space: 10 }) {
                      if (rec.pic !== undefined && rec.pic !== '') {
                        // 封面叠一条「已播放」红条，和首页「继续观看」栏完全同款
                        // （3vp 高、半透明黑底 + color_primary 填充）。
                        // 原来这里只有一张裸图，历史列表看不出哪部看了一半。
                        Stack({ alignContent: Alignment.Bottom }) {
                          Image(rec.pic)
                            .width('100%')
                            .height('100%')
                            .objectFit(ImageFit.Cover)
                          if (this.watchPercent(rec) !== '') {
                            Stack({ alignContent: Alignment.Start }) {
                              Row()
                                .width('100%')
                                .height(3)
                                .backgroundColor('#00000055')
                              Row()
                                .width(this.watchPercent(rec))
                                .height(3)
                                .backgroundColor($r('app.color.color_primary'))
                            }
                            .width('100%')
                            .height(3)
                          }
                        }
                        .width(80)
                        .height(110)
                        .borderRadius(8)
                        .clip(true)
                        .backgroundColor($r('app.color.color_chip_bg'))
                      } else {
                        Column()
                          .width(80)
                          .height(110)
                          .backgroundColor($r('app.color.color_chip_bg'))
                          .borderRadius(8)
                      }
                      Column({ space: 6 }) {
                        Text(rec.name)
                          .fontSize(14)
                          .fontColor($r('app.color.color_text'))
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .textAlign(TextAlign.Start)
                          .width('100%')
                        Text(rec.sourceName + ' · ' + this.episodeLabel(rec))
                          .fontSize(11)
                          .fontColor($r('app.color.color_text_secondary'))
                          .maxLines(1)
                          .width('100%')
                          .textAlign(TextAlign.Start)
                        if (rec.durationMs > 0) {
                          Text('看到 ' + Utils.formatTime(rec.positionMs) + ' / ' + Utils.formatTime(rec.durationMs))
                            .fontSize(11)
                            .fontColor($r('app.color.color_primary'))
                            .width('100%')
                            .textAlign(TextAlign.Start)
                        }
                        Blank()
                        // 与「下载管理」列表同一套按钮规范：13fp + 左右各 18vp 内边距的胶囊，
                        // 高约 40vp。老写法是 12fp 纯文字、零内边距，实测可点区只有 22x13vp
                        // （远小于 40vp 的推荐下限），手指稍偏就点不中；
                        // 删除又紧挨着继续播放，误触概率很高。
                        Row({ space: 10 }) {
                          Text('继续播放')
                            .fontSize(13)
                            .fontColor($r('app.color.color_primary'))
                            .padding({ left: 18, right: 18, top: 13, bottom: 13 })
                            .borderRadius(22)
                            .backgroundColor($r('app.color.color_chip_bg'))
                            .onClick(() => {
                              this.continuePlay(rec);
                            })
                          Text('删除')
                            .fontSize(13)
                            .fontColor($r('app.color.color_warning'))
                            .padding({ left: 18, right: 18, top: 13, bottom: 13 })
                            .borderRadius(22)
                            .backgroundColor($r('app.color.color_chip_bg'))
                            .onClick(() => {
                              HistoryStore.shared().removeHistory(rec.sourceKey, rec.vodId);
                              this.refresh();
                            })
                        }
                        // 靠底靠右：Blank 吃掉信息栏剩余高度，按钮贴到与封面对齐的下沿
                        .width('100%')
                        .justifyContent(FlexAlign.End)
                        .margin({ top: 2 })
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                    }
                    .width('100%')
                    .padding(10)
                    .backgroundColor($r('app.color.color_glass'))
                    .borderRadius(10)
                  }
                }, (rec: PlayRecord) => rec.sourceKey + '_' + rec.vodId)
              }
              .layoutWeight(1)
              .scrollBar(BarState.Off)
              .padding({ left: 16, right: 16, bottom: 16 })
            }
          } else {
            if (this.favorites.length === 0 && this.liveFavorites.length === 0) {
              EmptyView({ emptyText: '还没有收藏' })
            } else {
              List({ space: 10 }) {
            // 顶部占位：随内容滚走，让列表能从玻璃导航条背后滑过
            ListItem() {
              Column()
                .width('100%')
                .height(56 + SystemInsets.top())
            }
                // 直播频道收藏：台标 + 频道名，点击直接进直播播放
                ForEach(this.liveFavorites, (fav: LiveFavoriteItem, favIdx: number) => {
                  ListItem() {
                    Row({ space: 10 }) {
                      if (fav.logo !== undefined && fav.logo !== '') {
                        Image(fav.logo)
                          .width(80)
                          .height(80)
                          .objectFit(ImageFit.Contain)
                          .borderRadius(8)
                          .backgroundColor($r('app.color.color_chip_bg'))
                      } else {
                        Column()
                          .width(80)
                          .height(80)
                          .backgroundColor($r('app.color.color_chip_bg'))
                          .borderRadius(8)
                      }
                      Column({ space: 6 }) {
                        Text(fav.name)
                          .fontSize(14)
                          .fontColor($r('app.color.color_text'))
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .textAlign(TextAlign.Start)
                          .width('100%')
                        Text('直播 · ' + (fav.sourceName !== '' ? fav.sourceName : '直播源'))
                          .fontSize(11)
                          .fontColor($r('app.color.color_text_secondary'))
                          .width('100%')
                          .textAlign(TextAlign.Start)
                        Row() {
                          Text('取消收藏')
                            .fontSize(12)
                            .fontColor($r('app.color.color_text_secondary'))
                            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                            .onClick(() => {
                              HistoryStore.shared().removeLiveFavorite(fav.url);
                              this.refresh();
                            })
                          Blank()
                        }
                        .layoutWeight(1)
                    }
                    .width('100%')
                    .padding(10)
                    .backgroundColor($r('app.color.color_glass'))
                    .borderRadius(10)
                    .onClick(() => {
                      this.openLive(fav);
                    })
                  }
                }
                }, (fav: LiveFavoriteItem) => 'live_' + fav.url)

                ForEach(this.favorites, (fav: FavoriteItem, favIdx: number) => {
                  ListItem() {
                    Row({ space: 10 }) {
                      if (fav.pic !== undefined && fav.pic !== '') {
                        Image(fav.pic)
                          .width(80)
                          .height(110)
                          .objectFit(ImageFit.Cover)
                          .borderRadius(8)
                          .backgroundColor($r('app.color.color_chip_bg'))
                      } else {
                        Column()
                          .width(80)
                          .height(110)
                          .backgroundColor($r('app.color.color_chip_bg'))
                          .borderRadius(8)
                      }
                      Column({ space: 6 }) {
                        Text(fav.name)
                          .fontSize(14)
                          .fontColor($r('app.color.color_text'))
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .textAlign(TextAlign.Start)
                          .width('100%')
                        Text(fav.sourceName)
                          .fontSize(11)
                          .fontColor($r('app.color.color_text_secondary'))
                          .width('100%')
                          .textAlign(TextAlign.Start)
                        Row() {
                          Text('取消收藏')
                            .fontSize(12)
                            .fontColor($r('app.color.color_text_secondary'))
                            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                            .onClick(() => {
                              HistoryStore.shared().removeFavorite(fav.sourceKey, fav.vodId);
                              this.refresh();
                            })
                          Blank()
                        }
                        .layoutWeight(1)
                    }
                    .width('100%')
                    .padding(10)
                    .backgroundColor($r('app.color.color_glass'))
                    .borderRadius(10)
                    .onClick(() => {
                      this.openDetail(fav.sourceKey, fav.vodId, fav.name);
                    })
                  }
                }
                }, (fav: FavoriteItem) => fav.sourceKey + '_' + fav.vodId)
              }
              .layoutWeight(1)
              .scrollBar(BarState.Off)
              .padding({ left: 16, right: 16, bottom: 16 })
            }
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
            Text(this.pageTitle())
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.color_text'))
              .layoutWeight(1)
            if (this.mode === 'history' && this.records.length > 0) {
              Text('清空')
                .fontSize(14)
                .fontColor($r('app.color.color_primary'))
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .onClick(() => {
                  this.confirmClear();
                })
            }
            if (this.mode === 'favorites' && this.favorites.length > 0) {
              Text('清空')
                .fontSize(14)
                .fontColor($r('app.color.color_primary'))
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .onClick(() => {
                  this.confirmClear();
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
      // 缓存节点复用后 mode 还停在上一次：从「播放历史」退出再进「我的收藏」，
      // 看到的会是历史列表。参数必须重新取。
      const raw: Object | null = latestNavParam(this.navPathStack, 'History');
      if (raw !== null) {
        const p: HistoryPageParam = raw as HistoryPageParam;
        this.mode = p.mode;
      }
      this.refresh();
    })
  }

  private pageTitle(): string {
    if (this.mode === 'history') {
      return '播放历史';
    }
    return '我的收藏';
  }

  private episodeLabel(rec: PlayRecord): string {
    if (rec.episodeName !== undefined && rec.episodeName !== '') {
      return rec.episodeName;
    }
    return '第' + (rec.episode + 1) + '集';
  }
}
