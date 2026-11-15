// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

const int abilityRuntimeErrorCodeNoError = 0;

const int abilityRuntimeErrorCodeParamInvalid = 401;
typedef ApplicationContextGetDirNative =
    Int32 Function(Pointer<Char> buffer, Int32 bufferSize, Pointer<Int32> writeLength);

typedef ApplicationContextGetDirDart =
    int Function(Pointer<Char> buffer, int bufferSize, Pointer<Int32> writeLength);

abstract class AbilityRuntimeBindings {
  factory AbilityRuntimeBindings() = AbilityRuntimeBindingsImpl;

  bool get isAvailable;

  String? getCacheDir();

  String? getTempDir();

  String? getFilesDir();
}

@visibleForTesting
class AbilityRuntimeBindingsImpl implements AbilityRuntimeBindings {
  /// Creates bindings, opening the shared library when possible.
  AbilityRuntimeBindingsImpl({DynamicLibrary? library}) {
    try {
      _lib = library ?? DynamicLibrary.open('libability_runtime.so');
    } on ArgumentError {
      _lib = null;
      return;
    }
    _getCacheDir = _lookupGetDir('OH_AbilityRuntime_ApplicationContextGetCacheDir');
    _getTempDir = _lookupGetDir('OH_AbilityRuntime_ApplicationContextGetTempDir');
    _getFilesDir = _lookupGetDir('OH_AbilityRuntime_ApplicationContextGetFilesDir');
  }

  DynamicLibrary? _lib;
  ApplicationContextGetDirDart? _getCacheDir;
  ApplicationContextGetDirDart? _getTempDir;
  ApplicationContextGetDirDart? _getFilesDir;

  ApplicationContextGetDirDart? _lookupGetDir(String symbol) {
    final DynamicLibrary? lib = _lib;
    if (lib == null) {
      return null;
    }
    try {
      return lib.lookupFunction<ApplicationContextGetDirNative, ApplicationContextGetDirDart>(
        symbol,
      );
    } on ArgumentError {
      return null;
    }
  }
  @override
  bool get isAvailable =>
      _lib != null && (_getCacheDir != null || _getTempDir != null || _getFilesDir != null);

  @override
  String? getCacheDir() => _readDir(_getCacheDir);

  @override
  String? getTempDir() => _readDir(_getTempDir);

  @override
  String? getFilesDir() => _readDir(_getFilesDir);

  String? _readDir(ApplicationContextGetDirDart? function) {
    if (function == null) {
      return null;
    }

    for (final bufferSize in <int>[1024, 4096]) {
      final Pointer<Char> buffer = calloc<Char>(bufferSize);
      final Pointer<Int32> writeLength = calloc<Int32>();
      try {
        final int code = function(buffer, bufferSize, writeLength);
        if (code == abilityRuntimeErrorCodeNoError) {
          return buffer.cast<Utf8>().toDartString(length: writeLength.value);
        }
        if (code != abilityRuntimeErrorCodeParamInvalid) {
          return null;
        }
      } finally {
        calloc.free(buffer);
        calloc.free(writeLength);
      }
    }
    return null;
  }
}
