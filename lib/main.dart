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

  // Capturamos el tipo de flow ANTES de Supabase.initialize.
  //   - Implicit flow (fragment con #type=...): la SDK limpia el fragmento
  //     al procesarlo, así que se debe leer antes.
  //   - PKCE flow (query con ?code=... + opcionalmente ?flow=...): la SDK
  //     puede o no procesar el code automáticamente, depende de la
  //     versión. Leemos `?flow=...` para conocer el tipo.
  // Posibles valores: 'recovery' (forgot password), 'invite' (primera
  // entrada tras invitación), 'signup' (confirm email), null si arranque
  // normal.
  final initialUri = Uri.base;
  final initialAuthFlow = _extractAuthFlow(initialUri);
  final initialPkceCode = initialUri.queryParameters['code'];

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
  //
  // IMPORTANTE: el listener se setea ANTES de exchangeCodeForSession para
  // que los eventos del exchange (signedIn en flows recovery/invite) sean
  // capturados — sino PowerSync queda desconectado pese a tener sesión.
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

  // Si la SDK ya restauró sesión durante initialize (usuario con token
  // persistido), el listener puede haber 'llegado tarde' al initialSession
  // event. Forzamos un connect manual como red de seguridad.
  if (Supabase.instance.client.auth.currentSession != null) {
    await ps.connectPowerSync();
  }

  // Si vino un código PKCE en la URL y la SDK no lo intercambió sola,
  // lo hacemos a mano. Después de exchangeCodeForSession, la sesión queda
  // activa, dispara signedIn, y el listener de arriba conecta PowerSync.
  if (initialPkceCode != null && kIsWeb) {
    try {
      await Supabase.instance.client.auth
          .exchangeCodeForSession(initialPkceCode);
    } catch (e) {
      // Si falla (link expirado, code ya usado, code_verifier no en
      // localStorage de este browser), no bloqueamos el arranque —
      // el usuario verá la pantalla de login.
      debugPrint('exchangeCodeForSession falló: $e');
    }
  }

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

/// Determina el tipo de flow de auth a partir de la URL inicial.
///
/// Supabase puede mandar el usuario de vuelta vía dos esquemas:
///   - Implicit flow → `#access_token=...&type=recovery&...` (fragmento)
///   - PKCE flow     → `?code=...` (query) — preferido en versiones nuevas
///
/// Para PKCE el `type` se pierde en el redirect — Supabase no lo
/// propaga en la URL final. Para preservarlo, agregamos `?flow=...` al
/// redirectTo al iniciar el flow (ver login_screen y edge fn invitar).
/// Si la URL tiene `?code=...` pero no `?flow=...` (link viejo o desde
/// otro path), asumimos 'recovery' como default — es el caso más común
/// y el SetPasswordScreen funciona igual.
String? _extractAuthFlow(Uri uri) {
  // 1. Query param explícito (PKCE con redirectTo customizado).
  final fromQuery = uri.queryParameters['flow'];
  if (fromQuery != null) return fromQuery;

  // 2. Fragment (implicit flow).
  if (uri.fragment.isNotEmpty) {
    final fragParams = Uri.splitQueryString(uri.fragment);
    final fromFragment = fragParams['type'];
    if (fromFragment != null) return fromFragment;
  }

  // 3. Code PKCE sin flow explícito — asumimos recovery por default.
  if (uri.queryParameters['code'] != null) {
    return 'recovery';
  }

  return null;
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
