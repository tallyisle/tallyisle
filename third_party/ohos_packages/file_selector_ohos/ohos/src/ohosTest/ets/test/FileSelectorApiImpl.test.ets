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
import hilog from '@ohos.hilog';
import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { BinaryMessageHandler } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BinaryMessenger';
import { FileSelectorApiImpl } from '../../../main/ets/file_selector/FileSelectorApiImpl';
import {
  FileTypes,
  FileResponse,
  FileSelectorApiCodec
} from '../../../main/ets/file_selector/GeneratedFileSelectorApi';
import {
  TAG,
  TEST_FILE_DIR,
  TEST_FILE_PATH,
  TEST_FILE_CONTENT,
  MockFileResult,
  MockFilesResult,
  MockAbilityBinding,
  MockBinaryMessenger,
  MockBinaryReply,
  createFileTypes,
  nullFileTypes,
  ensureTestFile,
  ensureNamedTestFile,
  removePathQuietly,
  removeTestFile,
  writeTextFile,
  waitUntil
} from './TestMocks';

export default function fileSelectorApiImplTest() {
  describe('FileSelectorApiImplTest', () => {
    let api: FileSelectorApiImpl;

    beforeAll(() => {
      hilog.info(0x0000, TAG, '%{public}s', 'FileSelector plugin ohosTest suite start');
      ensureTestFile();
    });

    afterAll(() => {
      removeTestFile();
    });

    beforeEach(() => {
      api = new FileSelectorApiImpl(new MockAbilityBinding(TEST_FILE_DIR));
    });

    afterEach(() => {
      api.teardown();
    });

    it('createPluginDestroyedReply_returnsStableErrorPayload', 0, () => {
      const reply: Array<ESObject> = FileSelectorApiImpl.createPluginDestroyedReply();
      expect(reply.length).assertEqual(3);
      expect(reply[0]).assertEqual('plugin_destroyed');
      expect(reply[1]).assertEqual('FileSelectorApiImpl has been torn down.');
      expect(reply[2]).assertEqual(null);
    });

    it('getContext_throwsWhenDetached', 0, () => {
      const detached: FileSelectorApiImpl = new FileSelectorApiImpl(null);
      let thrown: boolean = false;
      try {
        detached.getContext();
      } catch (err) {
        thrown = err instanceof Error &&
          (err as Error).message === 'FileSelectorApiImpl is detached from Ability.';
      }
      expect(thrown).assertTrue();
      detached.teardown();
    });

    it('getContext_returnsCacheDirFromBinding', 0, () => {
      expect(api.getContext().cacheDir).assertEqual(TEST_FILE_DIR);
    });

    it('openFileWithExtensions_rejectsNullAllowedTypes', 0, () => {
      const result: MockFileResult = new MockFileResult();
      api.openFileWithExtensions('', nullFileTypes(), result);
      expect(result.lastError != null).assertTrue();
      expect(result.lastError?.message).assertEqual('allowedTypes must not be null.');
    });

    it('openFileWithExtensions_rejectsPathTraversalInInitialDirectory', 0, () => {
      const result: MockFileResult = new MockFileResult();
      api.openFileWithExtensions('../secret', createFileTypes([], ['txt']), result);
      expect(result.lastError != null).assertTrue();
      expect(result.lastError?.message).assertEqual('initialDirectory contains invalid path segments.');
    });

    it('openFilesWithExtensions_rejectsNullAllowedTypes', 0, () => {
      const result: MockFilesResult = new MockFilesResult();
      api.openFilesWithExtensions('', nullFileTypes(), result);
      expect(result.lastError != null).assertTrue();
      expect(result.lastError?.message).assertEqual('allowedTypes must not be null.');
    });

    it('openFilesWithExtensions_rejectsPathTraversalInInitialDirectory', 0, () => {
      const result: MockFilesResult = new MockFilesResult();
      api.openFilesWithExtensions('/valid/../secret', createFileTypes([], ['txt']), result);
      expect(result.lastError != null).assertTrue();
      expect(result.lastError?.message).assertEqual('initialDirectory contains invalid path segments.');
    });

    it('teardown_blocksFurtherOpenCallbacks', 0, () => {
      const fileResult: MockFileResult = new MockFileResult();
      const filesResult: MockFilesResult = new MockFilesResult();
      const allowedTypes: FileTypes = createFileTypes([], ['txt']);
      api.teardown();
      api.openFileWithExtensions('', allowedTypes, fileResult);
      api.openFilesWithExtensions('', allowedTypes, filesResult);
      expect(fileResult.lastError?.message).assertEqual('FileSelectorApiImpl has been torn down.');
      expect(filesResult.lastError?.message).assertEqual('FileSelectorApiImpl has been torn down.');
    });

    it('getUrisForPaths_returnsEmptyForEmptyInput', 0, (done: () => void) => {
      api.getUrisForPaths([]).then((uris: Array<string>) => {
        expect(uris.length).assertEqual(0);
        done();
      }).catch((_err: Error) => {
        expect(false).assertTrue();
        done();
      });
    });

    it('getUrisForPaths_copiesExistingFile', 0, (done: () => void) => {
      api.getUrisForPaths([TEST_FILE_PATH]).then((uris: Array<string>) => {
        expect(uris.length).assertEqual(1);
        expect(uris[0].indexOf('file_selector-') >= 0).assertTrue();
        expect(fs.accessSync(uris[0])).assertTrue();
        removePathQuietly(uris[0]);
        done();
      }).catch((_err: Error) => {
        expect(false).assertTrue();
        done();
      });
    });

    it('getUrisForPaths_failsForMissingFile', 0, (done: () => void) => {
      api.getUrisForPaths([TEST_FILE_DIR + '/missing.txt']).then((_uris: Array<string>) => {
        expect(false).assertTrue();
        done();
      }).catch((err: Error) => {
        expect(err.message).assertEqual('Failed to copy selected files to cache directory.');
        done();
      });
    });

    it('readFileContent_readsExistingAndMissingFiles', 0, () => {
      expect(FileSelectorApiImpl.readFileContent(
        TEST_FILE_DIR + '/missing.txt',
        'missing.txt'
      )).assertEqual(null);
      expect(FileSelectorApiImpl.readFileContent(TEST_FILE_PATH, 'unit_test.txt') != null).assertTrue();
    });

    it('buildFileResponseFromSelectedUri_buildsResponseForExistingFile', 0, (done: () => void) => {
      FileSelectorApiImpl.buildFileResponseFromSelectedUri(
        TEST_FILE_PATH,
        async (): Promise<Array<string>> => {
          return ['/cache/copied/unit_test.txt'];
        }
      ).then((response: FileResponse | null) => {
        expect(response != null).assertTrue();
        expect(response?.getName()).assertEqual('unit_test.txt');
        expect(response?.getMimeType()).assertEqual('text/plain');
        expect(response?.getSize()).assertEqual(TEST_FILE_CONTENT.length);
        expect(response?.getPath()).assertEqual('/cache/copied/unit_test.txt');
        done();
      }).catch((_err: Error) => {
        expect(false).assertTrue();
        done();
      });
    });

    it('buildFileResponseFromSelectedUri_returnsNullForMissingFile', 0, (done: () => void) => {
      FileSelectorApiImpl.buildFileResponseFromSelectedUri(
        TEST_FILE_DIR + '/missing.txt',
        async (): Promise<Array<string>> => {
          return [];
        }
      ).then((response: FileResponse | null) => {
        expect(response).assertEqual(null);
        done();
      }).catch((_err: Error) => {
        expect(false).assertTrue();
        done();
      });
    });

    it('buildFileResponseFromSelectedUri_handlesEmptyCopyAndGenericError', 0, (done: () => void) => {
      FileSelectorApiImpl.buildFileResponseFromSelectedUri(
        TEST_FILE_PATH,
        async (): Promise<Array<string>> => {
          return [];
        }
      ).then((emptyCopyResponse: FileResponse | null) => {
        expect(emptyCopyResponse?.getPath()).assertEqual('');
        return FileSelectorApiImpl.buildFileResponseFromSelectedUri(
          TEST_FILE_PATH,
          async (): Promise<Array<string>> => {
            throw new Error('copy failed');
          }
        );
      }).then((errorCopyResponse: FileResponse | null) => {
        expect(errorCopyResponse?.getPath()).assertEqual('');
        expect(errorCopyResponse?.getFileSelectorNativeException()).assertEqual(null);
        done();
      }).catch((_err: Error) => {
        expect(false).assertTrue();
        done();
      });
    });

    it('setup_registersChannelsAndGetDirectoryPathNotSupported', 0, (done: () => void) => {
      const messenger: MockBinaryMessenger = new MockBinaryMessenger();
      const binding: MockAbilityBinding = new MockAbilityBinding(TEST_FILE_DIR);
      const setupApi: FileSelectorApiImpl = new FileSelectorApiImpl(binding);
      setupApi.setup(messenger, binding);

      expect(messenger.handlers.has('dev.flutter.pigeon.FileSelectorApi.openFile')).assertTrue();
      expect(messenger.handlers.has('dev.flutter.pigeon.FileSelectorApi.openFiles')).assertTrue();

      const channelName: string = 'dev.flutter.pigeon.FileSelectorApi.getDirectoryPath';
      const handler: BinaryMessageHandler | undefined = messenger.handlers.get(channelName);
      expect(handler != undefined).assertTrue();

      const codec: FileSelectorApiCodec = FileSelectorApiCodec.INSTANCE;
      handler?.onMessage(codec.encodeMessage(null), new MockBinaryReply((message: ArrayBuffer | null): void => {
        const decoded: ESObject = codec.decodeMessage(message);
        const list: Array<ESObject> = decoded as Array<ESObject>;
        expect(list[0]).assertEqual('not_supported');
        expect(list[1]).assertEqual('getDirectoryPath is not supported on OpenHarmony.');
        expect(list[2]).assertEqual(null);
        setupApi.teardown();
        expect(messenger.handlers.has(channelName)).assertFalse();
        expect(messenger.handlers.has('dev.flutter.pigeon.FileSelectorApi.openFile')).assertFalse();
        done();
      }));
    });

    it('setup_openFileHandler_rejectsInvalidAllowedTypes', 0, (done: () => void) => {
      const messenger: MockBinaryMessenger = new MockBinaryMessenger();
      const binding: MockAbilityBinding = new MockAbilityBinding(TEST_FILE_DIR);
      const setupApi: FileSelectorApiImpl = new FileSelectorApiImpl(binding);
      setupApi.setup(messenger, binding);

      const handler: BinaryMessageHandler | undefined =
        messenger.handlers.get('dev.flutter.pigeon.FileSelectorApi.openFile');
      const codec: FileSelectorApiCodec = FileSelectorApiCodec.INSTANCE;
      handler?.onMessage(codec.encodeMessage(['', nullFileTypes()]),
        new MockBinaryReply((message: ArrayBuffer | null): void => {
          const list: Array<ESObject> = codec.decodeMessage(message) as Array<ESObject>;
          expect(list.length).assertEqual(3);
          expect((list[2] as string)).assertContain('allowedTypes must not be null');
          setupApi.teardown();
          done();
        }));
    });

    it('setup_openFilesHandler_rejectsPathTraversal', 0, (done: () => void) => {
      const messenger: MockBinaryMessenger = new MockBinaryMessenger();
      const binding: MockAbilityBinding = new MockAbilityBinding(TEST_FILE_DIR);
      const setupApi: FileSelectorApiImpl = new FileSelectorApiImpl(binding);
      setupApi.setup(messenger, binding);

      const handler: BinaryMessageHandler | undefined =
        messenger.handlers.get('dev.flutter.pigeon.FileSelectorApi.openFiles');
      const codec: FileSelectorApiCodec = FileSelectorApiCodec.INSTANCE;
      handler?.onMessage(codec.encodeMessage(['../secret', createFileTypes([], ['txt'])]),
        new MockBinaryReply((message: ArrayBuffer | null): void => {
          const list: Array<ESObject> = codec.decodeMessage(message) as Array<ESObject>;
          expect(list.length).assertEqual(3);
          expect((list[2] as string)).assertContain('initialDirectory contains invalid path segments');
          setupApi.teardown();
          done();
        }));
    });

    it('openFileAndOpenFiles_reportPickerFailure', 0, (done: () => void) => {
      const fileResult: MockFileResult = new MockFileResult();
      const filesResult: MockFilesResult = new MockFilesResult();
      const allowedTypes: FileTypes = createFileTypes(['text/plain'], ['txt']);
      api.openFileWithExtensions('', allowedTypes, fileResult);
      api.openFilesWithExtensions((null as ESObject) as string, allowedTypes, filesResult);
      waitUntil((): boolean => {
        return fileResult.lastError != null && filesResult.lastError != null;
      }, 3000).then(() => {
        expect(fileResult.lastError?.message).assertEqual('Failed to open file picker.');
        expect(filesResult.lastError?.message).assertEqual('Failed to open file picker.');
        done();
      });
    });

    it('setup_twice_clearsPreviousHandlers', 0, () => {
      const messenger: MockBinaryMessenger = new MockBinaryMessenger();
      const binding: MockAbilityBinding = new MockAbilityBinding(TEST_FILE_DIR);
      const setupApi: FileSelectorApiImpl = new FileSelectorApiImpl(binding);
      setupApi.setup(messenger, binding);
      expect(messenger.handlers.size).assertEqual(3);
      setupApi.setup(messenger, binding);
      expect(messenger.handlers.size).assertEqual(3);
      setupApi.teardown();
      expect(messenger.handlers.size).assertEqual(0);
    });

    it('setup_openFileHandler_catchesInvalidMessagePayload', 0, (done: () => void) => {
      const messenger: MockBinaryMessenger = new MockBinaryMessenger();
      const binding: MockAbilityBinding = new MockAbilityBinding(TEST_FILE_DIR);
      const setupApi: FileSelectorApiImpl = new FileSelectorApiImpl(binding);
      setupApi.setup(messenger, binding);
      const handler: BinaryMessageHandler | undefined =
        messenger.handlers.get('dev.flutter.pigeon.FileSelectorApi.openFile');
      const codec: FileSelectorApiCodec = FileSelectorApiCodec.INSTANCE;
      handler?.onMessage(codec.encodeMessage(null), new MockBinaryReply((message: ArrayBuffer | null): void => {
        const list: Array<ESObject> = codec.decodeMessage(message) as Array<ESObject>;
        expect(list.length).assertEqual(3);
        setupApi.teardown();
        done();
      }));
    });

    it('setup_openFilesHandler_reportsPickerFailure', 0, (done: () => void) => {
      const messenger: MockBinaryMessenger = new MockBinaryMessenger();
      const binding: MockAbilityBinding = new MockAbilityBinding(TEST_FILE_DIR);
      const setupApi: FileSelectorApiImpl = new FileSelectorApiImpl(binding);
      setupApi.setup(messenger, binding);
      const handler: BinaryMessageHandler | undefined =
        messenger.handlers.get('dev.flutter.pigeon.FileSelectorApi.openFiles');
      const codec: FileSelectorApiCodec = FileSelectorApiCodec.INSTANCE;
      const replyHolder: MockFilesResult = new MockFilesResult();
      handler?.onMessage(
        codec.encodeMessage(['', createFileTypes([], ['txt'])]),
        new MockBinaryReply((message: ArrayBuffer | null): void => {
          const list: Array<ESObject> = codec.decodeMessage(message) as Array<ESObject>;
          replyHolder.error(new Error((list[2] as string)));
        })
      );
      waitUntil((): boolean => {
        return replyHolder.lastError != null;
      }, 3000).then(() => {
        expect(replyHolder.lastError != null).assertTrue();
        expect(replyHolder.lastError?.message).assertContain('Failed to open file picker');
        setupApi.teardown();
        done();
      });
    });

    it('getUrisForPaths_createsMissingCacheDirectory', 0, (done: () => void) => {
      const missingCache: string = TEST_FILE_DIR + '/missing_cache_' + Date.now().toString();
      const boundApi: FileSelectorApiImpl = new FileSelectorApiImpl(new MockAbilityBinding(missingCache));
      boundApi.getUrisForPaths([TEST_FILE_PATH]).then((uris: Array<string>) => {
        expect(uris.length).assertEqual(1);
        expect(fs.accessSync(missingCache)).assertTrue();
        removePathQuietly(uris[0]);
        boundApi.teardown();
        done();
      }).catch((_err: Error) => {
        boundApi.teardown();
        expect(false).assertTrue();
        done();
      });
    });

    it('teardown_isIdempotent', 0, () => {
      const messenger: MockBinaryMessenger = new MockBinaryMessenger();
      const binding: MockAbilityBinding = new MockAbilityBinding(TEST_FILE_DIR);
      const setupApi: FileSelectorApiImpl = new FileSelectorApiImpl(binding);
      setupApi.setup(messenger, binding);
      setupApi.teardown();
      setupApi.teardown();
      expect(messenger.handlers.size).assertEqual(0);
      let thrown: boolean = false;
      try {
        setupApi.getContext();
      } catch (_err) {
        thrown = true;
      }
      expect(thrown).assertTrue();
    });

    it('setup_openFilesHandler_catchesInvalidMessagePayload', 0, (done: () => void) => {
      const messenger: MockBinaryMessenger = new MockBinaryMessenger();
      const binding: MockAbilityBinding = new MockAbilityBinding(TEST_FILE_DIR);
      const setupApi: FileSelectorApiImpl = new FileSelectorApiImpl(binding);
      setupApi.setup(messenger, binding);
      const handler: BinaryMessageHandler | undefined =
        messenger.handlers.get('dev.flutter.pigeon.FileSelectorApi.openFiles');
      const codec: FileSelectorApiCodec = FileSelectorApiCodec.INSTANCE;
      handler?.onMessage(codec.encodeMessage(null), new MockBinaryReply((message: ArrayBuffer | null): void => {
        const list: Array<ESObject> = codec.decodeMessage(message) as Array<ESObject>;
        expect(list.length).assertEqual(3);
        setupApi.teardown();
        done();
      }));
    });

    it('setup_openFileHandler_reportsPickerFailure', 0, (done: () => void) => {
      const messenger: MockBinaryMessenger = new MockBinaryMessenger();
      const binding: MockAbilityBinding = new MockAbilityBinding(TEST_FILE_DIR);
      const setupApi: FileSelectorApiImpl = new FileSelectorApiImpl(binding);
      setupApi.setup(messenger, binding);
      const handler: BinaryMessageHandler | undefined =
        messenger.handlers.get('dev.flutter.pigeon.FileSelectorApi.openFile');
      const codec: FileSelectorApiCodec = FileSelectorApiCodec.INSTANCE;
      const replyHolder: MockFileResult = new MockFileResult();
      handler?.onMessage(
        codec.encodeMessage(['', createFileTypes([], ['txt'])]),
        new MockBinaryReply((message: ArrayBuffer | null): void => {
          const list: Array<ESObject> = codec.decodeMessage(message) as Array<ESObject>;
          replyHolder.error(new Error((list[2] as string)));
        })
      );
      waitUntil((): boolean => {
        return replyHolder.lastError != null;
      }, 3000).then(() => {
        expect(replyHolder.lastError != null).assertTrue();
        expect(replyHolder.lastError?.message).assertContain('Failed to open file picker');
        setupApi.teardown();
        done();
      });
    });

    it('getUrisForPaths_sanitizesSuspiciousFileName', 0, (done: () => void) => {
      const suspiciousPath: string = ensureNamedTestFile('unit..test.txt');
      api.getUrisForPaths([suspiciousPath]).then((uris: Array<string>) => {
        expect(uris.length).assertEqual(1);
        expect(uris[0].indexOf('..') < 0).assertTrue();
        expect(uris[0].indexOf('unit_test.txt') >= 0).assertTrue();
        removePathQuietly(uris[0]);
        removePathQuietly(suspiciousPath);
        done();
      }).catch((_err: Error) => {
        removePathQuietly(suspiciousPath);
        expect(false).assertTrue();
        done();
      });
    });

    it('getUrisForPaths_cleansUpOnPartialFailure', 0, (done: () => void) => {
      const nestedPath: string = TEST_FILE_DIR + '/nested_copy/source.txt';
      writeTextFile(nestedPath, TEST_FILE_CONTENT);
      api.getUrisForPaths([nestedPath, TEST_FILE_DIR + '/missing_partial.txt']).then((_uris: Array<string>) => {
        removePathQuietly(nestedPath);
        expect(false).assertTrue();
        done();
      }).catch((err: Error) => {
        expect(err.message).assertEqual('Failed to copy selected files to cache directory.');
        removePathQuietly(nestedPath);
        done();
      });
    });

    it('getUrisForPaths_copiesMultipleExistingFiles', 0, (done: () => void) => {
      const secondPath: string = ensureNamedTestFile('second_unit_test.txt');
      api.getUrisForPaths([TEST_FILE_PATH, secondPath]).then((uris: Array<string>) => {
        expect(uris.length).assertEqual(2);
        expect(fs.accessSync(uris[0])).assertTrue();
        expect(fs.accessSync(uris[1])).assertTrue();
        removePathQuietly(uris[0]);
        removePathQuietly(uris[1]);
        removePathQuietly(secondPath);
        done();
      }).catch((_err: Error) => {
        removePathQuietly(secondPath);
        expect(false).assertTrue();
        done();
      });
    });

    it('openFileWithExtensions_rejectsAfterTeardownWhilePickerPending', 0, (done: () => void) => {
      const result: MockFileResult = new MockFileResult();
      const allowedTypes: FileTypes = createFileTypes(['text/plain'], ['txt']);
      api.openFileWithExtensions('', allowedTypes, result);
      api.teardown();
      waitUntil((): boolean => {
        return result.lastError != null;
      }, 3000).then(() => {
        expect(result.lastError != null).assertTrue();
        const message: string = result.lastError?.message ?? '';
        const isPickerOrDestroyed: boolean =
          message === 'Failed to open file picker.' ||
            message === 'FileSelectorApiImpl has been torn down.';
        expect(isPickerOrDestroyed).assertTrue();
        done();
      });
    });

    it('buildFileResponseFromSelectedUri_usesRealCopyToCache', 0, (done: () => void) => {
      FileSelectorApiImpl.buildFileResponseFromSelectedUri(
        TEST_FILE_PATH,
        (): Promise<Array<string>> => {
          return api.getUrisForPaths([TEST_FILE_PATH]);
        }
      ).then((response: FileResponse | null) => {
        expect(response != null).assertTrue();
        expect(response?.getName()).assertEqual('unit_test.txt');
        expect((response?.getPath().indexOf('file_selector-') ?? -1) >= 0).assertTrue();
        if (response != null && response.getPath().length > 0) {
          removePathQuietly(response.getPath());
        }
        done();
      }).catch((_err: Error) => {
        expect(false).assertTrue();
        done();
      });
    });
  });
}
