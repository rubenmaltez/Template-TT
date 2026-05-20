import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config/env.dart';
import 'data/providers/auth_identity_provider.dart';
import 'data/services/foto_comprobante_service.dart';
import 'features/auth/auth_flow_provider.dart';
import 'powersync/db.dart' as ps;

const _kLastKnownUserIdKey = 'last_known_user_id';

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
  final initialAuthError = _extractAuthError(initialUri);
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

  // Pre-cargar el last_known_user_id de SharedPreferences. El
  // authIdentityProvider lo necesita como estado inicial para detectar
  // user switch cross-session: si la pestaña se cerró post-signOut y
  // otro user se loguea al reabrir, sin este storage arrancaríamos en
  // (null, null) y no gatearíamos el cache stale del user anterior.
  final prefs = await SharedPreferences.getInstance();
  final lastKnownUserId = prefs.getString(_kLastKnownUserIdKey);

  // ProviderContainer creado acá (no dentro de ProviderScope) para que el
  // listener de auth de abajo pueda mutar el authIdentityProvider — el
  // sync gate (R7) necesita capturar el momento exacto de signIn/signOut.
  final container = ProviderContainer(
    overrides: [
      initialAuthFlowProvider.overrideWith((_) => initialAuthFlow),
      initialAuthErrorProvider.overrideWith((_) => initialAuthError),
      authIdentityProvider.overrideWith((ref) => AuthIdentityNotifier(
            lastKnownUserId: lastKnownUserId,
            onPersist: (uid) => prefs.setString(_kLastKnownUserIdKey, uid),
          )),
    ],
  );

  // Conectar/desconectar PowerSync siguiendo el ciclo de vida de la sesión.
  // `initialSession` cubre el caso de arranque con token persistido.
  //
  // IMPORTANTE: el listener se setea ANTES de exchangeCodeForSession para
  // que los eventos del exchange (signedIn en flows recovery/invite) sean
  // capturados — sino PowerSync queda desconectado pese a tener sesión.
  Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
    final session = data.session;
    switch (data.event) {
      case AuthChangeEvent.initialSession:
      case AuthChangeEvent.signedIn:
        if (session != null) {
          container
              .read(authIdentityProvider.notifier)
              .onSignIn(session.user.id);
          await ps.connectPowerSync();
        }
        break;
      case AuthChangeEvent.signedOut:
        // Sólo desconectamos sync — la data local del usuario anterior
        // queda en SQLite por performance / offline. El sync gate (R7)
        // bloquea la UI hasta que PowerSync confirme un sync posterior
        // al signOut, así el próximo user no ve data del anterior.
        container.read(authIdentityProvider.notifier).onSignOut();
        await ps.disconnectPowerSync();
        break;
      default:
        break;
    }
  });

  // Si la SDK ya restauró sesión durante initialize (usuario con token
  // persistido), el listener puede haber 'llegado tarde' al initialSession
  // event. Forzamos un connect manual como red de seguridad — sino
  // PowerSync queda desconectado pese a tener sesión.
  //
  // El guard `currentIdentity.userId != restoredSession.user.id` evita el
  // double-connect: si el listener YA recibió initialSession y llamó
  // onSignIn, el provider tiene el uid actual → skipeamos. Si el state
  // inicial vino del storage (mismo uid restaurado) también skipeamos.
  // Sólo entramos si la identidad efectivamente cambió.
  final restoredSession = Supabase.instance.client.auth.currentSession;
  if (restoredSession != null) {
    final currentIdentity = container.read(authIdentityProvider);
    if (currentIdentity.userId != restoredSession.user.id) {
      container
          .read(authIdentityProvider.notifier)
          .onSignIn(restoredSession.user.id);
      await ps.connectPowerSync();
    }
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

  runApp(UncontrolledProviderScope(
    container: container,
    child: const IspBillingApp(),
  ));
}

/// Lee el código de error de la URL inicial. Supabase manda errores en
/// query params cuando el link caduca o es inválido:
///   `?error=access_denied&error_code=otp_expired&error_description=…`
/// Preferimos error_description (legible) > error_code > error.
String? _extractAuthError(Uri uri) {
  final desc = uri.queryParameters['error_description'];
  if (desc != null && desc.isNotEmpty) return desc.replaceAll('+', ' ');
  final code = uri.queryParameters['error_code'];
  if (code != null && code.isNotEmpty) return code;
  return uri.queryParameters['error'];
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
