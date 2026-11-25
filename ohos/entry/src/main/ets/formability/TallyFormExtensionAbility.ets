import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import Want from '@ohos.app.ability.Want';
import {
  buildBindingData,
  loadSnapshot,
  normalizeWidgetKind,
  refreshAllForms,
  registerForm,
  unregisterForm,
  WidgetCardData,
} from '../common/WidgetStore';

const PARAM_FORM_ID: string = 'ohos.extra.param.key.form_identity';
const PARAM_FORM_NAME: string = 'ohos.extra.param.key.form_name';

function readStringParam(want: Want, key: string): string {
  const params: Record<string, Object> | undefined = want.parameters;
  if (params === undefined) {
    return '';
  }
  const value: Object = params[key];
  return typeof value === 'string' ? value : '';
}

export default class TallyFormExtensionAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = readStringParam(want, PARAM_FORM_ID);
    // The form name equals the wire kind declared in form_config.json.
    const kind: string = normalizeWidgetKind(readStringParam(want, PARAM_FORM_NAME));
    if (formId.length > 0) {
      registerForm(this.context, formId, kind).then((): Promise<WidgetCardData> => {
        return loadSnapshot(this.context);
      }).then((snapshot: WidgetCardData): Promise<void> => {
        return formProvider.updateForm(formId, buildBindingData(snapshot, kind));
      }).catch((): void => {});
    }
    // Synchronous first paint; the persisted snapshot is pushed right after.
    return buildBindingData(new WidgetCardData(), kind);
  }

  onUpdateForm(formId: string): void {
    refreshAllForms(this.context).catch((): void => {});
  }

  onRemoveForm(formId: string): void {
    unregisterForm(this.context, formId).catch((): void => {});
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
