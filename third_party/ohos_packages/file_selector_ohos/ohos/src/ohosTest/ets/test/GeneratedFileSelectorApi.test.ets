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

import { describe, it, expect } from '@ohos/hypium';
import { FileSelectorApiImpl } from '../../../main/ets/file_selector/FileSelectorApiImpl';
import {
  FileTypes,
  FileResponse,
  wrapError,
  FileSelectorExceptionCode,
  FileSelectorNativeException,
  FileSelectorApiCodec
} from '../../../main/ets/file_selector/GeneratedFileSelectorApi';
import { createFileTypes } from './TestMocks';

export default function generatedFileSelectorApiTest() {
  describe('GeneratedFileSelectorApiTest', () => {
    it('wrapError_wrapsStandardError', 0, () => {
      const wrapped: Array<ESObject> = wrapError(new Error('validation failed'));
      expect(wrapped.length).assertEqual(3);
      expect((wrapped[1] as string)).assertEqual('Error');
      expect((wrapped[2] as string)).assertContain('validation failed');
    });

    it('FileSelectorNativeException_roundTripsThroughList', 0, () => {
      const original: FileSelectorNativeException = new FileSelectorNativeException(
        FileSelectorExceptionCode.IO_EXCEPTION,
        'io failed'
      );
      const restored: FileSelectorNativeException =
        FileSelectorNativeException.fromList(original.toList());
      expect(restored.fileSelectorExceptionCode).assertEqual(FileSelectorExceptionCode.IO_EXCEPTION);
      expect(restored.message).assertEqual('io failed');
      expect(FileSelectorExceptionCode.SECURITY_EXCEPTION).assertEqual(0);
      expect(FileSelectorExceptionCode.ILLEGAL_ARGUMENT_EXCEPTION).assertEqual(2);
      expect(FileSelectorExceptionCode.ILLEGAL_STATE_EXCEPTION).assertEqual(3);
    });

    it('FileResponse_roundTripsAndSetters', 0, () => {
      const bytes: Uint8Array = new Uint8Array([1, 2, 3]);
      const exception: FileSelectorNativeException = new FileSelectorNativeException(
        FileSelectorExceptionCode.SECURITY_EXCEPTION,
        'denied'
      );
      const original: FileResponse = new FileResponse(
        '/cache/demo.txt',
        'text/plain',
        'demo.txt',
        3,
        bytes,
        exception
      );
      original.setPath('/cache/demo2.txt');
      original.setMimeType('application/json');
      original.setName('demo2.json');
      original.setSize(4);
      original.setBytes(new Uint8Array([4, 5, 6, 7]));
      original.setFileSelectorNativeException(null);
      expect(original.getPath()).assertEqual('/cache/demo2.txt');
      expect(original.getMimeType()).assertEqual('application/json');
      expect(original.getName()).assertEqual('demo2.json');
      expect(original.getSize()).assertEqual(4);
      expect(original.getBytes().length).assertEqual(4);
      expect(original.getFileSelectorNativeException()).assertEqual(null);

      const restored: FileResponse = FileResponse.fromList(original.toList());
      expect(restored.getPath()).assertEqual('/cache/demo2.txt');

      let pathNullThrown: boolean = false;
      try {
        original.setPath((null as ESObject) as string);
      } catch (_err) {
        pathNullThrown = true;
      }
      expect(pathNullThrown).assertTrue();

      let sizeNullThrown: boolean = false;
      try {
        original.setSize((null as ESObject) as number);
      } catch (_err) {
        sizeNullThrown = true;
      }
      expect(sizeNullThrown).assertTrue();

      let bytesNullThrown: boolean = false;
      try {
        original.setBytes((null as ESObject) as Uint8Array);
      } catch (_err) {
        bytesNullThrown = true;
      }
      expect(bytesNullThrown).assertTrue();
    });

    it('FileTypes_roundTripsAndNullSetters', 0, () => {
      const original: FileTypes = createFileTypes(['image/png'], ['png']);
      const restored: FileTypes = FileTypes.fromList(original.toList());
      expect(restored.getMimeTypes()[0]).assertEqual('image/png');
      expect(restored.getExtensions()[0]).assertEqual('png');

      let mimeNullThrown: boolean = false;
      try {
        restored.setMimeTypes(null);
      } catch (_err) {
        mimeNullThrown = true;
      }
      expect(mimeNullThrown).assertTrue();

      let extNullThrown: boolean = false;
      try {
        restored.setExtensions((null as ESObject) as Array<string>);
      } catch (_err) {
        extNullThrown = true;
      }
      expect(extNullThrown).assertTrue();
    });

    it('FileSelectorApiCodec_encodeDecodeCustomTypes', 0, () => {
      const codec: FileSelectorApiCodec = FileSelectorApiCodec.INSTANCE;
      expect(FileSelectorApiImpl.getCodec()).assertEqual(codec);

      const bytes: Uint8Array = new Uint8Array([9]);
      const response: FileResponse = new FileResponse('/p', 'text/plain', 'n.txt', 1, bytes, null);
      const types: FileTypes = createFileTypes(['text/plain'], ['txt']);
      const nativeException: FileSelectorNativeException = new FileSelectorNativeException(
        FileSelectorExceptionCode.ILLEGAL_ARGUMENT_EXCEPTION,
        'bad'
      );

      const decodedResponse: ESObject = codec.decodeMessage(codec.encodeMessage(response));
      expect(decodedResponse instanceof FileResponse).assertTrue();
      expect((decodedResponse as FileResponse).getName()).assertEqual('n.txt');

      const decodedTypes: ESObject = codec.decodeMessage(codec.encodeMessage(types));
      expect(decodedTypes instanceof FileTypes).assertTrue();
      expect((decodedTypes as FileTypes).getExtensions()[0]).assertEqual('txt');

      const decodedException: ESObject = codec.decodeMessage(codec.encodeMessage(nativeException));
      expect(decodedException instanceof FileSelectorNativeException).assertTrue();
      expect((decodedException as FileSelectorNativeException).message).assertEqual('bad');

      expect(codec.decodeMessage(codec.encodeMessage('plain'))).assertEqual('plain');
    });

    it('FileResponse_fromList_withNativeException', 0, () => {
      const bytes: Uint8Array = new Uint8Array([1]);
      const nativeException: FileSelectorNativeException = new FileSelectorNativeException(
        FileSelectorExceptionCode.SECURITY_EXCEPTION,
        'denied'
      );
      const original: FileResponse = new FileResponse('/p', 'text/plain', 'a.txt', 1, bytes, nativeException);
      const restored: FileResponse = FileResponse.fromList(original.toList());
      expect(restored.getFileSelectorNativeException() != null).assertTrue();
      expect(restored.getFileSelectorNativeException()?.message).assertEqual('denied');
    });

    it('FileResponse_fromList_withoutNativeExceptionField', 0, () => {
      const bytes: Uint8Array = new Uint8Array([9]);
      const restored: FileResponse = FileResponse.fromList([
        '/cache/a.txt',
        'text/plain',
        'a.txt',
        1,
        bytes
      ]);
      expect(restored.getPath()).assertEqual('/cache/a.txt');
      expect(restored.getFileSelectorNativeException()).assertEqual(null);
    });
  });
}
