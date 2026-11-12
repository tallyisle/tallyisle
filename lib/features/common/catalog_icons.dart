import 'package:flutter/material.dart';

import '../../domain/model/codes.dart';

/// Harmonious Material 3-aligned color presets matching 一羽记账's soft rounded
/// circular category and account icon badges.
const List<String> catalogColorHexPresets = <String>[
  '#FF7043', // Warm Coral (餐饮)
  '#EC407A', // Rose Pink (购物)
  '#42A5F5', // Sky Blue (交通)
  '#AB47BC', // Orchid Purple (娱乐)
  '#FFA726', // Amber Orange (零食)
  '#26A69A', // Teal (日用品)
  '#5C6BC0', // Indigo (生活居家)
  '#29B6F6', // Cyan Blue (话费/水电)
  '#66BB6A', // Fresh Green (运动)
  '#EF5350', // Coral Red (医疗)
  '#F06292', // Crimson Pink (发红包/人情)
  '#FB8C00', // Deep Tangerine (捐款/公益)
  '#2E7D32', // Emerald Green (工资/收益)
  '#00ACC1', // Vibrant Cyan (零花钱/储值)
  '#F59E0B', // Warm Gold (奖金/理财)
  '#E53935', // Festive Red (收红包/信用)
  '#7E57C2', // Deep Violet (学习/数码)
  '#8D6E63', // Warm Cocoa (咖啡/宠物)
  '#1677FF', // Brand Blue (支付宝/银行)
  '#07C160', // WeChat Green (微信)
];

/// Pre-parsed [Color] objects corresponding to [catalogColorHexPresets].
const List<Color> catalogColorPresets = <Color>[
  Color(0xFFFF7043),
  Color(0xFFEC407A),
  Color(0xFF42A5F5),
  Color(0xFFAB47BC),
  Color(0xFFFFA726),
  Color(0xFF26A69A),
  Color(0xFF5C6BC0),
  Color(0xFF29B6F6),
  Color(0xFF66BB6A),
  Color(0xFFEF5350),
  Color(0xFFF06292),
  Color(0xFFFB8C00),
  Color(0xFF2E7D32),
  Color(0xFF00ACC1),
  Color(0xFFF59E0B),
  Color(0xFFE53935),
  Color(0xFF7E57C2),
  Color(0xFF8D6E63),
  Color(0xFF1677FF),
  Color(0xFF07C160),
];

/// Safely parses hex color strings in common formats (`'#FF7043'`, `'FF7043'`,
/// `'#FFFF7043'`, `'0xFFFF7043'`, `'0xFF7043'`, `'#F74'`).
///
/// Returns `null` if [raw] is null, blank, or malformed.
Color? tryParseCatalogColor(String? raw) {
  if (raw == null) return null;
  var cleaned = raw.trim();
  if (cleaned.isEmpty) return null;

  if (cleaned.startsWith('#')) {
    cleaned = cleaned.substring(1);
  } else if (cleaned.startsWith('0x') || cleaned.startsWith('0X')) {
    cleaned = cleaned.substring(2);
  }

  if (cleaned.length == 3) {
    final r = cleaned[0];
    final g = cleaned[1];
    final b = cleaned[2];
    cleaned = 'FF$r$r$g$g$b$b';
  } else if (cleaned.length == 6) {
    cleaned = 'FF$cleaned';
  } else if (cleaned.length == 8) {
    // Keep explicit ARGB, except normalize fully transparent 00RRGGBB to opaque.
    if (cleaned.startsWith('00')) {
      cleaned = 'FF${cleaned.substring(2)}';
    }
  } else {
    return null;
  }

  final value = int.tryParse(cleaned, radix: 16);
  if (value == null) return null;
  return Color(value);
}

/// Parses [raw] into a [Color], falling back to [fallback] when invalid.
Color parseCatalogColor(
  String? raw, {
  Color fallback = const Color(0xFF5C6BC0),
}) => tryParseCatalogColor(raw) ?? fallback;

/// Formats [color] as an uppercase 6-digit `#RRGGBB` string (e.g. `'#FF7043'`).
String formatCatalogColorHex(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

// =============================================================================
// Category & Record Type Visuals
// =============================================================================

/// Metadata for a curated semantic category icon in the catalog.
final class CategoryIconSpec {
  const CategoryIconSpec({
    required this.key,
    required this.label,
    required this.icon,
    required this.defaultColorHex,
  });

  final String key;
  final String label;
  final IconData icon;
  final String defaultColorHex;
}

/// Logical group of category icons displayed in [showCategoryVisualPicker].
final class CategoryIconGroup {
  const CategoryIconGroup({required this.title, required this.items});

  final String title;
  final List<CategoryIconSpec> items;
}

/// Curated groups of 55+ semantic Material rounded icons for expense & income
/// categories. All `IconData` values are compile-time constants so Flutter's
/// `--tree-shake-icons` works cleanly in release builds.
const List<CategoryIconGroup> categoryIconGroups = <CategoryIconGroup>[
  CategoryIconGroup(
    title: '餐饮美食',
    items: <CategoryIconSpec>[
      CategoryIconSpec(
        key: 'restaurant',
        label: '餐饮',
        icon: Icons.restaurant_rounded,
        defaultColorHex: '#FF7043',
      ),
      CategoryIconSpec(
        key: 'breakfast',
        label: '早餐烘焙',
        icon: Icons.bakery_dining_rounded,
        defaultColorHex: '#FFA726',
      ),
      CategoryIconSpec(
        key: 'ramen_dining',
        label: '快餐面食',
        icon: Icons.ramen_dining_rounded,
        defaultColorHex: '#FF7043',
      ),
      CategoryIconSpec(
        key: 'coffee',
        label: '咖啡茶饮',
        icon: Icons.coffee_rounded,
        defaultColorHex: '#8D6E63',
      ),
      CategoryIconSpec(
        key: 'icecream',
        label: '零食甜品',
        icon: Icons.icecream_rounded,
        defaultColorHex: '#FFA726',
      ),
      CategoryIconSpec(
        key: 'cake',
        label: '蛋糕下午茶',
        icon: Icons.cake_rounded,
        defaultColorHex: '#F06292',
      ),
      CategoryIconSpec(
        key: 'set_meal',
        label: '买菜生鲜',
        icon: Icons.set_meal_rounded,
        defaultColorHex: '#66BB6A',
      ),
      CategoryIconSpec(
        key: 'local_bar',
        label: '酒水聚餐',
        icon: Icons.local_bar_rounded,
        defaultColorHex: '#AB47BC',
      ),
    ],
  ),
  CategoryIconGroup(
    title: '购物消费',
    items: <CategoryIconSpec>[
      CategoryIconSpec(
        key: 'shopping_bag',
        label: '购物',
        icon: Icons.shopping_bag_rounded,
        defaultColorHex: '#EC407A',
      ),
      CategoryIconSpec(
        key: 'shopping_cart',
        label: '日用品',
        icon: Icons.shopping_cart_rounded,
        defaultColorHex: '#26A69A',
      ),
      CategoryIconSpec(
        key: 'checkroom',
        label: '服饰鞋包',
        icon: Icons.checkroom_rounded,
        defaultColorHex: '#F06292',
      ),
      CategoryIconSpec(
        key: 'spa',
        label: '美容护肤',
        icon: Icons.spa_rounded,
        defaultColorHex: '#EC407A',
      ),
      CategoryIconSpec(
        key: 'devices',
        label: '数码电器',
        icon: Icons.devices_rounded,
        defaultColorHex: '#5C6BC0',
      ),
      CategoryIconSpec(
        key: 'watch',
        label: '配饰腕表',
        icon: Icons.watch_rounded,
        defaultColorHex: '#7E57C2',
      ),
      CategoryIconSpec(
        key: 'storefront',
        label: '超市百货',
        icon: Icons.storefront_rounded,
        defaultColorHex: '#26A69A',
      ),
    ],
  ),
  CategoryIconGroup(
    title: '交通出行',
    items: <CategoryIconSpec>[
      CategoryIconSpec(
        key: 'subway',
        label: '交通地铁',
        icon: Icons.subway_rounded,
        defaultColorHex: '#42A5F5',
      ),
      CategoryIconSpec(
        key: 'directions_bus',
        label: '公交',
        icon: Icons.directions_bus_rounded,
        defaultColorHex: '#29B6F6',
      ),
      CategoryIconSpec(
        key: 'directions_car',
        label: '打车汽车',
        icon: Icons.directions_car_rounded,
        defaultColorHex: '#42A5F5',
      ),
      CategoryIconSpec(
        key: 'local_gas_station',
        label: '加油充电',
        icon: Icons.local_gas_station_rounded,
        defaultColorHex: '#FB8C00',
      ),
      CategoryIconSpec(
        key: 'local_parking',
        label: '停车高速',
        icon: Icons.local_parking_rounded,
        defaultColorHex: '#5C6BC0',
      ),
      CategoryIconSpec(
        key: 'train',
        label: '火车高铁',
        icon: Icons.train_rounded,
        defaultColorHex: '#1677FF',
      ),
      CategoryIconSpec(
        key: 'flight',
        label: '机票航空',
        icon: Icons.flight_rounded,
        defaultColorHex: '#00ACC1',
      ),
      CategoryIconSpec(
        key: 'hotel',
        label: '酒店住宿',
        icon: Icons.hotel_rounded,
        defaultColorHex: '#7E57C2',
      ),
      CategoryIconSpec(
        key: 'pedal_bike',
        label: '单车骑行',
        icon: Icons.pedal_bike_rounded,
        defaultColorHex: '#66BB6A',
      ),
    ],
  ),
  CategoryIconGroup(
    title: '居家生活',
    items: <CategoryIconSpec>[
      CategoryIconSpec(
        key: 'home',
        label: '生活居家',
        icon: Icons.home_rounded,
        defaultColorHex: '#5C6BC0',
      ),
      CategoryIconSpec(
        key: 'water_drop',
        label: '水费燃气',
        icon: Icons.water_drop_rounded,
        defaultColorHex: '#29B6F6',
      ),
      CategoryIconSpec(
        key: 'bolt',
        label: '电费能源',
        icon: Icons.bolt_rounded,
        defaultColorHex: '#F59E0B',
      ),
      CategoryIconSpec(
        key: 'phone_android',
        label: '话费通讯',
        icon: Icons.phone_android_rounded,
        defaultColorHex: '#29B6F6',
      ),
      CategoryIconSpec(
        key: 'wifi',
        label: '宽带网络',
        icon: Icons.wifi_rounded,
        defaultColorHex: '#00ACC1',
      ),
      CategoryIconSpec(
        key: 'chair',
        label: '家具家装',
        icon: Icons.chair_rounded,
        defaultColorHex: '#8D6E63',
      ),
      CategoryIconSpec(
        key: 'cleaning_services',
        label: '家政清洁',
        icon: Icons.cleaning_services_rounded,
        defaultColorHex: '#26A69A',
      ),
      CategoryIconSpec(
        key: 'build',
        label: '维修养护',
        icon: Icons.build_rounded,
        defaultColorHex: '#8D6E63',
      ),
    ],
  ),
  CategoryIconGroup(
    title: '休闲娱乐',
    items: <CategoryIconSpec>[
      CategoryIconSpec(
        key: 'sports_esports',
        label: '娱乐游戏',
        icon: Icons.sports_esports_rounded,
        defaultColorHex: '#AB47BC',
      ),
      CategoryIconSpec(
        key: 'movie',
        label: '电影演出',
        icon: Icons.movie_rounded,
        defaultColorHex: '#7E57C2',
      ),
      CategoryIconSpec(
        key: 'music_note',
        label: '音乐会员',
        icon: Icons.music_note_rounded,
        defaultColorHex: '#EC407A',
      ),
      CategoryIconSpec(
        key: 'luggage',
        label: '旅游度假',
        icon: Icons.luggage_rounded,
        defaultColorHex: '#00ACC1',
      ),
      CategoryIconSpec(
        key: 'camera_alt',
        label: '摄影爱好',
        icon: Icons.camera_alt_rounded,
        defaultColorHex: '#5C6BC0',
      ),
      CategoryIconSpec(
        key: 'palette',
        label: '文化展览',
        icon: Icons.palette_rounded,
        defaultColorHex: '#AB47BC',
      ),
    ],
  ),
  CategoryIconGroup(
    title: '医疗运动',
    items: <CategoryIconSpec>[
      CategoryIconSpec(
        key: 'fitness_center',
        label: '运动健身',
        icon: Icons.fitness_center_rounded,
        defaultColorHex: '#66BB6A',
      ),
      CategoryIconSpec(
        key: 'sports_basketball',
        label: '球类户外',
        icon: Icons.sports_basketball_rounded,
        defaultColorHex: '#FB8C00',
      ),
      CategoryIconSpec(
        key: 'medical_services',
        label: '医疗看病',
        icon: Icons.medical_services_rounded,
        defaultColorHex: '#EF5350',
      ),
      CategoryIconSpec(
        key: 'medication',
        label: '买药保健',
        icon: Icons.medication_rounded,
        defaultColorHex: '#E53935',
      ),
    ],
  ),
  CategoryIconGroup(
    title: '学习与人情家庭',
    items: <CategoryIconSpec>[
      CategoryIconSpec(
        key: 'menu_book',
        label: '书籍阅读',
        icon: Icons.menu_book_rounded,
        defaultColorHex: '#7E57C2',
      ),
      CategoryIconSpec(
        key: 'school',
        label: '学习培训',
        icon: Icons.school_rounded,
        defaultColorHex: '#5C6BC0',
      ),
      CategoryIconSpec(
        key: 'work',
        label: '办公职场',
        icon: Icons.work_rounded,
        defaultColorHex: '#42A5F5',
      ),
      CategoryIconSpec(
        key: 'child_care',
        label: '育儿母婴',
        icon: Icons.child_care_rounded,
        defaultColorHex: '#FFA726',
      ),
      CategoryIconSpec(
        key: 'pets',
        label: '宠物',
        icon: Icons.pets_rounded,
        defaultColorHex: '#8D6E63',
      ),
      CategoryIconSpec(
        key: 'redeem',
        label: '发红包',
        icon: Icons.redeem_rounded,
        defaultColorHex: '#F06292',
      ),
      CategoryIconSpec(
        key: 'card_giftcard',
        label: '红包礼金',
        icon: Icons.card_giftcard_rounded,
        defaultColorHex: '#E53935',
      ),
      CategoryIconSpec(
        key: 'volunteer_activism',
        label: '捐款公益',
        icon: Icons.volunteer_activism_rounded,
        defaultColorHex: '#FB8C00',
      ),
      CategoryIconSpec(
        key: 'favorite',
        label: '亲情关爱',
        icon: Icons.favorite_rounded,
        defaultColorHex: '#EC407A',
      ),
    ],
  ),
  CategoryIconGroup(
    title: '收入与账务',
    items: <CategoryIconSpec>[
      CategoryIconSpec(
        key: 'payments',
        label: '工资薪水',
        icon: Icons.payments_rounded,
        defaultColorHex: '#2E7D32',
      ),
      CategoryIconSpec(
        key: 'savings',
        label: '零花钱储蓄',
        icon: Icons.savings_rounded,
        defaultColorHex: '#00ACC1',
      ),
      CategoryIconSpec(
        key: 'emoji_events',
        label: '奖金补贴',
        icon: Icons.emoji_events_rounded,
        defaultColorHex: '#F59E0B',
      ),
      CategoryIconSpec(
        key: 'trending_up',
        label: '理财投资',
        icon: Icons.trending_up_rounded,
        defaultColorHex: '#07C160',
      ),
      CategoryIconSpec(
        key: 'monetization_on',
        label: '兼职外快',
        icon: Icons.monetization_on_rounded,
        defaultColorHex: '#66BB6A',
      ),
      CategoryIconSpec(
        key: 'account_balance_wallet',
        label: '钱包入账',
        icon: Icons.account_balance_wallet_rounded,
        defaultColorHex: '#1677FF',
      ),
      CategoryIconSpec(
        key: 'swap_horiz',
        label: '流转退换',
        icon: Icons.swap_horiz_rounded,
        defaultColorHex: '#42A5F5',
      ),
      CategoryIconSpec(
        key: 'receipt_long',
        label: '报销票据',
        icon: Icons.receipt_long_rounded,
        defaultColorHex: '#5C6BC0',
      ),
      CategoryIconSpec(
        key: 'category',
        label: '其他分类',
        icon: Icons.category_rounded,
        defaultColorHex: '#7E57C2',
      ),
    ],
  ),
];

/// Flattened list of all curated [CategoryIconSpec] entries.
final List<CategoryIconSpec> categoryIconCatalog = <CategoryIconSpec>[
  for (final group in categoryIconGroups) ...group.items,
];

final Map<String, CategoryIconSpec> _categorySpecByKey =
    <String, CategoryIconSpec>{
      for (final spec in categoryIconCatalog) spec.key: spec,
    };

/// Legacy / camelCase icon aliases mapped to canonical [CategoryIconSpec.key].
const Map<String, String> _categoryIconAliases = <String, String>{
  'menubook': 'menu_book',
  'menu_book': 'menu_book',
  'swaphoriz': 'swap_horiz',
  'swap_horiz': 'swap_horiz',
  'setmeal': 'set_meal',
  // Original v8.6.0 preset category numeric codes (ledger-catalog.md §6):
  '1': 'restaurant',
  '2': 'shopping_bag',
  '3': 'subway',
  '4': 'sports_esports',
  '5': 'icecream',
  '6': 'emoji_events',
  '11': 'shopping_cart',
  '12': 'phone_android',
  '16': 'medical_services',
  '20': 'home',
  '24': 'fitness_center',
  '29': 'redeem',
  '30': 'volunteer_activism',
};

String _normalizeIconKey(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  final direct = _categorySpecByKey[trimmed];
  if (direct != null) return direct.key;
  final lower = trimmed.toLowerCase();
  if (_categorySpecByKey.containsKey(lower)) return lower;
  final alias = _categoryIconAliases[lower];
  if (alias != null) return alias;
  // Convert UpperCamelCase (e.g. "MenuBook") to snake_case ("menu_book").
  final snake = trimmed
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
      .toLowerCase();
  if (_categorySpecByKey.containsKey(snake)) return snake;
  return '';
}

/// Exact name mapping for all 16 seeded categories (`lib/data/db/seed.dart`),
/// guaranteeing every seeded category has a distinct icon and harmonious color
/// out of the box with zero database migration.
const Map<String, ({String iconKey, String colorHex})> _seededCategoryVisuals =
    <String, ({String iconKey, String colorHex})>{
      // 12 preset expense categories:
      '餐饮': (iconKey: 'restaurant', colorHex: '#FF7043'),
      '购物': (iconKey: 'shopping_bag', colorHex: '#EC407A'),
      '交通': (iconKey: 'subway', colorHex: '#42A5F5'),
      '娱乐': (iconKey: 'sports_esports', colorHex: '#AB47BC'),
      '零食': (iconKey: 'icecream', colorHex: '#FFA726'),
      '日用品': (iconKey: 'shopping_cart', colorHex: '#26A69A'),
      '生活居家': (iconKey: 'home', colorHex: '#5C6BC0'),
      '话费': (iconKey: 'phone_android', colorHex: '#29B6F6'),
      '运动': (iconKey: 'fitness_center', colorHex: '#66BB6A'),
      '医疗': (iconKey: 'medical_services', colorHex: '#EF5350'),
      '发红包': (iconKey: 'redeem', colorHex: '#F06292'),
      '捐款': (iconKey: 'volunteer_activism', colorHex: '#FB8C00'),
      // 4 preset income categories:
      '工资': (iconKey: 'payments', colorHex: '#2E7D32'),
      '零花钱': (iconKey: 'savings', colorHex: '#00ACC1'),
      '奖金': (iconKey: 'emoji_events', colorHex: '#F59E0B'),
      '收红包': (iconKey: 'card_giftcard', colorHex: '#E53935'),
    };

({String iconKey, String colorHex})? _matchCategoryByKeyword(
  String rawName,
  int? type,
) {
  final name = rawName.trim();
  if (name.isEmpty) return null;

  final exact = _seededCategoryVisuals[name];
  if (exact != null) return exact;

  // Ordered semantic keyword rules covering common primary & secondary names.
  const keywordRules =
      <({List<String> keywords, String iconKey, String? colorHex})>[
        (
          keywords: ['早餐', '早点', '面包', '烘焙'],
          iconKey: 'breakfast',
          colorHex: '#FFA726',
        ),
        (
          keywords: ['咖啡', '奶茶', '茶饮', '果茶', '饮品'],
          iconKey: 'coffee',
          colorHex: '#8D6E63',
        ),
        (keywords: ['蛋糕', '甜品', '下午茶'], iconKey: 'cake', colorHex: '#F06292'),
        (
          keywords: ['零食', '夜宵', '小吃', '冰淇淋', '雪糕'],
          iconKey: 'icecream',
          colorHex: '#FFA726',
        ),
        (
          keywords: ['买菜', '生鲜', '蔬菜', '水果', '食材'],
          iconKey: 'set_meal',
          colorHex: '#66BB6A',
        ),
        (
          keywords: ['酒水', '酒吧', '啤酒', '红酒'],
          iconKey: 'local_bar',
          colorHex: '#AB47BC',
        ),
        (
          keywords: ['外卖', '快餐', '面食', '粉面', '便当'],
          iconKey: 'ramen_dining',
          colorHex: '#FF7043',
        ),
        (
          keywords: ['餐饮', '午餐', '晚餐', '正餐', '聚餐', '火锅', '烧烤', '食堂', '美食'],
          iconKey: 'restaurant',
          colorHex: '#FF7043',
        ),
        (
          keywords: ['服饰', '衣服', '女装', '男装', '鞋', '穿搭', '衣帽'],
          iconKey: 'checkroom',
          colorHex: '#F06292',
        ),
        (
          keywords: ['美容', '护肤', '化妆', '美妆', '美发', '理发', '美甲'],
          iconKey: 'spa',
          colorHex: '#EC407A',
        ),
        (
          keywords: ['数码', '电子', '电脑', '相机', '家电', '电器', '科技'],
          iconKey: 'devices',
          colorHex: '#5C6BC0',
        ),
        (
          keywords: ['手表', '首饰', '配饰', '眼镜', '腕表'],
          iconKey: 'watch',
          colorHex: '#7E57C2',
        ),
        (
          keywords: ['日用', '纸品', '洗护', '生活用品', '超市', '杂货'],
          iconKey: 'shopping_cart',
          colorHex: '#26A69A',
        ),
        (
          keywords: ['便利店', '百货', '商场'],
          iconKey: 'storefront',
          colorHex: '#26A69A',
        ),
        (
          keywords: ['购物', '网购', '淘宝', '京东', '拼多多'],
          iconKey: 'shopping_bag',
          colorHex: '#EC407A',
        ),
        (
          keywords: ['加油', '油费', '充电桩', '汽车充电'],
          iconKey: 'local_gas_station',
          colorHex: '#FB8C00',
        ),
        (
          keywords: ['停车', '过路费', '高速', 'ETC'],
          iconKey: 'local_parking',
          colorHex: '#5C6BC0',
        ),
        (
          keywords: ['飞机', '机票', '航空', '民航'],
          iconKey: 'flight',
          colorHex: '#00ACC1',
        ),
        (keywords: ['火车', '高铁', '动车'], iconKey: 'train', colorHex: '#1677FF'),
        (
          keywords: ['酒店', '住宿', '民宿', '宾馆'],
          iconKey: 'hotel',
          colorHex: '#7E57C2',
        ),
        (
          keywords: ['公交', '巴士'],
          iconKey: 'directions_bus',
          colorHex: '#29B6F6',
        ),
        (
          keywords: ['单车', '骑行', '电动车'],
          iconKey: 'pedal_bike',
          colorHex: '#66BB6A',
        ),
        (
          keywords: ['打车', '出租', '网约车', '汽车', '自驾', '养车', '车险'],
          iconKey: 'directions_car',
          colorHex: '#42A5F5',
        ),
        (keywords: ['地铁', '交通', '出行'], iconKey: 'subway', colorHex: '#42A5F5'),
        (keywords: ['电费'], iconKey: 'bolt', colorHex: '#F59E0B'),
        (
          keywords: ['水费', '燃气', '水电', '暖气'],
          iconKey: 'water_drop',
          colorHex: '#29B6F6',
        ),
        (
          keywords: ['宽带', '网费', 'WiFi', 'wifi'],
          iconKey: 'wifi',
          colorHex: '#00ACC1',
        ),
        (
          keywords: ['话费', '通讯', '流量', '手机费'],
          iconKey: 'phone_android',
          colorHex: '#29B6F6',
        ),
        (
          keywords: ['家具', '装修', '家装', '软装'],
          iconKey: 'chair',
          colorHex: '#8D6E63',
        ),
        (
          keywords: ['家政', '保洁', '清洁', '干洗', '洗衣'],
          iconKey: 'cleaning_services',
          colorHex: '#26A69A',
        ),
        (keywords: ['维修', '修车', '保养'], iconKey: 'build', colorHex: '#8D6E63'),
        (
          keywords: ['房租', '房贷', '物业', '住房', '居家', '住宿费'],
          iconKey: 'home',
          colorHex: '#5C6BC0',
        ),
        (
          keywords: ['电影', '影院', '演出', '话剧', '演唱会'],
          iconKey: 'movie',
          colorHex: '#7E57C2',
        ),
        (
          keywords: ['音乐', '会员', '订阅', '视频', '播客'],
          iconKey: 'music_note',
          colorHex: '#EC407A',
        ),
        (
          keywords: ['旅行', '旅游', '景点', '门票', '度假'],
          iconKey: 'luggage',
          colorHex: '#00ACC1',
        ),
        (
          keywords: ['摄影', '拍照', '胶片'],
          iconKey: 'camera_alt',
          colorHex: '#5C6BC0',
        ),
        (
          keywords: ['展览', '博物馆', '艺术', '手工', '文创'],
          iconKey: 'palette',
          colorHex: '#AB47BC',
        ),
        (
          keywords: ['娱乐', '游戏', '桌游', 'KTV', '休闲', '剧本杀'],
          iconKey: 'sports_esports',
          colorHex: '#AB47BC',
        ),
        (
          keywords: ['篮球', '足球', '羽毛球', '网球', '乒乓', '球类', '游泳'],
          iconKey: 'sports_basketball',
          colorHex: '#FB8C00',
        ),
        (
          keywords: ['运动', '健身', '瑜伽', '跑步', '户外'],
          iconKey: 'fitness_center',
          colorHex: '#66BB6A',
        ),
        (
          keywords: ['买药', '药品', '保健', '维生素'],
          iconKey: 'medication',
          colorHex: '#E53935',
        ),
        (
          keywords: ['医疗', '看病', '医院', '挂号', '体检', '牙科', '门诊'],
          iconKey: 'medical_services',
          colorHex: '#EF5350',
        ),
        (
          keywords: ['书', '阅读', '教材', '杂志', '电子书'],
          iconKey: 'menu_book',
          colorHex: '#7E57C2',
        ),
        (
          keywords: ['学习', '教育', '培训', '课程', '学费', '考试', '文具'],
          iconKey: 'school',
          colorHex: '#5C6BC0',
        ),
        (
          keywords: ['育儿', '母婴', '宝宝', '孩子', '奶粉', '玩具'],
          iconKey: 'child_care',
          colorHex: '#FFA726',
        ),
        (
          keywords: ['宠物', '猫', '狗', '兽医', '猫粮', '狗粮'],
          iconKey: 'pets',
          colorHex: '#8D6E63',
        ),
        (
          keywords: ['捐款', '公益', '慈善', '爱心'],
          iconKey: 'volunteer_activism',
          colorHex: '#FB8C00',
        ),
        (
          keywords: ['孝敬', '父母', '长辈', '恋爱', '纪念日'],
          iconKey: 'favorite',
          colorHex: '#EC407A',
        ),
        (keywords: ['收红包'], iconKey: 'card_giftcard', colorHex: '#E53935'),
        (keywords: ['发红包'], iconKey: 'redeem', colorHex: '#F06292'),
        (
          keywords: ['红包', '礼金', '人情', '份子', '礼物', '请客'],
          iconKey: 'card_giftcard',
          colorHex: '#F06292',
        ),
        (
          keywords: ['工资', '薪水', '薪资', '底薪'],
          iconKey: 'payments',
          colorHex: '#2E7D32',
        ),
        (
          keywords: ['奖金', '年终奖', '绩效', '补贴', '津贴'],
          iconKey: 'emoji_events',
          colorHex: '#F59E0B',
        ),
        (
          keywords: ['理财', '基金', '股票', '利息', '分红', '收益', '投资'],
          iconKey: 'trending_up',
          colorHex: '#07C160',
        ),
        (
          keywords: ['兼职', '副业', '外快', '稿费', '劳务', '闲鱼', '二手'],
          iconKey: 'monetization_on',
          colorHex: '#66BB6A',
        ),
        (
          keywords: ['零花钱', '生活费', '储蓄', '存款'],
          iconKey: 'savings',
          colorHex: '#00ACC1',
        ),
        (
          keywords: ['办公', '快递', '顺丰', '邮政', '打印'],
          iconKey: 'work',
          colorHex: '#42A5F5',
        ),
        (
          keywords: ['报销', '发票', '税'],
          iconKey: 'receipt_long',
          colorHex: '#5C6BC0',
        ),
        (
          keywords: ['退款', '退货', '转账'],
          iconKey: 'swap_horiz',
          colorHex: '#42A5F5',
        ),
      ];

  for (final rule in keywordRules) {
    for (final kw in rule.keywords) {
      if (name.contains(kw)) {
        final spec = _categorySpecByKey[rule.iconKey]!;
        // Distinguish收红包/收入红包 vs 支出红包 when generic "红包" matched.
        if (kw == '红包' && type == RecordType.income) {
          return (iconKey: 'card_giftcard', colorHex: '#E53935');
        }
        return (
          iconKey: spec.key,
          colorHex: rule.colorHex ?? spec.defaultColorHex,
        );
      }
    }
  }
  return null;
}

Color _deterministicColorForName(String name) {
  if (name.isEmpty) return catalogColorPresets[6];
  var hash = 0;
  for (final codeUnit in name.codeUnits) {
    hash = (hash * 31 + codeUnit) & 0x7FFFFFFF;
  }
  return catalogColorPresets[hash % catalogColorPresets.length];
}

/// Resolved visual representation (icon + harmonious color) for a category.
final class CategoryVisual {
  const CategoryVisual({
    required this.iconKey,
    required this.label,
    required this.icon,
    required this.color,
    required this.colorHex,
  });

  final String iconKey;
  final String label;
  final IconData icon;
  final Color color;
  final String colorHex;
}

/// Resolves a [CategoryVisual] from stored [iconKey] and [colorHex], falling
/// back smartly to [name] (including `父分类 · 子分类` composite labels),
/// optional [parentIconKey], and [type].
CategoryVisual resolveCategoryVisual({
  String? iconKey,
  String? parentIconKey,
  String? colorHex,
  required String name,
  int? type,
}) {
  final normalizedKey = iconKey == null ? '' : _normalizeIconKey(iconKey);
  final normalizedParentKey = parentIconKey == null
      ? ''
      : _normalizeIconKey(parentIconKey);
  final explicitColor = tryParseCatalogColor(colorHex);

  // Clean composite labels such as "餐饮 · 早餐" or "餐饮（报销）".
  final stripped = name.replaceAll(RegExp(r'（[^）]*）|\([^)]*\)'), '').trim();
  final parts = stripped
      .split('·')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final leafName = parts.isEmpty ? stripped : parts.last;
  final parentName = parts.length > 1 ? parts.first : null;

  if (normalizedKey.isNotEmpty) {
    final spec = _categorySpecByKey[normalizedKey]!;
    final matched =
        _matchCategoryByKeyword(leafName, type) ??
        (parentName != null ? _matchCategoryByKeyword(parentName, type) : null);
    final resolvedColor =
        explicitColor ??
        tryParseCatalogColor(matched?.colorHex ?? spec.defaultColorHex)!;
    return CategoryVisual(
      iconKey: spec.key,
      label: spec.label,
      icon: spec.icon,
      color: resolvedColor,
      colorHex: formatCatalogColorHex(resolvedColor),
    );
  }

  final leafMatch = _matchCategoryByKeyword(leafName, type);
  if (leafMatch != null) {
    final spec = _categorySpecByKey[leafMatch.iconKey]!;
    final resolvedColor =
        explicitColor ?? tryParseCatalogColor(leafMatch.colorHex)!;
    return CategoryVisual(
      iconKey: spec.key,
      label: spec.label,
      icon: spec.icon,
      color: resolvedColor,
      colorHex: formatCatalogColorHex(resolvedColor),
    );
  }

  if (normalizedParentKey.isNotEmpty) {
    final spec = _categorySpecByKey[normalizedParentKey]!;
    final resolvedColor =
        explicitColor ?? tryParseCatalogColor(spec.defaultColorHex)!;
    return CategoryVisual(
      iconKey: spec.key,
      label: spec.label,
      icon: spec.icon,
      color: resolvedColor,
      colorHex: formatCatalogColorHex(resolvedColor),
    );
  }

  final parentMatch = parentName != null
      ? _matchCategoryByKeyword(parentName, type)
      : null;
  if (parentMatch != null) {
    final spec = _categorySpecByKey[parentMatch.iconKey]!;
    final resolvedColor =
        explicitColor ?? tryParseCatalogColor(parentMatch.colorHex)!;
    return CategoryVisual(
      iconKey: spec.key,
      label: spec.label,
      icon: spec.icon,
      color: resolvedColor,
      colorHex: formatCatalogColorHex(resolvedColor),
    );
  }

  final fallbackSpec = type == RecordType.income
      ? _categorySpecByKey['account_balance_wallet']!
      : _categorySpecByKey['category']!;
  final fallbackColor =
      explicitColor ??
      (type == RecordType.income
          ? const Color(0xFF2E7D32)
          : _deterministicColorForName(leafName));
  return CategoryVisual(
    iconKey: fallbackSpec.key,
    label: fallbackSpec.label,
    icon: fallbackSpec.icon,
    color: fallbackColor,
    colorHex: formatCatalogColorHex(fallbackColor),
  );
}

/// Soft/vivid circular badge rendering a category's semantic rounded icon.
class CategoryIconAvatar extends StatelessWidget {
  const CategoryIconAvatar({
    super.key,
    this.iconKey,
    this.parentIconKey,
    this.colorHex,
    required this.name,
    this.type,
    this.size = 36,
    this.selected = false,
    this.dimmed = false,
  });

  final String? iconKey;
  final String? parentIconKey;
  final String? colorHex;
  final String name;
  final int? type;
  final double size;
  final bool selected;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final visual = resolveCategoryVisual(
      iconKey: iconKey,
      parentIconKey: parentIconKey,
      colorHex: colorHex,
      name: name,
      type: type,
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = selected
        ? visual.color
        : visual.color.withValues(alpha: isDark ? 0.22 : 0.14);
    final fgColor = selected ? Colors.white : visual.color;

    Widget badge = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
        border: selected
            ? Border.all(
                color: visual.color.withValues(alpha: 0.35),
                width: 1.5,
              )
            : null,
      ),
      alignment: Alignment.center,
      child: Icon(visual.icon, size: size * 0.52, color: fgColor),
    );

    if (dimmed) {
      badge = Opacity(opacity: 0.45, child: badge);
    }
    return badge;
  }
}

/// Resolves a semantic [CategoryVisual] for any [RecordType] (`0..17`),
/// delegating to [resolveCategoryVisual] for categorized bills and providing
/// dedicated semantic icons for transfers, balance adjustments, debts, fees,
/// installments, reimbursements, deposits, and refunds.
CategoryVisual resolveRecordTypeVisual({
  required int recordType,
  String? categoryName,
  String? categoryIcon,
  String? parentCategoryIcon,
  String? categoryColor,
  int? subType,
  bool isRefund = false,
}) {
  final trimmedCat = categoryName?.trim() ?? '';
  final effectiveRefund = isRefund || trimmedCat.startsWith('退款');
  if (effectiveRefund) {
    const refundColor = Color(0xFF00897B);
    return CategoryVisual(
      iconKey: 'refund',
      label: '退款',
      icon: Icons.reply_rounded,
      color: refundColor,
      colorHex: formatCatalogColorHex(refundColor),
    );
  }

  const categoryBearingTypes = <int>{
    RecordType.expense,
    RecordType.income,
    RecordType.reimbursable,
    RecordType.advanceIncome,
    RecordType.advanceExpense,
  };
  final hasCategory =
      (categoryIcon != null && categoryIcon.trim().isNotEmpty) ||
      (parentCategoryIcon != null && parentCategoryIcon.trim().isNotEmpty) ||
      (trimmedCat.isNotEmpty && trimmedCat != '未分类');
  if (categoryBearingTypes.contains(recordType) && hasCategory) {
    final inferredType =
        (recordType == RecordType.income ||
            recordType == RecordType.advanceIncome)
        ? RecordType.income
        : RecordType.expense;
    return resolveCategoryVisual(
      iconKey: categoryIcon,
      parentIconKey: parentCategoryIcon,
      colorHex: categoryColor,
      name: trimmedCat,
      type: inferredType,
    );
  }

  final (
    String key,
    String label,
    IconData icon,
    Color color,
  ) = switch (recordType) {
    RecordType.income => (
      'payments',
      '收入',
      Icons.payments_rounded,
      const Color(0xFF2E7D32),
    ),
    RecordType.transfer => (
      'transfer',
      '转账',
      Icons.swap_horiz_rounded,
      const Color(0xFF1677FF),
    ),
    RecordType.reimbursable => (
      'reimbursable',
      '报销',
      Icons.receipt_long_rounded,
      const Color(0xFF5C6BC0),
    ),
    RecordType.balanceAdjust => (
      'balance_adjust',
      '余额变更',
      Icons.tune_rounded,
      const Color(0xFF78909C),
    ),
    RecordType.borrowIn => (
      'borrow_in',
      '借入',
      Icons.call_received_rounded,
      const Color(0xFFF4511E),
    ),
    RecordType.lendOut => (
      'lend_out',
      '借出',
      Icons.call_made_rounded,
      const Color(0xFF00897B),
    ),
    RecordType.repay => (
      'repay',
      '还款',
      Icons.credit_score_rounded,
      const Color(0xFF5C6BC0),
    ),
    RecordType.collect => (
      'collect',
      '收款',
      Icons.savings_rounded,
      const Color(0xFF2E7D32),
    ),
    RecordType.advanceIncome => (
      'advance_income',
      '预收',
      Icons.schedule_rounded,
      const Color(0xFF2E7D32),
    ),
    RecordType.debtInterest => (
      'debt_interest',
      '借贷利息',
      Icons.percent_rounded,
      subType == RecordDirection.income
          ? const Color(0xFF2E7D32)
          : const Color(0xFFF59E0B),
    ),
    RecordType.reimburseDiff => (
      'reimburse_diff',
      '报销差额',
      Icons.compare_arrows_rounded,
      const Color(0xFF8E24AA),
    ),
    RecordType.fee => (
      'fee',
      '手续费',
      Icons.percent_rounded,
      const Color(0xFF78909C),
    ),
    RecordType.billInstallment => (
      'bill_installment',
      '账单分期',
      Icons.date_range_rounded,
      const Color(0xFF7E57C2),
    ),
    RecordType.installmentPrincipal => (
      'installment_principal',
      '分期本金',
      Icons.calendar_month_rounded,
      const Color(0xFF7E57C2),
    ),
    RecordType.reimburseReceipt => (
      'reimburse_receipt',
      '报销收款',
      Icons.task_alt_rounded,
      const Color(0xFF2E7D32),
    ),
    RecordType.advanceExpense => (
      'advance_expense',
      '预支',
      Icons.pending_actions_rounded,
      const Color(0xFFFB8C00),
    ),
    RecordType.depositInterest => (
      'deposit_interest',
      '定存收益',
      Icons.trending_up_rounded,
      const Color(0xFF2E7D32),
    ),
    _ => ('expense', '支出', Icons.receipt_rounded, const Color(0xFFFF7043)),
  };

  return CategoryVisual(
    iconKey: key,
    label: label,
    icon: icon,
    color: color,
    colorHex: formatCatalogColorHex(color),
  );
}

/// Circular badge avatar for any bill row, handling both categorized bills and
/// uncategorized special record types (转账, 平账, 还款, 借入, 借出, 退款, 报销, 分期, 定存).
class RecordTypeIconAvatar extends StatelessWidget {
  const RecordTypeIconAvatar({
    super.key,
    required this.recordType,
    this.categoryName,
    this.categoryIcon,
    this.parentCategoryIcon,
    this.categoryColor,
    this.subType,
    this.isRefund = false,
    this.size = 38,
  });

  final int recordType;
  final String? categoryName;
  final String? categoryIcon;
  final String? parentCategoryIcon;
  final String? categoryColor;
  final int? subType;
  final bool isRefund;
  final double size;

  @override
  Widget build(BuildContext context) {
    final visual = resolveRecordTypeVisual(
      recordType: recordType,
      categoryName: categoryName,
      categoryIcon: categoryIcon,
      parentCategoryIcon: parentCategoryIcon,
      categoryColor: categoryColor,
      subType: subType,
      isRefund: isRefund,
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: visual.color.withValues(alpha: isDark ? 0.22 : 0.14),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(visual.icon, size: size * 0.52, color: visual.color),
    );
  }
}

/// Opens an interactive modal bottom sheet for choosing a category's icon and
/// color swatch, with a live preview header.
Future<({String icon, String colorHex})?> showCategoryVisualPicker(
  BuildContext context, {
  String? initialIcon,
  String? initialColor,
  required String previewName,
  int? categoryType,
}) {
  final initialVisual = resolveCategoryVisual(
    iconKey: initialIcon,
    colorHex: initialColor,
    name: previewName,
    type: categoryType,
  );

  return showModalBottomSheet<({String icon, String colorHex})>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetCtx) => _CategoryVisualPickerSheet(
      initialIconKey: initialVisual.iconKey,
      initialColorHex: initialVisual.colorHex,
      hasExplicitInitialColor:
          initialColor != null && initialColor.trim().isNotEmpty,
      previewName: previewName.trim().isEmpty ? '分类预览' : previewName.trim(),
      categoryType: categoryType,
    ),
  );
}

class _CategoryVisualPickerSheet extends StatefulWidget {
  const _CategoryVisualPickerSheet({
    required this.initialIconKey,
    required this.initialColorHex,
    required this.hasExplicitInitialColor,
    required this.previewName,
    this.categoryType,
  });

  final String initialIconKey;
  final String initialColorHex;
  final bool hasExplicitInitialColor;
  final String previewName;
  final int? categoryType;

  @override
  State<_CategoryVisualPickerSheet> createState() =>
      _CategoryVisualPickerSheetState();
}

class _CategoryVisualPickerSheetState
    extends State<_CategoryVisualPickerSheet> {
  late String _iconKey;
  late String _colorHex;
  late bool _userLockedColor;

  @override
  void initState() {
    super.initState();
    _iconKey = widget.initialIconKey;
    _colorHex = widget.initialColorHex;
    _userLockedColor = widget.hasExplicitInitialColor;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                CategoryIconAvatar(
                  iconKey: _iconKey,
                  colorHex: _colorHex,
                  name: widget.previewName,
                  type: widget.categoryType,
                  size: 42,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.previewName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '选择分类图标与配色',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  key: const Key('visual-picker-confirm'),
                  onPressed: () => Navigator.pop(sheetCtxOrContext(context), (
                    icon: _iconKey,
                    colorHex: _colorHex,
                  )),
                  child: const Text('确定'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                for (
                  var index = 0;
                  index < catalogColorHexPresets.length;
                  index++
                )
                  Builder(
                    builder: (context) {
                      final hex = catalogColorHexPresets[index];
                      final color = catalogColorPresets[index];
                      final selected =
                          _colorHex.toUpperCase() == hex.toUpperCase();
                      return InkWell(
                        key: Key('visual-color-$hex'),
                        customBorder: const CircleBorder(),
                        onTap: () => setState(() {
                          _colorHex = hex;
                          _userLockedColor = true;
                        }),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: selected
                                ? Border.all(
                                    color: theme.colorScheme.onSurface,
                                    width: 2.2,
                                  )
                                : null,
                          ),
                          child: selected
                              ? const Icon(
                                  Icons.check,
                                  size: 16,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                for (final group in categoryIconGroups) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8, top: 4),
                    child: Text(
                      group.title,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 76,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 0.92,
                        ),
                    itemCount: group.items.length,
                    itemBuilder: (context, idx) {
                      final spec = group.items[idx];
                      final isSelected = _iconKey == spec.key;
                      return InkWell(
                        key: Key('visual-icon-${spec.key}'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setState(() {
                          _iconKey = spec.key;
                          if (!_userLockedColor) {
                            _colorHex = spec.defaultColorHex;
                          }
                        }),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CategoryIconAvatar(
                              iconKey: spec.key,
                              colorHex: isSelected
                                  ? _colorHex
                                  : spec.defaultColorHex,
                              name: spec.label,
                              size: 38,
                              selected: isSelected,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              spec.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  BuildContext sheetCtxOrContext(BuildContext ctx) => ctx;
}

// =============================================================================
// Asset Account Visuals
// =============================================================================

/// Metadata for a curated asset account icon in the catalog.
final class AssetIconSpec {
  const AssetIconSpec({
    required this.key,
    required this.label,
    required this.icon,
    required this.defaultColorHex,
    required this.group,
  });

  final String key;
  final String label;
  final IconData icon;
  final String defaultColorHex;

  /// `'normal'`, `'credit'`, or `'debt'`.
  final String group;
}

/// Curated account icons & brand-harmonious colors covering 资金账户, 信用账户, and 借贷账户.
const List<AssetIconSpec> assetIconCatalog = <AssetIconSpec>[
  // 资金账户 (normal / invest)
  AssetIconSpec(
    key: 'cash',
    label: '现金',
    icon: Icons.payments_rounded,
    defaultColorHex: '#43A047',
    group: 'normal',
  ),
  AssetIconSpec(
    key: 'bank_card',
    label: '银行卡',
    icon: Icons.account_balance_rounded,
    defaultColorHex: '#1565C0',
    group: 'normal',
  ),
  AssetIconSpec(
    key: 'wechat_pay',
    label: '微信钱包',
    icon: Icons.chat_bubble_rounded,
    defaultColorHex: '#07C160',
    group: 'normal',
  ),
  AssetIconSpec(
    key: 'alipay',
    label: '支付宝',
    icon: Icons.account_balance_wallet_rounded,
    defaultColorHex: '#1677FF',
    group: 'normal',
  ),
  AssetIconSpec(
    key: 'wealth',
    label: '余额宝/理财',
    icon: Icons.monetization_on_rounded,
    defaultColorHex: '#F59E0B',
    group: 'normal',
  ),
  AssetIconSpec(
    key: 'stored_card',
    label: '充值/公交卡',
    icon: Icons.contactless_rounded,
    defaultColorHex: '#00ACC1',
    group: 'normal',
  ),
  AssetIconSpec(
    key: 'provident',
    label: '公积金/医保',
    icon: Icons.health_and_safety_rounded,
    defaultColorHex: '#00897B',
    group: 'normal',
  ),
  AssetIconSpec(
    key: 'stock',
    label: '股票/基金',
    icon: Icons.candlestick_chart_rounded,
    defaultColorHex: '#7E57C2',
    group: 'normal',
  ),
  AssetIconSpec(
    key: 'currency_exchange',
    label: '数字人民币/外币',
    icon: Icons.currency_exchange_rounded,
    defaultColorHex: '#3949AB',
    group: 'normal',
  ),
  AssetIconSpec(
    key: 'savings',
    label: '存折/金库',
    icon: Icons.savings_rounded,
    defaultColorHex: '#26A69A',
    group: 'normal',
  ),
  // 信用账户 (credit)
  AssetIconSpec(
    key: 'credit_card',
    label: '信用卡',
    icon: Icons.credit_card_rounded,
    defaultColorHex: '#E53935',
    group: 'credit',
  ),
  AssetIconSpec(
    key: 'huabei',
    label: '花呗',
    icon: Icons.auto_awesome_rounded,
    defaultColorHex: '#29B6F6',
    group: 'credit',
  ),
  AssetIconSpec(
    key: 'baitiao',
    label: '白条',
    icon: Icons.receipt_long_rounded,
    defaultColorHex: '#EF5350',
    group: 'credit',
  ),
  AssetIconSpec(
    key: 'credit_line',
    label: '月付/消费贷',
    icon: Icons.event_repeat_rounded,
    defaultColorHex: '#8E24AA',
    group: 'credit',
  ),
  // 借贷账户 (borrow / lend)
  AssetIconSpec(
    key: 'borrow',
    label: '借入/欠款',
    icon: Icons.call_received_rounded,
    defaultColorHex: '#F4511E',
    group: 'debt',
  ),
  AssetIconSpec(
    key: 'lend',
    label: '借出/应收',
    icon: Icons.call_made_rounded,
    defaultColorHex: '#00897B',
    group: 'debt',
  ),
];

final Map<String, AssetIconSpec> _assetSpecByKey = <String, AssetIconSpec>{
  for (final spec in assetIconCatalog) spec.key: spec,
};

AssetIconSpec? _matchAssetByKeyword(
  String rawName,
  int assetType,
  int? subType,
) {
  final name = rawName.trim();
  if (name.isEmpty) return null;
  final lower = name.toLowerCase();

  // Debt accounts match direction first unless explicit keyword overrides.
  if (assetType == AssetType.debt) {
    if (subType == AssetType.debtLend ||
        name.contains('借出') ||
        name.contains('借给') ||
        name.contains('应收')) {
      return _assetSpecByKey['lend'];
    }
    if (subType == AssetType.debtBorrow ||
        name.contains('借入') ||
        name.contains('借款') ||
        name.contains('欠')) {
      return _assetSpecByKey['borrow'];
    }
  }

  // Credit-brand keywords checked BEFORE generic Alipay/JD/bank keywords so
  // "支付宝花呗" -> huabei and "京东白条" -> baitiao.
  if (name.contains('花呗') || lower.contains('huabei')) {
    return _assetSpecByKey['huabei'];
  }
  if (name.contains('白条') || lower.contains('baitiao')) {
    return _assetSpecByKey['baitiao'];
  }
  if (name.contains('月付') ||
      name.contains('分期') ||
      name.contains('消费贷') ||
      name.contains('借呗') ||
      name.contains('微粒贷') ||
      name.contains('金条')) {
    return _assetSpecByKey['credit_line'];
  }
  if (name.contains('微信') || name.contains('零钱通') || lower.contains('wechat')) {
    return _assetSpecByKey['wechat_pay'];
  }
  if (name.contains('余额宝') || name.contains('朝朝宝') || name.contains('理财')) {
    return _assetSpecByKey['wealth'];
  }
  if (name.contains('支付宝') || lower.contains('alipay')) {
    return _assetSpecByKey['alipay'];
  }
  if (name.contains('股票') ||
      name.contains('基金') ||
      name.contains('证券') ||
      lower.contains('etf')) {
    return _assetSpecByKey['stock'];
  }
  if (name.contains('公积金') || name.contains('社保') || name.contains('医保')) {
    return _assetSpecByKey['provident'];
  }
  if (name.contains('公交') ||
      name.contains('交通卡') ||
      name.contains('地铁卡') ||
      name.contains('校园') ||
      name.contains('饭卡') ||
      name.contains('餐卡') ||
      name.contains('会员') ||
      name.contains('充值') ||
      name.contains('购物卡')) {
    return _assetSpecByKey['stored_card'];
  }
  if (name.contains('数字人民币') ||
      lower.contains('e-cny') ||
      name.contains('外币') ||
      name.contains('美元') ||
      name.contains('港币') ||
      name.contains('日元') ||
      name.contains('欧元')) {
    return _assetSpecByKey['currency_exchange'];
  }
  if (name.contains('存折') || name.contains('金库') || name.contains('定期')) {
    return _assetSpecByKey['savings'];
  }
  if (name.contains('现金') || name.contains('备用金') || name == '钱包') {
    return _assetSpecByKey['cash'];
  }
  if (name.contains('信用卡') || name.contains('贷记卡')) {
    return _assetSpecByKey['credit_card'];
  }
  const bankKeywords = <String>[
    '招行',
    '招商',
    '工行',
    '工商',
    '建行',
    '建设',
    '农行',
    '农业',
    '中行',
    '中国银行',
    '交行',
    '交通银行',
    '邮储',
    '邮政',
    '民生',
    '兴业',
    '浦发',
    '中信',
    '光大',
    '平安',
    '广发',
    '华夏',
    '银行',
    '储蓄',
    '借记卡',
    '工资卡',
  ];
  for (final kw in bankKeywords) {
    if (name.contains(kw)) {
      return assetType == AssetType.credit
          ? _assetSpecByKey['credit_card']
          : _assetSpecByKey['bank_card'];
    }
  }
  return null;
}

AssetIconSpec _fallbackAssetSpecForType(int assetType, int? subType) {
  if (assetType == AssetType.credit) {
    return _assetSpecByKey['credit_card']!;
  }
  if (assetType == AssetType.debt) {
    return subType == AssetType.debtLend
        ? _assetSpecByKey['lend']!
        : _assetSpecByKey['borrow']!;
  }
  return _assetSpecByKey['bank_card']!;
}

/// Resolved visual representation (icon + brand-harmonious color) for an asset account.
final class AssetVisual {
  const AssetVisual({
    required this.iconKey,
    required this.label,
    required this.icon,
    required this.color,
    required this.colorHex,
  });

  final String iconKey;
  final String label;
  final IconData icon;
  final Color color;
  final String colorHex;
}

/// Resolves an [AssetVisual] in priority order:
/// 1. Explicit [iconKey] in [assetIconCatalog]
/// 2. Smart keyword match on [name] (`微信`, `支付宝`, `花呗`, `白条`, `招行信用卡`, `现金`, etc.)
/// 3. Fallback by [assetType] (and optional [subType] for borrow/lend debt accounts).
AssetVisual resolveAssetVisual({
  String? iconKey,
  String? colorHex,
  required String name,
  required int assetType,
  int? subType,
}) {
  final trimmedKey = iconKey?.trim() ?? '';
  final explicitSpec = trimmedKey.isEmpty ? null : _assetSpecByKey[trimmedKey];
  final spec =
      explicitSpec ??
      _matchAssetByKeyword(name, assetType, subType) ??
      _fallbackAssetSpecForType(assetType, subType);

  final resolvedColor =
      tryParseCatalogColor(colorHex) ??
      tryParseCatalogColor(spec.defaultColorHex)!;
  return AssetVisual(
    iconKey: spec.key,
    label: spec.label,
    icon: spec.icon,
    color: resolvedColor,
    colorHex: formatCatalogColorHex(resolvedColor),
  );
}

/// Soft/vivid circular badge rendering an account's semantic rounded icon.
class AssetIconAvatar extends StatelessWidget {
  const AssetIconAvatar({
    super.key,
    this.iconKey,
    this.colorHex,
    required this.name,
    required this.assetType,
    this.subType,
    this.size = 38,
    this.selected = false,
  });

  final String? iconKey;
  final String? colorHex;
  final String name;
  final int assetType;
  final int? subType;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final visual = resolveAssetVisual(
      iconKey: iconKey,
      colorHex: colorHex,
      name: name,
      assetType: assetType,
      subType: subType,
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = selected
        ? visual.color
        : visual.color.withValues(alpha: isDark ? 0.22 : 0.14);
    final fgColor = selected ? Colors.white : visual.color;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
        border: selected
            ? Border.all(
                color: visual.color.withValues(alpha: 0.35),
                width: 1.5,
              )
            : null,
      ),
      alignment: Alignment.center,
      child: Icon(visual.icon, size: size * 0.52, color: fgColor),
    );
  }
}

/// Opens an interactive modal bottom sheet for choosing an asset account's
/// icon and color swatch, prioritizing icons matching [assetType].
Future<({String icon, String colorHex})?> showAssetVisualPicker(
  BuildContext context, {
  String? initialIcon,
  String? initialColor,
  required int assetType,
  int? subType,
  required String previewName,
}) {
  final initialVisual = resolveAssetVisual(
    iconKey: initialIcon,
    colorHex: initialColor,
    name: previewName,
    assetType: assetType,
    subType: subType,
  );

  return showModalBottomSheet<({String icon, String colorHex})>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetCtx) => _AssetVisualPickerSheet(
      initialIconKey: initialVisual.iconKey,
      initialColorHex: initialVisual.colorHex,
      hasExplicitInitialColor:
          initialColor != null && initialColor.trim().isNotEmpty,
      assetType: assetType,
      subType: subType,
      previewName: previewName.trim().isEmpty
          ? (assetType == AssetType.credit ? '信用账户预览' : '账户预览')
          : previewName.trim(),
    ),
  );
}

class _AssetVisualPickerSheet extends StatefulWidget {
  const _AssetVisualPickerSheet({
    required this.initialIconKey,
    required this.initialColorHex,
    required this.hasExplicitInitialColor,
    required this.assetType,
    this.subType,
    required this.previewName,
  });

  final String initialIconKey;
  final String initialColorHex;
  final bool hasExplicitInitialColor;
  final int assetType;
  final int? subType;
  final String previewName;

  @override
  State<_AssetVisualPickerSheet> createState() =>
      _AssetVisualPickerSheetState();
}

class _AssetVisualPickerSheetState extends State<_AssetVisualPickerSheet> {
  late String _iconKey;
  late String _colorHex;
  late bool _userLockedColor;

  @override
  void initState() {
    super.initState();
    _iconKey = widget.initialIconKey;
    _colorHex = widget.initialColorHex;
    _userLockedColor = widget.hasExplicitInitialColor;
  }

  List<({String title, List<AssetIconSpec> items})> _orderedSections() {
    final normalItems = assetIconCatalog
        .where((s) => s.group == 'normal')
        .toList();
    final creditItems = assetIconCatalog
        .where((s) => s.group == 'credit')
        .toList();
    final debtItems = assetIconCatalog.where((s) => s.group == 'debt').toList();

    if (widget.assetType == AssetType.credit) {
      return [
        (title: '信用账户', items: creditItems),
        (title: '资金账户', items: normalItems),
        (title: '借贷账户', items: debtItems),
      ];
    }
    if (widget.assetType == AssetType.debt) {
      return [
        (title: '借贷账户', items: debtItems),
        (title: '资金账户', items: normalItems),
        (title: '信用账户', items: creditItems),
      ];
    }
    return [
      (title: '资金账户', items: normalItems),
      (title: '信用账户', items: creditItems),
      (title: '借贷账户', items: debtItems),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    final sections = _orderedSections();

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                AssetIconAvatar(
                  iconKey: _iconKey,
                  colorHex: _colorHex,
                  name: widget.previewName,
                  assetType: widget.assetType,
                  subType: widget.subType,
                  size: 42,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.previewName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '选择账户图标与配色',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  key: const Key('visual-picker-confirm'),
                  onPressed: () => Navigator.pop(context, (
                    icon: _iconKey,
                    colorHex: _colorHex,
                  )),
                  child: const Text('确定'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                for (
                  var index = 0;
                  index < catalogColorHexPresets.length;
                  index++
                )
                  Builder(
                    builder: (context) {
                      final hex = catalogColorHexPresets[index];
                      final color = catalogColorPresets[index];
                      final selected =
                          _colorHex.toUpperCase() == hex.toUpperCase();
                      return InkWell(
                        key: Key('visual-color-$hex'),
                        customBorder: const CircleBorder(),
                        onTap: () => setState(() {
                          _colorHex = hex;
                          _userLockedColor = true;
                        }),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: selected
                                ? Border.all(
                                    color: theme.colorScheme.onSurface,
                                    width: 2.2,
                                  )
                                : null,
                          ),
                          child: selected
                              ? const Icon(
                                  Icons.check,
                                  size: 16,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                for (final section in sections) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8, top: 4),
                    child: Text(
                      section.title,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 84,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 0.94,
                        ),
                    itemCount: section.items.length,
                    itemBuilder: (context, idx) {
                      final spec = section.items[idx];
                      final isSelected = _iconKey == spec.key;
                      return InkWell(
                        key: Key('visual-icon-${spec.key}'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setState(() {
                          _iconKey = spec.key;
                          if (!_userLockedColor) {
                            _colorHex = spec.defaultColorHex;
                          }
                        }),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AssetIconAvatar(
                              iconKey: spec.key,
                              colorHex: isSelected
                                  ? _colorHex
                                  : spec.defaultColorHex,
                              name: spec.label,
                              assetType: widget.assetType,
                              subType: widget.subType,
                              size: 38,
                              selected: isSelected,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              spec.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
