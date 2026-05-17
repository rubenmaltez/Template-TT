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
import '../features/admin/pagos/pagos_admin_screen.dart';
import '../features/admin/reportes/reportes_admin_screen.dart';
import '../features/admin/settings/settings_admin_screen.dart';
import '../features/admin/shell/admin_shell.dart';
import '../features/auth/login_screen.dart';
import '../features/clientes/cliente_detail_screen.dart';
import '../features/clientes/clientes_list_screen.dart';
import '../features/cobro/cobro_screen.dart';
import '../features/cuotas/cuotas_list_screen.dart';
import '../features/historial/historial_screen.dart';
import '../features/home/home_screen.dart';
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

final routerProvider = Provider<GoRouter>((ref) {
  final auth = Supabase.instance.client.auth;
  final refresh = _AuthRefresh(auth);
  ref.onDispose(refresh.dispose);

  // Mantiene viva la suscripción al rol y dispara refresh del router cuando
  // cambia (típicamente al primer sync). Sin esto, redirect llamaría
  // valueOrNull antes de que el stream tenga data y nadie se enteraría.
  ref.listen(_rolUsuarioProvider, (_, __) => refresh.poke());

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final loggedIn = auth.currentSession != null;
      final goingToLogin = state.matchedLocation == '/login';
      if (!loggedIn) return goingToLogin ? null : '/login';
      if (goingToLogin) return '/';

      // Si el rol es admin o admin_cobranza, redirigir desde la raíz
      // del cobrador hacia el panel admin. Sólo en la raíz exacta — el
      // usuario admin podría querer ver pantallas del cobrador navegando.
      if (state.matchedLocation == '/') {
        final rol = ref.read(_rolUsuarioProvider).valueOrNull;
        if (rol == 'admin' || rol == 'admin_cobranza') return '/admin';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),

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
