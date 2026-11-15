# path_provider

This project is developed based on [path_provider@2.1.6](https://pub.dev/packages/path_provider/versions/2.1.6).

## Introduction

path_provider provides the ability to obtain commonly used filesystem paths on a device, such as the temporary directory and the application documents directory. path_provider_ohos is the OpenHarmony platform implementation of path_provider. It obtains application sandbox directories by calling AbilityRuntime interfaces over Dart FFI, requiring no permissions and no platform-side initialization code.

## How to Install

Add the dependency to the pubspec.yaml of your project:

```yaml
dependencies:
  path_provider_ohos:
    git:
      url: "https://gitcode.com/CPF-Flutter/flutter_packages.git"
      path: "packages/path_provider/path_provider_ohos"
      # ref: Select the TAG version that matches your Flutter framework version from the table below
      ref: TAG # Select the TAG version that matches your Flutter framework version from the table below
```

Run the following command to install the dependency:

```bash
flutter pub get
```

**TAG Version Mapping Table**

| Flutter Framework Version | TAG Name | Branch |
|---|---|---|
| 3.41 | path_provider_ohos-v2.1.6 | oh-3.47.7 |
| 3.44 | path_provider_ohos-v2.1.6 | oh-3.47.7 |
| 3.47 | path_provider_ohos-v2.1.6 | oh-3.47.7 |

## Constraints and Limitations

### Compatibility

```text
1. Flutter: 3.41.9+ohos-1.0.2, DevEco Studio: 26.0.0 Release (26.0.0.821), SDK: 5.0.5(17), ROM: 7.0.0.111 SP10;
2. Flutter: 3.44.9+ohos-0.0.1-canary1, DevEco Studio: 26.0.0 Release (26.0.0.821), SDK: 5.0.5(17), ROM: 7.0.0.111 SP10;
3. Flutter: 3.47.7+ohos-0.0.1-canary1, DevEco Studio: 26.0.0 Release (26.0.0.821), SDK: 5.0.5(17), ROM: 7.0.0.111 SP10;
```

### Permission Requirements

None. All directories returned by this library are located inside the application sandbox, so no permissions need to be declared in module.json5.

## Usage Example

```dart
import 'package:flutter/material.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

Future<void> logPathsFromExample() async {
  final PathProviderPlatform provider = PathProviderPlatform.instance;

  // Non-backed-up temporary directory, suitable for reconstructible cache files
  final String? tempPath = await provider.getTemporaryPath();
  debugPrint('Temporary: $tempPath');

  // Documents directory for user-generated or non-reconstructible data
  final String? documentsPath = await provider.getApplicationDocumentsPath();
  debugPrint('Documents: $documentsPath');

  // Application support directory; created automatically if missing
  final String? supportPath = await provider.getApplicationSupportPath();
  debugPrint('Support: $supportPath');

  // Application cache directory; created automatically if missing
  final String? cachePath = await provider.getApplicationCachePath();
  debugPrint('Cache: $cachePath');
}
```

## Usage Notes

1. Add `path_provider_ohos` in `pubspec.yaml` (configure the Git source and `ref` as in the previous section). The example project resolves `path_provider_platform_interface` as a transitive dependency.
2. For path queries, follow the example approach: use `PathProviderPlatform.instance` and methods such as `getTemporaryPath()`, trigger requests from UI buttons, and present results with `FutureBuilder`. The snippet in this document is simplified; for a complete runnable version, refer to `example/lib/main.dart`.

**Directory Mapping**

| PathProviderOhos API | Directory returned on OpenHarmony |
|---|---|
| getTemporaryPath() | Application cache directory (cache) |
| getApplicationSupportPath() | Application files directory (files) |
| getApplicationDocumentsPath() | app_flutter directory next to the application files directory |
| getApplicationCachePath() | Application cache directory (cache) |
| getExternalStoragePath() | Application files directory (files) |
| getExternalCachePaths() | List of application cache directories (cache) |
| getExternalStoragePaths(type) | Subdirectory of the application files directory named by type (for example, Music, Download) |
| getDownloadsPath() | Download subdirectory of the application files directory |

> OpenHarmony has no separate public external storage path; `getExternalStoragePath`, `getExternalStoragePaths`, `getExternalCachePaths`, and `getDownloadsPath` all return paths inside the application sandbox, as shown in the table above.

## API Description

### API

This library exports `PathProviderOhos`, which implements the interfaces defined by `PathProviderPlatform` in [path_provider_platform_interface](https://github.com/flutter/packages/tree/main/packages/path_provider/path_provider_platform_interface).

| Name | Description | Type | Parameter Type | Return Value | Required | OpenHarmony Platform Support |
|-----|-----|-----|---------|-------|-----|-------------|
| registerWith | Registers this class as the default instance of PathProviderPlatform | Method | None | void | No | Yes |
| getTemporaryPath | Returns the application cache directory path | Method | None | Future<String?> | No | Yes |
| getApplicationSupportPath | Returns the application files directory (files) path | Method | None | Future<String?> | No | Yes |
| getApplicationDocumentsPath | Returns the application documents directory (app_flutter) path | Method | None | Future<String?> | No | Yes |
| getApplicationCachePath | Returns the application cache directory (cache) path | Method | None | Future<String?> | No | Yes |
| getExternalStoragePath | Returns the primary external storage path (application files directory) | Method | None | Future<String?> | No | Yes |
| getExternalCachePaths | Returns the list of external cache directory paths | Method | None | Future<List<String>?> | No | Yes |
| getExternalStoragePaths | Returns the list of external storage directory paths of the specified type | Method | StorageDirectory? | Future<List<String>> | No | Yes |
| getDownloadsPath | Returns the downloads directory (Download subdirectory) path | Method | None | Future<String?> | No | Yes |

## Known Issues

- External-storage APIs (`getExternalStoragePath`, `getExternalStoragePaths`, `getExternalCachePaths`) return paths inside the application sandbox instead of device public storage.
- `getDownloadsPath` returns the `Download` subdirectory inside the application sandbox, not the system public downloads directory.

## Directory Structure

```text
path_provider_ohos
├── example                              # Sample application demonstrating directory APIs
├── lib
│   ├── path_provider_ohos.dart          # Library entry, conditionally exports the implementation or the stub
│   └── src
│       ├── ffi_bindings.dart            # FFI bindings for libability_runtime.so
│       ├── path_provider_ohos_real.dart # OpenHarmony platform implementation
│       └── path_provider_ohos_stub.dart # Stub for platforms without FFI support
├── CHANGELOG.OpenHarmony.md             # Historical changes
├── LICENSE                              # Open source license
├── pubspec.yaml                         # Package metadata and dependency configuration
├── README.OpenHarmony_CN.md             # Chinese documentation
├── README.OpenSource.md                 # Open source metadata
└── README.OpenHarmony.md                # English documentation
```

## How to Contribute

If you find any issues during use, feel free to submit an [Issue](https://gitcode.com/CPF-Flutter/flutter_packages/issues). Contributions via [PR](https://gitcode.com/CPF-Flutter/flutter_packages/pulls) are also very welcome.

## License

This project is licensed under [BSD-3-Clause License](https://github.com/flutter/packages/blob/main/packages/path_provider/path_provider/LICENSE). Please enjoy and contribute to open source freely.
