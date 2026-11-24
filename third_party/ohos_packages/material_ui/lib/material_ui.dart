// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart' as flutter_material;

export 'package:flutter/material.dart' hide MaterialApp;

/// Compatibility shim matching standalone `package:material_ui` type identity
/// for `go_router` while compiling cleanly on OpenHarmony (`TargetPlatform.ohos`).
class MaterialApp extends flutter_material.MaterialApp {
  const MaterialApp({super.key});

  static flutter_material.HeroController createMaterialHeroController() =>
      flutter_material.MaterialApp.createMaterialHeroController();
}
