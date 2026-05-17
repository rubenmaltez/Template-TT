import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config/env.dart';
import 'data/services/foto_comprobante_service.dart';
import 'powersync/db.dart' as ps;

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

  // Background worker: sube fotos del comprobante pendientes cuando hay
  // conexión. Reacciona a cambios en sync status; un flag evita corridas
  // simultáneas si el estado fluctúa.
  _arrancarFotosWorker();

  runApp(const ProviderScope(child: IspBillingApp()));
}

bool _fotosCorriendo = false;
void _arrancarFotosWorker() {
  ps.db.statusStream.listen((status) async {
    if (!status.connected || _fotosCorriendo) return;
    _fotosCorriendo = true;
    try {
      await FotoComprobanteService(Supabase.instance.client)
          .sincronizarPendientes();
    } catch (_) {
      // Silencioso: se reintenta en el próximo evento de sync.
    } finally {
      _fotosCorriendo = false;
    }
  });
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
