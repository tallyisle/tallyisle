import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/failure.dart';
import '../../domain/rules/reminder_rules.dart';
import '../common/common.dart';
import 'reminder_providers.dart';

class ReminderPage extends ConsumerStatefulWidget {
  const ReminderPage({super.key});

  @override
  ConsumerState<ReminderPage> createState() => _ReminderPageState();
}

class _ReminderPageState extends ConsumerState<ReminderPage>
    with WidgetsBindingObserver {
  final _ids = CommandIds();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      ref.invalidate(reminderNotificationPermissionProvider);
    }
  }

  Future<void> _handleEnablePermission() async {
    try {
      final service = await ref.read(reminderServiceProvider.future);
      final granted = await service.requestNotificationPermission();
      if (!granted) {
        await service.openNotificationSettings();
      }
      if (mounted) {
        ref.invalidate(reminderNotificationPermissionProvider);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _openEditor({ReminderItem? existing}) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => _ReminderEditorDialog(existing: existing),
    );
  }

  Future<void> _confirmAndDelete(ReminderItem item) async {
    final confirmed = await confirm(
      context,
      title: '确认删除此提醒？',
      message: '删除后将不再按时发送「${item.displayTime}」的记账提醒。',
      ok: '删除',
    );
    if (!confirmed || !mounted) return;
    try {
      final service = await ref.read(reminderServiceProvider.future);
      await service.deleteReminder(
        commandId: _ids.forPayload(['delete-reminder', item.id]),
        id: item.id,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final remindersAsync = ref.watch(remindersProvider);
    final permissionAsync = ref.watch(reminderNotificationPermissionProvider);
    final showPermissionBanner = permissionAsync.maybeWhen(
      data: (enabled) => !enabled,
      orElse: () => false,
    );

    return Scaffold(
      key: const Key('reminder_page'),
      appBar: AppBar(title: const Text('记账提醒')),
      body: Column(
        children: [
          if (showPermissionBanner)
            _PermissionBanner(onEnablePressed: _handleEnablePermission),
          Expanded(
            child: asyncBody(remindersAsync, (items) {
              if (items.isEmpty) {
                return const Center(
                  key: Key('reminder_empty_state'),
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.notifications_none_outlined,
                          size: 56,
                          color: Colors.grey,
                        ),
                        SizedBox(height: 12),
                        Text(
                          '暂无记账提醒',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          '点击右下角按钮添加每日定时提醒',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return Card(
                    key: Key('reminder_item_${item.id}'),
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      onTap: () => unawaited(_openEditor(existing: item)),
                      leading: CircleAvatar(
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primaryContainer,
                        child: Icon(
                          Icons.alarm,
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                        ),
                      ),
                      title: Text(
                        item.displayTime,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      subtitle: Text(item.displayTip),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: Key('edit_reminder_${item.id}'),
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: '编辑',
                            onPressed: () =>
                                unawaited(_openEditor(existing: item)),
                          ),
                          IconButton(
                            key: Key('delete_reminder_${item.id}'),
                            icon: const Icon(Icons.delete_outline),
                            tooltip: '删除',
                            onPressed: () => unawaited(_confirmAndDelete(item)),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            }),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_reminder_fab'),
        heroTag: 'fab-add-reminder',
        onPressed: () => unawaited(_openEditor()),
        icon: const Icon(Icons.add),
        label: const Text('新建提醒'),
      ),
    );
  }
}

class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner({required this.onEnablePressed});

  final Future<void> Function() onEnablePressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('reminder_permission_banner'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.notifications_off_outlined,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '系统通知权限未开启，到点后可能无法收到记账提醒',
              style: TextStyle(
                color: scheme.onSecondaryContainer,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            key: const Key('reminder_permission_action'),
            onPressed: () => unawaited(onEnablePressed()),
            child: const Text('去开启'),
          ),
        ],
      ),
    );
  }
}

class _ReminderEditorDialog extends ConsumerStatefulWidget {
  const _ReminderEditorDialog({this.existing});

  final ReminderItem? existing;

  @override
  ConsumerState<_ReminderEditorDialog> createState() =>
      _ReminderEditorDialogState();
}

class _ReminderEditorDialogState extends ConsumerState<_ReminderEditorDialog> {
  final _ids = CommandIds();
  late final TextEditingController _hourController;
  late final TextEditingController _minuteController;
  late final TextEditingController _tipController;
  String? _errorMessage;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final initialHour = widget.existing?.time.hour ?? 20;
    final initialMinute = widget.existing?.time.minute ?? 0;
    _hourController = TextEditingController(text: two(initialHour));
    _minuteController = TextEditingController(text: two(initialMinute));
    // CE-RE-05: preserve blank customTip as '' in edit dialog rather than prefilling default copy.
    _tipController = TextEditingController(
      text: widget.existing?.customTip ?? '',
    );
  }

  @override
  void dispose() {
    _hourController.dispose();
    _minuteController.dispose();
    _tipController.dispose();
    super.dispose();
  }

  Future<void> _pickViaSystemClock() async {
    final currentHour = (int.tryParse(_hourController.text.trim()) ?? 20).clamp(
      0,
      23,
    );
    final currentMinute = (int.tryParse(_minuteController.text.trim()) ?? 0)
        .clamp(0, 59);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: currentHour, minute: currentMinute),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _hourController.text = two(picked.hour);
      _minuteController.text = two(picked.minute);
      _errorMessage = null;
    });
  }

  Future<void> _save() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final parsedHour = int.tryParse(_hourController.text.trim());
      final parsedMinute = int.tryParse(_minuteController.text.trim());
      if (parsedHour == null || parsedMinute == null) {
        throw const Failure(FailureCode.validation, '提醒时间无效');
      }
      final validTime = ReminderTime(parsedHour, parsedMinute);

      final service = await ref.read(reminderServiceProvider.future);
      final rawTip = _tipController.text;
      final existing = widget.existing;

      if (existing == null) {
        await service.createReminder(
          commandId: _ids.forPayload([
            'create-reminder',
            validTime.hour,
            validTime.minute,
            rawTip,
          ]),
          hour: validTime.hour,
          minute: validTime.minute,
          tip: rawTip,
        );
      } else {
        await service.updateReminder(
          commandId: _ids.forPayload([
            'update-reminder',
            existing.id,
            validTime.hour,
            validTime.minute,
            rawTip,
          ]),
          id: existing.id,
          hour: validTime.hour,
          minute: validTime.minute,
          tip: rawTip,
        );
      }

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = safeMessage(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return AlertDialog(
      title: Text(isEdit ? '编辑记账提醒' : '新建记账提醒'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '提醒时间（每天 24 小时制）',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 68,
                  child: TextField(
                    key: const Key('reminder_hour_input'),
                    controller: _hourController,
                    enabled: !_submitting,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(2),
                    ],
                    decoration: const InputDecoration(
                      labelText: '时',
                      isDense: true,
                    ),
                    onChanged: (_) {
                      if (_errorMessage != null) {
                        setState(() => _errorMessage = null);
                      }
                    },
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    ':',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                SizedBox(
                  width: 68,
                  child: TextField(
                    key: const Key('reminder_minute_input'),
                    controller: _minuteController,
                    enabled: !_submitting,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(2),
                    ],
                    decoration: const InputDecoration(
                      labelText: '分',
                      isDense: true,
                    ),
                    onChanged: (_) {
                      if (_errorMessage != null) {
                        setState(() => _errorMessage = null);
                      }
                    },
                  ),
                ),
                const Spacer(),
                IconButton(
                  key: const Key('reminder_clock_picker_button'),
                  icon: const Icon(Icons.access_time),
                  tooltip: '拨盘选择时间',
                  onPressed: _submitting
                      ? null
                      : () => unawaited(_pickViaSystemClock()),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('reminder_tip_input'),
              controller: _tipController,
              enabled: !_submitting,
              maxLength: 60,
              decoration: const InputDecoration(
                labelText: '提醒文案（可选）',
                hintText: defaultReminderTip,
                counterText: '',
              ),
              onChanged: (_) {
                if (_errorMessage != null) {
                  setState(() => _errorMessage = null);
                }
              },
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 10),
              Text(
                _errorMessage!,
                key: const Key('reminder_dialog_error'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cancel_reminder_button'),
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('save_reminder_button'),
          onPressed: _submitting ? null : () => unawaited(_save()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
