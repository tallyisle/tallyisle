import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/app_version.dart';
import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart';
import '../../domain/rules/auto_map_rules.dart';
import '../../domain/rules/billing_period.dart';
import '../../domain/rules/budget_rules.dart';
import '../../domain/rules/category_stats.dart';
import '../../domain/rules/currency_rates.dart' show baseCurrency, billSnapshot;
import '../../domain/rules/debt_rules.dart' show isDebtVisibleInBook;
import '../../domain/rules/income_expense.dart';
import '../../domain/rules/mcp_rules.dart';
import '../../domain/rules/periodic_records.dart' show PeriodState, PeriodType;
import '../../domain/rules/receipt_diy_rules.dart'
    show RecordExtraLocation, parseRecordImages;
import '../../domain/rules/reimburse_overview.dart';
import '../../domain/rules/savings_plan.dart'
    show SavingsCycleType, SavingsPlanStatus, SavingsPlanType;
import '../../domain/rules/tag_stats.dart';
import '../../domain/rules/wish_note_rules.dart' show unsetWishTargetDate;
import '../../platform/auto_bill_bridge.dart';
import '../budget/budget_service.dart';
import '../catalog/catalog_service.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../ledger/ledger_service.dart';
import '../repo/ledger_queries.dart';
import '../tools/note_service.dart';
import '../tools/wish_service.dart';
import 'auto_bill_service.dart';
import 'url_scheme_service.dart'
    show matchCategoryByRef, matchFundingAssetByHint, matchFundingAssetByRef;

const _uuid = Uuid();

/// Metadata & JSON Schema definition for a single MCP tool (`F-039`).
final class McpToolSpec {
  const McpToolSpec({
    required this.name,
    required this.title,
    required this.description,
    required this.tier,
    required this.inputSchema,
    required this.readOnlyHint,
    required this.destructiveHint,
    required this.idempotentHint,
  });

  final String name;
  final String title;
  final String description;
  final McpToolTier tier;
  final Map<String, Object?> inputSchema;
  final bool readOnlyHint;
  final bool destructiveHint;
  final bool idempotentHint;

  Map<String, Object?> toMcpJson() => <String, Object?>{
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
    'annotations': <String, Object?>{
      'title': title,
      'readOnlyHint': readOnlyHint,
      'destructiveHint': destructiveHint,
      'idempotentHint': idempotentHint,
      'openWorldHint': false,
    },
  };
}

/// Canonical catalog of all 20 MCP tools exposed by TallyIsle (`F-039`).
const List<McpToolSpec> mcpToolCatalog = <McpToolSpec>[
  // ---- Read tools (7) ----
  McpToolSpec(
    name: 'get_overview',
    title: '获取账本与资产收支总览',
    description: '读取当前激活账本、全部账本列表、实时净资产/总资产/总负债（精确分与两位小数）及当前账期收支概览。',
    tier: McpToolTier.read,
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'book': <String, Object?>{
          'type': 'string',
          'description': '可选账本 ID 或名称；省略时使用当前激活账本。',
        },
      },
    },
  ),
  McpToolSpec(
    name: 'list_catalog',
    title: '读取分类、账户、标签与币种目录',
    description: '读取指定账本下的一二级收支分类树、资金/信用/借贷账户实时余额（含整数分与两位小数）、标签及币种汇率表。',
    tier: McpToolTier.read,
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'book': <String, Object?>{
          'type': 'string',
          'description': '可选账本 ID 或名称；省略时使用当前激活账本。',
        },
        'include_hidden': <String, Object?>{
          'type': 'boolean',
          'description': '是否包含已隐藏/已结清的分类、账户与标签（默认 false）。',
        },
      },
    },
  ),
  McpToolSpec(
    name: 'query_records',
    title: '多维检索账单流水',
    description:
        '按账本、起止日期（YYYY-MM-DD 或毫秒时间戳）、账单类型、分类（ID/名称/父>子）、账户、标签、关键词与金额区间分页查询账单（单页最多 200 条）。',
    tier: McpToolTier.read,
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'book': <String, Object?>{
          'type': 'string',
          'description': '账本 ID 或名称；省略且 all_books=false 时使用当前激活账本。',
        },
        'all_books': <String, Object?>{
          'type': 'boolean',
          'description': '是否跨全部账本检索（默认 false）。',
        },
        'start_date': <String, Object?>{
          'type': 'string',
          'description': '起始日期 YYYY-MM-DD、YYYY-MM-DD HH:mm 或毫秒时间戳字符串。',
        },
        'end_date': <String, Object?>{
          'type': 'string',
          'description':
              '结束日期 YYYY-MM-DD（含当日 23:59:59.999）、YYYY-MM-DD HH:mm 或毫秒时间戳字符串。',
        },
        'type': <String, Object?>{
          'type': 'string',
          'description':
              '账单类型编码或名称（如 expense/支出/0、income/收入/1、transfer/转账/2、reimbursable/报销/3）。',
        },
        'category': <String, Object?>{
          'type': 'string',
          'description': '分类 ID、名称或 "父分类>子分类" 路径（一级分类自动包含其下子分类）。',
        },
        'asset': <String, Object?>{
          'type': 'string',
          'description': '账户 ID 或名称（匹配入账、转出或转入账户）。',
        },
        'tag': <String, Object?>{
          'type': 'string',
          'description': '标签 ID 或名称（标签组自动包含子标签）。',
        },
        'keyword': <String, Object?>{
          'type': 'string',
          'description': '按备注、分类名、账户名或标签名模糊检索。',
        },
        'min_amount': <String, Object?>{
          'type': 'string',
          'description': '最小十进制金额（如 "10.00"）。',
        },
        'max_amount': <String, Object?>{
          'type': 'string',
          'description': '最大十进制金额（如 "500.00"）。',
        },
        'limit': <String, Object?>{
          'type': 'integer',
          'description': '返回条数上限（1..200，默认 50）。',
        },
        'offset': <String, Object?>{
          'type': 'integer',
          'description': '分页偏移量（>= 0，默认 0）。',
        },
      },
    },
  ),
  McpToolSpec(
    name: 'get_record_detail',
    title: '获取单笔账单完整详情',
    description: '按 record_id 读取账单完整字段及关联退款记录、报销收款记录、转账手续费子单、多币种汇率快照、标签与位置信息。',
    tier: McpToolTier.read,
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['record_id'],
      'properties': <String, Object?>{
        'record_id': <String, Object?>{
          'type': 'string',
          'description': '账单主键 record_id。',
        },
      },
    },
  ),
  McpToolSpec(
    name: 'get_statistics',
    title: '获取区间收支、分类与标签统计',
    description: '计算指定日期区间（缺省为当前账期）的总收入/总支出/结余、一级与二级分类排行及标签统计排行。',
    tier: McpToolTier.read,
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'book': <String, Object?>{
          'type': 'string',
          'description': '账本 ID 或名称；省略时使用当前激活账本。',
        },
        'all_books': <String, Object?>{
          'type': 'boolean',
          'description': '是否汇总全部账本（默认 false）。',
        },
        'start_date': <String, Object?>{
          'type': 'string',
          'description': '起始日期 YYYY-MM-DD；省略时取当前账期起点。',
        },
        'end_date': <String, Object?>{
          'type': 'string',
          'description': '结束日期 YYYY-MM-DD；省略时取当前账期终点。',
        },
        'include_exclude_budget': <String, Object?>{
          'type': 'boolean',
          'description': '是否包含标记为“不计入预算”的账单（默认 true）。',
        },
      },
    },
  ),
  McpToolSpec(
    name: 'get_budgets',
    title: '获取月度或年度预算执行进度',
    description: '查询指定账本在月度（YYYY-M）或年度（YYYY）的总预算及各分类预算已用、剩余与超支状态。',
    tier: McpToolTier.read,
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'book': <String, Object?>{
          'type': 'string',
          'description': '账本 ID 或名称；省略时使用当前激活账本。',
        },
        'section': <String, Object?>{
          'type': 'string',
          'description':
              '预算周期标识：月预算传 "YYYY-M"（如 "2026-11"），年预算传 "YYYY"（如 "2026"）。',
        },
      },
    },
  ),
  McpToolSpec(
    name: 'list_plans_and_notes',
    title: '获取待报销、借贷、计划、便签与心愿',
    description: '汇总读取待报销账单、借入/借出往来、信用卡分期、周期记账规则、存钱计划、活跃便签与心愿单。',
    tier: McpToolTier.read,
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'book': <String, Object?>{
          'type': 'string',
          'description': '可选账本 ID 或名称；省略且 all_books=false 时按当前激活账本过滤。',
        },
        'all_books': <String, Object?>{
          'type': 'boolean',
          'description': '是否跨全部账本读取（默认 false）。',
        },
      },
    },
  ),

  // ---- Append tools (5) ----
  McpToolSpec(
    name: 'create_record',
    title: '新建正式账单',
    description:
        '通过 LedgerService 精确入账一笔支出、收入、转账（含可选手续费）、报销、预收或预支，实时更新账户余额并支持幂等 command_id。',
    tier: McpToolTier.append,
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['amount'],
      'properties': <String, Object?>{
        'type': <String, Object?>{
          'type': 'string',
          'description':
              '账单类型：expense(支出,默认) / income(收入) / transfer(转账) / reimbursable(报销) / advance_income(预收) / advance_expense(预支)。',
        },
        'amount': <String, Object?>{
          'type': 'string',
          'description': '精确两位小数十进制实付/实收/转账金额字符串（如 "35.80"，严禁浮点误差）。',
        },
        'book': <String, Object?>{
          'type': 'string',
          'description': '账本 ID 或名称；省略时使用当前激活账本。',
        },
        'category': <String, Object?>{
          'type': 'string',
          'description': '分类 ID、名称或 "父分类>子分类"（转账无需填写）。',
        },
        'asset': <String, Object?>{
          'type': 'string',
          'description': '入账/付款资金或信用账户 ID 或名称（可选，转账请用 from_asset / to_asset）。',
        },
        'from_asset': <String, Object?>{
          'type': 'string',
          'description': '转账转出账户（或报销垫付账户）ID 或名称。',
        },
        'to_asset': <String, Object?>{
          'type': 'string',
          'description': '转账转入账户 ID 或名称。',
        },
        'fee': <String, Object?>{
          'type': 'string',
          'description': '可选转账手续费十进制字符串（如 "1.50"）。',
        },
        'fee_from_target': <String, Object?>{
          'type': 'boolean',
          'description': '手续费是否由转入账户承担（默认 false 由转出账户承担）。',
        },
        'discount': <String, Object?>{
          'type': 'string',
          'description': '可选优惠金额十进制字符串（仅支出/收入有效，如 "4.00"）。',
        },
        'remark': <String, Object?>{'type': 'string', 'description': '账单备注。'},
        'record_time': <String, Object?>{
          'type': 'string',
          'description': '记账时间（YYYY-MM-DD HH:mm[:ss]、ISO-8601 或毫秒时间戳；默认当前时间）。',
        },
        'tags': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
          'description': '关联标签 ID 或名称数组。',
        },
        'exclude_budget': <String, Object?>{
          'type': 'boolean',
          'description': '是否不计入预算（默认 false）。',
        },
        'exclude_ex_in': <String, Object?>{
          'type': 'boolean',
          'description': '是否不计入收支统计（默认 false）。',
        },
        'command_id': <String, Object?>{
          'type': 'string',
          'description': '可选幂等提交标识（1..128 字符）。',
        },
      },
    },
  ),
  McpToolSpec(
    name: 'create_record_draft',
    title: '创建待人工确认账单草稿',
    description:
        '将识别或整理的账单写入自动记账“待确认草稿池”（auto_map KEY_DRAFT），不直接改动账户余额，供用户在应用内人工核对入账。',
    tier: McpToolTier.append,
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['amount'],
      'properties': <String, Object?>{
        'type': <String, Object?>{
          'type': 'string',
          'description': '草稿类型：expense(默认) / income / transfer。',
        },
        'amount': <String, Object?>{
          'type': 'string',
          'description': '精确两位小数十进制金额字符串（> 0，如 "28.50"）。',
        },
        'discount': <String, Object?>{
          'type': 'string',
          'description': '可选优惠金额十进制字符串。',
        },
        'book': <String, Object?>{
          'type': 'string',
          'description': '目标账本 ID 或名称。',
        },
        'category': <String, Object?>{
          'type': 'string',
          'description': '预设分类 ID、名称或 "父>子" 提示。',
        },
        'asset': <String, Object?>{
          'type': 'string',
          'description': '预设账户/转出账户 ID 或名称提示。',
        },
        'to_asset': <String, Object?>{
          'type': 'string',
          'description': '转账转入账户 ID 或名称提示。',
        },
        'remark': <String, Object?>{
          'type': 'string',
          'description': '商户或备注说明。',
        },
        'source_app': <String, Object?>{
          'type': 'string',
          'description': '来源标识（默认 "MCP AI"）。',
        },
        'record_time': <String, Object?>{
          'type': 'string',
          'description': '发生时间（默认当前时间）。',
        },
        'command_id': <String, Object?>{
          'type': 'string',
          'description': '可选幂等提交标识。',
        },
      },
    },
  ),
  McpToolSpec(
    name: 'create_note',
    title: '新建便签',
    description: '在帐屿便签本中创建一条新便签。',
    tier: McpToolTier.append,
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['content'],
      'properties': <String, Object?>{
        'title': <String, Object?>{'type': 'string', 'description': '可选便签标题。'},
        'content': <String, Object?>{
          'type': 'string',
          'description': '便签正文内容。',
        },
        'command_id': <String, Object?>{
          'type': 'string',
          'description': '可选幂等提交标识。',
        },
      },
    },
  ),
  McpToolSpec(
    name: 'create_wish',
    title: '新建心愿单目标',
    description: '在心愿单中创建一个目标心愿（纯目标跟踪，不扣减账户余额）。',
    tier: McpToolTier.append,
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['content', 'value'],
      'properties': <String, Object?>{
        'content': <String, Object?>{
          'type': 'string',
          'description': '心愿名称或描述。',
        },
        'value': <String, Object?>{
          'type': 'string',
          'description': '心愿预计金额十进制字符串（如 "2999.00"）。',
        },
        'target_date': <String, Object?>{
          'type': 'string',
          'description': '可选目标实现日期（YYYY-MM-DD 或毫秒时间戳）。',
        },
        'command_id': <String, Object?>{
          'type': 'string',
          'description': '可选幂等提交标识。',
        },
      },
    },
  ),
  McpToolSpec(
    name: 'create_category_or_tag',
    title: '新建分类或标签',
    description: '在指定账本下新建一/二级收支分类，或新建全局标签/标签组。',
    tier: McpToolTier.append,
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['kind', 'name'],
      'properties': <String, Object?>{
        'kind': <String, Object?>{
          'type': 'string',
          'enum': <String>['category', 'tag'],
          'description': '创建类型："category"（分类）或 "tag"（标签）。',
        },
        'name': <String, Object?>{'type': 'string', 'description': '分类或标签名称。'},
        'book': <String, Object?>{
          'type': 'string',
          'description': '创建分类时的目标账本 ID 或名称（默认当前账本）。',
        },
        'category_type': <String, Object?>{
          'type': 'string',
          'description': '创建分类时的收支方向：expense(支出,默认) 或 income(收入)。',
        },
        'parent_category': <String, Object?>{
          'type': 'string',
          'description': '创建二级子分类时的一级父分类 ID 或名称。',
        },
        'is_group': <String, Object?>{
          'type': 'boolean',
          'description': '创建标签时是否为父级标签组（默认 false）。',
        },
        'parent_tag': <String, Object?>{
          'type': 'string',
          'description': '创建子标签时的父标签组 ID 或名称。',
        },
        'color': <String, Object?>{
          'type': 'string',
          'description': '可选十六进制颜色（如 "#1E88E5"）。',
        },
        'command_id': <String, Object?>{
          'type': 'string',
          'description': '可选幂等提交标识。',
        },
      },
    },
  ),

  // ---- Full-access tools (8) ----
  McpToolSpec(
    name: 'update_record',
    title: '编辑已有账单',
    description: '按 record_id 修改已有账单的金额、分类、账户、备注、时间或统计开关，并原子重算账户余额差额。',
    tier: McpToolTier.full,
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['record_id'],
      'properties': <String, Object?>{
        'record_id': <String, Object?>{
          'type': 'string',
          'description': '待修改的账单 record_id。',
        },
        'type': <String, Object?>{'type': 'string'},
        'amount': <String, Object?>{'type': 'string'},
        'book': <String, Object?>{'type': 'string'},
        'category': <String, Object?>{'type': 'string'},
        'asset': <String, Object?>{'type': 'string'},
        'from_asset': <String, Object?>{'type': 'string'},
        'to_asset': <String, Object?>{'type': 'string'},
        'fee': <String, Object?>{'type': 'string'},
        'fee_from_target': <String, Object?>{'type': 'boolean'},
        'discount': <String, Object?>{'type': 'string'},
        'remark': <String, Object?>{'type': 'string'},
        'record_time': <String, Object?>{'type': 'string'},
        'tags': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
        },
        'exclude_budget': <String, Object?>{'type': 'boolean'},
        'exclude_ex_in': <String, Object?>{'type': 'boolean'},
        'command_id': <String, Object?>{'type': 'string'},
      },
    },
  ),
  McpToolSpec(
    name: 'record_refund',
    title: '登记账单退款',
    description: '为已有支出、收入或报销账单登记一笔关联退款（双向绑定原单并回冲账户余额）。',
    tier: McpToolTier.full,
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['origin_id', 'amount'],
      'properties': <String, Object?>{
        'origin_id': <String, Object?>{
          'type': 'string',
          'description': '原账单 record_id。',
        },
        'amount': <String, Object?>{
          'type': 'string',
          'description': '退款金额十进制字符串（> 0）。',
        },
        'asset': <String, Object?>{
          'type': 'string',
          'description': '可选退款入账账户 ID 或名称（省略则默认退回原付款账户）。',
        },
        'record_time': <String, Object?>{
          'type': 'string',
          'description': '退款时间（默认当前时间）。',
        },
        'remark': <String, Object?>{'type': 'string', 'description': '退款备注。'},
        'command_id': <String, Object?>{'type': 'string'},
      },
    },
  ),
  McpToolSpec(
    name: 'record_reimbursement',
    title: '登记报销收款',
    description: '为待报销账单（type=3）登记报销到账款（生成关联 type=15 报销收款单并增加收款账户余额）。',
    tier: McpToolTier.full,
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['origin_id', 'amount'],
      'properties': <String, Object?>{
        'origin_id': <String, Object?>{
          'type': 'string',
          'description': '原报销支出单 record_id（须为 type=3）。',
        },
        'amount': <String, Object?>{
          'type': 'string',
          'description': '本次报销收款金额十进制字符串（> 0）。',
        },
        'asset': <String, Object?>{
          'type': 'string',
          'description': '报销收款账户 ID 或名称（省略则默认使用原垫付账户）。',
        },
        'record_time': <String, Object?>{
          'type': 'string',
          'description': '收款时间（默认当前时间）。',
        },
        'remark': <String, Object?>{'type': 'string', 'description': '报销收款备注。'},
        'command_id': <String, Object?>{'type': 'string'},
      },
    },
  ),
  McpToolSpec(
    name: 'delete_record',
    title: '删除账单',
    description: '按 record_id 删除账单及其关联手续费/退款/报销子单，对称回滚账户余额。',
    tier: McpToolTier.full,
    readOnlyHint: false,
    destructiveHint: true,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['record_id'],
      'properties': <String, Object?>{
        'record_id': <String, Object?>{
          'type': 'string',
          'description': '待删除账单 record_id。',
        },
        'command_id': <String, Object?>{'type': 'string'},
      },
    },
  ),
  McpToolSpec(
    name: 'update_note',
    title: '修改便签',
    description: '更新活跃便签的标题与正文内容。',
    tier: McpToolTier.full,
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['id', 'content'],
      'properties': <String, Object?>{
        'id': <String, Object?>{'type': 'integer', 'description': '便签整数 ID。'},
        'title': <String, Object?>{'type': 'string'},
        'content': <String, Object?>{'type': 'string'},
        'command_id': <String, Object?>{'type': 'string'},
      },
    },
  ),
  McpToolSpec(
    name: 'trash_note',
    title: '将便签移入回收站',
    description: '将指定便签软删除移入 30 天回收站。',
    tier: McpToolTier.full,
    readOnlyHint: false,
    destructiveHint: true,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['id'],
      'properties': <String, Object?>{
        'id': <String, Object?>{'type': 'integer', 'description': '便签整数 ID。'},
        'command_id': <String, Object?>{'type': 'string'},
      },
    },
  ),
  McpToolSpec(
    name: 'upsert_budget',
    title: '设置或更新总预算/分类预算',
    description:
        '按账本与周期（YYYY-M 月预算或 YYYY 年预算）设置总预算或分类预算，支出分类预算之和超总预算时自动联动上调总预算。',
    tier: McpToolTier.full,
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['amount'],
      'properties': <String, Object?>{
        'book': <String, Object?>{
          'type': 'string',
          'description': '账本 ID 或名称（默认当前账本）。',
        },
        'section': <String, Object?>{
          'type': 'string',
          'description':
              '预算周期："YYYY-M"（月预算，如 "2026-11"）或 "YYYY"（年预算）；省略时取当期月预算。',
        },
        'category': <String, Object?>{
          'type': 'string',
          'description': '分类 ID、名称或 "父>子"；省略时设置账本总预算。',
        },
        'budget_type': <String, Object?>{
          'type': 'string',
          'description': '可选类型：total(0) / expense(1) / saving(2)。',
        },
        'amount': <String, Object?>{
          'type': 'string',
          'description': '预算金额十进制字符串（>= 0，如 "3000.00"）。',
        },
        'auto_copy': <String, Object?>{
          'type': 'boolean',
          'description': '是否下期自动复制（默认 false）。',
        },
        'forward': <String, Object?>{
          'type': 'boolean',
          'description': '是否结余/超支自动结转（默认 false）。',
        },
        'command_id': <String, Object?>{'type': 'string'},
      },
    },
  ),
  McpToolSpec(
    name: 'delete_budget',
    title: '删除预算项',
    description: '按 budget_id 物理删除一条总预算或分类预算记录。',
    tier: McpToolTier.full,
    readOnlyHint: false,
    destructiveHint: true,
    idempotentHint: true,
    inputSchema: <String, Object?>{
      'type': 'object',
      'required': <String>['budget_id'],
      'properties': <String, Object?>{
        'budget_id': <String, Object?>{
          'type': 'integer',
          'description': '预算主键 budget_id。',
        },
        'command_id': <String, Object?>{'type': 'string'},
      },
    },
  ),
];

/// Returns tools visible under [tier].
List<McpToolSpec> mcpToolsForPermissionTier(McpPermissionTier tier) =>
    <McpToolSpec>[
      for (final spec in mcpToolCatalog)
        if (tier.allows(spec.tier)) spec,
    ];

/// Stateless MCP Streamable HTTP JSON-RPC 2.0 dispatcher over [AppDatabase] (`F-039`).
final class McpToolDispatcher {
  McpToolDispatcher(
    this.db, {
    LedgerService? ledgerService,
    AutoBillService? autoBillService,
    NoteService? noteService,
    WishService? wishService,
    BudgetService? budgetService,
    CatalogService? catalogService,
  }) : _ledger = ledgerService ?? LedgerService(db),
       _autoBill =
           autoBillService ??
           AutoBillService(
             db,
             ledgerService: ledgerService ?? LedgerService(db),
             bridge: InMemoryAutoBillBridge(),
           ),
       _notes = noteService ?? NoteService(db),
       _wishes = wishService ?? WishService(db),
       _budgets = budgetService ?? BudgetService(db),
       _catalog = catalogService ?? CatalogService(db),
       _queries = LedgerQueries(db);

  final AppDatabase db;
  final LedgerService _ledger;
  final AutoBillService _autoBill;
  final NoteService _notes;
  final WishService _wishes;
  final BudgetService _budgets;
  final CatalogService _catalog;
  final LedgerQueries _queries;

  static final Map<String, McpToolSpec> _specsByName = <String, McpToolSpec>{
    for (final spec in mcpToolCatalog) spec.name: spec,
  };

  /// Parses raw JSON text and dispatches a single JSON-RPC 2.0 message or batch.
  ///
  /// Returns `null` when the incoming message consists solely of JSON-RPC
  /// notifications (e.g. `notifications/initialized`), signaling HTTP `202 Accepted`.
  Future<Object?> dispatchRawJson(
    String rawBody, {
    required McpPermissionTier permissionTier,
  }) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(rawBody);
    } on FormatException catch (e) {
      return buildJsonRpcError(
        id: null,
        code: JsonRpcErrorCode.parseError,
        message: 'Parse error: ${e.message}',
      );
    }

    if (decoded is List) {
      if (decoded.isEmpty) {
        return buildJsonRpcError(
          id: null,
          code: JsonRpcErrorCode.invalidRequest,
          message: 'Invalid Request: empty batch',
        );
      }
      final responses = <Map<String, Object?>>[];
      for (final item in decoded) {
        final res = await dispatchDecoded(item, permissionTier: permissionTier);
        if (res != null) {
          responses.add(res);
        }
      }
      return responses.isEmpty ? null : responses;
    }

    return dispatchDecoded(decoded, permissionTier: permissionTier);
  }

  /// Dispatches a single decoded JSON-RPC 2.0 object.
  Future<Map<String, Object?>?> dispatchDecoded(
    Object? decoded, {
    required McpPermissionTier permissionTier,
  }) async {
    final validated = validateJsonRpcObject(decoded);
    if (!validated.isValid) {
      return validated.errorResponse;
    }
    final req = validated.request!;

    if (req.method == 'notifications/initialized' || req.isNotification) {
      return null;
    }

    try {
      switch (req.method) {
        case 'initialize':
          final requestedVersion = req.params['protocolVersion'] as String?;
          final negotiated = negotiateMcpProtocolVersion(requestedVersion);
          return buildJsonRpcResult(
            id: req.id,
            result: <String, Object?>{
              'protocolVersion': negotiated,
              'capabilities': <String, Object?>{
                'tools': <String, Object?>{'listChanged': false},
                'resources': <String, Object?>{},
              },
              'serverInfo': <String, Object?>{
                'name': 'tallyisle-mcp',
                'version': appVersionName,
              },
            },
          );

        case 'ping':
          return buildJsonRpcResult(id: req.id, result: <String, Object?>{});

        case 'tools/list':
          final allowed = mcpToolsForPermissionTier(permissionTier);
          return buildJsonRpcResult(
            id: req.id,
            result: <String, Object?>{
              'tools': <Object>[for (final t in allowed) t.toMcpJson()],
            },
          );

        case 'tools/call':
          return await _handleToolsCall(req, permissionTier: permissionTier);

        case 'resources/list':
          return buildJsonRpcResult(
            id: req.id,
            result: <String, Object?>{'resources': _resourceDefinitions},
          );

        case 'resources/read':
          return await _handleResourcesRead(req);

        default:
          return buildJsonRpcError(
            id: req.id,
            code: JsonRpcErrorCode.methodNotFound,
            message: 'Method not found: ${req.method}',
          );
      }
    } on Failure catch (f) {
      return buildJsonRpcError(
        id: req.id,
        code: JsonRpcErrorCode.invalidParams,
        message: f.message,
      );
    } catch (e) {
      return buildJsonRpcError(
        id: req.id,
        code: JsonRpcErrorCode.internalError,
        message: 'Internal server error',
      );
    }
  }

  static const List<Map<String, Object?>> _resourceDefinitions =
      <Map<String, Object?>>[
        <String, Object?>{
          'uri': 'tallyisle://overview',
          'name': '帐屿账本与净资产总览',
          'description': '当前激活账本、全部账本列表、实时净资产/总资产/总负债与当期收支概览',
          'mimeType': 'application/json',
        },
        <String, Object?>{
          'uri': 'tallyisle://books',
          'name': '账本列表',
          'description': '全部账本及其月起始日配置与当前激活状态',
          'mimeType': 'application/json',
        },
        <String, Object?>{
          'uri': 'tallyisle://assets',
          'name': '资产与负债账户列表',
          'description': '资金账户、信用账户与借入/借出账户实时余额（精确整数分与两位小数）',
          'mimeType': 'application/json',
        },
      ];

  Future<Map<String, Object?>> _handleResourcesRead(
    ValidatedJsonRpcRequest req,
  ) async {
    final uri = (req.params['uri'] as String?)?.trim() ?? '';
    if (uri.isEmpty) {
      return buildJsonRpcError(
        id: req.id,
        code: JsonRpcErrorCode.invalidParams,
        message: 'Invalid params: uri is required',
      );
    }
    final Map<String, Object?> payload;
    switch (uri) {
      case 'tallyisle://overview':
        payload = await _toolGetOverview(const <String, Object?>{});
      case 'tallyisle://books':
        payload = await _readBooksResource();
      case 'tallyisle://assets':
        payload = await _readAssetsResource();
      default:
        return buildJsonRpcError(
          id: req.id,
          code: JsonRpcErrorCode.invalidParams,
          message: 'Unknown resource URI: $uri',
        );
    }
    return buildJsonRpcResult(
      id: req.id,
      result: <String, Object?>{
        'contents': <Object>[
          <String, Object?>{
            'uri': uri,
            'mimeType': 'application/json',
            'text': jsonEncode(payload),
          },
        ],
      },
    );
  }

  Future<Map<String, Object?>> _handleToolsCall(
    ValidatedJsonRpcRequest req, {
    required McpPermissionTier permissionTier,
  }) async {
    final toolName = (req.params['name'] as String?)?.trim() ?? '';
    if (toolName.isEmpty) {
      return buildJsonRpcError(
        id: req.id,
        code: JsonRpcErrorCode.invalidParams,
        message: 'Invalid params: tool name is required',
      );
    }
    final rawArgs = req.params['arguments'];
    if (rawArgs != null && rawArgs is! Map) {
      return buildJsonRpcError(
        id: req.id,
        code: JsonRpcErrorCode.invalidParams,
        message: 'Invalid params: arguments must be an object',
      );
    }
    final args = rawArgs is Map
        ? <String, Object?>{
            for (final e in rawArgs.entries) '${e.key}': e.value,
          }
        : const <String, Object?>{};

    final spec = _specsByName[toolName];
    if (spec == null) {
      return buildJsonRpcError(
        id: req.id,
        code: JsonRpcErrorCode.invalidParams,
        message: 'Unknown tool: $toolName',
      );
    }

    if (!permissionTier.allows(spec.tier)) {
      final requiredTier = minimumTierForTool(spec.tier);
      return buildJsonRpcResult(
        id: req.id,
        result: _mcpToolErrorResult(
          '权限拒绝：工具 "$toolName" 需要「${requiredTier.label}」(${requiredTier.wireName}) 权限，'
          '当前服务权限档位为「${permissionTier.label}」(${permissionTier.wireName})。'
          '如需执行该操作，请在帐屿「MCP 服务」页面调高权限档位。',
        ),
      );
    }

    try {
      final data = await _executePermittedTool(toolName, args);
      return buildJsonRpcResult(
        id: req.id,
        result: _mcpToolSuccessResult(data),
      );
    } on Failure catch (f) {
      return buildJsonRpcResult(
        id: req.id,
        result: _mcpToolErrorResult(f.message),
      );
    } catch (_) {
      return buildJsonRpcResult(
        id: req.id,
        result: _mcpToolErrorResult('工具执行失败，请检查输入参数格式后重试。'),
      );
    }
  }

  Map<String, Object?> _mcpToolSuccessResult(Map<String, Object?> payload) =>
      <String, Object?>{
        'isError': false,
        'content': <Object>[
          <String, Object?>{'type': 'text', 'text': jsonEncode(payload)},
        ],
        'structuredContent': payload,
      };

  Map<String, Object?> _mcpToolErrorResult(String message) => <String, Object?>{
    'isError': true,
    'content': <Object>[
      <String, Object?>{'type': 'text', 'text': message},
    ],
  };

  Future<Map<String, Object?>> _executePermittedTool(
    String name,
    Map<String, Object?> args,
  ) => switch (name) {
    // Read
    'get_overview' => _toolGetOverview(args),
    'list_catalog' => _toolListCatalog(args),
    'query_records' => _toolQueryRecords(args),
    'get_record_detail' => _toolGetRecordDetail(args),
    'get_statistics' => _toolGetStatistics(args),
    'get_budgets' => _toolGetBudgets(args),
    'list_plans_and_notes' => _toolListPlansAndNotes(args),
    // Append
    'create_record' => _toolCreateRecord(args),
    'create_record_draft' => _toolCreateRecordDraft(args),
    'create_note' => _toolCreateNote(args),
    'create_wish' => _toolCreateWish(args),
    'create_category_or_tag' => _toolCreateCategoryOrTag(args),
    // Full
    'update_record' => _toolUpdateRecord(args),
    'record_refund' => _toolRecordRefund(args),
    'record_reimbursement' => _toolRecordReimbursement(args),
    'delete_record' => _toolDeleteRecord(args),
    'update_note' => _toolUpdateNote(args),
    'trash_note' => _toolTrashNote(args),
    'upsert_budget' => _toolUpsertBudget(args),
    'delete_budget' => _toolDeleteBudget(args),
    _ => Future<Map<String, Object?>>.error(
      Failure(FailureCode.validation, '未知工具：$name'),
    ),
  };

  // ===========================================================================
  // Resource Helpers
  // ===========================================================================

  Future<Map<String, Object?>> _readBooksResource() => guardDatabase(() async {
    final activeBookId = await _queries.getCurrentBookId();
    final books = await _queries.getBooks();
    return <String, Object?>{
      'active_book_id': activeBookId,
      'books': <Object>[
        for (final b in books)
          <String, Object?>{
            'id': b.id,
            'name': b.name,
            'start_day': b.startDay,
            'is_active': b.id == activeBookId,
          },
      ],
    };
  });

  Future<Map<String, Object?>> _readAssetsResource() => guardDatabase(() async {
    final assets = await _queries.getAssets();
    final currencies = await _queries.getCurrencies();
    final rates = RateTable({
      for (final c in currencies) c.code: c.rateToAnchor,
    });
    final overview = computeAssetOverview([
      for (final a in assets)
        OverviewAccount(
          id: a.id,
          type: a.type,
          subType: a.subType,
          balanceMinor: a.balanceMinor,
          isEffectiveAsset: a.isEffectiveAsset,
          status: a.status,
          currency: a.currency,
          creditInfo: a.creditInfo,
        ),
    ], rates);

    return <String, Object?>{
      'base_currency': baseCurrency,
      'overview': _serializeAssetOverview(overview),
      'accounts': <Object>[for (final a in assets) _serializeAsset(a)],
    };
  });

  // ===========================================================================
  // Read Tools (7)
  // ===========================================================================

  Future<Map<String, Object?>> _toolGetOverview(Map<String, Object?> args) =>
      guardDatabase(() async {
        final activeBookId = await _queries.getCurrentBookId();
        final books = await _queries.getBooks();
        final targetBook = await _resolveBook(_optStr(args['book']));

        final allAssets = await _queries.getAssets();
        final links = await _queries.getAssetBooks();
        final visibleAssets = _filterAssetsForBook(
          allAssets,
          links,
          targetBook.id,
        );
        final currencies = await _queries.getCurrencies();
        final rates = RateTable({
          for (final c in currencies) c.code: c.rateToAnchor,
        });

        final assetOverview = computeAssetOverview([
          for (final a in visibleAssets)
            OverviewAccount(
              id: a.id,
              type: a.type,
              subType: a.subType,
              balanceMinor: a.balanceMinor,
              isEffectiveAsset: a.isEffectiveAsset,
              status: a.status,
              currency: a.currency,
              creditInfo: a.creditInfo,
            ),
        ], rates);

        final nowDt = DateTime.fromMillisecondsSinceEpoch(db.nowMs()).toLocal();
        final period = BillingPeriod.containing(nowDt, targetBook.startDay);
        final periodRecords = await _queries.getRecords(
          targetBook.id,
          period.startMs,
          period.endMs,
        );
        final ie = aggregateIncomeExpense(
          periodRecords.map(statEntryOf),
          target: baseCurrency,
          scope: StatScope.home,
        );
        final drafts = await _autoBill.listDrafts();

        return <String, Object?>{
          'active_book_id': activeBookId,
          'selected_book': <String, Object?>{
            'id': targetBook.id,
            'name': targetBook.name,
            'start_day': targetBook.startDay,
          },
          'books': <Object>[
            for (final b in books)
              <String, Object?>{
                'id': b.id,
                'name': b.name,
                'start_day': b.startDay,
                'is_active': b.id == activeBookId,
              },
          ],
          'asset_overview': _serializeAssetOverview(assetOverview),
          'current_period': <String, Object?>{
            'section': period.monthlySection,
            'start_date': _formatDate(period.start),
            'end_date': _formatDate(period.end),
            'start_ms': period.startMs,
            'end_ms': period.endMs,
            'income_minor': ie.income.toString(),
            'income_decimal': Money.minor(ie.income).decimal,
            'expense_minor': ie.expense.toString(),
            'expense_decimal': Money.minor(ie.expense).decimal,
            'balance_minor': ie.balance.toString(),
            'balance_decimal': Money.minor(ie.balance).decimal,
            'income_count': ie.incomeCount,
            'expense_count': ie.expenseCount,
          },
          'pending_draft_count': drafts.length,
        };
      });

  Future<Map<String, Object?>> _toolListCatalog(
    Map<String, Object?> args,
  ) => guardDatabase(() async {
    final book = await _resolveBook(_optStr(args['book']));
    final includeHidden = _optBool(args['include_hidden']) ?? false;

    final rawCategories = await _queries.getCategories(book.id);
    final filteredCats = includeHidden
        ? rawCategories
        : rawCategories.where((c) => !c.isHide).toList(growable: false);

    List<Map<String, Object?>> buildTree(int catType) {
      final parents = filteredCats
          .where((c) => c.type == catType && c.parentCatId == noRef)
          .toList(growable: false);
      return <Map<String, Object?>>[
        for (final p in parents)
          <String, Object?>{
            'id': p.id,
            'name': p.name,
            'type': p.type,
            'is_hide': p.isHide,
            'children': <Object>[
              for (final child in filteredCats)
                if (child.parentCatId == p.id)
                  <String, Object?>{
                    'id': child.id,
                    'name': child.name,
                    'path': '${p.name}>${child.name}',
                    'type': child.type,
                    'parent_id': p.id,
                    'is_hide': child.isHide,
                  },
            ],
          },
      ];
    }

    final allAssets = await _queries.getAssets(includeArchived: includeHidden);
    final links = await _queries.getAssetBooks();
    final visibleAssets = _filterAssetsForBook(allAssets, links, book.id);

    final allTags =
        await (db.select(db.tags)..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.tagId),
            ]))
            .get();
    final visibleTags = includeHidden
        ? allTags
        : allTags.where((t) => !t.hidden).toList(growable: false);

    final currencies = await _queries.getCurrencies();

    return <String, Object?>{
      'book': <String, Object?>{
        'id': book.id,
        'name': book.name,
        'start_day': book.startDay,
      },
      'categories': <String, Object?>{
        'expense': buildTree(RecordType.expense),
        'income': buildTree(RecordType.income),
      },
      'accounts': <Object>[for (final a in visibleAssets) _serializeAsset(a)],
      'tags': <Object>[
        for (final t in visibleTags)
          <String, Object?>{
            'tag_id': t.tagId,
            'name': t.name,
            'is_group': t.parent == 1,
            'parent_tag_id':
                (t.parentTagId == null ||
                    t.parentTagId!.isEmpty ||
                    t.parentTagId == '-1')
                ? null
                : t.parentTagId,
            'hidden': t.hidden,
            'color': t.color,
          },
      ],
      'currencies': <Object>[
        for (final c in currencies)
          <String, Object?>{
            'code': c.code,
            'name': c.name,
            'symbol': c.symbol,
            'rate_to_anchor': c.rateToAnchor,
            'anchor_code': c.anchorCode,
            'enable': c.enable,
          },
      ],
    };
  });

  Future<Map<String, Object?>> _toolQueryRecords(
    Map<String, Object?> args,
  ) => guardDatabase(() async {
    final allBooks = _optBool(args['all_books']) ?? false;
    final AccountBook? targetBook = allBooks && _optStr(args['book']) == null
        ? null
        : await _resolveBook(_optStr(args['book']));

    final startMs = _parseFilterDateBound(
      args['start_date'],
      isEndOfDay: false,
    );
    final endMs = _parseFilterDateBound(args['end_date'], isEndOfDay: true);
    final filterType = _parseOptionalRecordType(args['type']);
    final minMinor = _parseOptionalMoneyMinor(args['min_amount']);
    final maxMinor = _parseOptionalMoneyMinor(args['max_amount']);
    final rawLimit = _optInt(args['limit']) ?? 50;
    final limit = rawLimit.clamp(1, 200);
    final offset = (_optInt(args['offset']) ?? 0) < 0
        ? 0
        : (_optInt(args['offset']) ?? 0);

    final books = await _queries.getBooks();
    final bookById = <int, AccountBook>{for (final b in books) b.id: b};
    final allCats = await db.select(db.recordCategories).get();
    final catById = <int, RecordCategory>{for (final c in allCats) c.id: c};
    final allAssets = await _queries.getAssets();
    final assetById = <int, Asset>{for (final a in allAssets) a.id: a};
    final allTags = await db.select(db.tags).get();
    final tagById = <String, Tag>{for (final t in allTags) t.tagId: t};

    Set<int>? allowedCategoryIds;
    final catRef = _optStr(args['category']);
    if (catRef != null) {
      final scopedCats = targetBook == null
          ? allCats
          : allCats
                .where((c) => c.accountBookId == targetBook.id)
                .toList(growable: false);
      final matched = matchCategoryByRef(scopedCats, catRef);
      if (matched == null) {
        allowedCategoryIds = const <int>{};
      } else if (matched.parentCatId == noRef) {
        allowedCategoryIds = <int>{
          matched.id,
          for (final c in scopedCats)
            if (c.parentCatId == matched.id) c.id,
        };
      } else {
        allowedCategoryIds = <int>{matched.id};
      }
    }

    int? filterAssetId;
    final assetRef = _optStr(args['asset']);
    if (assetRef != null) {
      final numId = int.tryParse(assetRef);
      final lower = assetRef.toLowerCase();
      final hit = numId != null
          ? assetById[numId]
          : allAssets
                .where((a) => a.name.trim().toLowerCase() == lower)
                .firstOrNull;
      if (hit == null) {
        return <String, Object?>{
          'total_count': 0,
          'limit': limit,
          'offset': offset,
          'has_more': false,
          'records': const <Object>[],
        };
      }
      filterAssetId = hit.id;
    }

    Set<String>? filterTagIds;
    final tagRef = _optStr(args['tag']);
    if (tagRef != null) {
      final lower = tagRef.toLowerCase();
      final hit =
          tagById[tagRef] ??
          allTags
              .where((t) => t.name.trim().toLowerCase() == lower)
              .firstOrNull;
      if (hit == null) {
        return <String, Object?>{
          'total_count': 0,
          'limit': limit,
          'offset': offset,
          'has_more': false,
          'records': const <Object>[],
        };
      }
      filterTagIds = <String>{
        hit.tagId,
        if (hit.parent == 1)
          for (final child in allTags)
            if (child.parentTagId == hit.tagId) child.tagId,
      };
    }

    final q = db.select(db.records);
    q.where((t) {
      Expression<bool> cond = const Constant(true);
      if (targetBook != null) {
        cond = cond & t.accountBookId.equals(targetBook.id);
      }
      if (startMs != null) {
        cond = cond & t.recordTime.isBiggerOrEqualValue(startMs);
      }
      if (endMs != null) {
        cond = cond & t.recordTime.isSmallerOrEqualValue(endMs);
      }
      if (filterType != null) {
        cond = cond & t.type.equals(filterType);
      }
      if (filterAssetId != null) {
        cond =
            cond &
            (t.assetId.equals(filterAssetId) |
                t.fromAssetId.equals(filterAssetId) |
                t.toAssetId.equals(filterAssetId));
      }
      return cond;
    });
    q.orderBy([
      (t) => OrderingTerm.desc(t.recordTime),
      (t) => OrderingTerm.desc(t.createDate),
      (t) => OrderingTerm.desc(t.recordId),
    ]);

    final candidates = await q.get();
    final allTagLinks = await db.select(db.tagRecords).get();
    final recordTagMap = <String, List<String>>{};
    for (final tr in allTagLinks) {
      recordTagMap.putIfAbsent(tr.recordId, () => <String>[]).add(tr.tagId);
    }

    final keywordLower = _optStr(args['keyword'])?.toLowerCase();
    final matchedRecords = <LedgerRecord>[];

    for (final r in candidates) {
      if (allowedCategoryIds != null &&
          !allowedCategoryIds.contains(r.recordCatId)) {
        continue;
      }
      final absMinor = r.moneyMinor.abs();
      if (minMinor != null && absMinor < minMinor) continue;
      if (maxMinor != null && absMinor > maxMinor) continue;

      final rTags = recordTagMap[r.recordId] ?? const <String>[];
      if (filterTagIds != null && !rTags.any(filterTagIds.contains)) {
        continue;
      }

      if (keywordLower != null && keywordLower.isNotEmpty) {
        final catPath = _categoryPathLabel(r.recordCatId, catById);
        final a1 = assetById[r.assetId]?.name ?? '';
        final af = assetById[r.fromAssetId]?.name ?? '';
        final at = assetById[r.toAssetId]?.name ?? '';
        final tagText = rTags.map((tid) => tagById[tid]?.name ?? '').join(' ');
        final haystack = '${r.remark} $catPath $a1 $af $at $tagText'
            .toLowerCase();
        if (!haystack.contains(keywordLower)) continue;
      }

      matchedRecords.add(r);
    }

    final totalCount = matchedRecords.length;
    final page = offset >= totalCount
        ? const <LedgerRecord>[]
        : matchedRecords.skip(offset).take(limit).toList(growable: false);

    return <String, Object?>{
      'total_count': totalCount,
      'limit': limit,
      'offset': offset,
      'has_more': offset + page.length < totalCount,
      'records': <Object>[
        for (final r in page)
          _serializeRecordSummary(
            r,
            bookById: bookById,
            catById: catById,
            assetById: assetById,
            tagIds: recordTagMap[r.recordId] ?? const <String>[],
            tagById: tagById,
          ),
      ],
    };
  });

  Future<Map<String, Object?>> _toolGetRecordDetail(
    Map<String, Object?> args,
  ) => guardDatabase(() async {
    final recordId = _reqStr(args['record_id'], 'record_id');
    final record = await _queries.getRecord(recordId);
    if (record == null) {
      throw Failure(FailureCode.validation, '找不到账单：$recordId');
    }

    final books = await _queries.getBooks();
    final bookById = <int, AccountBook>{for (final b in books) b.id: b};
    final allCats = await db.select(db.recordCategories).get();
    final catById = <int, RecordCategory>{for (final c in allCats) c.id: c};
    final allAssets = await _queries.getAssets();
    final assetById = <int, Asset>{for (final a in allAssets) a.id: a};
    final tagRows = await (db.select(
      db.tagRecords,
    )..where((t) => t.recordId.equals(recordId))).get();
    final allTags = await db.select(db.tags).get();
    final tagById = <String, Tag>{for (final t in allTags) t.tagId: t};

    final extra = RecordExtra.parse(record.extraInfo);
    final rel = RecordRelations.parse(record.relInfo);
    final feeChild = record.type == RecordType.transfer
        ? await _queries.feeChildOf(recordId)
        : null;

    final refundDetails = <Map<String, Object?>>[];
    for (final link in rel.refunds?.children ?? const <LinkedBill>[]) {
      final childRec = await _queries.getRecord(link.billId);
      refundDetails.add(<String, Object?>{
        'bill_id': link.billId,
        'amount_minor': link.amount.toString(),
        'amount_decimal': Money.minor(link.amount).decimal,
        if (childRec != null) ...<String, Object?>{
          'record_time_ms': childRec.recordTime,
          'record_time': _formatEpochMs(childRec.recordTime),
          'asset_id': childRec.assetId,
          'asset_name': assetById[childRec.assetId]?.name,
          'remark': childRec.remark,
        },
      });
    }

    final reimburseDetails = <Map<String, Object?>>[];
    for (final link in rel.reimbursements?.children ?? const <LinkedBill>[]) {
      final childRec = await _queries.getRecord(link.billId);
      reimburseDetails.add(<String, Object?>{
        'bill_id': link.billId,
        'amount_minor': link.amount.toString(),
        'amount_decimal': Money.minor(link.amount).decimal,
        if (childRec != null) ...<String, Object?>{
          'record_time_ms': childRec.recordTime,
          'record_time': _formatEpochMs(childRec.recordTime),
          'asset_id': childRec.assetId,
          'asset_name': assetById[childRec.assetId]?.name,
          'remark': childRec.remark,
        },
      });
    }

    final loc = extra.location;
    final snap = extra.currency;
    final adv = extra.advance;
    List<String> images = const <String>[];
    try {
      images = parseRecordImages(record.images);
    } on Failure {
      images = const <String>[];
    }

    final summary = _serializeRecordSummary(
      record,
      bookById: bookById,
      catById: catById,
      assetById: assetById,
      tagIds: [for (final tr in tagRows) tr.tagId],
      tagById: tagById,
    );

    return <String, Object?>{
      ...summary,
      'currency_snapshot': snap?.toJson(),
      'advance_info': adv?.toJson(),
      'location': loc?.toJson(),
      'images': images,
      'refund_origin_id': rel.refunds?.originId,
      'refunds': refundDetails,
      'reimburse_origin_id': rel.reimbursements?.originId,
      'reimbursements': reimburseDetails,
      'transfer_fee_child': feeChild == null
          ? null
          : _serializeRecordSummary(
              feeChild,
              bookById: bookById,
              catById: catById,
              assetById: assetById,
              tagIds: const <String>[],
              tagById: tagById,
            ),
    };
  });

  Future<Map<String, Object?>> _toolGetStatistics(
    Map<String, Object?> args,
  ) => guardDatabase(() async {
    final allBooks = _optBool(args['all_books']) ?? false;
    final includeExcludeBudget =
        _optBool(args['include_exclude_budget']) ?? true;
    final book = await _resolveBook(_optStr(args['book']));

    final nowDt = DateTime.fromMillisecondsSinceEpoch(db.nowMs()).toLocal();
    final defaultPeriod = BillingPeriod.containing(nowDt, book.startDay);
    final startMs =
        _parseFilterDateBound(args['start_date'], isEndOfDay: false) ??
        defaultPeriod.startMs;
    final endMs =
        _parseFilterDateBound(args['end_date'], isEndOfDay: true) ??
        defaultPeriod.endMs;
    if (endMs < startMs) {
      throw const Failure(FailureCode.validation, '结束日期不能早于起始日期');
    }
    final period = BillingPeriod.custom(
      DateTime.fromMillisecondsSinceEpoch(startMs),
      DateTime.fromMillisecondsSinceEpoch(endMs),
    );

    final q = db.select(db.records)
      ..where((t) {
        Expression<bool> cond =
            t.recordTime.isBetweenValues(startMs, endMs) &
            t.type.equals(RecordType.reimburseReceipt).not() &
            t.type.equals(RecordType.balanceAdjust).not();
        if (!allBooks) {
          cond = cond & t.accountBookId.equals(book.id);
        }
        return cond;
      });
    final rows = await q.get();

    final ie = aggregateIncomeExpense(
      rows.map(statEntryOf),
      target: baseCurrency,
      scope: StatScope(
        includeBalanceAdjust: false,
        honourExcludeExIn: true,
        honourExcludeBudget: !includeExcludeBudget,
      ),
    );

    final catRows = allBooks
        ? await db.select(db.recordCategories).get()
        : await _queries.getCategories(book.id);
    final catMetaMap = <int, CategoryMeta>{
      for (final c in catRows)
        c.id: CategoryMeta(
          id: c.id,
          name: c.name,
          icon: c.icon,
          type: c.type,
          parentCatId: c.parentCatId,
          sort: c.sort,
          accountBookId: c.accountBookId,
        ),
    };

    final allTagLinks = await db.select(db.tagRecords).get();
    final recordTagIds = <String, List<String>>{};
    for (final tr in allTagLinks) {
      recordTagIds.putIfAbsent(tr.recordId, () => <String>[]).add(tr.tagId);
    }

    final statEntries = <CategoryStatEntry>[
      for (final r in rows)
        CategoryStatEntry(
          recordId: r.recordId,
          accountBookId: r.accountBookId,
          recordTime: r.recordTime,
          type: r.type,
          subType: r.subType,
          moneyMinor: r.moneyMinor,
          discountMinor: r.discountMinor,
          recordCatId: r.recordCatId,
          assetId: r.assetId,
          fromAssetId: r.fromAssetId,
          toAssetId: r.toAssetId,
          currency: RecordExtra.parse(r.extraInfo).currency,
          relations: RecordRelations.parse(r.relInfo),
          excludeExIn: r.excludeExIn,
          excludeBudget: r.excludeBudget,
          remark: r.remark,
          tagIds: recordTagIds[r.recordId] ?? const <String>[],
          createDate: r.createDate,
        ),
    ];

    final expCatStats = aggregateCategoryStats(
      entries: statEntries,
      categories: catMetaMap,
      period: period,
      dimension: StatDimension.expense,
      now: nowDt,
      includeExcludeBudget: includeExcludeBudget,
      rangeKind: StatRangeKind.custom,
      targetCurrency: baseCurrency,
    );
    final incCatStats = aggregateCategoryStats(
      entries: statEntries,
      categories: catMetaMap,
      period: period,
      dimension: StatDimension.income,
      now: nowDt,
      includeExcludeBudget: includeExcludeBudget,
      rangeKind: StatRangeKind.custom,
      targetCurrency: baseCurrency,
    );

    final tagRows = await db.select(db.tags).get();
    final tagMetas = <TagStatMeta>[
      for (final t in tagRows)
        TagStatMeta(
          tagId: t.tagId,
          name: t.name,
          parentId: t.parentTagId,
          isGroup: t.parent == 1,
          color: t.color,
          sort: t.sort,
          hidden: t.hidden,
        ),
    ];
    final expTagRank = computeTagRankings(
      entries: statEntries,
      recordTagIds: recordTagIds,
      tags: tagMetas,
      bucket: StatBucket.expense,
      includeExcludeBudget: includeExcludeBudget,
      targetCurrency: baseCurrency,
    );
    final incTagRank = computeTagRankings(
      entries: statEntries,
      recordTagIds: recordTagIds,
      tags: tagMetas,
      bucket: StatBucket.income,
      includeExcludeBudget: includeExcludeBudget,
      targetCurrency: baseCurrency,
    );

    List<Map<String, Object?>> serializeCatRows(List<CategoryRowItem> list) {
      return <Map<String, Object?>>[
        for (final item in list)
          <String, Object?>{
            'category_id': item.categoryId,
            'name': item.name,
            'money_minor': item.moneyMinor.toString(),
            'decimal': Money.minor(item.moneyMinor).decimal,
            'count': item.count,
            'ratio_basis_points': item.ratioBasisPoints,
            'ratio_text': item.ratioText,
            if (item.children.isNotEmpty)
              'children': <Object>[
                for (final c in item.children)
                  <String, Object?>{
                    'category_id': c.categoryId,
                    'name': c.name,
                    'money_minor': c.moneyMinor.toString(),
                    'decimal': Money.minor(c.moneyMinor).decimal,
                    'count': c.count,
                    'ratio_text': c.ratioText,
                  },
              ],
          },
      ];
    }

    List<Map<String, Object?>> serializeTagRows(List<TagRankingItem> list) {
      return <Map<String, Object?>>[
        for (final item in list)
          <String, Object?>{
            'tag_id': item.tagId,
            'name': item.name,
            'parent_name': item.parentName,
            'money_minor': item.moneyMinor.toString(),
            'decimal': Money.minor(item.moneyMinor).decimal,
            'count': item.count,
            'ratio_basis_points': item.ratioBasisPoints,
            'ratio_text': item.ratioText,
          },
      ];
    }

    return <String, Object?>{
      'scope': allBooks ? 'all_books' : book.name,
      'book_id': allBooks ? null : book.id,
      'start_ms': startMs,
      'end_ms': endMs,
      'start_date': _formatDate(DateTime.fromMillisecondsSinceEpoch(startMs)),
      'end_date': _formatDate(DateTime.fromMillisecondsSinceEpoch(endMs)),
      'summary': <String, Object?>{
        'income_minor': ie.income.toString(),
        'income_decimal': Money.minor(ie.income).decimal,
        'expense_minor': ie.expense.toString(),
        'expense_decimal': Money.minor(ie.expense).decimal,
        'balance_minor': ie.balance.toString(),
        'balance_decimal': Money.minor(ie.balance).decimal,
        'income_count': ie.incomeCount,
        'expense_count': ie.expenseCount,
        'daily_average_expense_minor': expCatStats.dailyAverageMinor.toString(),
        'daily_average_expense_decimal': Money.minor(
          expCatStats.dailyAverageMinor,
        ).decimal,
      },
      'category_stats': <String, Object?>{
        'expense': serializeCatRows(expCatStats.firstLevelRows),
        'income': serializeCatRows(incCatStats.firstLevelRows),
        if (expCatStats.uncategorizedRow != null)
          'uncategorized_expense_minor': expCatStats
              .uncategorizedRow!
              .moneyMinor
              .toString(),
      },
      'tag_stats': <String, Object?>{
        'expense': serializeTagRows(expTagRank.items),
        'income': serializeTagRows(incTagRank.items),
      },
    };
  });

  Future<Map<String, Object?>> _toolGetBudgets(
    Map<String, Object?> args,
  ) => guardDatabase(() async {
    final book = await _resolveBook(_optStr(args['book']));
    final rawSection = _optStr(args['section']);
    final (normalizedSection, period, mode) = await _resolveBudgetPeriod(
      book: book,
      rawSection: rawSection,
    );

    final budgetRows =
        await (db.select(db.budgets)
              ..where(
                (t) =>
                    t.bookId.equals(book.id) &
                    t.section.equals(normalizedSection),
              )
              ..orderBy([
                (t) => OrderingTerm.asc(t.budgetType),
                (t) => OrderingTerm.asc(t.sort),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();

    final periodRecords =
        await (db.select(db.records)..where(
              (t) =>
                  t.accountBookId.equals(book.id) &
                  t.recordTime.isBetweenValues(period.startMs, period.endMs) &
                  t.type.isNotIn(<int>[
                    RecordType.balanceAdjust,
                    RecordType.reimburseReceipt,
                  ]),
            ))
            .get();

    final recordInputs = <BudgetRecordInput>[
      for (final r in periodRecords)
        BudgetRecordInput(
          recordId: r.recordId,
          recordCatId: r.recordCatId,
          entry: statEntryOf(r),
        ),
    ];

    final dbCats = await _queries.getCategories(book.id);
    final catNodes = <BudgetCategoryNode>[
      for (final c in dbCats)
        BudgetCategoryNode(
          id: c.id,
          name: c.name,
          icon: c.icon,
          type: c.type,
          parentCatId: c.parentCatId,
        ),
    ];
    final catNodeById = <int, BudgetCategoryNode>{
      for (final n in catNodes) n.id: n,
    };

    Map<String, Object?> serializeUsage(
      Budget row,
      BudgetUsage usage, {
      String? categoryName,
    }) {
      final extra = BudgetExtra.fromJson(
        row.extraInfo,
        fallbackAmountMinor: row.amountMinor,
      );
      final bp = usage.amountMinor <= BigInt.zero
          ? (usage.displayUsedMinor > BigInt.zero ? 10000 : 0)
          : divideRounded(
              usage.displayUsedMinor * BigInt.from(10000),
              usage.amountMinor,
              RoundingMode.halfUp,
            ).toInt();
      return <String, Object?>{
        'budget_id': row.id,
        'budget_type': row.budgetType,
        'category_id': row.recordCatId,
        'category_name': categoryName,
        'amount_minor': usage.amountMinor.toString(),
        'amount_decimal': Money.minor(usage.amountMinor).decimal,
        'used_minor': usage.displayUsedMinor.toString(),
        'used_decimal': Money.minor(usage.displayUsedMinor).decimal,
        'remaining_minor': usage.remainingMinor.toString(),
        'remaining_decimal': Money.minor(usage.remainingMinor).decimal,
        'is_overspent': usage.isOverspent,
        'usage_basis_points': bp,
        'usage_percent_text': formatBasisPoints(bp),
        'bill_count': usage.billCount,
        'auto_copy': extra.autoCopy,
        'forward': extra.forward,
      };
    }

    Map<String, Object?>? totalMap;
    final catBudgets = <Map<String, Object?>>[];
    for (final row in budgetRows) {
      if (row.budgetType == BudgetTypeCode.total && row.recordCatId == noRef) {
        final usage = computeTotalBudgetUsage(
          amountMinor: row.amountMinor,
          budgetId: row.id,
          records: recordInputs,
        );
        totalMap = serializeUsage(row, usage);
      } else {
        final node =
            catNodeById[row.recordCatId] ??
            BudgetCategoryNode(
              id: row.recordCatId,
              name: '未知分类',
              type: row.budgetType == BudgetTypeCode.savingCategory ? 1 : 0,
            );
        final usage = computeCategoryBudgetUsage(
          category: node,
          allCategories: catNodes,
          amountMinor: row.amountMinor,
          budgetId: row.id,
          budgetType: row.budgetType,
          records: recordInputs,
        );
        catBudgets.add(serializeUsage(row, usage, categoryName: node.name));
      }
    }

    return <String, Object?>{
      'book_id': book.id,
      'book_name': book.name,
      'mode': mode.name,
      'section': normalizedSection,
      'period_start_date': _formatDate(period.start),
      'period_end_date': _formatDate(period.end),
      'total_budget': totalMap,
      'category_budgets': catBudgets,
    };
  });

  Future<Map<String, Object?>> _toolListPlansAndNotes(
    Map<String, Object?> args,
  ) => guardDatabase(() async {
    final allBooks = _optBool(args['all_books']) ?? false;
    final book = await _resolveBook(_optStr(args['book']));

    // 1. Pending reimbursable bills
    final reimbQuery = db.select(db.records)
      ..where((t) {
        Expression<bool> cond = t.type.isIn(<int>[
          RecordType.reimbursable,
          RecordType.reimburseReceipt,
        ]);
        if (!allBooks) {
          cond = cond & t.accountBookId.equals(book.id);
        }
        return cond;
      });
    final reimbRows = await reimbQuery.get();
    final allAssets = await _queries.getAssets();
    final assetById = <int, Asset>{for (final a in allAssets) a.id: a};
    final currencies = await _queries.getCurrencies();
    final rates = RateTable({
      for (final c in currencies) c.code: c.rateToAnchor,
    });

    final reimbBills = <ReimburseBillInput>[];
    final liveReceipts = <String, ReimburseReceiptInput>{};
    for (final r in reimbRows) {
      if (r.type == RecordType.reimbursable) {
        final fundId = r.fromAssetId != noRef ? r.fromAssetId : r.assetId;
        reimbBills.add(
          ReimburseBillInput(
            recordId: r.recordId,
            bookId: r.accountBookId,
            moneyMinor: r.moneyMinor,
            recordTime: r.recordTime,
            createDate: r.createDate,
            categoryId: r.recordCatId,
            assetId: r.assetId,
            fromAssetId: r.fromAssetId,
            remark: r.remark,
            relInfo: r.relInfo,
            extraInfo: r.extraInfo,
            fallbackCurrencyCode: assetById[fundId]?.currency,
          ),
        );
      } else if (r.type == RecordType.reimburseReceipt) {
        liveReceipts[r.recordId] = ReimburseReceiptInput(
          recordId: r.recordId,
          moneyMinor: r.moneyMinor,
          recordTime: r.recordTime,
          assetId: r.assetId,
          remark: r.remark,
          relInfo: r.relInfo,
          extraInfo: r.extraInfo,
        );
      }
    }
    final reimbOverview = computeReimburseOverview(
      reimbBills,
      liveReceipts: liveReceipts,
      rates: rates,
    );

    // 2. Debts (asset.type == 4)
    final links = await _queries.getAssetBooks();
    final boundBooks = <int, Set<int>>{};
    for (final l in links) {
      boundBooks.putIfAbsent(l.assetId, () => <int>{}).add(l.bookId);
    }
    final debts = allAssets
        .where(
          (a) =>
              a.type == AssetType.debt &&
              isDebtVisibleInBook(
                boundBookIds: boundBooks[a.id] ?? const <int>{},
                queryBookId: allBooks ? null : book.id,
              ),
        )
        .toList(growable: false);

    // 3. Installments
    final instQuery = db.select(db.installments);
    if (!allBooks) {
      instQuery.where((t) => t.bookId.equals(book.id));
    }
    final installments = await instQuery.get();

    // 4. Periodic rules
    final periodQuery = db.select(db.recordPeriods);
    if (!allBooks) {
      periodQuery.where((t) => t.bookId.equals(book.id));
    }
    final periodicRules = await periodQuery.get();

    // 5. Savings plans
    final savingsQuery = db.select(db.moneySavePlans);
    if (!allBooks) {
      savingsQuery.where(
        (t) => t.bookId.equals(book.id) | t.bookId.equals(noRef),
      );
    }
    final savingsPlans = await savingsQuery.get();

    // 6. Active notes & Wishes
    final activeNotes = await _notes.getActiveNotes();
    final unrealizedWishes = await _wishes.getUnrealizedWishes();
    final realizedWishes = await _wishes.getRealizedWishes();

    return <String, Object?>{
      'pending_reimbursements': <String, Object?>{
        'pending_count': reimbOverview.pendingCount,
        'pending_total_minor': reimbOverview.pendingTotalMinor.toString(),
        'pending_total_decimal': Money.minor(
          reimbOverview.pendingTotalMinor,
        ).decimal,
        'items': <Object>[
          for (final item in reimbOverview.pendingItems)
            <String, Object?>{
              'record_id': item.recordId,
              'book_id': item.bookId,
              'currency': item.currencyCode,
              'origin_minor': item.originMinor.toString(),
              'origin_decimal': Money.minor(
                item.originMinor,
                item.currencyCode,
              ).decimal,
              'reimbursed_minor': item.reimbursedMinor.toString(),
              'remaining_minor': item.remainingMinor.toString(),
              'remaining_decimal': Money.minor(
                item.remainingMinor,
                item.currencyCode,
              ).decimal,
              'remark': item.remark,
              'record_time': _formatEpochMs(item.recordTime),
            },
        ],
      },
      'debts': <Object>[
        for (final d in debts)
          <String, Object?>{
            'id': d.id,
            'name': d.name,
            'direction': d.subType == AssetType.debtBorrow ? '借入' : '借出',
            'status': d.status == AssetStatus.settled ? 'settled' : 'active',
            'currency': normalizeCurrency(d.currency) ?? baseCurrency,
            'balance_minor': d.balanceMinor.toString(),
            'balance_decimal': Money.minor(
              d.balanceMinor,
              normalizeCurrency(d.currency) ?? baseCurrency,
            ).decimal,
            'remark': d.remark,
          },
      ],
      'installments': <Object>[
        for (final inst in installments)
          <String, Object?>{
            'id': inst.id,
            'name': inst.name,
            'book_id': inst.bookId,
            'asset_id': inst.assetId,
            'principal_minor': inst.principalMinor.toString(),
            'principal_decimal': Money.minor(inst.principalMinor).decimal,
            'charge_minor': inst.chargeMinor.toString(),
            'charge_decimal': Money.minor(inst.chargeMinor).decimal,
            'periods': inst.periods,
            'next_period': inst.nextPeriod,
            'next_period_date': _formatEpochMs(inst.nextPeriodDate),
          },
      ],
      'periodic_rules': <Object>[
        for (final p in periodicRules)
          <String, Object?>{
            'id': p.id,
            'book_id': p.bookId,
            'record_type': p.recordType,
            'record_type_name': RecordType.names[p.recordType] ?? '账单',
            'money_minor': p.moneyMinor.toString(),
            'money_decimal': Money.minor(p.moneyMinor).decimal,
            'period_type': PeriodType.labels[p.periodType] ?? '${p.periodType}',
            'state': PeriodState.labels[p.state] ?? '${p.state}',
            'remark': p.remark,
          },
      ],
      'savings_plans': <Object>[
        for (final s in savingsPlans)
          <String, Object?>{
            'id': s.id,
            'name': s.name,
            'plan_type': SavingsPlanType.labelOf(s.planType),
            'cycle_type': SavingsCycleType.labelOf(s.cycleType),
            'status': s.status == SavingsPlanStatus.archived
                ? 'archived'
                : 'active',
            'plan_money_minor': s.planMoneyMinor.toString(),
            'plan_money_decimal': Money.minor(s.planMoneyMinor).decimal,
            'saved_money_minor': s.savedMoneyMinor.toString(),
            'saved_money_decimal': Money.minor(s.savedMoneyMinor).decimal,
          },
      ],
      'active_notes': <Object>[
        for (final n in activeNotes)
          <String, Object?>{
            'id': n.id,
            'title': n.title,
            'content': n.content,
            'update_time_ms': n.updateTime,
            'update_time': _formatEpochMs(n.updateTime),
          },
      ],
      'wishes': <Object>[
        for (final w in <Wish>[...unrealizedWishes, ...realizedWishes])
          <String, Object?>{
            'id': w.id,
            'content': w.content,
            'value_minor': w.valueMinor.toString(),
            'value_decimal': Money.minor(w.valueMinor).decimal,
            'is_realized': w.isRealized,
            'target_date_ms': w.targetDate > 0 ? w.targetDate : null,
          },
      ],
    };
  });

  // ===========================================================================
  // Append Tools (5)
  // ===========================================================================

  Future<Map<String, Object?>> _toolCreateRecord(
    Map<String, Object?> args,
  ) async {
    final commandId = _resolveCommandId(args['command_id'], 'mcp-create-rec');
    final recordType = _parseCreateRecordType(args['type']);
    final book = await _resolveBook(_optStr(args['book']));

    final assets = await _queries.getAssets();
    final links = await _queries.getAssetBooks();

    final Asset? primaryAsset;
    final Asset? secondaryAsset;
    if (recordType == RecordType.transfer) {
      final fromRef = _optStr(args['from_asset'] ?? args['asset']);
      final toRef = _optStr(args['to_asset']);
      if (fromRef == null || toRef == null) {
        throw const Failure(
          FailureCode.validation,
          '转账必须提供有效的 from_asset（转出账户）与 to_asset（转入账户）',
        );
      }
      primaryAsset = _matchRequiredAsset(
        assets: assets,
        links: links,
        bookId: book.id,
        rawRef: fromRef,
        label: '转出账户',
      );
      secondaryAsset = _matchRequiredAsset(
        assets: assets,
        links: links,
        bookId: book.id,
        rawRef: toRef,
        label: '转入账户',
      );
    } else {
      final assetRef = _optStr(args['asset'] ?? args['from_asset']);
      primaryAsset = assetRef == null
          ? null
          : _matchRequiredAsset(
              assets: assets,
              links: links,
              bookId: book.id,
              rawRef: assetRef,
              label: '账户',
            );
      secondaryAsset = null;
    }

    final primaryCurrency =
        normalizeCurrency(primaryAsset?.currency) ?? baseCurrency;
    final money = _parseStrictMoney(
      args['amount'],
      fieldName: 'amount',
      currency: primaryCurrency,
    );
    if (money.units <= BigInt.zero &&
        recordType != RecordType.expense &&
        recordType != RecordType.income) {
      throw const Failure(FailureCode.validation, '金额须大于 0');
    }
    if (money.isNegative) {
      throw const Failure(FailureCode.validation, '金额不能为负数');
    }

    final discountRaw = _optStr(args['discount']);
    final discount = discountRaw == null
        ? null
        : _parseStrictMoney(
            discountRaw,
            fieldName: 'discount',
            currency: primaryCurrency,
          );

    final feeFromTarget = _optBool(args['fee_from_target']) ?? false;
    final feeRaw = _optStr(args['fee']);
    final feeCurrency = feeFromTarget
        ? (normalizeCurrency(secondaryAsset?.currency) ?? baseCurrency)
        : primaryCurrency;
    final fee = (recordType == RecordType.transfer && feeRaw != null)
        ? _parseStrictMoney(feeRaw, fieldName: 'fee', currency: feeCurrency)
        : null;

    final categoryId = await _resolveCategoryForWrite(
      book: book,
      recordType: recordType,
      categoryRef: _optStr(args['category']),
    );
    final tagIds = await _resolveTagRefs(args['tags']);
    final recordTimeMs = _parseTimestampOrNow(args['record_time']);
    final extra = await _buildWriteCurrencyExtra(
      recordType: recordType,
      netMoney: money,
      discount: discount,
      primaryAsset: primaryAsset,
      secondaryAsset: secondaryAsset,
    );

    final draft = RecordDraft(
      type: recordType,
      money: money,
      bookId: book.id,
      recordTime: recordTimeMs,
      categoryId: categoryId,
      assetId:
          (recordType == RecordType.transfer ||
              recordType == RecordType.reimbursable)
          ? noRef
          : (primaryAsset?.id ?? noRef),
      fromAssetId: recordType == RecordType.transfer
          ? primaryAsset!.id
          : (recordType == RecordType.reimbursable
                ? (primaryAsset?.id ?? noRef)
                : noRef),
      toAssetId: recordType == RecordType.transfer ? secondaryAsset!.id : noRef,
      remark: (_optStr(args['remark']) ?? ''),
      excludeBudget: _optBool(args['exclude_budget']) ?? false,
      excludeExIn: _optBool(args['exclude_ex_in']) ?? false,
      discount: discount,
      extra: extra,
      fee: fee,
      feeFromTarget: feeFromTarget,
      tagIds: tagIds,
    );

    final recordId = await _ledger.saveRecord(
      commandId: commandId,
      draft: draft,
    );
    final saved = await _queries.getRecord(recordId);
    final refreshedPrimary = primaryAsset == null
        ? null
        : await _queries.getAsset(primaryAsset.id);

    return <String, Object?>{
      'record_id': recordId,
      'book_id': book.id,
      'book_name': book.name,
      'type': recordType,
      'type_name': RecordType.names[recordType],
      'money_minor': (saved?.moneyMinor ?? money.storageMinor).toString(),
      'money_decimal': Money.minor(
        saved?.moneyMinor ?? money.storageMinor,
        primaryCurrency,
      ).decimal,
      'currency': primaryCurrency,
      if (refreshedPrimary != null) ...<String, Object?>{
        'asset_id': refreshedPrimary.id,
        'asset_name': refreshedPrimary.name,
        'asset_balance_minor': refreshedPrimary.balanceMinor.toString(),
        'asset_balance_decimal': Money.minor(
          refreshedPrimary.balanceMinor,
          primaryCurrency,
        ).decimal,
      },
    };
  }

  Future<Map<String, Object?>> _toolCreateRecordDraft(
    Map<String, Object?> args,
  ) async {
    final commandId = _resolveCommandId(args['command_id'], 'mcp-create-draft');
    final recordType = _parseCreateRecordType(args['type']);
    if (recordType != RecordType.expense &&
        recordType != RecordType.income &&
        recordType != RecordType.transfer) {
      throw const Failure(
        FailureCode.validation,
        '待确认草稿仅支持支出(expense)、收入(income)或转账(transfer)',
      );
    }

    final money = _parseStrictMoney(args['amount'], fieldName: 'amount');
    if (money.units <= BigInt.zero) {
      throw const Failure(FailureCode.validation, '草稿金额须大于 0');
    }
    final discountRaw = _optStr(args['discount']);
    final discount = discountRaw == null
        ? null
        : _parseStrictMoney(discountRaw, fieldName: 'discount');

    final book = await _resolveBook(_optStr(args['book']));
    final catRef = _optStr(args['category']);
    int? resolvedCatId;
    if (catRef != null && recordType != RecordType.transfer) {
      final cats = await _queries.getCategories(book.id);
      final dirCats = cats
          .where((c) => c.type == recordType)
          .toList(growable: false);
      resolvedCatId = matchCategoryByRef(dirCats, catRef)?.id;
    }

    final assets = await _queries.getAssets();
    final links = await _queries.getAssetBooks();
    final assetRef = _optStr(args['asset'] ?? args['from_asset']);
    final toAssetRef = _optStr(args['to_asset']);
    final resolvedAsset = assetRef == null
        ? null
        : (matchFundingAssetByRef(
                assets: assets,
                links: links,
                bookId: book.id,
                rawRef: assetRef,
              ) ??
              matchFundingAssetByHint(
                assets: assets,
                links: links,
                bookId: book.id,
                rawHint: assetRef,
              ));
    final resolvedToAsset = toAssetRef == null
        ? null
        : (matchFundingAssetByRef(
                assets: assets,
                links: links,
                bookId: book.id,
                rawRef: toAssetRef,
              ) ??
              matchFundingAssetByHint(
                assets: assets,
                links: links,
                bookId: book.id,
                rawHint: toAssetRef,
              ));

    final remark = _optStr(args['remark']);
    final sourceApp = _optStr(args['source_app']) ?? 'MCP AI';
    final recordTimeMs = _parseTimestampOrNow(args['record_time']);

    final draft = AutoBillDraft(
      recordType: recordType,
      money: money,
      discount: discount,
      recordTimeMs: recordTimeMs,
      sourceApp: sourceApp,
      remarks: remark == null ? const <String>[] : <String>[remark],
      accountHint1: assetRef,
      accountHint2: toAssetRef,
      categoryHint: catRef,
      bookId: book.id,
      categoryId: resolvedCatId,
      assetId: resolvedAsset?.id,
      toAssetId: resolvedToAsset?.id,
    );

    final draftId = await _autoBill.saveDraft(
      commandId: commandId,
      draft: draft,
    );
    return <String, Object?>{
      'draft_id': draftId,
      'status': 'pending_confirmation',
      'book_id': book.id,
      'type': recordType,
      'money_minor': money.storageMinor.toString(),
      'money_decimal': money.decimal,
      'remark': remark ?? '',
    };
  }

  Future<Map<String, Object?>> _toolCreateNote(
    Map<String, Object?> args,
  ) async {
    final commandId = _resolveCommandId(args['command_id'], 'mcp-create-note');
    final content = _reqStr(args['content'], 'content');
    final title = _optStr(args['title']);
    final id = await _notes.createNote(
      commandId: commandId,
      title: title,
      content: content,
    );
    return <String, Object?>{'id': id, 'title': title, 'content': content};
  }

  Future<Map<String, Object?>> _toolCreateWish(
    Map<String, Object?> args,
  ) async {
    final commandId = _resolveCommandId(args['command_id'], 'mcp-create-wish');
    final content = _reqStr(args['content'], 'content');
    final value = _parseStrictMoney(args['value'], fieldName: 'value');
    final targetDateRaw = _optStr(args['target_date']);
    final targetDate = targetDateRaw == null
        ? unsetWishTargetDate
        : _parseTimestampOrNow(targetDateRaw);
    final id = await _wishes.createWish(
      commandId: commandId,
      content: content,
      value: value,
      targetDate: targetDate,
    );
    return <String, Object?>{
      'id': id,
      'content': content,
      'value_minor': value.storageMinor.toString(),
      'value_decimal': value.decimal,
    };
  }

  Future<Map<String, Object?>> _toolCreateCategoryOrTag(
    Map<String, Object?> args,
  ) async {
    final commandId = _resolveCommandId(
      args['command_id'],
      'mcp-create-cat-tag',
    );
    final kind = _reqStr(args['kind'], 'kind').toLowerCase();
    final name = _reqStr(args['name'], 'name');

    if (kind == 'category') {
      final book = await _resolveBook(_optStr(args['book']));
      final catTypeRaw = _optStr(args['category_type'])?.toLowerCase();
      final catType =
          (catTypeRaw == 'income' || catTypeRaw == '收入' || catTypeRaw == '1')
          ? RecordType.income
          : RecordType.expense;
      var parentCatId = noRef;
      final parentRef = _optStr(args['parent_category']);
      if (parentRef != null) {
        final cats = await _queries.getCategories(book.id);
        final parents = cats
            .where((c) => c.type == catType && c.parentCatId == noRef)
            .toList(growable: false);
        final matchedParent = matchCategoryByRef(parents, parentRef);
        if (matchedParent == null) {
          throw Failure(FailureCode.validation, '找不到一级父分类：$parentRef');
        }
        parentCatId = matchedParent.id;
      }
      final id = await _catalog.createCategory(
        commandId: commandId,
        accountBookId: book.id,
        name: name,
        type: catType,
        parentCatId: parentCatId,
        colorFill: _optStr(args['color']),
      );
      return <String, Object?>{
        'kind': 'category',
        'id': id,
        'book_id': book.id,
        'name': name,
        'category_type': catType,
        'parent_id': parentCatId == noRef ? null : parentCatId,
      };
    }

    if (kind == 'tag') {
      final isGroup = _optBool(args['is_group']) ?? false;
      String? parentTagId;
      final parentTagRef = _optStr(args['parent_tag']);
      if (parentTagRef != null && !isGroup) {
        final allTags = await db.select(db.tags).get();
        final lower = parentTagRef.toLowerCase();
        final parentHit =
            allTags.where((t) => t.tagId == parentTagRef).firstOrNull ??
            allTags
                .where(
                  (t) => t.parent == 1 && t.name.trim().toLowerCase() == lower,
                )
                .firstOrNull;
        if (parentHit == null) {
          throw Failure(FailureCode.validation, '找不到父标签组：$parentTagRef');
        }
        parentTagId = parentHit.tagId;
      }
      final tagId = await _catalog.createTag(
        commandId: commandId,
        name: name,
        isGroup: isGroup,
        parentTagId: parentTagId,
        color: _optStr(args['color']),
      );
      return <String, Object?>{
        'kind': 'tag',
        'tag_id': tagId,
        'name': name,
        'is_group': isGroup,
        'parent_tag_id': parentTagId,
      };
    }

    throw Failure(
      FailureCode.validation,
      'kind 参数须为 "category" 或 "tag"，收到：$kind',
    );
  }

  // ===========================================================================
  // Full-Access Tools (8)
  // ===========================================================================

  static const Set<int> _editableRecordTypes = <int>{
    RecordType.expense,
    RecordType.income,
    RecordType.transfer,
    RecordType.reimbursable,
    RecordType.advanceIncome,
    RecordType.advanceExpense,
  };

  Future<Map<String, Object?>> _toolUpdateRecord(
    Map<String, Object?> args,
  ) async {
    final commandId = _resolveCommandId(args['command_id'], 'mcp-update-rec');
    final recordId = _reqStr(args['record_id'], 'record_id');
    final existing = await _queries.getRecord(recordId);
    if (existing == null) {
      throw Failure(FailureCode.validation, '找不到待编辑的账单：$recordId');
    }
    if (!_editableRecordTypes.contains(existing.type)) {
      throw Failure(
        FailureCode.validation,
        '${RecordType.names[existing.type] ?? existing.type}记录不支持通过普通改单修改',
      );
    }

    final nextType = args.containsKey('type') && args['type'] != null
        ? _parseCreateRecordType(args['type'])
        : existing.type;
    final book = args.containsKey('book') && _optStr(args['book']) != null
        ? await _resolveBook(_optStr(args['book']))
        : (await _queries.getBook(existing.accountBookId) ??
              await _resolveBook(null));

    final assets = await _queries.getAssets();
    final assetById = <int, Asset>{for (final a in assets) a.id: a};
    final links = await _queries.getAssetBooks();

    int nextAssetId = existing.assetId;
    int nextFromAssetId = existing.fromAssetId;
    int nextToAssetId = existing.toAssetId;

    if (nextType == RecordType.transfer) {
      nextAssetId = noRef;
      if (_optStr(args['from_asset'] ?? args['asset']) != null) {
        nextFromAssetId = _matchRequiredAsset(
          assets: assets,
          links: links,
          bookId: book.id,
          rawRef: _optStr(args['from_asset'] ?? args['asset'])!,
          label: '转出账户',
        ).id;
      }
      if (_optStr(args['to_asset']) != null) {
        nextToAssetId = _matchRequiredAsset(
          assets: assets,
          links: links,
          bookId: book.id,
          rawRef: _optStr(args['to_asset'])!,
          label: '转入账户',
        ).id;
      }
    } else if (nextType == RecordType.reimbursable) {
      nextAssetId = noRef;
      nextToAssetId = noRef;
      if (_optStr(args['from_asset'] ?? args['asset']) != null) {
        nextFromAssetId = _matchRequiredAsset(
          assets: assets,
          links: links,
          bookId: book.id,
          rawRef: _optStr(args['from_asset'] ?? args['asset'])!,
          label: '垫付账户',
        ).id;
      } else if (existing.type != RecordType.reimbursable &&
          existing.assetId != noRef) {
        nextFromAssetId = existing.assetId;
      }
    } else {
      nextFromAssetId = noRef;
      nextToAssetId = noRef;
      if (_optStr(args['asset']) != null) {
        nextAssetId = _matchRequiredAsset(
          assets: assets,
          links: links,
          bookId: book.id,
          rawRef: _optStr(args['asset'])!,
          label: '账户',
        ).id;
      } else if (existing.type == RecordType.reimbursable &&
          existing.fromAssetId != noRef) {
        nextAssetId = existing.fromAssetId;
      }
    }

    final primaryAsset =
        nextType == RecordType.transfer || nextType == RecordType.reimbursable
        ? assetById[nextFromAssetId]
        : assetById[nextAssetId];
    final secondaryAsset = nextType == RecordType.transfer
        ? assetById[nextToAssetId]
        : null;
    final primaryCurrency =
        normalizeCurrency(primaryAsset?.currency) ?? baseCurrency;

    final money = args.containsKey('amount') && args['amount'] != null
        ? _parseStrictMoney(
            args['amount'],
            fieldName: 'amount',
            currency: primaryCurrency,
          )
        : Money.minor(existing.moneyMinor, primaryCurrency);

    final Money? discount;
    if (args.containsKey('discount')) {
      final dStr = _optStr(args['discount']);
      discount = (dStr == null || dStr == '0' || dStr == '0.00')
          ? null
          : _parseStrictMoney(
              dStr,
              fieldName: 'discount',
              currency: primaryCurrency,
            );
    } else {
      discount = existing.discountMinor == null
          ? null
          : Money.minor(existing.discountMinor!, primaryCurrency);
    }

    final existingFee = nextType == RecordType.transfer
        ? await _queries.feeChildOf(recordId)
        : null;
    final existingRel = RecordRelations.parse(existing.relInfo);
    final feeFromTarget =
        _optBool(args['fee_from_target']) ??
        existingRel.transferFee?.feeFromTarget ??
        false;
    final feeCurrency = feeFromTarget
        ? (normalizeCurrency(secondaryAsset?.currency) ?? baseCurrency)
        : primaryCurrency;
    final Money? fee;
    if (nextType != RecordType.transfer) {
      fee = null;
    } else if (args.containsKey('fee')) {
      final fStr = _optStr(args['fee']);
      fee = (fStr == null || fStr == '0' || fStr == '0.00')
          ? null
          : _parseStrictMoney(fStr, fieldName: 'fee', currency: feeCurrency);
    } else {
      fee = existingFee == null
          ? null
          : Money.minor(existingFee.moneyMinor, feeCurrency);
    }

    final categoryId = nextType == RecordType.transfer
        ? noRef
        : (_optStr(args['category']) != null ||
              existing.accountBookId != book.id ||
              existing.recordCatId == noRef)
        ? await _resolveCategoryForWrite(
            book: book,
            recordType: nextType,
            categoryRef: _optStr(args['category']),
          )
        : existing.recordCatId;

    final List<String> tagIds;
    if (args.containsKey('tags')) {
      tagIds = await _resolveTagRefs(args['tags']);
    } else {
      final existingTags = await (db.select(
        db.tagRecords,
      )..where((t) => t.recordId.equals(recordId))).get();
      tagIds = [for (final t in existingTags) t.tagId];
    }

    final recordTimeMs =
        args.containsKey('record_time') && args['record_time'] != null
        ? _parseTimestampOrNow(args['record_time'])
        : existing.recordTime;
    final remark = args.containsKey('remark') && args['remark'] != null
        ? '${args['remark']}'
        : existing.remark;
    final excludeBudget =
        _optBool(args['exclude_budget']) ?? existing.excludeBudget;
    final excludeExIn = _optBool(args['exclude_ex_in']) ?? existing.excludeExIn;

    final existingExtra = RecordExtra.parse(existing.extraInfo);
    if (nextType == RecordType.transfer) {
      final secondaryCurrency =
          normalizeCurrency(secondaryAsset?.currency) ?? baseCurrency;
      if (primaryCurrency == baseCurrency &&
          secondaryCurrency == baseCurrency) {
        existingExtra.currency = null;
      } else if (existing.type == RecordType.transfer &&
          existing.fromAssetId == nextFromAssetId &&
          existing.toAssetId == nextToAssetId &&
          money.storageMinor == existing.moneyMinor &&
          existingExtra.currency != null &&
          existingExtra.currency!.isValid &&
          normalizeCurrency(existingExtra.currency!.sourceCode) ==
              primaryCurrency &&
          normalizeCurrency(existingExtra.currency!.assetCode) ==
              secondaryCurrency) {
        // L-07: Preserve historical FX snapshot on non-monetary transfer edits.
      } else {
        final freshExtra = await _buildWriteCurrencyExtra(
          recordType: nextType,
          netMoney: money,
          discount: discount,
          primaryAsset: primaryAsset,
          secondaryAsset: secondaryAsset,
        );
        existingExtra.currency = freshExtra.currency;
      }
    } else {
      final oldFundId = existing.type == RecordType.reimbursable
          ? existing.fromAssetId
          : existing.assetId;
      final newFundId = nextType == RecordType.reimbursable
          ? nextFromAssetId
          : nextAssetId;
      final oldDisc = existing.discountMinor ?? BigInt.zero;
      final newDisc =
          (nextType == RecordType.expense || nextType == RecordType.income)
          ? (discount?.storageMinor ?? BigInt.zero)
          : BigInt.zero;
      final keepExistingCurrency =
          existing.type != RecordType.transfer &&
          oldFundId == newFundId &&
          money.storageMinor == existing.moneyMinor &&
          oldDisc == newDisc;
      if (!keepExistingCurrency) {
        existingExtra.currency = null;
      }
    }

    final draft = RecordDraft(
      type: nextType,
      subType: existing.subType,
      money: money,
      bookId: book.id,
      recordTime: recordTimeMs,
      categoryId: categoryId,
      assetId: nextAssetId,
      fromAssetId: nextFromAssetId,
      toAssetId: nextToAssetId,
      remark: remark,
      excludeBudget: excludeBudget,
      excludeExIn: excludeExIn,
      discount: discount,
      extra: existingExtra,
      relations: existingRel,
      fee: fee,
      feeFromTarget: feeFromTarget,
      tagIds: tagIds,
    );

    await _ledger.saveRecord(
      commandId: commandId,
      recordId: recordId,
      draft: draft,
    );
    final updated = await _queries.getRecord(recordId);
    return <String, Object?>{
      'record_id': recordId,
      'updated': true,
      'money_minor': (updated?.moneyMinor ?? money.storageMinor).toString(),
      'money_decimal': Money.minor(
        updated?.moneyMinor ?? money.storageMinor,
        primaryCurrency,
      ).decimal,
      'remark': updated?.remark ?? remark,
    };
  }

  Future<Map<String, Object?>> _toolRecordRefund(
    Map<String, Object?> args,
  ) async {
    final commandId = _resolveCommandId(args['command_id'], 'mcp-refund');
    final originId = _reqStr(args['origin_id'], 'origin_id');
    final origin = await _queries.getRecord(originId);
    if (origin == null) {
      throw Failure(FailureCode.validation, '找不到原账单：$originId');
    }

    final assets = await _queries.getAssets();
    final links = await _queries.getAssetBooks();
    final assetRef = _optStr(args['asset']);
    final int targetAssetId;
    if (assetRef != null) {
      targetAssetId = _matchRequiredAsset(
        assets: assets,
        links: links,
        bookId: origin.accountBookId,
        rawRef: assetRef,
        label: '退款账户',
      ).id;
    } else {
      targetAssetId = origin.type == RecordType.reimbursable
          ? origin.fromAssetId
          : origin.assetId;
    }

    final targetAsset = assets.where((a) => a.id == targetAssetId).firstOrNull;
    final currency =
        normalizeCurrency(targetAsset?.currency) ??
        normalizeCurrency(
          RecordExtra.parse(origin.extraInfo).currency?.assetCode,
        ) ??
        baseCurrency;
    final amount = _parseStrictMoney(
      args['amount'],
      fieldName: 'amount',
      currency: currency,
    );
    final recordTime = _parseTimestampOrNow(args['record_time']);
    final remark = _optStr(args['remark']) ?? '';

    final refundRecordId = await _ledger.addRefund(
      commandId: commandId,
      originId: originId,
      amount: amount,
      assetId: targetAssetId,
      recordTime: recordTime,
      remark: remark,
    );
    return <String, Object?>{
      'refund_record_id': refundRecordId,
      'origin_id': originId,
      'amount_minor': amount.storageMinor.toString(),
      'amount_decimal': amount.decimal,
      'asset_id': targetAssetId == noRef ? null : targetAssetId,
    };
  }

  Future<Map<String, Object?>> _toolRecordReimbursement(
    Map<String, Object?> args,
  ) async {
    final commandId = _resolveCommandId(args['command_id'], 'mcp-reimburse');
    final originId = _reqStr(args['origin_id'], 'origin_id');
    final origin = await _queries.getRecord(originId);
    if (origin == null) {
      throw Failure(FailureCode.validation, '找不到原报销账单：$originId');
    }

    final assets = await _queries.getAssets();
    final links = await _queries.getAssetBooks();
    final assetRef = _optStr(args['asset']);
    final int targetAssetId;
    if (assetRef != null) {
      targetAssetId = _matchRequiredAsset(
        assets: assets,
        links: links,
        bookId: origin.accountBookId,
        rawRef: assetRef,
        label: '报销收款账户',
      ).id;
    } else {
      targetAssetId = origin.fromAssetId;
    }

    final targetAsset = assets.where((a) => a.id == targetAssetId).firstOrNull;
    final currency =
        normalizeCurrency(targetAsset?.currency) ??
        normalizeCurrency(
          RecordExtra.parse(origin.extraInfo).currency?.assetCode,
        ) ??
        baseCurrency;
    final amount = _parseStrictMoney(
      args['amount'],
      fieldName: 'amount',
      currency: currency,
    );
    final recordTime = _parseTimestampOrNow(args['record_time']);
    final remark = _optStr(args['remark']) ?? '';

    final receiptRecordId = await _ledger.addReimbursement(
      commandId: commandId,
      originId: originId,
      amount: amount,
      assetId: targetAssetId,
      recordTime: recordTime,
      remark: remark,
    );
    return <String, Object?>{
      'receipt_record_id': receiptRecordId,
      'origin_id': originId,
      'amount_minor': amount.storageMinor.toString(),
      'amount_decimal': amount.decimal,
      'asset_id': targetAssetId == noRef ? null : targetAssetId,
    };
  }

  Future<Map<String, Object?>> _toolDeleteRecord(
    Map<String, Object?> args,
  ) async {
    final commandId = _resolveCommandId(args['command_id'], 'mcp-delete-rec');
    final recordId = _reqStr(args['record_id'], 'record_id');
    await _ledger.deleteRecord(commandId: commandId, recordId: recordId);
    return <String, Object?>{'record_id': recordId, 'deleted': true};
  }

  Future<Map<String, Object?>> _toolUpdateNote(
    Map<String, Object?> args,
  ) async {
    final commandId = _resolveCommandId(args['command_id'], 'mcp-update-note');
    final id = _reqInt(args['id'], 'id');
    final content = _reqStr(args['content'], 'content');
    final existing = await _notes.getNote(id);
    if (existing == null) {
      throw const Failure(FailureCode.conflict, '便签不存在或已删除');
    }
    final title = args.containsKey('title')
        ? _optStr(args['title'])
        : existing.title;
    await _notes.updateNote(
      commandId: commandId,
      id: id,
      title: title,
      content: content,
    );
    return <String, Object?>{'id': id, 'updated': true};
  }

  Future<Map<String, Object?>> _toolTrashNote(Map<String, Object?> args) async {
    final commandId = _resolveCommandId(args['command_id'], 'mcp-trash-note');
    final id = _reqInt(args['id'], 'id');
    await _notes.moveToTrash(commandId: commandId, id: id);
    return <String, Object?>{'id': id, 'trashed': true};
  }

  Future<Map<String, Object?>> _toolUpsertBudget(
    Map<String, Object?> args,
  ) async {
    final commandId = _resolveCommandId(
      args['command_id'],
      'mcp-upsert-budget',
    );
    final book = await _resolveBook(_optStr(args['book']));
    final (normalizedSection, _, _) = await _resolveBudgetPeriod(
      book: book,
      rawSection: _optStr(args['section']),
    );
    final amount = _parseStrictMoney(args['amount'], fieldName: 'amount');
    if (amount.isNegative) {
      throw const Failure(FailureCode.validation, '预算金额不能为负');
    }
    final autoCopy = _optBool(args['auto_copy']) ?? false;
    final forward = _optBool(args['forward']) ?? false;

    final catRef = _optStr(args['category']);
    final typeHint = _optStr(args['budget_type'])?.toLowerCase();
    if (catRef == null &&
        (typeHint == null || typeHint == 'total' || typeHint == '0')) {
      final budgetId = await _budgets.upsertTotalBudget(
        commandId: commandId,
        bookId: book.id,
        section: normalizedSection,
        amountMinor: amount.storageMinor,
        autoCopy: autoCopy,
        forward: forward,
      );
      return <String, Object?>{
        'budget_id': budgetId,
        'book_id': book.id,
        'section': normalizedSection,
        'budget_type': BudgetTypeCode.total,
        'amount_minor': amount.storageMinor.toString(),
        'amount_decimal': amount.decimal,
      };
    }

    if (catRef == null) {
      throw const Failure(FailureCode.validation, '设置分类预算时必须指定 category');
    }
    final cats = await _queries.getCategories(book.id);
    final matchedCat = matchCategoryByRef(cats, catRef);
    if (matchedCat == null) {
      throw Failure(FailureCode.validation, '在账本“${book.name}”中找不到分类：$catRef');
    }
    final budgetType =
        (typeHint == 'saving' ||
            typeHint == '2' ||
            matchedCat.type == RecordType.income)
        ? BudgetTypeCode.savingCategory
        : BudgetTypeCode.expenseCategory;

    final budgetId = await _budgets.upsertCategoryBudget(
      commandId: commandId,
      bookId: book.id,
      section: normalizedSection,
      categoryId: matchedCat.id,
      budgetType: budgetType,
      amountMinor: amount.storageMinor,
      autoCopy: autoCopy,
      forward: forward,
    );
    return <String, Object?>{
      'budget_id': budgetId,
      'book_id': book.id,
      'section': normalizedSection,
      'budget_type': budgetType,
      'category_id': matchedCat.id,
      'category_name': matchedCat.name,
      'amount_minor': amount.storageMinor.toString(),
      'amount_decimal': amount.decimal,
    };
  }

  Future<Map<String, Object?>> _toolDeleteBudget(
    Map<String, Object?> args,
  ) async {
    final commandId = _resolveCommandId(
      args['command_id'],
      'mcp-delete-budget',
    );
    final budgetId = _reqInt(args['budget_id'], 'budget_id');
    await _budgets.deleteBudget(commandId: commandId, budgetId: budgetId);
    return <String, Object?>{'budget_id': budgetId, 'deleted': true};
  }

  // ===========================================================================
  // Internal Resolution & Formatting Helpers
  // ===========================================================================

  Future<AccountBook> _resolveBook(String? rawRef) async {
    final books = await _queries.getBooks();
    if (books.isEmpty) {
      throw const Failure(FailureCode.validation, '当前尚无可用账本');
    }
    if (rawRef != null && rawRef.trim().isNotEmpty) {
      final trimmed = rawRef.trim();
      final numId = int.tryParse(trimmed);
      if (numId != null) {
        final byId = books.where((b) => b.id == numId).firstOrNull;
        if (byId != null) return byId;
      }
      final lower = trimmed.toLowerCase();
      final byName = books
          .where((b) => b.name.trim().toLowerCase() == lower)
          .firstOrNull;
      if (byName != null) return byName;
      throw Failure(FailureCode.validation, '找不到账本：$trimmed');
    }
    final activeId = await _queries.getCurrentBookId();
    return books.where((b) => b.id == activeId).firstOrNull ?? books.first;
  }

  List<Asset> _filterAssetsForBook(
    List<Asset> assets,
    List<AssetBook> links,
    int bookId,
  ) {
    final bound = <int, Set<int>>{};
    for (final l in links) {
      bound.putIfAbsent(l.assetId, () => <int>{}).add(l.bookId);
    }
    return <Asset>[
      for (final a in assets)
        if (a.type == AssetType.debt
            ? isDebtVisibleInBook(
                boundBookIds: bound[a.id] ?? const <int>{},
                queryBookId: bookId,
              )
            : (bound[a.id] == null || bound[a.id]!.contains(bookId)))
          a,
    ];
  }

  Asset _matchRequiredAsset({
    required List<Asset> assets,
    required List<AssetBook> links,
    required int bookId,
    required String rawRef,
    required String label,
  }) {
    final matched = matchFundingAssetByRef(
      assets: assets,
      links: links,
      bookId: bookId,
      rawRef: rawRef,
    );
    if (matched == null) {
      throw Failure(FailureCode.validation, '找不到可用$label：$rawRef');
    }
    return matched;
  }

  Future<int> _resolveCategoryForWrite({
    required AccountBook book,
    required int recordType,
    required String? categoryRef,
  }) async {
    if (recordType == RecordType.transfer) return noRef;
    final wantCatType =
        (recordType == RecordType.income ||
            recordType == RecordType.advanceIncome)
        ? RecordType.income
        : RecordType.expense;
    final cats =
        await (db.select(db.recordCategories)
              ..where(
                (t) =>
                    t.accountBookId.equals(book.id) &
                    t.type.equals(wantCatType),
              )
              ..orderBy([
                (t) => OrderingTerm.asc(t.sort),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    if (categoryRef != null && categoryRef.trim().isNotEmpty) {
      final matched = matchCategoryByRef(cats, categoryRef);
      if (matched == null) {
        throw Failure(
          FailureCode.validation,
          '在账本“${book.name}”中找不到分类：$categoryRef',
        );
      }
      return matched.id;
    }
    final fallback =
        cats.where((c) => !c.isHide).firstOrNull ?? cats.firstOrNull;
    if (fallback == null) {
      throw Failure(FailureCode.validation, '账本“${book.name}”下暂无可用分类');
    }
    return fallback.id;
  }

  Future<List<String>> _resolveTagRefs(Object? rawTags) async {
    if (rawTags == null) return const <String>[];
    final refs = <String>[
      if (rawTags is List) ...<String>[
        for (final item in rawTags)
          if (item != null && '$item'.trim().isNotEmpty) '$item'.trim(),
      ] else if (rawTags is String) ...<String>[
        for (final part in rawTags.split(','))
          if (part.trim().isNotEmpty) part.trim(),
      ],
    ];
    if (refs.isEmpty) return const <String>[];
    final allTags = await db.select(db.tags).get();
    final out = <String>[];
    for (final ref in refs) {
      final lower = ref.toLowerCase();
      final hit =
          allTags.where((t) => t.tagId == ref).firstOrNull ??
          allTags
              .where((t) => !t.hidden && t.name.trim().toLowerCase() == lower)
              .firstOrNull ??
          allTags
              .where((t) => t.name.trim().toLowerCase() == lower)
              .firstOrNull;
      if (hit == null) {
        throw Failure(FailureCode.validation, '找不到标签：$ref');
      }
      if (!out.contains(hit.tagId)) {
        out.add(hit.tagId);
      }
    }
    return out;
  }

  Future<RecordExtra> _buildWriteCurrencyExtra({
    required int recordType,
    required Money netMoney,
    required Money? discount,
    required Asset? primaryAsset,
    required Asset? secondaryAsset,
  }) async {
    final extra = RecordExtra();
    final primaryCurrency =
        normalizeCurrency(primaryAsset?.currency) ?? baseCurrency;
    final secondaryCurrency =
        normalizeCurrency(secondaryAsset?.currency) ?? baseCurrency;

    if (recordType == RecordType.transfer) {
      if (primaryCurrency == baseCurrency &&
          secondaryCurrency == baseCurrency) {
        return extra;
      }
      final currencies = await _queries.getCurrencies();
      final rates = RateTable({
        for (final c in currencies) c.code: c.rateToAnchor,
      });
      final convertedMinor = primaryCurrency == secondaryCurrency
          ? netMoney.storageMinor
          : rates.convert(
              netMoney.storageMinor,
              primaryCurrency,
              secondaryCurrency,
            );
      extra.currency = billSnapshot(
        source: primaryCurrency,
        sourceMinor: netMoney.storageMinor,
        account: secondaryCurrency,
        assetMinor: convertedMinor,
        rates: rates,
      );
      return extra;
    }

    if (primaryCurrency != baseCurrency) {
      final currencies = await _queries.getCurrencies();
      final rates = RateTable({
        for (final c in currencies) c.code: c.rateToAnchor,
      });
      final discMinor =
          (recordType == RecordType.expense ||
                  recordType == RecordType.income) &&
              discount != null &&
              discount.storageMinor > BigInt.zero
          ? discount.storageMinor
          : null;
      final grossMinor = netMoney.storageMinor + (discMinor ?? BigInt.zero);
      extra.currency = billSnapshot(
        source: primaryCurrency,
        sourceMinor: grossMinor,
        account: primaryCurrency,
        assetMinor: netMoney.storageMinor,
        discountMinor: discMinor,
        rates: rates,
      );
    }
    return extra;
  }

  Future<(String, BillingPeriod, BudgetMode)> _resolveBudgetPeriod({
    required AccountBook book,
    required String? rawSection,
  }) async {
    if (rawSection != null && rawSection.trim().isNotEmpty) {
      final trimmed = rawSection.trim();
      final monthMatch = RegExp(r'^(\d{4})-(\d{1,2})$').firstMatch(trimmed);
      if (monthMatch != null) {
        final y = int.parse(monthMatch.group(1)!);
        final m = int.parse(monthMatch.group(2)!);
        if (m < 1 || m > 12) {
          throw Failure(FailureCode.validation, '无效的预算月份：$trimmed');
        }
        final period = BillingPeriod.starting(y, m, book.startDay);
        return (period.monthlySection, period, BudgetMode.monthly);
      }
      final yearMatch = RegExp(r'^(\d{4})$').firstMatch(trimmed);
      if (yearMatch != null) {
        final y = int.parse(yearMatch.group(1)!);
        final period = BillingPeriod.year(y, book.startDay);
        return (period.yearlySection, period, BudgetMode.yearly);
      }
      throw Failure(
        FailureCode.validation,
        '预算周期格式须为 "YYYY-M"（月度）或 "YYYY"（年度），收到：$trimmed',
      );
    }

    final modePref = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals('budget_mode_${book.id}'))).getSingleOrNull();
    final mode = BudgetMode.fromInt(int.tryParse(modePref?.value ?? ''));
    final nowDt = DateTime.fromMillisecondsSinceEpoch(db.nowMs()).toLocal();
    if (mode == BudgetMode.yearly) {
      final period = BillingPeriod.containingYear(nowDt, book.startDay);
      return (period.yearlySection, period, BudgetMode.yearly);
    }
    final period = BillingPeriod.containing(nowDt, book.startDay);
    return (period.monthlySection, period, BudgetMode.monthly);
  }

  Map<String, Object?> _serializeAssetOverview(
    AssetOverview overview,
  ) => <String, Object?>{
    'currency': baseCurrency,
    'net_worth_minor': overview.netAsset.toString(),
    'net_worth_decimal': Money.minor(overview.netAsset).decimal,
    'total_assets_minor': overview.totalAsset.toString(),
    'total_assets_decimal': Money.minor(overview.totalAsset).decimal,
    'total_liabilities_minor': overview.totalLiabilities.toString(),
    'total_liabilities_decimal': Money.minor(overview.totalLiabilities).decimal,
    'uncredited_installment_minor': overview.totalInstallment.toString(),
    'uncredited_installment_decimal': Money.minor(
      overview.totalInstallment,
    ).decimal,
    'missing_rates': overview.missingRates.toList()..sort(),
  };

  Map<String, Object?> _serializeAsset(Asset a) {
    final code = normalizeCurrency(a.currency) ?? baseCurrency;
    final categoryKind = switch (a.type) {
      AssetType.credit => 'credit',
      AssetType.debt =>
        a.subType == AssetType.debtBorrow ? 'debt_borrow' : 'debt_lend',
      _ => 'funding',
    };
    final counted = a.type == AssetType.debt
        ? a.isEffectiveAsset == 0
        : a.isEffectiveAsset == 1;
    final statusName = switch (a.status) {
      AssetStatus.hidden => 'hidden',
      AssetStatus.settled => 'settled',
      _ => 'active',
    };
    return <String, Object?>{
      'id': a.id,
      'name': a.name,
      'kind': categoryKind,
      'type': a.type,
      'sub_type': a.subType,
      'status': statusName,
      'currency': code,
      'balance_minor': a.balanceMinor.toString(),
      'decimal': Money.minor(a.balanceMinor, code).decimal,
      'balance_decimal': Money.minor(a.balanceMinor, code).decimal,
      'counted_in_net_worth': counted,
      'group_name': a.groupName,
      'remark': a.remark,
    };
  }

  Map<String, Object?> _serializeRecordSummary(
    LedgerRecord r, {
    required Map<int, AccountBook> bookById,
    required Map<int, RecordCategory> catById,
    required Map<int, Asset> assetById,
    required List<String> tagIds,
    required Map<String, Tag> tagById,
  }) {
    final snap = RecordExtra.parse(r.extraInfo).currency;
    final aid = r.type == RecordType.reimbursable ? r.fromAssetId : r.assetId;
    final currency =
        normalizeCurrency(snap?.assetCode) ??
        normalizeCurrency(assetById[aid]?.currency) ??
        baseCurrency;
    return <String, Object?>{
      'record_id': r.recordId,
      'book_id': r.accountBookId,
      'book_name': bookById[r.accountBookId]?.name,
      'type': r.type,
      'type_name': RecordType.names[r.type] ?? '${r.type}',
      'money_minor': r.moneyMinor.toString(),
      'decimal': Money.minor(r.moneyMinor, currency).decimal,
      'money_decimal': Money.minor(r.moneyMinor, currency).decimal,
      'discount_minor': r.discountMinor?.toString(),
      'discount_decimal': r.discountMinor == null
          ? null
          : Money.minor(r.discountMinor!, currency).decimal,
      'currency': currency,
      'category_id': r.recordCatId == noRef ? null : r.recordCatId,
      'category_name': r.recordCatId == noRef
          ? null
          : _categoryPathLabel(r.recordCatId, catById),
      'asset_id': r.assetId == noRef ? null : r.assetId,
      'asset_name': r.assetId == noRef ? null : assetById[r.assetId]?.name,
      'from_asset_id': r.fromAssetId == noRef ? null : r.fromAssetId,
      'from_asset_name': r.fromAssetId == noRef
          ? null
          : assetById[r.fromAssetId]?.name,
      'to_asset_id': r.toAssetId == noRef ? null : r.toAssetId,
      'to_asset_name': r.toAssetId == noRef
          ? null
          : assetById[r.toAssetId]?.name,
      'record_time_ms': r.recordTime,
      'record_time': _formatEpochMs(r.recordTime),
      'remark': r.remark,
      'exclude_budget': r.excludeBudget,
      'exclude_ex_in': r.excludeExIn,
      'tags': <Object>[
        for (final tid in tagIds)
          <String, Object?>{'tag_id': tid, 'name': tagById[tid]?.name ?? tid},
      ],
    };
  }

  String _categoryPathLabel(int catId, Map<int, RecordCategory> catById) {
    final cat = catById[catId];
    if (cat == null) return '';
    if (cat.parentCatId != noRef) {
      final parent = catById[cat.parentCatId];
      if (parent != null) return '${parent.name}>${cat.name}';
    }
    return cat.name;
  }

  String _resolveCommandId(Object? raw, String prefix) {
    final s = _optStr(raw);
    if (s != null) {
      if (s.length > 128) {
        throw const Failure(FailureCode.validation, 'command_id 长度不能超过 128 字符');
      }
      return s;
    }
    return '$prefix:${_uuid.v4()}';
  }

  Money _parseStrictMoney(
    Object? raw, {
    required String fieldName,
    String currency = baseCurrency,
  }) {
    if (raw == null) {
      throw Failure(FailureCode.validation, '缺少金额参数：$fieldName');
    }
    if (raw is bool || raw is List || raw is Map) {
      throw Failure(FailureCode.validation, '金额参数 $fieldName 格式无效');
    }
    final text = '$raw'.trim().replaceAll(',', '');
    if (text.isEmpty) {
      throw Failure(FailureCode.validation, '金额参数 $fieldName 不能为空');
    }
    return Money.parse(text, currency: currency);
  }

  BigInt? _parseOptionalMoneyMinor(Object? raw) {
    final s = _optStr(raw);
    if (s == null) return null;
    return Money.parse(s.replaceAll(',', '')).storageMinor;
  }

  int _parseCreateRecordType(Object? raw) {
    final s = _optStr(raw);
    if (s == null) return RecordType.expense;
    final parsed = _parseOptionalRecordType(s);
    if (parsed == null || !_editableRecordTypes.contains(parsed)) {
      throw Failure(FailureCode.validation, '不支持创建或编辑该账单类型：$s');
    }
    return parsed;
  }

  int? _parseOptionalRecordType(Object? raw) {
    if (raw == null) return null;
    final s = '$raw'.trim().toLowerCase();
    if (s.isEmpty) return null;
    final numCode = int.tryParse(s);
    if (numCode != null && RecordType.names.containsKey(numCode)) {
      return numCode;
    }
    return switch (s) {
      'expense' || '支出' => RecordType.expense,
      'income' || '收入' => RecordType.income,
      'transfer' || '转账' => RecordType.transfer,
      'reimbursable' || 'reimburse' || '报销' => RecordType.reimbursable,
      'balance_adjust' || '余额变更' => RecordType.balanceAdjust,
      'advance_income' || 'advanceincome' || '预收' => RecordType.advanceIncome,
      'advance_expense' ||
      'advanceexpense' ||
      '预支' => RecordType.advanceExpense,
      'fee' || '手续费' => RecordType.fee,
      _ => null,
    };
  }

  int _parseTimestampOrNow(Object? raw) {
    if (raw == null) return db.nowMs();
    if (raw is int) {
      return raw < 100000000000 ? raw * 1000 : raw;
    }
    final s = '$raw'.trim();
    if (s.isEmpty) return db.nowMs();
    if (RegExp(r'^\d{10,15}$').hasMatch(s)) {
      final n = int.parse(s);
      return s.length == 10 ? n * 1000 : n;
    }
    final dateOnly = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(s);
    if (dateOnly != null) {
      return DateTime(
        int.parse(dateOnly.group(1)!),
        int.parse(dateOnly.group(2)!),
        int.parse(dateOnly.group(3)!),
      ).millisecondsSinceEpoch;
    }
    final localDt = RegExp(
      r'^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?$',
    ).firstMatch(s);
    if (localDt != null) {
      return DateTime(
        int.parse(localDt.group(1)!),
        int.parse(localDt.group(2)!),
        int.parse(localDt.group(3)!),
        int.parse(localDt.group(4)!),
        int.parse(localDt.group(5)!),
        localDt.group(6) == null ? 0 : int.parse(localDt.group(6)!),
      ).millisecondsSinceEpoch;
    }
    final iso = DateTime.tryParse(s);
    if (iso != null) {
      return iso.toLocal().millisecondsSinceEpoch;
    }
    throw Failure(FailureCode.validation, '无法解析时间参数：$s');
  }

  int? _parseFilterDateBound(Object? raw, {required bool isEndOfDay}) {
    if (raw == null) return null;
    if (raw is int) return raw < 100000000000 ? raw * 1000 : raw;
    final s = '$raw'.trim();
    if (s.isEmpty) return null;
    if (RegExp(r'^\d{10,15}$').hasMatch(s)) {
      final n = int.parse(s);
      return s.length == 10 ? n * 1000 : n;
    }
    final dateOnly = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(s);
    if (dateOnly != null) {
      final y = int.parse(dateOnly.group(1)!);
      final m = int.parse(dateOnly.group(2)!);
      final d = int.parse(dateOnly.group(3)!);
      return isEndOfDay
          ? DateTime(y, m, d, 23, 59, 59, 999).millisecondsSinceEpoch
          : DateTime(y, m, d).millisecondsSinceEpoch;
    }
    return _parseTimestampOrNow(s);
  }

  String? _optStr(Object? v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }

  String _reqStr(Object? v, String name) {
    final s = _optStr(v);
    if (s == null) {
      throw Failure(FailureCode.validation, '缺少必填参数：$name');
    }
    return s;
  }

  int? _optInt(Object? v) => switch (v) {
    final int i => i,
    final num n => n.toInt(),
    final String s => int.tryParse(s.trim()),
    _ => null,
  };

  int _reqInt(Object? v, String name) {
    final parsed = _optInt(v);
    if (parsed == null) {
      throw Failure(FailureCode.validation, '参数 $name 必须为整数');
    }
    return parsed;
  }

  bool? _optBool(Object? v) => switch (v) {
    final bool b => b,
    final String s when s.trim().toLowerCase() == 'true' || s.trim() == '1' =>
      true,
    final String s when s.trim().toLowerCase() == 'false' || s.trim() == '0' =>
      false,
    final int i => i != 0,
    _ => null,
  };

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _formatDate(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';
  static String _formatEpochMs(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${_formatDate(d)} ${_two(d.hour)}:${_two(d.minute)}';
  }
}
