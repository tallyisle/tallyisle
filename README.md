# 帐屿 · TallyIsle

本地优先的多平台个人记账与资产管理应用（Flutter + Drift SQLite），支持 **Android / iOS / Windows / Linux / macOS** 五端统一数据格式与离线账务引擎。

## 核心特性

- **精确整数账务引擎**：金额全程采用整数“分”（`int64` / `Money` `BigInt`）计算与存储，杜绝浮点精度误差。
- **完整记账链路**：支出、收入、转账（含手续费与跨币种）、退款、分次报销、预收/预支结算、二级分类、多标签、多账本与自定义月起始日、搜索筛选与日历视图。
- **资产与多币种**：资金账户与信用卡账期管理（额度、账单日、还款日、免息期计算与一键还款）、账户对账模式、离线自定义汇率与免密钥多源在线汇率更新。
- **多维统计与预算**：底部统一统计总览、月/年总预算与支出/储蓄分类预算（超额自动联动与结余结转）、分类趋势与一级/二级平铺下钻、净资产/总资产/总负债历史守恒逆推、年度账单与年度报告。
- **跨端备份与数据流转**：五端 100% 统一的 `.tally` 全量备份包（本地文件、WebDAV、S3 兼容对象存储与退出自动同步），同时支持第三方记账软件与微信支付/支付宝 CSV 增量迁入。

## 多平台支持与原生体验

| 平台 | 构建产物 | 原生适配说明 |
|---|---|---|
| **Android** | `帐屿-Android-正式版.apk` / `开发版.apk` | SAF 文件保存、系统分享、桌面小组件、每日提醒通知、生物识别与应用锁、无障碍自动记账 |
| **iOS / iPadOS** | `帐屿-iOS-unsigned.ipa`（支持 AltStore / SideStore / Sideloadly 自签安装） | 原生“文件”应用共享（`UIFileSharingEnabled`）与 `UIActivityViewController` 导出/分享（含 iPad 居中浮层适配） |
| **Windows** | `帐屿-Windows-x64.zip` | Win32 原生窗口（`tallyisle.exe`）、多尺寸高清图标与系统保存/打开对话框 |
| **Linux (KDE / GNOME)** | `帐屿-Linux-x64.tar.gz` | **KDE Plasma 原生体验优化**：Wayland/X11 自动识别 KWin 原生标题栏（不强塞 GNOME HeaderBar），并通过 `xdg-desktop-portal-kde` 调起原生 Dolphin/Qt 文件选择器 |
| **macOS** | `帐屿-macOS.zip` | App Sandbox 网络与用户选定文件读写权限、Ad-hoc 签名开箱即用 |

## 目录结构

```text
lib/
├── app/        # 应用入口、全局 Provider 与 GoRouter 语义路由
├── core/       # Money 精确金额计算与基础工具
├── domain/     # 纯 Dart 账务、账期、资产、预算与统计领域规则
├── data/       # Drift SQLite Schema、DAO 查询、云同步与事务服务
├── features/   # 各业务模块 UI 与状态管理
└── platform/   # 跨平台数据库、文件桥接与运行环境适配
test/           # 领域规则、SQL 查询、平台桥接与 Widget 集成测试
tool/           # 工具链初始化、静态检查、测试与打包脚本
.github/        # GitHub Actions 五端自动化构建与 Release 发布流水线
```

## 快速开始与各端构建

```bash
# 1. 自动初始化独立工具链（支持 Linux x86_64 与 ARM64 / aarch64）并运行全量检查
bash tool/cloud_bootstrap.sh

# 2. 日常格式检查、静态分析与全量测试
bash tool/check.sh

# 3. 本地构建 Android APK（正式版 + 开发版）
bash tool/cloud_bootstrap.sh --with-android
TALLYISLE_GRADLE_ONLINE=1 bash tool/build_android.sh

# 4. 桌面端与 iOS 本地构建（在对应宿主系统执行）
flutter build linux --release            # Linux (需安装 clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev)
flutter build windows --release          # Windows x64
flutter build macos --release            # macOS
flutter build ios --release --no-codesign # iOS 无签名构建（打包 Payload/Runner.app 为 .ipa）
```

推送 `v*` 标签（如 `v0.1.0`）或在 GitHub Actions 手动触发 [Build & Release](.github/workflows/build.yml) 工作流，即可自动完成全量测试验证并产出五端安装包。
