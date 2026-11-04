/**
 * 通用 UI 组件：加载态 / 空态 / 视频卡片 / 设置行 / 分组标题 / 标签
 */

import { NetImage } from './NetImage';
import { PosterColor } from '../common/PosterColor';

@Component
export struct LoadingView {
  @Prop tipText: string = '加载中…';

  build() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(32)
        .height(32)
        .color($r('app.color.color_primary'))
      Text(this.tipText)
        .fontSize(13)
        .fontColor($r('app.color.color_text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}

@Component
export struct EmptyView {
  @Prop emptyText: string = '暂无内容';
  @Prop emptyIcon: string = '';

  build() {
    Column({ space: 12 }) {
      if (this.emptyIcon !== '') {
        Image(this.emptyIcon)
          .width(56)
          .height(56)
          .opacity(0.35)
      } else {
        Text('◌')
          .fontSize(48)
          .fontColor($r('app.color.color_text_secondary'))
          .opacity(0.4)
      }
      Text(this.emptyText)
        .fontSize(14)
        .fontColor($r('app.color.color_text_secondary'))
    }
    .width('100%')
    .padding(32)
    .justifyContent(FlexAlign.Center)
  }
}

@Component
export struct SectionHeader {
  @Prop headerText: string = '';
  @Prop headerAction: string = '';
  onActionClick: () => void = () => {};

  build() {
    Row() {
      Text(this.headerText)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.color_text'))
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
      if (this.headerAction !== '') {
        // 字号 13 且没有内边距时，实际可点区域只有文字本身，很容易点空。
        // 用 padding 把触达区撑到 30vp 高，右侧少留 8vp 抵消内边距。
        Text(this.headerAction)
          .fontSize(14)
          .fontColor($r('app.color.color_primary'))
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .onClick(() => {
            this.onActionClick();
          })
      }
    }
    .width('100%')
    // bottom 从 8 收到 2：标题和它下面那排标签之间原本空了近 20vp，
    // 看着像两个不相干的区块。标题行自身的行高已经带了余量，不需要再补。
    .padding({ left: 16, right: 8, top: 4, bottom: 2 })
  }
}

@Component
export struct TagText {
  @State tagText: string = '';
  @State tagColor: ResourceColor = $r('app.color.color_text_secondary');
  @State tagBg: ResourceColor = $r('app.color.color_chip_bg');

  build() {
    Text(this.tagText)
      .fontSize(10)
      .fontColor(this.tagColor)
      .backgroundColor(this.tagBg)
      .borderRadius(4)
      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
      .maxLines(1)
  }
}

/** 视频海报卡片 */
@Component
export struct VodCard {
  @Prop cardTitle: string = '';
  @Prop cardPic: string = '';
  @Prop cardRemarks: string = '';
  /** 评分横幅（「评分： 9.2」贴海报下沿整条铺开）；空串不显示 */
  @Prop cardRating: string = '';
  @Prop cardSource: string = '';
  @Prop cardProgress: string = '';
  /** 紧凑模式：海报、标题条、角标全部按比例缩小，用于首页「继续观看」这类小卡位 */
  @Prop cardCompact: boolean = false;
  /**
   * 是否开启「光从内容来」（方案 B）：
   * 采样海报主色，在卡片周围投出同色光晕。
   * 只在首页推荐区开启 —— 采样要额外解码一次，长列表里没必要每张都做。
   */
  @Prop cardGlow: boolean = false;
  /** 主色光晕强度（0~1） */
  @Prop cardGlowStrength: number = 1;
  onCardClick: () => void = () => {};

  /** 采样到的海报主色，'#RRGGBB'；空串表示还没采到 */
  @State mainColor: string = '';

  aboutToAppear(): void {
    if (this.cardGlow) {
      this.sampleColor();
    }
  }

  private async sampleColor(): Promise<void> {
    if (this.cardPic === '') {
      return;
    }
    const c: string = await PosterColor.dominant(this.cardPic);
    if (c !== '') {
      this.mainColor = c;
    }
  }

  /** 主色光晕色：带透明度的 rgba 字符串 */
  private glowColor(alpha: number): string {
    if (this.mainColor === '') {
      return '#00000000';
    }
    const hex: string = this.mainColor.substring(1);
    const r: string = hex.substring(0, 2);
    const g: string = hex.substring(2, 4);
    const b: string = hex.substring(4, 6);
    return `rgba(${parseInt(r, 16)}, ${parseInt(g, 16)}, ${parseInt(b, 16)}, ${alpha})`;
  }

  /**
   * 片名条底色：固定的深色磨砂玻璃，**不吃封面主色**。
   *
   * 试过两版彩色底都被否掉了：0.55 是全实色，0.30 仍是明显的彩色标签，
   * 一排看过去像给每张片子贴了张色卡 —— 比原来的深色玻璃难看得多。
   * 主色现在只负责两件事：卡片外沿那圈轮廓光、海报底部的那层溢光渐变。
   *
   * 用 0x4D 而不是更黑：32% 的黑 + 背景模糊能让海报自身的颜色透上来，
   * 不会出现"封面底部糊了一块死黑"的观感，白字配投影照样清楚。
   */
  private captionBg(): ResourceColor {
    // 深灰蓝而不是纯黑：纯黑在深色页面上就是"封面断了"，
    // 带一点点蓝调才能看出这是一条压在海报上的玻璃条。
    // 不透明度必须够高（0.77）—— 低于这个值时，海报底部那片饱和色
    // 会整片透上来，一条条彩色条看着像给每张片子贴了色卡。
    return '#C4121418';
  }

  build() {
    // 结构说明（方案 B + 磨砂玻璃）：
    //   · 卡片只剩海报一层，片名条以「浮层」形式压在海报下沿 ——
    //     这样 backgroundBlurStyle 背后真的有内容（海报），磨砂才不是一块平色板；
    //   · 海报下沿再叠一层主色径向渐变 —— 光从内容来；
    //   · 卡片外圈用主色投影，形成卡片向页面「洒光」的效果。
    Column() {
      Stack({ alignContent: Alignment.Bottom }) {
        Stack({ alignContent: Alignment.TopStart }) {
          NetImage({ url: this.cardPic !== undefined ? this.cardPic : '' })
            .width('100%')
            .height('100%')

          // 主色溢光（方案 B）：海报自身主色在下沿洇开的一层光。
          // 必须放在「有确定尺寸」的海报层里，且用 100% 铺满 ——
          // 之前这层写成 height('46%') 挂在无高度的外层 Stack 上，
          // 百分比参照无解，把整张卡撑成两倍高（海报缩在底部、上方大片空白）。
          if (this.mainColor !== '') {
            Column()
              .width('100%')
              .height('100%')
              .linearGradient({
                direction: GradientDirection.Bottom,
                colors: [
                  [this.glowColor(0.08 * this.cardGlowStrength), 0],
                  [this.glowColor(0.24 * this.cardGlowStrength), 0.62],
                  [this.glowColor(0.40 * this.cardGlowStrength), 1]
                ]
              })
              .hitTestBehavior(HitTestMode.None)
          }
          if (this.cardRemarks !== '') {
            Text(this.cardRemarks)
              .fontSize(this.cardCompact ? 8 : 10)
              .fontColor(Color.White)
              .backgroundColor('#00000066')
              .borderRadius(3)
              .padding({ left: this.cardCompact ? 3 : 4, right: this.cardCompact ? 3 : 4, top: 1, bottom: 1 })
              .margin(this.cardCompact ? 4 : 6)
              .maxLines(1)
          }
        }
        .width('100%')
        // 海报层自己定死比例：卡片高度由它决定；层内溢光/角标用 100% 才有明确参照。
        // 之前比例挂在 NetImage 上、溢光又用百分比，测量互相依赖，
        // 卡片被撑成两倍高（海报在上、下面一大片空玻璃）。
        .aspectRatio(0.72)


        // 封面下沿的信息区：评分横幅 / 进度条 / 片名条，从上到下排成一列。
        // 这三者早先都是 Bottom 对齐 Stack 的**直接子节点**，Bottom 对齐意味着
        // 全部贴在同一位置上互相重叠 —— 片名条最后画，正好把评分和进度整条盖住，
        // 表现就是「封面上的评分不见了」。必须包一层 Column 让它们纵向排开。
        Column() {
          // 评分横幅：深色半透明衬底 + 白字，任何封面上都清晰可读。
          if (this.cardRating !== '') {
            Row() {
              Text(this.cardRating)
                .fontSize(this.cardCompact ? 9 : 11)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
                .maxLines(1)
            }
            .width('100%')
            .padding({ left: this.cardCompact ? 4 : 6, right: this.cardCompact ? 4 : 6, top: 2, bottom: 2 })
            .backgroundColor('#B3000000')
            .alignItems(VerticalAlign.Center)
          }

          if (this.cardProgress !== '') {
            Stack({ alignContent: Alignment.Start }) {
              Row()
                .width('100%')
                .height(3)
                .backgroundColor('#00000055')
              Row()
                .width(this.cardProgress)
                .height(3)
                .backgroundColor($r('app.color.color_primary'))
            }
            .width('100%')
            .height(3)
          }

          // 磨砂玻璃片名条：浮在海报下沿。
          // 半透明底 + 背景模糊，背后是海报（不是空色板），所以是真正的磨砂。
          // 底色优先用封面主色（跳过暗色后的那个颜色）—— 深色玻璃压在暗海报上
          // 等于「海报下沿变暗了一点」，看不出是玻璃；用封面自己的亮色才有「光从内容来」
          // 的味道，白字配深色投影也仍然读得清。
          Column({ space: 1 }) {
            Text(this.cardTitle)
              .fontSize(this.cardCompact ? 10 : 13)
              .fontColor(Color.White)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .width('100%')
              .shadow({ radius: 4, color: '#80000000', offsetY: 1 })
            if (this.cardSource !== '') {
              Text(this.cardSource)
                .fontSize(10)
                .fontColor('#D9FFFFFF')
                .maxLines(1)
                .textAlign(TextAlign.Center)
                .width('100%')
                .shadow({ radius: 3, color: '#80000000', offsetY: 1 })
            }
          }
          .width('100%')
          .height(this.cardCompact ? 24 : (this.cardSource !== '' ? 44 : 34))
          .padding({ left: this.cardCompact ? 4 : 8, right: this.cardCompact ? 4 : 8 })
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.captionBg())
          // radius 不能给太大：给到 24 时海报下沿那点细节被磨成一整块平色，
          // 观感和"直接压一块暗色"完全一样，磨砂等于白做。14 能留下色块轮廓。
          // saturation 从 2.0 收到 1.35：2.0 会把透上来的封面色放大成荧光色，
          // 这也是上一版片名条看着"像彩色标签"的原因之一。
          .backgroundEffect({ radius: 14, saturation: 1.35 })
          // 上沿一道细高光：玻璃和背景之间必须有边界，否则只是「一块暗色」。
          .border({ width: { top: 1 }, color: '#2EFFFFFF' })
        }
        .width('100%')
      }
      .width('100%')
    }
    .width('100%')
    .borderRadius(this.cardCompact ? 7 : 10)
    .clip(true)
    // 落影回到普通阴影。
    // 之前是 26vp 半径、0.62 透明度的主色大光晕，一屏十几张卡片同时往外洒光，
    // 叠在一起就是一片脏色 —— 用户直接说"太丑"。光改由下面那圈细轮廓表达。
    .shadow({ radius: this.cardCompact ? 6 : 10, color: '#59000000', offsetY: this.cardCompact ? 2 : 4 })
    // 轮廓光：沿卡片外沿描一圈封面主色。
    // 这是「光从内容来」最克制也最耐看的形态 —— 光贴着片子走，
    // 不同封面的颜色在页面上连成一层淡淡的彩边，而不是各自泼一滩。
    // 没采到主色时退回一层极淡的白边，保住卡片轮廓不糊进背景。
    .border({
      width: 1,
      color: this.mainColor !== '' ? this.glowColor(0.55) : '#1FFFFFFF'
    })
    .onClick(() => {
      this.onCardClick();
    })
  }
}

/** 设置项行：左侧标题，右侧值 + 箭头 */
@Component
export struct SettingsRow {
  @Prop rowTitle: string = '';
  @Prop rowValue: string = '';
  @Prop rowShowArrow: boolean = true;
  rowTitleColor: ResourceColor = $r('app.color.color_text');
  onRowClick: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      Text(this.rowTitle)
        // 17 号字 + 上下 18 的内边距：整行高度约 60vp，手指点起来更稳
        .fontSize(17)
        .fontColor(this.rowTitleColor)
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
      if (this.rowValue !== '') {
        Text(this.rowValue)
          .fontSize(14)
          .fontColor($r('app.color.color_text_secondary'))
          .maxLines(1)
      }
      if (this.rowShowArrow) {
        Image($r('app.media.ic_back'))
          .width(14)
          .height(14)
          .rotate({ angle: 180 })
          .opacity(0.4)
      }
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: 18 })
    .backgroundColor($r('app.color.color_card'))
    .onClick(() => {
      this.onRowClick();
    })
  }
}
