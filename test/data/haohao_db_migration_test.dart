import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/migration/cross_migration_service.dart';
import 'package:tallyisle/data/migration/lan_zip_crypto.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';
import 'package:tallyisle/domain/rules/debt_rules.dart';
import 'package:tallyisle/domain/rules/haohao_db_migration_rules.dart';
import 'package:tallyisle/domain/rules/income_expense.dart';
import 'package:tallyisle/domain/rules/periodic_records.dart';
import 'package:tallyisle/domain/rules/savings_plan.dart';
import 'package:tallyisle/features/csv_transfer/csv_import_page.dart';
import 'package:tallyisle/features/migration/migration_page.dart';
import 'package:tallyisle/features/migration/migration_providers.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/platform/files.dart';
import 'package:tallyisle/platform/notifications.dart';

/// Builds a realistic Haohaojizhang v1.22.5 `account_record.db` binary via
/// `package:sqlite3` covering all 22 Room tables, soft-deleted rows, multi-book,
/// credit cards, lend/borrow debts, 2-level categories, tags, budgets, periodic
/// rules, installments, savings plans (modes 1..6), templates, custom FX rates,
/// and all bill types / relations.
Uint8List _buildFullHaohaoDbBytes(Directory workDir) {
  final file = File('${workDir.path}/account_record.db');
  if (file.existsSync()) file.deleteSync();
  final raw = raw_sqlite.sqlite3.open(file.path);
  try {
    final baseTs = DateTime(2026, 11, 10, 9, 30).millisecondsSinceEpoch;
    raw.execute('''
      CREATE TABLE user (
        user_id INTEGER PRIMARY KEY NOT NULL,
        start_bill_day INTEGER NOT NULL,
        account_book_id INTEGER NOT NULL,
        assets_account_id INTEGER NOT NULL,
        base_currency_code TEXT,
        status INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE user_currencies (
        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        user_id INTEGER NOT NULL,
        currency_code TEXT NOT NULL,
        currency_name TEXT,
        currency_rate REAL NOT NULL
      );
      CREATE TABLE account_book (
        account_book_id INTEGER PRIMARY KEY NOT NULL,
        user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        cover TEXT,
        order_num INTEGER NOT NULL,
        status INTEGER NOT NULL,
        create_by INTEGER NOT NULL
      );
      CREATE TABLE assets_account (
        assets_account_id INTEGER PRIMARY KEY NOT NULL,
        user_id INTEGER NOT NULL,
        account_book_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        category TEXT NOT NULL,
        balance REAL,
        quota REAL,
        bill_day INTEGER NOT NULL DEFAULT 0,
        repayment_day INTEGER NOT NULL DEFAULT 0,
        postpone_day INTEGER NOT NULL DEFAULT 0,
        is_fixed_repayment_date INTEGER NOT NULL DEFAULT 1,
        is_included INTEGER NOT NULL DEFAULT 1,
        currency_code TEXT,
        base_currency_rate REAL,
        order_num INTEGER NOT NULL DEFAULT 0,
        status INTEGER NOT NULL DEFAULT 0,
        remark TEXT,
        icon TEXT,
        color TEXT,
        create_by INTEGER NOT NULL
      );
      CREATE TABLE bill_initial_balance (
        id INTEGER PRIMARY KEY NOT NULL,
        account_book_id INTEGER NOT NULL,
        initial_amount REAL
      );
      CREATE TABLE debt_info (
        debt_id INTEGER PRIMARY KEY NOT NULL,
        user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        type INTEGER NOT NULL,
        status INTEGER NOT NULL,
        is_assets_flag INTEGER NOT NULL,
        repayment_date INTEGER NOT NULL DEFAULT 0,
        remarks TEXT,
        icon TEXT,
        currency_code TEXT,
        create_at INTEGER NOT NULL
      );
      CREATE TABLE bill_category (
        bill_category_id INTEGER PRIMARY KEY NOT NULL,
        bill_category_parent_id INTEGER NOT NULL,
        account_book_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        category_name TEXT NOT NULL,
        icon TEXT,
        color TEXT,
        order_num INTEGER NOT NULL,
        status INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE tags (
        tag_id INTEGER PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        color TEXT,
        weight INTEGER NOT NULL DEFAULT 0,
        status INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE bill_tags (
        bill_info_id INTEGER NOT NULL,
        tag_id INTEGER NOT NULL,
        PRIMARY KEY (bill_info_id, tag_id)
      );
      CREATE TABLE budget (
        budget_id INTEGER PRIMARY KEY NOT NULL,
        account_book_id INTEGER NOT NULL,
        amount REAL NOT NULL,
        budget_type INTEGER NOT NULL,
        bill_category_id INTEGER NOT NULL DEFAULT 0,
        exclude_bill_category_ids TEXT,
        order_num INTEGER NOT NULL DEFAULT 0,
        status INTEGER NOT NULL DEFAULT 0,
        start_date INTEGER NOT NULL,
        end_date INTEGER NOT NULL,
        name TEXT,
        create_by INTEGER NOT NULL
      );
      CREATE TABLE bill_category_budget (
        budget_id INTEGER NOT NULL,
        bill_category_id INTEGER NOT NULL,
        PRIMARY KEY (budget_id, bill_category_id)
      );
      CREATE TABLE recycle_info (
        recycle_id INTEGER PRIMARY KEY NOT NULL,
        type INTEGER NOT NULL,
        account_book_id INTEGER NOT NULL,
        category TEXT,
        money REAL NOT NULL,
        handling_fee REAL NOT NULL DEFAULT 0,
        forward_type INTEGER NOT NULL DEFAULT 0,
        assets_account_id INTEGER NOT NULL DEFAULT -1,
        to_assets_account_id INTEGER NOT NULL DEFAULT -1,
        bill_category_id INTEGER NOT NULL DEFAULT -1,
        bill_category_name TEXT,
        period TEXT,
        start_date INTEGER NOT NULL,
        end_recycle_type INTEGER NOT NULL DEFAULT 0,
        end_date INTEGER NOT NULL DEFAULT 0,
        end_count INTEGER NOT NULL DEFAULT 0,
        run_count INTEGER NOT NULL DEFAULT 0,
        next_date INTEGER NOT NULL DEFAULT 0,
        installment_total_num INTEGER NOT NULL DEFAULT 0,
        installment_num INTEGER NOT NULL DEFAULT 0,
        handle_fee_type INTEGER NOT NULL DEFAULT 1,
        remainder_included INTEGER NOT NULL DEFAULT 1,
        no_include_budget_flag INTEGER NOT NULL DEFAULT 0,
        no_include_income_consume INTEGER NOT NULL DEFAULT 0,
        status INTEGER NOT NULL DEFAULT 0,
        remarks TEXT,
        tags TEXT,
        create_by INTEGER NOT NULL
      );
      CREATE TABLE recycle_tags (
        recycle_id INTEGER NOT NULL,
        tag_id INTEGER NOT NULL
      );
      CREATE TABLE installment_bill (
        installment_bill_id INTEGER PRIMARY KEY NOT NULL,
        recycle_id INTEGER NOT NULL,
        num INTEGER NOT NULL,
        installment_date INTEGER NOT NULL,
        money REAL NOT NULL,
        handle_free REAL NOT NULL DEFAULT 0,
        status INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE saving_plan (
        saving_plan_id INTEGER PRIMARY KEY NOT NULL,
        account_book_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        type INTEGER NOT NULL,
        plan_type INTEGER NOT NULL DEFAULT 1,
        init_amount REAL NOT NULL DEFAULT 0,
        incremental_amount REAL NOT NULL DEFAULT 0,
        total_amount REAL NOT NULL DEFAULT 0,
        assets_account_id INTEGER NOT NULL DEFAULT -1,
        to_assets_account_id INTEGER NOT NULL DEFAULT -1,
        start_date INTEGER NOT NULL,
        end_date INTEGER NOT NULL,
        status INTEGER NOT NULL DEFAULT 0,
        weight INTEGER NOT NULL DEFAULT 0,
        remarks TEXT,
        create_at INTEGER NOT NULL
      );
      CREATE TABLE saving_plan_item (
        saving_plan_item_id INTEGER PRIMARY KEY NOT NULL,
        saving_plan_id INTEGER NOT NULL,
        amount REAL NOT NULL,
        plan_date INTEGER NOT NULL,
        status INTEGER NOT NULL,
        bill_info_id INTEGER NOT NULL DEFAULT 0,
        remarks TEXT
      );
      CREATE TABLE bill_template (
        bill_template_id INTEGER PRIMARY KEY NOT NULL,
        account_book_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        category TEXT NOT NULL,
        bill_type INTEGER NOT NULL DEFAULT 0,
        money REAL NOT NULL,
        handling_fee REAL NOT NULL DEFAULT 0,
        forward_type INTEGER NOT NULL DEFAULT 0,
        assets_account_id INTEGER NOT NULL DEFAULT -1,
        to_assets_account_id INTEGER NOT NULL DEFAULT -1,
        bill_category_id INTEGER NOT NULL DEFAULT -1,
        no_include_budget_flag INTEGER NOT NULL DEFAULT 0,
        no_include_income_consume INTEGER NOT NULL DEFAULT 0,
        order_num INTEGER NOT NULL DEFAULT 0,
        status INTEGER NOT NULL DEFAULT 0,
        remark TEXT,
        tags TEXT,
        create_by INTEGER NOT NULL
      );
      CREATE TABLE bill_template_tags (
        bill_template_id INTEGER NOT NULL,
        tag_id INTEGER NOT NULL
      );
      CREATE TABLE bill_info (
        bill_info_id INTEGER PRIMARY KEY NOT NULL,
        parent_id INTEGER NOT NULL DEFAULT -1,
        account_book_id INTEGER NOT NULL,
        consume REAL DEFAULT 0,
        income REAL DEFAULT 0,
        original_money REAL DEFAULT 0,
        assets_account_id INTEGER NOT NULL DEFAULT -1,
        to_assets_account_id INTEGER NOT NULL DEFAULT -1,
        handling_fee REAL DEFAULT 0,
        forward_type INTEGER NOT NULL DEFAULT 0,
        bill_type INTEGER NOT NULL DEFAULT 0,
        reimbursement_money REAL DEFAULT 0,
        reimbursement_date INTEGER NOT NULL DEFAULT 0,
        refund_money REAL DEFAULT 0,
        refund_date INTEGER NOT NULL DEFAULT 0,
        bill_category_id INTEGER NOT NULL DEFAULT -1,
        name TEXT,
        category TEXT NOT NULL,
        remark TEXT,
        tags TEXT,
        debt_id INTEGER NOT NULL DEFAULT 0,
        recycle_id INTEGER NOT NULL DEFAULT -1,
        status INTEGER NOT NULL DEFAULT 0,
        bill_from TEXT,
        no_include_budget_flag INTEGER NOT NULL DEFAULT 0,
        no_include_income_consume INTEGER NOT NULL DEFAULT 0,
        original_currency_code TEXT,
        assets_account_money REAL DEFAULT 0,
        assets_account_currency_code TEXT,
        base_currency_rate REAL DEFAULT 0,
        to_assets_account_money REAL DEFAULT 0,
        to_assets_currency_code TEXT,
        create_by INTEGER NOT NULL,
        same_date INTEGER NOT NULL
      );
    ''');

    // User & Custom FX currencies (`USD` = 7.25 CNY, `JPY` = 0.05 CNY)
    raw.execute('''
      INSERT INTO user VALUES (1, 5, 2, 10, 'CNY', 0);
      INSERT INTO user_currencies (user_id, currency_code, currency_name, currency_rate)
      VALUES
        (1, 'USD', '美元', 7.25),
        (1, 'JPY', '日元', 0.05);
    ''');

    // Books (including soft-deleted book 99 with status = 9)
    raw.execute('''
      INSERT INTO account_book VALUES
        (1, 1, '日常账本', '', 0, 0, $baseTs),
        (2, 1, '家庭账本', 'book_home', 1, 0, ${baseTs + 1000}),
        (99, 1, '已删账本', '', 2, 9, $baseTs);
    ''');

    // Accounts (normal, credit with postpone days, foreign USD, hidden excluded, soft-deleted)
    raw.execute('''
      INSERT INTO assets_account VALUES
        (10, 1, 0, '招商储蓄卡', 'CASH_CARD', 5680.35, 0, 0, 0, 0, 1, 1, 'CNY', 1.0, 0, 0, '工资卡', 'cmb', '#FF5252', $baseTs),
        (11, 1, 0, '招行信用卡', 'CREDIT_CARD', -1250.40, 30000.0, 15, 0, 20, 0, 1, 'CNY', 1.0, 1, 0, '主刷卡', 'cmb_credit', '#448AFF', $baseTs),
        (12, 1, 2, '美元钱包', 'CASH', 200.50, 0, 0, 0, 0, 1, 1, 'USD', 7.25, 2, 0, '海淘', 'usd_cash', NULL, $baseTs),
        (13, 1, 0, '私房小金库', 'CASH', 888.00, 0, 0, 0, 0, 1, 0, 'CNY', 1.0, 3, 2, NULL, 'vault', NULL, $baseTs),
        (99, 1, 0, '已删账户', 'CASH', 999.99, 0, 0, 0, 0, 1, 1, 'CNY', 1.0, 9, 9, NULL, '', NULL, $baseTs);
    ''');

    // Debts:
    // - debt 1: lend (`type = 1`), counted in net worth (`is_assets_flag = 1` -> `isEffectiveAsset = 0`)
    // - debt 2: borrow (`type = 0`), excluded (`is_assets_flag = 0` -> `isEffectiveAsset = 1`)
    raw.execute('''
      INSERT INTO debt_info VALUES
        (1, 1, '借给张三', 1, 0, 1, 0, '周转借款', 'debt_lend', 'CNY', $baseTs),
        (2, 1, '向李四借入', 0, 0, 0, 0, '短期拆借', 'debt_borrow', 'CNY', $baseTs),
        (9, 1, '已删借贷', 1, 9, 1, 0, NULL, '', 'CNY', $baseTs);
    ''');

    // Categories (2-level hierarchy + root `0` & `-1` + income)
    raw.execute('''
      INSERT INTO bill_category VALUES
        (100, -1, 2, '餐饮', '支出', 'food', '#FF7043', 0, 0),
        (101, 100, 2, '咖啡饮品', '支出', 'coffee', '#8D6E63', 1, 0),
        (102, 0, 2, '差旅办公', 'CONSUME', 'travel', '#26A69A', 2, 0),
        (200, -1, 2, '薪资', '收入', 'salary', '#66BB6A', 0, 0),
        (299, -1, 2, '已删分类', '支出', 'del', NULL, 9, 9);
    ''');

    // Tags & bill_tags
    raw.execute('''
      INSERT INTO tags VALUES
        (1, '出差', '#42A5F5', 0, 0),
        (2, '聚餐', '#FFA726', 1, 0),
        (9, '废弃标签', NULL, 2, 9);
      INSERT INTO bill_tags VALUES
        (1001, 2),
        (1004, 1);
    ''');

    // Budgets: monthly total + monthly category (`100`) + annual total
    raw.execute('''
      INSERT INTO budget VALUES
        (1, 2, 5000.00, 1, 0, NULL, 0, 0, $baseTs, ${baseTs + 864000000}, '家庭月预算', $baseTs),
        (2, 2, 1200.00, 1, 0, NULL, 1, 0, $baseTs, ${baseTs + 864000000}, '餐饮月预算', $baseTs),
        (3, 2, 60000.00, 2, 0, NULL, 2, 0, $baseTs, ${baseTs + 31536000000}, '年度总预算', $baseTs);
      INSERT INTO bill_category_budget VALUES (2, 100);
    ''');

    // Periodic rule (`type=1`) + Credit-card Installment (`type=2`)
    raw.execute('''
      INSERT INTO recycle_info VALUES
        (501, 1, 2, '支出', 35.00, 0, 0, 10, -1, 101, '咖啡饮品', 'everyMonth', $baseTs, 2, 0, 12, 2, ${baseTs + 2592000000}, 0, 0, 1, 1, 0, 0, 0, '云服务月租', NULL, $baseTs),
        (502, 2, 2, '支出', 3000.00, 30.00, 0, 11, -1, 102, '差旅办公', 'everyMonth', $baseTs, 0, 0, 0, 0, 0, 3, 1, 1, 1, 0, 0, 0, '笔记本分期', NULL, $baseTs);
      INSERT INTO recycle_tags VALUES (501, 1);
      INSERT INTO installment_bill VALUES
        (1, 502, 1, $baseTs, 1000.00, 10.00, 1),
        (2, 502, 2, ${baseTs + 2592000000}, 1000.00, 10.00, 0),
        (3, 502, 3, ${baseTs + 5184000000}, 1000.00, 10.00, 0);
    ''');

    // Savings plans (modes 1..6 sample: mode 1 = 365天, mode 4 = 定额, mode 5 = 自由)
    raw.execute('''
      INSERT INTO saving_plan VALUES
        (601, 2, '365天存钱挑战', 1, 1, 1.0, 1.0, 66795.0, 10, 13, $baseTs, ${baseTs + 31536000000}, 0, 0, '每日递增', $baseTs),
        (602, 2, '每月定额存钱', 4, 3, 1000.0, 0.0, 12000.0, 10, 13, $baseTs, ${baseTs + 31536000000}, 0, 1, '定额', $baseTs),
        (603, 2, '自由旅行基金', 5, 1, 0.0, 0.0, 8000.0, -1, -1, $baseTs, ${baseTs + 31536000000}, 1, 2, '已归档', $baseTs);
      INSERT INTO saving_plan_item VALUES
        (1, 601, 10.00, $baseTs, 1, 0, '打卡第1笔'),
        (2, 601, 15.50, ${baseTs + 86400000}, 1, 0, '打卡第2笔'),
        (3, 601, 99.00, ${baseTs + 172800000}, 0, 0, '未打卡预览槽');
    ''');

    // Bill template
    raw.execute('''
      INSERT INTO bill_template VALUES
        (701, 2, '早餐咖啡', '支出', 0, 18.50, 0, 0, 10, -1, 101, 0, 0, 0, 0, '美式', NULL, $baseTs);
      INSERT INTO bill_template_tags VALUES (701, 2);
    ''');

    // Bills (`bill_info`):
    // 1001: Expense with discount (100 -> 80, discount 20) + inline refund (30) + excludeBudget=1
    // 1002: Income (15000.00)
    // 1003: Transfer 10 -> 11 principal 1000.00 + handling_fee 5.00 (consume=1005, income=1000, forward_type=0)
    // 1004: Reimbursable expense (`bill_type=1`, paying account 11, reimbursed 450.00 to account 10)
    // 1005 + 1006: Expense 200.00 + standalone refund child (`parent_id=1005, bill_type=2, refund_money=50.00`)
    // 1007 + 1008: Debt 1 lend 1000.00 (`bill_type=1`) + collect 400.00 (`bill_type=3`) -> remaining 600.00
    // 1009 + 1010: Debt 2 borrow 500.00 (`bill_type=0`) + repay 500.00 (`bill_type=2`) -> settled 0.00
    // 1011: Foreign USD expense on USD wallet 12 (`25.50 USD`, `7.25` rate -> `184.88 CNY`, `excludeExIn=1`)
    // 1999: Soft-deleted bill (`status=9`)
    raw.execute('''
      INSERT INTO bill_info (
        bill_info_id, parent_id, account_book_id, consume, income, original_money,
        assets_account_id, to_assets_account_id, handling_fee, forward_type, bill_type,
        reimbursement_money, reimbursement_date, refund_money, refund_date,
        bill_category_id, name, category, remark, tags, debt_id, recycle_id, status,
        bill_from, no_include_budget_flag, no_include_income_consume,
        original_currency_code, assets_account_money, assets_account_currency_code,
        base_currency_rate, to_assets_account_money, to_assets_currency_code,
        create_by, same_date
      ) VALUES
        (1001, -1, 2, 80.00, 0, 100.00, 10, 10, 0, 0, 0, 0, 0, 30.00, ${baseTs + 3600000}, 101, '咖啡饮品', '支出', '团购咖啡部分退款', NULL, 0, 501, 1, '手动记账', 1, 0, 'CNY', 80.00, 'CNY', 1.0, 0, NULL, $baseTs, $baseTs),
        (1002, -1, 2, 0, 15000.00, 15000.00, 10, -1, 0, 0, 0, 0, 0, 0, 0, 200, '薪资', '收入', '11月工资', NULL, 0, -1, 0, '手动记账', 0, 0, 'CNY', 15000.00, 'CNY', 1.0, 0, NULL, ${baseTs + 10000}, ${baseTs + 10000}),
        (1003, -1, 2, 1005.00, 1000.00, 1000.00, 10, 11, 5.00, 0, 0, 0, 0, 0, 0, -1, '转账', '转账', '还招行信用卡', NULL, 0, -1, 0, '手动记账', 0, 0, 'CNY', 1005.00, 'CNY', 1.0, 1000.00, 'CNY', ${baseTs + 20000}, ${baseTs + 20000}),
        (1004, -1, 2, 450.00, 0, 450.00, 11, 10, 0, 0, 1, 450.00, ${baseTs + 90000}, 0, 0, 102, '差旅办公', '支出', '出差高铁票', NULL, 0, -1, 1, '手动记账', 0, 0, 'CNY', 450.00, 'CNY', 1.0, 0, NULL, ${baseTs + 30000}, ${baseTs + 30000}),
        (1005, -1, 2, 200.00, 0, 200.00, 10, -1, 0, 0, 0, 0, 0, 0, 0, 100, '餐饮', '支出', '外卖聚餐', NULL, 0, -1, 0, '手动记账', 0, 0, 'CNY', 200.00, 'CNY', 1.0, 0, NULL, ${baseTs + 40000}, ${baseTs + 40000}),
        (1006, 1005, 2, 0, 50.00, 50.00, 10, 10, 0, 0, 2, 0, 0, 50.00, ${baseTs + 45000}, 100, '餐饮', '退款', '缺菜退差价', NULL, 0, -1, 1, '自动生成', 0, 0, 'CNY', 50.00, 'CNY', 1.0, 0, NULL, ${baseTs + 45000}, ${baseTs + 45000}),
        (1007, -1, 2, 1000.00, 0, 1000.00, 10, -1, 0, 0, 1, 0, 0, 0, 0, -1, '借出', '债务', '借给张三1000', NULL, 1, -1, 0, '手动记账', 0, 0, 'CNY', 1000.00, 'CNY', 1.0, 0, NULL, ${baseTs + 50000}, ${baseTs + 50000}),
        (1008, -1, 2, 0, 400.00, 400.00, 10, -1, 0, 0, 3, 0, 0, 0, 0, -1, '收款', '债务', '张三归还400', NULL, 1, -1, 0, '手动记账', 0, 0, 'CNY', 400.00, 'CNY', 1.0, 0, NULL, ${baseTs + 55000}, ${baseTs + 55000}),
        (1009, -1, 2, 0, 500.00, 500.00, 10, -1, 0, 0, 0, 0, 0, 0, 0, -1, '借入', '债务', '向李四借入500', NULL, 2, -1, 0, '手动记账', 0, 0, 'CNY', 500.00, 'CNY', 1.0, 0, NULL, ${baseTs + 60000}, ${baseTs + 60000}),
        (1010, -1, 2, 500.00, 0, 500.00, 10, -1, 0, 0, 2, 0, 0, 0, 0, -1, '还款', '债务', '归还李四500', NULL, 2, -1, 0, '手动记账', 0, 0, 'CNY', 500.00, 'CNY', 1.0, 0, NULL, ${baseTs + 65000}, ${baseTs + 65000}),
        (1011, -1, 2, 184.88, 0, 25.50, 12, -1, 0, 0, 0, 0, 0, 0, 0, 102, '差旅办公', '支出', '海淘软件订阅', '订阅 AI', 0, -1, 0, '手动记账', 0, 1, 'USD', 25.50, 'USD', 7.25, 0, NULL, ${baseTs + 70000}, ${baseTs + 70000}),
        (1012, -1, 2, 145.00, 0, 20.00, 10, -1, 0, 0, 0, 0, 0, 0, 0, 102, '差旅办公', '支出', '储蓄卡海淘扣人民币', NULL, 0, -1, 0, '手动记账', 0, 0, 'USD', 145.00, 'CNY', 7.25, 0, NULL, ${baseTs + 71000}, ${baseTs + 71000}),
        (1013, -1, 2, 72.50, 0, 10.00, 10, -1, 0, 0, 1, 0, 0, 0, 0, -1, '借出', '债务', '储蓄卡借出10美元给张三', NULL, 1, -1, 0, '手动记账', 0, 0, 'USD', 72.50, 'CNY', 7.25, 0, NULL, ${baseTs + 72000}, ${baseTs + 72000}),
        (1014, -1, 2, 362.50, 0, 50.00, 12, 12, 0, 0, 0, 0, 0, 12.00, ${baseTs - 3600000}, 102, '差旅办公', '支出', '美元钱包订单部分退款', NULL, 0, -1, 1, '手动记账', 0, 0, 'USD', 50.00, 'USD', 7.25, 12.00, 'USD', ${baseTs + 73000}, ${baseTs + 73000}),
        (1015, -1, 2, 290.00, 0, 40.00, 12, 12, 0, 0, 1, 40.00, ${baseTs - 3600000}, 0, 0, 102, '差旅办公', '支出', '美元钱包差旅报销', NULL, 0, -1, 1, '手动记账', 0, 0, 'USD', 40.00, 'USD', 7.25, 40.00, 'USD', ${baseTs + 74000}, ${baseTs + 74000}),
        (1016, -1, 2, 145.00, 0, 30.00, 10, -1, 0, 0, 0, 0, 0, 0, 0, 102, '差旅办公', '支出', '储蓄卡海淘30减10美元', NULL, 0, -1, 0, '手动记账', 0, 0, 'USD', 145.00, 'CNY', 7.25, 0, NULL, ${baseTs + 75000}, ${baseTs + 75000}),
        (1017, -1, 2, 80.00, 0, 100.00, 12, -1, 0, 0, 0, 0, 0, 0, 0, 102, '差旅办公', '支出', '美元钱包刷人民币100减20', NULL, 0, -1, 0, '手动记账', 0, 0, 'CNY', 11.03, 'USD', 1.0, 0, NULL, ${baseTs + 76000}, ${baseTs + 76000}),
        (1999, -1, 2, 9999.00, 0, 9999.00, 10, -1, 0, 0, 0, 0, 0, 0, 0, 100, '餐饮', '支出', '已删除流水', NULL, 0, -1, 9, '手动记账', 0, 0, 'CNY', 9999.00, 'CNY', 1.0, 0, NULL, ${baseTs + 80000}, ${baseTs + 80000});
    ''');
  } finally {
    raw.close();
  }
  return file.readAsBytesSync();
}

/// Builds a legacy `*_new` table variant Haohao `.db` wrapped in an unencrypted `.zip`.
Uint8List _buildLegacyNewVariantZipBytes(Directory workDir) {
  final file = File('${workDir.path}/account_record_legacy.db');
  if (file.existsSync()) file.deleteSync();
  final raw = raw_sqlite.sqlite3.open(file.path);
  try {
    const ts = 1763000000000;
    raw.execute('''
      CREATE TABLE account_book_new (
        account_book_id INTEGER PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        order_num INTEGER NOT NULL,
        status INTEGER NOT NULL,
        create_by INTEGER NOT NULL
      );
      CREATE TABLE assets_account (
        assets_account_id INTEGER PRIMARY KEY NOT NULL,
        account_book_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        category TEXT NOT NULL,
        balance REAL,
        is_included INTEGER NOT NULL,
        status INTEGER NOT NULL,
        create_by INTEGER NOT NULL
      );
      CREATE TABLE bill_category_new (
        bill_category_id INTEGER PRIMARY KEY NOT NULL,
        bill_category_parent_id INTEGER NOT NULL,
        account_book_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        category_name TEXT NOT NULL,
        order_num INTEGER NOT NULL,
        status INTEGER NOT NULL
      );
      CREATE TABLE budget_new (
        budget_id INTEGER PRIMARY KEY NOT NULL,
        account_book_id INTEGER NOT NULL,
        amount REAL NOT NULL,
        budget_type INTEGER NOT NULL,
        bill_category_id INTEGER NOT NULL,
        order_num INTEGER NOT NULL,
        status INTEGER NOT NULL,
        start_date INTEGER NOT NULL,
        create_by INTEGER NOT NULL
      );
      CREATE TABLE bill_info_new (
        bill_info_id INTEGER PRIMARY KEY NOT NULL,
        parent_id INTEGER NOT NULL,
        account_book_id INTEGER NOT NULL,
        consume REAL,
        income REAL,
        assets_account_id INTEGER NOT NULL,
        to_assets_account_id INTEGER NOT NULL,
        bill_category_id INTEGER NOT NULL,
        category TEXT NOT NULL,
        remark TEXT,
        status INTEGER NOT NULL,
        create_by INTEGER NOT NULL,
        same_date INTEGER NOT NULL
      );
      INSERT INTO account_book_new VALUES (1, '旧版账本', 0, 0, $ts);
      INSERT INTO assets_account VALUES (1, 0, '微信零钱', 'ONLINE_PAYMENT_ACCOUNT', 321.45, 1, 0, $ts);
      INSERT INTO bill_category_new VALUES (10, 0, 1, '日用', '支出', 0, 0);
      INSERT INTO budget_new VALUES (1, 1, 2000.00, 1, 0, 0, 0, $ts, $ts);
      INSERT INTO bill_info_new VALUES (100, -1, 1, 45.60, 0, 1, -1, 10, '支出', '纸巾洗护', 0, $ts, $ts);
    ''');
  } finally {
    raw.close();
  }

  final dbBytes = file.readAsBytesSync();
  return buildLanZipArchive([
    LanZipInputEntry(name: 'backup/account_record_1.22.5.db', bytes: dbBytes),
  ]);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tempWorkDir;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  setUp(() {
    tempWorkDir = Directory.systemTemp.createTempSync('ti_haohao_db_test_');
  });

  tearDown(() {
    if (tempWorkDir.existsSync()) {
      tempWorkDir.deleteSync(recursive: true);
    }
  });

  group('HaohaoDbMigrationRules pure helpers', () {
    test(
      'parseHaohaoRealMinor converts SQLite REAL/int/String via exact HALF_UP BigInt without float drift',
      () {
        expect(parseHaohaoRealMinor(null), BigInt.zero);
        expect(parseHaohaoRealMinor(0), BigInt.zero);
        expect(parseHaohaoRealMinor(100), BigInt.from(10000));
        expect(parseHaohaoRealMinor(19.900000000000002), BigInt.from(1990));
        expect(parseHaohaoRealMinor(0.005), BigInt.from(1));
        expect(parseHaohaoRealMinor(-1250.40), BigInt.from(-125040));
        expect(parseHaohaoRealMinor('1,234.56'), BigInt.from(123456));
        expect(parseHaohaoRealMinor('5e-2'), BigInt.from(5));
        expect(parseHaohaoRealMinor(88888888.88), BigInt.from(8888888888));
      },
    );

    test('isHaohaoDatabaseTables detects Haohao Room tables only', () {
      expect(
        isHaohaoDatabaseTables(['assets_account', 'bill_info', 'account_book']),
        isTrue,
      );
      expect(
        isHaohaoDatabaseTables(['ASSETS_ACCOUNT', 'bill_info_new']),
        isTrue,
      );
      expect(
        isHaohaoDatabaseTables(['account_book', 'asset', 'record']),
        isFalse,
      );
    });
  });

  group('CrossMigrationService Haohaojizhang full .db migration', () {
    test(
      'inspectHaohaoDb + applyMigrationPayload maps all 22 tables accurately, preserves local notes & existing custom FX rates, and cleans up temp dirs',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final scheduler = InMemoryReminderScheduler();
        addTearDown(() async {
          await scheduler.dispose();
          await db.close();
        });

        // Seed pre-existing local `随手记` notes and a user-customized USD rate
        await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('随手记备忘'),
                content: '超市采购清单：牛奶、鸡蛋',
                createTime: 1700000001000,
                updateTime: 1700000002000,
              ),
            );
        await db
            .into(db.currencies)
            .insertOnConflictUpdate(
              CurrenciesCompanion.insert(
                code: 'USD',
                name: '美元(本机自定义)',
                symbol: r'$',
                rateToAnchor: '0.140000000000',
                anchorCode: 'CNY',
              ),
            );

        final inspectTempRoot = Directory(
          '${tempWorkDir.path}/service_temp_root',
        )..createSync(recursive: true);
        final service = CrossMigrationService(
          db,
          reminderScheduler: scheduler,
          tempRootDir: inspectTempRoot,
        );

        final dbBytes = _buildFullHaohaoDbBytes(tempWorkDir);
        final preview = await service.inspectHaohaoDb(
          fileName: 'account_record.db',
          bytes: dbBytes,
        );

        // Temp directory created during SQLite inspection must be cleaned up
        expect(inspectTempRoot.listSync(), isEmpty);

        expect(preview.sourceKind, MigrationSourceKind.haohaoDb);
        expect(preview.bookCount, 2); // soft-deleted book 99 excluded
        expect(
          preview.assetCount,
          6,
        ); // 4 active accounts + 2 active debts (deleted 99 & 9 excluded)
        expect(preview.categoryCount, 4); // 100, 101, 102, 200
        expect(preview.budgetCount, 3); // monthly total, monthly cat, annual
        expect(preview.installmentCount, 1);
        expect(preview.periodCount, 1);
        expect(preview.savingsPlanCount, 3);
        expect(
          preview.savingsRecordCount,
          2,
        ); // only status==1 saving_plan_items imported
        expect(preview.planCount, 5); // 1 installment + 1 period + 3 savings
        expect(preview.templateCount, 1);
        expect(preview.customCurrencyCount, 2); // USD & JPY

        // Verify mid-transaction failure rolls back completely without losing pre-seeded note
        await expectLater(
          () => service.applyMigrationPayload(
            commandId: 'cmd-haohao-rollback',
            payload: preview.payload,
            debugFailAfterClear: () =>
                throw const Failure(FailureCode.migrationFailed, '模拟写入中断'),
          ),
          throwsA(isA<Failure>()),
        );
        final notesAfterRollback = await db.select(db.notes).get();
        expect(notesAfterRollback.single.content, '超市采购清单：牛奶、鸡蛋');

        // Commit atomic migration
        final committed = await service.applyMigrationPayload(
          commandId: 'cmd-haohao-commit-1',
          payload: preview.payload,
        );
        expect(committed.activeBookId, 2); // from Haohao `user.account_book_id`
        expect(committed.bookCount, 2);
        expect(committed.assetCount, 6);

        // Idempotent replay with same commandId returns identical result
        final replayed = await service.applyMigrationPayload(
          commandId: 'cmd-haohao-commit-1',
          payload: preview.payload,
        );
        expect(replayed.recordCount, committed.recordCount);

        // 1. Local `note` (`随手记`) preserved 100%
        final notes = await db.select(db.notes).get();
        expect(notes.length, 1);
        expect(notes.single.title, '随手记备忘');
        expect(notes.single.content, '超市采购清单：牛奶、鸡蛋');

        // 2. Custom FX currencies: existing USD NOT clobbered; missing JPY upserted!
        final currencies = await db.select(db.currencies).get();
        final currByCode = {for (final c in currencies) c.code: c};
        expect(currByCode['USD']!.rateToAnchor, '0.140000000000');
        expect(currByCode['USD']!.name, '美元(本机自定义)');
        expect(currByCode['JPY'], isNotNull);
        expect(currByCode['JPY']!.rateToAnchor, '20'); // 1 / 0.05 = 20 JPY/CNY

        // 3. Books & start_day
        final books = await db.select(db.accountBooks).get();
        expect(books.map((b) => b.name).toList(), ['日常账本', '家庭账本']);
        expect(books.every((b) => b.startDay == 5), isTrue);

        // 4. Ordinary, Credit & Debt accounts + exact BigInt balances & polarity
        final assets = await db.select(db.assets).get();
        final assetById = {for (final a in assets) a.id: a};

        final debitCard = assetById[10]!;
        expect(debitCard.type, AssetType.normal);
        expect(debitCard.balanceMinor, BigInt.from(568035));
        expect(debitCard.isEffectiveAsset, 1);
        expect(debitCard.isDefault, isTrue);
        expect(debitCard.currency, isNull); // base CNY stored as null

        final creditCard = assetById[11]!;
        expect(creditCard.type, AssetType.credit);
        expect(creditCard.balanceMinor, BigInt.from(-125040));
        expect(creditCard.initMoneyMinor, BigInt.from(3000000)); // 30,000 limit
        final creditInfo = CreditInfo.parse(creditCard.creditInfo);
        expect(creditInfo.billDay, 15);
        expect(creditInfo.repaymentAfterBillDay, isTrue);
        expect(creditInfo.repaymentDay, 20);
        // Active installment 502 synced into credit_info.inst (periods 2 & 3 uncredited)
        expect(creditInfo.installments, isNotNull);
        expect(creditInfo.installments!.single.id, '502');
        expect(creditInfo.installments!.single.principal, BigInt.from(200000));
        expect(creditInfo.installments!.single.interest, BigInt.from(2000));

        final usdWallet = assetById[12]!;
        expect(usdWallet.currency, 'USD');
        expect(usdWallet.balanceMinor, BigInt.from(20050));

        final hiddenVault = assetById[13]!;
        expect(hiddenVault.isEffectiveAsset, 0);
        expect(hiddenVault.status, AssetStatus.hidden);

        // Debt 1 (`借给张三`): lend (99), counted in net worth (`isEffectiveAsset == 0` inverted!),
        // lent 1000.00 + 72.50 (10 USD @ 7.25) - collected 400.00 = 672.50 remaining
        final lendDebt = assets.singleWhere(
          (a) => a.type == AssetType.debt && a.subType == AssetType.debtLend,
        );
        expect(lendDebt.name, '借给张三');
        expect(lendDebt.isEffectiveAsset, 0); // inverted per tables.dart:45
        expect(lendDebt.status, AssetStatus.active);
        expect(lendDebt.balanceMinor, BigInt.from(67250));
        final lendLoan = LoanInfo.parse(lendDebt.loanInfo);
        expect(lendLoan.totalDebtMoneyMinor, BigInt.from(107250));

        // Debt 2 (`向李四借入`): borrow (100), excluded (`isEffectiveAsset == 1` inverted!),
        // borrowed 500.00 - repaid 500.00 = 0 -> auto-settled (`status == 2`)
        final borrowDebt = assets.singleWhere(
          (a) => a.type == AssetType.debt && a.subType == AssetType.debtBorrow,
        );
        expect(borrowDebt.name, '向李四借入');
        expect(borrowDebt.isEffectiveAsset, 1); // inverted per tables.dart:45
        expect(borrowDebt.status, AssetStatus.settled);
        expect(borrowDebt.balanceMinor, BigInt.zero);

        // 5. 2-level Categories
        final cats = await db.select(db.recordCategories).get();
        final catById = {for (final c in cats) c.id: c};
        expect(catById[100]!.parentCatId, noRef);
        expect(catById[101]!.parentCatId, 100);
        expect(catById[102]!.parentCatId, noRef); // root `0` mapped to `-1`
        expect(catById[200]!.type, RecordType.income);

        // 6. Records, child links (`ltfeei`, `lreimbursei`, `lrefundi`), discount, flags, FX
        final records = await db.select(db.records).get();
        final recById = {for (final r in records) r.recordId: r};

        // 1001: Expense 80.00, discount 20.00, excludeBudget=true + inline refund child -30.00
        final r1001 = recById['hh_bill_1001']!;
        expect(r1001.type, RecordType.expense);
        expect(r1001.moneyMinor, BigInt.from(8000));
        expect(r1001.discountMinor, BigInt.from(2000));
        expect(r1001.excludeBudget, isTrue);
        expect(r1001.excludeExIn, isFalse);
        final r1001Refund = recById['hh_bill_1001_refund']!;
        expect(r1001Refund.type, RecordType.expense);
        expect(r1001Refund.moneyMinor, BigInt.from(-3000));
        expect(
          RecordRelations.parse(r1001.relInfo).refunds!.children.single.billId,
          'hh_bill_1001_refund',
        );
        expect(
          RecordRelations.parse(r1001Refund.relInfo).refunds!.originId,
          'hh_bill_1001',
        );

        // 1003: Transfer 1000.00 + fee child 5.00 (`type=12`)
        final r1003 = recById['hh_bill_1003']!;
        expect(r1003.type, RecordType.transfer);
        expect(r1003.moneyMinor, BigInt.from(100000));
        expect(r1003.fromAssetId, 10);
        expect(r1003.toAssetId, 11);
        final r1003Fee = recById['hh_bill_1003_fee']!;
        expect(r1003Fee.type, RecordType.fee);
        expect(r1003Fee.moneyMinor, BigInt.from(500));
        expect(r1003Fee.assetId, 10);
        expect(
          RecordRelations.parse(r1003Fee.relInfo).transferFee!.parentId,
          'hh_bill_1003',
        );

        // 1004: Reimbursable (`type=3` with `fromAssetId = 11`, `assetId = -1`) + `type=15` receipt child
        final r1004 = recById['hh_bill_1004']!;
        expect(r1004.type, RecordType.reimbursable);
        expect(r1004.assetId, noRef);
        expect(r1004.fromAssetId, 11);
        expect(r1004.moneyMinor, BigInt.from(45000));
        final r1004Reimb = recById['hh_bill_1004_reimb']!;
        expect(r1004Reimb.type, RecordType.reimburseReceipt);
        expect(
          r1004Reimb.recordCatId,
          102,
        ); // inherits parent recordCatId (L-08)
        expect(r1004Reimb.assetId, 10);
        expect(r1004Reimb.moneyMinor, BigInt.from(45000));
        expect(
          RecordRelations.parse(
            r1004.relInfo,
          ).reimbursements!.children.single.billId,
          'hh_bill_1004_reimb',
        );
        expect(
          RecordRelations.parse(r1004Reimb.relInfo).reimbursements!.originId,
          'hh_bill_1004',
        );

        // 1005 + 1006: Standalone refund child linked via `parent_id`
        final r1005 = recById['hh_bill_1005']!;
        final r1006 = recById['hh_bill_1006']!;
        expect(r1006.moneyMinor, BigInt.from(-5000));
        expect(
          RecordRelations.parse(r1005.relInfo).refunds!.children.single.billId,
          'hh_bill_1006',
        );
        expect(
          RecordRelations.parse(r1006.relInfo).refunds!.originId,
          'hh_bill_1005',
        );

        // 1007..1010: Debt directions (`5, 6, 7, 8`)
        expect(recById['hh_bill_1007']!.type, RecordType.lendOut);
        expect(recById['hh_bill_1007']!.fromAssetId, 10);
        expect(recById['hh_bill_1007']!.toAssetId, lendDebt.id);
        expect(recById['hh_bill_1008']!.type, RecordType.collect);
        expect(recById['hh_bill_1008']!.fromAssetId, lendDebt.id);
        expect(recById['hh_bill_1008']!.toAssetId, 10);
        expect(recById['hh_bill_1009']!.type, RecordType.borrowIn);
        expect(recById['hh_bill_1010']!.type, RecordType.repay);

        // 1011: Foreign USD expense on USD wallet with `CurrencySnapshot` & `excludeExIn = true`
        final r1011 = recById['hh_bill_1011']!;
        expect(r1011.excludeExIn, isTrue);
        expect(r1011.moneyMinor, BigInt.from(2550));
        final curr1011 = RecordExtra.parse(r1011.extraInfo).currency!;
        expect(curr1011.sourceCode, 'USD');
        expect(curr1011.sourceGross, BigInt.from(2550));
        expect(curr1011.assetCode, 'USD');
        expect(curr1011.assetNet, BigInt.from(2550));
        expect(curr1011.baseCode, 'CNY');
        expect(curr1011.baseAmount, BigInt.from(18488));

        // 1012: Cross-currency USD expense on CNY account 10 -> `moneyMinor` MUST be in CNY (`assetNet`)!
        final r1012 = recById['hh_bill_1012']!;
        expect(r1012.assetId, 10);
        expect(r1012.moneyMinor, BigInt.from(14500)); // 145.00 CNY account net
        final curr1012 = RecordExtra.parse(r1012.extraInfo).currency!;
        expect(curr1012.sourceCode, 'USD');
        expect(curr1012.sourceGross, BigInt.from(2000));
        expect(curr1012.assetCode, 'CNY');
        expect(curr1012.assetNet, BigInt.from(14500));
        expect(curr1012.baseAmount, BigInt.from(14500));

        // 1013: Cross-currency USD debt lend from CNY account 10 -> `moneyMinor` MUST be in CNY funding currency!
        final r1013 = recById['hh_bill_1013']!;
        expect(r1013.type, RecordType.lendOut);
        expect(r1013.fromAssetId, 10);
        expect(r1013.moneyMinor, BigInt.from(7250)); // 72.50 CNY funding debit
        final curr1013 = RecordExtra.parse(r1013.extraInfo).currency!;
        expect(curr1013.sourceCode, 'USD');
        expect(curr1013.sourceGross, BigInt.from(1000));
        expect(curr1013.assetCode, 'CNY');
        expect(curr1013.assetNet, BigInt.from(7250));

        // 1014: Foreign USD account inline refund -> signed negative FX snapshot on child + LinkedBill FX fields + clamped timestamp
        final r1014 = recById['hh_bill_1014']!;
        final r1014Refund = recById['hh_bill_1014_refund']!;
        expect(r1014Refund.moneyMinor, BigInt.from(-1200));
        expect(r1014Refund.recordTime, r1014.recordTime + 1);
        final refundChildCurr = RecordExtra.parse(
          r1014Refund.extraInfo,
        ).currency!;
        expect(refundChildCurr.sourceCode, 'USD');
        expect(refundChildCurr.sourceGross, BigInt.from(-1200));
        expect(refundChildCurr.assetCode, 'USD');
        expect(refundChildCurr.assetNet, BigInt.from(-1200));
        expect(refundChildCurr.baseCode, 'CNY');
        expect(refundChildCurr.baseAmount, BigInt.from(-8700)); // -12 * 7.25
        final refundLink = RecordRelations.parse(
          r1014.relInfo,
        ).refunds!.children.single;
        expect(refundLink.amount, BigInt.from(1200));
        expect(refundLink.assetCode, 'USD');
        expect(refundLink.assetAmount, BigInt.from(1200));
        expect(refundLink.baseCode, 'CNY');
        expect(refundLink.baseAmount, BigInt.from(8700));

        // 1015: Foreign USD account inline reimbursement -> positive FX snapshot + LinkedBill FX fields + parent recordCatId + clamped timestamp
        final r1015 = recById['hh_bill_1015']!;
        final r1015Reimb = recById['hh_bill_1015_reimb']!;
        expect(r1015Reimb.recordCatId, r1015.recordCatId);
        expect(r1015Reimb.recordTime, r1015.recordTime + 1);
        expect(r1015Reimb.moneyMinor, BigInt.from(4000));
        final reimbChildCurr = RecordExtra.parse(
          r1015Reimb.extraInfo,
        ).currency!;
        expect(reimbChildCurr.sourceCode, 'USD');
        expect(reimbChildCurr.sourceGross, BigInt.from(4000));
        expect(reimbChildCurr.assetCode, 'USD');
        expect(reimbChildCurr.assetNet, BigInt.from(4000));
        expect(reimbChildCurr.baseCode, 'CNY');
        expect(reimbChildCurr.baseAmount, BigInt.from(29000)); // 40 * 7.25
        final reimbLink = RecordRelations.parse(
          r1015.relInfo,
        ).reimbursements!.children.single;
        expect(reimbLink.amount, BigInt.from(4000));
        expect(reimbLink.assetCode, 'USD');
        expect(reimbLink.assetAmount, BigInt.from(4000));
        expect(reimbLink.baseCode, 'CNY');
        expect(reimbLink.baseAmount, BigInt.from(29000));

        // 1016: Cross-currency discounted expense ($30 gross / $20 net on CNY card 10 @ 7.25)
        // -> `discountMinor` MUST be in source currency ('USD': 1000), `moneyMinor` in CNY (14500),
        // and `amountIn(..., 'USD') == 2000` & `amountIn(..., 'CNY') == 14500`!
        final r1016 = recById['hh_bill_1016']!;
        expect(r1016.moneyMinor, BigInt.from(14500));
        expect(r1016.discountMinor, BigInt.from(1000)); // $10.00 in USD
        final curr1016 = RecordExtra.parse(r1016.extraInfo).currency!;
        expect(curr1016.sourceCode, 'USD');
        expect(curr1016.sourceGross, BigInt.from(3000));
        expect(curr1016.assetCode, 'CNY');
        expect(curr1016.assetNet, BigInt.from(14500));
        expect(curr1016.assetDiscount, BigInt.from(7250));
        final stat1016 = StatEntry(
          type: r1016.type,
          moneyMinor: r1016.moneyMinor,
          discountMinor: r1016.discountMinor,
          currency: curr1016,
        );
        expect(amountIn(stat1016, 'USD'), BigInt.from(2000));
        expect(amountIn(stat1016, 'CNY'), BigInt.from(14500));

        // 1017: Cross-currency discounted expense (¥100 gross / ¥80 net on USD wallet 12)
        // -> `discountMinor` MUST be in source currency ('CNY': 2000), `moneyMinor` in USD (1103),
        // and `amountIn(..., 'CNY') == 8000` & `amountIn(..., 'USD') == 1103`!
        final r1017 = recById['hh_bill_1017']!;
        expect(r1017.moneyMinor, BigInt.from(1103));
        expect(r1017.discountMinor, BigInt.from(2000)); // ¥20.00 in CNY
        final curr1017 = RecordExtra.parse(r1017.extraInfo).currency!;
        expect(curr1017.sourceCode, 'CNY');
        expect(curr1017.sourceGross, BigInt.from(10000));
        expect(curr1017.assetCode, 'USD');
        expect(curr1017.assetNet, BigInt.from(1103));
        expect(curr1017.assetDiscount, BigInt.from(276));
        final stat1017 = StatEntry(
          type: r1017.type,
          moneyMinor: r1017.moneyMinor,
          discountMinor: r1017.discountMinor,
          currency: curr1017,
        );
        expect(amountIn(stat1017, 'CNY'), BigInt.from(8000));
        expect(amountIn(stat1017, 'USD'), BigInt.from(1103));

        // Soft-deleted bill 1999 absent
        expect(recById.containsKey('hh_bill_1999'), isFalse);

        // 7. Budgets, Periods, Installments, Savings Plans, Tags
        final budgets = await db.select(db.budgets).get();
        expect(budgets.length, 3);
        expect(
          budgets.any(
            (b) =>
                b.budgetType == BudgetTypeCode.total &&
                b.section == '2026-11' &&
                b.amountMinor == BigInt.from(500000),
          ),
          isTrue,
        );
        expect(
          budgets.any(
            (b) =>
                b.budgetType == BudgetTypeCode.expenseCategory &&
                b.recordCatId == 100 &&
                b.amountMinor == BigInt.from(120000),
          ),
          isTrue,
        );
        expect(
          budgets.any(
            (b) =>
                b.budgetType == BudgetTypeCode.total &&
                b.section == '2026' &&
                b.amountMinor == BigInt.from(6000000),
          ),
          isTrue,
        );

        final periods = await db.select(db.recordPeriods).get();
        expect(periods.single.periodType, PeriodType.monthly);
        expect(periods.single.periodEndDate, 12);
        expect(periods.single.moneyMinor, BigInt.from(3500));

        final plans = await db.select(db.moneySavePlans).get();
        final plan601 = plans.firstWhere((p) => p.id == 601);
        expect(plan601.planType, SavingsPlanType.incremental);
        expect(plan601.cycleType, SavingsCycleType.daily);
        expect(plan601.savedMoneyMinor, BigInt.from(2550)); // 10.00 + 15.50
      },
    );

    test(
      'supports unencrypted .zip wrapping *_new legacy tables and auto-detects Haohao DB in inspectLanBackup',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final scheduler = InMemoryReminderScheduler();
        addTearDown(() async {
          await scheduler.dispose();
          await db.close();
        });

        final service = CrossMigrationService(
          db,
          reminderScheduler: scheduler,
          tempRootDir: tempWorkDir,
        );

        final zipBytes = _buildLegacyNewVariantZipBytes(tempWorkDir);
        final preview = await service.inspectHaohaoDb(
          fileName: 'haohao_backup.zip',
          bytes: zipBytes,
        );
        expect(preview.sourceKind, MigrationSourceKind.haohaoDb);
        expect(preview.entryName, 'backup/account_record_1.22.5.db');
        expect(preview.bookCount, 1);
        expect(preview.assetCount, 1);
        expect(preview.categoryCount, 1);
        expect(preview.budgetCount, 1);
        expect(preview.recordCount, 1);
        expect(preview.payload.records.single.moneyMinor, BigInt.from(4560));

        // Auto-detection via inspectLanBackup when user picks bare Haohao .db
        final bareDbBytes = _buildFullHaohaoDbBytes(tempWorkDir);
        final lanOutcome = await service.inspectLanBackup(
          fileName: 'account_record.db',
          bytes: bareDbBytes,
        );
        expect(lanOutcome, isA<LanInspectReady>());
        final autoPreview = (lanOutcome as LanInspectReady).preview;
        expect(autoPreview.sourceKind, MigrationSourceKind.haohaoDb);
        expect(autoPreview.bookCount, 2);
      },
    );
  });

  group('MigrationPage third-party Qianji & Haohaojizhang UI flow', () {
    testWidgets(
      'renders Qianji & Haohaojizhang cards without overflow on 360x640 and desktop 1280x800, navigates to CsvImportPage, and previews/commits Haohao .db preserving notes',
      (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        late final AppDatabase db;
        await tester.runAsync(() async {
          db = AppDatabase(NativeDatabase.memory());
          await db
              .into(db.notes)
              .insert(
                NotesCompanion.insert(
                  title: const Value('我的随手记'),
                  content: '重要便签不可丢失',
                  createTime: 1700000000000,
                  updateTime: 1700000000000,
                ),
              );
        });
        final scheduler = InMemoryReminderScheduler();
        var closed = false;
        Future<void> disposeCleanly() async {
          if (closed) return;
          closed = true;
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 1));
          await tester.runAsync(scheduler.dispose);
          await tester.runAsync(db.close);
        }

        addTearDown(disposeCleanly);

        final dbBytes = _buildFullHaohaoDbBytes(tempWorkDir);
        final fakeFiles = FileAccess(
          onPickBytes: (_) async => SelectedBytes('account_record.db', dbBytes),
        );

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [
              databaseProvider.overrideWith((ref) async => db),
              reminderSchedulerProvider.overrideWithValue(scheduler),
              migrationFileAccessProvider.overrideWithValue(fakeFiles),
            ],
            child: const MaterialApp(home: MigrationPage()),
          ),
        );
        await settle(tester);

        // Scroll to Haohao card on narrow 360x640 mobile and verify sheet button navigates to CsvImportPage
        await tester.dragUntilVisible(
          find.byKey(const Key('migration_haohao_import_card')),
          find.byType(ListView),
          const Offset(0, -160),
        );
        await settle(tester);
        expect(tester.takeException(), isNull);

        await tester.ensureVisible(
          find.byKey(const Key('migration_open_haohao_sheet_button')),
        );
        await settle(tester);
        await tester.tap(
          find.byKey(const Key('migration_open_haohao_sheet_button')),
        );
        await settle(tester);
        expect(find.byType(CsvImportPage), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await settle(tester);

        // Scroll to Qianji card and verify button navigates to CsvImportPage
        await tester.dragUntilVisible(
          find.byKey(const Key('migration_open_qianji_import_button')),
          find.byType(ListView),
          const Offset(0, -140),
        );
        await settle(tester);
        expect(find.text('钱迹（Qianji）导入'), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('migration_open_qianji_import_button')),
        );
        await settle(tester);
        expect(find.byType(CsvImportPage), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await settle(tester);

        // Also check desktop 1280x800 wide layout renders side-by-side Haohao buttons cleanly
        tester.view.physicalSize = const Size(1280, 800);
        await settle(tester);
        expect(tester.takeException(), isNull);
        tester.view.physicalSize = const Size(360, 640);
        await settle(tester);

        // Trigger Haohao `.db` full-database atomic migration via preview dialog
        await tester.ensureVisible(
          find.byKey(const Key('migration_pick_haohao_db_button')),
        );
        await settle(tester);
        await tester.tap(
          find.byKey(const Key('migration_pick_haohao_db_button')),
        );
        // Inspect SQLite & open dialog using real async pump
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        await settle(tester);

        expect(
          find.byKey(const Key('haohao_db_confirm_dialog')),
          findsOneWidget,
        );
        expect(find.textContaining('账本 2 个'), findsOneWidget);
        expect(find.textContaining('账户 6 个'), findsOneWidget);
        expect(find.textContaining('分类 4 个'), findsOneWidget);
        expect(find.textContaining('预算 3 项'), findsOneWidget);
        expect(find.textContaining('计划 5 项'), findsOneWidget);
        expect(
          find.byKey(const Key('haohao_overwrite_warning')),
          findsOneWidget,
        );
        expect(find.textContaining('随手记'), findsWidgets);

        await tester.tap(find.byKey(const Key('migration_confirm_submit')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await settle(tester);
        expect(tester.takeException(), isNull);

        // Scroll back to top to inspect status banner & updated local summary
        await tester.dragUntilVisible(
          find.byKey(const Key('migration_local_summary_card')),
          find.byType(ListView),
          const Offset(0, 240),
        );
        await settle(tester);
        expect(find.textContaining('好好记账数据库整库迁入完成'), findsOneWidget);
        expect(find.textContaining('便签 1'), findsOneWidget);

        // Confirm local `随手记` note survived in DB
        final survivingNotes = await tester.runAsync(
          () => db.select(db.notes).get(),
        );
        expect(survivingNotes!.single.content, '重要便签不可丢失');

        await disposeCleanly();
      },
    );
  });
}
