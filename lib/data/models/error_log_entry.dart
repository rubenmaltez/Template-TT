import 'dart:convert';

/// Tipo de error según el handler que lo capturó.
/// - `flutter`: framework error (build asserts, layout, lifecycle).
/// - `zone`: excepción uncaught en zona (típicamente async sin try/catch).
/// - `platform`: error del isolate / engine (`PlatformDispatcher.onError`).
enum ErrorLogType {
  flutter,
  zone,
  platform;

  static ErrorLogType fromString(String raw) =>
      ErrorLogType.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => ErrorLogType.zone,
      );
}

/// Entrada de log de error capturada por `ErrorLogService`.
///
/// Inmutable. El cliente genera `id` y `clientLogId` (mismo valor en MVP)
/// para deduplicar reintentos de upload — si el backend ya tiene una row
/// con ese `client_log_id`, el segundo INSERT falla por unique constraint
/// y el cliente lo trata como éxito (idempotente).
///
/// `synced=false` indica que aún no se subió al backend. El service hace
/// flush en background al loguearse o al capturar otro error.
class ErrorLogEntry {
  const ErrorLogEntry({
    required this.id,
    required this.ts,
    required this.type,
    required this.message,
    this.stack,
    this.route,
    this.userId,
    this.tenantId,
    this.userAgent,
    this.appVersion,
    this.synced = false,
  });

  final String id;
  final DateTime ts;
  final ErrorLogType type;
  final String message;
  final String? stack;
  final String? route;
  final String? userId;
  final String? tenantId;
  final String? userAgent;
  final String? appVersion;
  final bool synced;

  ErrorLogEntry copyWith({
    bool? synced,
  }) {
    return ErrorLogEntry(
      id: id,
      ts: ts,
      type: type,
      message: message,
      stack: stack,
      route: route,
      userId: userId,
      tenantId: tenantId,
      userAgent: userAgent,
      appVersion: appVersion,
      synced: synced ?? this.synced,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'ts': ts.toIso8601String(),
        'type': type.name,
        'message': message,
        'stack': stack,
        'route': route,
        'user_id': userId,
        'tenant_id': tenantId,
        'user_agent': userAgent,
        'app_version': appVersion,
        'synced': synced,
      };

  /// Payload para insert al backend. Los campos `synced` (local-only) y `ts`
  /// quedan fuera — el backend toma `now()` como `ts` y nunca conoce el
  /// flag de sync.
  Map<String, dynamic> toBackendInsert() => {
        'client_log_id': id,
        'ts': ts.toIso8601String(),
        'error_type': type.name,
        'message': message,
        'stack': stack,
        'route': route,
        'user_id': userId,
        'tenant_id': tenantId,
        'user_agent': userAgent,
        'app_version': appVersion,
      };

  factory ErrorLogEntry.fromJson(Map<String, dynamic> j) => ErrorLogEntry(
        id: j['id'] as String,
        ts: DateTime.parse(j['ts'] as String),
        type: ErrorLogType.fromString(j['type'] as String),
        message: j['message'] as String,
        stack: j['stack'] as String?,
        route: j['route'] as String?,
        userId: j['user_id'] as String?,
        tenantId: j['tenant_id'] as String?,
        userAgent: j['user_agent'] as String?,
        appVersion: j['app_version'] as String?,
        synced: (j['synced'] as bool?) ?? false,
      );

  static String encodeList(List<ErrorLogEntry> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static List<ErrorLogEntry> decodeList(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(ErrorLogEntry.fromJson)
        .toList();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ErrorLogEntry &&
          other.id == id &&
          other.synced == synced);

  @override
  int get hashCode => Object.hash(id, synced);
}
