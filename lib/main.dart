import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config/env.dart';
import 'data/models/error_log_entry.dart';
import 'data/providers/auth_identity_provider.dart';
import 'data/providers/foto_comprobante_provider.dart';
import 'data/services/error_log_service.dart';
import 'features/auth/auth_flow_provider.dart';
import 'powersync/db.dart' as ps;

const _kLastKnownUserIdKey = 'last_known_user_id';

// Suscripción al auth state change. Se guarda en scope global para
// poder cancelarla en hot restart (dev) — sino el listener previo
// intenta usar el ProviderContainer disposed y tira excepciones.
StreamSubscription? _authSub;

Future<void> main() async {
  // Envolvemos todo en runZonedGuarded para capturar excepciones uncaught
  // de código async (sin try/catch) que no son interceptadas por
  // FlutterError.onError. El handler delega a ErrorLogService que persiste
  // local + sube al backend cuando hay sesión.
  //
  // WidgetsFlutterBinding.ensureInitialized() corre DENTRO de la zona para
  // que el binding y los runApp queden en la misma zona — sin esto
  // Flutter emite "Zone mismatch" warnings.
  await runZonedGuarded<Future<void>>(_bootstrap, (error, stack) {
    ErrorLogService.instance.record(
      error: error,
      stack: stack,
      type: ErrorLogType.zone,
    );
  });
}

Future<void> _bootstrap() async {
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

  // Inicializar el logger temprano (post-Supabase porque usa auth.client,
  // pre-PowerSync porque la query a cobradores es tolerante a DB cerrada).
  // Esto instala FlutterError.onError y PlatformDispatcher.onError, que
  // junto con el runZonedGuarded de main() capturan los 3 tipos de errores.
  await ErrorLogService.instance.init();

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
  //
  // **Telemetría del sync flow** (debug del bug "sync gate stuck
  // post-forzar-password"): logueamos cada paso del flow signedIn →
  // connectPowerSync para que la próxima reproducción del bug aparezca
  // en /super/logs con info útil. `connectPowerSync` envuelto en
  // try/catch porque sino las excepciones del SDK quedan silenciadas
  // dentro del listener async.
  // Cancelar suscripción previa si existe (hot restart en dev). Sin
  // cancel, el listener viejo intenta usar el container disposed →
  // ProviderDisposedException en consola.
  _authSub?.cancel();
  _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
    final session = data.session;
    switch (data.event) {
      case AuthChangeEvent.initialSession:
      case AuthChangeEvent.signedIn:
        if (session != null) {
          debugPrint('[SYNC-DIAG] ${data.event.name} for user ${session.user.id}');
          container
              .read(authIdentityProvider.notifier)
              .onSignIn(session.user.id);
          try {
            debugPrint('[SYNC-DIAG] connectPowerSync starting…');
            await ps.connectPowerSync();
            debugPrint('[SYNC-DIAG] connectPowerSync returned OK');
          } catch (e, stack) {
            debugPrint('[SYNC-DIAG] connectPowerSync THREW: $e');
            // Captura al logger para que aparezca en /super/logs.
            // Sin esto el error queda invisible y el sync gate queda
            // colgado eterno (el user ve "Sincronizando datos…" sin
            // saber que connect falló).
            unawaited(ErrorLogService.instance.record(
              error: 'connectPowerSync falló post-${data.event.name}: $e',
              stack: stack,
              type: ErrorLogType.zone,
            ));
          }
        }
        break;
      case AuthChangeEvent.signedOut:
        // Sólo desconectamos sync — la data local del usuario anterior
        // queda en SQLite por performance / offline. El sync gate (R7)
        // bloquea la UI hasta que PowerSync confirme un sync posterior
        // al signOut, así el próximo user no ve data del anterior.
        debugPrint('[SYNC-DIAG] signedOut event');
        container.read(authIdentityProvider.notifier).onSignOut();
        try {
          await ps.disconnectPowerSync();
          debugPrint('[SYNC-DIAG] disconnectPowerSync returned OK');
        } catch (e, stack) {
          debugPrint('[SYNC-DIAG] disconnectPowerSync THREW: $e');
          unawaited(ErrorLogService.instance.record(
            error: 'disconnectPowerSync falló post-signOut: $e',
            stack: stack,
            type: ErrorLogType.zone,
          ));
        }
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
      debugPrint('[SYNC-DIAG] Fallback manual connect for restored user '
          '${restoredSession.user.id} (identity ≠ session)');
      container
          .read(authIdentityProvider.notifier)
          .onSignIn(restoredSession.user.id);
      try {
        await ps.connectPowerSync();
        debugPrint('[SYNC-DIAG] Fallback connect returned OK');
      } catch (e, stack) {
        debugPrint('[SYNC-DIAG] Fallback connect THREW: $e');
        unawaited(ErrorLogService.instance.record(
          error: 'connectPowerSync falló en fallback manual: $e',
          stack: stack,
          type: ErrorLogType.zone,
        ));
      }
    } else {
      debugPrint('[SYNC-DIAG] Fallback skip (identity already matches '
          'restored session user)');
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
  //
  // Importante: leemos del container (mismo singleton que la UI consume).
  // Con instancia local separada, el StreamController de `results` no
  // sería el mismo que el UI watchea via `uploadResultsProvider` y los
  // SnackBars de R8 nunca llegarían.
  // GC de archivos huérfanos al arrancar (cobros cancelados, etc.).
  final fotoService = container.read(fotoComprobanteServiceProvider);
  unawaited(fotoService.limpiarHuerfanos());
  // Tracking del último error reportado para no spammear logs si el
  // status emite repetido con el mismo error en cada checkpoint.
  Object? lastReportedSyncError;
  ps.db.statusStream.listen((status) {
    if (status.connected) {
      unawaited(fotoService.sincronizarPendientes());
      // Reintento de uploads de error_logs que quedaron pendientes
      // durante offline (gap del listener de auth, que solo flushea
      // en signedIn).
      unawaited(ErrorLogService.instance.onConnectivityRestored());
    }
    // Telemetría del sync flow: si PowerSync reporta un error
    // (anyError, downloadError, uploadError), lo capturamos al
    // logger. Eso nos da visibilidad del bug "sync gate stuck" si
    // PowerSync está fallando silenciosamente sin emitir checkpoint.
    final err = status.anyError;
    if (err != null && err != lastReportedSyncError) {
      lastReportedSyncError = err;
      debugPrint('[SYNC-DIAG] PowerSync anyError: $err');
      unawaited(ErrorLogService.instance.record(
        error: 'PowerSync status.anyError: $err',
        stack: StackTrace.current,
        type: ErrorLogType.zone,
      ));
    } else if (err == null && lastReportedSyncError != null) {
      // Reset el tracker cuando el error se resuelve, para capturar
      // un error futuro distinto.
      lastReportedSyncError = null;
    }
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
