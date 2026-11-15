
/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd.
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import fs from '@ohos.file.fs';
import Log from '@ohos/flutter_ohos/src/main/ets/util/Log';
import {
  Result,
  FileTypes,
  FileResponse,
  FileSelectorApiCodec,
  FileSelectorNativeException,
  FileSelectorExceptionCode,
  FILE_SELECTOR_EXCEPTION_PLACEHOLDER_PATH,
  wrapError
} from './GeneratedFileSelectorApi'
import { BinaryMessenger } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BinaryMessenger';
import MessageCodec from '@ohos/flutter_ohos/src/main/ets/plugin/common/MessageCodec';
import BasicMessageChannel, { Reply } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BasicMessageChannel';
import { AbilityPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/ability/AbilityPluginBinding';
import common from '@ohos.app.ability.common';
import {
  filePicker,
  getMimeTypeFromPath
} from './FileSelectorUtil'

const TAG = "FileSelectorApiImpl";
const NOT_SUPPORTED_ERROR_CODE: string = 'not_supported';
const NOT_SUPPORTED_GET_DIRECTORY_PATH_MESSAGE: string =
  'getDirectoryPath is not supported on OpenHarmony.';
const PLUGIN_DESTROYED_ERROR_CODE: string = 'plugin_destroyed';
const PLUGIN_DESTROYED_MESSAGE: string = 'FileSelectorApiImpl has been torn down.';

class PathTraversalException extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PathTraversalException';
  }
}

class FileContent {
  mimeType: string;
  size: number;
  byteArray: Uint8Array;

  constructor(mimeType: string, size: number, byteArray: Uint8Array) {
    this.mimeType = mimeType;
    this.size = size;
    this.byteArray = byteArray;
  }
}

function sanitizeFileName(displayName: string): string {
  const badCharacters: Array<string> = ['..', '/'];
  const segments: Array<string> = displayName.split('/');
  let fileName: string = segments[segments.length - 1];
  // Use literal split/join (aligned with Android FileUtils.sanitizeFilename), not regex.
  for (const suspString of badCharacters) {
    fileName = fileName.split(suspString).join('_');
  }
  return fileName;
}

function verifyPathWithinDirectory(filePath: string, expectedDir: string): void {
  if (filePath.indexOf('..') >= 0) {
    throw new PathTraversalException(
      'Trying to open path outside of the expected directory. File: ' + filePath +
      ' was expected to be within directory: ' + expectedDir + '.'
    );
  }
  if (!filePath.startsWith(expectedDir)) {
    throw new PathTraversalException(
      'Trying to open path outside of the expected directory. File: ' + filePath +
      ' was expected to be within directory: ' + expectedDir + '.'
    );
  }
}

export class FileSelectorApiImpl {

  binding: AbilityPluginBinding | null;
  private openFileChannel: BasicMessageChannel<ESObject> | null = null;
  private openFilesChannel: BasicMessageChannel<ESObject> | null = null;
  private getDirectoryPathChannel: BasicMessageChannel<ESObject> | null = null;
  private isDestroyed: boolean = false;

  constructor(binding: AbilityPluginBinding | null) {
    this.binding = binding;
  }

  openFileWithExtensions(initialDirectory: string, allowedTypes: FileTypes, result: Result<FileResponse>): void {
    const validationError: string | null = this.validateFileSelectionParams(initialDirectory, allowedTypes);
    if (validationError != null) {
      result.error(new Error(validationError));
      return;
    }
    if (this.reportDestroyed(result)) {
      return;
    }
    Log.d(TAG, 'openFile types:' + allowedTypes.extensions + ' dir:' + initialDirectory)
    filePicker(initialDirectory, allowedTypes, this.getContext(), 1).then(async (filePickerResult: ESObject) => {
      if (this.reportDestroyed(result)) {
        return;
      }
      if (filePickerResult == undefined) {
        Log.i(TAG, 'documentPickerSelect cancelled or no file selected');
        result.success(null);
        return;
      }
      const uris = filePickerResult as string[];
      if (uris.length === 0) {
        Log.i(TAG, 'documentPickerSelect cancelled with empty selection');
        result.success(null);
        return;
      }
      try {
        const file: FileResponse | null =
          await FileSelectorApiImpl.buildFileResponseFromSelectedUri(uris[0], () => this.getUrisForPaths([uris[0]]));
        if (file == null) {
          result.error(new Error('Failed to read file: ' + uris[0]));
          return;
        }
        result.success(file);
      } catch (err) {
        Log.e(TAG, 'Failed to prepare selected file: ' + JSON.stringify(err));
        result.error(err instanceof Error ? err : new Error('Failed to prepare selected file.'));
      }
    }).catch((err: ESObject) => {
      Log.e(TAG, 'filePicker failed with err: ' + JSON.stringify(err));
      result.error(new Error('Failed to open file picker.'));
    });
  }

  openFilesWithExtensions(initialDirectory: string, allowedTypes: FileTypes, result: Result<Array<FileResponse>>): void {
    const validationError: string | null = this.validateFileSelectionParams(initialDirectory, allowedTypes);
    if (validationError != null) {
      result.error(new Error(validationError));
      return;
    }
    if (this.reportDestroyed(result)) {
      return;
    }
    Log.d(TAG, 'openFiles mimeTypes:' + allowedTypes.mimeTypes
      + ' extensions:' + allowedTypes.extensions + ' dir:' + initialDirectory);

    filePicker(initialDirectory, allowedTypes, this.getContext()).then(async (filePickerResult: ESObject) => {
      if (this.reportDestroyed(result)) {
        return;
      }
      if (filePickerResult == undefined) {
        Log.i(TAG, 'documentPickerSelect cancelled or no files selected');
        result.success([]);
        return;
      }
      const uris = filePickerResult as string[];
      if (uris.length === 0) {
        Log.i(TAG, 'documentPickerSelect cancelled with empty selection');
        result.success([]);
        return;
      }
      try {
        const files: Array<FileResponse> = [];
        for (let i = 0; i < uris.length; i++) {
          const uri: string = uris[i];
          const file: FileResponse | null =
            await FileSelectorApiImpl.buildFileResponseFromSelectedUri(uri, () => this.getUrisForPaths([uri]));
          if (file == null) {
            result.error(new Error('Failed to read file: ' + uri));
            return;
          }
          files.push(file);
        }
        Log.i(TAG, 'documentPickerSelect select files successfully, count: ' + files.length);
        result.success(files);
      } catch (err) {
        Log.e(TAG, 'documentPickerSelect select files failed with err: ' + JSON.stringify(err));
        result.error(err instanceof Error ? err : new Error('Failed to read selected files.'));
      }
    }).catch((err: ESObject) => {
      Log.e(TAG, 'filePicker failed with err: ' + JSON.stringify(err));
      result.error(new Error('Failed to open file picker.'));
    });
  }

  getContext(): common.UIAbilityContext {
    if (this.binding == null) {
      throw new Error('FileSelectorApiImpl is detached from Ability.');
    }
    return this.binding.getAbility().context;
  }

  private validateFileSelectionParams(
    initialDirectory: string | null | undefined,
    allowedTypes: FileTypes | null | undefined
  ): string | null {
    if (allowedTypes == null) {
      return 'allowedTypes must not be null.';
    }
    if (initialDirectory != null && initialDirectory.indexOf('..') >= 0) {
      return 'initialDirectory contains invalid path segments.';
    }
    return null;
  }

  private shouldSkipReply(): boolean {
    return this.isDestroyed;
  }

  private reportDestroyed<T>(result: Result<T>): boolean {
    if (!this.isDestroyed) {
      return false;
    }
    Log.w(TAG, 'Plugin is destroyed, replying with error');
    result.error(new Error(PLUGIN_DESTROYED_MESSAGE));
    return true;
  }

  static createPluginDestroyedReply(): Array<ESObject> {
    return [PLUGIN_DESTROYED_ERROR_CODE, PLUGIN_DESTROYED_MESSAGE, null];
  }

  async getUrisForPaths(paths: string[]): Promise<Array<string>> {
    Log.i(TAG, 'getUrisForPaths, count: ' + paths.length);
    const uris: Array<string> = [];
    if (paths.length === 0) {
      return uris;
    }
    const folder: string = this.getContext().cacheDir;
    if (!fs.accessSync(folder)) {
      fs.mkdirSync(folder);
    }
    try {
      for (let i = 0; i < paths.length; i++) {
        const path: string = paths[i];
        const oldFile: fs.File = fs.openSync(path);
        try {
          const sanitizedName: string = sanitizeFileName(oldFile.name);
          // Align with Android {cacheDir}/{uuid}/{fileName}; use system mkdtemp for unique subdir.
          const targetDir: string = fs.mkdtempSync(folder + '/file_selector-XXXXXX');
          const newFile: string = targetDir + '/' + sanitizedName;
          verifyPathWithinDirectory(newFile, targetDir);
          fs.copyFileSync(oldFile.fd, newFile);
          uris.push(newFile);
        } finally {
          fs.closeSync(oldFile);
        }
      }
      return uris;
    } catch (err) {
      for (let i = 0; i < uris.length; i++) {
        const copiedUri: string = uris[i];
        try {
          fs.unlinkSync(copiedUri);
        } catch (cleanupErr) {
          Log.w(TAG, 'Failed to cleanup copied file: ' + copiedUri + ', err: ' + JSON.stringify(cleanupErr));
        }
      }
      if (err instanceof PathTraversalException) {
        throw err;
      }
      Log.e(TAG, 'Failed to getUrisForPaths: ' + JSON.stringify(err));
      throw new Error('Failed to copy selected files to cache directory.');
    }
  }

  static getCodec(): MessageCodec<ESObject> {
    return FileSelectorApiCodec.INSTANCE;
  }

  setup(binaryMessenger: BinaryMessenger, abilityPluginBinding: AbilityPluginBinding): void {
    // Clear previous handlers before re-registering to avoid leaking prior closures.
    this.teardown();
    this.isDestroyed = false;
    this.binding = abilityPluginBinding;
    const api = this;
    this.openFileChannel = new BasicMessageChannel<ESObject>(
      binaryMessenger, "dev.flutter.pigeon.FileSelectorApi.openFile", FileSelectorApiImpl.getCodec());
    this.openFileChannel.setMessageHandler({
      onMessage(msg: ESObject, reply: Reply<ESObject>): void {
        try {
          Log.d(TAG, 'onMessage reply:' + reply)
          const wrapped: Array<ESObject> = new Array<ESObject>();
          const args: Array<ESObject> = msg as Array<ESObject>;
          const initialDirectoryArg = args[0] as string;
          const allowedTypesArg = args[1] as FileTypes;
          const resultCallback: Result<FileResponse> = new ResultBuilder((result: FileResponse | null): void => {
            if (api.shouldSkipReply()) {
              reply.reply(FileSelectorApiImpl.createPluginDestroyedReply());
              return;
            }
            wrapped.push(result);
            reply.reply(wrapped);
          }, (error: Error): void => {
            if (api.shouldSkipReply()) {
              reply.reply(FileSelectorApiImpl.createPluginDestroyedReply());
              return;
            }
            const wrappedError: Array<ESObject> = wrapError(error);
            reply.reply(wrappedError);
          })
          api.openFileWithExtensions(initialDirectoryArg, allowedTypesArg, resultCallback);
        } catch (err) {
          const wrappedError: Array<ESObject> = wrapError(
            err instanceof Error ? err : new Error('Unexpected error in openFile message handler.')
          );
          reply.reply(wrappedError);
        }
      }
    });
    this.openFilesChannel = new BasicMessageChannel<ESObject>(
      binaryMessenger, "dev.flutter.pigeon.FileSelectorApi.openFiles", FileSelectorApiImpl.getCodec());
    this.openFilesChannel.setMessageHandler({
      onMessage(msg: ESObject, reply: Reply<ESObject>): void {
        try {
          Log.d(TAG, 'onMessage reply:' + reply)
          const wrapped: Array<ESObject> = new Array<ESObject>();
          const args: Array<ESObject> = msg as Array<ESObject>;
          const initialDirectoryArg = args[0] as string;
          const allowedTypesArg = args[1] as FileTypes;
          const resultCallback: Result<Array<FileResponse>> = new ResultsBuilder((result: Array<FileResponse> | null): void => {
            if (api.shouldSkipReply()) {
              reply.reply(FileSelectorApiImpl.createPluginDestroyedReply());
              return;
            }
            wrapped.push(result);
            reply.reply(wrapped);
          }, (error: Error): void => {
            if (api.shouldSkipReply()) {
              reply.reply(FileSelectorApiImpl.createPluginDestroyedReply());
              return;
            }
            const wrappedError: Array<ESObject> = wrapError(error);
            reply.reply(wrappedError);
          })
          api.openFilesWithExtensions(initialDirectoryArg, allowedTypesArg, resultCallback);
        } catch (err) {
          const wrappedError: Array<ESObject> = wrapError(
            err instanceof Error ? err : new Error('Unexpected error in openFiles message handler.')
          );
          reply.reply(wrappedError);
        }
      }
    });
    this.getDirectoryPathChannel = new BasicMessageChannel<ESObject>(
      binaryMessenger, "dev.flutter.pigeon.FileSelectorApi.getDirectoryPath", FileSelectorApiImpl.getCodec());
    this.getDirectoryPathChannel.setMessageHandler({
      onMessage(_msg: ESObject, reply: Reply<ESObject>): void {
        try {
          reply.reply([
            NOT_SUPPORTED_ERROR_CODE,
            NOT_SUPPORTED_GET_DIRECTORY_PATH_MESSAGE,
            null
          ]);
        } catch (err) {
          const wrappedError: Array<ESObject> = wrapError(
            err instanceof Error ? err : new Error('Unexpected error in getDirectoryPath message handler.')
          );
          reply.reply(wrappedError);
        }
      }
    });
  }

  /**
   * Removes MessageChannel handlers and clears Ability binding so the API
   * instance and captured closures can be garbage-collected.
   */
  teardown(): void {
    this.isDestroyed = true;
    if (this.openFileChannel != null) {
      this.openFileChannel.setMessageHandler(null);
      this.openFileChannel = null;
    }
    if (this.openFilesChannel != null) {
      this.openFilesChannel.setMessageHandler(null);
      this.openFilesChannel = null;
    }
    if (this.getDirectoryPathChannel != null) {
      this.getDirectoryPathChannel.setMessageHandler(null);
      this.getDirectoryPathChannel = null;
    }
    this.binding = null;
  }

  static readFileContent(uri: string, name: string): FileContent | null {
    try {
      const mimeType: string = getMimeTypeFromPath(uri, name);
      const file: fs.File = fs.openSync(uri);
      try {
        const stat: fs.Stat = fs.statSync(file.fd);
        const size: number = stat.size;
        // Align with Android: unknown/invalid size cannot be read reliably.
        if (size < 0) {
          Log.w(TAG, 'File size is unknown or invalid: ' + size);
          return null;
        }
        const buffer: ArrayBuffer = new ArrayBuffer(size);
        fs.readSync(file.fd, buffer, { offset: 0, length: size });
        const byteArray: Uint8Array = new Uint8Array(buffer);
        return new FileContent(mimeType, size, byteArray);
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      Log.e(TAG, 'Failed to read file: ' + JSON.stringify(err));
      return null;
    }
  }

  static async buildFileResponseFromSelectedUri(
    selectedUri: string,
    copyToCache: () => Promise<Array<string>>
  ): Promise<FileResponse | null> {
    const fileName: string = selectedUri.substring(selectedUri.lastIndexOf('/') + 1);
    const content: FileContent | null = FileSelectorApiImpl.readFileContent(selectedUri, fileName);
    if (content == null) {
      return null;
    }

    // Align with Android: path is only set when copy to cache succeeds.
    let responsePath: string = '';
    let nativeException: FileSelectorNativeException | null = null;
    try {
      const cachedUris: Array<string> = await copyToCache();
      if (cachedUris.length > 0) {
        responsePath = cachedUris[0];
      }
    } catch (err) {
      if (err instanceof PathTraversalException) {
        responsePath = FILE_SELECTOR_EXCEPTION_PLACEHOLDER_PATH;
        nativeException = new FileSelectorNativeException(
          FileSelectorExceptionCode.ILLEGAL_ARGUMENT_EXCEPTION,
          err.message
        );
      } else {
        Log.w(TAG, 'Failed to copy selected file to cache: ' + JSON.stringify(err));
        responsePath = '';
      }
    }

    return new FileResponse(
      responsePath,
      content.mimeType,
      fileName,
      content.size,
      content.byteArray,
      nativeException
    );
  }
}

class ResultBuilder{
  success : (result: FileResponse | null)=>void
  error: (error: Error) =>void

  constructor(success:ESObject , error:ESObject) {
    this.success = success
    this.error = error
  }
}
class ResultsBuilder{
  success : (result: Array<FileResponse> | null)=>void
  error: (error: Error) =>void

  constructor(success:ESObject , error:ESObject) {
    this.success = success
    this.error = error
  }
}
