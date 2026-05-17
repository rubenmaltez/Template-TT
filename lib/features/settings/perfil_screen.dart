import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/sync_status_provider.dart';
import '../../data/utils/formatters.dart';
import '../shared/widgets/empty_state.dart';

class PerfilScreen extends ConsumerWidget {
  const PerfilScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final email = Supabase.instance.client.auth.currentUser?.email;

    if (cobrador == null) {
      return const EmptyState(
        icon: Icons.person_off,
        titulo: 'No hay datos de tu perfil aún',
        descripcion: 'Esperando primera sincronización.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  child: Text(
                    _initials(cobrador.nombre),
                    style: TextStyle(
                      fontSize: 28,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(cobrador.nombre,
                    style: Theme.of(context).textTheme.titleLarge),
                Text(_rolDisplay(cobrador.rol)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _InfoCard([
          if (email != null) (_, 'Email', email),
          (Icons.phone, 'Teléfono', cobrador.telefono ?? '—'),
          (Icons.receipt, 'Prefijo recibo', cobrador.prefijoRecibo ?? 'No asignado'),
        ]),
        const SizedBox(height: 12),
        const _SyncCard(),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          icon: const Icon(Icons.logout),
          label: const Text('Cerrar sesión'),
          onPressed: () => Supabase.instance.client.auth.signOut(),
        ),
      ],
    );
  }

  String _initials(String nombre) {
    final parts = nombre.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  String _rolDisplay(String rol) => switch (rol) {
        'admin' => 'Administrador',
        'admin_cobranza' => 'Admin de cobranza',
        'cobrador' => 'Cobrador',
        _ => rol,
      };
}

class _InfoCard extends StatelessWidget {
  const _InfoCard(this.filas);
  final List<(IconData?, String, String)> filas;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: filas
              .map((f) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        if (f.$1 != null)
                          Icon(f.$1, size: 18, color: scheme.outline),
                        const SizedBox(width: 12),
                        SizedBox(
                            width: 120,
                            child: Text(f.$2,
                                style: TextStyle(color: scheme.outline))),
                        Expanded(child: Text(f.$3)),
                      ],
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

class _SyncCard extends ConsumerWidget {
  const _SyncCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sincronización',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            status.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('Error: $e'),
              data: (s) {
                final connected = s?.connected ?? false;
                final last = s?.lastSyncedAt;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(connected ? Icons.cloud_done : Icons.cloud_off,
                            color: connected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.error),
                        const SizedBox(width: 8),
                        Text(connected ? 'Conectado' : 'Sin conexión'),
                      ],
                    ),
                    if (last != null) ...[
                      const SizedBox(height: 4),
                      Text(
                          'Última sincronización: ${Fmt.fechaCorta(last)} ${Fmt.hora(last)}',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
