import 'dart:async';

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
  final refresh = _AuthRefresh(auth);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final loggedIn = auth.currentSession != null;
      final goingToLogin = state.matchedLocation == '/login';
      if (!loggedIn && !goingToLogin) return '/login';
      if (loggedIn && goingToLogin) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),

      // ── Rutas raíz: dentro del Shell (drawer + sync indicator) ────────
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

      // ── Rutas push: con back button propio ────────────────────────────
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

/// Envuelve la pantalla con un InheritedWidget que le da título al AppShell.
Widget _titled(String titulo, Widget child) {
  return ShellTitleScope(titulo: titulo, child: child);
}

/// Permite a AppShell leer el título de la pantalla actual.
class ShellTitleScope extends InheritedWidget {
  const ShellTitleScope({super.key, required this.titulo, required super.child});
  final String titulo;

  @override
  bool updateShouldNotify(ShellTitleScope oldWidget) => oldWidget.titulo != titulo;

  static String? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ShellTitleScope>()?.titulo;
  }
}

class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(GoTrueClient auth) {
    _sub = auth.onAuthStateChange.listen((_) => notifyListeners());
  }
  late final StreamSubscription<AuthState> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
