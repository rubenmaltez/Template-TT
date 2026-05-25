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

/// Conecta PowerSync usando la sesión Supabase actual. Llamar en login.
Future<void> connectPowerSync() async {
  final connector = SupabaseConnector(Supabase.instance.client);
  connector.uploadErrors.listen((error) {
    uploadErrorsController.add(error);
  });
  await db.connect(connector: connector);
}

/// Desconecta PowerSync. Llamar en logout.
Future<void> disconnectPowerSync() async {
  await db.disconnect();
}
