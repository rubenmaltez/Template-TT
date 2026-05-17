import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/env.dart';
import 'powersync/db.dart' as ps;
import 'screens/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!Env.isConfigured) {
    runApp(const _ConfigMissingApp());
    return;
  }

  await Supabase.initialize(
    url: Env.supabaseUrl,
    anonKey: Env.supabaseAnonKey,
  );
  await ps.openDatabase();

  // Conectar/desconectar PowerSync siguiendo el ciclo de vida de la sesión.
  // `initialSession` cubre el caso de arranque con token persistido.
  // El refresh automático del token lo gestiona PowerSync llamando a
  // `fetchCredentials` cuando lo necesita, así que no escuchamos `tokenRefreshed`.
  Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
    switch (data.event) {
      case AuthChangeEvent.initialSession:
      case AuthChangeEvent.signedIn:
        if (data.session != null) {
          await ps.connectPowerSync();
        }
        break;
      case AuthChangeEvent.signedOut:
        await ps.disconnectPowerSync();
        break;
      default:
        break;
    }
  });

  runApp(const IspBillingApp());
}

class IspBillingApp extends StatelessWidget {
  const IspBillingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ISP Billing',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

class _ConfigMissingApp extends StatelessWidget {
  const _ConfigMissingApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Configuración pendiente:\n\n'
              'Faltan SUPABASE_URL / SUPABASE_ANON_KEY / '
              'POWERSYNC_URL / POWERSYNC_TOKEN_ENDPOINT.\n\n'
              'Lanza la app con:\n'
              'flutter run --dart-define-from-file=.env.json',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
