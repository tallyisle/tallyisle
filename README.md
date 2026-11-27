# 帐屿 · TallyIsle

本地优先的全平台个人记账与资产管理应用（Flutter + Drift SQLite），支持 **Android / iOS / HarmonyOS / Windows / Linux / macOS** 全平台统一数据格式与离线账务引擎。

## 核心特性

- **精确整数账务引擎**：金额全程采用整数“分”（`int64` / `Money` `BigInt`）计算与存储，杜绝浮点精度误差。
- **完整记账链路**：支出、收入、转账（含手续费与跨币种）、退款、分次报销与报销管理、预收/预支结算、二级分类、多标签、多账本与自定义月起始日、搜索筛选与日历视图。
- **资产与多币种**：资金账户与信用账户账期管理（额度、共享额度、账单日、还款日、分期占用与一键还款）、内置银行/支付矢量图标与自定义图标、账户对账模式、多币种手动维护与可选在线汇率更新。
- **多维统计、预算与计划**：统计总览、月/年总预算与支出/储蓄分类预算（联动、结转与明细穿透）、分类趋势与一二级平铺下钻、标签统计、净资产/总资产/总负债历史逆推、年度账单与年度报告，以及周期记账、分期、借贷、存钱计划与定期存款。
- **智能速记与外部联动**：支持中文口语速填、移动端离线图文识账（OCR）与熟店规则记账、`tallyisle://` URL Scheme 快捷调用、桌面小组件/服务卡片，以及可选开启的本地 MCP 服务。
- **全平台备份与数据流转**：全平台统一的 `.tally` 本地备份（支持自定义保存目录）、WebDAV / S3 云同步与自动备份策略，同时支持微信支付、支付宝及常见第三方记账软件账单导入。

## 全平台支持与原生体验

| 平台 | 构建产物 | 原生适配说明 |
|---|---|---|
| **Android** | `TallyIsle-Android-{arm64,x64}.apk` | 文件保存与系统分享、桌面小组件、每日提醒通知、指纹/面容与应用锁、通知栏/无障碍自动记账与离线中文识图 |
| **iOS / iPadOS** | `TallyIsle-iOS-unsigned.ipa`（支持自签安装） | 原生“文件”应用共享、快捷指令（AppIntents）联动、桌面图标长按菜单与离线识图 |
| **HarmonyOS** | `TallyIsle-HarmonyOS-{arm64,x64}-unsigned.hap` / `TallyIsle-HarmonyOS-installer-kit.zip` | HarmonyOS NEXT 原生适配、桌面服务卡片、系统分享与离线识图、生物识别解锁 |
| **Windows** | `TallyIsle-Windows-{x64,arm64}-setup.exe` / `.msi` / `-portable.zip` | Win32 原生窗口与状态记忆、桌面双栏布局与键盘快捷记账、`tallyisle://` 与 `.tally` 文件关联 |
| **Linux (KDE / GNOME)** | `TallyIsle-Linux-{x64,arm64}.deb` / `.rpm` / `.AppImage` / `.flatpak` / `-portable.tar.gz` | GTK3 窗口状态记忆、Wayland / X11 原生 KWin 标题栏识别、`xdg-desktop-portal` 原生文件选择器 |
| **macOS** | `TallyIsle-macOS.dmg` / `.pkg` / `-portable.zip` | AppKit 窗口状态记忆、App Sandbox 网络与选定文件读写权限、Ad-hoc 签名开箱即用 |

## 目录结构

```text
lib/
├── app/        # 应用入口、全局 Provider、自适应布局与 GoRouter 路由
├── core/       # Money 精确金额计算、版本号与基础错误类型
├── domain/     # 纯 Dart 账务、账期、资产、预算与统计领域规则
├── data/       # Drift SQLite Schema、DAO 查询、云同步与事务服务
├── features/   # 各业务模块界面与状态管理
└── platform/   # 跨平台数据库、文件桥接与系统能力适配
ohos/           # HarmonyOS NEXT 原生工程与桥接插件
test/           # 领域规则、SQL 查询、平台桥接与界面测试
tool/           # 工具链初始化、静态检查、测试与打包脚本
.github/        # GitHub Actions 自动化构建与 Release 发布配置
```

## 快速开始与各端构建

```bash
# 1. 自动初始化独立工具链（支持 Linux x86_64 与 ARM64 / aarch64）并运行全量检查
bash tool/cloud_bootstrap.sh

# 2. 日常格式检查、静态分析与全量测试
bash tool/check.sh

# 3. 本地构建 Android APK（arm64 + x64 正式包，支持 --arch arm64|x64|all）
bash tool/cloud_bootstrap.sh --with-android
TALLYISLE_GRADLE_ONLINE=1 bash tool/build_android.sh

# 4. 桌面端与 iOS 本地构建（在对应宿主系统执行）
flutter build linux --release             # Linux（x64 / arm64）
flutter build windows --release           # Windows（x64 / arm64）
flutter build macos --release             # macOS
flutter build ios --release --no-codesign # iOS 无签名构建
```

## 许可证

帐屿源码按 [PolyForm Noncommercial License 1.0.0](LICENSE) 提供，允许个人学习、研究与其他非商业用途；商业授权及官方增值服务的相关权利归 TallyIsle 所有。应用内置的银行矢量图标遵循 MIT 协议，详见应用内「帮助与关于 → 第三方开源组件与图标许可」。
