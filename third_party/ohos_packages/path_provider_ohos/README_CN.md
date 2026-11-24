# path_provider

本项目基于 [path_provider@2.1.6](https://pub.dev/packages/path_provider/versions/2.1.6) 开发。

## 简介

path_provider 提供获取设备常用文件系统路径（如临时目录、应用文档目录）的能力。path_provider_ohos 是 path_provider 的 OpenHarmony 平台实现，通过 Dart FFI 调用系统 AbilityRuntime 接口获取应用沙箱目录，无需申请权限，也无需编写平台侧初始化代码。

## 下载安装

在工程 pubspec.yaml 中添加依赖：

```yaml
dependencies:
  path_provider_ohos:
    git:
      url: "https://gitcode.com/CPF-Flutter/flutter_packages.git"
      path: "packages/path_provider/path_provider_ohos"
      # ref: 根据下方表格选择不同框架适配的TAG版本
      ref: TAG # 根据下方表格选择不同框架适配的TAG版本
```

执行命令安装依赖：

```bash
flutter pub get
```

**TAG 版本对应表**

| Flutter 框架版本 | TAG 名称 | 分支名 |
|---|---|---|
| 3.41 | path_provider_ohos-v2.1.6 | oh-3.47.7 |
| 3.44 | path_provider_ohos-v2.1.6 | oh-3.47.7 |
| 3.47 | path_provider_ohos-v2.1.6 | oh-3.47.7 |

## 约束与限制

### 兼容性

```text
1. Flutter: 3.41.9+ohos-1.0.2, DevEco Studio: 26.0.0 Release (26.0.0.821), SDK: 5.0.5(17), ROM: 7.0.0.111 SP10;
2. Flutter: 3.44.9+ohos-0.0.1-canary1, DevEco Studio: 26.0.0 Release (26.0.0.821), SDK: 5.0.5(17), ROM: 7.0.0.111 SP10;
3. Flutter: 3.47.7+ohos-0.0.1-canary1, DevEco Studio: 26.0.0 Release (26.0.0.821), SDK: 5.0.5(17), ROM: 7.0.0.111 SP10;
```

### 权限要求

无。本库返回的目录均位于应用沙箱内，无需在 module.json5 中申请权限。

## 使用示例

```dart
import 'package:flutter/material.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

Future<void> logPathsFromExample() async {
  final PathProviderPlatform provider = PathProviderPlatform.instance;

  // 获取未备份的临时目录路径，适合存放可重建的缓存文件
  final String? tempPath = await provider.getTemporaryPath();
  debugPrint('Temporary: $tempPath');

  // 获取用户文档目录路径，适合存放用户生成或无法重建的数据
  final String? documentsPath = await provider.getApplicationDocumentsPath();
  debugPrint('Documents: $documentsPath');

  // 获取应用支持目录路径；目录不存在时由实现自动创建
  final String? supportPath = await provider.getApplicationSupportPath();
  debugPrint('Support: $supportPath');

  // 获取应用缓存目录路径；目录不存在时由实现自动创建
  final String? cachePath = await provider.getApplicationCachePath();
  debugPrint('Cache: $cachePath');
}
```

## 使用说明

1. 在 `pubspec.yaml` 中依赖 `path_provider_ohos`（Git 源与 `ref` 按上节配置）；示例工程会通过传递依赖解析到 `path_provider_platform_interface`。
2. 路径查询可参考示例实现思路：通过 `PathProviderPlatform.instance` 调用 `getTemporaryPath()` 等方法，并在界面侧通过按钮触发、`FutureBuilder` 展示结果。本文代码片段为精简示例，完整可运行版本请以 `example/lib/main.dart` 为准。

**目录映射**

| PathProviderOhos 接口 | OpenHarmony 平台返回目录 |
|---|---|
| getTemporaryPath() | 应用缓存目录（cache） |
| getApplicationSupportPath() | 应用文件目录（files） |
| getApplicationDocumentsPath() | 应用文件目录同级的 app_flutter 目录 |
| getApplicationCachePath() | 应用缓存目录（cache） |
| getExternalStoragePath() | 应用文件目录（files） |
| getExternalCachePaths() | 应用缓存目录（cache）列表 |
| getExternalStoragePaths(type) | 应用文件目录下按类型命名的子目录（如 Music、Download） |
| getDownloadsPath() | 应用文件目录下的 Download 子目录 |

> OpenHarmony 没有独立的公共外部存储路径；`getExternalStoragePath`、`getExternalStoragePaths`、`getExternalCachePaths` 以及 `getDownloadsPath` 均返回应用沙箱内路径，与上表映射一致。

## 接口说明

### API

本库导出 `PathProviderOhos`，实现 [path_provider_platform_interface](https://github.com/flutter/packages/tree/main/packages/path_provider/path_provider_platform_interface) 中 `PathProviderPlatform` 定义的接口。

| 名称 | 描述 | 类型 | 参数类型 | 返回值 | 必填 | OpenHarmony平台支持 |
|-----|-----|-----|---------|-------|-----|-------------|
| registerWith | 将本类注册为 PathProviderPlatform 默认实例 | 方法 | 无 | void | 否 | 是 |
| getTemporaryPath | 返回应用缓存目录路径 | 方法 | 无 | Future<String?> | 否 | 是 |
| getApplicationSupportPath | 返回应用文件目录（files）路径 | 方法 | 无 | Future<String?> | 否 | 是 |
| getApplicationDocumentsPath | 返回应用文档目录（app_flutter）路径 | 方法 | 无 | Future<String?> | 否 | 是 |
| getApplicationCachePath | 返回应用缓存目录（cache）路径 | 方法 | 无 | Future<String?> | 否 | 是 |
| getExternalStoragePath | 返回主外部存储路径（应用文件目录） | 方法 | 无 | Future<String?> | 否 | 是 |
| getExternalCachePaths | 返回外部缓存目录路径列表 | 方法 | 无 | Future<List<String>?> | 否 | 是 |
| getExternalStoragePaths | 返回指定类型的外部存储目录路径列表 | 方法 | StorageDirectory? | Future<List<String>> | 否 | 是 |
| getDownloadsPath | 返回下载目录（Download 子目录）路径 | 方法 | 无 | Future<String?> | 否 | 是 |

## 遗留问题

- 外部存储类接口（`getExternalStoragePath`、`getExternalStoragePaths`、`getExternalCachePaths`）返回应用沙箱内路径，不指向设备公共存储。
- `getDownloadsPath` 返回应用沙箱内 `Download` 子目录，不指向系统公共下载目录。

## 目录结构

```text
path_provider_ohos
├── example                              # 示例应用，演示各目录获取接口的用法
├── lib
│   ├── path_provider_ohos.dart          # 库入口，按平台条件导出实现或桩实现
│   └── src
│       ├── ffi_bindings.dart            # libability_runtime.so 的 FFI 绑定
│       ├── path_provider_ohos_real.dart # OpenHarmony 平台实现
│       └── path_provider_ohos_stub.dart # 不支持 FFI 平台的桩实现
├── CHANGELOG.OpenHarmony.md             # 历史变更记录
├── LICENSE                              # 开源协议
├── pubspec.yaml                         # 包元信息与依赖配置
├── README.OpenHarmony_CN.md             # 中文说明文档
├── README.OpenSource.md                 # 开源说明
└── README.OpenHarmony.md                # 英文说明文档
```

## 贡献代码

使用过程中发现任何问题都可以提 [Issue](https://gitcode.com/CPF-Flutter/flutter_packages/issues) ，当然，也非常欢迎发 [PR](https://gitcode.com/CPF-Flutter/flutter_packages/pulls) 共建。

## 开源协议

本项目基于 [BSD-3-Clause License](https://github.com/flutter/packages/blob/main/packages/path_provider/path_provider/LICENSE) ，请自由地享受和参与开源。
