import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config/env.dart';
import 'data/services/foto_comprobante_service.dart';
import 'powersync/db.dart' as ps;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Path URL strategy en web: URLs limpias (`/admin` en vez de `/#/admin`).
  // Necesario para que Supabase pueda redirigir invitaciones/recuperaciones
  // con `#access_token=...` sin que GoRouter intente parsear el fragmento
  // como ruta y reviente.
  if (kIsWeb) usePathUrlStrategy();

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
        // disconnectAndClear (no sólo disconnect) — borra el SQLite local
        // así el próximo user que se loguee en este device no ve la fila
        // de cobradores ni los datos operativos del anterior hasta que
        // PowerSync sincronice la nueva data desde el server.
        await ps.disconnectAndClearPowerSync();
        break;
      default:
        break;
    }
  });

  // Background worker: sube fotos del comprobante pendientes cuando hay
  // conexión. El service tiene su propio lock interno — el botón manual
  // en perfil y este worker comparten la misma protección.
  // GC de archivos huérfanos al arrancar (cobros cancelados, etc.).
  final fotoService = FotoComprobanteService(Supabase.instance.client);
  unawaited(fotoService.limpiarHuerfanos());
  ps.db.statusStream.listen((status) {
    if (status.connected) unawaited(fotoService.sincronizarPendientes());
  });

  runApp(const ProviderScope(child: IspBillingApp()));
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
