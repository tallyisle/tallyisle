import 'dart:async' show unawaited;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/rules/bank_icon_catalog.dart';

/// Loads `assets/icons/banks/catalog.json` and verifies 1-to-1 parity with
/// Flutter's bundled `AssetManifest`.
Future<BankIconCatalog> loadVerifiedBankIconCatalog([
  AssetBundle? bundle,
]) async {
  final assetBundle = bundle ?? rootBundle;
  final manifest = await AssetManifest.loadFromAssetBundle(assetBundle);
  final catalog = BankIconCatalog.fromJson(
    await assetBundle.loadString(BankIconCatalog.catalogAssetPath),
  );
  BankIconCatalog.verifyManifestAssets(
    catalog: catalog,
    bundledAssetPaths: manifest.listAssets(),
  );
  return catalog;
}

/// Validates that [svgSource] contains no active scripts, event handlers,
/// entity expansion directives, or external network references.
void validateSvgSourceSecurity(String svgSource, {String? sourceLabel}) {
  final lower = svgSource.toLowerCase();
  final ctx = sourceLabel == null ? '' : ' ($sourceLabel)';
  if (lower.contains('<script') ||
      lower.contains('foreignobject') ||
      lower.contains('javascript:') ||
      lower.contains('<!doctype') ||
      lower.contains('<!entity')) {
    throw FormatException('Disallowed active or DTD construct in SVG$ctx');
  }
  if (_eventHandlerAttrPattern.hasMatch(svgSource)) {
    throw FormatException('Disallowed event handler attribute in SVG$ctx');
  }
  if (_externalHrefPattern.hasMatch(svgSource) ||
      _externalUrlRefPattern.hasMatch(svgSource)) {
    throw FormatException('Disallowed external resource reference in SVG$ctx');
  }
}

final RegExp _eventHandlerAttrPattern = RegExp(
  r'\bon[a-z]+\s*=',
  caseSensitive: false,
);
final RegExp _externalHrefPattern = RegExp(
  r'''(?:xlink:)?href\s*=\s*["']\s*(?:https?:|data:|//)''',
  caseSensitive: false,
);
final RegExp _externalUrlRefPattern = RegExp(
  r'''url\(\s*["']?\s*(?:https?:|//)''',
  caseSensitive: false,
);

/// Single vector draw operation parsed from an SVG shape element.
final class SvgShapeOp {
  const SvgShapeOp({
    required this.path,
    this.fillColor,
    this.strokeColor,
    this.strokeWidth = 1.0,
    this.strokeCap = StrokeCap.butt,
    this.strokeJoin = StrokeJoin.miter,
  });

  final Path path;
  final Color? fillColor;
  final Color? strokeColor;
  final double strokeWidth;
  final StrokeCap strokeCap;
  final StrokeJoin strokeJoin;
}

/// Parsed, immutable, zero-dependency vector SVG document ready for `Canvas`
/// painting at any target resolution.
final class SvgVectorDocument {
  const SvgVectorDocument({required this.viewBox, required this.ops});

  factory SvgVectorDocument.parse(String svgSource, {String? sourceLabel}) {
    validateSvgSourceSecurity(svgSource, sourceLabel: sourceLabel);
    return _SvgXmlParser(svgSource, sourceLabel: sourceLabel).parse();
  }

  final Rect viewBox;
  final List<SvgShapeOp> ops;

  void paint(Canvas canvas, Size size, {Color? monochromeColor}) {
    if (size.width <= 0 ||
        size.height <= 0 ||
        viewBox.width <= 0 ||
        viewBox.height <= 0 ||
        ops.isEmpty) {
      return;
    }

    final scale = math.min(
      size.width / viewBox.width,
      size.height / viewBox.height,
    );
    final scaledW = viewBox.width * scale;
    final scaledH = viewBox.height * scale;
    final dx = (size.width - scaledW) * 0.5 - viewBox.left * scale;
    final dy = (size.height - scaledH) * 0.5 - viewBox.top * scale;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale, scale);

    final paintObj = Paint()..isAntiAlias = true;
    for (final op in ops) {
      final fill = op.fillColor;
      if (fill != null && fill.a > 0) {
        paintObj
          ..style = PaintingStyle.fill
          ..color = monochromeColor == null
              ? fill
              : monochromeColor.withValues(alpha: monochromeColor.a * fill.a);
        canvas.drawPath(op.path, paintObj);
      }
      final stroke = op.strokeColor;
      if (stroke != null && stroke.a > 0 && op.strokeWidth > 0) {
        paintObj
          ..style = PaintingStyle.stroke
          ..strokeWidth = op.strokeWidth
          ..strokeCap = op.strokeCap
          ..strokeJoin = op.strokeJoin
          ..color = monochromeColor == null
              ? stroke
              : monochromeColor.withValues(alpha: monochromeColor.a * stroke.a);
        canvas.drawPath(op.path, paintObj);
      }
    }

    canvas.restore();
  }
}

/// Shared in-memory cache of parsed [SvgVectorDocument] instances.
abstract final class SvgVectorCache {
  static const int maxEntries = 256;
  static final Map<String, SvgVectorDocument> _docs =
      <String, SvgVectorDocument>{};
  static final Map<String, Future<SvgVectorDocument?>> _inflight =
      <String, Future<SvgVectorDocument?>>{};

  static SvgVectorDocument? peek(String assetPath) => _docs[assetPath];

  static void put(String assetPath, SvgVectorDocument doc) {
    if (_docs.length >= maxEntries && !_docs.containsKey(assetPath)) {
      _docs.remove(_docs.keys.first);
    }
    _docs[assetPath] = doc;
  }

  static Future<SvgVectorDocument?> load(
    String assetPath, {
    AssetBundle? bundle,
  }) {
    final cached = _docs[assetPath];
    if (cached != null) return Future<SvgVectorDocument?>.value(cached);

    final pending = _inflight[assetPath];
    if (pending != null) return pending;

    final assetBundle = bundle ?? rootBundle;
    final future = () async {
      try {
        final raw = await assetBundle.loadString(assetPath);
        final parsed = SvgVectorDocument.parse(raw, sourceLabel: assetPath);
        put(assetPath, parsed);
        return parsed;
      } catch (_) {
        return null;
      } finally {
        unawaited(_inflight.remove(assetPath));
      }
    }();
    _inflight[assetPath] = future;
    return future;
  }

  /// Pre-warms high-frequency payment & reviewed bank icons so first-frame
  /// renders hit the synchronous cache immediately.
  static Future<void> prewarmCommonIcons([AssetBundle? bundle]) async {
    final paths = <String>[
      'assets/icons/wechat.svg',
      'assets/icons/alipay.svg',
      'assets/icons/social/douyin.svg',
      'assets/icons/social/xiaohongshu.svg',
      for (final entry in BankIconCatalog.bundled.reviewedEntries)
        entry.assetPath,
    ];
    await Future.wait(paths.map((p) => load(p, bundle: bundle)));
  }

  @visibleForTesting
  static void clearForTesting() {
    _docs.clear();
    _inflight.clear();
  }
}

/// Renders a bundled `.svg` vector asset crisply at any DPI with zero external
/// package dependencies.
class SvgVectorIcon extends StatefulWidget {
  const SvgVectorIcon({
    super.key,
    required this.assetPath,
    required this.size,
    this.monochromeColor,
    this.fallbackIcon = Icons.account_balance_rounded,
    this.fallbackColor,
  });

  final String assetPath;
  final double size;
  final Color? monochromeColor;
  final IconData fallbackIcon;
  final Color? fallbackColor;

  @override
  State<SvgVectorIcon> createState() => _SvgVectorIconState();
}

class _SvgVectorIconState extends State<SvgVectorIcon> {
  SvgVectorDocument? _doc;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _doc = SvgVectorCache.peek(widget.assetPath);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureLoaded();
  }

  @override
  void didUpdateWidget(covariant SvgVectorIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetPath != widget.assetPath) {
      _failed = false;
      _doc = SvgVectorCache.peek(widget.assetPath);
      _ensureLoaded();
    }
  }

  void _ensureLoaded() {
    if (_doc != null || _failed) return;
    final syncDoc = SvgVectorCache.peek(widget.assetPath);
    if (syncDoc != null) {
      _doc = syncDoc;
      return;
    }
    final bundle = DefaultAssetBundle.of(context);
    final targetPath = widget.assetPath;
    unawaited(
      SvgVectorCache.load(targetPath, bundle: bundle).then((loaded) {
        if (!mounted || widget.assetPath != targetPath) return;
        setState(() {
          _doc = loaded;
          _failed = loaded == null;
        });
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc ?? SvgVectorCache.peek(widget.assetPath);
    if (doc == null) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: Center(
          child: Icon(
            widget.fallbackIcon,
            size: widget.size * 0.78,
            color:
                widget.fallbackColor ??
                Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        isComplex: true,
        willChange: false,
        painter: _SvgVectorPainter(
          document: doc,
          monochromeColor: widget.monochromeColor,
        ),
      ),
    );
  }
}

final class _SvgVectorPainter extends CustomPainter {
  const _SvgVectorPainter({required this.document, this.monochromeColor});

  final SvgVectorDocument document;
  final Color? monochromeColor;

  @override
  void paint(Canvas canvas, Size size) {
    document.paint(canvas, size, monochromeColor: monochromeColor);
  }

  @override
  bool shouldRepaint(covariant _SvgVectorPainter oldDelegate) =>
      oldDelegate.document != document ||
      oldDelegate.monochromeColor != monochromeColor;
}

// =============================================================================
// Lightweight XML + W3C SVG Path Parser
// =============================================================================

final class _SvgStyleContext {
  const _SvgStyleContext({
    this.fillRaw,
    this.strokeRaw,
    this.strokeWidth = 1.0,
    this.strokeCap = StrokeCap.butt,
    this.strokeJoin = StrokeJoin.miter,
    this.opacity = 1.0,
    this.fillType = PathFillType.nonZero,
  });

  final String? fillRaw;
  final String? strokeRaw;
  final double strokeWidth;
  final StrokeCap strokeCap;
  final StrokeJoin strokeJoin;
  final double opacity;
  final PathFillType fillType;

  _SvgStyleContext merge(Map<String, String> attrs) {
    final nextOpacity = opacity * (_parseUnitDouble(attrs['opacity']) ?? 1.0);
    return _SvgStyleContext(
      fillRaw: attrs['fill'] ?? fillRaw,
      strokeRaw: attrs['stroke'] ?? strokeRaw,
      strokeWidth: _parseDouble(attrs['stroke-width']) ?? strokeWidth,
      strokeCap: _parseStrokeCap(attrs['stroke-linecap']) ?? strokeCap,
      strokeJoin: _parseStrokeJoin(attrs['stroke-linejoin']) ?? strokeJoin,
      opacity: nextOpacity,
      fillType: _parseFillType(attrs['fill-rule']) ?? fillType,
    );
  }
}

final RegExp _xmlCommentOrPiPattern = RegExp(r'<!--[\s\S]*?-->|<\?[\s\S]*?\?>');
final RegExp _xmlTagPattern = RegExp(
  r'<(/?)([A-Za-z_][A-Za-z0-9_:.-]*)([^>]*?)(/?)>',
);
final RegExp _xmlAttrPattern = RegExp(
  r'''([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
);

final class _SvgXmlParser {
  _SvgXmlParser(this.rawSource, {this.sourceLabel});

  final String rawSource;
  final String? sourceLabel;

  SvgVectorDocument parse() {
    final cleaned = rawSource.replaceAll(_xmlCommentOrPiPattern, '');
    Rect? viewBox;
    final styleStack = <_SvgStyleContext>[];
    final tagStack = <String>[];
    final ops = <SvgShapeOp>[];
    var foundSvgRoot = false;
    var ignoredDepth = 0;

    for (final match in _xmlTagPattern.allMatches(cleaned)) {
      final isClosing = match.group(1) == '/';
      final rawTagName = match.group(2)!;
      final localTag = _localName(rawTagName).toLowerCase();
      final attrChunk = match.group(3) ?? '';
      final isSelfClosing = match.group(4) == '/';

      if (isClosing) {
        if (ignoredDepth > 0) {
          ignoredDepth--;
          continue;
        }
        if (tagStack.isNotEmpty) {
          tagStack.removeLast();
          styleStack.removeLast();
        }
        continue;
      }

      if (ignoredDepth > 0) {
        if (!isSelfClosing) ignoredDepth++;
        continue;
      }

      if (localTag == 'title' ||
          localTag == 'desc' ||
          localTag == 'metadata' ||
          localTag == 'defs') {
        if (!isSelfClosing) ignoredDepth++;
        continue;
      }

      final attrs = _parseAttrs(attrChunk);
      final parentStyle = styleStack.isEmpty
          ? const _SvgStyleContext()
          : styleStack.last;
      final currentStyle = parentStyle.merge(attrs);

      if (localTag == 'svg') {
        if (!foundSvgRoot) {
          foundSvgRoot = true;
          viewBox = _parseViewBox(attrs);
        }
      } else if (foundSvgRoot) {
        final shapeOp = _buildShapeOp(localTag, attrs, currentStyle);
        if (shapeOp != null) {
          ops.add(shapeOp);
        }
      }

      if (!isSelfClosing) {
        tagStack.add(localTag);
        styleStack.add(currentStyle);
      }
    }

    if (!foundSvgRoot || viewBox == null) {
      throw FormatException(
        'Invalid SVG root or missing viewBox${sourceLabel == null ? '' : ' ($sourceLabel)'}',
      );
    }

    return SvgVectorDocument(
      viewBox: viewBox,
      ops: List<SvgShapeOp>.unmodifiable(ops),
    );
  }

  SvgShapeOp? _buildShapeOp(
    String tag,
    Map<String, String> attrs,
    _SvgStyleContext style,
  ) {
    Path? path;
    var allowsDefaultBlackFill = true;

    switch (tag) {
      case 'path':
        final d = attrs['d'];
        if (d == null || d.trim().isEmpty) return null;
        path = parseSvgPathData(d);
      case 'rect':
        final x = _parseDouble(attrs['x']) ?? 0.0;
        final y = _parseDouble(attrs['y']) ?? 0.0;
        final w = _parseDouble(attrs['width']) ?? 0.0;
        final h = _parseDouble(attrs['height']) ?? 0.0;
        if (w <= 0 || h <= 0) return null;
        final rxAttr = _parseDouble(attrs['rx']);
        final ryAttr = _parseDouble(attrs['ry']);
        final rx = (rxAttr ?? ryAttr ?? 0.0).clamp(0.0, w * 0.5);
        final ry = (ryAttr ?? rxAttr ?? 0.0).clamp(0.0, h * 0.5);
        path = Path();
        if (rx > 0 || ry > 0) {
          path.addRRect(RRect.fromRectXY(Rect.fromLTWH(x, y, w, h), rx, ry));
        } else {
          path.addRect(Rect.fromLTWH(x, y, w, h));
        }
      case 'circle':
        final cx = _parseDouble(attrs['cx']) ?? 0.0;
        final cy = _parseDouble(attrs['cy']) ?? 0.0;
        final r = _parseDouble(attrs['r']) ?? 0.0;
        if (r <= 0) return null;
        path = Path()
          ..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
      case 'ellipse':
        final cx = _parseDouble(attrs['cx']) ?? 0.0;
        final cy = _parseDouble(attrs['cy']) ?? 0.0;
        final rx = _parseDouble(attrs['rx']) ?? 0.0;
        final ry = _parseDouble(attrs['ry']) ?? 0.0;
        if (rx <= 0 || ry <= 0) return null;
        path = Path()
          ..addOval(
            Rect.fromCenter(
              center: Offset(cx, cy),
              width: rx * 2,
              height: ry * 2,
            ),
          );
      case 'line':
        allowsDefaultBlackFill = false;
        final x1 = _parseDouble(attrs['x1']) ?? 0.0;
        final y1 = _parseDouble(attrs['y1']) ?? 0.0;
        final x2 = _parseDouble(attrs['x2']) ?? 0.0;
        final y2 = _parseDouble(attrs['y2']) ?? 0.0;
        path = Path()
          ..moveTo(x1, y1)
          ..lineTo(x2, y2);
      case 'polygon':
      case 'polyline':
        final pts = _parsePoints(attrs['points']);
        if (pts.length < 2) return null;
        path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (var i = 1; i < pts.length; i++) {
          path.lineTo(pts[i].dx, pts[i].dy);
        }
        if (tag == 'polygon') {
          path.close();
        }
      default:
        return null;
    }

    path.fillType = style.fillType;

    final fillOpacity = _parseUnitDouble(attrs['fill-opacity']) ?? 1.0;
    final strokeOpacity = _parseUnitDouble(attrs['stroke-opacity']) ?? 1.0;

    Color? fillColor;
    if (allowsDefaultBlackFill) {
      final effectiveFillRaw = style.fillRaw ?? '#000000';
      final baseFill = _parseSvgColor(effectiveFillRaw);
      if (baseFill != null) {
        final alpha = (baseFill.a * style.opacity * fillOpacity).clamp(
          0.0,
          1.0,
        );
        fillColor = baseFill.withValues(alpha: alpha);
      }
    }

    Color? strokeColor;
    if (style.strokeRaw != null) {
      final baseStroke = _parseSvgColor(style.strokeRaw);
      if (baseStroke != null) {
        final alpha = (baseStroke.a * style.opacity * strokeOpacity).clamp(
          0.0,
          1.0,
        );
        strokeColor = baseStroke.withValues(alpha: alpha);
      }
    }

    if (fillColor == null && strokeColor == null) return null;
    return SvgShapeOp(
      path: path,
      fillColor: fillColor,
      strokeColor: strokeColor,
      strokeWidth: style.strokeWidth,
      strokeCap: style.strokeCap,
      strokeJoin: style.strokeJoin,
    );
  }
}

String _localName(String raw) {
  final idx = raw.indexOf(':');
  return idx < 0 ? raw : raw.substring(idx + 1);
}

Map<String, String> _parseAttrs(String chunk) {
  final map = <String, String>{};
  for (final m in _xmlAttrPattern.allMatches(chunk)) {
    final key = _localName(m.group(1)!);
    final val = (m.group(2) ?? m.group(3) ?? '').trim();
    map[key] = val;
  }
  return map;
}

Rect? _parseViewBox(Map<String, String> attrs) {
  final rawVb = attrs['viewBox'];
  if (rawVb != null && rawVb.isNotEmpty) {
    final scanner = _SvgPathScanner(rawVb);
    final minX = scanner.readNumber();
    final minY = scanner.readNumber();
    final width = scanner.readNumber();
    final height = scanner.readNumber();
    if (minX != null &&
        minY != null &&
        width != null &&
        height != null &&
        width > 0 &&
        height > 0) {
      return Rect.fromLTWH(minX, minY, width, height);
    }
  }
  final w = _parseDouble(attrs['width']);
  final h = _parseDouble(attrs['height']);
  if (w != null && h != null && w > 0 && h > 0) {
    return Rect.fromLTWH(0, 0, w, h);
  }
  return null;
}

List<Offset> _parsePoints(String? raw) {
  if (raw == null || raw.isEmpty) return const <Offset>[];
  final scanner = _SvgPathScanner(raw);
  final result = <Offset>[];
  while (true) {
    final x = scanner.readNumber();
    final y = scanner.readNumber();
    if (x == null || y == null) break;
    result.add(Offset(x, y));
  }
  return result;
}

double? _parseDouble(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final cleaned = raw.endsWith('px')
      ? raw.substring(0, raw.length - 2).trim()
      : raw;
  return double.tryParse(cleaned);
}

double? _parseUnitDouble(String? raw) {
  final v = _parseDouble(raw);
  return v?.clamp(0.0, 1.0);
}

StrokeCap? _parseStrokeCap(String? raw) => switch (raw) {
  'round' => StrokeCap.round,
  'square' => StrokeCap.square,
  'butt' => StrokeCap.butt,
  _ => null,
};

StrokeJoin? _parseStrokeJoin(String? raw) => switch (raw) {
  'round' => StrokeJoin.round,
  'bevel' => StrokeJoin.bevel,
  'miter' => StrokeJoin.miter,
  _ => null,
};

PathFillType? _parseFillType(String? raw) => switch (raw) {
  'evenodd' => PathFillType.evenOdd,
  'nonzero' => PathFillType.nonZero,
  _ => null,
};

Color? _parseSvgColor(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();
  switch (lower) {
    case 'none':
    case 'transparent':
      return null;
    case 'white':
      return const Color(0xFFFFFFFF);
    case 'black':
    case 'currentcolor':
      return const Color(0xFF000000);
  }
  if (trimmed.startsWith('#')) {
    final hex = trimmed.substring(1);
    if (hex.length == 3) {
      final r = hex[0];
      final g = hex[1];
      final b = hex[2];
      final val = int.tryParse('FF$r$r$g$g$b$b', radix: 16);
      return val == null ? null : Color(val);
    }
    if (hex.length == 6) {
      final val = int.tryParse('FF$hex', radix: 16);
      return val == null ? null : Color(val);
    }
    if (hex.length == 8) {
      // SVG CSS Color 4 8-digit hex is #RRGGBBAA
      final rgb = hex.substring(0, 6);
      final aa = hex.substring(6, 8);
      final val = int.tryParse('$aa$rgb', radix: 16);
      return val == null ? null : Color(val);
    }
  }
  return null;
}

/// Parses a W3C SVG `d` path data string into a `dart:ui` [Path].
///
/// Supports `M/m`, `L/l`, `H/h`, `V/v`, `C/c`, `S/s`, `Q/q`, `T/t`, `A/a`,
/// `Z/z`, implicit repeated parameter groups, compact sign/decimal runs
/// (`12.525.02-.01`), and single-character arc flags (`a1 1 0 00.5.5`).
Path parseSvgPathData(String d) {
  final path = ui.Path();
  final scanner = _SvgPathScanner(d);

  var curX = 0.0;
  var curY = 0.0;
  var subStartX = 0.0;
  var subStartY = 0.0;
  var lastCubicCtrlX = 0.0;
  var lastCubicCtrlY = 0.0;
  var lastQuadCtrlX = 0.0;
  var lastQuadCtrlY = 0.0;
  int? prevCmd;

  while (true) {
    scanner.skipSeparators();
    if (scanner.isAtEnd) break;

    var cmd = scanner.peekCommand();
    if (cmd != null) {
      scanner.advance();
    } else if (prevCmd != null) {
      // Subsequent coordinate pairs after M/m are implicit L/l.
      if (prevCmd == 0x4D) {
        cmd = 0x4C; // 'L'
      } else if (prevCmd == 0x6D) {
        cmd = 0x6C; // 'l'
      } else {
        cmd = prevCmd;
      }
    } else {
      break;
    }

    switch (cmd) {
      case 0x4D: // 'M'
      case 0x6D: // 'm'
        final rel = cmd == 0x6D;
        final x = scanner.readNumber();
        final y = scanner.readNumber();
        if (x == null || y == null) return path;
        curX = rel ? curX + x : x;
        curY = rel ? curY + y : y;
        subStartX = curX;
        subStartY = curY;
        path.moveTo(curX, curY);
        prevCmd = cmd;

      case 0x4C: // 'L'
      case 0x6C: // 'l'
        final rel = cmd == 0x6C;
        final x = scanner.readNumber();
        final y = scanner.readNumber();
        if (x == null || y == null) return path;
        curX = rel ? curX + x : x;
        curY = rel ? curY + y : y;
        path.lineTo(curX, curY);
        prevCmd = cmd;

      case 0x48: // 'H'
      case 0x68: // 'h'
        final rel = cmd == 0x68;
        final x = scanner.readNumber();
        if (x == null) return path;
        curX = rel ? curX + x : x;
        path.lineTo(curX, curY);
        prevCmd = cmd;

      case 0x56: // 'V'
      case 0x76: // 'v'
        final rel = cmd == 0x76;
        final y = scanner.readNumber();
        if (y == null) return path;
        curY = rel ? curY + y : y;
        path.lineTo(curX, curY);
        prevCmd = cmd;

      case 0x43: // 'C'
      case 0x63: // 'c'
        final rel = cmd == 0x63;
        final x1 = scanner.readNumber();
        final y1 = scanner.readNumber();
        final x2 = scanner.readNumber();
        final y2 = scanner.readNumber();
        final x = scanner.readNumber();
        final y = scanner.readNumber();
        if (x1 == null ||
            y1 == null ||
            x2 == null ||
            y2 == null ||
            x == null ||
            y == null) {
          return path;
        }
        final cx1 = rel ? curX + x1 : x1;
        final cy1 = rel ? curY + y1 : y1;
        final cx2 = rel ? curX + x2 : x2;
        final cy2 = rel ? curY + y2 : y2;
        final nx = rel ? curX + x : x;
        final ny = rel ? curY + y : y;
        path.cubicTo(cx1, cy1, cx2, cy2, nx, ny);
        lastCubicCtrlX = cx2;
        lastCubicCtrlY = cy2;
        curX = nx;
        curY = ny;
        prevCmd = cmd;

      case 0x53: // 'S'
      case 0x73: // 's'
        final rel = cmd == 0x73;
        final x2 = scanner.readNumber();
        final y2 = scanner.readNumber();
        final x = scanner.readNumber();
        final y = scanner.readNumber();
        if (x2 == null || y2 == null || x == null || y == null) return path;
        final hasPrevCubic =
            prevCmd == 0x43 ||
            prevCmd == 0x63 ||
            prevCmd == 0x53 ||
            prevCmd == 0x73;
        final cx1 = hasPrevCubic ? 2 * curX - lastCubicCtrlX : curX;
        final cy1 = hasPrevCubic ? 2 * curY - lastCubicCtrlY : curY;
        final cx2 = rel ? curX + x2 : x2;
        final cy2 = rel ? curY + y2 : y2;
        final nx = rel ? curX + x : x;
        final ny = rel ? curY + y : y;
        path.cubicTo(cx1, cy1, cx2, cy2, nx, ny);
        lastCubicCtrlX = cx2;
        lastCubicCtrlY = cy2;
        curX = nx;
        curY = ny;
        prevCmd = cmd;

      case 0x51: // 'Q'
      case 0x71: // 'q'
        final rel = cmd == 0x71;
        final x1 = scanner.readNumber();
        final y1 = scanner.readNumber();
        final x = scanner.readNumber();
        final y = scanner.readNumber();
        if (x1 == null || y1 == null || x == null || y == null) return path;
        final qx1 = rel ? curX + x1 : x1;
        final qy1 = rel ? curY + y1 : y1;
        final nx = rel ? curX + x : x;
        final ny = rel ? curY + y : y;
        path.quadraticBezierTo(qx1, qy1, nx, ny);
        lastQuadCtrlX = qx1;
        lastQuadCtrlY = qy1;
        curX = nx;
        curY = ny;
        prevCmd = cmd;

      case 0x54: // 'T'
      case 0x74: // 't'
        final rel = cmd == 0x74;
        final x = scanner.readNumber();
        final y = scanner.readNumber();
        if (x == null || y == null) return path;
        final hasPrevQuad =
            prevCmd == 0x51 ||
            prevCmd == 0x71 ||
            prevCmd == 0x54 ||
            prevCmd == 0x74;
        final qx1 = hasPrevQuad ? 2 * curX - lastQuadCtrlX : curX;
        final qy1 = hasPrevQuad ? 2 * curY - lastQuadCtrlY : curY;
        final nx = rel ? curX + x : x;
        final ny = rel ? curY + y : y;
        path.quadraticBezierTo(qx1, qy1, nx, ny);
        lastQuadCtrlX = qx1;
        lastQuadCtrlY = qy1;
        curX = nx;
        curY = ny;
        prevCmd = cmd;

      case 0x41: // 'A'
      case 0x61: // 'a'
        final rel = cmd == 0x61;
        final rx = scanner.readNumber();
        final ry = scanner.readNumber();
        final xAxisRot = scanner.readNumber();
        final largeArc = scanner.readArcFlag();
        final sweep = scanner.readArcFlag();
        final x = scanner.readNumber();
        final y = scanner.readNumber();
        if (rx == null ||
            ry == null ||
            xAxisRot == null ||
            largeArc == null ||
            sweep == null ||
            x == null ||
            y == null) {
          return path;
        }
        final nx = rel ? curX + x : x;
        final ny = rel ? curY + y : y;
        if (rx == 0 || ry == 0) {
          path.lineTo(nx, ny);
        } else {
          path.arcToPoint(
            Offset(nx, ny),
            radius: Radius.elliptical(rx.abs(), ry.abs()),
            rotation: xAxisRot,
            largeArc: largeArc,
            clockwise: sweep,
          );
        }
        curX = nx;
        curY = ny;
        prevCmd = cmd;

      case 0x5A: // 'Z'
      case 0x7A: // 'z'
        path.close();
        curX = subStartX;
        curY = subStartY;
        prevCmd = cmd;

      default:
        return path;
    }
  }

  return path;
}

final class _SvgPathScanner {
  _SvgPathScanner(this.src);

  final String src;
  int pos = 0;

  bool get isAtEnd => pos >= src.length;

  void advance() {
    pos++;
  }

  void skipSeparators() {
    while (pos < src.length) {
      final cu = src.codeUnitAt(pos);
      if (cu == 0x20 || cu == 0x09 || cu == 0x0A || cu == 0x0D || cu == 0x2C) {
        pos++;
      } else {
        break;
      }
    }
  }

  int? peekCommand() {
    if (pos >= src.length) return null;
    final cu = src.codeUnitAt(pos);
    final upper = cu & ~0x20;
    if (upper == 0x4D || // M
        upper == 0x4C || // L
        upper == 0x48 || // H
        upper == 0x56 || // V
        upper == 0x43 || // C
        upper == 0x53 || // S
        upper == 0x51 || // Q
        upper == 0x54 || // T
        upper == 0x41 || // A
        upper == 0x5A) {
      // Z
      return cu;
    }
    return null;
  }

  bool? readArcFlag() {
    skipSeparators();
    if (pos >= src.length) return null;
    final cu = src.codeUnitAt(pos);
    if (cu == 0x30) {
      pos++;
      return false;
    }
    if (cu == 0x31) {
      pos++;
      return true;
    }
    return null;
  }

  double? readNumber() {
    skipSeparators();
    if (pos >= src.length) return null;
    final start = pos;
    var cu = src.codeUnitAt(pos);
    if (cu == 0x2B || cu == 0x2D) {
      pos++;
    }

    var hasDigits = false;
    while (pos < src.length) {
      cu = src.codeUnitAt(pos);
      if (cu >= 0x30 && cu <= 0x39) {
        hasDigits = true;
        pos++;
      } else {
        break;
      }
    }

    if (pos < src.length && src.codeUnitAt(pos) == 0x2E) {
      pos++;
      while (pos < src.length) {
        cu = src.codeUnitAt(pos);
        if (cu >= 0x30 && cu <= 0x39) {
          hasDigits = true;
          pos++;
        } else {
          break;
        }
      }
    }

    if (!hasDigits) {
      pos = start;
      return null;
    }

    if (pos < src.length) {
      cu = src.codeUnitAt(pos);
      if (cu == 0x65 || cu == 0x45) {
        final expPos = pos;
        pos++;
        if (pos < src.length) {
          final signCu = src.codeUnitAt(pos);
          if (signCu == 0x2B || signCu == 0x2D) {
            pos++;
          }
        }
        var expDigits = false;
        while (pos < src.length) {
          final dCu = src.codeUnitAt(pos);
          if (dCu >= 0x30 && dCu <= 0x39) {
            expDigits = true;
            pos++;
          } else {
            break;
          }
        }
        if (!expDigits) {
          pos = expPos;
        }
      }
    }

    return double.tryParse(src.substring(start, pos));
  }
}
