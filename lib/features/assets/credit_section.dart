import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';

/// Credit card statements, available limit and pending repayment
/// (docs/modules/credit-account.md). Placeholder until the credit module lands.
class CreditSection extends ConsumerWidget {
  const CreditSection({super.key, required this.asset});
  final Asset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) => const SizedBox.shrink();
}
