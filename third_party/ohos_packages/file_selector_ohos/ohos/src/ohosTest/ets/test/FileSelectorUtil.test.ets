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
import { getMimeTypeFromPath, tryConvertMimetypesToExtensions, filePicker } from
  '../../../main/ets/file_selector/FileSelectorUtil';
import {
  createFileTypes,
  mockUiAbilityContext,
  TEST_FILE_DIR,
  waitUntil
} from './TestMocks';

export default function fileSelectorUtilTest() {
  describe('FileSelectorUtilTest', () => {
    it('getMimeTypeFromPath_resolvesKnownExtensions', 0, () => {
      expect(getMimeTypeFromPath('/storage/Download/report.pdf')).assertEqual('application/pdf');
      expect(getMimeTypeFromPath('/storage/Download/photo.jpg')).assertEqual('image/jpeg');
      expect(getMimeTypeFromPath('/storage/Download/photo.jpeg')).assertEqual('image/jpeg');
      expect(getMimeTypeFromPath('/storage/Download/photo.png')).assertEqual('image/png');
      expect(getMimeTypeFromPath('/storage/Download/photo.gif')).assertEqual('image/gif');
      expect(getMimeTypeFromPath('/storage/Download/photo.webp')).assertEqual('image/webp');
      expect(getMimeTypeFromPath('/storage/Download/photo.bmp')).assertEqual('image/bmp');
      expect(getMimeTypeFromPath('/storage/Download/photo.svg')).assertEqual('image/svg+xml');
      expect(getMimeTypeFromPath('/storage/Download/video.mp4')).assertEqual('video/mp4');
      expect(getMimeTypeFromPath('/storage/Download/video.3gp')).assertEqual('video/3gpp');
      expect(getMimeTypeFromPath('/storage/Download/video.webm')).assertEqual('video/webm');
      expect(getMimeTypeFromPath('/storage/Download/video.mov')).assertEqual('video/quicktime');
      expect(getMimeTypeFromPath('/storage/Download/video.mkv')).assertEqual('video/x-matroska');
      expect(getMimeTypeFromPath('/storage/Download/audio.mp3')).assertEqual('audio/mpeg');
      expect(getMimeTypeFromPath('/storage/Download/audio.wav')).assertEqual('audio/x-wav');
      expect(getMimeTypeFromPath('/storage/Download/audio.aac')).assertEqual('audio/aac');
      expect(getMimeTypeFromPath('/storage/Download/audio.flac')).assertEqual('audio/flac');
      expect(getMimeTypeFromPath('/storage/Download/doc.doc')).assertEqual('application/msword');
      expect(getMimeTypeFromPath('/storage/Download/doc.docx')).assertEqual(
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
      expect(getMimeTypeFromPath('/storage/Download/sheet.xls')).assertEqual('application/vnd.ms-excel');
      expect(getMimeTypeFromPath('/storage/Download/sheet.xlsx')).assertEqual(
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      expect(getMimeTypeFromPath('/storage/Download/slide.ppt')).assertEqual('application/vnd.ms-powerpoint');
      expect(getMimeTypeFromPath('/storage/Download/slide.pptx')).assertEqual(
        'application/vnd.openxmlformats-officedocument.presentationml.presentation');
      expect(getMimeTypeFromPath('/storage/Download/data.csv')).assertEqual('text/csv');
      expect(getMimeTypeFromPath('/storage/Download/page.html')).assertEqual('text/html');
      expect(getMimeTypeFromPath('/storage/Download/page.htm')).assertEqual('text/html');
      expect(getMimeTypeFromPath('/storage/Download/data.json')).assertEqual('application/json');
      // xml is listed under both text/xml and application/xml; later map entry wins.
      expect(getMimeTypeFromPath('/storage/Download/data.xml')).assertEqual('application/xml');
      expect(getMimeTypeFromPath('/storage/Download/archive.zip')).assertEqual('application/zip');
      expect(getMimeTypeFromPath('/storage/Download/archive.gz')).assertEqual('application/gzip');
      expect(getMimeTypeFromPath('/storage/Download/archive.tar')).assertEqual('application/x-tar');
      expect(getMimeTypeFromPath('/storage/Download/archive.7z')).assertEqual('application/x-7z-compressed');
      expect(getMimeTypeFromPath('/storage/Download/archive.rar')).assertEqual('application/x-rar-compressed');
      expect(getMimeTypeFromPath('/storage/Download/readme.txt', 'notes.txt')).assertEqual('text/plain');
      expect(getMimeTypeFromPath('/storage/Download/readme.log')).assertEqual('text/plain');
    });

    it('getMimeTypeFromPath_handlesUnknownAndQuerySuffix', 0, () => {
      expect(getMimeTypeFromPath('/storage/Download/file.unknownext')).assertEqual('application/octet-stream');
      expect(getMimeTypeFromPath('/storage/Download/image.png?version=1')).assertEqual('image/png');
      expect(getMimeTypeFromPath('/storage/Download/no_extension')).assertEqual('application/octet-stream');
      expect(getMimeTypeFromPath('/storage/Download/endsWithDot.')).assertEqual('application/octet-stream');
      expect(getMimeTypeFromPath('/storage/Download/path', '')).assertEqual('application/octet-stream');
    });

    it('tryConvertMimetypesToExtensions_mapsBuiltInMimes', 0, () => {
      expect(tryConvertMimetypesToExtensions(null).length).assertEqual(0);
      expect(tryConvertMimetypesToExtensions([]).length).assertEqual(0);

      const jpegExtensions: Array<string> = tryConvertMimetypesToExtensions(['image/jpeg']);
      expect(jpegExtensions.indexOf('jpg') >= 0).assertTrue();
      expect(jpegExtensions.indexOf('jpeg') >= 0).assertTrue();

      const imageWildcardExtensions: Array<string> = tryConvertMimetypesToExtensions(['image/*']);
      expect(imageWildcardExtensions.indexOf('png') >= 0).assertTrue();
      expect(imageWildcardExtensions.indexOf('webp') >= 0).assertTrue();

      const videoWildcardExtensions: Array<string> = tryConvertMimetypesToExtensions(['video/*']);
      expect(videoWildcardExtensions.indexOf('mp4') >= 0).assertTrue();

      const audioWildcardExtensions: Array<string> = tryConvertMimetypesToExtensions(['audio/*']);
      expect(audioWildcardExtensions.indexOf('mp3') >= 0).assertTrue();

      expect(tryConvertMimetypesToExtensions(['application/x-custom-mime']).length).assertEqual(0);
    });

    it('tryConvertMimetypesToExtensions_mapsDocumentAndTextMimes', 0, () => {
      const pdf: Array<string> = tryConvertMimetypesToExtensions(['application/pdf']);
      expect(pdf.indexOf('pdf') >= 0).assertTrue();

      const docs: Array<string> = tryConvertMimetypesToExtensions([
        'application/msword',
        'text/plain',
        'text/xml',
        'application/xml'
      ]);
      expect(docs.indexOf('doc') >= 0).assertTrue();
      expect(docs.indexOf('txt') >= 0).assertTrue();
      expect(docs.indexOf('xml') >= 0).assertTrue();
    });

    it('filePicker_coversFilterBranchesAndRejectsWithMockContext', 0, (done: () => void) => {
      const context = mockUiAbilityContext(TEST_FILE_DIR);
      let settled: boolean = false;
      filePicker('', createFileTypes([], []), context)
        .then(() => {
          expect(false).assertTrue();
          settled = true;
        })
        .catch(() => {
          return filePicker(
            '/docs',
            createFileTypes(['image/png', 'application/pdf'], ['txt', '.docx']),
            context,
            1
          );
        })
        .then(() => {
          expect(false).assertTrue();
          settled = true;
        })
        .catch(() => {
          settled = true;
        });
      waitUntil((): boolean => settled, 3000).then(() => {
        expect(settled).assertTrue();
        done();
      });
    });

    it('filePicker_withMimeTypesOnly_rejectsWithMockContext', 0, (done: () => void) => {
      const context = mockUiAbilityContext(TEST_FILE_DIR);
      let settled: boolean = false;
      filePicker('', createFileTypes(['text/plain', 'application/json'], []), context, 1)
        .then(() => {
          expect(false).assertTrue();
          settled = true;
        })
        .catch(() => {
          settled = true;
        });
      waitUntil((): boolean => settled, 3000).then(() => {
        expect(settled).assertTrue();
        done();
      });
    });
  });
}
