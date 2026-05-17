import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'connector.dart';
import 'schema.dart';

/// Singleton de la base PowerSync. Inicializar con [openDatabase] en `main`.
late final PowerSyncDatabase db;

/// Abre el SQLite local. Llamar UNA vez al arrancar la app.
Future<void> openDatabase() async {
  final dir = await getApplicationSupportDirectory();
  final path = '${dir.path}${Platform.pathSeparator}isp_billing.db';
  db = PowerSyncDatabase(schema: schema, path: path);
  await db.initialize();
}

/// Conecta PowerSync usando la sesión Supabase actual. Llamar en login.
Future<void> connectPowerSync() async {
  await db.connect(
    connector: SupabaseConnector(Supabase.instance.client),
  );
}

/// Desconecta PowerSync. Llamar en logout.
Future<void> disconnectPowerSync() async {
  await db.disconnect();
}
