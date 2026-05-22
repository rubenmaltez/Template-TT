import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsService;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_flow_provider.dart';

/// Pantalla de login.
///
/// Modelo SaaS B2B con onboarding manual: NO permite signup público.
/// El proveedor crea cada tenant + su admin desde Supabase Dashboard.
/// El admin del tenant invita cobradores via la Edge Function
/// `invitar-cobrador` desde el panel admin.
///
/// Sólo dos flujos visibles:
///   - Iniciar sesión
///   - Recuperar contraseña (olvidé mi contraseña)
enum _Modo { login, recuperar }

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  _Modo _modo = _Modo.login;
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    // Si el banner de error viene seteado desde el boot (link expirado,
    // ?error_code=otp_expired, etc.), `liveRegion` no dispara porque
    // está presente en el primer frame — no es una transición. Usamos
    // SemanticsService.announce para forzar la anunciación una vez
    // construido el árbol.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final err = ref.read(initialAuthErrorProvider);
      if (err != null && err.isNotEmpty) {
        SemanticsService.announce(
          _humanizeAuthError(err),
          Directionality.of(context),
        );
      }
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _ejecutar() async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      final email = _email.text.trim();
      switch (_modo) {
        case _Modo.login:
          await Supabase.instance.client.auth.signInWithPassword(
            email: email,
            password: _pass.text,
          );
          break;
        case _Modo.recuperar:
          // redirectTo con flow=recovery: necesario porque Supabase no
          // propaga el `type` original en el redirect del flow PKCE.
          // Sin esto, después del exchange caemos en el dashboard sin
          // pasar por /set-password.
          await Supabase.instance.client.auth.resetPasswordForEmail(
            email,
            redirectTo: kIsWeb
                ? '${Uri.base.origin}/?flow=recovery'
                : null,
          );
          setState(() => _info =
              'Te mandamos un email con el link para recuperar tu contraseña.');
          break;
      }
    } on AuthException catch (e) {
      // Preservamos el Error en la consola del browser para debugging
      // sin exponerlo al user. developer.log queda accesible vía
      // DevTools incluso en release.
      developer.log('Login AuthException', name: 'login', error: e);
      setState(() => _error = _humanizarLoginError(e));
    } catch (e) {
      developer.log('Login error', name: 'login', error: e);
      setState(() => _error = _humanizarLoginError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Traduce excepciones del login/recovery a copy en español. Cubre:
  ///   - `AuthException` con mensajes conocidos de Supabase Auth
  ///     (credenciales inválidas, email no confirmado, rate limit,
  ///     rate-limit-por-tiempo del recovery, formato de email, etc.).
  ///   - Network errors (`ClientException`, `SocketException`,
  ///     `TimeoutException`): el SDK devuelve "ClientException: Failed
  ///     to fetch, uri=https://...supabase.co/auth/v1/token..." que
  ///     expone el backend y string técnico. Lo reemplazamos por un
  ///     mensaje genérico de "sin conexión".
  ///   - Fallback: toString tal cual (raro — los logs de developer.log
  ///     capturan el detalle si pasa).
  String _humanizarLoginError(Object e) {
    if (e is AuthException) {
      final m = e.message.toLowerCase();
      if (m.contains('invalid login') || m.contains('invalid credentials')) {
        return 'Credenciales inválidas. Verificá tu email y contraseña.';
      }
      if (m.contains('email not confirmed')) {
        return 'Tu cuenta todavía no confirmó el email. Revisá tu '
            'bandeja de entrada.';
      }
      if (m.contains('rate limit') || m.contains('too many requests')) {
        return 'Demasiados intentos. Esperá un momento y volvé a probar.';
      }
      // Rate limit del flow de recovery: Supabase devuelve "For security
      // purposes, you can only request this after X seconds".
      if (m.contains('for security purposes') ||
          m.contains('only request this after')) {
        return 'Esperá unos segundos antes de pedir otro link.';
      }
      if (m.contains('unable to validate email') ||
          m.contains('invalid format')) {
        return 'El email no tiene un formato válido.';
      }
      if (m.contains('user not found')) {
        return 'No encontramos ese email en el sistema.';
      }
      return e.message;
    }
    // Detección de network errors por toString: agregar un dep de
    // `http` solo para `is ClientException` es overhead. El package
    // de Supabase los lanza con strings reconocibles.
    final s = e.toString();
    if (s.contains('ClientException') ||
        s.contains('Failed to fetch') ||
        s.contains('SocketException') ||
        s.contains('TimeoutException') ||
        s.contains('Network is unreachable') ||
        s.contains('XMLHttpRequest')) {
      return 'Sin conexión. Verificá tu red e intentá de nuevo.';
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Error capturado desde la URL al boot (link expirado, etc.).
    // Lo mostramos como banner amber arriba del form. Se limpia cuando
    // el user clickea o cuando intenta loguear.
    final authError = ref.watch(initialAuthErrorProvider);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (authError != null) ...[
                  // liveRegion + container para anuncio en transiciones
                  // (login → login con error). Para el caso boot (banner
                  // presente desde el primer frame) liveRegion no
                  // dispara — eso lo cubre el SemanticsService.announce
                  // de initState.
                  Semantics(
                    liveRegion: true,
                    container: true,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.warning_amber,
                              color: scheme.onErrorContainer, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _humanizeAuthError(authError),
                              style: TextStyle(
                                color: scheme.onErrorContainer,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.close,
                                color: scheme.onErrorContainer, size: 18),
                            tooltip: 'Cerrar',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 28, minHeight: 28),
                            onPressed: () => ref
                                .read(initialAuthErrorProvider.notifier)
                                .state = null,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                Icon(Icons.wifi_tethering,
                    size: 64, color: scheme.primary),
                const SizedBox(height: 8),
                Text(
                  'Cobranza ISP',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  switch (_modo) {
                    _Modo.login => 'Iniciar sesión',
                    _Modo.recuperar => 'Recuperar contraseña',
                  },
                  style: TextStyle(color: scheme.outline),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_modo == _Modo.login) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pass,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(
                      labelText: 'Contraseña',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  // Mismo styling de errorContainer que el banner de
                  // arriba — antes era texto rojo suelto, débil en
                  // contraste no-texto (WCAG 1.4.11). liveRegion +
                  // container aseguran que NVDA/TalkBack anuncien al
                  // aparecer (null → String es una transición).
                  Semantics(
                    liveRegion: true,
                    container: true,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.error_outline,
                              color: scheme.onErrorContainer, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: scheme.onErrorContainer,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (_info != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    container: true,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(_info!, textAlign: TextAlign.center),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _ejecutar,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(switch (_modo) {
                          _Modo.login => 'Iniciar sesión',
                          _Modo.recuperar => 'Enviar link',
                        }),
                ),
                const SizedBox(height: 12),
                if (_modo == _Modo.login)
                  TextButton(
                    onPressed: () => setState(() {
                      _modo = _Modo.recuperar;
                      _error = null;
                      _info = null;
                    }),
                    child: const Text('Olvidé mi contraseña'),
                  )
                else
                  TextButton(
                    onPressed: () => setState(() {
                      _modo = _Modo.login;
                      _error = null;
                      _info = null;
                    }),
                    child: const Text('Volver a iniciar sesión'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Convierte códigos de error técnicos de Supabase en mensajes legibles.
  /// Fallback al string original si no hay traducción específica.
  String _humanizeAuthError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('otp_expired') ||
        lower.contains('invalid or has expired')) {
      return 'El link expiró o ya fue usado. Pedí un nuevo email de '
          'recuperación abajo.';
    }
    if (lower.contains('access_denied')) {
      return 'Acceso denegado. Probá iniciar sesión normalmente.';
    }
    return raw;
  }
}
