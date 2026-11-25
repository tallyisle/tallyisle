let storage: LocalStorage = new LocalStorage();

class CardActionParams {
  card_action: string = '';

  constructor(cardAction: string) {
    this.card_action = cardAction;
  }
}

class CardRouterAction {
  action: string = 'router';
  abilityName: string = 'EntryAbility';
  params: CardActionParams;

  constructor(cardAction: string) {
    this.params = new CardActionParams(cardAction);
  }
}

const COLOR_PRIMARY: string = '#1F7A6D';
const COLOR_TEXT: string = '#1B1F23';
const COLOR_SUBTLE: string = '#6B7280';
const COLOR_EXPENSE: string = '#D9534F';
const COLOR_INCOME: string = '#2E8B57';
const COLOR_CARD_BG: string = '#FFFFFF';
const COLOR_PILL_BG: string = '#E6F2EF';

@Entry(storage)
@Component
struct TallyWidgetCard {
  @LocalStorageProp('kind') kind: string = 'quick_add';
  @LocalStorageProp('hasData') hasData: boolean = false;
  @LocalStorageProp('bookName') bookName: string = '';
  @LocalStorageProp('periodLabel') periodLabel: string = '';
  @LocalStorageProp('currencySymbol') currencySymbol: string = '';
  @LocalStorageProp('expenseFormatted') expenseFormatted: string = '';
  @LocalStorageProp('incomeFormatted') incomeFormatted: string = '';
  @LocalStorageProp('balanceFormatted') balanceFormatted: string = '';
  @LocalStorageProp('todayExpenseFormatted') todayExpenseFormatted: string = '';
  @LocalStorageProp('budgetRemainingFormatted') budgetRemainingFormatted: string = '';
  @LocalStorageProp('pendingDraftCount') pendingDraftCount: number = 0;

  private post(cardAction: string): void {
    postCardAction(this, new CardRouterAction(cardAction));
  }

  @Builder
  AmountColumn(label: Resource, value: string, color: string) {
    Column() {
      Text(label)
        .fontSize(11)
        .fontColor(COLOR_SUBTLE)
        .maxLines(1)
      Text(value.length > 0 ? value : '--')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ActionPill(label: Resource, cardAction: string) {
    Text(label)
      .fontSize(13)
      .fontColor(COLOR_PRIMARY)
      .fontWeight(FontWeight.Medium)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor(COLOR_PILL_BG)
      .borderRadius(14)
      .onClick((): void => {
        this.post(cardAction);
      })
  }

  @Builder
  QuickAddLayout() {
    Column() {
      Text($r('app.string.widget_add_record'))
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_PRIMARY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .backgroundColor(COLOR_PILL_BG)
        .borderRadius(20)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick((): void => {
      this.post('new_record');
    })
  }

  @Builder
  MonthSummaryLayout() {
    Column({ space: 6 }) {
      Text(this.periodLabel.length > 0 ? this.periodLabel : this.bookName)
        .fontSize(13)
        .fontColor(COLOR_SUBTLE)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.hasData) {
        this.AmountColumn($r('app.string.widget_expense'), this.expenseFormatted, COLOR_EXPENSE)
        this.AmountColumn($r('app.string.widget_income'), this.incomeFormatted, COLOR_INCOME)
        this.AmountColumn($r('app.string.widget_balance'), this.balanceFormatted, COLOR_TEXT)
      } else {
        Text($r('app.string.widget_no_data'))
          .fontSize(13)
          .fontColor(COLOR_SUBTLE)
          .maxLines(2)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .onClick((): void => {
      this.post('new_record');
    })
  }

  @Builder
  MonthBarLayout() {
    Column({ space: 8 }) {
      Row() {
        Text(this.periodLabel.length > 0 ? this.periodLabel : this.bookName)
          .fontSize(13)
          .fontColor(COLOR_SUBTLE)
          .maxLines(1)
          .layoutWeight(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.ActionPill($r('app.string.widget_add_record'), 'new_record')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.hasData) {
        Row() {
          Column() {
            this.AmountColumn($r('app.string.widget_expense'), this.expenseFormatted, COLOR_EXPENSE)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Column() {
            this.AmountColumn($r('app.string.widget_income'), this.incomeFormatted, COLOR_INCOME)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Column() {
            this.AmountColumn($r('app.string.widget_balance'), this.balanceFormatted, COLOR_TEXT)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
      } else {
        Text($r('app.string.widget_no_data'))
          .fontSize(13)
          .fontColor(COLOR_SUBTLE)
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  SmartQuickLayout() {
    Column({ space: 8 }) {
      Row() {
        Text($r('app.string.widget_smart_title'))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT)
          .layoutWeight(1)
          .maxLines(1)
        if (this.pendingDraftCount > 0) {
          Text($r('app.string.widget_pending_count', this.pendingDraftCount))
            .fontSize(11)
            .fontColor(Color.White)
            .maxLines(1)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(COLOR_EXPENSE)
            .borderRadius(10)
            .onClick((): void => {
              this.post('drafts');
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.ActionPill($r('app.string.widget_add_record'), 'new_record')
      this.ActionPill($r('app.string.widget_smart_bill'), 'smart_bill')
      this.ActionPill($r('app.string.widget_ocr_bill'), 'ocr_bill')
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      if (this.kind === 'month_summary') {
        this.MonthSummaryLayout()
      } else if (this.kind === 'month_bar') {
        this.MonthBarLayout()
      } else if (this.kind === 'smart_quick') {
        this.SmartQuickLayout()
      } else {
        this.QuickAddLayout()
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor(COLOR_CARD_BG)
  }
}
