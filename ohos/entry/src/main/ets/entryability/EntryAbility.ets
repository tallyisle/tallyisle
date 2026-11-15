import { BinaryMessenger, FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { FileBridge } from '../plugins/FileBridge';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';

export default class EntryAbility extends FlutterAbility {
  private fileBridge: FileBridge | null = null;

  configureFlutterEngine(flutterEngine: FlutterEngine): void {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine);

    const messenger: BinaryMessenger = flutterEngine.dartExecutor.getBinaryMessenger();
    this.fileBridge = new FileBridge(this.context);
    this.fileBridge.attach(messenger);
  }

  cleanUpFlutterEngine(flutterEngine: FlutterEngine): void {
    if (this.fileBridge != null) {
      this.fileBridge.detach();
      this.fileBridge = null;
    }
    super.cleanUpFlutterEngine(flutterEngine);
  }
}
