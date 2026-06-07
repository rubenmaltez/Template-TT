import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config/router.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/crud_error_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/providers/modulos_provider.dart';
import '../../../data/providers/sync_status_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../shared/widgets/app_version_label.dart';
import '../../shared/widgets/impersonation_banner.dart';
import '../../shared/widgets/update_banner.dart';
import '../../auth/cambiar_password_dialog.dart';
import '../../shared/utils/shell_nav.dart';
import '../../shared/utils/sign_out_helper.dart';
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
    // Escuchar errores de CRUD upload para mostrar SnackBar cuando un
    // write local es rechazado por Postgres (trigger, constraint, RLS).
    ref.listen(crudUploadErrorProvider, (_, next) {
      final error = next.valueOrNull;
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.table == 'clientes' &&
                      error.message.toString().toLowerCase().contains('codigo')
                  ? 'Código de cliente duplicado: otro cliente ya usa ese '
                      'código. Editá el cliente y asignale uno distinto.'
                  : 'Error al sincronizar ${error.table}: ${error.message}'),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    });

    final isDesktop = MediaQuery.sizeOf(context).width >= _breakpoint;
    final titulo = ShellTitleScope.of(context) ?? 'Panel admin';
    final location = GoRouterState.of(context).matchedLocation;
    final impersonating =
        ref.watch(impersonatedTenantIdProvider).valueOrNull != null;

    // El admin entra directo al dashboard. Ya NO hay wizard de onboarding
    // (se quitó en v0.6.4): el admin configura empresa en Ajustes → Empresa
    // y genera sus planes en Administración → Planes por su cuenta. Por eso
    // tampoco gateamos la carga en `empresaNombreProvider` — sin redirect al
    // wizard, no hay flash que enmascarar.
    final Widget bodyContent = OfflineBanner(child: child);

    // Banners: update disponible (azul) + impersonación (amber).
    // Se apilan arriba del contenido. El update banner se auto-oculta
    // si no hay update o si el user lo cierra.
    final Widget bodyWithBanners;
    if (impersonating) {
      bodyWithBanners = Column(
        children: [
          const UpdateBanner(),
          const ImpersonationBanner(),
          Expanded(child: bodyContent),
        ],
      );
    } else {
      bodyWithBanners = Column(
        children: [
          const UpdateBanner(),
          Expanded(child: bodyContent),
        ],
      );
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
                  Expanded(child: bodyWithBanners),
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
        title: Text(titulo, overflow: TextOverflow.ellipsis),
        actions: const [_SyncIndicator(), SizedBox(width: 8)],
      ),
      body: bodyWithBanners,
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

/// Items del menú del panel admin. BULK 12: sidebar simplificado.
/// Contratos/Cuotas/Pagos viven dentro del detalle del cliente.
/// Personal/Planes/Geografía/Auditoría se agrupan bajo "Administración".
const _adminMenu = [
  _MenuItem(Icons.dashboard, 'Resumen', '/admin'),
  _MenuItem(Icons.people, 'Clientes', '/admin/clientes'),
  // Operativo: admin y admin_cobranza ven la vista de Cobros (misma pantalla
  // del cobrador, con filtros por cobrador/zona). NO adminOnly a propósito.
  _MenuItem(Icons.point_of_sale, 'Cobros', '/admin/cobros'),
  _MenuItem(Icons.admin_panel_settings, 'Administración', '/admin/cobradores',
      adminOnly: true, children: [
    _MenuItem(Icons.groups, 'Personal', '/admin/cobradores', adminOnly: true),
    _MenuItem(Icons.wifi, 'Planes', '/admin/planes', adminOnly: true),
    _MenuItem(Icons.location_city, 'Geografía', '/admin/geografia',
        adminOnly: true),
    _MenuItem(Icons.hub, 'Red', '/admin/red', adminOnly: true),
    // Auditoría: oculta para el admin por defecto. El super_admin la ve
    // siempre; el admin sólo si el super habilita el toggle por tenant
    // (cobranza.audit_visible_admin, migración 0089).
    _MenuItem(Icons.history_edu, 'Auditoría', '/admin/audit',
        adminOnly: true, settingKey: 'cobranza.audit_visible_admin'),
  ]),
  // Pantallas opcionales: las habilita el super_admin por tenant (toggle
  // super_admin-only en settings). Sin habilitar, el item no aparece.
  _MenuItem(Icons.payments, 'Pagos', '/admin/pagos',
      adminOnly: true, settingKey: 'cobranza.pantalla_pagos'),
  _MenuItem(Icons.notifications_active, 'Notificaciones', '/admin/notificaciones',
      adminOnly: true, settingKey: 'cobranza.pantalla_notificaciones'),
  // Módulo opcional Inventario: aparece solo si el super_admin lo habilitó
  // para el tenant (tenant_modulos 'inventario'). adminOnly.
  _MenuItem(Icons.inventory_2, 'Inventario', '/admin/inventario',
      adminOnly: true, moduloKey: 'inventario'),
  // Módulo opcional Tickets (Fase 3).
  _MenuItem(Icons.confirmation_number, 'Tickets', '/admin/tickets',
      adminOnly: true, moduloKey: 'tickets'),
  _MenuItem(Icons.bar_chart, 'Reportes', '/admin/reportes'),
  _MenuItem(Icons.map, 'Mapa', '/admin/mapa'),
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
    this.settingKey,
    this.moduloKey,
    this.children = const [],
  });
  final IconData icon;
  final String label;
  final String path;
  final bool adminOnly;
  final bool superAdminOnly;
  // Si está seteado, el item solo se muestra cuando ese setting booleano está
  // en ON (pantallas opcionales que habilita el super_admin por tenant).
  final String? settingKey;
  // Si está seteado, el item solo se muestra cuando el tenant tiene ese módulo
  // habilitado (tenant_modulos). Ej: 'inventario'. A diferencia de settingKey,
  // NO lo bypassa el super_admin: si el (sub)tenant no tiene el módulo, no se ve
  // (el super_admin lo habilita en /super/tenants/:id y entonces aparece).
  final String? moduloKey;
  final List<_MenuItem> children;
}

bool _menuVisible(
  _MenuItem m, {
  required bool esSuperAdmin,
  required bool tieneAccesoAdmin,
  bool impersonating = false,
  Set<String> pantallasOn = const {},
  Set<String> modulosOn = const {},
}) {
  // Pantallas/opciones gateadas por un setting per-tenant (las habilita el
  // super_admin). El super_admin las ve SIEMPRE (acceso total al panel del
  // tenant); el admin sólo si el setting está en ON. Si el item tiene
  // settingKey, no es super_admin y el setting no está en ON, no se muestra.
  if (m.settingKey != null &&
      !esSuperAdmin &&
      !pantallasOn.contains(m.settingKey)) {
    return false;
  }
  // Módulo opcional (tenant_modulos). Se gatea por el tenant ACTUAL (o el
  // impersonado): si no lo tiene habilitado, no se muestra ni al super_admin
  // (refleja el módulo real del tenant; el super lo habilita en /super).
  if (m.moduloKey != null && !modulosOn.contains(m.moduloKey)) {
    return false;
  }
  // Cuando el super_admin está impersonando, ocultar el item de
  // /super/* — el router lo bloquearía de todas formas, pero es
  // mejor no mostrar una opción que no funciona.
  if (m.superAdminOnly) return esSuperAdmin && !impersonating;
  if (m.adminOnly) return tieneAccesoAdmin;
  return true;
}

/// Item de menú agrupador (con sub-ítems). Render como ExpansionTile,
/// usado tanto por el rail (desktop) como por el drawer (mobile). Arranca
/// expandido si la ruta actual cae dentro de alguno de sus hijos, para que
/// el usuario vea dónde está parado al entrar por deep-link.
class _ExpandableMenuItem extends ConsumerWidget {
  const _ExpandableMenuItem({required this.item, required this.currentPath});
  final _MenuItem item;
  final String currentPath;

  bool _matches(_MenuItem m) =>
      currentPath == m.path || currentPath.startsWith('${m.path}/');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // Los sub-ítems también respetan _menuVisible. Antes se renderizaban
    // todos los children sin filtro (el gate del padre adminOnly alcanzaba),
    // pero ahora "Auditoría" tiene settingKey: el admin sólo la ve si el
    // super_admin habilitó el toggle por tenant; el super_admin la ve siempre.
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final esSuperAdmin = cobrador?.esSuperAdmin ?? false;
    final tieneAccesoAdmin = cobrador?.tieneAccesoAdmin ?? false;
    final impersonating =
        ref.watch(impersonatedTenantIdProvider).valueOrNull != null;
    final settings = ref.watch(appSettingsProvider);
    final pantallasOn = _pantallasOn(settings);
    final modulosOn = ref.watch(modulosHabilitadosProvider).valueOrNull ?? {};
    final visibleChildren = item.children
        .where((child) => _menuVisible(child,
            esSuperAdmin: esSuperAdmin,
            tieneAccesoAdmin: tieneAccesoAdmin,
            impersonating: impersonating,
            pantallasOn: pantallasOn,
            modulosOn: modulosOn))
        .toList();
    // Si no quedó ningún hijo visible, no mostramos el grupo vacío.
    if (visibleChildren.isEmpty) return const SizedBox.shrink();
    final algunHijoActivo = visibleChildren.any(_matches);
    return ExpansionTile(
      leading: Icon(item.icon),
      title: Text(item.label),
      initiallyExpanded: algunHijoActivo,
      shape: const Border(),
      collapsedShape: const Border(),
      childrenPadding: const EdgeInsets.only(left: 16),
      children: visibleChildren.map((child) {
        final selected = _matches(child);
        return ListTile(
          leading: Icon(child.icon, size: 20),
          title: Text(child.label),
          selected: selected,
          selectedTileColor: scheme.primaryContainer,
          // Mismo guard que los items planos: cierra modales + chequea
          // formDirtyProvider antes de navegar (context.go bypassa PopScope).
          onTap: () => context.closeModalsAndGoGuarded(ref, child.path),
        );
      }).toList(),
    );
  }
}

/// Conjunto de settingKeys habilitados por el super_admin para este tenant.
/// Centralizado para que el rail, el drawer y los grupos usen la misma lógica.
Set<String> _pantallasOn(AppSettings settings) => <String>{
      if (settings.pantallaPagosHabilitada) 'cobranza.pantalla_pagos',
      if (settings.pantallaNotificacionesHabilitada)
        'cobranza.pantalla_notificaciones',
      if (settings.auditVisibleAdmin) 'cobranza.audit_visible_admin',
    };

class _AdminRail extends ConsumerWidget {
  const _AdminRail({required this.currentPath});
  final String currentPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final tieneAccesoAdmin = cobrador?.tieneAccesoAdmin ?? false;
    final esSuperAdmin = cobrador?.esSuperAdmin ?? false;
    final impersonating =
        ref.watch(impersonatedTenantIdProvider).valueOrNull != null;
    final settings = ref.watch(appSettingsProvider);
    final pantallasOn = _pantallasOn(settings);
    final modulosOn = ref.watch(modulosHabilitadosProvider).valueOrNull ?? {};
    final items = _adminMenu
        .where((m) => _menuVisible(m,
            esSuperAdmin: esSuperAdmin,
            tieneAccesoAdmin: tieneAccesoAdmin,
            impersonating: impersonating,
            pantallasOn: pantallasOn,
            modulosOn: modulosOn))
        .toList();
    // Los grupos (con children) no se "seleccionan" como tile plano — su
    // estado activo lo maneja el _ExpandableMenuItem mirando sus hijos.
    final selectedIndex = items.indexWhere((m) =>
        m.children.isEmpty &&
        (currentPath == m.path || currentPath.startsWith('${m.path}/')));

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
                  if (item.children.isNotEmpty) {
                    return _ExpandableMenuItem(
                        item: item, currentPath: currentPath);
                  }
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
              onTap: () => confirmarSignOut(context),
            ),
            const AppVersionLabel(),
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
    final impersonating =
        ref.watch(impersonatedTenantIdProvider).valueOrNull != null;
    final settings = ref.watch(appSettingsProvider);
    final pantallasOn = _pantallasOn(settings);
    final modulosOn = ref.watch(modulosHabilitadosProvider).valueOrNull ?? {};
    final items = _adminMenu
        .where((m) => _menuVisible(m,
            esSuperAdmin: esSuperAdmin,
            tieneAccesoAdmin: tieneAccesoAdmin,
            impersonating: impersonating,
            pantallasOn: pantallasOn,
            modulosOn: modulosOn))
        .toList();

    return Drawer(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SafeArea(
        child: Column(
          children: [
            _UserHeader(cobrador: cobrador),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: items.map((item) {
                  if (item.children.isNotEmpty) {
                    return _ExpandableMenuItem(
                        item: item, currentPath: currentPath);
                  }
                  return ListTile(
                    leading: Icon(item.icon),
                    title: Text(item.label),
                    selected: currentPath == item.path,
                    selectedTileColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    // closeModalsAndGoGuarded: cierra el drawer + dialogs
                    // descartables + consulta el formDirtyProvider. Si hay
                    // form dirty, pregunta "¿Descartar?" antes de navegar.
                    // Sin esto, tap en item del drawer perdía cambios sin
                    // warning (context.go bypassa PopScope).
                    onTap: () =>
                        context.closeModalsAndGoGuarded(ref, item.path),
                  );
                }).toList(),
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
              onTap: () => confirmarSignOut(context),
            ),
            const AppVersionLabel(),
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

