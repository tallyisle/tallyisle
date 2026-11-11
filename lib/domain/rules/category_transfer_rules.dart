import 'dart:convert';
import 'dart:typed_data';

import '../../core/failure.dart';

const String categoryPackFormat = 'tallyisle_categories';
const int categoryPackVersion = 1;
const int maxCategoryNameLength = 50;

String _validateCategoryName(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.length > maxCategoryNameLength) {
    throw const Failure(FailureCode.validation, '分类名称须为 1–50 个字符');
  }
  return trimmed;
}

int _validateCategoryType(Object? raw) {
  final int? type = switch (raw) {
    int v => v,
    String s => int.tryParse(s.trim()),
    _ => null,
  };
  if (type != 0 && type != 1) {
    throw const Failure(FailureCode.validation, '分类收支类型无效（仅支持 0 支出 / 1 收入）');
  }
  return type!;
}

bool _parseOptionalBool(Object? raw, {bool fallback = false}) {
  if (raw == null) return fallback;
  if (raw is bool) return raw;
  if (raw is int) return raw != 0;
  if (raw is String) {
    final lower = raw.trim().toLowerCase();
    if (lower == 'true' || lower == '1') return true;
    if (lower == 'false' || lower == '0' || lower.isEmpty) return false;
  }
  throw const Failure(FailureCode.validation, '分类隐藏标志格式无效');
}

int _parseOptionalInt(Object? raw, {int fallback = 0}) {
  if (raw == null) return fallback;
  if (raw is int) return raw;
  if (raw is String) {
    final parsed = int.tryParse(raw.trim());
    if (parsed != null) return parsed;
  }
  throw const Failure(FailureCode.validation, '分类整数字段格式无效');
}

String? _parseOptionalNullableString(Object? raw) {
  if (raw == null) return null;
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (raw is Map) return jsonEncode(raw);
  throw const Failure(FailureCode.validation, '分类扩展文本格式无效');
}

/// Pure 2-level category node for JSON export/import and cross-book copy (F-031).
final class CategoryNode {
  CategoryNode({
    required String name,
    required this.type,
    this.icon = '',
    this.colorFill,
    this.sort = 0,
    this.isHide = false,
    this.extraInfo,
    Iterable<CategoryNode> children = const [],
  }) : name = _validateCategoryName(name),
       children = List<CategoryNode>.unmodifiable(children) {
    if (type != 0 && type != 1) {
      throw const Failure(FailureCode.validation, '分类收支类型无效');
    }
    for (final child in this.children) {
      if (child.type != type) {
        throw const Failure(FailureCode.validation, '二级子分类必须与父分类收支类型一致');
      }
      if (child.children.isNotEmpty) {
        throw const Failure(FailureCode.validation, '仅支持两级分类结构');
      }
    }
  }

  final String name;
  final int type;
  final String icon;
  final String? colorFill;
  final int sort;
  final bool isHide;
  final String? extraInfo;
  final List<CategoryNode> children;

  Map<String, Object?> toJson({bool includeChildren = true}) => {
    'name': name,
    'type': type,
    'icon': icon,
    'colorFill': colorFill,
    'sort': sort,
    'isHide': isHide,
    'extraInfo': extraInfo,
    if (includeChildren)
      'children': [
        for (final child in children) child.toJson(includeChildren: false),
      ],
  };

  factory CategoryNode.fromJson(
    Map<String, Object?> json, {
    required bool allowChildren,
    int? inheritedType,
  }) {
    final rawName = json['name'];
    if (rawName is! String) {
      throw const Failure(FailureCode.validation, '分类节点缺少有效的 name 字段');
    }
    final type = json['type'] == null && inheritedType != null
        ? inheritedType
        : _validateCategoryType(json['type']);
    if (inheritedType != null && type != inheritedType) {
      throw const Failure(FailureCode.validation, '二级子分类必须与父分类收支类型一致');
    }

    final rawChildren = json['children'];
    final children = <CategoryNode>[];
    if (rawChildren != null) {
      if (rawChildren is! List) {
        throw const Failure(FailureCode.validation, '分类 children 字段必须为数组');
      }
      if (!allowChildren && rawChildren.isNotEmpty) {
        throw const Failure(FailureCode.validation, '仅支持两级分类结构');
      }
      for (final item in rawChildren) {
        if (item is! Map) {
          throw const Failure(FailureCode.validation, '二级子分类节点格式无效');
        }
        children.add(
          CategoryNode.fromJson(
            <String, Object?>{
              for (final e in item.entries) e.key.toString(): e.value,
            },
            allowChildren: false,
            inheritedType: type,
          ),
        );
      }
    }

    final rawIcon = json['icon'];
    if (rawIcon != null && rawIcon is! String && rawIcon is! int) {
      throw const Failure(FailureCode.validation, '分类 icon 格式无效');
    }

    return CategoryNode(
      name: rawName,
      type: type,
      icon: rawIcon == null ? '' : rawIcon.toString(),
      colorFill: _parseOptionalNullableString(
        json['colorFill'] ?? json['color_fill'],
      ),
      sort: _parseOptionalInt(json['sort']),
      isHide: _parseOptionalBool(json['isHide'] ?? json['is_hide']),
      extraInfo: _parseOptionalNullableString(
        json['extraInfo'] ?? json['extra_info'],
      ),
      children: children,
    );
  }
}

/// Portable local JSON package for a book's 2-level category tree (F-031, P-03).
final class CategoryPack {
  CategoryPack({
    this.version = categoryPackVersion,
    required String bookName,
    required this.exportedAtMs,
    required Iterable<CategoryNode> categories,
  }) : bookName = bookName.trim().isEmpty ? '默认账本' : bookName.trim(),
       categories = List<CategoryNode>.unmodifiable(categories) {
    if (version < 1) {
      throw const Failure(FailureCode.validation, '分类方案版本号无效');
    }
    if (version > categoryPackVersion) {
      throw const Failure(FailureCode.upgradeRequired, '分类方案版本较新，请升级帐屿后再导入');
    }
  }

  final int version;
  final String bookName;
  final int exportedAtMs;
  final List<CategoryNode> categories;

  int get topCategoryCount => categories.length;
  int get subCategoryCount =>
      categories.fold<int>(0, (sum, c) => sum + c.children.length);
  int get totalCategoryCount => topCategoryCount + subCategoryCount;
  int get expenseTopCount => categories.where((c) => c.type == 0).length;
  int get incomeTopCount => categories.where((c) => c.type == 1).length;

  Map<String, Object?> toJson() => {
    'format': categoryPackFormat,
    'version': version,
    'bookName': bookName,
    'exportedAtMs': exportedAtMs,
    'categories': [for (final c in categories) c.toJson()],
  };

  String encodeJson({bool pretty = true}) => pretty
      ? const JsonEncoder.withIndent('  ').convert(toJson())
      : jsonEncode(toJson());

  Uint8List encodeUtf8Bytes({bool pretty = true}) =>
      Uint8List.fromList(utf8.encode(encodeJson(pretty: pretty)));

  static CategoryPack decodeUtf8Bytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const Failure(FailureCode.validation, '分类文件为空');
    }
    final String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const Failure(FailureCode.corruptData, '分类文件不是有效的 UTF-8 编码');
    }
    return decodeJson(text);
  }

  static CategoryPack decodeJson(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const Failure(FailureCode.validation, '分类文件为空');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw const Failure(FailureCode.corruptData, '分类文件 JSON 解析失败');
    }

    if (decoded is List) {
      final nodes = _parseCategoryList(decoded);
      if (nodes.isEmpty) {
        throw const Failure(FailureCode.validation, '分类导入文件不包含有效分类');
      }
      return CategoryPack(bookName: '导入分类', exportedAtMs: 0, categories: nodes);
    }

    if (decoded is! Map) {
      throw const Failure(FailureCode.corruptData, '分类文件顶层 JSON 结构无效');
    }

    final map = <String, Object?>{
      for (final e in decoded.entries) e.key.toString(): e.value,
    };
    final rawFormat = map['format'];
    if (rawFormat != null &&
        rawFormat is String &&
        rawFormat.isNotEmpty &&
        rawFormat != categoryPackFormat) {
      throw const Failure(FailureCode.validation, '不是有效的帐屿分类方案文件');
    }

    final version = _parseOptionalInt(
      map['version'],
      fallback: categoryPackVersion,
    );
    if (version > categoryPackVersion) {
      throw const Failure(FailureCode.upgradeRequired, '分类方案版本较新，请升级帐屿后再导入');
    }
    if (version < 1) {
      throw const Failure(FailureCode.validation, '分类方案版本号无效');
    }

    final rawCategories = map['categories'];
    if (rawCategories is! List) {
      throw const Failure(FailureCode.validation, '分类文件缺少 categories 数组');
    }
    final nodes = _parseCategoryList(rawCategories);
    if (nodes.isEmpty) {
      throw const Failure(FailureCode.validation, '分类导入文件不包含有效分类');
    }
    final bookName = map['bookName'] is String
        ? map['bookName'] as String
        : '导入分类';
    final exportedAtMs = _parseOptionalInt(map['exportedAtMs']);

    return CategoryPack(
      version: version,
      bookName: bookName,
      exportedAtMs: exportedAtMs < 0 ? 0 : exportedAtMs,
      categories: nodes,
    );
  }

  static List<CategoryNode> _parseCategoryList(List<Object?> rawList) {
    // Support both nested `{children: [...]}` trees and flat `{id, parentCatId}` lists.
    final hasFlatParentKey = rawList.any(
      (item) =>
          item is Map &&
          (item.containsKey('parent_cat_id') ||
              item.containsKey('parentCatId')) &&
          !item.containsKey('children'),
    );
    if (hasFlatParentKey) {
      final snapshots = <ExistingCategorySnapshot>[];
      var syntheticId = 1;
      for (final item in rawList) {
        if (item is! Map) {
          throw const Failure(FailureCode.validation, '分类条目格式无效');
        }
        final m = <String, Object?>{
          for (final e in item.entries) e.key.toString(): e.value,
        };
        final rawName = m['name'];
        if (rawName is! String) {
          throw const Failure(FailureCode.validation, '分类节点缺少有效的 name 字段');
        }
        snapshots.add(
          ExistingCategorySnapshot(
            id: _parseOptionalInt(m['id'], fallback: syntheticId++),
            name: _validateCategoryName(rawName),
            type: _validateCategoryType(m['type']),
            parentCatId: _parseOptionalInt(
              m['parentCatId'] ?? m['parent_cat_id'],
              fallback: -1,
            ),
            sort: _parseOptionalInt(m['sort']),
            icon: (m['icon'] ?? '').toString(),
            colorFill: _parseOptionalNullableString(
              m['colorFill'] ?? m['color_fill'],
            ),
            isHide: _parseOptionalBool(m['isHide'] ?? m['is_hide']),
            extraInfo: _parseOptionalNullableString(
              m['extraInfo'] ?? m['extra_info'],
            ),
            accountBookId: 1,
          ),
        );
      }
      // Verify no 3rd level in flat representation.
      final byId = {for (final s in snapshots) s.id: s};
      for (final s in snapshots) {
        if (s.parentCatId != -1) {
          final parent = byId[s.parentCatId];
          if (parent == null) {
            throw const Failure(FailureCode.validation, '平铺分类缺少对应的一级父分类');
          }
          if (parent.parentCatId != -1) {
            throw const Failure(FailureCode.validation, '仅支持两级分类结构');
          }
          if (parent.type != s.type) {
            throw const Failure(FailureCode.validation, '二级子分类必须与父分类收支类型一致');
          }
        }
      }
      return buildCategoryTreeFromSnapshots(snapshots, includeHidden: true);
    }

    return [
      for (final item in rawList)
        if (item is Map)
          CategoryNode.fromJson(<String, Object?>{
            for (final e in item.entries) e.key.toString(): e.value,
          }, allowChildren: true)
        else
          throw const Failure(FailureCode.validation, '分类节点必须为 JSON 对象'),
    ];
  }
}

/// Pure snapshot of a stored `record_category` row for domain planning.
final class ExistingCategorySnapshot {
  const ExistingCategorySnapshot({
    required this.id,
    required this.name,
    required this.type,
    this.parentCatId = -1,
    this.sort = 0,
    this.icon = '',
    this.colorFill,
    this.isHide = false,
    this.extraInfo,
    required this.accountBookId,
  });

  final int id;
  final String name;
  final int type;
  final int parentCatId;
  final int sort;
  final String icon;
  final String? colorFill;
  final bool isHide;
  final String? extraInfo;
  final int accountBookId;
}

/// Builds a normalized 2-level [CategoryNode] list from stored category rows.
List<CategoryNode> buildCategoryTreeFromSnapshots(
  Iterable<ExistingCategorySnapshot> rows, {
  bool includeHidden = true,
}) {
  final filtered = [
    for (final r in rows)
      if (includeHidden || !r.isHide) r,
  ];
  final tops =
      [
        for (final r in filtered)
          if (r.parentCatId == -1) r,
      ]..sort((a, b) {
        final t = a.type.compareTo(b.type);
        if (t != 0) return t;
        final s = a.sort.compareTo(b.sort);
        return s != 0 ? s : a.id.compareTo(b.id);
      });

  final subsByParent = <int, List<ExistingCategorySnapshot>>{};
  for (final r in filtered) {
    if (r.parentCatId != -1) {
      subsByParent.putIfAbsent(r.parentCatId, () => []).add(r);
    }
  }
  for (final subs in subsByParent.values) {
    subs.sort((a, b) {
      final s = a.sort.compareTo(b.sort);
      return s != 0 ? s : a.id.compareTo(b.id);
    });
  }

  return [
    for (final top in tops)
      CategoryNode(
        name: top.name,
        type: top.type,
        icon: top.icon,
        colorFill: top.colorFill,
        sort: top.sort,
        isHide: top.isHide,
        extraInfo: top.extraInfo,
        children: [
          for (final sub in subsByParent[top.id] ?? const [])
            if (sub.type == top.type)
              CategoryNode(
                name: sub.name,
                type: sub.type,
                icon: sub.icon,
                colorFill: sub.colorFill,
                sort: sub.sort,
                isHide: sub.isHide,
                extraInfo: sub.extraInfo,
              ),
        ],
      ),
  ];
}

/// Builds a [CategoryPack] from stored category rows of one book.
CategoryPack buildCategoryPackFromRows({
  required String bookName,
  required int exportedAtMs,
  required Iterable<ExistingCategorySnapshot> rows,
  bool includeHidden = true,
}) => CategoryPack(
  bookName: bookName,
  exportedAtMs: exportedAtMs,
  categories: buildCategoryTreeFromSnapshots(
    rows,
    includeHidden: includeHidden,
  ),
);

/// Extracts the 2-level category forest to copy from a source book (R3).
///
/// - When [selectedIds] is null, copies all categories (respecting [includeHidden]).
/// - When a top-level category is selected without any explicit child in
///   [selectedIds], all of its visible children are included.
/// - When only a subcategory is selected, its parent top-level category is
///   automatically included so the 2-level hierarchy remains intact.
List<CategoryNode> buildSelectedCategoryTree({
  required Iterable<ExistingCategorySnapshot> sourceRows,
  Set<int>? selectedIds,
  bool includeHidden = false,
}) {
  if (selectedIds == null) {
    return buildCategoryTreeFromSnapshots(
      sourceRows,
      includeHidden: includeHidden,
    );
  }
  if (selectedIds.isEmpty) {
    throw const Failure(FailureCode.validation, '请至少选择一个要复制的分类');
  }

  final byId = {for (final r in sourceRows) r.id: r};
  for (final id in selectedIds) {
    if (!byId.containsKey(id)) {
      throw const Failure(FailureCode.validation, '所选源分类不存在');
    }
  }

  final subsByParent = <int, List<ExistingCategorySnapshot>>{};
  for (final r in sourceRows) {
    if (r.parentCatId != -1) {
      subsByParent.putIfAbsent(r.parentCatId, () => []).add(r);
    }
  }

  final includedRows = <int, ExistingCategorySnapshot>{};
  for (final id in selectedIds) {
    final row = byId[id]!;
    if (!includeHidden && row.isHide) continue;
    includedRows[row.id] = row;
    if (row.parentCatId == -1) {
      final allSubs = subsByParent[row.id] ?? const [];
      final explicitlySelectedSubs = [
        for (final s in allSubs)
          if (selectedIds.contains(s.id) && (includeHidden || !s.isHide)) s,
      ];
      final effectiveSubs = explicitlySelectedSubs.isNotEmpty
          ? explicitlySelectedSubs
          : [
              for (final s in allSubs)
                if (includeHidden || !s.isHide) s,
            ];
      for (final s in effectiveSubs) {
        includedRows[s.id] = s;
      }
    } else {
      final parent = byId[row.parentCatId];
      if (parent != null) {
        includedRows[parent.id] = parent;
      }
    }
  }

  final tree = buildCategoryTreeFromSnapshots(
    includedRows.values,
    includeHidden: true,
  );
  if (tree.isEmpty) {
    throw const Failure(FailureCode.validation, '没有符合条件的分类可复制');
  }
  return tree;
}

final class PlannedSubCategory {
  const PlannedSubCategory({
    required this.node,
    required this.sort,
    this.reuseExistingId,
  });

  final CategoryNode node;
  final int sort;
  final int? reuseExistingId;

  bool get isDuplicate => reuseExistingId != null;
}

final class PlannedTopCategory {
  const PlannedTopCategory({
    required this.node,
    required this.sort,
    this.reuseExistingId,
    required this.children,
  });

  final CategoryNode node;
  final int sort;
  final int? reuseExistingId;
  final List<PlannedSubCategory> children;

  bool get isDuplicate => reuseExistingId != null;
}

/// Deterministic duplicate-safe `(type, name)` merge plan for 2-level categories (R2).
final class CategoryMergePlan {
  const CategoryMergePlan({
    required this.topCategories,
    required this.addedTopCount,
    required this.addedSubCount,
    required this.skippedDuplicateCount,
  });

  final List<PlannedTopCategory> topCategories;
  final int addedTopCount;
  final int addedSubCount;
  final int skippedDuplicateCount;

  int get totalAddedCount => addedTopCount + addedSubCount;
}

final class _MergedIncomingTop {
  _MergedIncomingTop(this.base);
  final CategoryNode base;
  final List<CategoryNode> children = [];
  final Set<String> childNames = {};
  int duplicateCount = 0;

  void addChildren(Iterable<CategoryNode> incomingChildren) {
    for (final child in incomingChildren) {
      final key = child.name.trim();
      if (childNames.add(key)) {
        children.add(child);
      } else {
        duplicateCount++;
      }
    }
  }
}

/// Computes a duplicate-safe merge plan against [targetExisting] categories in a book.
CategoryMergePlan planCategoryMerge({
  required Iterable<ExistingCategorySnapshot> targetExisting,
  required Iterable<CategoryNode> incoming,
}) {
  // 1. Deduplicate incoming nodes by `(type, name.trim())` at top and sub levels.
  final dedupedTopByKey = <(int, String), _MergedIncomingTop>{};
  final orderedKeys = <(int, String)>[];
  var internalSkipped = 0;

  for (final top in incoming) {
    final key = (top.type, top.name.trim());
    final bucket = dedupedTopByKey[key];
    if (bucket == null) {
      final created = _MergedIncomingTop(top)..addChildren(top.children);
      dedupedTopByKey[key] = created;
      orderedKeys.add(key);
    } else {
      internalSkipped++;
      bucket.addChildren(top.children);
    }
  }
  for (final b in dedupedTopByKey.values) {
    internalSkipped += b.duplicateCount;
  }

  // 2. Index existing target categories.
  final existingTopByKey = <(int, String), ExistingCategorySnapshot>{};
  final existingSubsByParent = <int, Map<String, ExistingCategorySnapshot>>{};
  final nextTopSortByType = <int, int>{0: 0, 1: 0};
  final nextSubSortByParent = <int, int>{};

  for (final row in targetExisting) {
    if (row.parentCatId == -1) {
      existingTopByKey.putIfAbsent((row.type, row.name.trim()), () => row);
      final curMax = nextTopSortByType[row.type] ?? 0;
      if (row.sort + 1 > curMax) {
        nextTopSortByType[row.type] = row.sort + 1;
      }
    } else {
      existingSubsByParent.putIfAbsent(
        row.parentCatId,
        () => <String, ExistingCategorySnapshot>{},
      )[row.name.trim()] = row;
      final curSubMax = nextSubSortByParent[row.parentCatId] ?? 0;
      if (row.sort + 1 > curSubMax) {
        nextSubSortByParent[row.parentCatId] = row.sort + 1;
      }
    }
  }

  // 3. Plan operations.
  final plannedTops = <PlannedTopCategory>[];
  var addedTop = 0;
  var addedSub = 0;
  var skipped = internalSkipped;

  for (final key in orderedKeys) {
    final item = dedupedTopByKey[key]!;
    final existingTop = existingTopByKey[key];
    if (existingTop != null) {
      skipped++;
      final existingSubMap =
          existingSubsByParent[existingTop.id] ??
          const <String, ExistingCategorySnapshot>{};
      var subSort = nextSubSortByParent[existingTop.id] ?? 0;
      final plannedSubs = <PlannedSubCategory>[];
      for (final child in item.children) {
        final existingSub = existingSubMap[child.name.trim()];
        if (existingSub != null) {
          skipped++;
          plannedSubs.add(
            PlannedSubCategory(
              node: child,
              sort: existingSub.sort,
              reuseExistingId: existingSub.id,
            ),
          );
        } else {
          addedSub++;
          plannedSubs.add(PlannedSubCategory(node: child, sort: subSort++));
        }
      }
      nextSubSortByParent[existingTop.id] = subSort;
      plannedTops.add(
        PlannedTopCategory(
          node: item.base,
          sort: existingTop.sort,
          reuseExistingId: existingTop.id,
          children: plannedSubs,
        ),
      );
    } else {
      addedTop++;
      final topSort = nextTopSortByType[item.base.type] ?? 0;
      nextTopSortByType[item.base.type] = topSort + 1;
      var subSort = 0;
      final plannedSubs = <PlannedSubCategory>[];
      for (final child in item.children) {
        addedSub++;
        plannedSubs.add(PlannedSubCategory(node: child, sort: subSort++));
      }
      plannedTops.add(
        PlannedTopCategory(
          node: item.base,
          sort: topSort,
          children: plannedSubs,
        ),
      );
    }
  }

  return CategoryMergePlan(
    topCategories: plannedTops,
    addedTopCount: addedTop,
    addedSubCount: addedSub,
    skippedDuplicateCount: skipped,
  );
}

/// Validates intra-book category migration and returns all source category IDs
/// to migrate (`[source.id, ...subIds]` when [includeSubcategories] is true).
List<int> validateIntraBookMigration({
  required ExistingCategorySnapshot source,
  required ExistingCategorySnapshot target,
  required Iterable<ExistingCategorySnapshot> allBookCategories,
  bool includeSubcategories = true,
}) {
  if (source.accountBookId != target.accountBookId) {
    throw const Failure(FailureCode.validation, '源分类与目标分类必须属于同一账本');
  }
  if (source.type != target.type) {
    throw const Failure(FailureCode.validation, '源分类与目标分类收支类型必须一致');
  }
  final affectedIds = <int>[source.id];
  if (includeSubcategories && source.parentCatId == -1) {
    for (final c in allBookCategories) {
      if (c.parentCatId == source.id) {
        affectedIds.add(c.id);
      }
    }
  }
  if (affectedIds.contains(target.id)) {
    throw const Failure(FailureCode.validation, '不能迁移到自身或其下属子分类');
  }
  return affectedIds;
}

/// Formats a safe export filename (`categories_<book>_YYYYMMDD_HHMMSS.json`).
String formatCategoryPackFileName(String bookName, DateTime when) {
  String pad2(int n) => n.toString().padLeft(2, '0');
  final safeBook = bookName
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')
      .replaceAll(RegExp(r'_+'), '_');
  final label = safeBook.isEmpty ? 'book' : safeBook;
  final y = when.year.toString().padLeft(4, '0');
  final m = pad2(when.month);
  final d = pad2(when.day);
  final hh = pad2(when.hour);
  final mm = pad2(when.minute);
  final ss = pad2(when.second);
  return 'categories_${label}_${y}${m}${d}_$hh$mm$ss.json';
}
