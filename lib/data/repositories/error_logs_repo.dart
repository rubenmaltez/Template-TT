import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/error_log_entry.dart';

/// Row tal como la devuelve la RPC `list_error_logs`. Incluye los nombres
/// joineados de `tenants.nombre` y `cobradores.nombre` para evitar tener
/// que resolverlos por separado en la UI.
class ErrorLogView {
  const ErrorLogView({
    required this.id,
    required this.ts,
    required this.errorType,
    required this.message,
    this.stack,
    this.route,
    this.userId,
    this.userNombre,
    this.tenantId,
    this.tenantNombre,
    this.userAgent,
    this.appVersion,
    required this.reportedAt,
  });

  final String id;
  final DateTime ts;
  final ErrorLogType errorType;
  final String message;
  final String? stack;
  final String? route;
  final String? userId;
  final String? userNombre;
  final String? tenantId;
  final String? tenantNombre;
  final String? userAgent;
  final String? appVersion;
  final DateTime reportedAt;

  factory ErrorLogView.fromMap(Map<String, dynamic> m) => ErrorLogView(
        id: m['id'] as String,
        ts: DateTime.parse(m['ts'] as String),
        errorType: ErrorLogType.fromString(m['error_type'] as String),
        message: m['message'] as String,
        stack: m['stack'] as String?,
        route: m['route'] as String?,
        userId: m['user_id'] as String?,
        userNombre: m['user_nombre'] as String?,
        tenantId: m['tenant_id'] as String?,
        tenantNombre: m['tenant_nombre'] as String?,
        userAgent: m['user_agent'] as String?,
        appVersion: m['app_version'] as String?,
        reportedAt: DateTime.parse(m['reported_at'] as String),
      );
}

class ErrorLogsRepo {
  const ErrorLogsRepo(this._client);
  final SupabaseClient _client;

  Future<List<ErrorLogView>> list({
    String? tenantId,
    ErrorLogType? errorType,
    String? search,
    int limit = 100,
  }) async {
    final params = <String, dynamic>{
      'p_tenant_id': tenantId,
      'p_error_type': errorType?.name,
      'p_search': (search == null || search.isEmpty) ? null : search,
      'p_limit': limit,
    };
    final res = await _client.rpc('list_error_logs', params: params)
        as List<dynamic>;
    return res
        .map((e) => ErrorLogView.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}

final errorLogsRepoProvider = Provider<ErrorLogsRepo>((ref) {
  return ErrorLogsRepo(Supabase.instance.client);
});

/// Tamaño de página por defecto para el viewer de error logs.
const int kErrorLogsPageSize = 50;

/// Filtros mutables del viewer.
class ErrorLogsFilter {
  const ErrorLogsFilter({
    this.tenantId,
    this.errorType,
    this.search,
    this.limit = kErrorLogsPageSize,
  });

  final String? tenantId;
  final ErrorLogType? errorType;
  final String? search;
  final int limit;

  ErrorLogsFilter copyWith({
    Object? tenantId = _sentinel,
    Object? errorType = _sentinel,
    Object? search = _sentinel,
    Object? limit = _sentinel,
  }) {
    return ErrorLogsFilter(
      tenantId: identical(tenantId, _sentinel)
          ? this.tenantId
          : tenantId as String?,
      errorType: identical(errorType, _sentinel)
          ? this.errorType
          : errorType as ErrorLogType?,
      search:
          identical(search, _sentinel) ? this.search : search as String?,
      limit: identical(limit, _sentinel) ? this.limit : limit as int,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ErrorLogsFilter &&
          other.tenantId == tenantId &&
          other.errorType == errorType &&
          other.search == search &&
          other.limit == limit);

  @override
  int get hashCode => Object.hash(tenantId, errorType, search, limit);

  static const _sentinel = Object();
}

final errorLogsFilterProvider =
    StateProvider<ErrorLogsFilter>((_) => const ErrorLogsFilter());

final errorLogsListProvider =
    FutureProvider.autoDispose<List<ErrorLogView>>((ref) {
  final filter = ref.watch(errorLogsFilterProvider);
  return ref.read(errorLogsRepoProvider).list(
        tenantId: filter.tenantId,
        errorType: filter.errorType,
        search: filter.search,
        limit: filter.limit,
      );
});
