/**
 * 搜索结果页：聚合多源结果、跨源同名合并、搜索历史
 */

import { MergedVideo } from '../model/Types';
import { SearchService } from '../model/SearchService';
import { SettingsStore } from '../data/SettingsStore';
import { HistoryStore } from '../data/HistoryStore';
import { Utils } from '../common/Utils';
import { pageBgGradient } from '../common/GlassTheme';
import { EmptyView, LoadingView } from '../components/CommonWidgets';
import { DetailPageParam } from './DetailPage';
import { latestNavParam } from '../common/NavParam';
import { SystemInsets } from '../common/SystemInsets';
import { BlurFade } from '../common/BlurFade';
import { SuggestItem } from '../model/DoubanClient';
import { SuggestEngine, SuggestSink } from '../model/SuggestEngine';


export interface SearchPageParam {
  keyword: string;
}

@Component
export struct SearchResultPage {
  navPathStack: NavPathStack = new NavPathStack();
  keyword: string = '';

  @State searchValue: string = '';
  @State results: MergedVideo[] = [];
  @State loading: boolean = false;
  @State searched: boolean = false;
  @State failedCount: number = 0;
  @State historyWords: string[] = [];

  // ---------- 搜索栏联想 ----------
  /** 候选项：最多 6 条，与首页同一套面板 */
  @State suggestItems: SuggestItem[] = [];
  /** 请求在飞：面板里先显示一行「正在联想」 */
  @State suggestLoading: boolean = false;
  /** 只在「有输入」时展开，清空立即收起 */
  @State suggestOpen: boolean = false;
  /** 防抖 / 作废 / 两段式补全都交给共用引擎 */
  private suggestEngine: SuggestEngine = new SuggestEngine();
  /** 程序化回填的输入值：等值 onChange 视为回声，不触发联想 */
  private quietValue: string = '';

  /** 已经处理过的路由参数：缓存节点复用后靠它判断「这次是不是换了个关键词」 */
  private appliedKeyword: string = '';

  aboutToAppear(): void {
    this.historyWords = HistoryStore.shared().getSearchHistory();
    if (this.keyword !== '') {
      this.appliedKeyword = this.keyword;
      this.setSearchQuiet(this.keyword);
      this.runSearch();
    }
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private async runSearch(): Promise<void> {
    this.closeSuggest();
    const wd = this.searchValue.trim();
    if (wd === '') {
      this.toast('请输入搜索关键词');
      return;
    }
    HistoryStore.shared().addSearchHistory(wd);
    this.historyWords = HistoryStore.shared().getSearchHistory();
    this.loading = true;
    this.searched = true;
    const res = await SearchService.aggregate(wd, SettingsStore.shared().get());
    const sorted = res.merged.slice().sort((a: MergedVideo, b: MergedVideo): number => b.items.length - a.items.length);
    this.results = sorted;
    this.failedCount = res.failedCount;
    this.loading = false;
  }

  private openDetail(v: MergedVideo): void {
    const first = v.items[0];
    if (first === undefined) {
      return;
    }
    const p: DetailPageParam = {
      sourceKey: first.sourceKey,
      vodId: first.vodId,
      title: v.name
    };
    this.navPathStack.pushPath({ name: 'Detail', param: p });
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        // 内容层铺满整屏：滚动内容会从下方玻璃导航条背后穿过
        Column({ space: 0 }) {

          if (this.loading) {
            LoadingView()
          } else if (!this.searched) {
            this.historyPanel()
          } else if (this.results.length === 0) {
            Column({ space: 8 }) {
              EmptyView({ emptyText: '没有找到相关视频' })
              if (this.failedCount > 0) {
                Text('有 ' + this.failedCount + ' 个源请求失败，可前往「视频源管理」检查')
                  .fontSize(12)
                  .fontColor($r('app.color.color_text_secondary'))
              }
            }
          } else {
            List({ space: 10 }) {
              ListItem() {
                Row() {
                  Text('共 ' + this.results.length + ' 个结果')
                    .fontSize(12)
                    .fontColor($r('app.color.color_text_secondary'))
                    .layoutWeight(1)
                  if (this.failedCount > 0) {
                    Text(this.failedCount + ' 个源失败')
                      .fontSize(12)
                      .fontColor($r('app.color.color_warning'))
                  }
                }
                .width('100%')
                .padding({ left: 0, right: 0, bottom: 6 })
              }
            // 顶部占位：随内容滚走，让列表能从玻璃导航条背后滑过
            ListItem() {
              Column()
                .width('100%')
                .height(56 + SystemInsets.top())
            }
                ForEach(this.results, (v: MergedVideo) => {
                  ListItem() {
                    Row({ space: 10 }) {
                      if (v.pic !== undefined && v.pic !== '') {
                        Image(v.pic)
                          .width(88)
                          .height(120)
                          .objectFit(ImageFit.Cover)
                          .borderRadius(8)
                          .backgroundColor($r('app.color.color_chip_bg'))
                      } else {
                        Column()
                          .width(88)
                          .height(120)
                          .backgroundColor($r('app.color.color_chip_bg'))
                          .borderRadius(8)
                      }
                      Column({ space: 6 }) {
                        Text(v.name)
                          .fontSize(15)
                          .fontWeight(FontWeight.Medium)
                          .fontColor($r('app.color.color_text'))
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .textAlign(TextAlign.Start)
                          .width('100%')
                        Row({ space: 6 }) {
                          if (v.year !== undefined && v.year !== '') {
                            Text(v.year)
                              .fontSize(11)
                              .fontColor($r('app.color.color_text_secondary'))
                          }
                          if (v.typeName !== undefined && v.typeName !== '') {
                            Text(v.typeName)
                              .fontSize(11)
                              .fontColor($r('app.color.color_text_secondary'))
                          }
                          if (v.area !== undefined && v.area !== '') {
                            Text(v.area)
                              .fontSize(11)
                              .fontColor($r('app.color.color_text_secondary'))
                          }
                        }
                        .width('100%')
                        if (v.remarks !== undefined && v.remarks !== '') {
                          Text(v.remarks)
                            .fontSize(11)
                            .fontColor($r('app.color.color_primary'))
                        }
                        Text(v.items.length + ' 个播放源')
                          .fontSize(11)
                          .fontColor($r('app.color.color_text_secondary'))
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                    }
                    .width('100%')
                    .padding(10)
                    .backgroundColor($r('app.color.color_glass'))
                    .borderRadius(10)
                    .onClick(() => {
                      this.openDetail(v);
                    })
                  }
                }, (v: MergedVideo) => Utils.normalizeTitle(v.name) + '|' + (v.year !== undefined ? v.year : ''))
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
          Row({ space: 8 }) {
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
            // 搜索框 + 联想面板放进同一个纵向流：
            // 面板是输入框的兄弟节点、按它的盒底排下来，天然贴在正下方，
            // 不会像叠层那样压住输入框（首页踩过这个坑，这里一开始就这么写）。
            Column({ space: 6 }) {
              Search({
                placeholder: '搜索电影 / 电视剧',
                value: $$this.searchValue
              })
                .width('100%')
                .height(36)
                .searchButton('搜索', { fontSize: 14, fontColor: $r('app.color.color_primary') })
                .onSubmit((value: string) => {
                  this.runSearch();
                })
                .onChange((value: string) => {
                  this.onSearchInput(value);
                })
              if (this.suggestOpen && (this.suggestItems.length > 0 || this.suggestLoading)) {
                this.suggestPanel()
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          // 对齐到顶：面板展开时整行会变高，回退按钮不能被拽到中间去
          .alignItems(VerticalAlign.Top)
          .padding({ left: 12, right: 12, top: 8 + SystemInsets.top(), bottom: 8 })
          // 不给底色/磨砂/底边描边：顶部与结果区是同一块页面渐变，
          // 滚动内容由上面的 BlurFade 虚化，两者之间不再有可见分界。
          
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onShown(() => {
      this.historyWords = HistoryStore.shared().getSearchHistory();
      // Navigation 会复用缓存的 NavDestination 节点：换个关键词再搜时页面不会重建，
      // 必须自己取最新参数，否则看到的还是上一次的结果。
      const raw: Object | null = latestNavParam(this.navPathStack, 'Search');
      if (raw === null) {
        return;
      }
      const p: SearchPageParam = raw as SearchPageParam;
      if (p.keyword === '' || p.keyword === this.appliedKeyword) {
        return;
      }
      this.appliedKeyword = p.keyword;
      this.keyword = p.keyword;
      this.setSearchQuiet(p.keyword);
      this.results = [];
      this.failedCount = 0;
      this.searched = false;
      this.runSearch();
    })
  }

  // ---------- 搜索联想 ----------

  /** 程序化回填输入框：等那次等值 onChange 到来时忽略它 */
  private setSearchQuiet(v: string): void {
    this.quietValue = v;
    this.searchValue = v;
  }

  private onSearchInput(value: string): void {
    // 进页面时带入关键词、点候选、点历史词 —— 这些回填都会回抛一次等值 onChange。
    // 那是回声不是输入，吞掉；只有用户真的改了关键字才展开联想。
    if (value === this.quietValue) {
      this.quietValue = '';
      return;
    }
    this.quietValue = '';
    this.suggestOpen = value.trim() !== '';
    // 兜底池：本页能拿到的「片名」就是搜索历史
    this.suggestEngine.setPool(HistoryStore.shared().getSearchHistory());
    this.suggestEngine.input(value, this.suggestSink());
  }

  /** 引擎出口 -> 页面 @State */
  private suggestSink(): SuggestSink {
    return {
      onUpdate: (items: SuggestItem[], loading: boolean): void => {
        this.suggestItems = items;
        this.suggestLoading = loading;
      },
      onClose: (): void => {
        this.suggestItems = [];
        this.suggestLoading = false;
        this.suggestOpen = false;
      }
    };
  }

  private closeSuggest(): void {
    this.suggestEngine.close(this.suggestSink());
  }

  /** 点中候选：回填并直接搜（用户要的是片子，不是豆瓣条目页） */
  private pickSuggest(item: SuggestItem): void {
    this.setSearchQuiet(item.title);
    this.runSearch();
  }

  /**
   * 联想面板：磨砂卡片 + 一行一条。
   * 高度由行数撑，最多 6 行，不会把结果区盖死。
   */
  @Builder
  suggestPanel() {
    Column() {
      Column() {
        if (this.suggestItems.length === 0) {
          Row({ space: 8 }) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color($r('app.color.color_text_secondary'))
            Text('正在联想片名…')
              .fontSize(13)
              .fontColor($r('app.color.color_text_secondary'))
          }
          .width('100%')
          .height(44)
          .padding({ left: 14, right: 14 })
          .alignItems(VerticalAlign.Center)
        } else {
          ForEach(this.suggestItems, (item: SuggestItem) => {
            Row({ space: 8 }) {
              Text(item.title)
                .fontSize(14)
                .fontColor($r('app.color.color_text'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (item.year !== '') {
                Text(item.year)
                  .fontSize(11)
                  .fontColor($r('app.color.color_text_secondary'))
                  .maxLines(1)
              }
              Text(item.kind)
                .fontSize(10)
                .fontColor($r('app.color.color_text_secondary'))
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(6)
                .backgroundColor($r('app.color.color_caption_glass'))
            }
            .width('100%')
            .height(42)
            .padding({ left: 14, right: 14 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.pickSuggest(item);
            })
          }, (item: SuggestItem) => item.title + '|' + item.year + '|' + item.kind)
        }
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor($r('app.color.color_panel_glass'))
      .backgroundEffect({ radius: 18, saturation: 1.6 })
      .borderRadius(16)
      .border({ width: 1, color: $r('app.color.color_nav_border') })
      .shadow({ radius: 18, color: $r('app.color.color_glass_shadow'), offsetY: 6 })
    }
    .width('100%')
  }

  @Builder
  historyPanel() {
    Column({ space: 12 }) {
      Row() {
        Text('搜索历史')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.color_text'))
          .layoutWeight(1)
        if (this.historyWords.length > 0) {
          Text('清空')
            .fontSize(13)
            .fontColor($r('app.color.color_text_secondary'))
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .onClick(() => {
              HistoryStore.shared().clearSearchHistory();
              this.historyWords = [];
            })
        }
      }
      .width('100%')

      if (this.historyWords.length === 0) {
        EmptyView({ emptyText: '输入关键词开始搜索' })
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.historyWords, (w: string) => {
            Text(w)
              .fontSize(13)
              .fontColor($r('app.color.color_text'))
              .backgroundColor($r('app.color.color_chip_bg'))
              .borderRadius(16)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .margin({ right: 8, bottom: 8 })
              .onClick(() => {
                this.setSearchQuiet(w);
                this.runSearch();
              })
          }, (w: string) => w)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
    }
    .layoutWeight(1)
    .padding({ left: 16, right: 16, top: 4 })
  }
}
