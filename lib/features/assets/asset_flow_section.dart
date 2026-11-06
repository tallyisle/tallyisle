import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';

/// The account's bills across all books with an optional reconciliation mode
/// (docs/modules/reconciliation.md). Returns a sliver. Placeholder until the
/// reconciliation module lands.
class AssetFlowSection extends ConsumerWidget {
  const AssetFlowSection({super.key, required this.asset});
  final Asset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      const SliverToBoxAdapter(child: SizedBox.shrink());
}
