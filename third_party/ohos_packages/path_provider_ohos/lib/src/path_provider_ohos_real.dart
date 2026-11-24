// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'ffi_bindings.dart';

@visibleForTesting
AbilityRuntimeBindings? abilityRuntimeBindingsOverride;

/// The OpenHarmony implementation of [PathProviderPlatform].
class PathProviderOhos extends PathProviderPlatform {
  PathProviderOhos() : _bindings = abilityRuntimeBindingsOverride ?? AbilityRuntimeBindings();

  @visibleForTesting
  PathProviderOhos.private({required AbilityRuntimeBindings bindings}) : _bindings = bindings;

  final AbilityRuntimeBindings _bindings;

  /// Registers this class as the default instance of [PathProviderPlatform].
  static void registerWith() {
    PathProviderPlatform.instance = PathProviderOhos();
  }

  @override
  Future<String?> getTemporaryPath() {
    return getApplicationCachePath();
  }

  @override
  Future<String?> getApplicationSupportPath() async {
    return _bindings.getFilesDir();
  }

  @override
  Future<String?> getApplicationDocumentsPath() async {
    final String? filesDir = _bindings.getFilesDir();
    if (filesDir == null) {
      return null;
    }
    final String filePath = path.join(path.dirname(filesDir), 'app_flutter');
    await _createDirectoryIfMissing(filePath);
    return filePath;
  }

  @override
  Future<String?> getApplicationCachePath() async {
    return _bindings.getCacheDir();
  }

  @override
  Future<String?> getExternalStoragePath() async {
    final List<String> paths = await getExternalStoragePaths() ?? <String>[];
    if (paths.isEmpty) {
      return null;
    }
    return paths.first;
  }

  @override
  Future<List<String>?> getExternalCachePaths() async {
    final String? cacheDir = _bindings.getCacheDir();
    if (cacheDir != null) {
      return <String>[cacheDir];
    }
    return null;
  }

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) async {
    final List<String> paths = <String>[];
    final String? filesDir = _bindings.getFilesDir();
    if (filesDir == null) {
      return paths;
    }

    final String subDir = type == null ? '' : _toNativeStorageDirectory(type);
    final String filePath = subDir.isEmpty ? filesDir : path.join(filesDir, subDir);
    if (await _createDirectoryIfMissing(filePath)) {
      paths.add(filePath);
    }
    return paths;
  }

  @override
  Future<String?> getDownloadsPath() async {
    final List<String> paths =
        await getExternalStoragePaths(type: StorageDirectory.downloads) ?? <String>[];
    return paths.firstOrNull;
  }
}

Future<bool> _createDirectoryIfMissing(String filePath) async {
  final Directory directory = Directory(filePath);
  try {
    if (!directory.existsSync()) {
      await directory.create();
    }
    return true;
  } on FileSystemException {
    return false;
  }
}

String _toNativeStorageDirectory(StorageDirectory directory) {
  switch (directory) {
    case StorageDirectory.music:
      return 'Music';
    case StorageDirectory.podcasts:
      return 'Podcasts';
    case StorageDirectory.ringtones:
      return 'Ringtones';
    case StorageDirectory.alarms:
      return 'Alarms';
    case StorageDirectory.notifications:
      return 'Notifications';
    case StorageDirectory.pictures:
      return 'Pictures';
    case StorageDirectory.movies:
      return 'Movies';
    case StorageDirectory.downloads:
      return 'Download';
    case StorageDirectory.dcim:
      return 'DCIM';
    case StorageDirectory.documents:
      return 'Documents';
  }
}
