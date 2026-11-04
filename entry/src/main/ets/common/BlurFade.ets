/**
 * 边缘磨砂渐隐带：一整块**均匀**磨砂 + 页面底色羽化收边。
 *
 * 为什么不能靠"分段变半径"来做渐变（上一版的教训）：
 *   背景模糊的半径只要分档，档与档之间就是一条清晰度突变的横线；
 *   6 档看着像三条杠，12 档仍能看出台阶 —— 用户能一眼看出"磨砂区里有过渡带"。
 *   所以磨砂必须是**一整块同半径**，内部零档位。
 *
 * 那磨砂的下沿怎么办：
 *   用页面底色（color_bg_top）做一层罩子，在磨砂的下沿处**几乎完全不透明**
 *   （color_veil_deep），于是那条"糊/清"的硬边两侧被同一层底色盖住 ——
 *   交界线上方 = 底色 + 模糊内容，下方 = 底色 + 清晰内容，肉眼完全一致，边界消失。
 *   罩子再往下 30~45vp 淡到全透明，清晰内容从这片"雾"里浮出来；
 *   这一段只是颜色渐变，天然不会有台阶。
 *
 *   纵向剖面（以顶部为例）：
 *     屏幕顶 ── 淡罩(40%) + 磨砂 ──┐
 *                                  │ 越往下罩子越浓，磨砂越来越"洗白"
 *     磨砂下沿 ── 罩子≈不透明 ─────┘  ← 糊/清的界线藏在这里
 *                ↓ 罩子 不透明 -> 透明
 *     版面内容 ── 清晰，逐渐浮现
 */
@Component
export struct BlurFade {
  /** 'top'：从屏幕顶端往下渐隐；'bottom'：从底端往上渐隐 */
  edge: string = 'top';
  /** 磨砂本体高度（vp）：从屏幕边缘算到「糊/清交界线」 */
  band: number = 100;
  /** 交界线之外继续让底色淡出的长度（vp），这一段里内容由模糊过渡到清晰 */
  fade: number = 40;
  /** 磨砂半径，整块统一 */
  radius: number = 26;

  /** 罩子外缘（离屏幕边缘最近处）的颜色 */
  soft: ResourceColor = $r('app.color.color_veil_soft');
  /** 「糊/清交界线」处的颜色：要接近不透明，把硬边盖死 */
  deep: ResourceColor = $r('app.color.color_veil_deep');
  /**
   * 罩子淡到全透明时的颜色。
   *
   * 必须与 soft / deep **同 RGB、只把 alpha 置 0**（如 #00DCE3F1）。
   * 万不能用 Color.Transparent（= #00000000）：渐变会把 RGB 一起插值到纯黑，
   * 淡出段于是变成一条「黑灰色的半透明长条」——
   * 深色主题本来就接近纯黑，所以这个 bug 只在浅色主题暴露。
   */
  clear: ResourceColor = $r('app.color.color_veil_clear');

  private total(): number {
    return this.band + this.fade;
  }

  /** 交界线在整块上的比例：顶部在上沿往下 band 处；底部在下沿往上 band 处 */
  private joinPos(): number {
    const t: number = this.total();
    return this.edge === 'top' ? this.band / t : this.fade / t;
  }

  private veil(): LinearGradientOptions {
    const j: number = this.joinPos();
    const colors: Array<[ResourceColor, number]> = this.edge === 'top'
      ? [
        [this.soft, 0],
        [this.deep, j],
        [this.clear, 1]
      ]
      : [
        [this.clear, 0],
        [this.deep, j],
        [this.soft, 1]
      ];
    const opt: LinearGradientOptions = {
      angle: 180,
      colors: colors
    };
    return opt;
  }

  build() {
    Stack({ alignContent: this.edge === 'top' ? Alignment.Top : Alignment.Bottom }) {
      // 均匀磨砂：整块同半径，内部没有任何档位
      Column()
        .width('100%')
        .height(this.band)
        .backgroundEffect({ radius: this.radius, saturation: 1.6 })

      // 底色罩：交界处≈不透明（把硬边盖死），再向外淡出
      Column()
        .width('100%')
        .height(this.total())
        .linearGradient(this.veil())
    }
    .width('100%')
    .height(this.total())
    .hitTestBehavior(HitTestMode.None)
  }
}
