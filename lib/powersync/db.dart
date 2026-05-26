import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'connector.dart';
import 'schema.dart';

/// Singleton de la base PowerSync. Inicializar con [openDatabase] en `main`.
late final PowerSyncDatabase db;

/// Stream global de errores de CRUD upload. Se re-emite cada vez que
/// el connector detecta un error no-retryable (constraint, trigger, RLS).
/// Los shells lo escuchan para mostrar SnackBars al user.
final uploadErrorsController = StreamController<CrudUploadError>.broadcast();

/// Abre el SQLite local. Llamar UNA vez al arrancar la app.
Future<void> openDatabase() async {
  final String path;
  if (kIsWeb) {
    path = 'isp_billing.db';
  } else {
    final dir = await getApplicationSupportDirectory();
    path = '${dir.path}/isp_billing.db';
  }
  db = PowerSyncDatabase(schema: schema, path: path);
  await db.initialize();
}

/// Lock para serializar disconnect/connect y evitar race conditions
/// cuando signedOut y signedIn llegan en rápida sucesión.
Future<void>? _pendingDisconnect;

/// Conecta PowerSync usando la sesión Supabase actual. Llamar en login.
Future<void> connectPowerSync() async {
  // Esperar a que cualquier disconnect en vuelo termine antes de conectar.
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

/// Desconecta y limpia la DB local. Llamar en logout.
/// disconnectAndClear() elimina datos locales + cola CRUD pendiente,
/// evitando que escrituras del usuario anterior bloqueen el checkpoint
/// del nuevo usuario.
Future<void> disconnectPowerSync() async {
  final completer = Completer<void>();
  _pendingDisconnect = completer.future;
  try {
    await db.disconnectAndClear();
  } finally {
    completer.complete();
  }
}
