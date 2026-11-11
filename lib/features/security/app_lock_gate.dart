import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/failure.dart';
import '../../domain/rules/app_lock_rules.dart';
import '../common/common.dart';
import 'app_lock_providers.dart';

/// Full-screen security shield wrapping the application UI (`F-024`, `R4`, `R5`).
///
/// While locked (or before initial lock configuration has resolved on cold
/// start), [child] is kept mounted with `Visibility(visible: false, maintainState: true)`
/// so navigation state is preserved while hiding all ledger figures, pointer
/// events, focus traversal, and accessibility semantics.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  String _enteredPin = '';
  bool _verifying = false;
  String? _localMessage;

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
    final notifier = ref.read(appLockSessionProvider.notifier);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        notifier.onAppBackgrounded();
      case AppLifecycleState.resumed:
        notifier.onAppResumed();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _onDigitPressed(String digit, AppLockConfig config) async {
    if (_verifying) return;
    final now = ref.read(appLockClockProvider)();
    if (config.isCoolingDownAt(now)) {
      final secs = config.remainingCooldownSecondsAt(now);
      setState(() {
        _enteredPin = '';
        _localMessage = '密码连续错误次数过多，请等待 $secs 秒后再试';
      });
      return;
    }

    if (_enteredPin.length >= config.pinLength) return;
    final nextPin = '$_enteredPin$digit';
    setState(() {
      _enteredPin = nextPin;
      _localMessage = null;
    });

    if (nextPin.length == config.pinLength) {
      await _submitPin(nextPin);
    }
  }

  void _onBackspace() {
    if (_verifying || _enteredPin.isEmpty) return;
    setState(() {
      _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
    });
  }

  void _onClear() {
    if (_verifying || _enteredPin.isEmpty) return;
    setState(() {
      _enteredPin = '';
    });
  }

  Future<void> _submitPin(String candidate) async {
    setState(() => _verifying = true);
    try {
      final outcome = await ref
          .read(appLockSessionProvider.notifier)
          .unlockWithPin(candidate);
      if (!mounted) return;
      setState(() {
        _enteredPin = '';
        _localMessage = outcome.matched ? null : outcome.message;
      });
    } on Failure catch (e) {
      if (!mounted) return;
      setState(() {
        _enteredPin = '';
        _localMessage = e.message;
      });
    } finally {
      if (mounted) {
        setState(() => _verifying = false);
      }
    }
  }

  Future<void> _triggerBiometricUnlock() async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _localMessage = null;
    });
    try {
      final result = await ref
          .read(appLockSessionProvider.notifier)
          .unlockWithBiometrics();
      if (!mounted) return;
      if (!result.isAuthenticated) {
        setState(() => _localMessage = result.message);
      } else {
        setState(() => _enteredPin = '');
      }
    } finally {
      if (mounted) {
        setState(() => _verifying = false);
      }
    }
  }

  Future<void> _showForgotPinHelpDialog(
    BuildContext context,
  ) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('忘记安全锁密码？'),
      content: const Text(
        '帐屿采用纯本地无账号隐私架构（P-03），您的密码仅以加盐迭代哈希形式保存在本机，没有任何云端后门可跳过验证。\n\n'
        '若确实遗忘密码且未开启生物识别，可在系统设置中清除应用数据后，重新导入您此前保存的 .tally 本地备份或 WebDAV 备份恢复账本。',
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(appLockConfigProvider);
    final session = ref.watch(appLockSessionProvider);
    final bioAvailAsync = ref.watch(biometricAvailabilityProvider);

    final isResolvingInitial =
        !session.initializedColdStart && configAsync.isLoading;
    final config = configAsync.value ?? AppLockConfig.disabled;
    final hideLedger =
        isResolvingInitial || (config.isConfigured && session.isLocked);

    return Stack(
      children: [
        Visibility(
          visible: !hideLedger,
          maintainState: true,
          child: widget.child,
        ),
        if (isResolvingInitial)
          const Positioned.fill(
            child: Material(
              key: Key('app_lock_loading_shield'),
              child: Loading(),
            ),
          )
        else if (config.isConfigured && session.isLocked)
          Positioned.fill(
            child: Navigator(
              pages: [
                MaterialPage<void>(
                  key: const ValueKey<String>('app_lock_shield_page'),
                  child: Builder(
                    builder: (navContext) => _LockOverlayScreen(
                      config: config,
                      enteredLength: _enteredPin.length,
                      verifying: _verifying,
                      message: _localMessage ?? session.feedbackMessage,
                      nowMs: ref.read(appLockClockProvider)(),
                      canUseBiometric:
                          config.biometricEnabled &&
                          (bioAvailAsync.value?.canAuthenticate ?? false),
                      onDigit: (d) => unawaited(_onDigitPressed(d, config)),
                      onBackspace: _onBackspace,
                      onClear: _onClear,
                      onBiometric: () => unawaited(_triggerBiometricUnlock()),
                      onForgotHelp: () =>
                          unawaited(_showForgotPinHelpDialog(navContext)),
                    ),
                  ),
                ),
              ],
              onDidRemovePage: (_) {},
            ),
          ),
      ],
    );
  }
}

class _LockOverlayScreen extends StatelessWidget {
  const _LockOverlayScreen({
    required this.config,
    required this.enteredLength,
    required this.verifying,
    required this.message,
    required this.nowMs,
    required this.canUseBiometric,
    required this.onDigit,
    required this.onBackspace,
    required this.onClear,
    required this.onBiometric,
    required this.onForgotHelp,
  });

  final AppLockConfig config;
  final int enteredLength;
  final bool verifying;
  final String? message;
  final int nowMs;
  final bool canUseBiometric;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onBiometric;
  final VoidCallback onForgotHelp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coolingDown = config.isCoolingDownAt(nowMs);
    final cooldownSecs = config.remainingCooldownSecondsAt(nowMs);
    final effectiveMessage = coolingDown
        ? '已连续输错 $maxPinFailedAttempts 次，请等待 $cooldownSecs 秒后再试'
        : message;

    return Material(
      key: const Key('app_lock_overlay'),
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 44,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text('帐屿已锁定', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 6),
                  Text(
                    '请输入 ${config.pinLength} 位数字密码解锁',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    key: const Key('app_lock_pin_dots'),
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < config.pinLength; i++)
                        Container(
                          width: 14,
                          height: 14,
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i < enteredLength
                                ? theme.colorScheme.primary
                                : Colors.transparent,
                            border: Border.all(
                              color: theme.colorScheme.primary,
                              width: 1.8,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 40,
                    child: Center(
                      child: effectiveMessage == null
                          ? const SizedBox.shrink()
                          : Text(
                              effectiveMessage,
                              key: const Key('app_lock_message'),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _PinNumericKeypad(
                    enabled: !verifying,
                    onDigit: onDigit,
                    onBackspace: onBackspace,
                    onClear: onClear,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    children: [
                      if (canUseBiometric)
                        TextButton.icon(
                          key: const Key('app_lock_biometric_button'),
                          onPressed: verifying ? null : onBiometric,
                          icon: const Icon(Icons.fingerprint),
                          label: const Text('使用生物识别解锁'),
                        ),
                      TextButton(
                        key: const Key('app_lock_forgot_button'),
                        onPressed: onForgotHelp,
                        child: const Text('忘记密码？'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinNumericKeypad extends StatelessWidget {
  const _PinNumericKeypad({
    required this.enabled,
    required this.onDigit,
    required this.onBackspace,
    required this.onClear,
  });

  final bool enabled;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onClear;

  Widget _digitBtn(BuildContext context, String digit) => Expanded(
    child: Padding(
      padding: const EdgeInsets.all(6),
      child: OutlinedButton(
        key: Key('app_lock_key_$digit'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 54),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        onPressed: enabled ? () => onDigit(digit) : null,
        child: Text(digit, style: Theme.of(context).textTheme.titleLarge),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          _digitBtn(context, '1'),
          _digitBtn(context, '2'),
          _digitBtn(context, '3'),
        ],
      ),
      Row(
        children: [
          _digitBtn(context, '4'),
          _digitBtn(context, '5'),
          _digitBtn(context, '6'),
        ],
      ),
      Row(
        children: [
          _digitBtn(context, '7'),
          _digitBtn(context, '8'),
          _digitBtn(context, '9'),
        ],
      ),
      Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: TextButton(
                key: const Key('app_lock_key_clear'),
                style: TextButton.styleFrom(minimumSize: const Size(64, 54)),
                onPressed: enabled ? onClear : null,
                child: const Text('清空'),
              ),
            ),
          ),
          _digitBtn(context, '0'),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: IconButton(
                key: const Key('app_lock_key_backspace'),
                tooltip: '退格',
                onPressed: enabled ? onBackspace : null,
                icon: const Icon(Icons.backspace_outlined),
              ),
            ),
          ),
        ],
      ),
    ],
  );
}
