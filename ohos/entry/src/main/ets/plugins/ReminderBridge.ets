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
import notificationManager from '@ohos.notificationManager';
import reminderAgentManager from '@ohos.reminderAgentManager';

const TAG: string = 'TallyIsleReminderBridge';
const CHANNEL_NAME: string = 'dev.tallyisle/reminders';
const STORE_FILE_NAME: string = 'reminders_ohos.json';
const EXTRA_LAUNCH_ROUTE: string = 'launch_route';
const DEFAULT_REMINDER_TIP: string = '别忘了记录今天的收支哦';
const DEFAULT_LAUNCH_ROUTE: string = '/record/new';
const APP_BUNDLE_NAME: string = 'dev.tallyisle.app';
const APP_ABILITY_NAME: string = 'EntryAbility';

interface PersistedReminderRecord {
  id: number;
  hour: number;
  minute: number;
  title: string;
  body: string;
  route: string;
  osReminderId: number;
}

function clampInt(value: number, minVal: number, maxVal: number): number {
  const truncated: number = Math.trunc(value);
  if (truncated < minVal) {
    return minVal;
  }
  if (truncated > maxVal) {
    return maxVal;
  }
  return truncated;
}

function parseIncomingReminders(rawArg: Any): Array<PersistedReminderRecord> {
  const parsed: Array<PersistedReminderRecord> = new Array<PersistedReminderRecord>();
  if (!(rawArg instanceof Array)) {
    return parsed;
  }
  const items: Array<Any> = rawArg as Array<Any>;
  for (let i: number = 0; i < items.length; i++) {
    const entry: Any = items[i];
    if (entry instanceof Map) {
      const map: Map<Any, Any> = entry as Map<Any, Any>;
      const rawId: Any = map.get('id');
      if (typeof rawId !== 'number') {
        continue;
      }
      const rawHour: Any = map.get('hour');
      const rawMinute: Any = map.get('minute');
      const rawTitle: Any = map.get('title');
      const rawBody: Any = map.get('body');
      const rawRoute: Any = map.get('route');

      const hour: number = typeof rawHour === 'number' ? clampInt(rawHour, 0, 23) : 20;
      const minute: number = typeof rawMinute === 'number' ? clampInt(rawMinute, 0, 59) : 0;
      const title: string =
        (typeof rawTitle === 'string' && rawTitle.trim().length > 0)
          ? rawTitle
          : DEFAULT_REMINDER_TIP;
      const body: string = typeof rawBody === 'string' ? rawBody : '';
      const route: string =
        (typeof rawRoute === 'string' && rawRoute.trim().length > 0)
          ? rawRoute
          : DEFAULT_LAUNCH_ROUTE;

      const rec: PersistedReminderRecord = {
        id: Math.trunc(rawId),
        hour: hour,
        minute: minute,
        title: title,
        body: body,
        route: route,
        osReminderId: -1,
      };
      parsed.push(rec);
    }
  }
  return parsed;
}

export class ReminderBridge implements MethodCallHandler {
  private context: common.UIAbilityContext;
  private channel: MethodChannel | null = null;
  private pendingLaunchRoute: string | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
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

  captureWant(want: Want | null, notifyFlutter: boolean): void {
    if (want == null || want.parameters == null) {
      return;
    }
    const params: Record<string, Object> = want.parameters as Record<string, Object>;
    const rawRoute: Object | undefined = params[EXTRA_LAUNCH_ROUTE];
    if (typeof rawRoute !== 'string') {
      return;
    }
    const route: string = rawRoute.trim();
    if (route.length === 0) {
      return;
    }
    params[EXTRA_LAUNCH_ROUTE] = '';
    this.pendingLaunchRoute = route;

    const activeChannel: MethodChannel | null = this.channel;
    if (notifyFlutter && activeChannel != null) {
      const replyCallback: MethodResult = {
        success: (handled: Any): void => {
          if (handled === true && this.pendingLaunchRoute === route) {
            this.pendingLaunchRoute = null;
          }
        },
        error: (_code: string, _msg: string, _details: Any): void => {},
        notImplemented: (): void => {},
      };
      activeChannel.invokeMethod('onLaunchRoute', route, replyCallback);
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'syncReminders':
        this.handleSyncReminders(call, result);
        break;
      case 'cancelReminder':
        this.handleCancelReminder(call, result);
        break;
      case 'cancelAll':
        this.handleCancelAll(result);
        break;
      case 'areNotificationsEnabled':
        this.handleAreNotificationsEnabled(result);
        break;
      case 'requestPermission':
        this.handleRequestPermission(result);
        break;
      case 'openNotificationSettings':
        this.handleOpenNotificationSettings(result);
        break;
      case 'consumePendingLaunchRoute': {
        const route: string | null = this.pendingLaunchRoute;
        this.pendingLaunchRoute = null;
        result.success(route);
        break;
      }
      default:
        result.notImplemented();
        break;
    }
  }

  private handleAreNotificationsEnabled(result: MethodResult): void {
    notificationManager.isNotificationEnabled().then((enabled: boolean): void => {
      result.success(enabled);
    }).catch((_err: Error): void => {
      result.success(false);
    });
  }

  private handleRequestPermission(result: MethodResult): void {
    notificationManager.requestEnableNotification(this.context).then((): void => {
      notificationManager.isNotificationEnabled().then((enabled: boolean): void => {
        result.success(enabled);
      }).catch((_innerErr: Error): void => {
        result.success(false);
      });
    }).catch((_err: Error): void => {
      // requestEnableNotification rejects if already enabled or dismissed; check actual state.
      notificationManager.isNotificationEnabled().then((enabled: boolean): void => {
        result.success(enabled);
      }).catch((_innerErr: Error): void => {
        result.success(false);
      });
    });
  }

  private handleOpenNotificationSettings(result: MethodResult): void {
    notificationManager.openNotificationSettings(this.context).then((): void => {
      result.success(null);
    }).catch((_err: Error): void => {
      const settingsParams: Record<string, Object> = {
        'pushParams': APP_BUNDLE_NAME,
      };
      const fallbackWant: Want = {
        bundleName: 'com.huawei.hmos.settings',
        abilityName: 'com.huawei.hmos.settings.MainAbility',
        uri: 'application_info_entry',
        parameters: settingsParams,
      };
      this.context.startAbility(fallbackWant).then((): void => {
        result.success(null);
      }).catch((fallbackErr: Error): void => {
        Log.e(TAG, 'Failed opening notification settings: ' + JSON.stringify(fallbackErr));
        result.error('SETTINGS_UNAVAILABLE', '无法打开系统通知设置', null);
      });
    });
  }

  private handleSyncReminders(call: MethodCall, result: MethodResult): void {
    const incoming: Array<PersistedReminderRecord> = parseIncomingReminders(
      call.argument('reminders')
    );
    this.syncAsync(incoming).then((): void => {
      result.success(null);
    }).catch((err: Error): void => {
      Log.e(TAG, 'syncReminders failed: ' + JSON.stringify(err));
      result.success(null);
    });
  }

  private handleCancelReminder(call: MethodCall, result: MethodResult): void {
    const idArg: Any = call.argument('id');
    if (typeof idArg !== 'number') {
      result.success(null);
      return;
    }
    const targetId: number = Math.trunc(idArg);
    this.cancelOneAsync(targetId).then((): void => {
      result.success(null);
    }).catch((_err: Error): void => {
      result.success(null);
    });
  }

  private handleCancelAll(result: MethodResult): void {
    this.cancelAllAsync().then((): void => {
      result.success(null);
    }).catch((_err: Error): void => {
      result.success(null);
    });
  }

  private async syncAsync(incoming: Array<PersistedReminderRecord>): Promise<void> {
    const existing: Array<PersistedReminderRecord> = this.readStore();
    for (let i: number = 0; i < existing.length; i++) {
      if (existing[i].osReminderId >= 0) {
        try {
          await reminderAgentManager.cancelReminder(existing[i].osReminderId);
        } catch (_ignoreCancel) {
          // Ignore already-expired or unpermitted reminder cancellations.
        }
      }
    }

    for (let i: number = 0; i < incoming.length; i++) {
      const item: PersistedReminderRecord = incoming[i];
      const launchParams: Record<string, Object> = {
        'launch_route': item.route,
      };
      const alarmReq: reminderAgentManager.ReminderRequestAlarm = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_ALARM,
        hour: item.hour,
        minute: item.minute,
        daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
        title: item.title,
        content: item.body,
        notificationId: 40000 + item.id,
        slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        tapDismissed: true,
        wantAgent: {
          pkgName: APP_BUNDLE_NAME,
          abilityName: APP_ABILITY_NAME,
          parameters: launchParams,
        },
      };
      try {
        const osId: number = await reminderAgentManager.publishReminder(alarmReq);
        item.osReminderId = osId;
      } catch (pubErr) {
        // Unapproved consumer builds without PUBLISH_AGENT_REMINDER ACL receive 201;
        // keep persisted state intact without failing user reminder saves.
        Log.w(TAG, 'publishReminder degraded cleanly: ' + JSON.stringify(pubErr));
        item.osReminderId = -1;
      }
    }

    this.writeStore(incoming);
  }

  private async cancelOneAsync(id: number): Promise<void> {
    const existing: Array<PersistedReminderRecord> = this.readStore();
    const remaining: Array<PersistedReminderRecord> = new Array<PersistedReminderRecord>();
    for (let i: number = 0; i < existing.length; i++) {
      if (existing[i].id === id) {
        if (existing[i].osReminderId >= 0) {
          try {
            await reminderAgentManager.cancelReminder(existing[i].osReminderId);
          } catch (_ignoreCancel) {
            // Best-effort OS reminder cancellation.
          }
        }
      } else {
        remaining.push(existing[i]);
      }
    }
    this.writeStore(remaining);
  }

  private async cancelAllAsync(): Promise<void> {
    const existing: Array<PersistedReminderRecord> = this.readStore();
    for (let i: number = 0; i < existing.length; i++) {
      if (existing[i].osReminderId >= 0) {
        try {
          await reminderAgentManager.cancelReminder(existing[i].osReminderId);
        } catch (_ignoreCancel) {
          // Best-effort individual cancellation.
        }
      }
    }
    try {
      await reminderAgentManager.cancelAllReminders();
    } catch (_ignoreCancelAll) {
      // Ignore if reminder agent permission is unavailable.
    }
    this.writeStore(new Array<PersistedReminderRecord>());
  }

  private storeFilePath(): string {
    return this.context.filesDir + '/' + STORE_FILE_NAME;
  }

  private readStore(): Array<PersistedReminderRecord> {
    const path: string = this.storeFilePath();
    try {
      if (!fs.accessSync(path)) {
        return new Array<PersistedReminderRecord>();
      }
      const text: string = fs.readTextSync(path);
      if (!text || text.trim().length === 0) {
        return new Array<PersistedReminderRecord>();
      }
      const decoded: Array<PersistedReminderRecord> =
        JSON.parse(text) as Array<PersistedReminderRecord>;
      if (decoded instanceof Array) {
        return decoded;
      }
    } catch (_err) {
      // Ignore corrupted store and start fresh.
    }
    return new Array<PersistedReminderRecord>();
  }

  private writeStore(records: Array<PersistedReminderRecord>): void {
    const path: string = this.storeFilePath();
    try {
      const jsonText: string = JSON.stringify(records);
      const outFile: fs.File = fs.openSync(
        path,
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC
      );
      try {
        fs.writeSync(outFile.fd, jsonText);
        fs.fsyncSync(outFile.fd);
      } finally {
        fs.closeSync(outFile);
      }
    } catch (err) {
      Log.e(TAG, 'Failed persisting reminder store: ' + JSON.stringify(err));
    }
  }
}
