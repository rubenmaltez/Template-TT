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

/// Lock para serializar disconnect/connect.
Future<void>? _pendingDisconnect;

/// Directorio base para las DBs (lazy, solo se calcula una vez).
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

String _dbPathForUser(String userId, String basePath) {
  if (kIsWeb) {
    // En web, IndexedDB usa el nombre como key — incluir user ID.
    return 'sitecsa_$userId.db';
  }
  // En mobile/desktop, archivo separado por user.
  return '$basePath/sitecsa_$userId.db';
}

/// Abre la DB genérica (sin user). Solo para el boot inicial antes del login.
Future<void> openDatabase() async {
  final dir = await _getDbDir();
  final path = kIsWeb ? 'sitecsa_default.db' : '$dir/sitecsa_default.db';
  db = PowerSyncDatabase(schema: schema, path: path);
  await db.initialize();
}

/// Abre (o reutiliza) la DB del usuario específico. Si es el mismo user
/// que la DB actual, no hace nada (reconexión instantánea). Si es un
/// user diferente, cierra la DB anterior y abre la nueva.
Future<void> openDatabaseForUser(String userId) async {
  if (_currentDbUserId == userId) return;

  // Cerrar la DB anterior si existe.
  try {
    await db.disconnect();
    await db.close();
  } catch (_) {}

  final dir = await _getDbDir();
  final path = _dbPathForUser(userId, dir);
  db = PowerSyncDatabase(schema: schema, path: path);
  await db.initialize();
  _currentDbUserId = userId;
}

/// Conecta PowerSync usando la sesión Supabase actual.
Future<void> connectPowerSync() async {
  if (_pendingDisconnect != null) {
    await _pendingDisconnect;
    _pendingDisconnect = null;
  }
  final connector = SupabaseConnector(Supabase.instance.client);
  connector.uploadErrors.listen((error) {
    uploadErrorsController.add(error);
  });
  await db.connect(connector: connector);
}

/// Desconecta PowerSync sin borrar datos locales. La DB del user
/// queda intacta para reconexión rápida la próxima vez.
Future<void> disconnectPowerSync() async {
  final completer = Completer<void>();
  _pendingDisconnect = completer.future;
  try {
    await db.disconnect();
  } finally {
    completer.complete();
  }
}
