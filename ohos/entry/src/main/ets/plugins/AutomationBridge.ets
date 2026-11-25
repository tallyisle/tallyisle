import {
  Any,
  BinaryMessenger,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import fs from '@ohos.file.fs';
import { image } from '@kit.ImageKit';
import { textRecognition } from '@kit.CoreVisionKit';
import { systemShare } from '@kit.ShareKit';
import { util } from '@kit.ArkTS';
import {
  allWidgetKinds,
  countByKind,
  loadActiveForms,
  refreshAllForms,
  saveSnapshot,
  WidgetCardData,
} from '../common/WidgetStore';

const TAG: string = 'TallyIsleAutomationBridge';
const CHANNEL_NAME: string = 'dev.tallyisle/automation';
const STATUS_UNSUPPORTED_LABEL: string = '当前平台不支持';
const ACTION_SEND_DATA: string = 'ohos.want.action.sendData';
const PARAM_SHORTCUT_ACTION: string = 'shortcut_action';
const PARAM_CARD_ACTION: string = 'card_action';
const SHARE_FILE_PREFIX: string = 'ohos_share_';
const SHARE_FILE_MAX_AGE_MS: number = 24 * 60 * 60 * 1000;
const SHARE_TEXT_FILE_MAX_BYTES: number = 256 * 1024;
const OCR_MAX_EDGE_PX: number = 4096;
const OCR_SYSCAP: string = 'SystemCapability.AI.OCR.TextRecognition';
const ERROR_OCR_UNSUPPORTED: string = 'OCR_UNSUPPORTED';
const ERROR_OCR_FAILED: string = 'OCR_FAILED';
const ERROR_WIDGET_FAILED: string = 'WIDGET_UPDATE_FAILED';

function extractSupportedDeepLink(rawUri: string): string | null {
  const trimmed: string = rawUri.trim();
  if (trimmed.length === 0) {
    return null;
  }
  const lower: string = trimmed.toLowerCase();
  if (!lower.startsWith('tallyisle://')) {
    return null;
  }
  const rest: string = lower.substring(12);

  let endIdx: number = rest.length;
  const slashIdx: number = rest.indexOf('/');
  const queryIdx: number = rest.indexOf('?');
  const hashIdx: number = rest.indexOf('#');
  if (slashIdx >= 0 && slashIdx < endIdx) {
    endIdx = slashIdx;
  }
  if (queryIdx >= 0 && queryIdx < endIdx) {
    endIdx = queryIdx;
  }
  if (hashIdx >= 0 && hashIdx < endIdx) {
    endIdx = hashIdx;
  }
  const host: string = rest.substring(0, endIdx).trim();
  if (host === 'reminder' || host === 'reminder-open') {
    return null;
  }
  return trimmed;
}

function isSupportedShortcutAction(action: string): boolean {
  return action === 'new_record' || action === 'smart_bill' || action === 'ocr_bill' || action === 'drafts';
}

function unsupportedStatusMap(): Map<string, Any> {
  // Honest capability degradation on HarmonyOS NEXT (ADR-008): third-party apps
  // cannot register system-wide cross-app AccessibilityService screen readers, read
  // other apps' notifications, or draw system overlays.
  const status: Map<string, Any> = new Map<string, Any>();
  status.set('supported', false);
  status.set('enabled', false);
  status.set('statusLabel', STATUS_UNSUPPORTED_LABEL);
  return status;
}

function countsToMap(counts: Map<string, number>): Map<string, Any> {
  const out: Map<string, Any> = new Map<string, Any>();
  const kinds: Array<string> = allWidgetKinds();
  for (let i: number = 0; i < kinds.length; i++) {
    const value: number | undefined = counts.get(kinds[i]);
    out.set(kinds[i], value === undefined ? 0 : value);
  }
  return out;
}

function argString(call: MethodCall, key: string): string {
  const value: Any = call.argument(key);
  return typeof value === 'string' ? value : '';
}

function argNumber(call: MethodCall, key: string): number {
  const value: Any = call.argument(key);
  return typeof value === 'number' ? value : 0;
}

function isTextUtd(utd: string): boolean {
  return utd.startsWith('general.plain-text') || utd.startsWith('general.text');
}

function pickImageExtension(uri: string): string {
  const withoutQuery: string = uri.split('?')[0];
  const dot: number = withoutQuery.lastIndexOf('.');
  if (dot < 0) {
    return 'png';
  }
  const ext: string = withoutQuery.substring(dot + 1).toLowerCase();
  if (ext.length === 0 || ext.length > 5) {
    return 'png';
  }
  for (let i: number = 0; i < ext.length; i++) {
    const code: number = ext.charCodeAt(i);
    const isDigit: boolean = code >= 48 && code <= 57;
    const isLower: boolean = code >= 97 && code <= 122;
    if (!isDigit && !isLower) {
      return 'png';
    }
  }
  return ext;
}

/** Acknowledgement of a live native -> Dart callback; `true` means handled. */
class LiveAckCallback implements MethodResult {
  private onHandled: () => void;

  constructor(onHandled: () => void) {
    this.onHandled = onHandled;
  }

  success = (handled: Any): void => {
    if (handled === true) {
      this.onHandled();
    }
  };

  error = (_code: string, _msg: string, _details: Any): void => {};

  notImplemented = (): void => {};
}

export class AutomationBridge implements MethodCallHandler {
  private context: common.Context;
  private channel: MethodChannel | null = null;
  private pendingDeepLinkUri: string | null = null;
  private pendingSharedPayloads: Array<Map<string, Any>> = new Array<Map<string, Any>>();
  private pendingCapturedEvents: Array<Map<string, Any>> = new Array<Map<string, Any>>();
  private pendingPromptActions: Array<Map<string, Any>> = new Array<Map<string, Any>>();

  constructor(context: common.Context) {
    this.context = context;
  }

  acknowledgeDeepLink(uri: string): void {
    if (this.pendingDeepLinkUri === uri) {
      this.pendingDeepLinkUri = null;
    }
  }

  attach(messenger: BinaryMessenger): void {
    this.detach();
    const methodChannel: MethodChannel = new MethodChannel(messenger, CHANNEL_NAME);
    methodChannel.setMethodCallHandler(this);
    this.channel = methodChannel;
  }

  detach(): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
  }

  /**
   * Captures an incoming [Want] from `onCreate` or `onNewWant`. Handles, in order:
   * 1. `tallyisle://` deep links (clears `want.uri` so Flutter's default navigation
   *    channel does not push the raw custom-scheme URI as an unknown route);
   * 2. system share (`ohos.want.action.sendData`) with text and/or screenshots;
   * 3. desktop icon long-press shortcuts (`shortcut_action`) and service card
   *    taps (`card_action`).
   * Returns true when the want was consumed by this bridge.
   */
  captureWant(want: Want | null, notifyFlutter: boolean): boolean {
    if (want == null) {
      return false;
    }
    if (typeof want.uri === 'string' && this.captureDeepLink(want, notifyFlutter)) {
      return true;
    }
    if (want.action === ACTION_SEND_DATA) {
      this.captureShare(want);
      return true;
    }
    return this.captureShortcutOrCard(want);
  }

  private captureDeepLink(want: Want, notifyFlutter: boolean): boolean {
    const rawUri: string = want.uri === undefined ? '' : want.uri;
    const matchedUri: string | null = extractSupportedDeepLink(rawUri);
    if (matchedUri == null) {
      return false;
    }

    want.uri = '';
    this.pendingDeepLinkUri = matchedUri;

    const activeChannel: MethodChannel | null = this.channel;
    if (notifyFlutter && activeChannel != null) {
      const replyCallback: LiveAckCallback = new LiveAckCallback((): void => {
        this.acknowledgeDeepLink(matchedUri);
      });
      activeChannel.invokeMethod('onDeepLink', matchedUri, replyCallback);
    }
    return true;
  }

  private captureShortcutOrCard(want: Want): boolean {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return false;
    }
    let source: string = '';
    let action: string = '';
    let consumedKey: string = '';
    const shortcutValue: Object = params[PARAM_SHORTCUT_ACTION];
    const cardValue: Object = params[PARAM_CARD_ACTION];
    if (typeof shortcutValue === 'string' && isSupportedShortcutAction(shortcutValue)) {
      source = 'shortcut';
      action = shortcutValue;
      consumedKey = PARAM_SHORTCUT_ACTION;
    } else if (typeof cardValue === 'string' && isSupportedShortcutAction(cardValue)) {
      source = 'card';
      action = cardValue;
      consumedKey = PARAM_CARD_ACTION;
    }
    if (consumedKey.length === 0) {
      return false;
    }
    // Clear so a later onNewWant replay of the same Want cannot enqueue twice.
    params[consumedKey] = '';

    const payload: Map<string, Any> = this.newPayload('shortcut', source);
    payload.set('shortcutAction', action);
    this.dispatchSharedPayload(payload);
    return true;
  }

  private captureShare(want: Want): void {
    this.collectSharedPayload(want).then((payload: Map<string, Any> | null): void => {
      if (payload != null) {
        this.dispatchSharedPayload(payload);
      }
    }).catch((err: Error): void => {
      Log.e(TAG, 'Failed to read shared data: ' + JSON.stringify(err));
    });
  }

  private newPayload(kind: string, source: string): Map<string, Any> {
    const payload: Map<string, Any> = new Map<string, Any>();
    payload.set('kind', kind);
    payload.set('source', source);
    payload.set('receivedAtMs', Date.now());
    return payload;
  }

  /** Images win over text: a screenshot share is the primary smart-bill input. */
  private async collectSharedPayload(want: Want): Promise<Map<string, Any> | null> {
    const sharedData: systemShare.SharedData = await systemShare.getSharedData(want);
    const records: Array<systemShare.SharedRecord> = sharedData.getRecords();
    const imagePaths: Array<string> = new Array<string>();
    const texts: Array<string> = new Array<string>();
    this.pruneOldShareFiles();
    for (let i: number = 0; i < records.length; i++) {
      const record: systemShare.SharedRecord = records[i];
      const uri: string = typeof record.uri === 'string' ? record.uri : '';
      const utd: string = typeof record.utd === 'string' ? record.utd : '';
      const content: string = typeof record.content === 'string' ? record.content.trim() : '';
      if (content.length > 0 && isTextUtd(utd)) {
        texts.push(content);
      } else if (uri.length > 0 && isTextUtd(utd)) {
        const fileText: string = this.readTextFromUri(uri);
        if (fileText.length > 0) {
          texts.push(fileText);
        }
      } else if (uri.length > 0) {
        const copied: string | null = this.copySharedUri(uri, i);
        if (copied != null) {
          imagePaths.push(copied);
        }
      } else if (content.length > 0) {
        texts.push(content);
      }
    }
    if (imagePaths.length > 0) {
      const payload: Map<string, Any> = this.newPayload('image', 'share');
      payload.set('imagePaths', imagePaths);
      return payload;
    }
    if (texts.length > 0) {
      const payload: Map<string, Any> = this.newPayload('text', 'share');
      payload.set('text', texts.join('\n'));
      return payload;
    }
    return null;
  }

  private readTextFromUri(uri: string): string {
    let source: fs.File | null = null;
    try {
      source = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const buffer: ArrayBuffer = new ArrayBuffer(SHARE_TEXT_FILE_MAX_BYTES);
      const readLength: number = fs.readSync(source.fd, buffer);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer, 0, readLength)).trim();
    } catch (err) {
      Log.e(TAG, 'Failed to read shared text file: ' + JSON.stringify(err));
      return '';
    } finally {
      const opened: fs.File | null = source;
      if (opened != null) {
        try {
          fs.closeSync(opened);
        } catch (closeErr) {
          Log.e(TAG, 'Failed to close shared text file: ' + JSON.stringify(closeErr));
        }
      }
    }
  }

  private copySharedUri(uri: string, index: number): string | null {
    let source: fs.File | null = null;
    let dest: fs.File | null = null;
    let target: string = '';
    try {
      const tempDir: string = this.context.tempDir;
      if (!fs.accessSync(tempDir)) {
        fs.mkdirSync(tempDir);
      }
      target = tempDir + '/' + SHARE_FILE_PREFIX + Date.now() + '_' + index + '.' + pickImageExtension(uri);
      source = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      dest = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.copyFileSync(source.fd, dest.fd);
      return target;
    } catch (err) {
      Log.e(TAG, 'Failed to copy shared file: ' + JSON.stringify(err));
      return null;
    } finally {
      const openedSource: fs.File | null = source;
      const openedDest: fs.File | null = dest;
      try {
        if (openedSource != null) {
          fs.closeSync(openedSource);
        }
        if (openedDest != null) {
          fs.closeSync(openedDest);
        }
      } catch (closeErr) {
        Log.e(TAG, 'Failed to close shared file: ' + JSON.stringify(closeErr));
      }
    }
  }

  private pruneOldShareFiles(): void {
    try {
      const tempDir: string = this.context.tempDir;
      if (!fs.accessSync(tempDir)) {
        return;
      }
      const names: Array<string> = fs.listFileSync(tempDir);
      const now: number = Date.now();
      for (let i: number = 0; i < names.length; i++) {
        if (!names[i].startsWith(SHARE_FILE_PREFIX)) {
          continue;
        }
        const path: string = tempDir + '/' + names[i];
        const stat: fs.Stat = fs.statSync(path);
        if (now - stat.mtime * 1000 > SHARE_FILE_MAX_AGE_MS) {
          fs.unlinkSync(path);
        }
      }
    } catch (err) {
      Log.e(TAG, 'Failed to prune shared temp files: ' + JSON.stringify(err));
    }
  }

  private dispatchSharedPayload(payload: Map<string, Any>): void {
    this.pendingSharedPayloads.push(payload);
    const activeChannel: MethodChannel | null = this.channel;
    if (activeChannel != null) {
      const ack: LiveAckCallback = new LiveAckCallback((): void => {
        this.removePending(this.pendingSharedPayloads, payload);
      });
      activeChannel.invokeMethod('onSharedPayload', payload, ack);
    }
  }

  /** Live native -> Dart `onCapturedEvent`; HarmonyOS has no producer today. */
  dispatchCapturedEvent(event: Map<string, Any>): void {
    this.pendingCapturedEvents.push(event);
    const activeChannel: MethodChannel | null = this.channel;
    if (activeChannel != null) {
      const ack: LiveAckCallback = new LiveAckCallback((): void => {
        this.removePending(this.pendingCapturedEvents, event);
      });
      activeChannel.invokeMethod('onCapturedEvent', event, ack);
    }
  }

  /** Live native -> Dart `onPromptAction`; HarmonyOS has no producer today. */
  dispatchPromptAction(action: Map<string, Any>): void {
    this.pendingPromptActions.push(action);
    const activeChannel: MethodChannel | null = this.channel;
    if (activeChannel != null) {
      const ack: LiveAckCallback = new LiveAckCallback((): void => {
        this.removePending(this.pendingPromptActions, action);
      });
      activeChannel.invokeMethod('onPromptAction', action, ack);
    }
  }

  private removePending(queue: Array<Map<string, Any>>, item: Map<string, Any>): void {
    const index: number = queue.indexOf(item);
    if (index >= 0) {
      queue.splice(index, 1);
    }
  }

  private drain(queue: Array<Map<string, Any>>): Array<Map<string, Any>> {
    const drained: Array<Map<string, Any>> = queue.splice(0, queue.length);
    return drained;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'consumePendingDeepLink': {
        const uri: string | null = this.pendingDeepLinkUri;
        this.pendingDeepLinkUri = null;
        result.success(uri);
        break;
      }
      case 'getAccessibilityStatus':
      case 'getNotificationListenerStatus':
      case 'getOverlayPermissionStatus':
        result.success(unsupportedStatusMap());
        break;
      case 'openAccessibilitySettings':
      case 'openNotificationListenerSettings':
      case 'openOverlaySettings':
      case 'syncAndroidAutoBillConfig':
      case 'showAutoBillPrompt':
      case 'requestPinWidget':
        // No third-party equivalent on HarmonyOS NEXT; Android-only capabilities
        // and programmatic card pinning are reported honestly as not performed.
        result.success(false);
        break;
      case 'consumeCapturedEvents':
        result.success(this.drain(this.pendingCapturedEvents));
        break;
      case 'consumePendingSharedPayloads':
        result.success(this.drain(this.pendingSharedPayloads));
        break;
      case 'consumePendingPromptActions':
        result.success(this.drain(this.pendingPromptActions));
        break;
      case 'recognizeImageOffline':
        this.handleRecognizeImageOffline(call, result);
        break;
      case 'updateWidgetSnapshot':
        this.handleUpdateWidgetSnapshot(call, result);
        break;
      case 'getActiveWidgetCounts':
        loadActiveForms(this.context).then((forms: Map<string, string>): void => {
          result.success(countsToMap(countByKind(forms)));
        }).catch((): void => {
          result.success(countsToMap(countByKind(new Map<string, string>())));
        });
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  private handleUpdateWidgetSnapshot(call: MethodCall, result: MethodResult): void {
    const data: WidgetCardData = new WidgetCardData();
    data.hasData = true;
    data.bookName = argString(call, 'bookName');
    data.periodLabel = argString(call, 'periodLabel');
    data.currencySymbol = argString(call, 'currencySymbol');
    data.expenseFormatted = argString(call, 'expenseFormatted');
    data.incomeFormatted = argString(call, 'incomeFormatted');
    data.balanceFormatted = argString(call, 'balanceFormatted');
    data.todayExpenseFormatted = argString(call, 'todayExpenseFormatted');
    data.budgetRemainingFormatted = argString(call, 'budgetRemainingFormatted');
    data.pendingDraftCount = Math.max(0, Math.trunc(argNumber(call, 'pendingDraftCount')));
    data.updatedAtMs = argNumber(call, 'updatedAtMs');

    saveSnapshot(this.context, data).then((): Promise<Map<string, number>> => {
      return refreshAllForms(this.context);
    }).then((counts: Map<string, number>): void => {
      result.success(countsToMap(counts));
    }).catch((err: Error): void => {
      Log.e(TAG, 'Failed to update widget snapshot: ' + JSON.stringify(err));
      result.error(ERROR_WIDGET_FAILED, '刷新桌面服务卡片失败', null);
    });
  }

  private handleRecognizeImageOffline(call: MethodCall, result: MethodResult): void {
    const bytesArg: Any = call.argument('bytes');
    if (!(bytesArg instanceof Uint8Array) || bytesArg.length === 0) {
      result.error(ERROR_OCR_FAILED, '图片数据为空', null);
      return;
    }
    if (!canIUse(OCR_SYSCAP)) {
      result.error(ERROR_OCR_UNSUPPORTED, '当前设备不支持本机离线文字识别（模拟器或系统版本过低）', null);
      return;
    }
    const bytes: Uint8Array = bytesArg as Uint8Array;
    this.runOfflineOcr(bytes).then((text: string): void => {
      const out: Map<string, Any> = new Map<string, Any>();
      out.set('supported', true);
      out.set('text', text);
      result.success(out);
    }).catch((err: Error): void => {
      Log.e(TAG, 'Offline OCR failed: ' + JSON.stringify(err));
      result.error(ERROR_OCR_FAILED, '本机离线文字识别失败', null);
    });
  }

  private async runOfflineOcr(bytes: Uint8Array): Promise<string> {
    let imageSource: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    let ocrInitialized: boolean = false;
    try {
      ocrInitialized = await textRecognition.init();
      const buffer: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      const source: image.ImageSource = image.createImageSource(buffer);
      imageSource = source;
      const info: image.ImageInfo = await source.getImageInfo();
      const options: image.DecodingOptions = {
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      };
      const longEdge: number = Math.max(info.size.width, info.size.height);
      if (longEdge > OCR_MAX_EDGE_PX) {
        const scale: number = OCR_MAX_EDGE_PX / longEdge;
        const target: image.Size = {
          width: Math.max(1, Math.floor(info.size.width * scale)),
          height: Math.max(1, Math.floor(info.size.height * scale)),
        };
        options.desiredSize = target;
      }
      const decoded: image.PixelMap = await source.createPixelMap(options);
      pixelMap = decoded;
      const visionInfo: textRecognition.VisionInfo = {
        pixelMap: decoded,
      };
      const configuration: textRecognition.TextRecognitionConfiguration = {
        isDirectionDetectionSupported: true,
      };
      const recognized: textRecognition.TextRecognitionResult = await textRecognition.recognizeText(visionInfo, configuration);
      return recognized.value;
    } finally {
      if (ocrInitialized) {
        try {
          await textRecognition.release();
        } catch (releaseErr) {
          Log.e(TAG, 'Failed to release OCR engine: ' + JSON.stringify(releaseErr));
        }
      }
      const mapToRelease: image.PixelMap | null = pixelMap;
      if (mapToRelease != null) {
        await mapToRelease.release();
      }
      const sourceToRelease: image.ImageSource | null = imageSource;
      if (sourceToRelease != null) {
        await sourceToRelease.release();
      }
    }
  }
}
