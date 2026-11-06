# 帐屿 · TallyIsle

本地优先的多平台个人记账与资产管理应用（Flutter + Drift SQLite）。

## 核心特性

- **精确整数账务引擎**：金额全程采用整数“分”（`int64` / `Money` `BigInt`）计算与存储，杜绝浮点精度误差。
- **完整记账链路**：支出、收入、转账（含手续费与跨币种）、退款、分次报销、预收/预支结算、二级分类、多标签、多账本与自定义月起始日、搜索筛选与日历视图。
- **资产与多币种**：资金账户与信用卡账期管理（额度、账单日、还款日、免息期计算与一键还款）、账户对账模式、离线自定义汇率与外币折算。
- **多维统计与预算**：底部统一统计总览、月/年总预算与支出/储蓄分类预算（超额自动联动与结余结转）、分类趋势与一级/二级平铺下钻、净资产/总资产/总负债历史守恒逆推、年度账单与年度报告。

## 目录结构

```text
lib/
├── app/        # 应用入口、全局 Provider 与 GoRouter 语义路由
├── core/       # Money 精确金额计算与基础工具
├── domain/     # 纯 Dart 账务、账期、资产、预算与统计领域规则
├── data/       # Drift SQLite Schema、DAO 查询与事务服务
├── features/   # 各业务模块 UI 与状态管理
└── platform/   # 跨平台数据库与运行环境适配
test/           # 领域规则、SQL 查询与 Widget 集成测试
tool/           # 工具链初始化、静态检查、测试与打包脚本
```

## 快速开始

```bash
# 1. 自动初始化独立工具链（支持 Linux x86_64 与 ARM64 / aarch64）并运行全量检查
bash tool/cloud_bootstrap.sh

# 2. 日常格式检查、静态分析与全量测试
bash tool/check.sh

# 3. 初始化 Android SDK / NDK 并构建 ARM64 开发版 APK
bash tool/cloud_bootstrap.sh --with-android
TALLYISLE_GRADLE_ONLINE=1 bash tool/build_android.sh
```
