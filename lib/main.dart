import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'domain/rules/bank_icon_catalog.dart';
import 'features/common/svg_vector_icon.dart';

var _bankLogoLicenseRegistered = false;

/// Registers the MIT open-source license notice for bundled bank vector SVGs.
void registerBundledIconLicenses() {
  if (_bankLogoLicenseRegistered) return;
  _bankLogoLicenseRegistered = true;
  LicenseRegistry.addLicense(() async* {
    try {
      final text = await rootBundle.loadString(
        BankIconCatalog.licenseAssetPath,
      );
      yield LicenseEntryWithLineBreaks(const <String>[
        'icongo/bank-logos',
      ], text);
    } catch (_) {
      // Missing license asset must never break the license page or startup.
    }
  });
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledIconLicenses();
  unawaited(SvgVectorCache.prewarmCommonIcons());
  runApp(ProviderScope(retry: (_, _) => null, child: const TallyIsleApp()));
}
