import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/router.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/providers/sync_status_provider.dart';
import '../../auth/cambiar_password_dialog.dart';
import '../../shared/utils/shell_nav.dart';
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
    final impersonating =
        ref.watch(impersonatedTenantIdProvider).valueOrNull != null;

    // Gate de carga inicial: mientras `empresaNombreProvider` no haya
    // emitido su primer valor, no rendeamos el child. Sin esto, el
    // redirect del router corre con empresaState=loading
    // (hasValue=false → needsOnboarding=false), no manda al wizard, y
    // un admin nuevo cae en el dashboard con KPIs en cero por una
    // fracción de segundo antes del redirect a /admin/onboarding.
    //
    // IMPORTANTE: usamos el MISMO provider que consume el redirect
    // (router.dart:158). Si watcheáramos un signal distinto (ej
    // settingsMapProvider) podría liberar el gate antes que el router
    // tenga su data — la race se mantendría. El gate scoped al content
    // mantiene visible el sidebar/topbar — menos pérdida de contexto.
    //
    // Skip gate cuando super_admin está impersonando: la data del
    // tenant llega vía el bucket impersonated_tenant y puede tardar
    // un momento. Si gateamos en empresaNombreProvider, el super_admin
    // vería "Cargando…" por cada entrada. Como el super_admin no
    // necesita onboarding del tenant ajeno, lo dejamos pasar directo.
    final empresaAsync = ref.watch(empresaNombreProvider);
    final Widget bodyContent;
    if (impersonating) {
      bodyContent = OfflineBanner(child: child);
    } else {
      bodyContent = empresaAsync.when(
        data: (_) => OfflineBanner(child: child),
        loading: () => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('Cargando…'),
            ],
          ),
        ),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'No se pudo cargar la configuración del ISP: $e',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    // Banner de impersonación: se muestra arriba del contenido cuando
    // el super_admin está dentro de un tenant. Usa empresaNombreProvider
    // para mostrar el nombre del tenant (que ahora viene del bucket
    // impersonated_tenant).
    final Widget bodyWithBanner;
    if (impersonating) {
      bodyWithBanner = Column(
        children: [
          _ImpersonationBanner(empresaAsync: empresaAsync),
          Expanded(child: bodyContent),
        ],
      );
    } else {
      bodyWithBanner = bodyContent;
    }

    if (isDesktop) {
      return Scaffold(
        body: Row(
          children: [
            _AdminRail(currentPath: location),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  _TopBar(
                    titulo: titulo,
                    showMenu: false,
                    parentRoute: _parentRouteFor(location),
                    location: location,
                  ),
                  Expanded(child: bodyWithBanner),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final parentRoute = _parentRouteFor(location);
    return Scaffold(
      drawer: _AdminDrawer(currentPath: location),
      appBar: AppBar(
        // Si la ruta actual es una sub-ruta (ej. /admin/clientes/:id/editar),
        // override el leading para mostrar back arrow en vez del hamburger
        // implícito. Sin esto, en sub-rutas el user no tiene una flecha
        // "atrás" obvia — afford UX de web/mobile standard.
        leading: parentRoute != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Volver',
                onPressed: () => _onBackPressed(context, location, parentRoute),
              )
            : null,
        title: Text(titulo),
        actions: const [_SyncIndicator(), SizedBox(width: 8)],
      ),
      body: bodyWithBanner,
    );
  }
}

/// Handler del back arrow del AppBar. Decide entre:
///   - Sub-rutas que tienen PopScope (forms con `_dirty` guard) →
///     `Navigator.maybePop` para delegar al PopScope; el form decide
///     mostrar "¿Descartar?" o cerrar limpio.
///   - Otras sub-rutas → `closeModalsAndGo` directo (sin guard).
///
/// Sin este split, el back arrow bypassa el PopScope guard del form
/// porque `closeModalsAndGo` usa `context.go(...)` (replace, no pop).
Future<void> _onBackPressed(
  BuildContext context,
  String location,
  String parentRoute,
) async {
  if (_hasFormGuard(location)) {
    // El form tiene PopScope. Si _dirty=false, maybePop simplemente
    // popea al parent. Si _dirty=true, dispara el handler del form
    // que muestra "¿Descartar?" y hace el pop+go correcto.
    await Navigator.maybePop(context);
    return;
  }
  // Ruta sin PopScope guard. Navegación directa.
  if (!context.mounted) return;
  context.closeModalsAndGo(parentRoute);
}

/// Routes con PopScope activo. Mantener sincronizado con los forms
/// que implementan el guard.
bool _hasFormGuard(String loc) {
  return loc.startsWith('/admin/clientes/') ||
      loc.startsWith('/admin/contratos/');
}

/// Si [loc] es una sub-ruta dentro del AdminShell (con sufijo /nuevo,
/// /:id/editar, etc.), retorna la ruta del listado padre para que el
/// back arrow del AppBar navegue allí. Si es una ruta "raíz" del menú
/// (ej. /admin, /admin/clientes), retorna null — auto-leading
/// (hamburger en mobile, sin leading en desktop).
String? _parentRouteFor(String loc) {
  // Maps de "/admin/X/sub-cosa" → "/admin/X". Mantener sincronizado
  // con las routes declaradas en router.dart.
  const subRouteParents = <String, String>{
    '/admin/clientes/': '/admin/clientes',
    '/admin/contratos/': '/admin/contratos',
  };
  for (final entry in subRouteParents.entries) {
    if (loc.startsWith(entry.key)) return entry.value;
  }
  return null;
}

/// Top bar para layout desktop (sin hamburger). En sub-rutas (cuando
/// `parentRoute != null`) muestra un back button al inicio.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.titulo,
    required this.showMenu,
    this.parentRoute,
    this.location = '',
  });
  final String titulo;
  final bool showMenu;
  final String? parentRoute;

  /// Ruta actual (matchedLocation). Necesario para que el back button
  /// elija entre `Navigator.maybePop` (rutas con PopScope) y
  /// `closeModalsAndGo` (sin guard). Default `''` para callers que no
  /// muestran back (parentRoute == null).
  final String location;

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
            if (parentRoute != null) ...[
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Volver',
                onPressed: () =>
                    _onBackPressed(context, location, parentRoute!),
              ),
              const SizedBox(width: 8),
            ],
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

/// Items del menú del panel admin.
///   adminOnly       = sólo admin / super_admin (no admin_cobranza).
///   superAdminOnly  = sólo super_admin (panel SaaS, cross-tenant).
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
  _MenuItem(Icons.shield, 'Tenants', '/super/tenants', superAdminOnly: true),
];

class _MenuItem {
  const _MenuItem(
    this.icon,
    this.label,
    this.path, {
    this.adminOnly = false,
    this.superAdminOnly = false,
  });
  final IconData icon;
  final String label;
  final String path;
  final bool adminOnly;
  final bool superAdminOnly;
}

bool _menuVisible(
  _MenuItem m, {
  required bool esSuperAdmin,
  required bool tieneAccesoAdmin,
}) {
  if (m.superAdminOnly) return esSuperAdmin;
  if (m.adminOnly) return tieneAccesoAdmin;
  return true;
}

class _AdminRail extends ConsumerWidget {
  const _AdminRail({required this.currentPath});
  final String currentPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final tieneAccesoAdmin = cobrador?.tieneAccesoAdmin ?? false;
    final esSuperAdmin = cobrador?.esSuperAdmin ?? false;
    final items = _adminMenu
        .where((m) => _menuVisible(m,
            esSuperAdmin: esSuperAdmin, tieneAccesoAdmin: tieneAccesoAdmin))
        .toList();
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
                    // closeModalsAndGoGuarded: cierra dialogs/sheets
                    // descartables + consulta el formDirtyProvider. Si
                    // el screen actual es un form con cambios sin
                    // guardar, muestra "¿Descartar?" antes de navegar.
                    // Sin el guard, `context.go` bypassaba el PopScope
                    // del form y se perdían los cambios silenciosamente.
                    onTap: () =>
                        context.closeModalsAndGoGuarded(ref, item.path),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Cambiar contraseña'),
              onTap: () => context
                  .closeModalsThenRun(() => mostrarCambiarPasswordDialog(context)),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Cerrar sesión'),
              // closeModalsThenRun cierra dialogs abiertos antes del
              // signOut. Sin esto, un dialog flotaba sobre /login tras
              // el redirect — mismo bug de fondo que el resto del sprint.
              onTap: () => context.closeModalsThenRun(
                  () => Supabase.instance.client.auth.signOut()),
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
    final esSuperAdmin = cobrador?.esSuperAdmin ?? false;
    final items = _adminMenu
        .where((m) => _menuVisible(m,
            esSuperAdmin: esSuperAdmin, tieneAccesoAdmin: tieneAccesoAdmin))
        .toList();

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
                          // closeModalsAndGoGuarded: cierra el drawer
                          // + dialogs descartables + consulta el
                          // formDirtyProvider. Si hay form dirty,
                          // pregunta "¿Descartar?" antes de navegar.
                          // Sin esto, tap en item del drawer perdía
                          // cambios sin warning (context.go bypassa
                          // PopScope).
                          onTap: () => context.closeModalsAndGoGuarded(
                              ref, item.path),
                        ))
                    .toList(),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Cambiar contraseña'),
              // Cerrar el drawer ANTES del dialog para que no quede de
              // fondo: en mobile el drawer ocupa ancho completo y el
              // dialog quedaría detrás. closeModalsThenRun invoca
              // Scaffold.closeDrawer (el drawer es LocalHistoryEntry,
              // no Route) y popea modales sueltos antes del dialog.
              onTap: () => context
                  .closeModalsThenRun(() => mostrarCambiarPasswordDialog(context)),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Cerrar sesión'),
              // closeModalsThenRun cierra el drawer + dialogs abiertos
              // antes del signOut. Sin esto, un dialog podía flotar
              // sobre /login tras el redirect del router.
              onTap: () => context.closeModalsThenRun(
                  () => Supabase.instance.client.auth.signOut()),
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

/// Banner que se muestra en la parte superior del panel admin cuando el
/// super_admin está impersonando un tenant. Muestra el nombre del tenant
/// (vía empresaNombreProvider, que ahora apunta al tenant impersonado) y
/// un botón "Salir" para terminar la impersonación.
class _ImpersonationBanner extends StatefulWidget {
  const _ImpersonationBanner({required this.empresaAsync});
  final AsyncValue<String?> empresaAsync;

  @override
  State<_ImpersonationBanner> createState() => _ImpersonationBannerState();
}

class _ImpersonationBannerState extends State<_ImpersonationBanner> {
  bool _saliendo = false;

  Future<void> _salir() async {
    setState(() => _saliendo = true);
    try {
      await stopImpersonation();
      if (!mounted) return;
      context.go('/super/tenants');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al salir: $e')),
      );
      setState(() => _saliendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // El nombre del tenant viene de empresaNombreProvider — cuando el
    // super_admin impersona, el bucket impersonated_tenant sincroniza
    // los settings del tenant y empresaNombreProvider emite el nombre.
    // Mientras la data llega (loading), mostramos "Cargando…".
    final nombre = widget.empresaAsync.when(
      data: (n) => n ?? 'Tenant sin nombre',
      loading: () => 'Cargando…',
      error: (_, __) => 'Tenant',
    );
    return Material(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.shield, size: 18, color: scheme.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Super Admin · Viendo: $nombre',
                style: TextStyle(
                  color: scheme.onTertiaryContainer,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            _saliendo
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton.icon(
                    icon: const Icon(Icons.exit_to_app, size: 18),
                    label: const Text('Salir'),
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.onTertiaryContainer,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: _salir,
                  ),
          ],
        ),
      ),
    );
  }
}
