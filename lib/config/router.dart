import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

final routerProvider = Provider<GoRouter>((ref) {
  final auth = Supabase.instance.client.auth;

  return GoRouter(
    initialLocation: '/',
    refreshListenable: _AuthRefresh(auth),
    redirect: (context, state) {
      final loggedIn = auth.currentSession != null;
      final goingToLogin = state.matchedLocation == '/login';
      if (!loggedIn && !goingToLogin) return '/login';
      if (loggedIn && goingToLogin) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      ShellRoute(
        builder: (_, __, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/',            builder: (_, __) => const HomeScreen()),
          GoRoute(path: '/clientes',    builder: (_, __) => const ClientesListScreen()),
          GoRoute(
            path: '/clientes/:id',
            builder: (_, s) => ClienteDetailScreen(clienteId: s.pathParameters['id']!),
          ),
          GoRoute(path: '/cuotas',      builder: (_, __) => const CuotasListScreen()),
          GoRoute(
            path: '/cobro/:cuotaId',
            builder: (_, s) => CobroScreen(cuotaId: s.pathParameters['cuotaId']!),
          ),
          GoRoute(
            path: '/recibo/:reciboId',
            builder: (_, s) => ReciboScreen(reciboId: s.pathParameters['reciboId']!),
          ),
          GoRoute(path: '/mapa',        builder: (_, __) => const MapaScreen()),
          GoRoute(path: '/historial',   builder: (_, __) => const HistorialScreen()),
          GoRoute(path: '/perfil',      builder: (_, __) => const PerfilScreen()),
        ],
      ),
    ],
  );
});

/// ChangeNotifier que dispara cuando cambia la sesión de Supabase, para que
/// GoRouter re-evalúe `redirect` automáticamente.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(GoTrueClient auth) {
    _sub = auth.onAuthStateChange.listen((_) => notifyListeners());
  }
  late final dynamic _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
