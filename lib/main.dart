import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config/env.dart';
import 'data/services/foto_comprobante_service.dart';
import 'features/auth/auth_flow_provider.dart';
import 'powersync/db.dart' as ps;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Path URL strategy en web: URLs limpias (`/admin` en vez de `/#/admin`).
  // Necesario para que Supabase pueda redirigir invitaciones/recuperaciones
  // con `#access_token=...` sin que GoRouter intente parsear el fragmento
  // como ruta y reviente.
  if (kIsWeb) usePathUrlStrategy();

  // Capturamos el tipo de flow ANTES de Supabase.initialize, porque la SDK
  // procesa y LIMPIA el fragmento durante la inicialización. Si lo
  // intentamos leer después, ya no está. Posibles valores: 'recovery'
  // (forgot password), 'invite' (primera entrada tras invitación),
  // 'signup' (confirm email), o null si arranque normal.
  final initialAuthFlow = _extractAuthFlow(Uri.base);

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
        // Sólo desconectamos sync — la data local del usuario anterior
        // queda en SQLite por performance / offline. Si otro user se
        // loguea en el mismo browser puede ver brevemente el panel
        // 'viejo' hasta que PowerSync sincronice la suya: TODO mejorar
        // ese caso sin perder el caché local (ver TODOs globales).
        await ps.disconnectPowerSync();
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

  runApp(ProviderScope(
    overrides: [
      initialAuthFlowProvider.overrideWith((_) => initialAuthFlow),
    ],
    child: const IspBillingApp(),
  ));
}

/// Lee el query param `type` del fragmento de la URL inicial.
/// Supabase manda los links de recovery / invite con el formato
/// `localhost:55000/#access_token=...&type=recovery&...`.
String? _extractAuthFlow(Uri uri) {
  final fragment = uri.fragment;
  if (fragment.isEmpty) return null;
  final params = Uri.splitQueryString(fragment);
  return params['type'];
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
