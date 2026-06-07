import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'connector.dart';
import 'schema.dart';

/// Base PowerSync activa. Se recrea al cambiar de usuario (per-user DB).
late PowerSyncDatabase db;

/// Stream global de errores de CRUD upload.
final uploadErrorsController = StreamController<CrudUploadError>.broadcast();

/// User ID de la DB actualmente abierta. null si no hay DB abierta.
String? _currentDbUserId;

/// Lock para serializar operaciones de DB.
Completer<void>? _pendingOp;

/// Suscripción al connector actual (para cancelar al reconectar).
StreamSubscription<CrudUploadError>? _connectorSub;

/// Callback que se invoca después de abrir una nueva DB per-user.
/// main.dart lo usa para re-suscribir statusStream y re-invalidar providers.
void Function(PowerSyncDatabase newDb)? onDatabaseSwitched;

/// Directorio base para las DBs (lazy).
String? _dbDirPath;

Future<String> _getDbDir() async {
  if (_dbDirPath != null) return _dbDirPath!;
  if (kIsWeb) {
    _dbDirPath = '';
    return '';
  }
  final dir = await getApplicationSupportDirectory();
  _dbDirPath = dir.path;
  return dir.path;
}

/// Versión del schema local. Bumpear cuando se modifica schema.dart
/// (nueva columna, nueva tabla). Esto fuerza una DB fresca para todos
/// los usuarios, evitando bugs de schema cache.
const _schemaVersion = 20;

String _dbPathForUser(String userId, String basePath) {
  if (kIsWeb) {
    return 'sitecsa_${userId}_v$_schemaVersion.db';
  }
  return '$basePath/sitecsa_${userId}_v$_schemaVersion.db';
}

/// Abre la DB genérica (sin user). Solo para el boot inicial antes del login.
Future<void> openDatabase() async {
  final dir = await _getDbDir();
  final path = kIsWeb
      ? 'sitecsa_default_v$_schemaVersion.db'
      : '$dir/sitecsa_default_v$_schemaVersion.db';
  db = PowerSyncDatabase(schema: schema, path: path);
  await db.initialize();
}

/// Abre (o reutiliza) la DB del usuario específico. Si es el mismo user
/// que la DB actual, no hace nada (reconexión instantánea). Si es un
/// user diferente, cierra la DB anterior y abre la nueva.
Future<void> openDatabaseForUser(String userId) async {
  if (_currentDbUserId == userId) return;

  // Serializar con cualquier operación en vuelo.
  if (_pendingOp != null && !_pendingOp!.isCompleted) {
    await _pendingOp!.future;
  }
  final op = Completer<void>();
  _pendingOp = op;

  try {
    // Cerrar la DB anterior.
    try { await db.disconnect(); } catch (_) {}
    try { await db.close(); } catch (_) {}

    final dir = await _getDbDir();
    final path = _dbPathForUser(userId, dir);
    db = PowerSyncDatabase(schema: schema, path: path);
    await db.initialize();
    _currentDbUserId = userId;

    // Notificar a main.dart para re-suscribir statusStream y providers.
    onDatabaseSwitched?.call(db);
  } finally {
    op.complete();
  }
}

/// Conecta PowerSync usando la sesión Supabase actual.
Future<void> connectPowerSync() async {
  // Cancelar suscripción anterior del connector.
  await _connectorSub?.cancel();

  final connector = SupabaseConnector(Supabase.instance.client);
  _connectorSub = connector.uploadErrors.listen((error) {
    uploadErrorsController.add(error);
  });
  await db.connect(connector: connector);
}

/// Desconecta PowerSync sin borrar datos locales.
Future<void> disconnectPowerSync() async {
  if (_pendingOp != null && !_pendingOp!.isCompleted) {
    await _pendingOp!.future;
  }
  final op = Completer<void>();
  _pendingOp = op;
  try {
    await db.disconnect();
  } finally {
    op.complete();
  }
}
