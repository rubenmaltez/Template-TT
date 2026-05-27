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
import '../data/providers/cobrador_provider.dart';
import '../data/providers/impersonation_provider.dart';
import '../data/providers/sync_ready_provider.dart';
import '../data/providers/sync_status_provider.dart';
import '../data/providers/mora_count_provider.dart';
import '../features/auth/auth_flow_provider.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/set_password_screen.dart';
import '../features/shared/widgets/sync_gate_screen.dart';
import '../features/super_admin/error_logs_screen.dart';
import '../features/super_admin/miembro_detalle_screen.dart';
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

/// True si la row específica de `empresa.nombre` existe en el SQLite
/// local. Sirve para distinguir "row aún no sincronizada" (sync en
/// curso) vs "row sincronizada con valor vacío" (necesita onboarding).
///
/// **Por qué la row específica y no `COUNT(*) > 0`**: PowerSync puede
/// materializar OTRAS rows de `settings` antes que `empresa.nombre`
/// específicamente (ej. `cobranza.dias_gracia`). Un check de
/// "al menos una row" flipparía a true antes de que llegue el valor
/// real de `empresa.nombre` → `empresaNombreProvider` seguiría emitiendo
/// `null` (rows.isEmpty=true para esa key) y el guard del router
/// redirigiría a `/admin/onboarding` por ~50ms. Flash más cortito pero
/// no eliminado. Gateando sobre la row específica el bug desaparece
/// completamente.
///
/// **Por qué existe el bug originalmente**: durante el sync inicial
/// post-cambio de identidad (típico tras `forzar-password-cobrador` que
/// invalida la sesión vieja con signOut global), la tabla `settings`
/// local arranca vacía. `empresaNombreProvider` emite `null`, el guard
/// lo interpreta como "necesita onboarding" y redirige al wizard por
/// ~1s antes de que llegue la row del seed (migración 0010).
final empresaNombreRowExistsProvider = StreamProvider<bool>((ref) async* {
  yield* ps.db
      .watch(
          "SELECT 1 FROM settings WHERE clave = 'empresa.nombre' LIMIT 1")
      .map((rows) => rows.isNotEmpty);
});

/// Stream de `empresa.nombre` para detectar si falta onboarding del tenant.
/// Si está vacío, redirigimos al wizard.
///
/// Público porque el AdminShell también lo consume — el gate de carga
/// inicial tiene que usar EXACTAMENTE el mismo signal que esta lógica
/// de redirect, sino la pantalla rendea con el redirect todavía
/// pendiente y se ve un flash del dashboard antes del onboarding.
final empresaNombreProvider = StreamProvider<String?>((ref) async* {
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
  //
  // También invalidamos cobradorActualProvider: sin esto, cuando user A
  // hace logout y user B login en el mismo browser, el AdminShell sigue
  // mostrando los datos de A (nombre, rol, menú filtrado) hasta que algo
  // dispare una recarga manual.
  final authSub = auth.onAuthStateChange.listen((_) {
    ref.invalidate(_rolUsuarioProvider);
    ref.invalidate(empresaNombreProvider);
    ref.invalidate(empresaNombreRowExistsProvider);
    ref.invalidate(cobradorActualProvider);
    ref.invalidate(impersonatedTenantIdProvider);
    ref.invalidate(syncStatusProvider);
    ref.invalidate(moraCountProvider);
  });
  ref.onDispose(authSub.cancel);

  // Mantiene viva la suscripción al rol y dispara refresh del router cuando
  // cambia (típicamente al primer sync). Sin esto, redirect llamaría
  // valueOrNull antes de que el stream tenga data y nadie se enteraría.
  ref.listen(_rolUsuarioProvider, (_, __) => refresh.poke());
  // Idem para detectar setup completo del tenant.
  ref.listen(empresaNombreProvider, (_, __) => refresh.poke());
  // empresaNombreRowExistsProvider participa del guard `needsOnboarding`
  // — cuando flippa de false a true (la row de empresa.nombre llegó
  // del sync), tenemos que reevaluar el redirect.
  ref.listen(empresaNombreRowExistsProvider, (_, __) => refresh.poke());
  // Y para que SetPasswordScreen pueda limpiar el flow y desencadenar
  // una re-evaluación del redirect (sino quedaría atrapado en
  // /set-password después de actualizar la contraseña).
  ref.listen(initialAuthFlowProvider, (_, __) => refresh.poke());
  // Sync gate (R7): cuando PowerSync confirma sync post-cambio de
  // identidad, syncReady flippa a true y queremos que el redirect
  // saque al user de /sync-gate hacia su pantalla por rol.
  ref.listen(syncReadyProvider, (_, __) => refresh.poke());
  // Impersonación: cuando el super_admin entra o sale de un tenant,
  // re-evaluamos el redirect para moverlo entre /super/* y /admin/*.
  ref.listen(impersonatedTenantIdProvider, (_, __) => refresh.poke());

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final loggedIn = auth.currentSession != null;
      final goingToLogin = state.matchedLocation == '/login';
      if (!loggedIn) return goingToLogin ? null : '/login';
      if (goingToLogin) return '/';

      // Si la app arrancó desde un link de recovery / invite, el user
      // ya está logueado (Supabase auto-procesó el token) pero todavía
      // no setó su contraseña. Lo desviamos a /set-password antes de
      // dejarlo entrar al resto de la app. Funciona también para
      // invite (primera vez tras aceptar).
      final authFlow = ref.read(initialAuthFlowProvider);
      final yaEstaEnSetPassword =
          state.matchedLocation == '/set-password';
      if ((authFlow == 'recovery' || authFlow == 'invite') &&
          !yaEstaEnSetPassword) {
        return '/set-password';
      }
      // Si el flow ya no aplica (user terminó de setear o no había
      // flow) pero está en /set-password, lo sacamos.
      if (yaEstaEnSetPassword && authFlow != 'recovery' &&
          authFlow != 'invite') {
        return '/';
      }

      // Sync gate (R7): si la identidad cambió (signOut + signIn, o
      // user switch) y PowerSync todavía no confirmó un sync posterior
      // al cambio, esperamos en /sync-gate. Va DESPUÉS del set-password
      // gate porque ese flow no toca la identidad de PowerSync — el
      // user que setea contraseña ya es el dueño del cache.
      final syncReady = ref.read(syncReadyProvider);
      final goingToGate = state.matchedLocation == '/sync-gate';
      if (!syncReady) return goingToGate ? null : '/sync-gate';
      if (goingToGate) return '/';

      final rol = ref.read(_rolUsuarioProvider).valueOrNull;
      final loc = state.matchedLocation;
      final impersonating =
          ref.read(impersonatedTenantIdProvider).valueOrNull != null;

      // Landing por rol desde la raíz `/`. Sólo en la raíz exacta —
      // los usuarios admin/super pueden querer ver pantallas del cobrador
      // navegando, así que sub-rutas como `/clientes/:id` no se tocan.
      //
      // super_admin impersonando → `/admin` (opera como admin del tenant).
      // super_admin normal → `/super/tenants` (panel SaaS).
      // admin / admin_cobranza → `/admin` (panel del tenant).
      if (loc == '/') {
        if (rol == 'super_admin') {
          return impersonating ? '/admin' : '/super/tenants';
        }
        if (rol == 'admin' || rol == 'admin_cobranza') return '/admin';
      }

      // Onboarding: si rol=admin y `empresa.nombre` está vacío, llevar al
      // wizard. NO aplica a super_admin normal (vive en el tenant System,
      // no necesita onboarding del producto) NI a super_admin impersonando
      // (el tenant ya fue configurado por su admin — el super_admin no
      // debería ver el wizard).
      //
      // empresaNombreRowExistsProvider gate: si la row específica de
      // `empresa.nombre` aún no llegó del sync, `empresaState.value`
      // será null por defecto (rows.isEmpty=true para esa key). Sin
      // este guard, el redirect caería en /admin/onboarding tentativo
      // hasta que llegue la row real. Esperamos a confirmar que la
      // row existe localmente — recién ahí confiamos en que
      // `empresa.nombre = null` (mapeado a null) es "vacío" real, no
      // un artefacto del sync inicial.
      if (rol == 'admin') {
        final empresaState = ref.read(empresaNombreProvider);
        final empresaRowExiste =
            ref.read(empresaNombreRowExistsProvider).valueOrNull ?? false;
        final needsOnboarding = empresaRowExiste &&
            empresaState.hasValue &&
            empresaState.value == null;
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

      // super_admin impersonando que intenta acceder a /super/*:
      // primero debe salir de la impersonación. Lo redirigimos a /admin
      // donde verá el banner de impersonación con "Salir".
      if (loc.startsWith('/super') && impersonating) {
        return '/admin';
      }

      // super_admin que dejó de impersonar pero quedó en /admin/*:
      // redirigir a /super/tenants (su panel real). Sin esto, el
      // super_admin queda viendo el AdminShell vacío post-exit.
      if (rol == 'super_admin' && !impersonating && loc.startsWith('/admin')) {
        return '/super/tenants';
      }

      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/set-password',
        builder: (_, __) => const SetPasswordScreen(),
      ),
      GoRoute(
        path: '/sync-gate',
        builder: (_, __) => const SyncGateScreen(),
      ),
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
          GoRoute(path: '/admin/clientes/:id',
              builder: (_, s) => ClienteDetailScreen(
                  clienteId: s.pathParameters['id']!)),
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
          final titulo = loc == '/super/logs'
              ? 'Logs de errores'
              : loc.contains('/miembros/')
                  ? 'Detalle del miembro'
                  : (loc.startsWith('/super/tenants/') &&
                          loc.length > '/super/tenants/'.length
                      ? 'Configurar tenant'
                      : 'Tenants');
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
          GoRoute(
            path: '/super/tenants/:tid/miembros/:cid',
            builder: (_, s) => MiembroDetalleScreen(
              tenantId: s.pathParameters['tid']!,
              cobradorId: s.pathParameters['cid']!,
            ),
          ),
          GoRoute(
            path: '/super/logs',
            builder: (_, s) => const ErrorLogsScreen(),
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
        builder: (_, s) {
          final param = s.pathParameters['cuotaId']!;
          final ids = param.split(',');
          return CobroScreen(cuotaIds: ids);
        },
      ),
      GoRoute(
        path: '/recibo/:reciboId',
        builder: (_, s) => ReciboScreen(
          reciboId: s.pathParameters['reciboId']!,
          grupoCobro: s.uri.queryParameters['grupo'],
        ),
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
