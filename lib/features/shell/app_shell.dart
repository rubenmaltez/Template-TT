import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/router.dart';
import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/mora_count_provider.dart';
import '../../data/providers/sync_status_provider.dart';
import '../shared/utils/shell_nav.dart';
import '../shared/widgets/offline_banner.dart';
import '../shared/widgets/update_banner.dart';

/// Scaffold con drawer compartido por todas las pantallas raíz (las
/// pantallas detalle/cobro/recibo tienen su propio Scaffold).
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final titulo = ShellTitleScope.of(context) ?? 'Cobranza ISP';
    return Scaffold(
      drawer: const _AppDrawer(),
      appBar: AppBar(
        title: Text(titulo),
        actions: const [_SyncIndicator(), SizedBox(width: 8)],
      ),
      body: Column(
        children: [
          const UpdateBanner(),
          Expanded(child: OfflineBanner(child: child)),
        ],
      ),
    );
  }
}

class _SyncIndicator extends ConsumerWidget {
  const _SyncIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider);
    final scheme = Theme.of(context).colorScheme;

    return status.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (_, __) => Icon(Icons.error_outline, color: scheme.error),
      data: (s) {
        final connected = s?.connected ?? false;
        final downloading = s?.downloading ?? false;
        final uploading = s?.uploading ?? false;
        final color = !connected
            ? scheme.error
            : (downloading || uploading)
                ? scheme.tertiary
                : scheme.primary;
        final icon = !connected
            ? Icons.cloud_off
            : (downloading || uploading)
                ? Icons.cloud_sync
                : Icons.cloud_done;
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Tooltip(
            message: !connected
                ? 'Sin conexión'
                : (downloading || uploading)
                    ? 'Sincronizando'
                    : 'Sincronizado',
            child: Icon(icon, color: color),
          ),
        );
      },
    );
  }
}

class _AppDrawer extends ConsumerWidget {
  const _AppDrawer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final scheme = Theme.of(context).colorScheme;

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: scheme.primaryContainer),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: scheme.primary,
                    child: Text(
                      _initials(cobrador?.nombre),
                      style: TextStyle(color: scheme.onPrimary, fontSize: 22),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    cobrador?.nombre ?? '—',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    _rolDisplay(cobrador?.rol),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            _navTile(context, Icons.dashboard_outlined, 'Inicio', '/'),
            _navTile(context, Icons.people_outline, 'Clientes', '/clientes'),
            _navTileWithBadge(context, ref, Icons.receipt_long_outlined, 'Cuotas pendientes', '/cuotas'),
            _navTile(context, Icons.map_outlined, 'Mapa', '/mapa'),
            _navTile(context, Icons.history_outlined, 'Historial', '/historial'),
            const Divider(),
            _navTile(context, Icons.person_outline, 'Mi perfil', '/perfil'),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Cerrar sesión'),
              // Cierra el drawer + dialogs antes del signOut para que
              // ningún modal flote sobre /login tras el redirect.
              onTap: () => context.closeModalsThenRun(
                  () => Supabase.instance.client.auth.signOut()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navTileWithBadge(BuildContext context, WidgetRef ref, IconData icon, String label, String path) {
    final moraCount = ref.watch(moraCountProvider).valueOrNull ?? 0;
    return ListTile(
      leading: Badge(
        isLabelVisible: moraCount > 0,
        label: Text('$moraCount'),
        child: Icon(icon),
      ),
      title: Text(label),
      onTap: () => context.closeModalsAndGo(path),
    );
  }

  Widget _navTile(BuildContext context, IconData icon, String label, String path) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      // closeModalsAndGo cierra el drawer + cualquier dialog que el user
      // haya dejado abierto antes de navegar. Sin esto, en algunas rutas
      // un dialog imperativo (showDialog) queda flotando sobre la nueva
      // ruta porque go_router no desmonta PopupRoutes al cambiar shell child.
      onTap: () => context.closeModalsAndGo(path),
    );
  }

  String _initials(String? nombre) {
    if (nombre == null || nombre.trim().isEmpty) return '?';
    final parts = nombre.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  String _rolDisplay(String? rol) {
    switch (rol) {
      case 'admin':
        return 'Administrador';
      case 'admin_cobranza':
        return 'Admin de cobranza';
      case 'cobrador':
        return 'Cobrador';
      default:
        return '—';
    }
  }
}
