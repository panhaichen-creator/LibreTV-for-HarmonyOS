/**
 * 设置页：广告过滤 / 自动连播 / 成人过滤 / 主题 / 推荐源 / 默认倍速 / 播放历史开关
 */

import { Settings } from '../model/Types';
import { SettingsStore } from '../data/SettingsStore';
import { SourceManager } from '../data/SourceManager';
import { BootstrapSources } from '../model/BootstrapSources';
import { SettingsRow } from '../components/CommonWidgets';
import { pageBgGradient } from '../common/GlassTheme';
import { SystemInsets } from '../common/SystemInsets';
import { BlurFade } from '../common/BlurFade';

interface OptionItem {
  key: string;
  label: string;
}

@Component
export struct SettingsPage {
  navPathStack: NavPathStack = new NavPathStack();

  @State adFilter: string = SettingsStore.shared().get().adFilter;
  @State autoNext: boolean = SettingsStore.shared().get().autoNext;
  @State adultFilter: boolean = SettingsStore.shared().get().adultFilter;
  @State themeMode: string = SettingsStore.shared().get().themeMode;
  @State recommendSource: string = SettingsStore.shared().get().recommendSource;
  @State defaultSpeed: number = SettingsStore.shared().get().defaultSpeed;
  @State playHistoryEnabled: boolean = SettingsStore.shared().get().playHistoryEnabled;
  @State autoDiscover: boolean = SettingsStore.shared().get().autoDiscover;
  @State activePanel: string = '';

  private static readonly AD_FILTERS: OptionItem[] = [
    { key: 'off', label: '关闭' },
    { key: 'loose', label: '宽松（推荐）' },
    { key: 'strict', label: '严格' }
  ];

  private static readonly THEMES: OptionItem[] = [
    { key: 'system', label: '跟随系统' },
    { key: 'light', label: '浅色' },
    { key: 'dark', label: '深色' }
  ];

  private static readonly RECOMMENDS: OptionItem[] = [
    { key: 'douban_movie', label: '豆瓣电影' },
    { key: 'douban_tv', label: '豆瓣电视剧' },
    { key: 'douban_rank', label: '豆瓣排行（Top 250）' },
    { key: 'bangumi', label: '番组计划（Bangumi）' }
  ];

  private static readonly SPEEDS: OptionItem[] = [
    { key: '0.5', label: '0.5x' },
    { key: '0.75', label: '0.75x' },
    { key: '1.0', label: '1.0x（正常）' },
    { key: '1.25', label: '1.25x' },
    { key: '1.5', label: '1.5x' },
    { key: '2.0', label: '2.0x' }
  ];

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private save(patch: Partial<Settings>): void {
    SettingsStore.shared().update(patch);
  }

  private labelOf(items: OptionItem[], key: string): string {
    for (const item of items) {
      if (item.key === key) {
        return item.label;
      }
    }
    return '';
  }

  private speedLabel(value: number): string {
    const key = value.toString();
    return this.labelOf(SettingsPage.SPEEDS, key);
  }

  private togglePanel(name: string): void {
    if (this.activePanel === name) {
      this.activePanel = '';
    } else {
      this.activePanel = name;
    }
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        // 内容层铺满整屏：滚动内容会从下方玻璃导航条背后穿过
        Column({ space: 0 }) {

        Stack({ alignContent: Alignment.Bottom }) {
          Scroll() {
            Column({ space: 10 }) {
            // 顶部占位：随内容滚走，让内容能从玻璃导航条背后滑过
            Column()
              .width('100%')
              .height(56 + SystemInsets.top())
              // 播放
              Text('播放')
                .fontSize(13)
                .fontColor($r('app.color.color_text_secondary'))
                .padding({ left: 16, top: 8 })
                .width('100%')
                .textAlign(TextAlign.Start)

              SettingsRow({
                rowTitle: '广告过滤',
                rowValue: this.labelOf(SettingsPage.AD_FILTERS, this.adFilter),
                onRowClick: () => {
                  this.togglePanel('adFilter');
                }
              })
              if (this.activePanel === 'adFilter') {
                this.optionPanel('adFilter', SettingsPage.AD_FILTERS, this.adFilter)
              }

              SettingsRow({
                rowTitle: '自动连播',
                rowValue: this.autoNext ? '开' : '关',
                rowShowArrow: false,
                onRowClick: () => {
                  this.autoNext = !this.autoNext;
                  this.save({ autoNext: this.autoNext });
                }
              })

              SettingsRow({
                rowTitle: '默认倍速',
                rowValue: this.speedLabel(this.defaultSpeed),
                onRowClick: () => {
                  this.togglePanel('speed');
                }
              })
              if (this.activePanel === 'speed') {
                this.optionPanel('speed', SettingsPage.SPEEDS, this.defaultSpeed.toString())
              }

              SettingsRow({
                rowTitle: '记录播放历史',
                rowValue: this.playHistoryEnabled ? '开' : '关',
                rowShowArrow: false,
                onRowClick: () => {
                  this.playHistoryEnabled = !this.playHistoryEnabled;
                  this.save({ playHistoryEnabled: this.playHistoryEnabled });
                }
              })

              // 内容
              Text('内容')
                .fontSize(13)
                .fontColor($r('app.color.color_text_secondary'))
                .padding({ left: 16, top: 12 })
                .width('100%')
                .textAlign(TextAlign.Start)

              SettingsRow({
                rowTitle: '成人内容过滤',
                rowValue: this.adultFilter ? '开' : '关',
                rowShowArrow: false,
                onRowClick: () => {
                  this.adultFilter = !this.adultFilter;
                  this.save({ adultFilter: this.adultFilter });
                }
              })

              SettingsRow({
                rowTitle: '首页推荐来源',
                rowValue: this.labelOf(SettingsPage.RECOMMENDS, this.recommendSource),
                onRowClick: () => {
                  this.togglePanel('recommend');
                }
              })
              if (this.activePanel === 'recommend') {
                this.optionPanel('recommend', SettingsPage.RECOMMENDS, this.recommendSource)
              }

              // 外观
              Text('外观')
                .fontSize(13)
                .fontColor($r('app.color.color_text_secondary'))
                .padding({ left: 16, top: 12 })
                .width('100%')
                .textAlign(TextAlign.Start)

              SettingsRow({
                rowTitle: '主题模式',
                rowValue: this.labelOf(SettingsPage.THEMES, this.themeMode),
                onRowClick: () => {
                  this.togglePanel('theme');
                }
              })
              if (this.activePanel === 'theme') {
                this.optionPanel('theme', SettingsPage.THEMES, this.themeMode)
              }

              // 维护
              Text('维护')
                .fontSize(13)
                .fontColor($r('app.color.color_text_secondary'))
                .padding({ left: 16, top: 12 })
                .width('100%')
                .textAlign(TextAlign.Start)

              SettingsRow({
                rowTitle: '自动发现视频源',
                rowValue: this.autoDiscover ? '开' : '关',
                rowShowArrow: false,
                onRowClick: () => {
                  this.autoDiscover = !this.autoDiscover;
                  this.save({ autoDiscover: this.autoDiscover });
                  if (this.autoDiscover) {
                    this.toast('已开启，正在发现可用源…');
                    BootstrapSources.run(true).then((summary: string) => {
                      if (summary !== '') {
                        this.toast(summary);
                      }
                    }).catch((_e: object) => {
                    });
                  } else {
                    this.toast('已关闭自动发现');
                  }
                }
              })

              SettingsRow({
                rowTitle: '恢复视频源健康度',
                rowValue: '',
                onRowClick: () => {
                  SourceManager.shared().resetAllHealth();
                  this.toast('已重置所有源的健康度');
                }
              })
            }
            .width('100%')
            // 内容不满一屏时 Scroll 会把子内容垂直居中，设置项上方因此空出一大块；
            // minHeight 撑满视口即可强制顶对齐（与 DetailPage 同款修复）。
            .constraintSize({ minHeight: '100%' })
          }
          .scrollBar(BarState.Off)
          .layoutWeight(1)
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor($r('app.color.color_bg'))
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
                .fillColor($r('app.color.color_text'))
            }
            .width(36)
            .height(40)
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.navPathStack.pop();
            })
            Text('设置')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.color_text'))
              .layoutWeight(1)
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .height(48 + SystemInsets.top())
          .padding({ left: 8, right: 16, top: SystemInsets.top() })
          // 纯文字导航：不再给底色 / 磨砂 / 描边，让它和下面的内容背景融为一体。
          // 滚动内容仍从它「背后」穿过（它不参与布局流），所以顶部要保留占位。
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
  }

  @Builder
  optionPanel(name: string, items: OptionItem[], currentKey: string) {
    Column({ space: 8 }) {
      ForEach(items, (item: OptionItem, index: number) => {
        Row({ space: 8 }) {
          Text(item.label)
            .fontSize(14)
            .fontColor($r('app.color.color_text'))
            .layoutWeight(1)
          if (item.key === currentKey) {
            Image($r('app.media.ic_check'))
              .width(16)
              .height(16)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .backgroundColor($r('app.color.color_chip_bg'))
        .borderRadius(8)
        .onClick(() => {
          this.onOptionPicked(name, item.key);
        })
      }, (item: OptionItem) => item.key)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 8 })
  }

  private onOptionPicked(name: string, key: string): void {
    this.activePanel = '';
    if (name === 'adFilter') {
      this.adFilter = key;
      this.save({ adFilter: key });
    } else if (name === 'theme') {
      this.themeMode = key;
      this.save({ themeMode: key });
      this.toast('主题将在重启应用后生效');
    } else if (name === 'recommend') {
      this.recommendSource = key;
      this.save({ recommendSource: key });
    } else if (name === 'speed') {
      const value = Number(key);
      if (value > 0) {
        this.defaultSpeed = value;
        this.save({ defaultSpeed: value });
      }
    }
  }
}
