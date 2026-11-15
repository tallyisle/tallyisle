/*
* Copyright (C) 2026 Huawei Device Co., Ltd.
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
import UIAbility from '@ohos.app.ability.UIAbility';
import { BinaryMessenger, BinaryMessageHandler, BinaryReply, TaskQueue, TaskQueueOptions } from
  '@ohos/flutter_ohos/src/main/ets/plugin/common/BinaryMessenger';
import { AbilityPluginBinding, NewWantListener, WindowFocusChangedListener, OnSaveStateListener } from
  '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/ability/AbilityPluginBinding';
import { FlutterPluginBinding } from
  '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import { FileTypes, FileResponse, Result } from '../../../main/ets/file_selector/GeneratedFileSelectorApi';
import common from '@ohos.app.ability.common';

export const TAG: string = 'FileSelectorOhosPluginTest';
export const TEST_FILE_DIR: string = '/data/storage/el2/base/cache/file_selector_plugin_test';
export const TEST_FILE_PATH: string = TEST_FILE_DIR + '/unit_test.txt';
export const TEST_FILE_CONTENT: string = 'hello';

export class MockFileResult implements Result<FileResponse> {
  lastSuccess: FileResponse | null | undefined = undefined;
  lastError: Error | null = null;

  success(result: FileResponse | null): void {
    this.lastSuccess = result;
  }

  error(error: Error): void {
    this.lastError = error;
  }
}

export class MockFilesResult implements Result<Array<FileResponse>> {
  lastSuccess: Array<FileResponse> | null | undefined = undefined;
  lastError: Error | null = null;

  success(result: Array<FileResponse> | null): void {
    this.lastSuccess = result;
  }

  error(error: Error): void {
    this.lastError = error;
  }
}

class MockAbilityContext {
  cacheDir: string;

  constructor(cacheDir: string) {
    this.cacheDir = cacheDir;
  }
}

class MockAbility {
  context: MockAbilityContext;

  constructor(cacheDir: string) {
    this.context = new MockAbilityContext(cacheDir);
  }
}

export class MockAbilityBinding implements AbilityPluginBinding {
  private cacheDir: string;

  constructor(cacheDir: string) {
    this.cacheDir = cacheDir;
  }

  getAbility(): UIAbility {
    return (new MockAbility(this.cacheDir) as ESObject) as UIAbility;
  }

  addOnNewWantListener(_listener: NewWantListener): void {
  }

  removeOnNewWantListener(_listener: NewWantListener): void {
  }

  addOnWindowFocusChangedListener(_listener: WindowFocusChangedListener): void {
  }

  removeOnWindowFocusChangedListener(_listener: WindowFocusChangedListener): void {
  }

  addOnSaveStateListener(_listener: OnSaveStateListener): void {
  }

  removeOnSaveStateListener(_listener: OnSaveStateListener): void {
  }
}

class MockTaskQueue implements TaskQueue {
}

export class MockBinaryMessenger implements BinaryMessenger {
  handlers: Map<string, BinaryMessageHandler> = new Map<string, BinaryMessageHandler>();

  makeBackgroundTaskQueue(_options?: TaskQueueOptions): TaskQueue {
    return new MockTaskQueue();
  }

  send(_channel: String, _message: ArrayBuffer | null, _callback?: BinaryReply | null): void {
  }

  setMessageHandler(channel: String, handler: BinaryMessageHandler | null): void {
    const key: string = channel.toString();
    if (handler == null) {
      this.handlers.delete(key);
    } else {
      this.handlers.set(key, handler);
    }
  }
}

class MockFlutterPluginBinding {
  private messenger: BinaryMessenger;

  constructor(messenger: BinaryMessenger) {
    this.messenger = messenger;
  }

  getBinaryMessenger(): BinaryMessenger {
    return this.messenger;
  }
}

export class MockBinaryReply implements BinaryReply {
  private onReply: (message: ArrayBuffer | null) => void;

  constructor(onReply: (message: ArrayBuffer | null) => void) {
    this.onReply = onReply;
  }

  reply: (reply: ArrayBuffer | null) => void = (message: ArrayBuffer | null): void => {
    this.onReply(message);
  };
}

export function createFileTypes(mimeTypes: Array<string>, extensions: Array<string>): FileTypes {
  return FileTypes.fromList([mimeTypes, extensions]);
}

export function nullFileTypes(): FileTypes {
  return (null as ESObject) as FileTypes;
}

export function createMockPluginBinding(messenger: BinaryMessenger): FlutterPluginBinding {
  return (new MockFlutterPluginBinding(messenger) as ESObject) as FlutterPluginBinding;
}

export function writeTextFile(path: string, content: string): void {
  const parentSlash: number = path.lastIndexOf('/');
  if (parentSlash > 0) {
    const parent: string = path.substring(0, parentSlash);
    if (!fs.accessSync(parent)) {
      fs.mkdirSync(parent, true);
    }
  }
  const file: fs.File = fs.openSync(
    path,
    fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC
  );
  try {
    const buffer: ArrayBuffer = new ArrayBuffer(content.length);
    const bytes: Uint8Array = new Uint8Array(buffer);
    for (let i = 0; i < content.length; i++) {
      bytes[i] = content.charCodeAt(i);
    }
    fs.writeSync(file.fd, buffer);
  } finally {
    fs.closeSync(file);
  }
}

export function ensureTestFile(): void {
  writeTextFile(TEST_FILE_PATH, TEST_FILE_CONTENT);
}

export function ensureNamedTestFile(fileName: string): string {
  const path: string = TEST_FILE_DIR + '/' + fileName;
  writeTextFile(path, TEST_FILE_CONTENT);
  return path;
}

export function removePathQuietly(path: string): void {
  try {
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
  } catch (_err) {
  }
}

export function removeTestFile(): void {
  removePathQuietly(TEST_FILE_PATH);
}

export function mockUiAbilityContext(cacheDir: string): common.UIAbilityContext {
  return (new MockAbility(cacheDir).context as ESObject) as common.UIAbilityContext;
}

export function waitUntil(predicate: () => boolean, timeoutMs: number): Promise<void> {
  return new Promise<void>((resolve) => {
    const started: number = Date.now();
    const timer = setInterval(() => {
      if (predicate() || Date.now() - started >= timeoutMs) {
        clearInterval(timer);
        resolve();
      }
    }, 20);
  });
}
