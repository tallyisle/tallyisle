import {
  Any,
  BinaryMessenger,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { BusinessError } from '@ohos.base';
import { i18n } from '@kit.LocalizationKit';
import userAuth from '@ohos.userIAM.userAuth';

const TAG: string = 'TallyIsleBiometricBridge';
const CHANNEL_NAME: string = 'dev.tallyisle/biometrics';

const STATUS_AVAILABLE: string = 'available';
const STATUS_NOT_ENROLLED: string = 'notEnrolled';
const STATUS_NO_HARDWARE: string = 'noHardware';
const STATUS_TEMPORARILY_UNAVAILABLE: string = 'temporarilyUnavailable';
const STATUS_UNSUPPORTED: string = 'unsupported';

const OUTCOME_AUTHENTICATED: string = 'authenticated';
const OUTCOME_CANCELLED: string = 'cancelled';
const OUTCOME_LOCKOUT: string = 'lockout';
const OUTCOME_UNAVAILABLE: string = 'unavailable';
const OUTCOME_FAILED: string = 'failed';

const CODE_PERMISSION_DENIED: number = 201;
const CODE_SUCCESS: number = 12500000;
const CODE_CANCELED: number = 12500003;
const CODE_TYPE_NOT_SUPPORT: number = 12500005;
const CODE_TRUST_LEVEL_NOT_SUPPORT: number = 12500006;
const CODE_LOCKED: number = 12500009;
const CODE_NOT_ENROLLED: number = 12500010;
const CODE_CANCELED_FROM_WIDGET: number = 12500011;

class BiometricProbeResult {
  status: string;
  reason: string;
  deviceSecure: boolean;
  preferredType: userAuth.UserAuthType | null;

  constructor(
    status: string,
    reason: string,
    deviceSecure: boolean,
    preferredType: userAuth.UserAuthType | null
  ) {
    this.status = status;
    this.reason = reason;
    this.deviceSecure = deviceSecure;
    this.preferredType = preferredType;
  }

  toWireMap(): Map<string, Any> {
    const map: Map<string, Any> = new Map<string, Any>();
    map.set('status', this.status);
    map.set('reason', this.reason);
    map.set('deviceSecure', this.deviceSecure);
    return map;
  }
}

class AuthSession {
  private instance: userAuth.UserAuthInstance | null = null;
  private callback: userAuth.IAuthCallback | null = null;
  private result: MethodResult;
  private finished: boolean = false;

  constructor(result: MethodResult) {
    this.result = result;
  }

  attachInstance(
    instance: userAuth.UserAuthInstance,
    callback: userAuth.IAuthCallback
  ): void {
    this.instance = instance;
    this.callback = callback;
  }

  complete(outcome: string, message: string): boolean {
    if (this.finished) {
      return false;
    }
    this.finished = true;
    if (this.instance != null) {
      try {
        if (this.callback != null) {
          this.instance.off('result', this.callback);
        } else {
          this.instance.off('result');
        }
      } catch (_ignoreOff) {
        // Ignore listener detach errors after completion.
      }
      this.instance = null;
      this.callback = null;
    }
    const payload: Map<string, Any> = new Map<string, Any>();
    payload.set('outcome', outcome);
    payload.set('message', message);
    this.result.success(payload);
    return true;
  }

  cancel(reason: string): void {
    if (this.finished) {
      return;
    }
    const activeInstance: userAuth.UserAuthInstance | null = this.instance;
    if (activeInstance != null) {
      try {
        activeInstance.cancel();
      } catch (_ignoreCancel) {
        // Ignore cancellation race if prompt already closed.
      }
    }
    this.complete(OUTCOME_CANCELLED, reason);
  }
}

class BiometricAuthCallback implements userAuth.IAuthCallback {
  private bridge: BiometricBridge;
  private session: AuthSession;

  constructor(bridge: BiometricBridge, session: AuthSession) {
    this.bridge = bridge;
    this.session = session;
  }

  onResult(authResult: userAuth.UserAuthResult): void {
    this.bridge.onAuthResultCode(this.session, authResult.result);
  }
}

function probeAuthTypeStatus(authType: userAuth.UserAuthType): number {
  try {
    userAuth.getAvailableStatus(authType, userAuth.AuthTrustLevel.ATL1);
    return 0;
  } catch (err) {
    const bizErr: BusinessError = err as BusinessError;
    if (bizErr && typeof bizErr.code === 'number') {
      return bizErr.code;
    }
    return -1;
  }
}

function isChineseSystemLanguage(): boolean {
  try {
    const language: string = i18n.System.getSystemLanguage();
    return language.trim().toLowerCase().startsWith('zh');
  } catch (_err) {
    return false;
  }
}

function buildChallengeBytes(): Uint8Array {
  const challenge: Uint8Array = new Uint8Array(8);
  let seed: number = Date.now();
  for (let i: number = 0; i < 8; i++) {
    challenge[i] = (seed + i * 31) & 0xff;
    seed = Math.floor(seed / 256);
  }
  if (challenge[0] === 0) {
    challenge[0] = 0x5a;
  }
  return challenge;
}

export class BiometricBridge implements MethodCallHandler {
  private channel: MethodChannel | null = null;
  private activeSession: AuthSession | null = null;

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
    this.cancelCurrentSession('已取消生物识别验证');
  }

  shutdown(): void {
    this.detach();
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'checkAvailability':
        result.success(this.queryAvailability().toWireMap());
        break;
      case 'authenticate':
        this.handleAuthenticate(call, result);
        break;
      case 'cancelAuthentication':
        this.cancelCurrentSession('已取消生物识别验证');
        result.success(null);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  private queryAvailability(): BiometricProbeResult {
    const pinCode: number = probeAuthTypeStatus(userAuth.UserAuthType.PIN);
    const deviceSecure: boolean = pinCode === 0;

    const fpCode: number = probeAuthTypeStatus(userAuth.UserAuthType.FINGERPRINT);
    if (fpCode === 0) {
      return new BiometricProbeResult(
        STATUS_AVAILABLE,
        '可使用系统指纹或面容解锁',
        deviceSecure,
        userAuth.UserAuthType.FINGERPRINT
      );
    }

    const faceCode: number = probeAuthTypeStatus(userAuth.UserAuthType.FACE);
    if (faceCode === 0) {
      return new BiometricProbeResult(
        STATUS_AVAILABLE,
        '可使用系统面容解锁',
        deviceSecure,
        userAuth.UserAuthType.FACE
      );
    }

    if (fpCode === CODE_PERMISSION_DENIED || faceCode === CODE_PERMISSION_DENIED) {
      return new BiometricProbeResult(
        STATUS_UNSUPPORTED,
        '未授予系统生物识别权限，请使用数字密码解锁',
        deviceSecure,
        null
      );
    }

    if (fpCode === CODE_NOT_ENROLLED || faceCode === CODE_NOT_ENROLLED) {
      return new BiometricProbeResult(
        STATUS_NOT_ENROLLED,
        '系统尚未录入指纹或面容，请先在系统设置中录入',
        deviceSecure,
        null
      );
    }

    const fpNoHw: boolean =
      fpCode === CODE_TYPE_NOT_SUPPORT || fpCode === CODE_TRUST_LEVEL_NOT_SUPPORT;
    const faceNoHw: boolean =
      faceCode === CODE_TYPE_NOT_SUPPORT || faceCode === CODE_TRUST_LEVEL_NOT_SUPPORT;
    if (fpNoHw && faceNoHw) {
      return new BiometricProbeResult(
        STATUS_NO_HARDWARE,
        '当前设备无指纹或面容识别硬件',
        deviceSecure,
        null
      );
    }

    return new BiometricProbeResult(
      STATUS_TEMPORARILY_UNAVAILABLE,
      '生物识别硬件暂不可用，请使用数字密码',
      deviceSecure,
      null
    );
  }

  private handleAuthenticate(call: MethodCall, result: MethodResult): void {
    const availability: BiometricProbeResult = this.queryAvailability();
    if (availability.status !== STATUS_AVAILABLE || availability.preferredType == null) {
      const unavailableMap: Map<string, Any> = new Map<string, Any>();
      unavailableMap.set('outcome', OUTCOME_UNAVAILABLE);
      unavailableMap.set('message', availability.reason);
      result.success(unavailableMap);
      return;
    }

    this.cancelCurrentSession('已开启新的生物识别请求');

    const isZh: boolean = isChineseSystemLanguage();
    const defaultTitle: string = isZh
      ? '验证身份以解锁帐屿'
      : 'Verify identity to unlock TallyIsle';
    const defaultNegative: string = isZh ? '使用数字密码' : 'Use PIN';

    const rawTitleArg: Any = call.argument('title');
    const titleText: string =
      (typeof rawTitleArg === 'string' && rawTitleArg.trim().length > 0)
        ? rawTitleArg.trim().substring(0, 200)
        : defaultTitle;

    const rawNegArg: Any = call.argument('negativeButtonText');
    const negativeText: string =
      (typeof rawNegArg === 'string' && rawNegArg.trim().length > 0)
        ? rawNegArg.trim().substring(0, 60)
        : defaultNegative;

    const session: AuthSession = new AuthSession(result);
    this.activeSession = session;

    try {
      // Single UserAuthType ensures WidgetParam.navigationButtonText is supported on API 12-17+.
      const authParam: userAuth.AuthParam = {
        challenge: buildChallengeBytes(),
        authType: [availability.preferredType],
        authTrustLevel: userAuth.AuthTrustLevel.ATL1,
      };
      const widgetParam: userAuth.WidgetParam = {
        title: titleText,
        navigationButtonText: negativeText,
      };
      const authInstance: userAuth.UserAuthInstance = userAuth.getUserAuthInstance(
        authParam,
        widgetParam
      );
      const authCallback: BiometricAuthCallback = new BiometricAuthCallback(this, session);
      session.attachInstance(authInstance, authCallback);

      authInstance.on('result', authCallback);
      authInstance.start();
    } catch (err) {
      Log.e(TAG, 'Failed starting UserAuthInstance: ' + JSON.stringify(err));
      const bizErr: BusinessError = err as BusinessError;
      if (bizErr && typeof bizErr.code === 'number') {
        this.onAuthResultCode(session, bizErr.code);
      } else {
        this.finishSession(session, OUTCOME_UNAVAILABLE, '无法调起系统生物识别，请使用数字密码');
      }
    }
  }

  onAuthResultCode(session: AuthSession, code: number): void {
    if (code === CODE_SUCCESS) {
      this.finishSession(session, OUTCOME_AUTHENTICATED, '生物识别验证通过');
    } else if (code === CODE_CANCELED_FROM_WIDGET) {
      this.finishSession(session, OUTCOME_CANCELLED, '已切换为数字密码验证');
    } else if (code === CODE_CANCELED) {
      this.finishSession(session, OUTCOME_CANCELLED, '已取消生物识别，请输入数字密码');
    } else if (code === CODE_LOCKED) {
      this.finishSession(session, OUTCOME_LOCKOUT, '生物识别尝试次数过多，请使用数字密码解锁');
    } else if (
      code === CODE_NOT_ENROLLED ||
      code === CODE_TYPE_NOT_SUPPORT ||
      code === CODE_TRUST_LEVEL_NOT_SUPPORT
    ) {
      this.finishSession(session, OUTCOME_UNAVAILABLE, '生物识别当前不可用，请使用数字密码');
    } else {
      this.finishSession(session, OUTCOME_FAILED, '生物识别未通过，请使用数字密码');
    }
  }

  private finishSession(session: AuthSession, outcome: string, message: string): void {
    if (this.activeSession === session) {
      this.activeSession = null;
    }
    session.complete(outcome, message);
  }

  private cancelCurrentSession(reason: string): void {
    const existing: AuthSession | null = this.activeSession;
    if (existing == null) {
      return;
    }
    this.activeSession = null;
    existing.cancel(reason);
  }
}
