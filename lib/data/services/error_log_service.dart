import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/error_log_entry.dart';
import '../../powersync/db.dart' as ps;

/// Singleton que captura errores no manejados (Flutter framework, async
/// zones, isolate platform) y los persiste localmente + los sube a la
/// tabla `error_logs` de Supabase cuando hay sesión.
///
/// **Flujo**:
/// 1. `init()` se llama una vez en `main.dart` antes de `runApp`. Instala
///    `FlutterError.onError`, `PlatformDispatcher.instance.onError`, y se
///    suscribe a `onAuthStateChange` para flushear pendientes al loguearse.
/// 2. `runZonedGuarded` en `main.dart` redirige errores uncaught a
///    `record(type: ErrorLogType.zone)`.
/// 3. Cada error se guarda en memoria + SharedPreferences (FIFO 200 max)
///    e intenta upload en background.
/// 4. Pre-login (sin `auth.uid()`) los logs quedan locales — la RLS
///    requiere `user_id = auth.uid()` y atribuir post-hoc al user que
///    haga login podría ser un user distinto.
///
/// **Idempotencia**: cada entry tiene un `client_log_id` (UUID v4). La
/// migración 0035 lo declara UNIQUE — un reintento del mismo entry choca
/// contra el unique constraint y lo tratamos como éxito (already-uploaded).
///
/// **Recursión**: si el propio handler tira excepción, queda atrapada en
/// `_safeRecord` con try/catch para no entrar en loop infinito.
class ErrorLogService {
  ErrorLogService._();
  static final ErrorLogService instance = ErrorLogService._();

  static const _kPrefsKey = 'error_logs_v1';
  static const _kMaxLocalEntries = 200;
  static const _uuid = Uuid();

  final List<ErrorLogEntry> _logs = [];
  bool _initialized = false;
  bool _flushing = false;
  String? _appVersion;

  // Suscripción al auth state change. Se guarda para poder cancelarla en
  // hot restart (dev) — sino cada init() acumula un listener nuevo sobre
  // el anterior (mismo patrón que `_authSub` global en main.dart).
  StreamSubscription? _authSub;

  // Rate limit: evita que un crash-loop llene la cola FIFO con cientos
  // de entries idénticas por segundo. Si el mismo error (tipo+mensaje)
  // se registró hace menos de 5s, skip.
  String? _lastRecordedKey;
  DateTime? _lastRecordedAt;
  static const _rateLimitWindow = Duration(seconds: 5);

  // User agent: distingue plataforma (web vs Android vs desktop).
  // Se cachea una vez; no es el browser UA completo pero es útil
  // para filtrar en el viewer.
  static String? _cachedUserAgent;

  /// Setup handlers + carga pendientes. Idempotente.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Cargar pendientes del storage local.
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        _logs.addAll(ErrorLogEntry.decodeList(raw));
      }
    } catch (_) {
      // SharedPreferences puede fallar en first run o si el storage está
      // corrupto. Arrancamos con lista vacía y seguimos.
    }

    // App version (best-effort).
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {
      _appVersion = null;
    }

    // Handlers globales.
    FlutterError.onError = (details) {
      // Imprimir en consola dev también (default behavior).
      FlutterError.presentError(details);
      _safeRecord(
        error: details.exception,
        stack: details.stack,
        type: ErrorLogType.flutter,
      );
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      _safeRecord(
        error: error,
        stack: stack,
        type: ErrorLogType.platform,
      );
      return true;
    };

    // Flush al loguearse. Antes del flush purgamos entries con userId
    // diferente al actual — son del user anterior del browser y nunca
    // van a poder subirse (RLS rechazaría). Sin esta purga ocupan slots
    // del FIFO 200 indefinidamente.
    //
    // Cancelar suscripción previa antes de re-suscribir (hot restart en
    // dev) — sino se acumulan listeners y flushPending corre N veces por
    // evento. Mismo patrón que el `_authSub` global de main.dart.
    _authSub?.cancel();
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      if (event.event == AuthChangeEvent.signedIn ||
          event.event == AuthChangeEvent.initialSession) {
        final uid = event.session?.user.id;
        if (uid != null) {
          _purgeForeignUserEntries(uid);
        }
        unawaited(flushPending());
      }
    });
  }

  /// Disparable externamente cuando PowerSync reconecta — los entries que
  /// quedaron pendientes durante offline se intentan subir ahora.
  Future<void> onConnectivityRestored() => flushPending();

  /// Captura un error. NUNCA tira excepción — cualquier fallo del propio
  /// servicio se traga en silencio para evitar recursión.
  void _safeRecord({
    required Object error,
    StackTrace? stack,
    required ErrorLogType type,
  }) {
    try {
      unawaited(record(error: error, stack: stack, type: type));
    } catch (_) {
      // No podemos hacer nada más. Si esto se ejecuta, hay un bug en
      // record() mismo.
    }
  }

  /// API pública para errores capturados manualmente (ej. catch blocks).
  ///
  /// Wrapped en try/catch entero — cualquier fallo del propio servicio
  /// (ej. PowerSync `getAll` que tira async, Supabase no inicializado,
  /// SharedPreferences quota exceeded) NO debe propagar al runZonedGuarded
  /// que lo invocó originalmente porque entraría en recursión infinita.
  Future<void> record({
    required Object error,
    StackTrace? stack,
    required ErrorLogType type,
    String? route,
  }) async {
    try {
      // Pre-init: SharedPreferences aún no se cargó, así que `_logs` está
      // vacío. Si registramos ahora y `_save()`, pisamos los pendientes
      // de la sesión anterior. Mejor descartar este error temprano
      // — la ventana es chica (entre WidgetsFlutterBinding.ensureInitialized
      // y Supabase.initialize + ErrorLogService.init).
      if (!_initialized) return;

      // Rate limit: si el mismo error (tipo+mensaje) se registró hace
      // menos de 5s, skip. Evita que un crash-loop llene la cola FIFO
      // con cientos de entries idénticas por segundo.
      final rateLimitKey = '${type.name}:${error.toString().hashCode}';
      final now = DateTime.now();
      if (rateLimitKey == _lastRecordedKey &&
          _lastRecordedAt != null &&
          now.difference(_lastRecordedAt!) < _rateLimitWindow) {
        return;
      }
      _lastRecordedKey = rateLimitKey;
      _lastRecordedAt = now;

      // User agent: cachear una vez para distinguir plataforma.
      if (_cachedUserAgent == null) {
        _cachedUserAgent = kIsWeb
            ? 'Flutter Web'
            : 'Flutter ${defaultTargetPlatform.name}';
      }

      final entry = ErrorLogEntry(
        id: _uuid.v4(),
        ts: DateTime.now().toUtc(),
        type: type,
        message: _truncate(error.toString(), 4000),
        stack: stack == null ? null : _truncate(stack.toString(), 16000),
        route: route ?? _currentRoute(),
        userId: Supabase.instance.client.auth.currentUser?.id,
        tenantId: await _currentTenantId(),
        userAgent: _cachedUserAgent,
        appVersion: _appVersion,
        synced: false,
      );

      _logs.add(entry);
      // Rotación FIFO.
      while (_logs.length > _kMaxLocalEntries) {
        _logs.removeAt(0);
      }
      await _save();

      // Upload background. Skipeamos si flushPending está iterando para
      // evitar doble INSERT (mitigado por UNIQUE en client_log_id pero
      // genera ruido en logs). El próximo flush levanta este entry.
      if (!_flushing) {
        unawaited(_uploadOne(entry));
      }
    } catch (_) {
      // Tragar TODO. Si el logger crashea, no podemos hacer más sin
      // arriesgar recursión via runZonedGuarded.
    }
  }

  /// Reintenta uploads pendientes. Llamado al loguearse y manualmente.
  Future<void> flushPending() async {
    if (_flushing) return;
    _flushing = true;
    try {
      // Copia para evitar mutación durante iteración.
      final pending = _logs.where((e) => !e.synced).toList();
      for (final e in pending) {
        await _uploadOne(e);
      }
    } finally {
      _flushing = false;
    }
  }

  /// Lista en memoria — útil para debug y un viewer local opcional.
  List<ErrorLogEntry> getRecent() => List.unmodifiable(_logs.reversed);

  /// Borra el storage local. NO afecta backend.
  Future<void> clearLocal() async {
    _logs.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kPrefsKey);
    } catch (_) {}
  }

  // ── Internals ─────────────────────────────────────────────────────────

  Future<void> _uploadOne(ErrorLogEntry entry) async {
    if (entry.synced) return;

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    // Pre-login (entry.userId == null): no podemos atribuir. La RLS
    // exige user_id = auth.uid() en INSERT; atribuir post-hoc al user
    // que esté logueado AHORA sería incorrecto (podría ser otro user
    // que entró al mismo browser). Lo dejamos local.
    if (entry.userId == null) return;
    if (entry.userId != user.id) return;

    try {
      await Supabase.instance.client
          .from('error_logs')
          .insert(entry.toBackendInsert());

      _markSynced(entry.id);
      await _save();
    } on PostgrestException catch (e) {
      // 23505 = unique_violation. Idempotente: el client_log_id ya está
      // en backend, marcamos como synced.
      if (e.code == '23505') {
        _markSynced(entry.id);
        await _save();
        return;
      }
      // 42501 = insufficient_privilege. RLS rechazó el insert: la
      // sesión no puede subir este entry NUNCA (user_id mismatch,
      // tenant_id mismatch, sesión expirada con cache stale). Marcamos
      // synced para descartar — sino queda atascado en el FIFO
      // ocupando un slot e intentando indefinidamente.
      if (e.code == '42501') {
        _markSynced(entry.id);
        await _save();
        return;
      }
      // Otros (red, 5xx, etc.): queda pendiente, reintento próximo.
    } catch (_) {
      // Red u otros errores no-PostgrestException: queda pendiente.
    }
  }

  void _markSynced(String id) {
    final i = _logs.indexWhere((e) => e.id == id);
    if (i >= 0) {
      _logs[i] = _logs[i].copyWith(synced: true);
    }
  }

  /// Borra entries cuyo `userId` no coincide con el `currentUserId`.
  /// Llamado en signedIn para limpiar logs del user anterior del browser
  /// que jamás podrían subirse (RLS rechazaría).
  void _purgeForeignUserEntries(String currentUserId) {
    _logs.removeWhere(
      (e) => e.userId != null && e.userId != currentUserId,
    );
    unawaited(_save());
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefsKey, ErrorLogEntry.encodeList(_logs));
    } catch (_) {
      // Si SharedPreferences falla (quota exceeded, storage corrupto),
      // mantenemos los logs en memoria al menos para esta sesión.
    }
  }

  String? _currentRoute() {
    // GoRouter no expone una API estática global. En web podemos leer
    // la URL actual del navigator. En mobile queda null por ahora
    // (anotado al backlog).
    if (kIsWeb) {
      try {
        return Uri.base.path + (Uri.base.hasQuery ? '?${Uri.base.query}' : '');
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<String?> _currentTenantId() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return null;
    try {
      final rows = await ps.db.getAll(
        'SELECT tenant_id FROM cobradores WHERE id = ?',
        [user.id],
      );
      if (rows.isEmpty) return null;
      return rows.first['tenant_id'] as String?;
    } catch (_) {
      // PowerSync DB puede no estar abierta aún o el row puede no estar
      // sincronizado. tenant_id queda null — el backend lo acepta.
      return null;
    }
  }

  String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…[truncated ${s.length - max} chars]';
}
