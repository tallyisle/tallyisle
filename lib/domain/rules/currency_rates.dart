import '../../core/failure.dart';
import '../../core/money.dart';
import '../ledger/record_extra.dart';
import 'asset_overview.dart';

/// App base (anchor) currency. Rates in the `currency` table are relative to it.
const baseCurrency = 'CNY';

/// Metadata for a standard ISO 4217 world currency offered when adding foreign
/// currencies.
final class WorldCurrencySpec {
  const WorldCurrencySpec({
    required this.code,
    required this.name,
    required this.symbol,
    this.keywords = '',
    this.popular = false,
  });

  /// 3-letter uppercase ISO 4217 currency code (e.g. `'TRY'`, `'USD'`).
  final String code;

  /// Localized Chinese display name (e.g. `'土耳其里拉'`, `'美元'`).
  final String name;

  /// Display symbol or short sign (e.g. `'₺'`, `'$'`).
  final String symbol;

  /// Space-separated search keywords (country/region names in Chinese/English,
  /// currency unit aliases).
  final String keywords;

  /// Whether this currency is surfaced in the default popular quick-pick list.
  final bool popular;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorldCurrencySpec &&
          other.code == code &&
          other.name == name &&
          other.symbol == symbol &&
          other.keywords == keywords &&
          other.popular == popular;

  @override
  int get hashCode => Object.hash(code, name, symbol, keywords, popular);

  @override
  String toString() => 'WorldCurrencySpec($code, $name, $symbol)';
}

/// Global ISO 4217 fiat currency catalog (150+ foreign currencies across
/// Asia-Pacific, Middle East & Central Asia, Europe, Americas, and Africa).
/// Excludes [baseCurrency] (`CNY`), which is always pinned as anchor currency.
const worldCurrencies = <WorldCurrencySpec>[
  // --- Popular Travel, Study & Cross-Border Trade Currencies ---
  WorldCurrencySpec(
    code: 'USD',
    name: '美元',
    symbol: r'$',
    keywords: '美国 美金 刀 united states dollar usa',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'EUR',
    name: '欧元',
    symbol: '€',
    keywords: '欧盟 欧洲 德国 法国 意大利 西班牙 荷兰 葡萄牙 希腊 奥地利 芬兰 爱尔兰 比利时 euro europe',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'JPY',
    name: '日元',
    symbol: '¥',
    keywords: '日本 日币 日圆 东京 大阪 japan japanese yen',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'HKD',
    name: '港币',
    symbol: r'HK$',
    keywords: '香港 港元 中国香港 hong kong dollar',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'GBP',
    name: '英镑',
    symbol: '£',
    keywords: '英国 伦敦 大不列颠 英格兰 苏格兰 united kingdom british pound sterling uk',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'THB',
    name: '泰铢',
    symbol: '฿',
    keywords: '泰国 曼谷 普吉 清迈 铢 thailand thai baht',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'KRW',
    name: '韩元',
    symbol: '₩',
    keywords: '韩国 首尔 济州 韩币 south korea korean won',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'TRY',
    name: '土耳其里拉',
    symbol: '₺',
    keywords: '土耳其 里拉 新里拉 伊斯坦布尔 turkey turkish lira',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'SGD',
    name: '新加坡元',
    symbol: r'S$',
    keywords: '新加坡 新币 坡币 singapore dollar',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'TWD',
    name: '新台币',
    symbol: r'NT$',
    keywords: '台湾 台币 台北 中国台湾 taiwan new dollar',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'MOP',
    name: '澳门元',
    symbol: r'MOP$',
    keywords: '澳门 葡币 中国澳门 macau macao pataca',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'MYR',
    name: '马来西亚林吉特',
    symbol: 'RM',
    keywords: '马来西亚 吉隆坡 马币 令吉 林吉特 malaysia ringgit',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'AUD',
    name: '澳元',
    symbol: r'A$',
    keywords: '澳大利亚 澳洲 悉尼 墨尔本 澳币 australia australian dollar',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'CAD',
    name: '加元',
    symbol: r'C$',
    keywords: '加拿大 温哥华 多伦多 加币 canada canadian dollar',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'CHF',
    name: '瑞士法郎',
    symbol: 'CHF',
    keywords: '瑞士 瑞郎 苏黎世 日内瓦 列支敦士登 switzerland swiss franc',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'NZD',
    name: '新西兰元',
    symbol: r'NZ$',
    keywords: '新西兰 奥克兰 纽币 纽元 new zealand dollar',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'AED',
    name: '阿联酋迪拉姆',
    symbol: 'AED',
    keywords: '阿联酋 迪拜 阿布扎比 迪拉姆 uae united arab emirates dubai dirham',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'RUB',
    name: '俄罗斯卢布',
    symbol: '₽',
    keywords: '俄罗斯 莫斯科 圣彼得堡 卢布 russia russian ruble',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'VND',
    name: '越南盾',
    symbol: '₫',
    keywords: '越南 河内 胡志明 岘港 盾 vietnam vietnamese dong',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'PHP',
    name: '菲律宾比索',
    symbol: '₱',
    keywords: '菲律宾 马尼拉 长滩岛 比索 philippines philippine peso',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'IDR',
    name: '印尼盾',
    symbol: 'Rp',
    keywords: '印度尼西亚 印尼 雅加达 巴厘岛 卢比 indonesia rupiah',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'INR',
    name: '印度卢比',
    symbol: '₹',
    keywords: '印度 新德里 孟买 卢比 india indian rupee',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'SAR',
    name: '沙特里亚尔',
    symbol: 'SAR',
    keywords: '沙特 沙特阿拉伯 利雅得 里亚尔 saudi arabia riyal',
    popular: true,
  ),
  WorldCurrencySpec(
    code: 'EGP',
    name: '埃及镑',
    symbol: 'E£',
    keywords: '埃及 开罗 卢克索 埃镑 egypt egyptian pound',
    popular: true,
  ),

  // --- Asia-Pacific ---
  WorldCurrencySpec(
    code: 'AFN',
    name: '阿富汗尼',
    symbol: '؋',
    keywords: '阿富汗 喀布尔 afghanistan afghani',
  ),
  WorldCurrencySpec(
    code: 'BDT',
    name: '孟加拉塔卡',
    symbol: '৳',
    keywords: '孟加拉 孟加拉国 达卡 塔卡 bangladesh taka',
  ),
  WorldCurrencySpec(
    code: 'BND',
    name: '文莱元',
    symbol: r'B$',
    keywords: '文莱 达鲁萨兰 brunei dollar',
  ),
  WorldCurrencySpec(
    code: 'BTN',
    name: '不丹努尔特鲁姆',
    symbol: 'Nu.',
    keywords: '不丹 廷布 努扎姆 bhutan ngultrum',
  ),
  WorldCurrencySpec(
    code: 'FJD',
    name: '斐济元',
    symbol: r'FJ$',
    keywords: '斐济 苏瓦 fiji fijian dollar',
  ),
  WorldCurrencySpec(
    code: 'KHR',
    name: '柬埔寨瑞尔',
    symbol: '៛',
    keywords: '柬埔寨 金边 暹粒 吴哥窟 瑞尔 cambodia riel',
  ),
  WorldCurrencySpec(
    code: 'KPW',
    name: '朝鲜圆',
    symbol: '₩',
    keywords: '朝鲜 平壤 朝币 north korea won',
  ),
  WorldCurrencySpec(
    code: 'LAK',
    name: '老挝基普',
    symbol: '₭',
    keywords: '老挝 万象 琅勃拉邦 基普 laos lao kip',
  ),
  WorldCurrencySpec(
    code: 'LKR',
    name: '斯里兰卡卢比',
    symbol: 'Rs',
    keywords: '斯里兰卡 科伦坡 卢比 sri lanka rupee',
  ),
  WorldCurrencySpec(
    code: 'MMK',
    name: '缅甸元',
    symbol: 'K',
    keywords: '缅甸 仰光 曼德勒 缅元 缅币 myanmar burma kyat',
  ),
  WorldCurrencySpec(
    code: 'MNT',
    name: '蒙古图格里克',
    symbol: '₮',
    keywords: '蒙古 蒙古国 乌兰巴托 图格里克 mongolia tugrik',
  ),
  WorldCurrencySpec(
    code: 'MVR',
    name: '马尔代夫拉菲亚',
    symbol: 'Rf',
    keywords: '马尔代夫 马累 拉菲亚 maldives rufiyaa',
  ),
  WorldCurrencySpec(
    code: 'NPR',
    name: '尼泊尔卢比',
    symbol: 'Rs',
    keywords: '尼泊尔 加德满都 卢比 nepal nepalese rupee',
  ),
  WorldCurrencySpec(
    code: 'PGK',
    name: '巴布亚新几内亚基那',
    symbol: 'K',
    keywords: '巴布亚新几内亚 莫尔兹比港 基那 papua new guinea kina',
  ),
  WorldCurrencySpec(
    code: 'PKR',
    name: '巴基斯坦卢比',
    symbol: '₨',
    keywords: '巴基斯坦 伊斯兰堡 卡拉奇 拉合尔 卢比 pakistan rupee',
  ),
  WorldCurrencySpec(
    code: 'SBD',
    name: '所罗门群岛元',
    symbol: r'SI$',
    keywords: '所罗门群岛 solomon islands dollar',
  ),
  WorldCurrencySpec(
    code: 'SCR',
    name: '塞舌尔卢比',
    symbol: '₨',
    keywords: '塞舌尔 维多利亚 卢比 seychelles rupee',
  ),
  WorldCurrencySpec(
    code: 'TOP',
    name: '汤加潘加',
    symbol: r'T$',
    keywords: '汤加 努库阿洛法 潘加 tonga paanga',
  ),
  WorldCurrencySpec(
    code: 'VUV',
    name: '瓦努阿图瓦图',
    symbol: 'VT',
    keywords: '瓦努阿图 维拉港 瓦图 vanuatu vatu',
  ),
  WorldCurrencySpec(
    code: 'WST',
    name: '萨摩亚塔拉',
    symbol: r'WS$',
    keywords: '萨摩亚 阿皮亚 塔拉 samoa tala',
  ),
  WorldCurrencySpec(
    code: 'XPF',
    name: '太平洋法郎',
    symbol: '₣',
    keywords: '法属波利尼西亚 大溪地 塔希提 新喀里多尼亚 瓦利斯 cfp franc tahiti',
  ),

  // --- Middle East, Central Asia & Caucasus ---
  WorldCurrencySpec(
    code: 'AMD',
    name: '亚美尼亚德拉姆',
    symbol: '֏',
    keywords: '亚美尼亚 埃里温 德拉姆 armenia dram',
  ),
  WorldCurrencySpec(
    code: 'AZN',
    name: '阿塞拜疆马纳特',
    symbol: '₼',
    keywords: '阿塞拜疆 巴库 马纳特 azerbaijan manat',
  ),
  WorldCurrencySpec(
    code: 'BHD',
    name: '巴林第纳尔',
    symbol: 'BD',
    keywords: '巴林 麦纳麦 第纳尔 bahrain dinar',
  ),
  WorldCurrencySpec(
    code: 'GEL',
    name: '格鲁吉亚拉里',
    symbol: '₾',
    keywords: '格鲁吉亚 第比利斯 巴统 拉里 georgia lari',
  ),
  WorldCurrencySpec(
    code: 'ILS',
    name: '以色列新谢克尔',
    symbol: '₪',
    keywords: '以色列 特拉维夫 耶路撒冷 谢克尔 israel new shekel',
  ),
  WorldCurrencySpec(
    code: 'IQD',
    name: '伊拉克第纳尔',
    symbol: 'ع.د',
    keywords: '伊拉克 巴格达 第纳尔 iraq dinar',
  ),
  WorldCurrencySpec(
    code: 'IRR',
    name: '伊朗里亚尔',
    symbol: '﷼',
    keywords: '伊朗 德黑兰 里亚尔 托曼 iran rial',
  ),
  WorldCurrencySpec(
    code: 'JOD',
    name: '约旦第纳尔',
    symbol: 'JD',
    keywords: '约旦 安曼 佩特拉 第纳尔 jordan dinar',
  ),
  WorldCurrencySpec(
    code: 'KGS',
    name: '吉尔吉斯斯坦索姆',
    symbol: 'с',
    keywords: '吉尔吉斯斯坦 比什凯克 索姆 kyrgyzstan som',
  ),
  WorldCurrencySpec(
    code: 'KWD',
    name: '科威特第纳尔',
    symbol: 'KD',
    keywords: '科威特 第纳尔 kuwait dinar',
  ),
  WorldCurrencySpec(
    code: 'KZT',
    name: '哈萨克斯坦坚戈',
    symbol: '₸',
    keywords: '哈萨克斯坦 阿拉木图 阿斯塔纳 坚戈 kazakhstan tenge',
  ),
  WorldCurrencySpec(
    code: 'LBP',
    name: '黎巴嫩镑',
    symbol: 'L£',
    keywords: '黎巴嫩 贝鲁特 黎镑 lebanon pound',
  ),
  WorldCurrencySpec(
    code: 'OMR',
    name: '阿曼里亚尔',
    symbol: 'OMR',
    keywords: '阿曼 马斯喀特 里亚尔 oman rial',
  ),
  WorldCurrencySpec(
    code: 'QAR',
    name: '卡塔尔里亚尔',
    symbol: 'QR',
    keywords: '卡塔尔 多哈 里亚尔 qatar riyal',
  ),
  WorldCurrencySpec(
    code: 'SYP',
    name: '叙利亚镑',
    symbol: '£S',
    keywords: '叙利亚 大马士革 叙镑 syria pound',
  ),
  WorldCurrencySpec(
    code: 'TJS',
    name: '塔吉克斯坦索莫尼',
    symbol: 'SM',
    keywords: '塔吉克斯坦 杜尚别 索莫尼 tajikistan somoni',
  ),
  WorldCurrencySpec(
    code: 'TMT',
    name: '土库曼斯坦马纳特',
    symbol: 'T',
    keywords: '土库曼斯坦 阿什哈巴德 马纳特 turkmenistan manat',
  ),
  WorldCurrencySpec(
    code: 'UZS',
    name: '乌兹别克斯坦苏姆',
    symbol: "so'm",
    keywords: '乌兹别克斯坦 塔什干 撒马尔罕 苏姆 uzbekistan som',
  ),
  WorldCurrencySpec(
    code: 'YER',
    name: '也门里亚尔',
    symbol: '﷼',
    keywords: '也门 萨那 里亚尔 yemen rial',
  ),

  // --- Europe ---
  WorldCurrencySpec(
    code: 'ALL',
    name: '阿尔巴尼亚列克',
    symbol: 'L',
    keywords: '阿尔巴尼亚 地拉那 列克 albania lek',
  ),
  WorldCurrencySpec(
    code: 'BAM',
    name: '波黑可兑换马克',
    symbol: 'KM',
    keywords: '波黑 波斯尼亚 黑塞哥维那 萨拉热窝 马克 bosnia convertible mark',
  ),
  WorldCurrencySpec(
    code: 'BGN',
    name: '保加利亚列弗',
    symbol: 'лв',
    keywords: '保加利亚 索非亚 列弗 bulgaria lev',
  ),
  WorldCurrencySpec(
    code: 'BYN',
    name: '白俄罗斯卢布',
    symbol: 'Br',
    keywords: '白俄罗斯 明斯克 卢布 belarus ruble',
  ),
  WorldCurrencySpec(
    code: 'CZK',
    name: '捷克克朗',
    symbol: 'Kč',
    keywords: '捷克 布拉格 克朗 czech koruna',
  ),
  WorldCurrencySpec(
    code: 'DKK',
    name: '丹麦克朗',
    symbol: 'kr',
    keywords: '丹麦 哥本哈根 格陵兰 法罗群岛 克朗 denmark danish krone',
  ),
  WorldCurrencySpec(
    code: 'GIP',
    name: '直布罗陀镑',
    symbol: '£',
    keywords: '直布罗陀 gibraltar pound',
  ),
  WorldCurrencySpec(
    code: 'HRK',
    name: '克罗地亚库纳',
    symbol: 'kn',
    keywords: '克罗地亚 萨格勒布 库纳 croatia kuna',
  ),
  WorldCurrencySpec(
    code: 'HUF',
    name: '匈牙利福林',
    symbol: 'Ft',
    keywords: '匈牙利 布达佩斯 福林 hungary forint',
  ),
  WorldCurrencySpec(
    code: 'ISK',
    name: '冰岛克朗',
    symbol: 'kr',
    keywords: '冰岛 雷克雅未克 克朗 iceland krona',
  ),
  WorldCurrencySpec(
    code: 'MDL',
    name: '摩尔多瓦列伊',
    symbol: 'L',
    keywords: '摩尔多瓦 基希讷乌 列伊 moldova leu',
  ),
  WorldCurrencySpec(
    code: 'MKD',
    name: '北马其顿第纳尔',
    symbol: 'ден',
    keywords: '北马其顿 马其顿 斯科普里 第纳尔 north macedonia denar',
  ),
  WorldCurrencySpec(
    code: 'NOK',
    name: '挪威克朗',
    symbol: 'kr',
    keywords: '挪威 奥斯陆 克朗 norway norwegian krone',
  ),
  WorldCurrencySpec(
    code: 'PLN',
    name: '波兰兹罗提',
    symbol: 'zł',
    keywords: '波兰 华沙 克拉科夫 兹罗提 poland zloty',
  ),
  WorldCurrencySpec(
    code: 'RON',
    name: '罗马尼亚列伊',
    symbol: 'lei',
    keywords: '罗马尼亚 布加勒斯特 列伊 romania leu',
  ),
  WorldCurrencySpec(
    code: 'RSD',
    name: '塞尔维亚第纳尔',
    symbol: 'дин.',
    keywords: '塞尔维亚 贝尔格莱德 第纳尔 serbia dinar',
  ),
  WorldCurrencySpec(
    code: 'SEK',
    name: '瑞典克朗',
    symbol: 'kr',
    keywords: '瑞典 斯德哥尔摩 克朗 sweden swedish krona',
  ),
  WorldCurrencySpec(
    code: 'UAH',
    name: '乌克兰格里夫纳',
    symbol: '₴',
    keywords: '乌克兰 基辅 格里夫纳 ukraine hryvnia',
  ),

  // --- Americas & Caribbean ---
  WorldCurrencySpec(
    code: 'ANG',
    name: '荷属安的列斯盾',
    symbol: 'ƒ',
    keywords: '荷属安的列斯 库拉索 圣马丁 盾 netherlands antillean guilder',
  ),
  WorldCurrencySpec(
    code: 'ARS',
    name: '阿根廷比索',
    symbol: r'$',
    keywords: '阿根廷 布宜诺斯艾利斯 比索 argentina peso',
  ),
  WorldCurrencySpec(
    code: 'AWG',
    name: '阿鲁巴弗罗林',
    symbol: 'ƒ',
    keywords: '阿鲁巴 弗罗林 aruba florin',
  ),
  WorldCurrencySpec(
    code: 'BBD',
    name: '巴巴多斯元',
    symbol: r'Bds$',
    keywords: '巴巴多斯 barbados dollar',
  ),
  WorldCurrencySpec(
    code: 'BMD',
    name: '百慕大元',
    symbol: r'BD$',
    keywords: '百慕大 bermuda dollar',
  ),
  WorldCurrencySpec(
    code: 'BOB',
    name: '玻利维亚诺',
    symbol: 'Bs.',
    keywords: '玻利维亚 拉巴斯 乌尤尼 玻利维亚诺 bolivia boliviano',
  ),
  WorldCurrencySpec(
    code: 'BRL',
    name: '巴西雷亚尔',
    symbol: r'R$',
    keywords: '巴西 圣保罗 里约热内卢 雷亚尔 brazil brazilian real',
  ),
  WorldCurrencySpec(
    code: 'BSD',
    name: '巴哈马元',
    symbol: r'B$',
    keywords: '巴哈马 拿骚 bahamas dollar',
  ),
  WorldCurrencySpec(
    code: 'BZD',
    name: '伯利兹元',
    symbol: r'BZ$',
    keywords: '伯利兹 belize dollar',
  ),
  WorldCurrencySpec(
    code: 'CLP',
    name: '智利比索',
    symbol: r'$',
    keywords: '智利 圣地亚哥 比索 chile chilean peso',
  ),
  WorldCurrencySpec(
    code: 'COP',
    name: '哥伦比亚比索',
    symbol: r'$',
    keywords: '哥伦比亚 波哥大 比索 colombia colombian peso',
  ),
  WorldCurrencySpec(
    code: 'CRC',
    name: '哥斯达黎加科朗',
    symbol: '₡',
    keywords: '哥斯达黎加 圣何塞 科朗 costa rica colon',
  ),
  WorldCurrencySpec(
    code: 'CUC',
    name: '古巴可兑换比索',
    symbol: r'CUC$',
    keywords: '古巴 可兑换比索 cuba convertible peso',
  ),
  WorldCurrencySpec(
    code: 'CUP',
    name: '古巴比索',
    symbol: r'$',
    keywords: '古巴 哈瓦那 比索 cuba cuban peso',
  ),
  WorldCurrencySpec(
    code: 'DOP',
    name: '多米尼加比索',
    symbol: r'RD$',
    keywords: '多米尼加 圣多明各 比索 dominican peso',
  ),
  WorldCurrencySpec(
    code: 'FKP',
    name: '福克兰群岛镑',
    symbol: '£',
    keywords: '福克兰群岛 马尔维纳斯 falkland islands pound',
  ),
  WorldCurrencySpec(
    code: 'GTQ',
    name: '危地马拉格查尔',
    symbol: 'Q',
    keywords: '危地马拉 格查尔 guatemala quetzal',
  ),
  WorldCurrencySpec(
    code: 'GYD',
    name: '圭亚那元',
    symbol: r'G$',
    keywords: '圭亚那 乔治敦 guyana dollar',
  ),
  WorldCurrencySpec(
    code: 'HNL',
    name: '洪都拉斯伦皮拉',
    symbol: 'L',
    keywords: '洪都拉斯 特古西加尔巴 伦皮拉 honduras lempira',
  ),
  WorldCurrencySpec(
    code: 'HTG',
    name: '海地古德',
    symbol: 'G',
    keywords: '海地 太子港 古德 haiti gourde',
  ),
  WorldCurrencySpec(
    code: 'JMD',
    name: '牙买加元',
    symbol: r'J$',
    keywords: '牙买加 金斯敦 jamaica dollar',
  ),
  WorldCurrencySpec(
    code: 'KYD',
    name: '开曼群岛元',
    symbol: r'CI$',
    keywords: '开曼群岛 cayman islands dollar',
  ),
  WorldCurrencySpec(
    code: 'MXN',
    name: '墨西哥比索',
    symbol: r'Mex$',
    keywords: '墨西哥 墨西哥城 坎昆 比索 mexico mexican peso',
  ),
  WorldCurrencySpec(
    code: 'NIO',
    name: '尼加拉瓜科多巴',
    symbol: r'C$',
    keywords: '尼加拉瓜 马那瓜 科多巴 nicaragua cordoba',
  ),
  WorldCurrencySpec(
    code: 'PAB',
    name: '巴拿马巴波亚',
    symbol: 'B/.',
    keywords: '巴拿马 巴波亚 panama balboa',
  ),
  WorldCurrencySpec(
    code: 'PEN',
    name: '秘鲁索尔',
    symbol: 'S/',
    keywords: '秘鲁 利马 库斯科 索尔 新索尔 peru peruvian sol',
  ),
  WorldCurrencySpec(
    code: 'PYG',
    name: '巴拉圭瓜拉尼',
    symbol: '₲',
    keywords: '巴拉圭 亚松森 瓜拉尼 paraguay guarani',
  ),
  WorldCurrencySpec(
    code: 'SRD',
    name: '苏里南元',
    symbol: r'$',
    keywords: '苏里南 帕拉马里博 suriname dollar',
  ),
  WorldCurrencySpec(
    code: 'SVC',
    name: '萨尔瓦多科朗',
    symbol: '₡',
    keywords: '萨尔瓦多 科朗 el salvador colon',
  ),
  WorldCurrencySpec(
    code: 'TTD',
    name: '特立尼达和多巴哥元',
    symbol: r'TT$',
    keywords: '特立尼达和多巴哥 trinidad tobago dollar',
  ),
  WorldCurrencySpec(
    code: 'UYU',
    name: '乌拉圭比索',
    symbol: r'$U',
    keywords: '乌拉圭 蒙得维的亚 比索 uruguay peso',
  ),
  WorldCurrencySpec(
    code: 'VES',
    name: '委内瑞拉玻利瓦尔',
    symbol: 'Bs.S',
    keywords: '委内瑞拉 加拉加斯 玻利瓦尔 venezuela bolivar',
  ),
  WorldCurrencySpec(
    code: 'XCD',
    name: '东加勒比元',
    symbol: r'EC$',
    keywords: '东加勒比 安提瓜 圣卢西亚 格林纳达 多米尼克 圣基茨 east caribbean dollar',
  ),
  WorldCurrencySpec(
    code: 'XCG',
    name: '加勒比盾',
    symbol: 'Cg',
    keywords: '库拉索 荷属圣马丁 加勒比盾 caribbean guilder',
  ),

  // --- Africa ---
  WorldCurrencySpec(
    code: 'AOA',
    name: '安哥拉宽扎',
    symbol: 'Kz',
    keywords: '安哥拉 罗安达 宽扎 angola kwanza',
  ),
  WorldCurrencySpec(
    code: 'BIF',
    name: '布隆迪法郎',
    symbol: 'FBu',
    keywords: '布隆迪 法郎 burundi franc',
  ),
  WorldCurrencySpec(
    code: 'BWP',
    name: '博茨瓦纳普拉',
    symbol: 'P',
    keywords: '博茨瓦纳 哈博罗内 普拉 botswana pula',
  ),
  WorldCurrencySpec(
    code: 'CDF',
    name: '刚果法郎',
    symbol: 'FC',
    keywords: '刚果金 刚果民主共和国 金沙萨 法郎 congo franc',
  ),
  WorldCurrencySpec(
    code: 'CVE',
    name: '佛得角埃斯库多',
    symbol: 'Esc',
    keywords: '佛得角 埃斯库多 cape verde escudo',
  ),
  WorldCurrencySpec(
    code: 'DJF',
    name: '吉布提法郎',
    symbol: 'Fdj',
    keywords: '吉布提 法郎 djibouti franc',
  ),
  WorldCurrencySpec(
    code: 'DZD',
    name: '阿尔及利亚第纳尔',
    symbol: 'د.ج',
    keywords: '阿尔及利亚 阿尔及尔 第纳尔 algeria dinar',
  ),
  WorldCurrencySpec(
    code: 'ERN',
    name: '厄立特里亚纳克法',
    symbol: 'Nfk',
    keywords: '厄立特里亚 阿斯马拉 纳克法 eritrea nakfa',
  ),
  WorldCurrencySpec(
    code: 'ETB',
    name: '埃塞俄比亚比尔',
    symbol: 'Br',
    keywords: '埃塞俄比亚 亚的斯亚贝巴 比尔 ethiopia birr',
  ),
  WorldCurrencySpec(
    code: 'GHS',
    name: '加纳塞地',
    symbol: '₵',
    keywords: '加纳 阿克拉 塞地 ghana cedi',
  ),
  WorldCurrencySpec(
    code: 'GMD',
    name: '冈比亚达拉西',
    symbol: 'D',
    keywords: '冈比亚 班珠尔 达拉西 gambia dalasi',
  ),
  WorldCurrencySpec(
    code: 'GNF',
    name: '几内亚法郎',
    symbol: 'FG',
    keywords: '几内亚 科纳克里 法郎 guinea franc',
  ),
  WorldCurrencySpec(
    code: 'KES',
    name: '肯尼亚先令',
    symbol: 'KSh',
    keywords: '肯尼亚 内罗毕 蒙巴萨 先令 kenya shilling',
  ),
  WorldCurrencySpec(
    code: 'KMF',
    name: '科摩罗法郎',
    symbol: 'CF',
    keywords: '科摩罗 法郎 comoros franc',
  ),
  WorldCurrencySpec(
    code: 'LRD',
    name: '利比里亚元',
    symbol: r'L$',
    keywords: '利比里亚 蒙罗维亚 liberia dollar',
  ),
  WorldCurrencySpec(
    code: 'LSL',
    name: '莱索托洛蒂',
    symbol: 'L',
    keywords: '莱索托 马塞卢 洛蒂 lesotho loti',
  ),
  WorldCurrencySpec(
    code: 'LYD',
    name: '利比亚第纳尔',
    symbol: 'LD',
    keywords: '利比亚 的黎波里 第纳尔 libya dinar',
  ),
  WorldCurrencySpec(
    code: 'MAD',
    name: '摩洛哥迪拉姆',
    symbol: 'MAD',
    keywords: '摩洛哥 卡萨布兰卡 马拉喀什 舍夫沙万 迪拉姆 morocco dirham',
  ),
  WorldCurrencySpec(
    code: 'MGA',
    name: '马达加斯加阿里亚里',
    symbol: 'Ar',
    keywords: '马达加斯加 塔那那利佛 阿里亚里 madagascar ariary',
  ),
  WorldCurrencySpec(
    code: 'MRU',
    name: '毛里塔尼亚乌吉亚',
    symbol: 'UM',
    keywords: '毛里塔尼亚 努瓦克肖特 乌吉亚 mauritania ouguiya',
  ),
  WorldCurrencySpec(
    code: 'MUR',
    name: '毛里求斯卢比',
    symbol: '₨',
    keywords: '毛里求斯 路易港 卢比 mauritius rupee',
  ),
  WorldCurrencySpec(
    code: 'MWK',
    name: '马拉维克瓦查',
    symbol: 'MK',
    keywords: '马拉维 利隆圭 克瓦查 malawi kwacha',
  ),
  WorldCurrencySpec(
    code: 'MZN',
    name: '莫桑比克梅蒂卡尔',
    symbol: 'MT',
    keywords: '莫桑比克 马普托 梅蒂卡尔 mozambique metical',
  ),
  WorldCurrencySpec(
    code: 'NAD',
    name: '纳米比亚元',
    symbol: r'N$',
    keywords: '纳米比亚 温得和克 namibia dollar',
  ),
  WorldCurrencySpec(
    code: 'NGN',
    name: '尼日利亚奈拉',
    symbol: '₦',
    keywords: '尼日利亚 拉各斯 阿布贾 奈拉 nigeria naira',
  ),
  WorldCurrencySpec(
    code: 'RWF',
    name: '卢旺达法郎',
    symbol: 'RF',
    keywords: '卢旺达 基加利 法郎 rwanda franc',
  ),
  WorldCurrencySpec(
    code: 'SDG',
    name: '苏丹镑',
    symbol: 'SDG',
    keywords: '苏丹 喀土穆 苏丹镑 sudan pound',
  ),
  WorldCurrencySpec(
    code: 'SHP',
    name: '圣赫勒拿镑',
    symbol: '£',
    keywords: '圣赫勒拿 saint helena pound',
  ),
  WorldCurrencySpec(
    code: 'SLE',
    name: '塞拉利昂利昂',
    symbol: 'Le',
    keywords: '塞拉利昂 弗里敦 利昂 sierra leone leone',
  ),
  WorldCurrencySpec(
    code: 'SLL',
    name: '塞拉利昂旧利昂',
    symbol: 'Le',
    keywords: '塞拉利昂 旧利昂 sierra leone old leone',
  ),
  WorldCurrencySpec(
    code: 'SOS',
    name: '索马里先令',
    symbol: 'Sh.So.',
    keywords: '索马里 摩加迪沙 先令 somalia shilling',
  ),
  WorldCurrencySpec(
    code: 'SSP',
    name: '南苏丹镑',
    symbol: '£',
    keywords: '南苏丹 朱巴 南苏丹镑 south sudan pound',
  ),
  WorldCurrencySpec(
    code: 'STN',
    name: '圣多美和普林西比多布拉',
    symbol: 'Db',
    keywords: '圣多美和普林西比 多布拉 sao tome dobra',
  ),
  WorldCurrencySpec(
    code: 'SZL',
    name: '斯威士兰里兰吉尼',
    symbol: 'E',
    keywords: '斯威士兰 里兰吉尼 eswatini swaziland lilangeni',
  ),
  WorldCurrencySpec(
    code: 'TND',
    name: '突尼斯第纳尔',
    symbol: 'DT',
    keywords: '突尼斯 第纳尔 tunisia dinar',
  ),
  WorldCurrencySpec(
    code: 'TZS',
    name: '坦桑尼亚先令',
    symbol: 'TSh',
    keywords: '坦桑尼亚 达累斯萨拉姆 桑给巴尔 先令 tanzania shilling',
  ),
  WorldCurrencySpec(
    code: 'UGX',
    name: '乌干达先令',
    symbol: 'USh',
    keywords: '乌干达 坎帕拉 先令 uganda shilling',
  ),
  WorldCurrencySpec(
    code: 'XAF',
    name: '中非法郎',
    symbol: 'FCFA',
    keywords: '中非 喀麦隆 加蓬 乍得 刚果布 赤道几内亚 法郎 central african cfa franc',
  ),
  WorldCurrencySpec(
    code: 'XOF',
    name: '西非法郎',
    symbol: 'CFA',
    keywords: '西非 塞内加尔 科特迪瓦 马里 贝宁 布基纳法索 多哥 尼日尔 法郎 west african cfa franc',
  ),
  WorldCurrencySpec(
    code: 'ZAR',
    name: '南非兰特',
    symbol: 'R',
    keywords: '南非 约翰内斯堡 开普敦 兰特 south africa rand',
  ),
  WorldCurrencySpec(
    code: 'ZMW',
    name: '赞比亚克瓦查',
    symbol: 'ZK',
    keywords: '赞比亚 卢萨卡 克瓦查 zambia kwacha',
  ),
  WorldCurrencySpec(
    code: 'ZWG',
    name: '津巴布韦金',
    symbol: 'ZiG',
    keywords: '津巴布韦 哈拉雷 津元 zimbabwe gold',
  ),
  WorldCurrencySpec(
    code: 'ZWL',
    name: '津巴布韦元',
    symbol: r'Z$',
    keywords: '津巴布韦 津元 zimbabwe dollar',
  ),
];

/// Common currencies offered when adding one (code, Chinese name, symbol).
/// Kept as a const record list for backward compatibility with existing callers.
const presetCurrencies = <(String, String, String)>[
  ('USD', '美元', r'$'),
  ('EUR', '欧元', '€'),
  ('JPY', '日元', '¥'),
  ('HKD', '港币', r'HK$'),
  ('MOP', '澳门元', r'MOP$'),
  ('TWD', '新台币', r'NT$'),
  ('GBP', '英镑', '£'),
  ('KRW', '韩元', '₩'),
  ('SGD', '新加坡元', r'S$'),
  ('AUD', '澳元', r'A$'),
  ('CAD', '加元', r'C$'),
  ('CHF', '瑞士法郎', 'CHF'),
  ('THB', '泰铢', '฿'),
  ('TRY', '土耳其里拉', '₺'),
  ('MYR', '马来西亚林吉特', 'RM'),
  ('RUB', '俄罗斯卢布', '₽'),
  ('NZD', '新西兰元', r'NZ$'),
  ('VND', '越南盾', '₫'),
  ('PHP', '菲律宾比索', '₱'),
  ('IDR', '印尼盾', 'Rp'),
  ('INR', '印度卢比', '₹'),
  ('AED', '阿联酋迪拉姆', 'AED'),
  ('SAR', '沙特里亚尔', 'SAR'),
  ('EGP', '埃及镑', 'E£'),
];

final Map<String, WorldCurrencySpec> _worldCurrencyByCode = {
  for (final spec in worldCurrencies) spec.code: spec,
};

/// Looks up a standard currency specification by case-insensitive ISO code.
WorldCurrencySpec? findWorldCurrency(String? code) {
  final normalized = normalizeCurrency(code);
  if (normalized == null) return null;
  return _worldCurrencyByCode[normalized];
}

/// Returns the default display symbol for [code]: `'¥'` for `'CNY'`, the
/// catalog symbol when non-empty for known ISO currencies, or normalized
/// [code] (empty string when null/blank).
String defaultCurrencySymbol(String? code) {
  final normalized = normalizeCurrency(code);
  if (normalized == null) return '';
  if (normalized == baseCurrency) return '¥';
  final spec = _worldCurrencyByCode[normalized];
  if (spec != null) {
    final trimmed = spec.symbol.trim();
    return trimmed.isNotEmpty ? trimmed : spec.code;
  }
  return normalized;
}

int _matchRank(WorldCurrencySpec spec, String lowerQuery) {
  final codeLower = spec.code.toLowerCase();
  if (codeLower == lowerQuery) return 0;
  final symbolLower = spec.symbol.toLowerCase();
  if (symbolLower == lowerQuery) return 1;
  final nameLower = spec.name.toLowerCase();
  if (nameLower == lowerQuery) return 2;
  if (codeLower.startsWith(lowerQuery)) return 3;
  if (nameLower.contains(lowerQuery)) return 4;
  if (symbolLower.contains(lowerQuery)) return 5;
  return 6;
}

bool _matchesToken(WorldCurrencySpec spec, String token) {
  return spec.code.toLowerCase().contains(token) ||
      spec.name.toLowerCase().contains(token) ||
      spec.symbol.toLowerCase().contains(token) ||
      spec.keywords.toLowerCase().contains(token);
}

/// Searches [worldCurrencies] by case-insensitive [query] against `code`,
/// `name`, `symbol`, and `keywords`, excluding [baseCurrency] and any codes in
/// [excludeCodes].
///
/// When [query] is blank, returns `popular` items first (in curated order),
/// followed by all remaining currencies sorted alphabetically by `code`.
List<WorldCurrencySpec> searchWorldCurrencies(
  String query, {
  Set<String> excludeCodes = const {},
}) {
  final excluded = <String>{
    baseCurrency,
    for (final c in excludeCodes)
      if (normalizeCurrency(c) case final norm?) norm,
  };
  final candidates = worldCurrencies
      .where((c) => !excluded.contains(c.code))
      .toList();

  final trimmed = query.trim();
  if (trimmed.isEmpty) {
    final popular = <WorldCurrencySpec>[];
    final others = <WorldCurrencySpec>[];
    for (final c in candidates) {
      if (c.popular) {
        popular.add(c);
      } else {
        others.add(c);
      }
    }
    others.sort((a, b) => a.code.compareTo(b.code));
    return [...popular, ...others];
  }

  final lowerQuery = trimmed.toLowerCase();
  final tokens = lowerQuery.split(RegExp(r'\s+'));
  final matched = candidates
      .where((c) => tokens.every((t) => _matchesToken(c, t)))
      .toList();

  matched.sort((a, b) {
    final rankCmp = _matchRank(
      a,
      lowerQuery,
    ).compareTo(_matchRank(b, lowerQuery));
    if (rankCmp != 0) return rankCmp;
    if (a.popular != b.popular) return a.popular ? -1 : 1;
    return a.code.compareTo(b.code);
  });
  return matched;
}

/// Canonical fractional scale stored in `currency.rate_to_anchor` (12 decimals).
const rateToAnchorScale = 12;

String _trim(String s) {
  if (!s.contains('.')) return s;
  var t = s.replaceFirst(RegExp(r'0+$'), '');
  if (t.endsWith('.')) t = t.substring(0, t.length - 1);
  return t;
}

/// Formats `coefficient / 10^scale` as a canonical decimal string with
/// trailing fractional zeros stripped.
String formatRateDecimal(BigInt coefficient, int scale) {
  final negative = coefficient.isNegative;
  final digits = coefficient.abs().toString().padLeft(scale + 1, '0');
  final text = scale == 0
      ? digits
      : '${digits.substring(0, digits.length - scale)}.'
            '${digits.substring(digits.length - scale)}';
  return '${negative ? '-' : ''}${_trim(text)}';
}

/// "1 USD = 7.10 CNY" (user input `price`) -> stored `rate_to_anchor`
/// (= amount of that currency per 1 CNY), HALF_UP to 12 decimals.
String rateToAnchorFromPrice(String price) {
  final DecimalValue p;
  try {
    p = DecimalValue.parse(price.trim());
  } on Failure {
    throw const Failure(FailureCode.validation, '汇率须为正数');
  }
  if (p.coefficient <= BigInt.zero) {
    throw const Failure(FailureCode.validation, '汇率须为正数');
  }
  // 1 / (c / 10^s) = 10^s / c, expressed with rateToAnchorScale decimals.
  final coefficient = divideRounded(
    powerOfTen(p.scale + rateToAnchorScale),
    p.coefficient,
    RoundingMode.halfUp,
  );
  if (coefficient == BigInt.zero) {
    throw const Failure(FailureCode.validation, '汇率过大');
  }
  return formatRateDecimal(coefficient, rateToAnchorScale);
}

/// Stored `rate_to_anchor` -> price of 1 unit in CNY, HALF_UP to 4 decimals.
String priceFromRateToAnchor(String rateToAnchor) {
  final r = DecimalValue.parse(rateToAnchor);
  if (r.coefficient <= BigInt.zero) return '0';
  final coefficient = divideRounded(
    powerOfTen(r.scale + 4),
    r.coefficient,
    RoundingMode.halfUp,
  );
  return formatRateDecimal(coefficient, 4);
}

/// Builds the `extra_info.curr` snapshot for an income/expense bill entered as
/// [sourceMinor] in [source], booked as [assetMinor] in the account currency
/// [account]. Returns null when every currency is the base currency.
CurrencySnapshot? billSnapshot({
  required String source,
  required BigInt sourceMinor,
  required String account,
  required BigInt assetMinor,
  required RateTable rates,
}) {
  final sc = normalizeCurrency(source) ?? baseCurrency;
  final ac = normalizeCurrency(account) ?? baseCurrency;
  if (sc == baseCurrency && ac == baseCurrency) return null;
  final bm = ac == baseCurrency
      ? assetMinor
      : sc == baseCurrency
      ? sourceMinor
      : rates.convert(assetMinor, ac, baseCurrency);
  return CurrencySnapshot(
    sourceCode: sc,
    sourceGross: sourceMinor,
    assetCode: ac,
    assetNet: assetMinor,
    baseCode: baseCurrency,
    baseAmount: bm,
  );
}
