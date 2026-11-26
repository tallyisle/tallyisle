import 'package:flutter/material.dart';

/// Unified empty-state placeholder with a soft circular icon badge, title,
/// optional subtitle, and optional action button.
class TallyEmptyState extends StatelessWidget {
  const TallyEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.titleKey,
    this.subtitle,
    this.action,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
    this.iconSize = 26,
    this.badgeSize = 56,
  });

  final IconData icon;
  final String title;
  final Key? titleKey;
  final String? subtitle;
  final Widget? action;
  final EdgeInsetsGeometry padding;
  final double iconSize;
  final double badgeSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final badgeColor = cs.brightness == Brightness.dark
        ? cs.primaryContainer.withValues(alpha: 0.32)
        : cs.primaryContainer.withValues(alpha: 0.48);

    return Center(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: badgeSize,
              height: badgeSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: badgeColor,
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: iconSize, color: cs.primary),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              key: titleKey,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
