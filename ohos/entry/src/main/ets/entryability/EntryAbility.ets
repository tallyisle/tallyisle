import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import { BinaryMessenger, FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { AutomationBridge } from '../plugins/AutomationBridge';
import { BiometricBridge } from '../plugins/BiometricBridge';
import { FileBridge } from '../plugins/FileBridge';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { ReminderBridge } from '../plugins/ReminderBridge';

export default class EntryAbility extends FlutterAbility {
  private fileBridge: FileBridge | null = null;
  private biometricBridge: BiometricBridge | null = null;
  private automationBridge: AutomationBridge | null = null;
  private reminderBridge: ReminderBridge | null = null;

  private ensureAutomationBridge(): AutomationBridge {
    if (this.automationBridge == null) {
      this.automationBridge = new AutomationBridge();
    }
    return this.automationBridge;
  }

  private ensureReminderBridge(): ReminderBridge {
    if (this.reminderBridge == null) {
      this.reminderBridge = new ReminderBridge(this.context);
    }
    return this.reminderBridge;
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const handledDeepLink: boolean = this.ensureAutomationBridge().captureWant(want, false);
    if (!handledDeepLink) {
      this.ensureReminderBridge().captureWant(want, false);
    }
    super.onCreate(want, launchParam);
  }

  onNewWant(want: Want, launchParams: AbilityConstant.LaunchParam): void {
    const handledDeepLink: boolean = this.ensureAutomationBridge().captureWant(want, true);
    if (!handledDeepLink) {
      this.ensureReminderBridge().captureWant(want, true);
    }
    super.onNewWant(want, launchParams);
  }

  configureFlutterEngine(flutterEngine: FlutterEngine): void {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine);

    const messenger: BinaryMessenger = flutterEngine.dartExecutor.getBinaryMessenger();

    if (this.fileBridge == null) {
      this.fileBridge = new FileBridge(this.context);
    }
    this.fileBridge.attach(messenger);

    if (this.biometricBridge == null) {
      this.biometricBridge = new BiometricBridge();
    }
    this.biometricBridge.attach(messenger);

    this.ensureAutomationBridge().attach(messenger);
    this.ensureReminderBridge().attach(messenger);
  }

  cleanUpFlutterEngine(flutterEngine: FlutterEngine): void {
    if (this.fileBridge != null) {
      this.fileBridge.detach();
    }
    if (this.biometricBridge != null) {
      this.biometricBridge.detach();
    }
    if (this.automationBridge != null) {
      this.automationBridge.detach();
    }
    if (this.reminderBridge != null) {
      this.reminderBridge.detach();
    }
    super.cleanUpFlutterEngine(flutterEngine);
  }

  onDestroy(): void {
    if (this.fileBridge != null) {
      this.fileBridge.detach();
      this.fileBridge = null;
    }
    if (this.biometricBridge != null) {
      this.biometricBridge.shutdown();
      this.biometricBridge = null;
    }
    if (this.automationBridge != null) {
      this.automationBridge.detach();
      this.automationBridge = null;
    }
    if (this.reminderBridge != null) {
      this.reminderBridge.detach();
      this.reminderBridge = null;
    }
    super.onDestroy();
  }
}
