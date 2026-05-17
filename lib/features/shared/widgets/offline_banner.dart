import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/sync_status_provider.dart';

/// Banner persistente que aparece cuando PowerSync está desconectado.
/// Pensado para envolver el body de los shells (cobrador y admin).
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider);
    final desconectado = status.valueOrNull?.connected == false;

    return Column(
      children: [
        if (desconectado) _Banner(),
        Expanded(child: child),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.cloud_off, size: 18, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sin conexión. Los cambios se guardan localmente y se '
                  'sincronizarán al volver la red.',
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
