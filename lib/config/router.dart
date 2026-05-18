import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/admin/audit/audit_admin_screen.dart';
import '../features/admin/clientes/cliente_form_screen.dart';
import '../features/admin/clientes/clientes_admin_screen.dart';
import '../features/admin/cobradores/cobradores_admin_screen.dart';
import '../features/admin/contratos/contratos_admin_screen.dart';
import '../features/admin/cuotas/cuotas_admin_screen.dart';
import '../features/admin/dashboard/dashboard_admin_screen.dart';
import '../features/admin/geografia/geografia_admin_screen.dart';
import '../features/admin/notificaciones/notificaciones_mora_screen.dart';
import '../features/admin/onboarding/onboarding_screen.dart';
import '../features/admin/pagos/pagos_admin_screen.dart';
import '../features/admin/planes/planes_admin_screen.dart';
import '../features/admin/reportes/reportes_admin_screen.dart';
import '../features/admin/settings/settings_admin_screen.dart';
import '../features/admin/shell/admin_shell.dart';
import '../features/auth/login_screen.dart';
import '../features/super_admin/super_shell.dart';
import '../features/super_admin/tenant_modulos_screen.dart';
import '../features/super_admin/tenants_list_screen.dart';
import '../features/clientes/cliente_detail_screen.dart';
import '../features/clientes/clientes_list_screen.dart';
import '../features/cobro/cobro_screen.dart';
import '../features/cuotas/cuotas_list_screen.dart';
import '../features/historial/historial_screen.dart';
import '../features/home/home_screen.dart';
import '../features/impresora/impresora_setup_screen.dart';
import '../features/mapa/mapa_screen.dart';
import '../features/recibo/recibo_screen.dart';
import '../features/settings/perfil_screen.dart';
import '../features/shell/app_shell.dart';
import '../powersync/db.dart' as ps;

/// Stream del rol del usuario actual desde la tabla cobradores local.
/// Una sola suscripción global que el router lee en cada redirect.
/// Si aún no hay valor sincronizado, asumimos cobrador (conservador).
final _rolUsuarioProvider = StreamProvider<String?>((ref) async* {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) {
    yield null;
    return;
  }
  yield* ps.db
      .watch('SELECT rol FROM cobradores WHERE id = ?', parameters: [user.id])
      .map((rows) => rows.isEmpty ? null : rows.first['rol'] as String?);
});

/// Stream de `empresa.nombre` para detectar si falta onboarding del tenant.
/// Si está vacío, redirigimos al wizard.
final _empresaNombreProvider = StreamProvider<String?>((ref) async* {
  yield* ps.db
      .watch("SELECT valor FROM settings WHERE clave = 'empresa.nombre'")
      .map((rows) {
    if (rows.isEmpty) return null;
    final v = rows.first['valor'] as String?;
    if (v == null) return null;
    // Settings.valor es JSON serializado: "X" o null.
    final s = v.trim();
    if (s == 'null' || s == '""' || s.isEmpty) return null;
    return s;
  });
});

final routerProvider = Provider<GoRouter>((ref) {
  final auth = Supabase.instance.client.auth;
  final refresh = _AuthRefresh(auth);
  ref.onDispose(refresh.dispose);

  // El routerProvider se evalúa en el arranque, *antes* de que Supabase
  // restaure la sesión persistida. En ese momento auth.currentUser es null,
  // así que _rolUsuarioProvider hace `yield null; return;` y queda muerto
  // en AsyncData(null) — el redirect siempre vería rol=null y bloquearía
  // /super/*. Invalidamos los providers en cada cambio de auth para que
  // Riverpod los recree con el user.id correcto.
  final authSub = auth.onAuthStateChange.listen((_) {
    ref.invalidate(_rolUsuarioProvider);
    ref.invalidate(_empresaNombreProvider);
  });
  ref.onDispose(authSub.cancel);

  // Mantiene viva la suscripción al rol y dispara refresh del router cuando
  // cambia (típicamente al primer sync). Sin esto, redirect llamaría
  // valueOrNull antes de que el stream tenga data y nadie se enteraría.
  ref.listen(_rolUsuarioProvider, (_, __) => refresh.poke());
  // Idem para detectar setup completo del tenant.
  ref.listen(_empresaNombreProvider, (_, __) => refresh.poke());

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final loggedIn = auth.currentSession != null;
      final goingToLogin = state.matchedLocation == '/login';
      if (!loggedIn) return goingToLogin ? null : '/login';
      if (goingToLogin) return '/';

      final rol = ref.read(_rolUsuarioProvider).valueOrNull;
      final loc = state.matchedLocation;

      // Si el rol es admin / admin_cobranza / super_admin, redirigir desde
      // la raíz del cobrador hacia el panel admin. Sólo en la raíz exacta —
      // los usuarios admin pueden querer ver pantallas del cobrador navegando.
      if (loc == '/' &&
          (rol == 'admin' ||
              rol == 'admin_cobranza' ||
              rol == 'super_admin')) {
        return '/admin';
      }

      // Onboarding: si rol=admin y `empresa.nombre` está vacío, llevar al
      // wizard. NO aplica a super_admin (vive en el tenant System, no
      // necesita onboarding del producto).
      if (rol == 'admin') {
        final empresaState = ref.read(_empresaNombreProvider);
        final needsOnboarding =
            empresaState.hasValue && empresaState.value == null;
        if (needsOnboarding && loc != '/admin/onboarding') {
          return '/admin/onboarding';
        }
        if (!needsOnboarding && loc == '/admin/onboarding') {
          return '/admin';
        }
      }

      // Guard por rol en rutas admin-only: admin_cobranza no accede a
      // Cobradores / Auditoría / Geografía / Settings (alineado con el
      // menú del shell).
      const soloAdmin = [
        '/admin/cobradores',
        '/admin/audit',
        '/admin/geografia',
        '/admin/settings',
        '/admin/planes',
      ];
      if (rol == 'admin_cobranza' &&
          soloAdmin.any((p) => loc == p || loc.startsWith('$p/'))) {
        return '/admin';
      }

      // Panel /super/* sólo para super_admin. Cualquier otro rol que
      // intente entrar (por URL directa) se va al panel admin del tenant.
      if (loc.startsWith('/super') && rol != 'super_admin') {
        return '/admin';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/admin/onboarding',
        builder: (_, __) => const OnboardingScreen(),
      ),

      // ── Cobrador: ShellRoute con drawer ────────────────────────────────
      ShellRoute(
        builder: (_, __, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/',          builder: (_, s) => _titled('Inicio', const HomeScreen())),
          GoRoute(path: '/clientes',  builder: (_, s) => _titled('Clientes', const ClientesListScreen())),
          GoRoute(path: '/cuotas',    builder: (_, s) => _titled('Cuotas pendientes', const CuotasListScreen())),
          GoRoute(path: '/mapa',      builder: (_, s) => _titled('Mapa', const MapaScreen())),
          GoRoute(path: '/historial', builder: (_, s) => _titled('Historial', const HistorialScreen())),
          GoRoute(path: '/perfil',    builder: (_, s) => _titled('Mi perfil', const PerfilScreen())),
        ],
      ),

      // ── Admin: ShellRoute con sidebar responsive ───────────────────────
      ShellRoute(
        builder: (_, __, child) => AdminShell(child: child),
        routes: [
          GoRoute(path: '/admin',
              builder: (_, s) => _titled('Resumen', const DashboardAdminScreen())),
          GoRoute(path: '/admin/clientes',
              builder: (_, s) => _titled('Clientes', const ClientesAdminScreen())),
          GoRoute(path: '/admin/clientes/nuevo',
              builder: (_, s) => _titled('Nuevo cliente', const ClienteFormScreen())),
          GoRoute(path: '/admin/clientes/:id/editar',
              builder: (_, s) => _titled('Editar cliente',
                  ClienteFormScreen(clienteId: s.pathParameters['id']))),
          GoRoute(path: '/admin/contratos',
              builder: (_, s) => _titled('Contratos', const ContratosAdminScreen())),
          GoRoute(path: '/admin/contratos/nuevo',
              builder: (_, s) => _titled('Nuevo contrato',
                  ContratoFormScreen(clienteId: s.uri.queryParameters['cliente_id']))),
          GoRoute(path: '/admin/contratos/:id/editar',
              builder: (_, s) => _titled('Editar contrato',
                  ContratoFormScreen(contratoId: s.pathParameters['id']))),
          GoRoute(path: '/admin/planes',
              builder: (_, s) => _titled('Planes', const PlanesAdminScreen())),
          GoRoute(path: '/admin/notificaciones',
              builder: (_, s) => _titled('Notificaciones de mora',
                  const NotificacionesMoraScreen())),
          GoRoute(path: '/admin/cobradores',
              builder: (_, s) => _titled('Cobradores', const CobradoresAdminScreen())),
          GoRoute(path: '/admin/cuotas',
              builder: (_, s) => _titled('Cuotas', const CuotasAdminScreen())),
          GoRoute(path: '/admin/pagos',
              builder: (_, s) => _titled('Pagos', const PagosAdminScreen())),
          GoRoute(path: '/admin/mapa',
              builder: (_, s) => _titled('Mapa', const MapaScreen())),
          GoRoute(path: '/admin/reportes',
              builder: (_, s) => _titled('Reportes', const ReportesAdminScreen())),
          GoRoute(path: '/admin/audit',
              builder: (_, s) => _titled('Auditoría', const AuditAdminScreen())),
          GoRoute(path: '/admin/geografia',
              builder: (_, s) => _titled('Geografía', const GeografiaAdminScreen())),
          GoRoute(path: '/admin/settings',
              builder: (_, s) => _titled('Configuración', const SettingsAdminScreen())),
        ],
      ),

      // ── Super Admin: ShellRoute propio (sólo super_admin lo alcanza) ───
      ShellRoute(
        builder: (_, state, child) {
          final loc = state.matchedLocation;
          final titulo = loc.startsWith('/super/tenants/') &&
                  loc.length > '/super/tenants/'.length
              ? 'Configurar tenant'
              : 'Tenants';
          return SuperShell(titulo: titulo, child: child);
        },
        routes: [
          GoRoute(
            path: '/super/tenants',
            builder: (_, s) => const TenantsListScreen(),
          ),
          GoRoute(
            path: '/super/tenants/:id',
            builder: (_, s) =>
                TenantModulosScreen(tenantId: s.pathParameters['id']!),
          ),
        ],
      ),

      // ── Rutas push del cobrador (con back propio) ──────────────────────
      GoRoute(
        path: '/clientes/:id',
        builder: (_, s) => ClienteDetailScreen(clienteId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/cobro/:cuotaId',
        builder: (_, s) => CobroScreen(cuotaId: s.pathParameters['cuotaId']!),
      ),
      GoRoute(
        path: '/recibo/:reciboId',
        builder: (_, s) => ReciboScreen(reciboId: s.pathParameters['reciboId']!),
      ),
      GoRoute(
        path: '/perfil/impresora',
        builder: (_, __) => const ImpresoraSetupScreen(),
      ),
    ],
  );
});

Widget _titled(String titulo, Widget child) =>
    ShellTitleScope(titulo: titulo, child: child);

class ShellTitleScope extends InheritedWidget {
  const ShellTitleScope({super.key, required this.titulo, required super.child});
  final String titulo;

  @override
  bool updateShouldNotify(ShellTitleScope oldWidget) => oldWidget.titulo != titulo;

  static String? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellTitleScope>()?.titulo;
}

class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(GoTrueClient auth) {
    _sub = auth.onAuthStateChange.listen((_) => notifyListeners());
  }
  late final StreamSubscription<AuthState> _sub;

  /// Disparable externamente (ej. cuando llega el rol del usuario).
  void poke() => notifyListeners();

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
