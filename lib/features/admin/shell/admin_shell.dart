import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/router.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/sync_status_provider.dart';
import '../../shared/widgets/offline_banner.dart';

/// Shell del admin/admin_cobranza. Layout adaptativo:
///   - ≥ 900px: NavigationRail permanente a la izquierda.
///   - < 900px: Drawer hamburguesa.
class AdminShell extends ConsumerWidget {
  const AdminShell({super.key, required this.child});
  final Widget child;

  static const double _breakpoint = 900;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = MediaQuery.sizeOf(context).width >= _breakpoint;
    final titulo = ShellTitleScope.of(context) ?? 'Panel admin';
    final location = GoRouterState.of(context).matchedLocation;

    if (isDesktop) {
      return Scaffold(
        body: Row(
          children: [
            _AdminRail(currentPath: location),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  _TopBar(titulo: titulo, showMenu: false),
                  Expanded(child: OfflineBanner(child: child)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      drawer: _AdminDrawer(currentPath: location),
      appBar: AppBar(
        title: Text(titulo),
        actions: const [_SyncIndicator(), SizedBox(width: 8)],
      ),
      body: OfflineBanner(child: child),
    );
  }
}

/// Top bar para layout desktop (sin hamburger).
class _TopBar extends StatelessWidget {
  const _TopBar({required this.titulo, required this.showMenu});
  final String titulo;
  final bool showMenu;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 0,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            Text(titulo, style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            const _SyncIndicator(),
          ],
        ),
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
      loading: () => const SizedBox(
          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      error: (_, __) => Icon(Icons.error_outline, color: scheme.error),
      data: (s) {
        final connected = s?.connected ?? false;
        final activo = (s?.downloading ?? false) || (s?.uploading ?? false);
        final color = !connected ? scheme.error : (activo ? scheme.tertiary : scheme.primary);
        final icon = !connected ? Icons.cloud_off : (activo ? Icons.cloud_sync : Icons.cloud_done);
        return Tooltip(
          message: !connected ? 'Sin conexión' : (activo ? 'Sincronizando' : 'Sincronizado'),
          child: Icon(icon, color: color),
        );
      },
    );
  }
}

/// Items del menú del panel admin. `adminOnly` = sólo rol 'admin'.
const _adminMenu = [
  _MenuItem(Icons.dashboard, 'Resumen', '/admin'),
  _MenuItem(Icons.people, 'Clientes', '/admin/clientes'),
  _MenuItem(Icons.assignment, 'Contratos', '/admin/contratos'),
  _MenuItem(Icons.wifi, 'Planes', '/admin/planes', adminOnly: true),
  _MenuItem(Icons.engineering, 'Cobradores', '/admin/cobradores', adminOnly: true),
  _MenuItem(Icons.receipt_long, 'Cuotas', '/admin/cuotas'),
  _MenuItem(Icons.payments, 'Pagos', '/admin/pagos'),
  _MenuItem(Icons.notification_important, 'Mora', '/admin/notificaciones'),
  _MenuItem(Icons.map, 'Mapa', '/admin/mapa'),
  _MenuItem(Icons.bar_chart, 'Reportes', '/admin/reportes'),
  _MenuItem(Icons.history_edu, 'Auditoría', '/admin/audit', adminOnly: true),
  _MenuItem(Icons.place, 'Geografía', '/admin/geografia', adminOnly: true),
  _MenuItem(Icons.settings, 'Configuración', '/admin/settings', adminOnly: true),
];

class _MenuItem {
  const _MenuItem(this.icon, this.label, this.path, {this.adminOnly = false});
  final IconData icon;
  final String label;
  final String path;
  final bool adminOnly;
}

class _AdminRail extends ConsumerWidget {
  const _AdminRail({required this.currentPath});
  final String currentPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final tieneAccesoAdmin = cobrador?.tieneAccesoAdmin ?? false;
    final items = _adminMenu.where((m) => !m.adminOnly || tieneAccesoAdmin).toList();
    final selectedIndex = items
        .indexWhere((m) => currentPath == m.path || currentPath.startsWith('${m.path}/'));

    return SizedBox(
      width: 240,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            _UserHeader(cobrador: cobrador),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final item = items[i];
                  final selected = i == selectedIndex;
                  return ListTile(
                    leading: Icon(item.icon),
                    title: Text(item.label),
                    selected: selected,
                    selectedTileColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    onTap: () => context.go(item.path),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Cerrar sesión'),
              onTap: () => Supabase.instance.client.auth.signOut(),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _AdminDrawer extends ConsumerWidget {
  const _AdminDrawer({required this.currentPath});
  final String currentPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final tieneAccesoAdmin = cobrador?.tieneAccesoAdmin ?? false;
    final items = _adminMenu.where((m) => !m.adminOnly || tieneAccesoAdmin).toList();

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            _UserHeader(cobrador: cobrador),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: items
                    .map((item) => ListTile(
                          leading: Icon(item.icon),
                          title: Text(item.label),
                          selected: currentPath == item.path,
                          onTap: () {
                            Navigator.of(context).pop();
                            context.go(item.path);
                          },
                        ))
                    .toList(),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Cerrar sesión'),
              onTap: () async {
                Navigator.of(context).pop();
                await Supabase.instance.client.auth.signOut();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _UserHeader extends StatelessWidget {
  const _UserHeader({required this.cobrador});
  final dynamic cobrador;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final nombre = cobrador?.nombre as String? ?? '—';
    final rol = cobrador?.rol as String? ?? '—';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      width: double.infinity,
      color: scheme.primaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: scheme.primary,
                child: Text(
                  _initials(nombre),
                  style: TextStyle(color: scheme.onPrimary),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nombre,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text(_rolDisplay(rol),
                        style: TextStyle(color: scheme.onPrimaryContainer.withValues(alpha: 0.7), fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _initials(String s) {
    final parts = s.trim().split(RegExp(r'\s+'));
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
