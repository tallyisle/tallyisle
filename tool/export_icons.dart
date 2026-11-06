import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';

// Asset export command, not a behavioral test. Resizes the original square PNG;
// no crop, redraw, recolor or replacement art.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('export platform icon assets from unchanged original', () async {
    final source = await File(
      'assets/branding/tallyisle-logo-original.png',
    ).readAsBytes();
    Future<Uint8List> png(int size) async {
      final codec = await ui.instantiateImageCodec(
        source,
        targetWidth: size,
        targetHeight: size,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      return data!.buffer.asUint8List();
    }

    Future<void> write(String path, int size) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(await png(size));
    }

    for (final item in [
      ('mdpi', 48),
      ('hdpi', 72),
      ('xhdpi', 96),
      ('xxhdpi', 144),
      ('xxxhdpi', 192),
    ]) {
      await write(
        'android/app/src/main/res/mipmap-${item.$1}/ic_launcher.png',
        item.$2,
      );
    }
    for (final size in [192, 512]) {
      await write('web/icons/Icon-$size.png', size);
      // Full square artwork; maskable safe-area variants are NOT claimed.
    }
    await write('web/favicon.png', 32);
    final apple = <String, int>{
      'Icon-App-20x20@1x.png': 20,
      'Icon-App-20x20@2x.png': 40,
      'Icon-App-20x20@3x.png': 60,
      'Icon-App-29x29@1x.png': 29,
      'Icon-App-29x29@2x.png': 58,
      'Icon-App-29x29@3x.png': 87,
      'Icon-App-40x40@1x.png': 40,
      'Icon-App-40x40@2x.png': 80,
      'Icon-App-40x40@3x.png': 120,
      'Icon-App-60x60@2x.png': 120,
      'Icon-App-60x60@3x.png': 180,
      'Icon-App-76x76@1x.png': 76,
      'Icon-App-76x76@2x.png': 152,
      'Icon-App-83.5x83.5@2x.png': 167,
      'Icon-App-1024x1024@1x.png': 1024,
    };
    for (final item in apple.entries) {
      await write(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/${item.key}',
        item.value,
      );
    }
    for (final size in [16, 32, 64, 128, 256, 512, 1024]) {
      await write(
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png',
        size,
      );
    }
    final image = await png(256);
    final header = ByteData(22)
      ..setUint16(2, 1, Endian.little)
      ..setUint16(4, 1, Endian.little)
      ..setUint16(10, 1, Endian.little)
      ..setUint16(12, 32, Endian.little)
      ..setUint32(14, image.length, Endian.little)
      ..setUint32(18, 22, Endian.little);
    await File(
      'windows/runner/resources/app_icon.ico',
    ).writeAsBytes([...header.buffer.asUint8List(), ...image]);
  });
}
