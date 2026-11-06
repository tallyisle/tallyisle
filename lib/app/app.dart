import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'router.dart';

String brandName(Locale locale) =>
    locale.languageCode == 'zh' ? '帐屿' : 'TallyIsle';

class TallyIsleApp extends StatefulWidget {
  const TallyIsleApp({super.key});
  @override
  State<TallyIsleApp> createState() => _TallyIsleAppState();
}

class _TallyIsleAppState extends State<TallyIsleApp> {
  late final router = buildRouter();

  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    onGenerateTitle: (context) => brandName(Localizations.localeOf(context)),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('zh'), Locale('en')],
    locale: const Locale('zh'),
    theme: ThemeData(
      fontFamilyFallback: const ['NotoSansSC'],
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff138eaa)),
      useMaterial3: true,
    ),
    routerConfig: router,
  );
}
