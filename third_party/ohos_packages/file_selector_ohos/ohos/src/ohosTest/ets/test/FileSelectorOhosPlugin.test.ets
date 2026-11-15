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
import FileSelectorOhosPlugin from '../../../main/ets/file_selector/FileSelectorOhosPlugin';
import {
  createMockPluginBinding,
  MockAbilityBinding,
  MockBinaryMessenger,
  TEST_FILE_DIR
} from './TestMocks';

export default function fileSelectorOhosPluginTest() {
  describe('FileSelectorOhosPluginTest', () => {
    it('FileSelectorOhosPlugin_lifecycleWithoutEngineBinding', 0, () => {
      const plugin: FileSelectorOhosPlugin = new FileSelectorOhosPlugin();
      expect(plugin.getUniqueClassName()).assertEqual('FileSelectorOhosPlugin');

      const abilityBinding: MockAbilityBinding = new MockAbilityBinding(TEST_FILE_DIR);
      plugin.onAttachedToAbility(abilityBinding);
      plugin.onDetachedFromAbility();
      plugin.onDetachedFromAbility();

      const messenger: MockBinaryMessenger = new MockBinaryMessenger();
      const pluginBinding = createMockPluginBinding(messenger);
      plugin.onAttachedToEngine(pluginBinding);
      plugin.onDetachedFromEngine(pluginBinding);
    });

    it('FileSelectorOhosPlugin_lifecycleWithEngineThenAbility', 0, () => {
      const plugin: FileSelectorOhosPlugin = new FileSelectorOhosPlugin();
      const messenger: MockBinaryMessenger = new MockBinaryMessenger();
      const pluginBinding = createMockPluginBinding(messenger);
      const abilityBinding: MockAbilityBinding = new MockAbilityBinding(TEST_FILE_DIR);

      plugin.onAttachedToEngine(pluginBinding);
      plugin.onAttachedToAbility(abilityBinding);
      expect(messenger.handlers.has('dev.flutter.pigeon.FileSelectorApi.openFile')).assertTrue();
      expect(messenger.handlers.has('dev.flutter.pigeon.FileSelectorApi.openFiles')).assertTrue();
      expect(messenger.handlers.has('dev.flutter.pigeon.FileSelectorApi.getDirectoryPath')).assertTrue();

      plugin.onDetachedFromAbility();
      expect(messenger.handlers.has('dev.flutter.pigeon.FileSelectorApi.openFile')).assertFalse();

      plugin.onAttachedToAbility(abilityBinding);
      plugin.onDetachedFromEngine(pluginBinding);
      expect(messenger.handlers.has('dev.flutter.pigeon.FileSelectorApi.openFile')).assertFalse();
    });

    it('FileSelectorOhosPlugin_abilityBeforeEngine_doesNotRegisterChannels', 0, () => {
      const plugin: FileSelectorOhosPlugin = new FileSelectorOhosPlugin();
      const messenger: MockBinaryMessenger = new MockBinaryMessenger();
      const pluginBinding = createMockPluginBinding(messenger);
      const abilityBinding: MockAbilityBinding = new MockAbilityBinding(TEST_FILE_DIR);

      plugin.onAttachedToAbility(abilityBinding);
      plugin.onAttachedToEngine(pluginBinding);
      expect(messenger.handlers.size).assertEqual(0);

      plugin.onDetachedFromAbility();
      plugin.onDetachedFromEngine(pluginBinding);
    });
  });
}
