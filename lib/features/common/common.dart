import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../core/money.dart';

const _uuid = Uuid();

String safeMessage(Object error) =>
    error is Failure ? error.message : '操作未完成，请重试。';

/// "1234.50" from minor units.
String formatMinor(BigInt minor) => Money.minor(minor).decimal;

/// Keeps the same command id while the submitted payload is unchanged, so a
/// retried submit is idempotent and an edited form gets a new id (ADR-009).
final class CommandIds {
  String? _payload;
  String? _id;
  String forPayload(Object? payload) {
    final text = jsonEncode(payload);
    if (text != _payload || _id == null) {
      _payload = text;
      _id = _uuid.v4();
    }
    return _id!;
  }
}

class ErrorView extends ConsumerWidget {
  const ErrorView(this.error, {super.key});
  final Object error;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(safeMessage(error), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => ref.invalidate(databaseProvider),
            child: const Text('重试'),
          ),
        ],
      ),
    ),
  );
}

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}

/// Renders an AsyncValue with shared loading/error views.
Widget asyncBody<T>(AsyncValue<T> value, Widget Function(T data) data) =>
    value.when(
      data: data,
      loading: () => const Loading(),
      error: (e, _) => ErrorView(e),
    );

Future<bool> confirm(
  BuildContext context, {
  required String title,
  String? message,
  String ok = '确定',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: message == null ? null : Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(ok),
          ),
        ],
      ),
    ) ==
    true;

String two(int v) => v.toString().padLeft(2, '0');
String formatDate(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
String formatDateTime(DateTime d) =>
    '${formatDate(d)} ${two(d.hour)}:${two(d.minute)}';
