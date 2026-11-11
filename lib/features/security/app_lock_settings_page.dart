import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/rules/app_lock_rules.dart';
import '../../platform/biometrics.dart';
import '../common/common.dart';
import 'app_lock_providers.dart';

/// Settings page for configuring App Lock (`F-024`):
/// - Enable 4/6-digit salted hashed PIN
/// - Change or disable PIN (requires verifying current PIN)
/// - Toggle OS biometric unlock (`ADR-008`)
/// - Select background lock timeout (`0 / 30 / 60 / 300` seconds)
class AppLockSettingsPage extends ConsumerStatefulWidget {
  const AppLockSettingsPage({super.key});

  @override
  ConsumerState<AppLockSettingsPage> createState() =>
      _AppLockSettingsPageState();
}

class _AppLockSettingsPageState extends ConsumerState<AppLockSettingsPage> {
  final _commandIds = CommandIds();
  bool _busy = false;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openEnableDialog() async {
    final result = await showDialog<({String pin, int length})>(
      context: context,
      builder: (_) => const _SetNewPinDialog(requireCurrentPin: false),
    );
    if (result == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = await ref.read(appLockServiceProvider.future);
      final cmdId = _commandIds.forPayload([
        'enable',
        result.length,
        DateTime.now().microsecondsSinceEpoch,
      ]);
      await service.enableAppLock(commandId: cmdId, pin: result.pin);
      _toast('已启用应用安全锁');
    } catch (e) {
      _toast(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openChangePinDialog(AppLockConfig config) async {
    final result = await showDialog<({String currentPin, String newPin})>(
      context: context,
      builder: (_) => _ChangePinDialog(currentPinLength: config.pinLength),
    );
    if (result == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = await ref.read(appLockServiceProvider.future);
      final cmdId = _commandIds.forPayload([
        'change-pin',
        result.newPin.length,
        DateTime.now().microsecondsSinceEpoch,
      ]);
      await service.changePin(
        commandId: cmdId,
        currentPin: result.currentPin,
        newPin: result.newPin,
      );
      _toast('密码已修改');
    } catch (e) {
      _toast(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDisableDialog(AppLockConfig config) async {
    final currentPin = await showDialog<String>(
      context: context,
      builder: (_) => _VerifyCurrentPinDialog(
        title: '关闭应用安全锁',
        pinLength: config.pinLength,
      ),
    );
    if (currentPin == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = await ref.read(appLockServiceProvider.future);
      final cmdId = _commandIds.forPayload([
        'disable',
        DateTime.now().microsecondsSinceEpoch,
      ]);
      await service.disableAppLock(commandId: cmdId, currentPin: currentPin);
      _toast('已关闭应用安全锁');
    } catch (e) {
      _toast(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleBiometric(
    AppLockConfig config,
    BiometricAvailability availability,
    bool value,
  ) async {
    if (_busy || !config.isConfigured) return;
    if (value && !availability.canAuthenticate) {
      _toast(availability.reason);
      return;
    }

    setState(() => _busy = true);
    try {
      final service = await ref.read(appLockServiceProvider.future);
      if (value) {
        final verify = await service.authenticator.authenticate(
          title: '验证生物识别以开启快捷解锁',
          subtitle: '开启后可使用系统指纹或面容解锁帐屿',
          negativeButtonText: '取消',
        );
        if (!verify.isAuthenticated) {
          _toast(verify.message);
          return;
        }
      }
      final cmdId = _commandIds.forPayload([
        'bio-toggle',
        value,
        config.updatedAtMs,
      ]);
      await service.updateLockOptions(
        commandId: cmdId,
        biometricEnabled: value,
      );
      _toast(value ? '已开启生物识别解锁' : '已关闭生物识别解锁');
    } catch (e) {
      _toast(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectTimeout(AppLockConfig config, int seconds) async {
    if (_busy || !config.isConfigured || config.timeoutSeconds == seconds) {
      return;
    }
    setState(() => _busy = true);
    try {
      final service = await ref.read(appLockServiceProvider.future);
      final cmdId = _commandIds.forPayload([
        'timeout',
        seconds,
        config.updatedAtMs,
      ]);
      await service.updateLockOptions(
        commandId: cmdId,
        timeoutSeconds: seconds,
      );
    } catch (e) {
      _toast(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(appLockConfigProvider);
    final bioAsync = ref.watch(biometricAvailabilityProvider);
    final theme = Theme.of(context);

    return Scaffold(
      key: const Key('app_lock_settings_page'),
      appBar: AppBar(title: const Text('应用安全锁')),
      body: asyncBody(configAsync, (config) {
        final bio =
            bioAsync.value ??
            const BiometricAvailability(
              status: BiometricAvailabilityStatus.unsupportedPlatform,
              reason: '正在检测设备生物识别支持状态…',
            );

        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                children: [
                  SwitchListTile(
                    key: const Key('app_lock_enable_switch'),
                    secondary: Icon(
                      config.isConfigured ? Icons.lock : Icons.lock_open,
                    ),
                    title: const Text('启用数字密码安全锁'),
                    subtitle: Text(
                      config.isConfigured
                          ? '已启用 ${config.pinLength} 位加盐哈希密码保护'
                          : '开启后冷启动或从后台切回时需验证身份',
                    ),
                    value: config.isConfigured,
                    onChanged: _busy
                        ? null
                        : (next) => next
                              ? _openEnableDialog()
                              : _openDisableDialog(config),
                  ),
                  if (config.isConfigured) ...[
                    const Divider(height: 1),
                    ListTile(
                      key: const Key('app_lock_change_pin_tile'),
                      leading: const Icon(Icons.password_outlined),
                      title: const Text('修改数字密码'),
                      subtitle: Text(
                        '当前为 ${config.pinLength} 位数字密码（支持切换 4/6 位）',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      enabled: !_busy,
                      onTap: () => _openChangePinDialog(config),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const Key('app_lock_lock_now_button'),
                      leading: const Icon(Icons.phonelink_lock_outlined),
                      title: const Text('立即锁定'),
                      subtitle: const Text('立刻遮蔽账本界面并进入锁屏状态'),
                      enabled: !_busy,
                      onTap: () {
                        ref.read(appLockSessionProvider.notifier).lockNow();
                        _toast('应用已锁定');
                      },
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                '生物识别与自动锁定',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    key: const Key('app_lock_biometric_switch'),
                    secondary: const Icon(Icons.fingerprint),
                    title: const Text('使用系统生物识别解锁'),
                    subtitle: Text(bio.reason),
                    value: config.isConfigured && config.biometricEnabled,
                    onChanged:
                        (!_busy && config.isConfigured && bio.canAuthenticate)
                        ? (v) => _toggleBiometric(config, bio, v)
                        : null,
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                    child: Text('后台切回锁定延迟', style: theme.textTheme.titleSmall),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final sec in allowedLockTimeouts)
                          ChoiceChip(
                            key: Key('app_lock_timeout_$sec'),
                            label: Text(lockTimeoutLabel(sec)),
                            selected: config.timeoutSeconds == sec,
                            onSelected: (!_busy && config.isConfigured)
                                ? (_) => _selectTimeout(config, sec)
                                : null,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Text(
                '安全说明：数字密码采用 16 字节随机盐与至少 10,000 轮 PBKDF2-HMAC-SHA256 单向派生存储，'
                '不保存明文密码；连续输错 5 次将锁定冷却 30 秒。请定期通过「备份与恢复」导出 .tally 备份。',
                style: TextStyle(fontSize: 12.5),
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _SetNewPinDialog extends StatefulWidget {
  const _SetNewPinDialog({required this.requireCurrentPin});
  final bool requireCurrentPin;

  @override
  State<_SetNewPinDialog> createState() => _SetNewPinDialogState();
}

class _SetNewPinDialogState extends State<_SetNewPinDialog> {
  int _pinLength = 4;
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _pinController.text.trim();
    final confirmPin = _confirmController.text.trim();
    try {
      validatePinFormat(pin, expectedLength: _pinLength);
    } catch (e) {
      setState(() => _error = safeMessage(e));
      return;
    }
    if (pin != confirmPin) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }
    Navigator.of(context).pop((pin: pin, length: _pinLength));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('设置安全锁密码'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<int>(
            key: const Key('set_pin_length_selector'),
            segments: const [
              ButtonSegment<int>(value: 4, label: Text('4 位密码')),
              ButtonSegment<int>(value: 6, label: Text('6 位密码')),
            ],
            selected: <int>{_pinLength},
            onSelectionChanged: (s) => setState(() {
              _pinLength = s.first;
              _pinController.clear();
              _confirmController.clear();
              _error = null;
            }),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('new_pin_input'),
            controller: _pinController,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: _pinLength,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: '输入 $_pinLength 位数字密码'),
          ),
          TextField(
            key: const Key('confirm_pin_input'),
            controller: _confirmController,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: _pinLength,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: '再次确认 $_pinLength 位数字密码',
              errorText: _error,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('confirm_set_pin_button'),
        onPressed: _submit,
        child: const Text('保存'),
      ),
    ],
  );
}

class _ChangePinDialog extends StatefulWidget {
  const _ChangePinDialog({required this.currentPinLength});
  final int currentPinLength;

  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  late int _newLength = widget.currentPinLength;
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _submit() {
    final currentPin = _currentController.text.trim();
    final newPin = _newController.text.trim();
    final confirmPin = _confirmController.text.trim();
    try {
      validatePinFormat(currentPin, expectedLength: widget.currentPinLength);
      validatePinFormat(newPin, expectedLength: _newLength);
    } catch (e) {
      setState(() => _error = safeMessage(e));
      return;
    }
    if (newPin != confirmPin) {
      setState(() => _error = '两次输入的新密码不一致');
      return;
    }
    Navigator.of(context).pop((currentPin: currentPin, newPin: newPin));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('修改数字密码'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('change_current_pin_input'),
            controller: _currentController,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: widget.currentPinLength,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: '当前 ${widget.currentPinLength} 位密码',
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment<int>(value: 4, label: Text('新 4 位')),
              ButtonSegment<int>(value: 6, label: Text('新 6 位')),
            ],
            selected: <int>{_newLength},
            onSelectionChanged: (s) => setState(() {
              _newLength = s.first;
              _newController.clear();
              _confirmController.clear();
              _error = null;
            }),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('change_new_pin_input'),
            controller: _newController,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: _newLength,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: '输入新 $_newLength 位密码'),
          ),
          TextField(
            key: const Key('change_confirm_pin_input'),
            controller: _confirmController,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: _newLength,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: '确认新 $_newLength 位密码',
              errorText: _error,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('confirm_change_pin_button'),
        onPressed: _submit,
        child: const Text('确认修改'),
      ),
    ],
  );
}

class _VerifyCurrentPinDialog extends StatefulWidget {
  const _VerifyCurrentPinDialog({required this.title, required this.pinLength});
  final String title;
  final int pinLength;

  @override
  State<_VerifyCurrentPinDialog> createState() =>
      _VerifyCurrentPinDialogState();
}

class _VerifyCurrentPinDialogState extends State<_VerifyCurrentPinDialog> {
  final _pinController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _pinController.text.trim();
    try {
      validatePinFormat(pin, expectedLength: widget.pinLength);
    } catch (e) {
      setState(() => _error = safeMessage(e));
      return;
    }
    Navigator.of(context).pop(pin);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const Key('verify_current_pin_input'),
      controller: _pinController,
      keyboardType: TextInputType.number,
      obscureText: true,
      maxLength: widget.pinLength,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: '请输入当前 ${widget.pinLength} 位密码确认',
        errorText: _error,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('confirm_verify_pin_button'),
        onPressed: _submit,
        child: const Text('确认'),
      ),
    ],
  );
}
