/**
 * 液态玻璃对话框（方案 D）
 *
 * 系统自带的 showAlertDialog 无法套用沉浸材质 —— 它由系统进程绘制，
 * 应用侧改不了外观。所以自己画一个：
 *   · 半透明玻璃底 + 背景模糊（背后是页面内容，所以是「真」通透）
 *   · systemMaterial(GlassMaterial.liquid)：薄材质 + 自动互补色 + 按压形变 + 光随指动
 *   · 折射边用渐变描边自绘（材质本身不提供边）
 *
 * 用法（组件内）：
 *   const ctl = new CustomDialogController({
 *     builder: LiquidDialog({
 *       message: '确定清空吗？',
 *       confirmText: '清空',
 *       cancelText: '取消',
 *       danger: true,
 *       onConfirm: () => { ... }
 *     })
 *   });
 *   ctl.open();
 *
 * 注意：controller 由 CustomDialogController 自动注入到本组件的 controller 字段，
 * 所以点按钮时可以直接 this.controller?.close() 关掉自己。
 */

@CustomDialog
export struct LiquidDialog {
  message: string = '';
  confirmText: string = '确定';
  cancelText: string = '取消';
  danger: boolean = false;
  onConfirm: () => void = () => {};
  onCancel: () => void = () => {};
  controller?: CustomDialogController;

  build() {
    Column({ space: 18 }) {
      Text(this.message)
        .fontSize(16)
        .fontColor($r('app.color.color_text'))
        .textAlign(TextAlign.Center)
        .width('100%')

      Row({ space: 12 }) {
        if (this.cancelText !== '') {
          Text(this.cancelText)
            .fontSize(15)
            .fontColor($r('app.color.color_text'))
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            .borderRadius(20)
            .backgroundColor($r('app.color.color_chip_bg'))
            .onClick(() => {
              this.controller?.close();
              this.onCancel();
            })
        }
        Text(this.confirmText)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .padding({ left: 22, right: 22, top: 10, bottom: 10 })
          .borderRadius(20)
          .backgroundColor(this.danger ? $r('app.color.color_primary_dark') : $r('app.color.color_primary'))
          .onClick(() => {
            this.controller?.close();
            this.onConfirm();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .padding(20)
    // 限宽：不限的话会横贯整个平板屏幕，看着像一条横幅而不是弹窗
    .constraintSize({ maxWidth: 320 })
    .width('100%')
    .borderRadius(24)
    // 玻璃底：半透明 + 背景模糊
    .backgroundColor($r('app.color.color_panel_glass'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    // 折射边：细描边，模拟玻璃棱边
    .border({ width: 1, color: $r('app.color.color_liquid_edge') })
    .shadow({ radius: 30, color: '#40000000', offsetY: 10 })
  }
}
