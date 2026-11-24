// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/cupertino.dart' as flutter_cupertino;

export 'package:flutter/cupertino.dart' hide CupertinoApp;

/// Compatibility shim matching standalone `package:cupertino_ui` type identity
/// for `go_router` while compiling cleanly on OpenHarmony (`TargetPlatform.ohos`).
class CupertinoApp extends flutter_cupertino.CupertinoApp {
  const CupertinoApp({super.key});

  static flutter_cupertino.HeroController createCupertinoHeroController() =>
      flutter_cupertino.CupertinoApp.createCupertinoHeroController();
}
