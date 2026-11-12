import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachments/attachment_providers.dart'
    show billAttachmentServiceProvider;
import '../common/common.dart';
import 'receipt_diy_providers.dart';

/// Settings page for customizing the record-editor function toolbar (`F-036`, `/bkp/ARPFDAct`).
class DiyToolbarSettingsPage extends ConsumerStatefulWidget {
  const DiyToolbarSettingsPage({super.key});

  @override
  ConsumerState<DiyToolbarSettingsPage> createState() =>
      _DiyToolbarSettingsPageState();
}

class _DiyToolbarSettingsPageState
    extends ConsumerState<DiyToolbarSettingsPage> {
  final _ids = CommandIds();
  bool _busy = false;
  int _saveSeq = 0;

  static IconData _iconFor(DiyToolbarAction action) => switch (action) {
    DiyToolbarAction.tags => Icons.sell_outlined,
    DiyToolbarAction.images => Icons.photo_camera_back_outlined,
    DiyToolbarAction.discount => Icons.local_offer_outlined,
    DiyToolbarAction.location => Icons.place_outlined,
    DiyToolbarAction.excludeBudget => Icons.pie_chart_outline,
    DiyToolbarAction.excludeExIn => Icons.visibility_off_outlined,
    DiyToolbarAction.currency => Icons.currency_exchange,
    DiyToolbarAction.templates => Icons.bookmarks_outlined,
    DiyToolbarAction.frequentRemarks => Icons.comment_outlined,
  };

  Future<void> _persist(DiyToolbarConfig next) async {
    setState(() => _busy = true);
    try {
      final service = await ref.read(billAttachmentServiceProvider.future);
      final seq = _saveSeq++;
      await service.saveDiyToolbarConfig(
        commandId: _ids.forPayload(['ui-diy-toolbar', seq, next.toJson()]),
        config: next,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(diyToolbarConfigProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('记账工具栏自定义'),
        actions: [
          TextButton(
            key: const Key('diy-toolbar-reset-btn'),
            onPressed: _busy
                ? null
                : () => _persist(DiyToolbarConfig.defaults()),
            child: const Text('恢复默认'),
          ),
        ],
      ),
      body: asyncBody(configAsync, (config) {
        final visible = config.visibleActions;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              key: const Key('diy-toolbar-preview'),
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前启用预览（${visible.length}/${config.items.length}）',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    if (visible.isEmpty)
                      const Text('已隐藏全部工具栏按钮')
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final a in visible)
                            Chip(
                              avatar: Icon(_iconFor(a), size: 16),
                              label: Text(a.label),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                '长按拖拽或点击上下箭头调整顺序，开关控制是否在记一笔页面展示：',
                style: TextStyle(fontSize: 12),
              ),
            ),
            Expanded(
              child: ReorderableListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: config.items.length,
                onReorderItem: (oldIndex, newIndex) {
                  if (_busy) return;
                  _persist(config.moveItem(oldIndex, newIndex));
                },
                itemBuilder: (context, index) {
                  final item = config.items[index];
                  final action = item.action;
                  return ListTile(
                    key: ValueKey('diy-row-${action.key}'),
                    leading: Icon(_iconFor(action)),
                    title: Text(action.label),
                    subtitle: Text(action.description),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: Key('diy-up-${action.key}'),
                          tooltip: '上移',
                          icon: const Icon(Icons.arrow_upward, size: 18),
                          onPressed: _busy || index == 0
                              ? null
                              : () =>
                                    _persist(config.moveItem(index, index - 1)),
                        ),
                        IconButton(
                          key: Key('diy-down-${action.key}'),
                          tooltip: '下移',
                          icon: const Icon(Icons.arrow_downward, size: 18),
                          onPressed: _busy || index == config.items.length - 1
                              ? null
                              : () =>
                                    _persist(config.moveItem(index, index + 1)),
                        ),
                        Switch(
                          key: Key('diy-switch-${action.key}'),
                          value: item.enabled,
                          onChanged: _busy
                              ? null
                              : (enabled) => _persist(
                                  config.setEnabled(action, enabled),
                                ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      }),
    );
  }
}
