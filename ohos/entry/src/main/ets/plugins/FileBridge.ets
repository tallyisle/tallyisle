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
import fileUri from '@ohos.file.fileuri';
import picker from '@ohos.file.picker';
import uniformTypeDescriptor from '@ohos.data.uniformTypeDescriptor';
import { systemShare } from '@kit.ShareKit';

const TAG: string = 'TallyIsleFileBridge';
const CHANNEL_NAME: string = 'com.tallyisle/files';
const SHARED_EXPORTS_DIR: string = 'shared_exports';
const EXPORT_CACHE_TTL_MS: number = 24 * 60 * 60 * 1000;

const ERROR_CANCELLED: string = 'CANCELLED';
const ERROR_INVALID_ARGS: string = 'INVALID_ARGS';
const ERROR_IO: string = 'IO_ERROR';
const ERROR_UNAVAILABLE: string = 'UNAVAILABLE';

function sanitizeFileName(raw: string, fallback: string): string {
  const trimmed: string = raw.trim();
  if (trimmed.length === 0) {
    return fallback;
  }
  const normalized: string = trimmed
    .split('/').join('_')
    .split('\\').join('_')
    .split('\u0000').join('_');
  if (normalized === '.' || normalized === '..') {
    return fallback;
  }
  return normalized;
}

function normalizeDirectoryPath(rawPath: string): string {
  let clean: string = rawPath.trim();
  while (clean.length > 1 && clean.endsWith('/')) {
    clean = clean.substring(0, clean.length - 1);
  }
  return clean;
}

function extractExtension(fileName: string): string {
  const dotIndex: number = fileName.lastIndexOf('.');
  if (dotIndex < 0 || dotIndex === fileName.length - 1) {
    return '';
  }
  return fileName.substring(dotIndex + 1).toLowerCase();
}

function hasValidHttpHost(url: string): boolean {
  const lower: string = url.toLowerCase();
  let rest: string = '';
  if (lower.startsWith('https://')) {
    rest = url.substring(8);
  } else if (lower.startsWith('http://')) {
    rest = url.substring(7);
  } else {
    return false;
  }
  const slashIdx: number = rest.indexOf('/');
  const queryIdx: number = rest.indexOf('?');
  const hashIdx: number = rest.indexOf('#');
  let endIdx: number = rest.length;
  if (slashIdx >= 0 && slashIdx < endIdx) {
    endIdx = slashIdx;
  }
  if (queryIdx >= 0 && queryIdx < endIdx) {
    endIdx = queryIdx;
  }
  if (hashIdx >= 0 && hashIdx < endIdx) {
    endIdx = hashIdx;
  }
  const authority: string = rest.substring(0, endIdx).trim();
  return authority.length > 0;
}

function resolveUniformTypeId(fileName: string): string {
  const ext: string = extractExtension(fileName);
  if (ext.length > 0) {
    try {
      const matched: string = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(
        '.' + ext,
        uniformTypeDescriptor.UniformDataType.FILE
      );
      if (matched && matched.length > 0) {
        return matched;
      }
    } catch (_err) {
      // Custom extensions such as .tally fall back cleanly to general.file.
    }
  }
  return uniformTypeDescriptor.UniformDataType.FILE;
}

export class FileBridge implements MethodCallHandler {
  private context: common.UIAbilityContext;
  private channel: MethodChannel | null = null;

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

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'saveBytes':
        this.handleSaveBytes(call, result);
        break;
      case 'shareBytes':
        this.handleShareBytes(call, result);
        break;
      case 'openExternalUrl':
        this.handleOpenExternalUrl(call, result);
        break;
      case 'pickBackupDirectory':
        this.handlePickBackupDirectory(result);
        break;
      case 'checkDirectoryAccessible':
        this.handleCheckDirectoryAccessible(call, result);
        break;
      case 'listDirectoryBackups':
        this.handleListDirectoryBackups(call, result);
        break;
      case 'writeDirectoryBackup':
        this.handleWriteDirectoryBackup(call, result);
        break;
      case 'readDirectoryBackup':
        this.handleReadDirectoryBackup(call, result);
        break;
      case 'deleteDirectoryBackup':
        this.handleDeleteDirectoryBackup(call, result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  private handleSaveBytes(call: MethodCall, result: MethodResult): void {
    const bytesArg: Any = call.argument('bytes');
    if (!(bytesArg instanceof Uint8Array)) {
      result.error(ERROR_INVALID_ARGS, '缺少待保存文件内容', null);
      return;
    }
    const bytes: Uint8Array = bytesArg as Uint8Array;
    const rawNameArg: Any = call.argument('suggestedName');
    const rawName: string = typeof rawNameArg === 'string' ? rawNameArg : '';
    const safeName: string = sanitizeFileName(rawName, 'backup.tally');

    const saveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [safeName];

    let documentPicker: picker.DocumentViewPicker;
    try {
      documentPicker = new picker.DocumentViewPicker(this.context);
    } catch (err) {
      Log.e(TAG, 'Failed to create DocumentViewPicker: ' + JSON.stringify(err));
      result.error(ERROR_UNAVAILABLE, '无法打开系统文件保存器', null);
      return;
    }

    documentPicker.save(saveOptions).then((uris: Array<string>): void => {
      if (!uris || uris.length === 0 || uris[0].length === 0) {
        result.error(ERROR_CANCELLED, '已取消保存', null);
        return;
      }
      try {
        const slice: ArrayBuffer = bytes.buffer.slice(
          bytes.byteOffset,
          bytes.byteOffset + bytes.byteLength
        );
        const targetFile: fs.File = fs.openSync(
          uris[0],
          fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC
        );
        try {
          fs.writeSync(targetFile.fd, slice);
          fs.fsyncSync(targetFile.fd);
        } finally {
          fs.closeSync(targetFile);
        }
        result.success(null);
      } catch (ioErr) {
        Log.e(TAG, 'Failed writing saved file: ' + JSON.stringify(ioErr));
        result.error(ERROR_IO, '文件未完成保存', null);
      }
    }).catch((err: Error): void => {
      Log.e(TAG, 'DocumentViewPicker.save failed: ' + JSON.stringify(err));
      result.error(ERROR_IO, '文件未完成保存', null);
    });
  }

  private handlePickBackupDirectory(result: MethodResult): void {
    const saveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    saveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;

    let documentPicker: picker.DocumentViewPicker;
    try {
      documentPicker = new picker.DocumentViewPicker(this.context);
    } catch (err) {
      Log.e(TAG, 'Failed to create DocumentViewPicker for DOWNLOAD: ' + JSON.stringify(err));
      result.error(ERROR_UNAVAILABLE, '无法打开系统下载目录授权', null);
      return;
    }

    documentPicker.save(saveOptions).then((uris: Array<string>): void => {
      if (!uris || uris.length === 0 || uris[0].length === 0) {
        result.error(ERROR_CANCELLED, '已取消选择备份目录', null);
        return;
      }
      try {
        const dirPath: string = normalizeDirectoryPath(new fileUri.FileUri(uris[0]).path);
        if (dirPath.length === 0) {
          result.error(ERROR_IO, '未能解析公共下载目录路径', null);
          return;
        }
        if (!fs.accessSync(dirPath)) {
          fs.mkdirSync(dirPath);
        }
        const binding: Map<string, Any> = new Map<string, Any>();
        binding.set('mode', 'ohosDownload');
        binding.set('locator', dirPath);
        binding.set('displayPath', '文件管理 / 下载 / 帐屿');
        result.success(binding);
      } catch (ioErr) {
        Log.e(TAG, 'Failed resolving DOWNLOAD backup directory: ' + JSON.stringify(ioErr));
        result.error(ERROR_IO, '无法准备公共下载备份目录', null);
      }
    }).catch((err: Error): void => {
      Log.e(TAG, 'DocumentViewPicker DOWNLOAD save failed: ' + JSON.stringify(err));
      result.error(ERROR_IO, '无法绑定公共下载备份目录', null);
    });
  }

  private handleCheckDirectoryAccessible(call: MethodCall, result: MethodResult): void {
    const locatorArg: Any = call.argument('locator');
    const dirPath: string = typeof locatorArg === 'string' ? normalizeDirectoryPath(locatorArg) : '';
    if (dirPath.length === 0) {
      result.success(false);
      return;
    }
    try {
      if (!fs.accessSync(dirPath)) {
        result.success(false);
        return;
      }
      const stat: fs.Stat = fs.statSync(dirPath);
      result.success(stat.isDirectory());
    } catch (_err) {
      result.success(false);
    }
  }

  private handleListDirectoryBackups(call: MethodCall, result: MethodResult): void {
    const locatorArg: Any = call.argument('locator');
    const dirPath: string = typeof locatorArg === 'string' ? normalizeDirectoryPath(locatorArg) : '';
    if (dirPath.length === 0) {
      result.error(ERROR_INVALID_ARGS, '缺少目录定位标识', null);
      return;
    }
    try {
      if (!fs.accessSync(dirPath)) {
        result.error(ERROR_IO, '外部备份目录不存在或不可访问', null);
        return;
      }
      const entries: Array<string> = fs.listFileSync(dirPath);
      const items: Array<Map<string, Any>> = new Array<Map<string, Any>>();
      for (let i: number = 0; i < entries.length; i++) {
        const name: string = entries[i];
        if (name.toLowerCase().endsWith('.tmp')) {
          continue;
        }
        const childPath: string = dirPath + '/' + name;
        try {
          const stat: fs.Stat = fs.statSync(childPath);
          if (stat.isFile()) {
            const item: Map<string, Any> = new Map<string, Any>();
            item.set('fileName', name);
            item.set('sizeBytes', stat.size);
            item.set('modifiedAtMs', Math.floor(stat.mtime * 1000));
            items.push(item);
          }
        } catch (_ignoreChild) {
          // Ignore transient stat failure on individual child entry.
        }
      }
      result.success(items);
    } catch (err) {
      Log.e(TAG, 'listDirectoryBackups failed: ' + JSON.stringify(err));
      result.error(ERROR_IO, '无法读取外部备份目录', null);
    }
  }

  private handleWriteDirectoryBackup(call: MethodCall, result: MethodResult): void {
    const locatorArg: Any = call.argument('locator');
    const dirPath: string = typeof locatorArg === 'string' ? normalizeDirectoryPath(locatorArg) : '';
    const nameArg: Any = call.argument('fileName');
    const rawName: string = typeof nameArg === 'string' ? nameArg : '';
    const safeName: string = sanitizeFileName(rawName, '');
    const bytesArg: Any = call.argument('bytes');
    if (dirPath.length === 0 || safeName.length === 0 || !(bytesArg instanceof Uint8Array)) {
      result.error(ERROR_INVALID_ARGS, '写入外部备份目录参数无效', null);
      return;
    }
    const bytes: Uint8Array = bytesArg as Uint8Array;
    const tmpPath: string = dirPath + '/' + safeName + '.tmp';
    const finalPath: string = dirPath + '/' + safeName;
    try {
      if (!fs.accessSync(dirPath)) {
        result.error(ERROR_IO, '外部备份目录不存在或不可访问', null);
        return;
      }
      const slice: ArrayBuffer = bytes.buffer.slice(
        bytes.byteOffset,
        bytes.byteOffset + bytes.byteLength
      );
      const outFile: fs.File = fs.openSync(
        tmpPath,
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC
      );
      try {
        fs.writeSync(outFile.fd, slice);
        fs.fsyncSync(outFile.fd);
      } finally {
        fs.closeSync(outFile);
      }
      if (fs.accessSync(finalPath)) {
        fs.unlinkSync(finalPath);
      }
      fs.renameSync(tmpPath, finalPath);
      result.success(null);
    } catch (err) {
      try {
        if (fs.accessSync(tmpPath)) {
          fs.unlinkSync(tmpPath);
        }
      } catch (_cleanupErr) {
        // Ignore temp file cleanup error.
      }
      Log.e(TAG, 'writeDirectoryBackup failed: ' + JSON.stringify(err));
      result.error(ERROR_IO, '写入外部备份文件失败', null);
    }
  }

  private handleReadDirectoryBackup(call: MethodCall, result: MethodResult): void {
    const locatorArg: Any = call.argument('locator');
    const dirPath: string = typeof locatorArg === 'string' ? normalizeDirectoryPath(locatorArg) : '';
    const nameArg: Any = call.argument('fileName');
    const rawName: string = typeof nameArg === 'string' ? nameArg : '';
    const safeName: string = sanitizeFileName(rawName, '');
    if (dirPath.length === 0 || safeName.length === 0) {
      result.error(ERROR_INVALID_ARGS, '读取外部备份文件参数无效', null);
      return;
    }
    const targetPath: string = dirPath + '/' + safeName;
    try {
      if (!fs.accessSync(targetPath)) {
        result.error(ERROR_IO, '外部备份文件不存在', null);
        return;
      }
      const stat: fs.Stat = fs.statSync(targetPath);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const inFile: fs.File = fs.openSync(targetPath, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(inFile.fd, buffer);
      } finally {
        fs.closeSync(inFile);
      }
      result.success(new Uint8Array(buffer));
    } catch (err) {
      Log.e(TAG, 'readDirectoryBackup failed: ' + JSON.stringify(err));
      result.error(ERROR_IO, '读取外部备份文件失败', null);
    }
  }

  private handleDeleteDirectoryBackup(call: MethodCall, result: MethodResult): void {
    const locatorArg: Any = call.argument('locator');
    const dirPath: string = typeof locatorArg === 'string' ? normalizeDirectoryPath(locatorArg) : '';
    const nameArg: Any = call.argument('fileName');
    const rawName: string = typeof nameArg === 'string' ? nameArg : '';
    const safeName: string = sanitizeFileName(rawName, '');
    if (dirPath.length === 0 || safeName.length === 0) {
      result.error(ERROR_INVALID_ARGS, '删除外部备份文件参数无效', null);
      return;
    }
    const targetPath: string = dirPath + '/' + safeName;
    try {
      if (fs.accessSync(targetPath)) {
        fs.unlinkSync(targetPath);
      }
      result.success(null);
    } catch (err) {
      Log.e(TAG, 'deleteDirectoryBackup failed: ' + JSON.stringify(err));
      result.error(ERROR_IO, '删除外部备份文件失败', null);
    }
  }

  private handleShareBytes(call: MethodCall, result: MethodResult): void {
    const bytesArg: Any = call.argument('bytes');
    if (!(bytesArg instanceof Uint8Array)) {
      result.error(ERROR_INVALID_ARGS, '缺少待分享文件内容', null);
      return;
    }
    const bytes: Uint8Array = bytesArg as Uint8Array;
    const rawNameArg: Any = call.argument('fileName');
    const rawName: string = typeof rawNameArg === 'string' ? rawNameArg : '';
    const safeName: string = sanitizeFileName(rawName, 'backup.tally');
    const subjectArg: Any = call.argument('subject');
    const shareTitle: string =
      (typeof subjectArg === 'string' && subjectArg.trim().length > 0)
        ? subjectArg.trim()
        : safeName;

    let targetPath: string = '';
    try {
      const exportsDir: string = this.context.cacheDir + '/' + SHARED_EXPORTS_DIR;
      if (!fs.accessSync(exportsDir)) {
        fs.mkdirSync(exportsDir);
      }
      this.pruneOldExports(exportsDir);

      targetPath = exportsDir + '/' + safeName;
      const slice: ArrayBuffer = bytes.buffer.slice(
        bytes.byteOffset,
        bytes.byteOffset + bytes.byteLength
      );
      const outFile: fs.File = fs.openSync(
        targetPath,
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC
      );
      try {
        fs.writeSync(outFile.fd, slice);
        fs.fsyncSync(outFile.fd);
      } finally {
        fs.closeSync(outFile);
      }
    } catch (ioErr) {
      Log.e(TAG, 'Failed preparing shared file: ' + JSON.stringify(ioErr));
      result.error(ERROR_IO, '准备分享文件失败', null);
      return;
    }

    try {
      const shareUri: string = fileUri.getUriFromPath(targetPath);
      const utdId: string = resolveUniformTypeId(safeName);
      const record: systemShare.SharedRecord = {
        utd: utdId,
        uri: shareUri,
        title: shareTitle,
        label: safeName,
      };
      const sharedData: systemShare.SharedData = new systemShare.SharedData(record);
      const controller: systemShare.ShareController = new systemShare.ShareController(sharedData);
      const options: systemShare.ShareControllerOptions = {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL,
      };
      controller.show(this.context, options).then((): void => {
        result.success(null);
      }).catch((shareErr: Error): void => {
        Log.e(TAG, 'ShareController.show failed: ' + JSON.stringify(shareErr));
        result.error(ERROR_UNAVAILABLE, '无法调起系统分享', null);
      });
    } catch (err) {
      Log.e(TAG, 'ShareKit setup failed: ' + JSON.stringify(err));
      result.error(ERROR_UNAVAILABLE, '无法调起系统分享', null);
    }
  }

  private handleOpenExternalUrl(call: MethodCall, result: MethodResult): void {
    const urlArg: Any = call.argument('url');
    const url: string = typeof urlArg === 'string' ? urlArg.trim() : '';
    if (!hasValidHttpHost(url)) {
      result.error(ERROR_INVALID_ARGS, '仅支持打开 HTTP/HTTPS 网页链接', null);
      return;
    }

    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url,
    };
    this.context.startAbility(want).then((): void => {
      result.success(null);
    }).catch((err: Error): void => {
      Log.e(TAG, 'startAbility browser failed: ' + JSON.stringify(err));
      result.error(ERROR_UNAVAILABLE, '无法调起系统浏览器', null);
    });
  }

  private pruneOldExports(exportsDir: string): void {
    try {
      const cutoffMs: number = Date.now() - EXPORT_CACHE_TTL_MS;
      const entries: Array<string> = fs.listFileSync(exportsDir);
      for (let i: number = 0; i < entries.length; i++) {
        const childPath: string = exportsDir + '/' + entries[i];
        try {
          const stat: fs.Stat = fs.statSync(childPath);
          if (stat.isFile() && stat.mtime * 1000 < cutoffMs) {
            fs.unlinkSync(childPath);
          }
        } catch (_ignoreChild) {
          // Ignore individual stale file cleanup errors.
        }
      }
    } catch (_ignoreDir) {
      // Ignore directory listing failures during best-effort cache pruning.
    }
  }
}
