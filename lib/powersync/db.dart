import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'connector.dart';
import 'schema.dart';

/// Singleton de la base PowerSync. Inicializar con [openDatabase] en `main`.
late final PowerSyncDatabase db;

Future<void> openDatabase() async {
  final dir = await getApplicationSupportDirectory();
  final path = '${dir.path}${Platform.pathSeparator}isp_billing.db';

  db = PowerSyncDatabase(schema: schema, path: path);
  await db.initialize();
  db.connect(connector: SupabaseConnector(Supabase.instance.client));
}
