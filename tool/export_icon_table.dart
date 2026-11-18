import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/bank_icon_catalog.dart';
import 'package:tallyisle/features/common/catalog_icons.dart';
import 'package:tallyisle/features/common/svg_vector_icon.dart';

// Export command, not a behavioral test (same pattern as tool/export_icons.dart).
//
//   flutter test --no-pub tool/export_icon_table.dart
//
// Renders every account icon through the real `AssetIconAvatar` widget and
// writes `build/icon_table/manifest.json` + `build/icon_table/png/*.png`, the
// input of `tool/build_icon_table.py` (Excel + PDF auto-association review
// table). Keyword rules are parsed from source so the table never drifts from
// `matchReviewedInstitution` / `_matchAssetByKeyword`.

const String _outDir = 'build/icon_table';
const String _bankSrc = 'lib/domain/rules/bank_icon_catalog.dart';
const String _catalogSrc = 'lib/features/common/catalog_icons.dart';

final RegExp _quoted = RegExp(r"'([^']+)'");

String _block(String src, String startMarker, String endMarker) {
  final start = src.indexOf(startMarker);
  if (start < 0) throw StateError('marker not found: $startMarker');
  final end = src.indexOf(endMarker, start + startMarker.length);
  if (end < 0) throw StateError('end marker not found: $endMarker');
  return src.substring(start, end);
}

final class _Rule {
  _Rule({
    required this.layer,
    required this.keyword,
    required this.sample,
    required this.assetType,
    required this.targetKey,
    this.note = '',
  });

  final String layer;
  final String keyword;
  final String sample;
  final int assetType;
  final String targetKey;
  final String note;
}

String _typeLabel(int t) => switch (t) {
  AssetType.credit => '信用账户',
  AssetType.debt => '借贷账户',
  _ => '资金账户',
};

List<_Rule> _parseInstitutionRules() {
  final src = File(_bankSrc).readAsStringSync();
  final rules = <_Rule>[];

  final cjk = _block(
    src,
    '_reviewedBankCjkKeywords',
    'const List<(String, String)> _contextualBankCjkStems',
  );
  final entry = RegExp(r"'(builtin:bank\.[a-z0-9_]+)',\s*<String>\[([^\]]*)\]");
  for (final m in entry.allMatches(cjk)) {
    for (final kw in _quoted.allMatches(m.group(2)!)) {
      rules.add(
        _Rule(
          layer: 'A 机构矢量图标 · 银行全称/简称',
          keyword: kw.group(1)!,
          sample: kw.group(1)!,
          assetType: AssetType.normal,
          targetKey: m.group(1)!,
        ),
      );
    }
  }

  final stems = _block(
    src,
    '_contextualBankCjkStems =',
    'const List<String> _bankingContextWords',
  );
  final ctxWords = [
    for (final m in _quoted.allMatches(
      _block(src, '_bankingContextWords =', '];'),
    ))
      m.group(1)!,
  ];
  for (final m in RegExp(
    r"\('(builtin:bank\.[a-z0-9_]+)',\s*'([^']+)'\)",
  ).allMatches(stems)) {
    rules.add(
      _Rule(
        layer: 'A 机构矢量图标 · 简称词干（需上下文）',
        keyword: m.group(2)!,
        sample: '${m.group(2)}储蓄卡',
        assetType: AssetType.normal,
        targetKey: m.group(1)!,
        note: '名称还需包含：${ctxWords.join(' / ')} 之一',
      ),
    );
  }

  final ascii = _block(src, '_reviewedBankAsciiPatterns =', '];\n');
  for (final m in RegExp(
    r"\('(builtin:bank\.[a-z0-9_]+)',\s*'([A-Za-z]+)',\s*(true|false)\)",
  ).allMatches(ascii)) {
    final strict = m.group(3) == 'true';
    rules.add(
      _Rule(
        layer: 'A 机构矢量图标 · 英文代码',
        keyword: m.group(2)!,
        sample: m.group(2)!,
        assetType: AssetType.normal,
        targetKey: m.group(1)!,
        note: strict ? '整词匹配；须大写或含银行/卡等字样（防止误配普通英文）' : '整词匹配，不区分大小写',
      ),
    );
  }

  const asciiPatterns = <String, List<String>>{
    '_wechatAsciiPattern': ['wechat'],
    '_alipayAsciiPattern': ['alipay'],
    '_douyinAsciiPattern': ['douyin', 'tiktok'],
    '_xhsAsciiPattern': ['xiaohongshu'],
  };
  final pay = _block(src, '// 4. Payment', 'return null;\n}');
  final pending = <String>[];
  for (final line in const LineSplitter().convert(pay)) {
    for (final m in RegExp(r"name\.contains\('([^']+)'\)").allMatches(line)) {
      pending.add(m.group(1)!);
    }
    for (final e in asciiPatterns.entries) {
      if (line.contains('${e.key}.hasMatch')) pending.addAll(e.value);
    }
    final target = RegExp(r"_extraVectorByKey\['([^']+)'\]").firstMatch(line);
    if (target != null) {
      for (final kw in pending) {
        rules.add(
          _Rule(
            layer: 'A 机构矢量图标 · 支付/社交钱包',
            keyword: kw,
            sample: kw,
            assetType: AssetType.normal,
            targetKey: target.group(1)!,
            note: RegExp(r'^[a-z]+$').hasMatch(kw) ? '整词匹配，不区分大小写' : '',
          ),
        );
      }
      pending.clear();
    }
  }
  return rules;
}

List<_Rule> _parsePresetRules() {
  final src = File(_catalogSrc).readAsStringSync();
  final body = _block(
    src,
    'AssetIconSpec? _matchAssetByKeyword(',
    'AssetIconSpec _fallbackAssetSpecForType(',
  );
  final generic = body.substring(0, body.indexOf('const bankKeywords'));
  final rules = <_Rule>[];
  final pending = <String>[];
  var inDebt = false;
  for (final line in const LineSplitter().convert(generic)) {
    if (line.contains('assetType == AssetType.debt')) inDebt = true;
    if (line.contains('// Credit-brand')) inDebt = false;
    if (line.contains('subType == AssetType.debtLend')) pending.add('（借出方向）');
    if (line.contains('subType == AssetType.debtBorrow')) {
      pending.add('（借入方向）');
    }
    for (final m in RegExp(
      r"(name|lower)\.contains\('([^']+)'\)|name == '([^']+)'",
    ).allMatches(line)) {
      pending.add(m.group(2) ?? '${m.group(3)}（完全等于）');
    }
    final target = RegExp(r"_assetSpecByKey\['([^']+)'\]").firstMatch(line);
    if (target != null) {
      final key = target.group(1)!;
      final group = assetIconCatalog.firstWhere((s) => s.key == key).group;
      for (final kw in pending) {
        final isDirection = kw.startsWith('（');
        final exact = kw.endsWith('（完全等于）');
        final plain = exact ? kw.replaceAll('（完全等于）', '') : kw;
        final type = inDebt
            ? AssetType.debt
            : (group == 'credit' ? AssetType.credit : AssetType.normal);
        rules.add(
          _Rule(
            layer: inDebt ? 'B 通用预设图标 · 借贷账户' : 'B 通用预设图标 · 名称关键词',
            keyword: plain,
            sample: isDirection
                ? (kw.contains('借出') ? '小王' : '小李')
                : (RegExp(r'^[a-z0-9-]+$').hasMatch(plain)
                      ? plain.toUpperCase()
                      : plain),
            assetType: type,
            targetKey: key,
            note: isDirection ? '借贷账户按借出/借入方向自动选择' : (exact ? '名称须完全等于该词' : ''),
          ),
        );
      }
      pending.clear();
    }
  }

  final bankList = _block(body, 'const bankKeywords', '];');
  for (final m in _quoted.allMatches(bankList)) {
    rules.add(
      _Rule(
        layer: 'B 通用预设图标 · 银行兜底关键词',
        keyword: m.group(1)!,
        sample: m.group(1)!,
        assetType: AssetType.normal,
        targetKey: 'bank_card',
        note: '信用账户时显示「信用卡」通用图标',
      ),
    );
  }
  return rules;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('export account icon auto-association table', (tester) async {
    final flutterRoot =
        Platform.environment['FLUTTER_ROOT'] ??
        '${Directory.current.parent.path}/toolchain/flutter-3.47.7';
    final fontBytes = File(
      '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytesSync();
    await tester.runAsync(() async {
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(fontBytes)));
      await loader.load();
    });

    final svgPaths = <String>{
      for (final e in BankIconCatalog.bundled.entries) e.assetPath,
      for (final e in extraVectorIconCatalog) e.assetPath,
    };
    for (final path in svgPaths) {
      SvgVectorCache.put(
        path,
        SvgVectorDocument.parse(
          File(path).readAsStringSync(),
          sourceLabel: path,
        ),
      );
    }

    final pngDir = Directory('$_outDir/png');
    if (pngDir.existsSync()) pngDir.deleteSync(recursive: true);
    pngDir.createSync(recursive: true);
    await tester.binding.setSurfaceSize(const Size(200, 200));

    final rendered = <String, String>{};
    var seq = 0;
    Future<String> render({
      String? iconKey,
      required String name,
      required int assetType,
      int? subType,
    }) async {
      final cacheKey = '$iconKey|$name|$assetType|$subType';
      final hit = rendered[cacheKey];
      if (hit != null) return hit;
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF006972),
            ),
          ),
          home: Scaffold(
            backgroundColor: Colors.white,
            body: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: AssetIconAvatar(
                  iconKey: iconKey,
                  name: name,
                  assetType: assetType,
                  subType: subType,
                  size: 40,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 3);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return data!.buffer.asUint8List();
      });
      final file = 'icon_${(seq++).toString().padLeft(4, '0')}.png';
      File('${pngDir.path}/$file').writeAsBytesSync(bytes!);
      rendered[cacheKey] = file;
      return file;
    }

    String presetLabel(String key) {
      for (final s in assetIconCatalog) {
        if (s.key == key) return s.label;
      }
      return resolveBundledVectorIcon(key)?.displayName ?? key;
    }

    final ruleRows = <Map<String, Object?>>[];
    final rules = [..._parseInstitutionRules(), ..._parsePresetRules()];
    for (var i = 0; i < rules.length; i++) {
      final r = rules[i];
      final subType = r.assetType != AssetType.debt
          ? null
          : (r.keyword.contains('借出')
                ? AssetType.debtLend
                : (r.keyword.contains('借入')
                      ? AssetType.debtBorrow
                      : AssetType.debtBorrow));
      final visual = resolveAssetVisual(
        name: r.sample,
        assetType: r.assetType,
        subType: subType,
      );
      final targetVector = resolveBundledVectorIcon(r.targetKey);
      final targetCanonical = targetVector?.canonicalKey ?? r.targetKey;
      final shadowed = visual.iconKey != targetCanonical;
      ruleRows.add({
        'no': i + 1,
        'layer': r.layer,
        'keyword': r.keyword,
        'sample': r.sample,
        'account_type': _typeLabel(r.assetType),
        'png': await render(
          name: r.sample,
          assetType: r.assetType,
          subType: subType,
        ),
        'actual_name': visual.label,
        'actual_key': visual.iconKey,
        'color': visual.colorHex,
        'target_name': presetLabel(r.targetKey),
        'target_key': targetCanonical,
        'note': [
          if (shadowed) '⚠ 被更高优先级规则覆盖，实际显示「${visual.label}」',
          if (r.note.isNotEmpty) r.note,
        ].join('；'),
      });
    }

    final bankRows = <Map<String, Object?>>[];
    final banks = BankIconCatalog.bundled.entries.toList()
      ..sort((a, b) {
        if (a.isReviewed != b.isReviewed) return a.isReviewed ? -1 : 1;
        return a.reference.compareTo(b.reference);
      });
    for (var i = 0; i < banks.length; i++) {
      final b = banks[i];
      bankRows.add({
        'no': i + 1,
        'png': await render(
          iconKey: b.reference,
          name: b.displayName,
          assetType: AssetType.normal,
        ),
        'name': b.displayName,
        'aliases': b.aliases.join('、'),
        'key': b.reference,
        'kind': b.isReviewed ? '已审校 · 自动关联' : '扩展库 · 仅手动搜索选择',
        'color': b.defaultColorHex,
      });
    }

    final generalRows = <Map<String, Object?>>[];
    var g = 0;
    const categoryLabels = {
      'payment': '支付钱包（矢量）',
      'social': '社交平台（矢量）',
      'type': '账户类型（矢量）',
    };
    for (final s in extraVectorIconCatalog) {
      generalRows.add({
        'no': ++g,
        'png': await render(
          iconKey: s.canonicalKey,
          name: s.displayName,
          assetType: AssetType.normal,
        ),
        'name': s.displayName,
        'key': s.canonicalKey,
        'kind': categoryLabels[s.category] ?? s.category,
        'aliases': s.aliases.join('、'),
        'color': s.defaultColorHex,
      });
    }
    const groupLabels = {
      'normal': '资金账户预设（系统图标）',
      'credit': '信用账户预设（系统图标）',
      'debt': '借贷账户预设（系统图标）',
    };
    for (final s in assetIconCatalog) {
      final type = switch (s.group) {
        'credit' => AssetType.credit,
        'debt' => AssetType.debt,
        _ => AssetType.normal,
      };
      generalRows.add({
        'no': ++g,
        'png': await render(iconKey: s.key, name: s.label, assetType: type),
        'name': s.label,
        'key': s.key,
        'kind': groupLabels[s.group] ?? s.group,
        'aliases': '',
        'color': s.defaultColorHex,
      });
    }

    File('$_outDir/manifest.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'generated_at': DateTime.now().toIso8601String(),
        'rules': ruleRows,
        'banks': bankRows,
        'general': generalRows,
      }),
    );
    // ignore: avoid_print
    print(
      'rules=${ruleRows.length} banks=${bankRows.length} '
      'general=${generalRows.length} png=${rendered.length}',
    );
  });
}
