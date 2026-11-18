import 'dart:convert';

import '../model/codes.dart';

/// A single built-in bank icon entry from `assets/icons/banks/catalog.json`.
///
/// The reviewed root set uses `builtin:bank.<code>` (`reviewStatus == 'reviewed'`),
/// while the extended manual-pick library uses `builtin:bank-icon.<code>`
/// (`reviewStatus == 'source_label_only'`). Only `reviewed` entries are
/// eligible for automatic institution name matching.
final class BankIconDescriptor {
  const BankIconDescriptor({
    required this.reference,
    required this.assetPath,
    this.displayName = '',
    this.aliases = const <String>[],
    this.relatedEntityCode,
    this.reviewStatus = 'source_label_only',
    this.defaultColorHex = '#1565C0',
  });

  final String reference;
  final String assetPath;
  final String displayName;
  final List<String> aliases;
  final String? relatedEntityCode;
  final String reviewStatus;
  final String defaultColorHex;

  String get code => BankIconCatalog.codeFor(reference)!;

  bool get isReviewed => reviewStatus == 'reviewed';

  bool matchesSearch(String rawQuery) {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (displayName.toLowerCase().contains(q)) return true;
    if (code.toLowerCase().contains(q)) return true;
    if (reference.toLowerCase().contains(q)) return true;
    for (final alias in aliases) {
      if (alias.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  @override
  String toString() => 'BankIconDescriptor($reference -> $assetPath)';

  @override
  bool operator ==(Object other) {
    return other is BankIconDescriptor &&
        other.reference == reference &&
        other.assetPath == assetPath &&
        other.displayName == displayName &&
        _stringListEquals(other.aliases, aliases) &&
        other.relatedEntityCode == relatedEntityCode &&
        other.reviewStatus == reviewStatus;
  }

  @override
  int get hashCode => Object.hash(
    reference,
    assetPath,
    displayName,
    Object.hashAll(aliases),
    relatedEntityCode,
    reviewStatus,
  );
}

bool _stringListEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Pure-Dart registry resolving `builtin:bank.<code>` and
/// `builtin:bank-icon.<code>` references to bundled SVG assets.
final class BankIconCatalog {
  BankIconCatalog._(Iterable<BankIconDescriptor> descriptors)
    : entries = List<BankIconDescriptor>.unmodifiable(
        descriptors.toList(growable: false),
      ),
      _byReference = <String, BankIconDescriptor>{
        for (final descriptor in descriptors) descriptor.reference: descriptor,
      } {
    if (_byReference.length != entries.length) {
      throw const FormatException('Duplicate built-in bank icon reference');
    }
  }

  /// Builds a catalog from logical asset paths (used by contract tests).
  factory BankIconCatalog.fromAssetPaths(Iterable<String> assetPaths) {
    final descriptors = <BankIconDescriptor>[];
    final seenReferences = <String>{};

    for (final assetPath in assetPaths) {
      final reference = _referenceFromAssetPath(assetPath);
      if (reference == null) continue;
      if (!seenReferences.add(reference)) {
        throw FormatException('Duplicate built-in bank icon: $reference');
      }
      descriptors.add(
        BankIconDescriptor(
          reference: reference,
          assetPath: assetPath,
          displayName: codeFor(reference)!,
        ),
      );
    }

    descriptors.sort((a, b) => a.reference.compareTo(b.reference));
    return BankIconCatalog._(descriptors);
  }

  /// Builds and validates a catalog from `assets/icons/banks/catalog.json`.
  factory BankIconCatalog.fromJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Bank icon catalog root must be an object');
    }

    final rawIcons = decoded['icons'];
    if (rawIcons is! List) {
      throw const FormatException(
        'Bank icon catalog must contain an icons list',
      );
    }

    final descriptors = <BankIconDescriptor>[];
    final seenAssetPaths = <String>{};
    for (final rawIcon in rawIcons) {
      if (rawIcon is! Map) {
        throw const FormatException(
          'Bank icon catalog entry must be an object',
        );
      }
      final item = Map<String, Object?>.from(rawIcon);
      final reference = item['ref'];
      final assetPath = item['assetPath'];
      final displayName = item['displayName'];
      final reviewStatus = item['reviewStatus'];
      final rawAliases = item['aliases'];
      final relatedEntityCode = item['relatedEntityCode'];

      if (reference is! String ||
          assetPath is! String ||
          displayName is! String ||
          reviewStatus is! String ||
          rawAliases is! List ||
          (relatedEntityCode != null && relatedEntityCode is! String)) {
        throw FormatException('Invalid bank icon catalog entry: $item');
      }
      if (rawAliases.any((alias) => alias is! String)) {
        throw FormatException('Bank icon aliases must be strings: $reference');
      }
      if (!isReference(reference)) {
        throw FormatException('Invalid bank icon reference: $reference');
      }
      final code = codeFor(reference)!;
      if (assetPathFor(reference) != assetPath) {
        throw FormatException(
          'Bank icon path does not match reference: $reference -> $assetPath',
        );
      }
      if (!seenAssetPaths.add(assetPath)) {
        throw FormatException('Duplicate bank icon assetPath: $assetPath');
      }
      if (displayName.trim().isEmpty) {
        throw FormatException('Bank icon displayName is empty: $reference');
      }
      if (reviewStatus != 'reviewed' && reviewStatus != 'source_label_only') {
        throw FormatException('Invalid bank icon reviewStatus: $reviewStatus');
      }
      if (reviewStatus == 'reviewed') {
        if (!reference.startsWith(reviewedReferencePrefix) ||
            relatedEntityCode != 'bank.$code') {
          throw FormatException(
            'Reviewed bank icon must use builtin:bank.<code> and '
            'relatedEntityCode=bank.<code>: $reference',
          );
        }
      } else if (!reference.startsWith(libraryReferencePrefix) ||
          relatedEntityCode != null) {
        throw FormatException(
          'Source-label-only bank icon must use builtin:bank-icon.<code> '
          'without relatedEntityCode: $reference',
        );
      }

      final defaultColor =
          bundled._byReference[reference]?.defaultColorHex ?? '#1565C0';
      descriptors.add(
        BankIconDescriptor(
          reference: reference,
          assetPath: assetPath,
          displayName: displayName,
          aliases: List<String>.unmodifiable(rawAliases.cast<String>()),
          relatedEntityCode: relatedEntityCode as String?,
          reviewStatus: reviewStatus,
          defaultColorHex: defaultColor,
        ),
      );
    }

    return BankIconCatalog._(descriptors);
  }

  static const String assetDirectory = 'assets/icons/banks';
  static const String libraryAssetDirectory = '$assetDirectory/library';
  static const String catalogAssetPath = '$assetDirectory/catalog.json';
  static const String licenseAssetPath =
      '$assetDirectory/LICENSE.icongo-bank-logos.txt';
  static const String reviewedReferencePrefix = 'builtin:bank.';
  static const String libraryReferencePrefix = 'builtin:bank-icon.';
  static const String _assetExtension = '.svg';

  static final RegExp _codePattern = RegExp(r'^[a-z0-9]+(?:[_-][a-z0-9]+)*$');

  final List<BankIconDescriptor> entries;
  final Map<String, BankIconDescriptor> _byReference;

  late final List<BankIconDescriptor> reviewedEntries =
      List<BankIconDescriptor>.unmodifiable(
        entries.where((e) => e.isReviewed).toList(growable: false),
      );

  late final List<BankIconDescriptor> libraryEntries =
      List<BankIconDescriptor>.unmodifiable(
        entries.where((e) => !e.isReviewed).toList(growable: false),
      );

  /// Verifies 1-to-1 parity between [catalog] and [bundledAssetPaths] from
  /// Flutter's `AssetManifest`.
  static void verifyManifestAssets({
    required BankIconCatalog catalog,
    required Iterable<String> bundledAssetPaths,
  }) {
    final bundledSet = bundledAssetPaths.toSet();
    final missing = catalog.entries
        .where((entry) => !bundledSet.contains(entry.assetPath))
        .map((entry) => entry.assetPath)
        .toList();
    if (missing.isNotEmpty) {
      throw FormatException(
        'Bank icon catalog references assets missing from AssetManifest: $missing',
      );
    }

    final catalogPaths = catalog.entries
        .map((entry) => entry.assetPath)
        .toSet();
    final unregistered = bundledSet
        .where(_isBankSvgAssetPath)
        .where((assetPath) => !catalogPaths.contains(assetPath))
        .toList();
    if (unregistered.isNotEmpty) {
      throw FormatException(
        'Bundled bank SVGs missing from catalog.json: $unregistered',
      );
    }
  }

  BankIconDescriptor? descriptorFor(String? reference) =>
      reference == null ? null : _byReference[reference.trim()];

  String? pathFor(String? reference) => descriptorFor(reference)?.assetPath;

  static String referenceFor(String code) {
    if (!_isValidCode(code)) {
      throw ArgumentError.value(code, 'code', 'Invalid bank icon code');
    }
    return '$reviewedReferencePrefix$code';
  }

  static String libraryReferenceFor(String code) {
    if (!_isValidCode(code)) {
      throw ArgumentError.value(code, 'code', 'Invalid bank icon code');
    }
    return '$libraryReferencePrefix$code';
  }

  static String assetPathForCode(String code) {
    if (!_isValidCode(code)) {
      throw ArgumentError.value(code, 'code', 'Invalid bank icon code');
    }
    return '$assetDirectory/$code$_assetExtension';
  }

  static String libraryAssetPathForCode(String code) {
    if (!_isValidCode(code)) {
      throw ArgumentError.value(code, 'code', 'Invalid bank icon code');
    }
    return '$libraryAssetDirectory/$code$_assetExtension';
  }

  static String? assetPathFor(String? reference) {
    final code = codeFor(reference);
    if (code == null) return null;
    if (reference!.startsWith(reviewedReferencePrefix)) {
      return assetPathForCode(code);
    }
    return libraryAssetPathForCode(code);
  }

  static String? codeFor(String? reference) {
    if (reference == null) return null;
    String? code;
    if (reference.startsWith(reviewedReferencePrefix)) {
      code = reference.substring(reviewedReferencePrefix.length);
    } else if (reference.startsWith(libraryReferencePrefix)) {
      code = reference.substring(libraryReferencePrefix.length);
    }
    return code != null && _isValidCode(code) ? code : null;
  }

  static bool isReference(String? reference) => codeFor(reference) != null;

  static bool _isValidCode(String code) => _codePattern.hasMatch(code);

  static String? _referenceFromAssetPath(String assetPath) {
    if (assetPath.startsWith('$libraryAssetDirectory/') &&
        assetPath.endsWith(_assetExtension)) {
      final code = assetPath.substring(
        libraryAssetDirectory.length + 1,
        assetPath.length - _assetExtension.length,
      );
      if (_isValidCode(code) && !code.contains('/')) {
        return libraryReferenceFor(code);
      }
      return null;
    }

    if (assetPath.startsWith('$assetDirectory/') &&
        assetPath.endsWith(_assetExtension)) {
      final code = assetPath.substring(
        assetDirectory.length + 1,
        assetPath.length - _assetExtension.length,
      );
      if (_isValidCode(code) && !code.contains('/')) {
        return referenceFor(code);
      }
    }
    return null;
  }

  static bool _isBankSvgAssetPath(String assetPath) =>
      _referenceFromAssetPath(assetPath) != null;

  /// Pre-validated synchronous snapshot of `assets/icons/banks/catalog.json`
  /// (19 reviewed institutions + 194 manual-pick library icons).
  static final BankIconCatalog bundled = BankIconCatalog._(
    const <BankIconDescriptor>[
      BankIconDescriptor(
        reference: 'builtin:bank-icon.pbc',
        assetPath: 'assets/icons/banks/library/pbc.svg',
        displayName: '中国人民银行',
        aliases: const <String>['pbc'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50619',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.boc',
        assetPath: 'assets/icons/banks/boc.svg',
        displayName: '中国银行',
        aliases: const <String>['中行', 'BOC'],
        relatedEntityCode: 'bank.boc',
        reviewStatus: 'reviewed',
        defaultColorHex: '#B81C22',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.icbc',
        assetPath: 'assets/icons/banks/icbc.svg',
        displayName: '中国工商银行',
        aliases: const <String>['工商银行', '工行', 'ICBC'],
        relatedEntityCode: 'bank.icbc',
        reviewStatus: 'reviewed',
        defaultColorHex: '#CF0106',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.abc',
        assetPath: 'assets/icons/banks/abc.svg',
        displayName: '中国农业银行',
        aliases: const <String>['农业银行', '农行', 'ABC'],
        relatedEntityCode: 'bank.abc',
        reviewStatus: 'reviewed',
        defaultColorHex: '#009882',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.ccb',
        assetPath: 'assets/icons/banks/ccb.svg',
        displayName: '中国建设银行',
        aliases: const <String>['建设银行', '建行', 'CCB'],
        relatedEntityCode: 'bank.ccb',
        reviewStatus: 'reviewed',
        defaultColorHex: '#06569F',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.bocom',
        assetPath: 'assets/icons/banks/bocom.svg',
        displayName: '交通银行',
        aliases: const <String>['交行', 'BOCOM'],
        relatedEntityCode: 'bank.bocom',
        reviewStatus: 'reviewed',
        defaultColorHex: '#00367A',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bosc',
        assetPath: 'assets/icons/banks/library/bosc.svg',
        displayName: '上海银行',
        aliases: const <String>['bosc'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0F469B',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.cdb',
        assetPath: 'assets/icons/banks/library/cdb.svg',
        displayName: '国家开发银行',
        aliases: const <String>['cdb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D8B350',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.citic',
        assetPath: 'assets/icons/banks/citic.svg',
        displayName: '中信银行',
        aliases: const <String>['中信', 'CITIC'],
        relatedEntityCode: 'bank.citic',
        reviewStatus: 'reviewed',
        defaultColorHex: '#D7000F',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.cmb',
        assetPath: 'assets/icons/banks/cmb.svg',
        displayName: '招商银行',
        aliases: const <String>['招行', 'CMB'],
        relatedEntityCode: 'bank.cmb',
        reviewStatus: 'reviewed',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jsbchina',
        assetPath: 'assets/icons/banks/library/jsbchina.svg',
        displayName: '江苏银行',
        aliases: const <String>['jsbchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D4AB44',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.psbc',
        assetPath: 'assets/icons/banks/psbc.svg',
        displayName: '中国邮政储蓄银行',
        aliases: const <String>['邮储银行', '邮储', 'PSBC'],
        relatedEntityCode: 'bank.psbc',
        reviewStatus: 'reviewed',
        defaultColorHex: '#118A3F',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankofbeijing',
        assetPath: 'assets/icons/banks/library/bankofbeijing.svg',
        displayName: '北京银行',
        aliases: const <String>['bankofbeijing'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50012',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.cgb',
        assetPath: 'assets/icons/banks/cgb.svg',
        displayName: '广发银行',
        aliases: const <String>['广发', 'CGB'],
        relatedEntityCode: 'bank.cgb',
        reviewStatus: 'reviewed',
        defaultColorHex: '#BD0016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.ceb',
        assetPath: 'assets/icons/banks/ceb.svg',
        displayName: '中国光大银行',
        aliases: const <String>['光大银行', '光大', 'CEB'],
        relatedEntityCode: 'bank.ceb',
        reviewStatus: 'reviewed',
        defaultColorHex: '#6B1785',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.eximbank',
        assetPath: 'assets/icons/banks/library/eximbank.svg',
        displayName: '中国进出口银行',
        aliases: const <String>['eximbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#004098',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.cmbc',
        assetPath: 'assets/icons/banks/cmbc.svg',
        displayName: '中国民生银行',
        aliases: const <String>['民生银行', '民生', 'CMBC'],
        relatedEntityCode: 'bank.cmbc',
        reviewStatus: 'reviewed',
        defaultColorHex: '#006CA9',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.pingan',
        assetPath: 'assets/icons/banks/pingan.svg',
        displayName: '平安银行',
        aliases: const <String>['平安', 'PAB'],
        relatedEntityCode: 'bank.pingan',
        reviewStatus: 'reviewed',
        defaultColorHex: '#EC681B',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.hxb',
        assetPath: 'assets/icons/banks/hxb.svg',
        displayName: '华夏银行',
        aliases: const <String>['华夏', 'HXB'],
        relatedEntityCode: 'bank.hxb',
        reviewStatus: 'reviewed',
        defaultColorHex: '#D80C18',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.spdb',
        assetPath: 'assets/icons/banks/spdb.svg',
        displayName: '上海浦东发展银行',
        aliases: const <String>['浦发银行', '浦发', 'SPDB'],
        relatedEntityCode: 'bank.spdb',
        reviewStatus: 'reviewed',
        defaultColorHex: '#012882',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.cib',
        assetPath: 'assets/icons/banks/cib.svg',
        displayName: '兴业银行',
        aliases: const <String>['兴业', 'CIB'],
        relatedEntityCode: 'bank.cib',
        reviewStatus: 'reviewed',
        defaultColorHex: '#004785',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.bohai',
        assetPath: 'assets/icons/banks/bohai.svg',
        displayName: '渤海银行',
        aliases: const <String>['渤海', 'CBHB'],
        relatedEntityCode: 'bank.bohai',
        reviewStatus: 'reviewed',
        defaultColorHex: '#6FB92C',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.hengfeng',
        assetPath: 'assets/icons/banks/hengfeng.svg',
        displayName: '恒丰银行',
        aliases: const <String>['恒丰', 'HFBANK'],
        relatedEntityCode: 'bank.hengfeng',
        reviewStatus: 'reviewed',
        defaultColorHex: '#A88249',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.njcb',
        assetPath: 'assets/icons/banks/library/njcb.svg',
        displayName: '南京银行',
        aliases: const <String>['njcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#CA1A1D',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.gzcb',
        assetPath: 'assets/icons/banks/library/gzcb.svg',
        displayName: '广州银行',
        aliases: const <String>['gzcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D82321',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.z-bank',
        assetPath: 'assets/icons/banks/library/z-bank.svg',
        displayName: '武汉众邦银行',
        aliases: const <String>['z-bank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#2BAEA2',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.czbank',
        assetPath: 'assets/icons/banks/czbank.svg',
        displayName: '浙商银行',
        aliases: const <String>['浙商', 'CZBANK'],
        relatedEntityCode: 'bank.czbank',
        reviewStatus: 'reviewed',
        defaultColorHex: '#E60012',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank.zabank',
        assetPath: 'assets/icons/banks/zabank.svg',
        displayName: '众安银行',
        aliases: const <String>['众安', 'ZA Bank', 'ZABank'],
        relatedEntityCode: 'bank.zabank',
        reviewStatus: 'reviewed',
        defaultColorHex: '#00CF9A',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankcz',
        assetPath: 'assets/icons/banks/library/bankcz.svg',
        displayName: '沧州银行',
        aliases: const <String>['bankcz'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.lccb',
        assetPath: 'assets/icons/banks/library/lccb.svg',
        displayName: '廊坊银行',
        aliases: const <String>['lccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#00A0E8',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.chengdebank',
        assetPath: 'assets/icons/banks/library/chengdebank.svg',
        displayName: '承德银行',
        aliases: const <String>['chengdebank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D70110',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.scnhh',
        assetPath: 'assets/icons/banks/library/scnhh.svg',
        displayName: '安徽舒城农村商业银行',
        aliases: const <String>['scnhh'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D52018',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankofas',
        assetPath: 'assets/icons/banks/library/bankofas.svg',
        displayName: '鞍山银行',
        aliases: const <String>['bankofas'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#CC201E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.zgbank',
        assetPath: 'assets/icons/banks/library/zgbank.svg',
        displayName: '自贡银行',
        aliases: const <String>['zgbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#FBC400',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.zhnsb',
        assetPath: 'assets/icons/banks/library/zhnsb.svg',
        displayName: '珠海农商银行',
        aliases: const <String>['zhnsb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#008EBC',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.zybank',
        assetPath: 'assets/icons/banks/library/zybank.svg',
        displayName: '中原银行',
        aliases: const <String>['zybank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#16307F',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.zsebank',
        assetPath: 'assets/icons/banks/library/zsebank.svg',
        displayName: '中山农商',
        aliases: const <String>['zsebank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#C00220',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.china-cba',
        assetPath: 'assets/icons/banks/library/china-cba.svg',
        displayName: '中国银行业协会',
        aliases: const <String>['china-cba'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.norincogroup',
        assetPath: 'assets/icons/banks/library/norincogroup.svg',
        displayName: '中国银行业协会',
        aliases: const <String>['norincogroup'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#002C6F',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.sgb',
        assetPath: 'assets/icons/banks/library/sgb.svg',
        displayName: '中德住房储蓄银行',
        aliases: const <String>['sgb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F9BE00',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.zzbank',
        assetPath: 'assets/icons/banks/library/zzbank.svg',
        displayName: '郑州银行',
        aliases: const <String>['zzbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#ED991F',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.cscb',
        assetPath: 'assets/icons/banks/library/cscb.svg',
        displayName: '长沙银行',
        aliases: const <String>['cscb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D80C18',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.megabank',
        assetPath: 'assets/icons/banks/library/megabank.svg',
        displayName: '兆丰国际商业银行',
        aliases: const <String>['megabank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#885A12',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.czcb',
        assetPath: 'assets/icons/banks/library/czcb.svg',
        displayName: '浙江稠州商业银行',
        aliases: const <String>['czcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#A72226',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.mintaibank',
        assetPath: 'assets/icons/banks/library/mintaibank.svg',
        displayName: '浙江民泰商行',
        aliases: const <String>['mintaibank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#ED1C24',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.zj96596',
        assetPath: 'assets/icons/banks/library/zj96596.svg',
        displayName: '浙江农村信用社联合社',
        aliases: const <String>['zj96596'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0A6BAF',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.xmbankonline',
        assetPath: 'assets/icons/banks/library/xmbankonline.svg',
        displayName: '浙江农村信用社联合社',
        aliases: const <String>['xmbankonline'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#005BAC',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.trcbank',
        assetPath: 'assets/icons/banks/library/trcbank.svg',
        displayName: '天津农商',
        aliases: const <String>['trcbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#EA5603',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankoftianjin',
        assetPath: 'assets/icons/banks/library/bankoftianjin.svg',
        displayName: '天津农商',
        aliases: const <String>['bankoftianjin'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0D579F',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.wzcb',
        assetPath: 'assets/icons/banks/library/wzcb.svg',
        displayName: '温州银行',
        aliases: const <String>['wzcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F9B71F',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankwf',
        assetPath: 'assets/icons/banks/library/bankwf.svg',
        displayName: '潍坊银行',
        aliases: const <String>['bankwf'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D70E19',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.wrcb',
        assetPath: 'assets/icons/banks/library/wrcb.svg',
        displayName: '无锡农商',
        aliases: const <String>['wrcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D31219',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jx-bank',
        assetPath: 'assets/icons/banks/library/jx-bank.svg',
        displayName: '江西银行',
        aliases: const <String>['jx-bank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0061AE',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jinzhoubank',
        assetPath: 'assets/icons/banks/library/jinzhoubank.svg',
        displayName: '锦州银行',
        aliases: const <String>['jinzhoubank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.lzbank',
        assetPath: 'assets/icons/banks/library/lzbank.svg',
        displayName: '兰州银行',
        aliases: const <String>['lzbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#00509E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.lzccb',
        assetPath: 'assets/icons/banks/library/lzccb.svg',
        displayName: '泸州银行',
        aliases: const <String>['lzccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#A62626',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.lsbankchina',
        assetPath: 'assets/icons/banks/library/lsbankchina.svg',
        displayName: '莱商银行',
        aliases: const <String>['lsbankchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F2931E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.lsccb',
        assetPath: 'assets/icons/banks/library/lsccb.svg',
        displayName: '乐山市商业银行',
        aliases: const <String>['lsccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#DA251C',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.klb',
        assetPath: 'assets/icons/banks/library/klb.svg',
        displayName: '昆仑银行',
        aliases: const <String>['klb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#ED9F2D',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.ksrcb',
        assetPath: 'assets/icons/banks/library/ksrcb.svg',
        displayName: '昆山农商',
        aliases: const <String>['ksrcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#A40000',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jjccb',
        assetPath: 'assets/icons/banks/library/jjccb.svg',
        displayName: '九江银行',
        aliases: const <String>['jjccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E30016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.nbcb',
        assetPath: 'assets/icons/banks/library/nbcb.svg',
        displayName: '宁波银行',
        aliases: const <String>['nbcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F2933B',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankofnx',
        assetPath: 'assets/icons/banks/library/bankofnx.svg',
        displayName: '宁夏银行',
        aliases: const <String>['bankofnx'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#EC1D24',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankgy',
        assetPath: 'assets/icons/banks/library/bankgy.svg',
        displayName: '贵阳银行',
        aliases: const <String>['bankgy'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E70012',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bgzchina',
        assetPath: 'assets/icons/banks/library/bgzchina.svg',
        displayName: '贵州银行',
        aliases: const <String>['bgzchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#DE0112',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankofdl',
        assetPath: 'assets/icons/banks/library/bankofdl.svg',
        displayName: '大连银行',
        aliases: const <String>['bankofdl'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#C7000C',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bjrcb',
        assetPath: 'assets/icons/banks/library/bjrcb.svg',
        displayName: '北京农商银行',
        aliases: const <String>['bjrcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#C8171E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bd-bank',
        assetPath: 'assets/icons/banks/library/bd-bank.svg',
        displayName: '保定银行',
        aliases: const <String>['bd-bank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#A60D13',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.cqrcb',
        assetPath: 'assets/icons/banks/library/cqrcb.svg',
        displayName: '重庆农商',
        aliases: const <String>['cqrcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E4181E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.csrcbank',
        assetPath: 'assets/icons/banks/library/csrcbank.svg',
        displayName: '常熟农商',
        aliases: const <String>['csrcbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#5A422E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.cycb',
        assetPath: 'assets/icons/banks/library/cycb.svg',
        displayName: '朝阳银行',
        aliases: const <String>['cycb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#025198',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bocd',
        assetPath: 'assets/icons/banks/library/bocd.svg',
        displayName: '成都银行',
        aliases: const <String>['bocd'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F29600',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.cqcbank',
        assetPath: 'assets/icons/banks/library/cqcbank.svg',
        displayName: '重庆银行',
        aliases: const <String>['cqcbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#009F40',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.qdccb',
        assetPath: 'assets/icons/banks/library/qdccb.svg',
        displayName: '青岛银行',
        aliases: const <String>['qdccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D80313',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankqh',
        assetPath: 'assets/icons/banks/library/bankqh.svg',
        displayName: '青海银行',
        aliases: const <String>['bankqh'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#900471',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.uccb',
        assetPath: 'assets/icons/banks/library/uccb.svg',
        displayName: '乌鲁木齐商业银行',
        aliases: const <String>['uccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#005DA9',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankoftieling',
        assetPath: 'assets/icons/banks/library/bankoftieling.svg',
        displayName: '铁岭银行',
        aliases: const <String>['bankoftieling'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D61919',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.whrcbank',
        assetPath: 'assets/icons/banks/library/whrcbank.svg',
        displayName: '武汉农商',
        aliases: const <String>['whrcbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D40019',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.xacbank',
        assetPath: 'assets/icons/banks/library/xacbank.svg',
        displayName: '西安银行',
        aliases: const <String>['xacbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#005DA9',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.ncbank',
        assetPath: 'assets/icons/banks/library/ncbank.svg',
        displayName: '宁波通商银行',
        aliases: const <String>['ncbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0E70BB',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.ncbchina',
        assetPath: 'assets/icons/banks/library/ncbchina.svg',
        displayName: '南洋商业银行',
        aliases: const <String>['ncbchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D60110',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankofpj',
        assetPath: 'assets/icons/banks/library/bankofpj.svg',
        displayName: '盘锦银行',
        aliases: const <String>['bankofpj'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E5332B',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.srbank',
        assetPath: 'assets/icons/banks/library/srbank.svg',
        displayName: '上饶银行',
        aliases: const <String>['srbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F8A600',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.sxccb',
        assetPath: 'assets/icons/banks/library/sxccb.svg',
        displayName: '绍兴银行',
        aliases: const <String>['sxccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#1870BB',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.dzccb',
        assetPath: 'assets/icons/banks/library/dzccb.svg',
        displayName: '达州银行',
        aliases: const <String>['dzccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#735222',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.uobchina',
        assetPath: 'assets/icons/banks/library/uobchina.svg',
        displayName: '大华银行',
        aliases: const <String>['uobchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.dahsing',
        assetPath: 'assets/icons/banks/library/dahsing.svg',
        displayName: '大新银行',
        aliases: const <String>['dahsing'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#B90A7A',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.ordosbank',
        assetPath: 'assets/icons/banks/library/ordosbank.svg',
        displayName: '鄂尔多斯银行',
        aliases: const <String>['ordosbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.gzccb',
        assetPath: 'assets/icons/banks/library/gzccb.svg',
        displayName: '赣州银行',
        aliases: const <String>['gzccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#C7161E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.fuxinbank',
        assetPath: 'assets/icons/banks/library/fuxinbank.svg',
        displayName: '阜新银行',
        aliases: const <String>['fuxinbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#337CC6',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankoffs',
        assetPath: 'assets/icons/banks/library/bankoffs.svg',
        displayName: '抚顺银行',
        aliases: const <String>['bankoffs'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D51719',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hkbea',
        assetPath: 'assets/icons/banks/library/hkbea.svg',
        displayName: '东亚银行',
        aliases: const <String>['hkbea'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#EC1B2E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.dyccb',
        assetPath: 'assets/icons/banks/library/dyccb.svg',
        displayName: '东营银行',
        aliases: const <String>['dyccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#DE0112',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.drcbank',
        assetPath: 'assets/icons/banks/library/drcbank.svg',
        displayName: '东莞农商',
        aliases: const <String>['drcbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#9B0F11',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.dongguanbank',
        assetPath: 'assets/icons/banks/library/dongguanbank.svg',
        displayName: '东莞银行',
        aliases: const <String>['dongguanbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#DE0112',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.dzbchina',
        assetPath: 'assets/icons/banks/library/dzbchina.svg',
        displayName: '德州银行',
        aliases: const <String>['dzbchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hanabank',
        assetPath: 'assets/icons/banks/library/hanabank.svg',
        displayName: '韩亚银行',
        aliases: const <String>['hanabank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#008375',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hkbchina',
        assetPath: 'assets/icons/banks/library/hkbchina.svg',
        displayName: '汉口银行',
        aliases: const <String>['hkbchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0086B2',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hebbank',
        assetPath: 'assets/icons/banks/library/hebbank.svg',
        displayName: '河北银行',
        aliases: const <String>['hebbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#154580',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.boy',
        assetPath: 'assets/icons/banks/library/boy.svg',
        displayName: '横滨银行',
        aliases: const <String>['boy'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#00468E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hzbank',
        assetPath: 'assets/icons/banks/library/hzbank.svg',
        displayName: '杭州银行',
        aliases: const <String>['hzbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0AA1E5',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hzccb',
        assetPath: 'assets/icons/banks/library/hzccb.svg',
        displayName: '湖州银行',
        aliases: const <String>['hzccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#FE0316',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hubeibank',
        assetPath: 'assets/icons/banks/library/hubeibank.svg',
        displayName: '湖北银行',
        aliases: const <String>['hubeibank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#EA1D25',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hangseng',
        assetPath: 'assets/icons/banks/library/hangseng.svg',
        displayName: '恒生银行',
        aliases: const <String>['hangseng'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#FE0009',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hsbc',
        assetPath: 'assets/icons/banks/library/hsbc.svg',
        displayName: '汇丰银行',
        aliases: const <String>['hsbc'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.ocbc',
        assetPath: 'assets/icons/banks/library/ocbc.svg',
        displayName: '华侨银行',
        aliases: const <String>['ocbc'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E30016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jlbank',
        assetPath: 'assets/icons/banks/library/jlbank.svg',
        displayName: '吉林银行',
        aliases: const <String>['jlbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#DC0917',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jn-bank',
        assetPath: 'assets/icons/banks/library/jn-bank.svg',
        displayName: '济宁银行',
        aliases: const <String>['jn-bank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F8A700',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jmrcb',
        assetPath: 'assets/icons/banks/library/jmrcb.svg',
        displayName: '江门农商',
        aliases: const <String>['jmrcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#04346E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hsbank',
        assetPath: 'assets/icons/banks/library/hsbank.svg',
        displayName: '徽商银行',
        aliases: const <String>['hsbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#C8171E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bohuihe',
        assetPath: 'assets/icons/banks/library/bohuihe.svg',
        displayName: '汇和银行',
        aliases: const <String>['bohuihe'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jybank',
        assetPath: 'assets/icons/banks/library/jybank.svg',
        displayName: '江阴农商',
        aliases: const <String>['jybank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#00693E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jshbank',
        assetPath: 'assets/icons/banks/library/jshbank.svg',
        displayName: '晋商银行',
        aliases: const <String>['jshbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E74225',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankyellowriver',
        assetPath: 'assets/icons/banks/library/bankyellowriver.svg',
        displayName: '黄河农商',
        aliases: const <String>['bankyellowriver'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D70E25',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.crbank',
        assetPath: 'assets/icons/banks/library/crbank.svg',
        displayName: '华润银行',
        aliases: const <String>['crbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F4A21C',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.citibank',
        assetPath: 'assets/icons/banks/library/citibank.svg',
        displayName: '花旗银行',
        aliases: const <String>['citibank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#022E72',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.eastwestbank',
        assetPath: 'assets/icons/banks/library/eastwestbank.svg',
        displayName: '华美银行',
        aliases: const <String>['eastwestbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#DC022A',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.grcbank',
        assetPath: 'assets/icons/banks/library/grcbank.svg',
        displayName: '广东农商',
        aliases: const <String>['grcbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#FFCC00',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.gsbankchina',
        assetPath: 'assets/icons/banks/library/gsbankchina.svg',
        displayName: '甘肃银行',
        aliases: const <String>['gsbankchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#CA7038',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.foshanbank',
        assetPath: 'assets/icons/banks/library/foshanbank.svg',
        displayName: '佛山农商',
        aliases: const <String>['foshanbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F07C00',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.ccqtgb',
        assetPath: 'assets/icons/banks/library/ccqtgb.svg',
        displayName: '重庆三峡银行',
        aliases: const <String>['ccqtgb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#00639E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.urcb',
        assetPath: 'assets/icons/banks/library/urcb.svg',
        displayName: '杭州联合银行',
        aliases: const <String>['urcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0A6BAF',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hznsyh',
        assetPath: 'assets/icons/banks/library/hznsyh.svg',
        displayName: '惠州农商',
        aliases: const <String>['hznsyh'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#50A01A',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankofhld',
        assetPath: 'assets/icons/banks/library/bankofhld.svg',
        displayName: '葫芦岛银行',
        aliases: const <String>['bankofhld'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D70110',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.cmbcn',
        assetPath: 'assets/icons/banks/library/cmbcn.svg',
        displayName: '华商银行',
        aliases: const <String>['cmbcn'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#CF0106',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hrxjbank',
        assetPath: 'assets/icons/banks/library/hrxjbank.svg',
        displayName: '华融湘江银行',
        aliases: const <String>['hrxjbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#C00415',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jhccb',
        assetPath: 'assets/icons/banks/library/jhccb.svg',
        displayName: '金华银行',
        aliases: const <String>['jhccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F08300',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.syrcb',
        assetPath: 'assets/icons/banks/library/syrcb.svg',
        displayName: '江苏射阳农商银行',
        aliases: const <String>['syrcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#BC1B25',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.fudian',
        assetPath: 'assets/icons/banks/library/fudian.svg',
        displayName: '富滇银行',
        aliases: const <String>['fudian'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#B41D22',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.ghbank',
        assetPath: 'assets/icons/banks/library/ghbank.svg',
        displayName: '广东华兴银行',
        aliases: const <String>['ghbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#B21E27',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankofbbg',
        assetPath: 'assets/icons/banks/library/bankofbbg.svg',
        displayName: '广西北部湾银行',
        aliases: const <String>['bankofbbg'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0068B6',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.gdnybank',
        assetPath: 'assets/icons/banks/library/gdnybank.svg',
        displayName: '广东南粤银行',
        aliases: const <String>['gdnybank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#CE253D',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.fubonchina',
        assetPath: 'assets/icons/banks/library/fubonchina.svg',
        displayName: '富邦华一银行',
        aliases: const <String>['fubonchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0095CC',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.societegenerale',
        assetPath: 'assets/icons/banks/library/societegenerale.svg',
        displayName: '法兴银行',
        aliases: const <String>['societegenerale'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E30016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.firstbank',
        assetPath: 'assets/icons/banks/library/firstbank.svg',
        displayName: '第一银行',
        aliases: const <String>['firstbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D5AB48',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.fjhxbank',
        assetPath: 'assets/icons/banks/library/fjhxbank.svg',
        displayName: '福建海峡银行',
        aliases: const <String>['fjhxbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#047AC6',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.chinadb',
        assetPath: 'assets/icons/banks/library/chinadb.svg',
        displayName: '德意志银行',
        aliases: const <String>['chinadb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#26298A',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jhrcbank',
        assetPath: 'assets/icons/banks/library/jhrcbank.svg',
        displayName: '建湖农商',
        aliases: const <String>['jhrcbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#AE935C',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.scotiabank',
        assetPath: 'assets/icons/banks/library/scotiabank.svg',
        displayName: '加拿大丰业银行',
        aliases: const <String>['scotiabank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E30016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hnnxs',
        assetPath: 'assets/icons/banks/library/hnnxs.svg',
        displayName: '湖南省农村信用社',
        aliases: const <String>['hnnxs'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E30016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.tcb-bank',
        assetPath: 'assets/icons/banks/library/tcb-bank.svg',
        displayName: '合作金库银行',
        aliases: const <String>['tcb-bank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#007A55',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.cathaybk',
        assetPath: 'assets/icons/banks/library/cathaybk.svg',
        displayName: '国泰世华银行',
        aliases: const <String>['cathaybk'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#058F44',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankofamerica',
        assetPath: 'assets/icons/banks/library/bankofamerica.svg',
        displayName: '美国银行',
        aliases: const <String>['bankofamerica'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0060AA',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bmo',
        assetPath: 'assets/icons/banks/library/bmo.svg',
        displayName: '蒙特利尔银行',
        aliases: const <String>['bmo'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E30016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bangkokbank',
        assetPath: 'assets/icons/banks/library/bangkokbank.svg',
        displayName: '盘谷银行',
        aliases: const <String>['bangkokbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#030098',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.qhdbank',
        assetPath: 'assets/icons/banks/library/qhdbank.svg',
        displayName: '秦皇岛银行',
        aliases: const <String>['qhdbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#015CAA',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.qsbank',
        assetPath: 'assets/icons/banks/library/qsbank.svg',
        displayName: '齐商银行',
        aliases: const <String>['qsbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.qingbank',
        assetPath: 'assets/icons/banks/library/qingbank.svg',
        displayName: '清远农商',
        aliases: const <String>['qingbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#A3C400',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.nanhaibank',
        assetPath: 'assets/icons/banks/library/nanhaibank.svg',
        displayName: '南海农商',
        aliases: const <String>['nanhaibank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D50030',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jpmorganchina',
        assetPath: 'assets/icons/banks/library/jpmorganchina.svg',
        displayName: '摩根大通银行',
        aliases: const <String>['jpmorganchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#034492',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.lsbchina',
        assetPath: 'assets/icons/banks/library/lsbchina.svg',
        displayName: '临商银行',
        aliases: const <String>['lsbchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E30016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.o-bank',
        assetPath: 'assets/icons/banks/library/o-bank.svg',
        displayName: '王道银行',
        aliases: const <String>['o-bank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#EE8215',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.tjbhb',
        assetPath: 'assets/icons/banks/library/tjbhb.svg',
        displayName: '天津滨海农商',
        aliases: const <String>['tjbhb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#009035',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.ts-bank',
        assetPath: 'assets/icons/banks/library/ts-bank.svg',
        displayName: '唐山银行',
        aliases: const <String>['ts-bank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#782A85',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.taccb',
        assetPath: 'assets/icons/banks/library/taccb.svg',
        displayName: '泰安银行',
        aliases: const <String>['taccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E30016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.zjtlcb',
        assetPath: 'assets/icons/banks/library/zjtlcb.svg',
        displayName: '泰隆银行',
        aliases: const <String>['zjtlcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F45D3D',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.wuhaicb',
        assetPath: 'assets/icons/banks/library/wuhaicb.svg',
        displayName: '乌海银行',
        aliases: const <String>['wuhaicb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D20819',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.xynsh',
        assetPath: 'assets/icons/banks/library/xynsh.svg',
        displayName: '新沂农商',
        aliases: const <String>['xynsh'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D20016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.dbs',
        assetPath: 'assets/icons/banks/library/dbs.svg',
        displayName: '星展银行',
        aliases: const <String>['dbs'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E30016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bcm',
        assetPath: 'assets/icons/banks/library/bcm.svg',
        displayName: '澳门商业银行',
        aliases: const <String>['bcm'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#1D7A74',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.gx966888',
        assetPath: 'assets/icons/banks/library/gx966888.svg',
        displayName: '广西农村信用社',
        aliases: const <String>['gx966888'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#009035',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.guilinbank',
        assetPath: 'assets/icons/banks/library/guilinbank.svg',
        displayName: '桂林银行',
        aliases: const <String>['guilinbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#1984BF',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hrbb',
        assetPath: 'assets/icons/banks/library/hrbb.svg',
        displayName: '哈尔滨银行',
        aliases: const <String>['hrbb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#EA5C03',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hdcb',
        assetPath: 'assets/icons/banks/library/hdcb.svg',
        displayName: '邯郸银行',
        aliases: const <String>['hdcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0276C3',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.kbstarchina',
        assetPath: 'assets/icons/banks/library/kbstarchina.svg',
        displayName: '韩国国民银行',
        aliases: const <String>['kbstarchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#FFBF4C',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.ibk',
        assetPath: 'assets/icons/banks/library/ibk.svg',
        displayName: '韩国企业银行',
        aliases: const <String>['ibk'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#00A4E2',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.hfrcbc',
        assetPath: 'assets/icons/banks/library/hfrcbc.svg',
        displayName: '合肥科技农商',
        aliases: const <String>['hfrcbc'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E30016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jnbank',
        assetPath: 'assets/icons/banks/library/jnbank.svg',
        displayName: '合肥科技农商',
        aliases: const <String>['jnbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#BE8E20',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jjbank',
        assetPath: 'assets/icons/banks/library/jjbank.svg',
        displayName: '江苏靖江农商',
        aliases: const <String>['jjbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jrnsh',
        assetPath: 'assets/icons/banks/library/jrnsh.svg',
        displayName: '江苏句容农商',
        aliases: const <String>['jrnsh'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#AE935C',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jsyxrcb',
        assetPath: 'assets/icons/banks/library/jsyxrcb.svg',
        displayName: '江苏宜兴农商',
        aliases: const <String>['jsyxrcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#BA533A',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.cjccb',
        assetPath: 'assets/icons/banks/library/cjccb.svg',
        displayName: '江苏长江商业银行',
        aliases: const <String>['cjccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bolz',
        assetPath: 'assets/icons/banks/library/bolz.svg',
        displayName: '柳州银行',
        aliases: const <String>['bolz'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E30016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.lj-bank',
        assetPath: 'assets/icons/banks/library/lj-bank.svg',
        displayName: '龙江银行',
        aliases: const <String>['lj-bank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#FBBE02',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.lqrcb',
        assetPath: 'assets/icons/banks/library/lqrcb.svg',
        displayName: '路桥农村合作银行',
        aliases: const <String>['lqrcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0A6BAF',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.qlbchina',
        assetPath: 'assets/icons/banks/library/qlbchina.svg',
        displayName: '齐鲁银行',
        aliases: const <String>['qlbchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#FFAD19',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.qjccb',
        assetPath: 'assets/icons/banks/library/qjccb.svg',
        displayName: '曲靖市商业银行',
        aliases: const <String>['qjccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E30016',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.qzccbank',
        assetPath: 'assets/icons/banks/library/qzccbank.svg',
        displayName: '泉州银行',
        aliases: const <String>['qzccbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#004D99',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankofrizhao',
        assetPath: 'assets/icons/banks/library/bankofrizhao.svg',
        displayName: '日照银行',
        aliases: const <String>['bankofrizhao'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F4632F',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.ubs',
        assetPath: 'assets/icons/banks/library/ubs.svg',
        displayName: '瑞士银行',
        aliases: const <String>['ubs'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E60000',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.tf',
        assetPath: 'assets/icons/banks/library/tf.svg',
        displayName: '四川天府银行',
        aliases: const <String>['tf'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#37474F',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.srcb',
        assetPath: 'assets/icons/banks/library/srcb.svg',
        displayName: '上海农商',
        aliases: const <String>['srcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F4A000',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.csxbank',
        assetPath: 'assets/icons/banks/library/csxbank.svg',
        displayName: '三湘银行',
        aliases: const <String>['csxbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.xib',
        assetPath: 'assets/icons/banks/library/xib.svg',
        displayName: '厦门国际银行',
        aliases: const <String>['xib'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0062AB',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.sdnxs',
        assetPath: 'assets/icons/banks/library/sdnxs.svg',
        displayName: '山东省农村信用社',
        aliases: const <String>['sdnxs'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50113',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.yamaguchibank',
        assetPath: 'assets/icons/banks/library/yamaguchibank.svg',
        displayName: '山口银行',
        aliases: const <String>['yamaguchibank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#EE161E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.szsccb',
        assetPath: 'assets/icons/banks/library/szsccb.svg',
        displayName: '石嘴山银行',
        aliases: const <String>['szsccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#D2A230',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.sdebank',
        assetPath: 'assets/icons/banks/library/sdebank.svg',
        displayName: '顺德农商',
        aliases: const <String>['sdebank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#1A2E92',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.snccb',
        assetPath: 'assets/icons/banks/library/snccb.svg',
        displayName: '遂宁银行',
        aliases: const <String>['snccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#438BA7',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.shengjingbank',
        assetPath: 'assets/icons/banks/library/shengjingbank.svg',
        displayName: '盛京银行',
        aliases: const <String>['shengjingbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E60019',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.suzhoubank',
        assetPath: 'assets/icons/banks/library/suzhoubank.svg',
        displayName: '苏州银行',
        aliases: const <String>['suzhoubank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#648F34',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.yantaibank',
        assetPath: 'assets/icons/banks/library/yantaibank.svg',
        displayName: '烟台银行',
        aliases: const <String>['yantaibank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#6BB42B',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.bankofyk',
        assetPath: 'assets/icons/banks/library/bankofyk.svg',
        displayName: '营口银行',
        aliases: const <String>['bankofyk'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#004898',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.sinopac',
        assetPath: 'assets/icons/banks/library/sinopac.svg',
        displayName: '永丰银行',
        aliases: const <String>['sinopac'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E62511',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.csrc',
        assetPath: 'assets/icons/banks/library/csrc.svg',
        displayName: '证监会',
        aliases: const <String>['csrc'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#AD2024',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.zaozhuangbank',
        assetPath: 'assets/icons/banks/library/zaozhuangbank.svg',
        displayName: '枣庄银行',
        aliases: const <String>['zaozhuangbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0088C2',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.sc',
        assetPath: 'assets/icons/banks/library/sc.svg',
        displayName: '枣庄银行',
        aliases: const <String>['sc'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#82B9D8',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.zxbk',
        assetPath: 'assets/icons/banks/library/zxbk.svg',
        displayName: '正信银行',
        aliases: const <String>['zxbk'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#A11017',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.ccabchina',
        assetPath: 'assets/icons/banks/library/ccabchina.svg',
        displayName: '长安银行',
        aliases: const <String>['ccabchina'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#DE0516',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.lygdfrcb',
        assetPath: 'assets/icons/banks/library/lygdfrcb.svg',
        displayName: '连云港东方农商',
        aliases: const <String>['lygdfrcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#AE935C',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.maybank',
        assetPath: 'assets/icons/banks/library/maybank.svg',
        displayName: '马来亚银行',
        aliases: const <String>['maybank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#F8C213',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.meigin',
        assetPath: 'assets/icons/banks/library/meigin.svg',
        displayName: '名古屋银行',
        aliases: const <String>['meigin'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#009B63',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.rbcroyalbank',
        assetPath: 'assets/icons/banks/library/rbcroyalbank.svg',
        displayName: '加拿大皇家银行',
        aliases: const <String>['rbcroyalbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#144B8E',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.abnamro',
        assetPath: 'assets/icons/banks/library/abnamro.svg',
        displayName: '荷兰银行',
        aliases: const <String>['abnamro'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#029286',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.barclays',
        assetPath: 'assets/icons/banks/library/barclays.svg',
        displayName: '巴克莱银行',
        aliases: const <String>['barclays'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#009DDF',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.anz',
        assetPath: 'assets/icons/banks/library/anz.svg',
        displayName: '澳新银行',
        aliases: const <String>['anz'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0096D6',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.dandongbank',
        assetPath: 'assets/icons/banks/library/dandongbank.svg',
        displayName: '丹东银行',
        aliases: const <String>['dandongbank'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#B91B24',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.xjkccb',
        assetPath: 'assets/icons/banks/library/xjkccb.svg',
        displayName: '库尔勒市商业银行',
        aliases: const <String>['xjkccb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#BE3338',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.jtnsh',
        assetPath: 'assets/icons/banks/library/jtnsh.svg',
        displayName: '九台农商',
        aliases: const <String>['jtnsh'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#007733',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.luoyang-szgold',
        assetPath: 'assets/icons/banks/library/luoyang-szgold.svg',
        displayName: '洛阳银行',
        aliases: const <String>['luoyang-szgold'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#003A81',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.mycc',
        assetPath: 'assets/icons/banks/library/mycc.svg',
        displayName: '绵阳商业银行',
        aliases: const <String>['mycc'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E60012',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.masrcb',
        assetPath: 'assets/icons/banks/library/masrcb.svg',
        displayName: '马鞍山农商',
        aliases: const <String>['masrcb'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#0086CC',
      ),
      BankIconDescriptor(
        reference: 'builtin:bank-icon.mufg',
        assetPath: 'assets/icons/banks/library/mufg.svg',
        displayName: '东京三菱银行',
        aliases: const <String>['mufg'],
        relatedEntityCode: null,
        reviewStatus: 'source_label_only',
        defaultColorHex: '#E50B1A',
      ),
    ],
  );
}

/// Metadata for bundled non-bank vector SVGs imported from `qizhang`
/// (payment platforms, social wallets, and colorful account-type badges).
final class ExtraVectorIconSpec {
  const ExtraVectorIconSpec({
    required this.reference,
    required this.canonicalKey,
    required this.assetPath,
    required this.displayName,
    required this.defaultColorHex,
    required this.insetFraction,
    required this.category,
    this.aliases = const <String>[],
  });

  /// Stable `builtin:*` reference (e.g. `'builtin:pay.wechat'`, `'builtin:social.douyin'`).
  final String reference;

  /// Key persisted when picked in TallyIsle (`'wechat_pay'` / `'alipay'` for
  /// backward compatibility, or [reference] for newly added `builtin:*` entries).
  final String canonicalKey;
  final String assetPath;
  final String displayName;
  final String defaultColorHex;
  final double insetFraction;

  /// `'payment'`, `'social'`, or `'type'`.
  final String category;
  final List<String> aliases;

  bool matchesSearch(String rawQuery) {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (displayName.toLowerCase().contains(q)) return true;
    if (canonicalKey.toLowerCase().contains(q)) return true;
    if (reference.toLowerCase().contains(q)) return true;
    for (final alias in aliases) {
      if (alias.toLowerCase().contains(q)) return true;
    }
    return false;
  }
}

const List<ExtraVectorIconSpec> extraVectorIconCatalog = <ExtraVectorIconSpec>[
  ExtraVectorIconSpec(
    reference: 'builtin:pay.wechat',
    canonicalKey: 'wechat_pay',
    assetPath: 'assets/icons/wechat.svg',
    displayName: '微信钱包',
    defaultColorHex: '#07C160',
    insetFraction: 0.18,
    category: 'payment',
    aliases: <String>['微信', '微信支付', '零钱通', 'WeChat'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:pay.alipay',
    canonicalKey: 'alipay',
    assetPath: 'assets/icons/alipay.svg',
    displayName: '支付宝',
    defaultColorHex: '#1677FF',
    insetFraction: 0.14,
    category: 'payment',
    aliases: <String>['Alipay', '支付宝钱包'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:pay.huabei',
    canonicalKey: 'huabei',
    assetPath: 'assets/icons/huabei.svg',
    displayName: '花呗',
    defaultColorHex: '#30B4FF',
    insetFraction: 0.16,
    category: 'payment',
    aliases: <String>['蚂蚁花呗', 'Huabei', '信用付'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:pay.baitiao',
    canonicalKey: 'baitiao',
    assetPath: 'assets/icons/baitiao.svg',
    displayName: '京东白条',
    defaultColorHex: '#D12C28',
    insetFraction: 0.16,
    category: 'payment',
    aliases: <String>['白条', 'Baitiao', '分期付'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:pay.yuebao',
    canonicalKey: 'builtin:pay.yuebao',
    assetPath: 'assets/icons/yuebao.svg',
    displayName: '余额宝',
    defaultColorHex: '#F15A4A',
    insetFraction: 0.16,
    category: 'payment',
    aliases: <String>['支付宝余额宝', 'Yuebao', '天弘余额宝'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:pay.ecny',
    canonicalKey: 'builtin:pay.ecny',
    assetPath: 'assets/icons/ecny.svg',
    displayName: '数字人民币',
    defaultColorHex: '#275FF5',
    insetFraction: 0.14,
    category: 'payment',
    aliases: <String>['e-CNY', 'ECNY', '数币'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:pay.yunshanfu',
    canonicalKey: 'builtin:pay.yunshanfu',
    assetPath: 'assets/icons/yunshanfu.svg',
    displayName: '云闪付',
    defaultColorHex: '#3366CC',
    insetFraction: 0.14,
    category: 'payment',
    aliases: <String>['银联云闪付', 'Yunshanfu'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:pay.unionpay',
    canonicalKey: 'unionpay',
    assetPath: 'assets/icons/unionpay.svg',
    displayName: '银联',
    defaultColorHex: '#ED171F',
    insetFraction: 0.15,
    category: 'payment',
    aliases: <String>['中国银联', 'UnionPay', '银联卡'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:pay.paypal',
    canonicalKey: 'paypal_intl',
    assetPath: 'assets/icons/paypal.svg',
    displayName: 'PayPal',
    defaultColorHex: '#179BD7',
    insetFraction: 0.15,
    category: 'payment',
    aliases: <String>['paypal', '贝宝', '跨境户'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:pay.jd',
    canonicalKey: 'builtin:pay.jd',
    assetPath: 'assets/icons/jd.svg',
    displayName: '京东',
    defaultColorHex: '#FF1010',
    insetFraction: 0.16,
    category: 'payment',
    aliases: <String>['京东金融', '京东钱包', '京东小金库', 'JD'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:pay.meituan',
    canonicalKey: 'builtin:pay.meituan',
    assetPath: 'assets/icons/meituan.svg',
    displayName: '美团',
    defaultColorHex: '#FF8E12',
    insetFraction: 0.15,
    category: 'payment',
    aliases: <String>['美团钱包', '美团生活费', 'Meituan'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:pay.visa',
    canonicalKey: 'builtin:pay.visa',
    assetPath: 'assets/icons/visa.svg',
    displayName: 'Visa',
    defaultColorHex: '#1A1F71',
    insetFraction: 0.14,
    category: 'payment',
    aliases: <String>['VISA', 'Visa卡', '维萨'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:pay.mastercard',
    canonicalKey: 'builtin:pay.mastercard',
    assetPath: 'assets/icons/mastercard.svg',
    displayName: 'Mastercard',
    defaultColorHex: '#EB001B',
    insetFraction: 0.15,
    category: 'payment',
    aliases: <String>['万事达', '万事达卡', 'MasterCard'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:social.douyin',
    canonicalKey: 'builtin:social.douyin',
    assetPath: 'assets/icons/social/douyin.svg',
    displayName: '抖音钱包',
    defaultColorHex: '#111827',
    insetFraction: 0.22,
    category: 'social',
    aliases: <String>['抖音', '抖音支付', '抖音零钱', 'TikTok', 'douyin'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:social.xiaohongshu',
    canonicalKey: 'builtin:social.xiaohongshu',
    assetPath: 'assets/icons/social/xiaohongshu.svg',
    displayName: '小红书',
    defaultColorHex: '#FF2442',
    insetFraction: 0.20,
    category: 'social',
    aliases: <String>['小红书钱包', 'RED', 'xiaohongshu'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:social.github',
    canonicalKey: 'builtin:social.github',
    assetPath: 'assets/icons/social/github.svg',
    displayName: 'GitHub',
    defaultColorHex: '#24292F',
    insetFraction: 0.18,
    category: 'social',
    aliases: <String>['github', '开发者赞助'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:social.telegram',
    canonicalKey: 'builtin:social.telegram',
    assetPath: 'assets/icons/social/telegram.svg',
    displayName: 'Telegram',
    defaultColorHex: '#26A5E4',
    insetFraction: 0.14,
    category: 'social',
    aliases: <String>['telegram', 'tg', '电报钱包'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:type.cash',
    canonicalKey: 'builtin:type.cash',
    assetPath: 'assets/icons/cash.svg',
    displayName: '现钞票据',
    defaultColorHex: '#FF9800',
    insetFraction: 0.16,
    category: 'type',
    aliases: <String>['现金', '纸币', 'cash'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:type.bank_card',
    canonicalKey: 'builtin:type.bank_card',
    assetPath: 'assets/icons/bank_card.svg',
    displayName: '储蓄卡面',
    defaultColorHex: '#1890FF',
    insetFraction: 0.16,
    category: 'type',
    aliases: <String>['银行卡', '借记卡', '储蓄卡'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:type.credit_card',
    canonicalKey: 'builtin:type.credit_card',
    assetPath: 'assets/icons/credit_card.svg',
    displayName: '信用卡面',
    defaultColorHex: '#9C27B0',
    insetFraction: 0.16,
    category: 'type',
    aliases: <String>['信用卡', '贷记卡'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:type.investment',
    canonicalKey: 'builtin:type.investment',
    assetPath: 'assets/icons/investment.svg',
    displayName: '投资理财',
    defaultColorHex: '#FF9800',
    insetFraction: 0.16,
    category: 'type',
    aliases: <String>['投资', '理财', '股票', '基金'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:type.insurance',
    canonicalKey: 'builtin:type.insurance',
    assetPath: 'assets/icons/insurance.svg',
    displayName: '保险保单',
    defaultColorHex: '#4CAF50',
    insetFraction: 0.16,
    category: 'type',
    aliases: <String>['保险', '保单'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:type.social_fund',
    canonicalKey: 'builtin:type.social_fund',
    assetPath: 'assets/icons/social_fund.svg',
    displayName: '社保公积金',
    defaultColorHex: '#3F51B5',
    insetFraction: 0.16,
    category: 'type',
    aliases: <String>['社保', '公积金', '医保'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:type.real_estate',
    canonicalKey: 'builtin:type.real_estate',
    assetPath: 'assets/icons/real_estate.svg',
    displayName: '房产置业',
    defaultColorHex: '#795548',
    insetFraction: 0.16,
    category: 'type',
    aliases: <String>['房产', '不动产', '房屋'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:type.vehicle',
    canonicalKey: 'builtin:type.vehicle',
    assetPath: 'assets/icons/vehicle.svg',
    displayName: '车辆座驾',
    defaultColorHex: '#607D8B',
    insetFraction: 0.16,
    category: 'type',
    aliases: <String>['车辆', '汽车', '车产'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:type.loan',
    canonicalKey: 'builtin:type.loan',
    assetPath: 'assets/icons/loan.svg',
    displayName: '贷款负债',
    defaultColorHex: '#E91E63',
    insetFraction: 0.16,
    category: 'type',
    aliases: <String>['贷款', '房贷', '车贷'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:type.receivable',
    canonicalKey: 'builtin:type.receivable',
    assetPath: 'assets/icons/receivable.svg',
    displayName: '应收票据',
    defaultColorHex: '#009688',
    insetFraction: 0.16,
    category: 'type',
    aliases: <String>['应收', '待报销'],
  ),
  ExtraVectorIconSpec(
    reference: 'builtin:type.other_account',
    canonicalKey: 'builtin:type.other_account',
    assetPath: 'assets/icons/other_account.svg',
    displayName: '通用卡包',
    defaultColorHex: '#607D8B',
    insetFraction: 0.16,
    category: 'type',
    aliases: <String>['卡包', '其他账户'],
  ),
];

final Map<String, ExtraVectorIconSpec> _extraVectorByKey =
    <String, ExtraVectorIconSpec>{
      for (final spec in extraVectorIconCatalog) ...{
        spec.reference: spec,
        spec.canonicalKey: spec,
      },
    };

/// Resolves any bundled SVG icon (`builtin:bank.*`, `builtin:bank-icon.*`,
/// `builtin:pay.*`, `builtin:social.*`, `builtin:type.*`, `'wechat_pay'`,
/// `'alipay'`) to its vector rendering metadata.
({
  String canonicalKey,
  String assetPath,
  String displayName,
  String defaultColorHex,
  double insetFraction,
})?
resolveBundledVectorIcon(String? rawKey) {
  if (rawKey == null) return null;
  final trimmed = rawKey.trim();
  if (trimmed.isEmpty) return null;

  final extra = _extraVectorByKey[trimmed];
  if (extra != null) {
    return (
      canonicalKey: extra.canonicalKey,
      assetPath: extra.assetPath,
      displayName: extra.displayName,
      defaultColorHex: extra.defaultColorHex,
      insetFraction: extra.insetFraction,
    );
  }

  final bank = BankIconCatalog.bundled.descriptorFor(trimmed);
  if (bank != null) {
    return (
      canonicalKey: bank.reference,
      assetPath: bank.assetPath,
      displayName: bank.displayName,
      defaultColorHex: bank.defaultColorHex,
      insetFraction: 0.05,
    );
  }
  return null;
}

/// Result of smart institution auto-matching on an account or bank-card name.
final class InstitutionAutoMatch {
  const InstitutionAutoMatch({
    required this.iconKey,
    required this.colorHex,
    required this.displayName,
    required this.svgAssetPath,
  });

  final String iconKey;
  final String colorHex;
  final String displayName;
  final String svgAssetPath;
}

const List<(String, List<String>)> _reviewedBankCjkKeywords =
    <(String, List<String>)>[
      (
        'builtin:bank.psbc',
        <String>['中国邮政储蓄银行', '邮政储蓄银行', '邮政储蓄', '邮政银行', '邮储银行', '邮储'],
      ),
      ('builtin:bank.spdb', <String>['上海浦东发展银行', '浦东发展银行', '浦发银行', '浦发']),
      ('builtin:bank.icbc', <String>['中国工商银行', '工商银行', '工行']),
      ('builtin:bank.ccb', <String>['中国建设银行', '建设银行', '建行']),
      ('builtin:bank.abc', <String>['中国农业银行', '农业银行', '农行']),
      ('builtin:bank.bocom', <String>['中国交通银行', '交通银行', '交行']),
      ('builtin:bank.cmbc', <String>['中国民生银行', '民生银行', '民生']),
      ('builtin:bank.ceb', <String>['中国光大银行', '光大银行', '光大']),
      ('builtin:bank.cgb', <String>['广东发展银行', '广发银行', '广发']),
      ('builtin:bank.boc', <String>['中国银行', '中行']),
      ('builtin:bank.cmb', <String>['招商银行', '招行', '招商']),
      ('builtin:bank.citic', <String>['中信银行', '中信']),
      ('builtin:bank.cib', <String>['兴业银行', '兴业']),
      ('builtin:bank.pingan', <String>['平安银行', '平安']),
      ('builtin:bank.hxb', <String>['华夏银行', '华夏']),
      ('builtin:bank.czbank', <String>['浙商银行', '浙商']),
      ('builtin:bank.bohai', <String>['渤海银行', '渤海']),
      ('builtin:bank.hengfeng', <String>['恒丰银行', '恒丰']),
      ('builtin:bank.zabank', <String>['众安银行', '众安']),
    ];

const List<(String, String)> _contextualBankCjkStems = <(String, String)>[
  ('builtin:bank.icbc', '工商'),
  ('builtin:bank.ccb', '建设'),
  ('builtin:bank.abc', '农业'),
  ('builtin:bank.psbc', '邮政'),
];

const List<String> _bankingContextWords = <String>[
  '银行',
  '卡',
  '储蓄',
  '借记',
  '信用',
  '贷记',
  '存折',
  '工资',
];

final List<(String, RegExp, bool)>
_reviewedBankAsciiPatterns = <(String, RegExp, bool)>[
  for (final (ref, code, requireUpperOrBankContext)
      in const <(String, String, bool)>[
        ('builtin:bank.czbank', 'CZBANK', false),
        ('builtin:bank.hengfeng', 'HFBANK', false),
        ('builtin:bank.zabank', 'ZABank', false),
        ('builtin:bank.zabank', 'ZA Bank', false),
        ('builtin:bank.bocom', 'BOCOM', false),
        ('builtin:bank.citic', 'CITIC', false),
        ('builtin:bank.icbc', 'ICBC', false),
        ('builtin:bank.cmbc', 'CMBC', false),
        ('builtin:bank.psbc', 'PSBC', false),
        ('builtin:bank.spdb', 'SPDB', false),
        ('builtin:bank.bohai', 'CBHB', false),
        ('builtin:bank.boc', 'BOC', false),
        ('builtin:bank.ccb', 'CCB', false),
        ('builtin:bank.cmb', 'CMB', false),
        ('builtin:bank.cgb', 'CGB', false),
        ('builtin:bank.ceb', 'CEB', false),
        ('builtin:bank.pingan', 'PAB', false),
        ('builtin:bank.hxb', 'HXB', false),
        ('builtin:bank.cib', 'CIB', false),
        ('builtin:bank.abc', 'ABC', true),
      ])
    (
      ref,
      RegExp(
        '(?<![A-Za-z0-9])${code.split(' ').map(RegExp.escape).join(r'\s+')}(?![A-Za-z0-9])',
        caseSensitive: false,
      ),
      requireUpperOrBankContext,
    ),
];

final RegExp _upperAbcPattern = RegExp(r'(?<![A-Za-z0-9])ABC(?![A-Za-z0-9])');
final RegExp _jdECardPattern = RegExp(r'京东\s*e\s*卡', caseSensitive: false);
final RegExp _huabeiAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])huabei(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _baitiaoAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])baitiao(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _yuebaoAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])yuebao(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _wechatAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])wechat(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _alipayAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])alipay(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _ecnyAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])e-?cny(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _yunshanfuAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])yunshanfu(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _unionpayAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])union\s*pay(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _paypalAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])pay\s*pal(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _jdAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])jd(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _meituanAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])meituan(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _visaAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])visa(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _mastercardAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])master\s*card(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _douyinAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])(douyin|tiktok)(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _xhsAsciiPattern = RegExp(
  r'(?<![A-Za-z0-9])xiaohongshu(?![A-Za-z0-9])',
  caseSensitive: false,
);

bool _containsAny(String text, List<String> needles) {
  for (final n in needles) {
    if (text.contains(n)) return true;
  }
  return false;
}

InstitutionAutoMatch _bankMatchFor(String ref) {
  final desc = BankIconCatalog.bundled.descriptorFor(ref)!;
  return InstitutionAutoMatch(
    iconKey: desc.reference,
    colorHex: desc.defaultColorHex,
    displayName: desc.displayName,
    svgAssetPath: desc.assetPath,
  );
}

InstitutionAutoMatch _extraMatchFor(ExtraVectorIconSpec spec) =>
    InstitutionAutoMatch(
      iconKey: spec.canonicalKey,
      colorHex: spec.defaultColorHex,
      displayName: spec.displayName,
      svgAssetPath: spec.assetPath,
    );

/// Smartly matches [rawName] against the 19 reviewed commercial banks and
/// curated payment/card-network/social platforms, strictly rejecting
/// `source_label_only` entries and ambiguous non-bank names (`交通卡`, `平安保险`,
/// `华夏基金`, `美团月付`, `京东e卡`, `朝朝宝`, `abcde`).
InstitutionAutoMatch? matchReviewedInstitution(
  String rawName, {
  int? assetType,
  bool isBankCardMemo = false,
}) {
  final name = rawName.trim();
  if (name.isEmpty) return null;
  if (!isBankCardMemo && assetType == AssetType.debt) return null;

  final lower = name.toLowerCase();
  final hasBankContext =
      isBankCardMemo || _containsAny(name, _bankingContextWords);

  if (!isBankCardMemo) {
    // Non-SVG credit/gift/wealth sub-brands keep their dedicated Material presets
    // (`virtual_credit`, `credit_line`, `gift_card`, `wealth`).
    if (name.contains('先享后付') ||
        name.contains('信用购') ||
        name.contains('借呗') ||
        name.contains('微粒贷') ||
        name.contains('金条') ||
        name.contains('美团月付') ||
        (name.contains('美团') && name.contains('月付')) ||
        _jdECardPattern.hasMatch(name) ||
        name.contains('朝朝宝')) {
      return null;
    }

    // Insurance policies (e.g. 平安保险 / 众安保险) stay insurance unless bank/card context exists.
    if (!hasBankContext &&
        _containsAny(name, const <String>[
          '保险',
          '保单',
          '车险',
          '寿险',
          '重疾险',
          '医疗险',
          '年金',
        ])) {
      return null;
    }

    // Brokerage / fund accounts (e.g. 招商证券 / 华夏基金 / 广发基金) stay stock/fund unless bank/card context exists.
    if (!hasBankContext &&
        (_containsAny(name, const <String>['证券', '基金', '股票', '定投']) ||
            lower.contains('etf'))) {
      return null;
    }
  }

  // 1. Check unambiguous reviewed bank CJK names & aliases (beats card networks).
  for (final (ref, keywords) in _reviewedBankCjkKeywords) {
    for (final kw in keywords) {
      if (name.contains(kw)) {
        return _bankMatchFor(ref);
      }
    }
  }

  // 2. Check contextual CJK stems (e.g. "工商工资卡", "建设储蓄卡").
  if (hasBankContext) {
    for (final (ref, stem) in _contextualBankCjkStems) {
      if (name.contains(stem)) {
        return _bankMatchFor(ref);
      }
    }
  }

  // 3. Check reviewed ASCII bank codes with strict alphanumeric word boundaries.
  for (final (ref, pattern, requireUpperOrBankContext)
      in _reviewedBankAsciiPatterns) {
    if (pattern.hasMatch(name)) {
      if (requireUpperOrBankContext &&
          !hasBankContext &&
          !_upperAbcPattern.hasMatch(name)) {
        continue;
      }
      return _bankMatchFor(ref);
    }
  }

  // 4. Payment, card networks & social wallets (for Asset accounts; bank card memos stay bank-focused).
  if (!isBankCardMemo) {
    if (name.contains('花呗') || _huabeiAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['huabei']!);
    }
    if (name.contains('白条') || _baitiaoAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['baitiao']!);
    }
    if (name.contains('余额宝') || _yuebaoAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['builtin:pay.yuebao']!);
    }
    if (name.contains('微信') ||
        name.contains('零钱通') ||
        _wechatAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['wechat_pay']!);
    }
    if (name.contains('支付宝') || _alipayAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['alipay']!);
    }
    if (name.contains('数字人民币') || _ecnyAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['builtin:pay.ecny']!);
    }
    if (name.contains('云闪付') || _yunshanfuAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['builtin:pay.yunshanfu']!);
    }
    if (name.contains('银联') || _unionpayAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['unionpay']!);
    }
    if (name.contains('贝宝') || _paypalAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['paypal_intl']!);
    }
    if (name.contains('京东') || _jdAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['builtin:pay.jd']!);
    }
    if (name.contains('美团') || _meituanAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['builtin:pay.meituan']!);
    }
    if (_visaAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['builtin:pay.visa']!);
    }
    if (name.contains('万事达') || _mastercardAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['builtin:pay.mastercard']!);
    }
    if (name.contains('抖音') || _douyinAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['builtin:social.douyin']!);
    }
    if (name.contains('小红书') || _xhsAsciiPattern.hasMatch(name)) {
      return _extraMatchFor(_extraVectorByKey['builtin:social.xiaohongshu']!);
    }
  }

  return null;
}
