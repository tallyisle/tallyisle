<div align="center">
  <h1>file_selector_ohos</h1>
</div>

本项目基于 [file_selector@1.1.0](https://pub.dev/packages/file_selector/versions/1.1.0) 开发。

## 简介

`file_selector` 的 OpenHarmony 平台实现（包名：`file_selector_ohos`）。为 Flutter 应用提供文件选择能力，支持单文件选择与多文件选择。

## 下载安装

进入到工程目录并在 pubspec.yaml 中添加以下依赖：

```yaml
dependencies:
  file_selector:
    git:
      url: "https://gitcode.com/CPF-Flutter/flutter_packages.git"
      path: "packages/file_selector/file_selector"
      # ref: 根据下方表格选择不同框架适配的TAG版本
      ref: TAG
```

执行命令：

```bash
flutter pub get
```

> TAG 命名规则：`原库版本-ohos-版本号-betax`，不同 TAG 之间的变更详见 CHANGELOG.md。

| Flutter 框架版本 | TAG 名称 | 分支名 |
| --- | --- | --- |
| 3.47 | file_selector-v1.1.0-ohos-1.0.3 | oh-3.47.7 |

### 升级迁移说明

1. 按上表将 `ref` 切换到目标 Flutter 框架对应的分支或 TAG。
2. 执行 `flutter clean` 与 `flutter pub get`。
3. 若从仅 Android/iOS 项目迁到 OpenHarmony，需增加 `ohos` 平台工程并重新编译 HAP。

## 约束与限制

### 兼容性

在以下版本中已测试通过：

1. Flutter: 3.47.7+ohos-0.0.1-canary1; SDK: 5.0.5(17); IDE: DevEco Studio 26.0.0 Beta2, ROM: 6.1.0.135 SP8;

### OHOS 环境配置步骤

1. 安装并配置 DevEco Studio。
2. 安装 OpenHarmony SDK。
3. 配置 OpenHarmony 版 Flutter SDK，并确认 `flutter doctor` 中 ohos 工具链可用。
4. 在工程中执行依赖安装：`flutter pub get`。
5. 编译示例或业务工程：`flutter build hap`。
6. 通过 DevEco Studio 或 `hdc` 将 HAP 安装到设备/模拟器并运行。

## 使用示例

```dart
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';

Future<void> pickTextFile() async {
  // 导入并定义文件过滤条件
  const XTypeGroup typeGroup = XTypeGroup(
    label: 'text',
    extensions: <String>['txt', 'json'],
    uniformTypeIdentifiers: <String>['public.text'],
  );

  // 调用平台接口打开文件选择器
  final XFile? file = await FileSelectorPlatform.instance.openFile(
    acceptedTypeGroups: <XTypeGroup>[typeGroup],
  );
  if (file == null) {
    return;
  }
}
```

## 使用说明

1. 通过 `FileSelectorOhos.registerWith()` 或手动赋值 `FileSelectorPlatform.instance = FileSelectorOhos()` 注册平台实现。
2. 使用 `openFile` / `openFiles` 拉起系统文档选择器；可通过 `XTypeGroup` 的 `extensions` 或 `mimeTypes` 过滤。
3. `confirmButtonText` 在 ohos 上不生效，系统使用默认确认文案。
4. `getDirectoryPath` 在手机侧 DocumentViewPicker 场景下不支持。

## 接口说明

### API

> "ohos 支持"列为 yes 表示 ohos 平台支持该属性；no 则表示不支持；partially 表示部分支持。使用方法跨平台一致，效果对标 iOS 或 Android。

| 名称 | 返回值 | 描述 | 类型 | ohos 支持 |
| --- | --- | --- | --- | --- |
| openFile({List<[XTypeGroup](#XTypeGroup)>? acceptedTypeGroups, String? initialDirectory, String? confirmButtonText,}) | Future\<XFile?\> | 打开一个用于加载文件的文件对话框，并返回用户选择的文件。 | function | partially |
| openFiles({List<[XTypeGroup](#XTypeGroup)>? acceptedTypeGroups, String? initialDirectory, String? confirmButtonText,}) | Future\<List\<XFile\>\> | 打开一个文件对话框以加载文件，并返回用户选择的文件列表。 | function | partially |
| getDirectoryPath({String? initialDirectory, String? confirmButtonText,}) | Future\<String?\> | 打开一个文件对话框以选择目录，并返回所选的目录路径。 | function | no |

### 参数

| 名称 | 描述 | 类型 | ohos 支持 |
| --- | --- | --- | --- |
| acceptedTypeGroups | 可以在对话框中选择的文件类型组列表，其显示方式取决于平台。 | List\<[XTypeGroup](#XTypeGroup)\>? | yes |
| initialDirectory | 对话框打开时将显示的目录的完整路径。如果没有提供，平台将选择一个初始位置。 | String? | yes |
| confirmButtonText | 对话框确认按钮上的文本。如果没有提供，将使用默认的操作系统标签（例如，“Open”）。 | String? | no |

### XTypeGroup

| 名称 | 描述 | 类型 | ohos 支持 |
| --- | --- | --- | --- |
| label | 这个类型组的“名称”或引用。 | String? | yes |
| extensions | 这个组的文件扩展名。 | List\<String\>? | yes |
| mimeTypes | 这个组的 MIME 类型。 | List\<String\>? | yes |
| uniformTypeIdentifiers | 这个组的统一类型标识符。 | List\<String\>? | no |
| webWildCards | 这个组的网络通配符（例如：image/*，video/*）。 | List\<String\>? | no |

## 遗留问题

1. 系统选择对话框确认按钮不支持自定义文案。
2. 手机侧 DocumentViewPicker 不支持选择目录（`getDirectoryPath` 不可用）。
3. `webWildCards` 仅在 Web 生效；`uniformTypeIdentifiers` 是统一类型标识符（UTI）列表，仅在 iOS/macOS 生效。

## 目录结构

```text
file_selector_ohos/
├─ lib/                         # OpenHarmony 平台实现导出与核心逻辑
├─ ohos/                        # OpenHarmony 原生侧实现
├─ example/                     # 示例应用
├─ test/                        # 测试代码
├─ pubspec.yaml                 # 包配置
├─ CHANGELOG.md                 # 版本变更记录
├─ README.md                    # 包说明（英文）
└─ README_CN.md                 # 包说明（中文）
```

## 贡献代码

使用过程中发现任何问题都可以提 [Issue](https://gitcode.com/CPF-Flutter/flutter_packages/issues)，也非常欢迎发 [PR](https://gitcode.com/CPF-Flutter/flutter_packages/pulls) 共建。

## 开源协议

本项目基于 [Apache-2.0](https://gitcode.com/CPF-Flutter/flutter_packages/blob/master/packages/file_selector/file_selector_ohos/LICENSE) ，请自由地享受和参与开源。
