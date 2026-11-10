export interface SleepTimerChoice {
  label: string;
  minutes: number;
}

@CustomDialog
export struct SleepTimerDialog {
  currentLabel: string = '未开启';
  selectedMinutes: number = -999;
  listMaxHeight: number = 300;
  isLandscape: boolean = false;
  choices: SleepTimerChoice[] = [];
  onSelect: (minutes: number) => void = () => {};
  onClose: () => void = () => {};
  controller?: CustomDialogController;

  build() {
    Column({ space: 10 }) {
      Column({ space: 4 }) {
        Text('定时停止').fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.color_text'))
        Text(this.currentLabel).fontSize(13).fontColor($r('app.color.color_text_secondary'))
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 4 })
      Scroll() {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
          ForEach(this.choices, (choice: SleepTimerChoice) => {
            Row() {
              Text(choice.label).fontSize(14)
                .fontColor(choice.minutes === this.selectedMinutes ? Color.White : $r('app.color.color_text'))
                .layoutWeight(1).textAlign(TextAlign.Center)
              if (choice.minutes === this.selectedMinutes) {
                Text('✓').fontSize(16).fontWeight(FontWeight.Medium).fontColor(Color.White).width(24)
              }
            }
              .width('100%').height(40).padding({ left: 16, right: 12 })
              .borderRadius(14)
              .backgroundColor(choice.minutes === this.selectedMinutes ? $r('app.color.color_primary') : $r('app.color.color_chip_bg'))
              .onClick(() => {
                this.controller?.close();
                this.onClose();
                this.onSelect(choice.minutes);
              })
              .margin({ bottom: 8 })
              .width(this.isLandscape ? '48%' : '100%')
          }, (choice: SleepTimerChoice) => choice.minutes.toString())
        }.width('100%').padding({ right: this.isLandscape ? 0 : 10 })
      }
      .width('100%').height(Math.min(this.listMaxHeight, Math.ceil(this.choices.length / (this.isLandscape ? 2 : 1)) * 48))
      .clip(true).scrollBar(BarState.Auto)
    }
    .padding({ left: 18, right: 18, top: 18, bottom: this.isLandscape ? 18 : 24 })
    .constraintSize({ maxWidth: this.isLandscape ? 340 : 560 })
    .width('100%')
    .borderRadius(this.isLandscape ? 24 : { topLeft: 24, topRight: 24, bottomLeft: 0, bottomRight: 0 })
    .backgroundColor($r('app.color.color_panel_glass'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .border({ width: 1, color: $r('app.color.color_liquid_edge') })
    .shadow({ radius: 30, color: '#40000000', offsetY: 10 })
  }
}
