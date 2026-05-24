import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/foto_comprobante_provider.dart';
import '../../data/providers/impresora_provider.dart';
import '../../data/providers/sync_status_provider.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../auth/cambiar_password_dialog.dart';
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
          if (email != null) (null, 'Email', email),
          (Icons.phone, 'Teléfono', cobrador.telefono ?? '—'),
          (Icons.receipt, 'Prefijo recibo', cobrador.prefijoRecibo ?? 'No asignado'),
        ]),
        const SizedBox(height: 12),
        const _SyncCard(),
        if (!kIsWeb) ...[
          const SizedBox(height: 12),
          const _ImpresoraCard(),
        ],
        const SizedBox(height: 12),
        const _FotosPendientesCard(),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          icon: const Icon(Icons.lock_outline),
          label: const Text('Cambiar contraseña'),
          onPressed: () => mostrarCambiarPasswordDialog(context),
        ),
        const SizedBox(height: 12),
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

class _ImpresoraCard extends ConsumerWidget {
  const _ImpresoraCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fav = ref.watch(impresoraFavoritaProvider).valueOrNull;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.print),
        title: const Text('Impresora térmica'),
        subtitle: Text(fav == null
            ? 'Sin configurar'
            : fav.nombre,
            style: fav == null
                ? TextStyle(color: Theme.of(context).colorScheme.error)
                : null),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/perfil/impresora'),
      ),
    );
  }
}

class _FotosPendientesCard extends ConsumerStatefulWidget {
  const _FotosPendientesCard();
  @override
  ConsumerState<_FotosPendientesCard> createState() =>
      _FotosPendientesCardState();
}

class _FotosPendientesCardState extends ConsumerState<_FotosPendientesCard> {
  bool _ejecutando = false;

  // Cacheamos el stream de PowerSync en initState para evitar que cada
  // rebuild cree una nueva suscripción (anti-patrón ps.db.watch inline).
  // La query no tiene parámetros dinámicos, así que late final alcanza.
  late final Stream<List<Map<String, dynamic>>> _pendientesStream;

  @override
  void initState() {
    super.initState();
    _pendientesStream = ps.db.watch(
      "SELECT COUNT(*) AS n FROM pagos "
      "WHERE foto_comprobante_path LIKE 'local://%' AND anulado = 0",
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: _pendientesStream,
      builder: (context, snap) {
        final pendientes = snap.data == null || snap.data!.isEmpty
            ? 0
            : (snap.data!.first['n'] as num).toInt();
        if (pendientes == 0 && !_ejecutando) {
          return const SizedBox.shrink();
        }
        final scheme = Theme.of(context).colorScheme;
        return Card(
          color: scheme.tertiaryContainer.withValues(alpha: 0.4),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.cloud_upload, color: scheme.tertiary),
                    const SizedBox(width: 8),
                    Text('Fotos pendientes de subir',
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 8),
                Text('$pendientes foto(s) están guardadas en este teléfono y '
                    'se subirán automáticamente cuando haya conexión.'),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    icon: _ejecutando
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                    label: Text(_ejecutando ? 'Subiendo...' : 'Intentar ahora'),
                    onPressed: _ejecutando ? null : _intentar,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _intentar() async {
    setState(() => _ejecutando = true);
    try {
      final n = await ref
          .read(fotoComprobanteServiceProvider)
          .sincronizarPendientes();
      if (mounted) {
        // Mostramos sólo el feedback positivo. Los errores de upload
        // los surfacea el listener global en app.dart (R8) — sino
        // mostraríamos dos SnackBars solapados con mensajes
        // contradictorios cuando la corrida es parcial.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(n == 0
              ? 'No hay fotos elegibles para subir ahora.'
              : '$n foto(s) subidas')),
        );
      }
    } catch (e) {
      // sincronizarPendientes captura sus propios errores de upload
      // y los emite por el stream. Si llegamos acá es algo inesperado
      // (provider disposed, etc.) — logueamos sin molestar al user.
      if (kDebugMode) debugPrint('_intentar: error inesperado: $e');
    } finally {
      if (mounted) setState(() => _ejecutando = false);
    }
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
