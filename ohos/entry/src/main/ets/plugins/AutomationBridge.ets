import {
  Any,
  BinaryMessenger,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import Want from '@ohos.app.ability.Want';

const CHANNEL_NAME: string = 'dev.tallyisle/automation';
const STATUS_UNSUPPORTED_LABEL: string = '当前平台不支持';

function extractSupportedDeepLink(rawUri: string): string | null {
  const trimmed: string = rawUri.trim();
  if (trimmed.length === 0) {
    return null;
  }
  const lower: string = trimmed.toLowerCase();
  let rest: string = '';
  if (lower.startsWith('tallyisle://')) {
    rest = lower.substring(12);
  } else if (lower.startsWith('yyjz://')) {
    rest = lower.substring(7);
  } else {
    return null;
  }

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

function emptyWidgetCountsMap(): Map<string, Any> {
  const counts: Map<string, Any> = new Map<string, Any>();
  counts.set('quick_add', 0);
  counts.set('month_summary', 0);
  counts.set('month_bar', 0);
  return counts;
}

class DeepLinkAckCallback implements MethodResult {
  private bridge: AutomationBridge;
  private expectedUri: string;

  constructor(bridge: AutomationBridge, expectedUri: string) {
    this.bridge = bridge;
    this.expectedUri = expectedUri;
  }

  success = (handled: Any): void => {
    if (handled === true) {
      this.bridge.acknowledgeDeepLink(this.expectedUri);
    }
  };

  error = (_code: string, _msg: string, _details: Any): void => {};

  notImplemented = (): void => {};
}

export class AutomationBridge implements MethodCallHandler {
  private channel: MethodChannel | null = null;
  private pendingDeepLinkUri: string | null = null;

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
   * Captures an incoming `tallyisle://` or `yyjz://` deep-link [Want] from `onCreate`
   * or `onNewWant`. Clears `want.uri` when matched so Flutter's default navigation channel
   * does not push the raw custom-scheme URI as an unknown route.
   */
  captureWant(want: Want | null, notifyFlutter: boolean): boolean {
    if (want == null || typeof want.uri !== 'string') {
      return false;
    }
    const matchedUri: string | null = extractSupportedDeepLink(want.uri);
    if (matchedUri == null) {
      return false;
    }

    want.uri = '';
    this.pendingDeepLinkUri = matchedUri;

    const activeChannel: MethodChannel | null = this.channel;
    if (notifyFlutter && activeChannel != null) {
      const replyCallback: DeepLinkAckCallback = new DeepLinkAckCallback(this, matchedUri);
      activeChannel.invokeMethod('onDeepLink', matchedUri, replyCallback);
    }
    return true;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'consumePendingDeepLink': {
        const uri: string | null = this.pendingDeepLinkUri;
        this.pendingDeepLinkUri = null;
        result.success(uri);
        break;
      }
      case 'getAccessibilityStatus': {
        // Honest capability degradation on HarmonyOS NEXT (ADR-008): third-party apps
        // cannot register system-wide cross-app AccessibilityService screen readers.
        const status: Map<string, Any> = new Map<string, Any>();
        status.set('supported', false);
        status.set('enabled', false);
        status.set('statusLabel', STATUS_UNSUPPORTED_LABEL);
        result.success(status);
        break;
      }
      case 'openAccessibilitySettings':
        result.success(false);
        break;
      case 'consumeCapturedEvents':
        result.success(new Array<Any>());
        break;
      case 'updateWidgetSnapshot':
      case 'getActiveWidgetCounts':
        result.success(emptyWidgetCountsMap());
        break;
      case 'requestPinWidget':
        result.success(false);
        break;
      default:
        result.notImplemented();
        break;
    }
  }
}
