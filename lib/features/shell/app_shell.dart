import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/router.dart';
import '../../data/providers/crud_error_provider.dart';
import '../../data/providers/mora_count_provider.dart';
import '../../data/providers/sync_status_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../shared/utils/shell_nav.dart';
import 'global_search_delegate.dart';
import '../shared/widgets/offline_banner.dart';
import '../shared/widgets/update_banner.dart';

/// Scaffold con bottom-nav compartido por las pantallas raíz del cobrador
/// (Cobros · Clientes · Mapa · Perfil). Las pantallas detalle/cobro/recibo
/// se pushean con su propio Scaffold, fuera de este shell.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(crudUploadErrorProvider, (_, next) {
      final error = next.valueOrNull;
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al sincronizar ${error.table}: ${error.message}'),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    });

    final empresaNombre = ref.watch(appSettingsProvider).empresaNombre;
    final titulo = ShellTitleScope.of(context) ??
        (empresaNombre.isNotEmpty ? empresaNombre : 'SITECSA CRM');
    return Scaffold(
      appBar: AppBar(
        title: Text(titulo),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Buscar',
            onPressed: () => showSearch(
              context: context,
              delegate: GlobalSearchDelegate(),
            ),
          ),
          const _SyncIndicator(),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          const UpdateBanner(),
          Expanded(child: OfflineBanner(child: child)),
        ],
      ),
      bottomNavigationBar: const _AppBottomNav(),
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

/// Bottom-nav del cobrador: 4 destinos (Cobros · Clientes · Mapa · Perfil).
/// "Cobros" es la landing (`/`) y lleva el badge de cuotas en mora.
/// (Cerrar sesión, cambiar contraseña, impresora e historial viven en Perfil.)
class _AppBottomNav extends ConsumerWidget {
  const _AppBottomNav();

  static const _rutas = ['/', '/clientes', '/mapa', '/perfil'];

  int _indexFor(String path) {
    if (path.startsWith('/clientes')) return 1;
    if (path.startsWith('/mapa')) return 2;
    if (path.startsWith('/perfil')) return 3;
    return 0; // Cobros: '/' y pushes sin tab propia.
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = GoRouterState.of(context).uri.path;
    final moraCount = ref.watch(moraCountProvider).valueOrNull ?? 0;
    return NavigationBar(
      selectedIndex: _indexFor(path),
      onDestinationSelected: (i) => context.closeModalsAndGo(_rutas[i]),
      destinations: [
        NavigationDestination(
          icon: Badge(
            isLabelVisible: moraCount > 0,
            label: Text('$moraCount'),
            child: const Icon(Icons.receipt_long_outlined),
          ),
          selectedIcon: Badge(
            isLabelVisible: moraCount > 0,
            label: Text('$moraCount'),
            child: const Icon(Icons.receipt_long),
          ),
          label: 'Cobros',
        ),
        const NavigationDestination(
          icon: Icon(Icons.people_outline),
          selectedIcon: Icon(Icons.people),
          label: 'Clientes',
        ),
        const NavigationDestination(
          icon: Icon(Icons.map_outlined),
          selectedIcon: Icon(Icons.map),
          label: 'Mapa',
        ),
        const NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: 'Perfil',
        ),
      ],
    );
  }
}
