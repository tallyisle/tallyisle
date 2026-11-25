import common from '@ohos.app.ability.common';
import dataPreferences from '@ohos.data.preferences';
import { formBindingData, formProvider } from '@kit.FormKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * Shared (main process <-> form extension process) persistence for HarmonyOS
 * service cards. Intentionally free of any Flutter imports so the lightweight
 * FormExtensionAbility process never loads the Flutter engine.
 */

export const WIDGET_PREFS_NAME: string = 'tallyisle_ohos_widgets';
const KEY_SNAPSHOT: string = 'snapshot_json';
const KEY_ACTIVE_FORMS: string = 'active_forms_json';
const FORM_NOT_EXIST_CODE: number = 16500050;

export const KIND_QUICK_ADD: string = 'quick_add';
export const KIND_MONTH_SUMMARY: string = 'month_summary';
export const KIND_MONTH_BAR: string = 'month_bar';
export const KIND_SMART_QUICK: string = 'smart_quick';

export function allWidgetKinds(): Array<string> {
  return [KIND_QUICK_ADD, KIND_MONTH_SUMMARY, KIND_MONTH_BAR, KIND_SMART_QUICK];
}

export function normalizeWidgetKind(raw: string): string {
  const kinds: Array<string> = allWidgetKinds();
  for (let i: number = 0; i < kinds.length; i++) {
    if (kinds[i] === raw) {
      return raw;
    }
  }
  return KIND_QUICK_ADD;
}

class PersistedFormEntry {
  formId: string = '';
  kind: string = KIND_QUICK_ADD;

  constructor(formId: string, kind: string) {
    this.formId = formId;
    this.kind = kind;
  }
}

/** Flat key/value payload bound to the card via @LocalStorageProp keys. */
export class WidgetCardData {
  kind: string = KIND_QUICK_ADD;
  hasData: boolean = false;
  bookName: string = '';
  periodLabel: string = '';
  currencySymbol: string = '';
  expenseFormatted: string = '';
  incomeFormatted: string = '';
  balanceFormatted: string = '';
  todayExpenseFormatted: string = '';
  budgetRemainingFormatted: string = '';
  pendingDraftCount: number = 0;
  updatedAtMs: number = 0;
}

function readString(map: Record<string, Object>, key: string): string {
  const value: Object = map[key];
  return typeof value === 'string' ? value : '';
}

function readNumber(map: Record<string, Object>, key: string): number {
  const value: Object = map[key];
  return typeof value === 'number' ? value : 0;
}

export function parseSnapshotJson(raw: string): WidgetCardData {
  const data: WidgetCardData = new WidgetCardData();
  if (raw.length === 0) {
    return data;
  }
  try {
    const map: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    data.hasData = true;
    data.bookName = readString(map, 'bookName');
    data.periodLabel = readString(map, 'periodLabel');
    data.currencySymbol = readString(map, 'currencySymbol');
    data.expenseFormatted = readString(map, 'expenseFormatted');
    data.incomeFormatted = readString(map, 'incomeFormatted');
    data.balanceFormatted = readString(map, 'balanceFormatted');
    data.todayExpenseFormatted = readString(map, 'todayExpenseFormatted');
    data.budgetRemainingFormatted = readString(map, 'budgetRemainingFormatted');
    data.pendingDraftCount = Math.max(0, Math.trunc(readNumber(map, 'pendingDraftCount')));
    data.updatedAtMs = readNumber(map, 'updatedAtMs');
  } catch (err) {
    return new WidgetCardData();
  }
  return data;
}

export function serializeSnapshot(data: WidgetCardData): string {
  return JSON.stringify(data);
}

async function openPrefs(context: common.Context): Promise<dataPreferences.Preferences> {
  // UIAbilityContext and FormExtensionContext are ability-scoped; the application
  // context gives both processes the same preferences file path.
  const appContext: common.Context = context.getApplicationContext();
  // The form extension runs in a separate process; drop any cached instance so
  // we always observe the latest bytes written by the other process.
  try {
    await dataPreferences.removePreferencesFromCache(appContext, WIDGET_PREFS_NAME);
  } catch (err) {
    // Nothing cached yet.
  }
  return await dataPreferences.getPreferences(appContext, WIDGET_PREFS_NAME);
}

export async function loadSnapshot(context: common.Context): Promise<WidgetCardData> {
  try {
    const prefs: dataPreferences.Preferences = await openPrefs(context);
    const raw: dataPreferences.ValueType = await prefs.get(KEY_SNAPSHOT, '');
    return parseSnapshotJson(typeof raw === 'string' ? raw : '');
  } catch (err) {
    return new WidgetCardData();
  }
}

export async function saveSnapshot(context: common.Context, data: WidgetCardData): Promise<void> {
  const prefs: dataPreferences.Preferences = await openPrefs(context);
  await prefs.put(KEY_SNAPSHOT, serializeSnapshot(data));
  await prefs.flush();
}

export async function loadActiveForms(context: common.Context): Promise<Map<string, string>> {
  const forms: Map<string, string> = new Map<string, string>();
  try {
    const prefs: dataPreferences.Preferences = await openPrefs(context);
    const raw: dataPreferences.ValueType = await prefs.get(KEY_ACTIVE_FORMS, '');
    if (typeof raw !== 'string' || raw.length === 0) {
      return forms;
    }
    const parsed: Object = JSON.parse(raw);
    if (parsed instanceof Array) {
      const items: Array<Object> = parsed as Array<Object>;
      for (let i: number = 0; i < items.length; i++) {
        const item: Record<string, Object> = items[i] as Record<string, Object>;
        if (item == null) {
          continue;
        }
        const formId: Object = item['formId'];
        const kind: Object = item['kind'];
        if (typeof formId === 'string' && formId.length > 0 && typeof kind === 'string') {
          forms.set(formId, normalizeWidgetKind(kind));
        }
      }
    }
  } catch (err) {
    // Treat unreadable state as "no active forms".
  }
  return forms;
}

async function saveActiveForms(context: common.Context, forms: Map<string, string>): Promise<void> {
  const record: Array<PersistedFormEntry> = new Array<PersistedFormEntry>();
  forms.forEach((kind: string, formId: string): void => {
    record.push(new PersistedFormEntry(formId, kind));
  });
  const prefs: dataPreferences.Preferences = await openPrefs(context);
  await prefs.put(KEY_ACTIVE_FORMS, JSON.stringify(record));
  await prefs.flush();
}

let formsLock: Promise<void> = Promise.resolve();

function runExclusive(task: () => Promise<void>): Promise<void> {
  const next: Promise<void> = formsLock.then(task);
  formsLock = next.catch((): void => {});
  return next;
}

export function registerForm(context: common.Context, formId: string, kind: string): Promise<void> {
  return runExclusive(async (): Promise<void> => {
    const forms: Map<string, string> = await loadActiveForms(context);
    forms.set(formId, normalizeWidgetKind(kind));
    await saveActiveForms(context, forms);
  });
}

export function unregisterForm(context: common.Context, formId: string): Promise<void> {
  return runExclusive(async (): Promise<void> => {
    const forms: Map<string, string> = await loadActiveForms(context);
    if (forms.delete(formId)) {
      await saveActiveForms(context, forms);
    }
  });
}

export function countByKind(forms: Map<string, string>): Map<string, number> {
  const counts: Map<string, number> = new Map<string, number>();
  const kinds: Array<string> = allWidgetKinds();
  for (let i: number = 0; i < kinds.length; i++) {
    counts.set(kinds[i], 0);
  }
  forms.forEach((kind: string): void => {
    const previous: number | undefined = counts.get(kind);
    counts.set(kind, (previous === undefined ? 0 : previous) + 1);
  });
  return counts;
}

export function buildBindingData(base: WidgetCardData, kind: string): formBindingData.FormBindingData {
  const data: WidgetCardData = new WidgetCardData();
  data.hasData = base.hasData;
  data.bookName = base.bookName;
  data.periodLabel = base.periodLabel;
  data.currencySymbol = base.currencySymbol;
  data.expenseFormatted = base.expenseFormatted;
  data.incomeFormatted = base.incomeFormatted;
  data.balanceFormatted = base.balanceFormatted;
  data.todayExpenseFormatted = base.todayExpenseFormatted;
  data.budgetRemainingFormatted = base.budgetRemainingFormatted;
  data.pendingDraftCount = base.pendingDraftCount;
  data.updatedAtMs = base.updatedAtMs;
  data.kind = normalizeWidgetKind(kind);
  return formBindingData.createFormBindingData(JSON.stringify(data));
}

/**
 * Pushes the latest persisted snapshot to every registered card. Cards that the
 * system no longer knows about are pruned. Returns the live per-kind counts.
 */
export async function refreshAllForms(context: common.Context): Promise<Map<string, number>> {
  const snapshot: WidgetCardData = await loadSnapshot(context);
  const forms: Map<string, string> = await loadActiveForms(context);
  const stale: Array<string> = new Array<string>();
  const entries: Array<string> = new Array<string>();
  forms.forEach((_kind: string, formId: string): void => {
    entries.push(formId);
  });
  for (let i: number = 0; i < entries.length; i++) {
    const formId: string = entries[i];
    const kind: string | undefined = forms.get(formId);
    try {
      await formProvider.updateForm(formId, buildBindingData(snapshot, kind === undefined ? KIND_QUICK_ADD : kind));
    } catch (err) {
      const businessError: BusinessError = err as BusinessError;
      if (businessError.code === FORM_NOT_EXIST_CODE) {
        stale.push(formId);
      }
    }
  }
  for (let i: number = 0; i < stale.length; i++) {
    forms.delete(stale[i]);
    await unregisterForm(context, stale[i]);
  }
  return countByKind(forms);
}
