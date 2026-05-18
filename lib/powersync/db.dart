import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'connector.dart';
import 'schema.dart';

/// Singleton de la base PowerSync. Inicializar con [openDatabase] en `main`.
late final PowerSyncDatabase db;

/// Abre el SQLite local. Llamar UNA vez al arrancar la app.
Future<void> openDatabase() async {
  // En web, PowerSync usa OPFS/IndexedDB y solo necesita un nombre.
  // En nativo, necesita una ruta absoluta dentro de un directorio de la app.
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
  await db.connect(
    connector: SupabaseConnector(Supabase.instance.client),
  );
}

/// Desconecta PowerSync. Llamar en logout.
Future<void> disconnectPowerSync() async {
  await db.disconnect();
}

/// Desconecta y limpia toda la data local. Llamar al cerrar sesión para
/// que el próximo usuario no vea la fila de cobradores ni los datos
/// operativos del anterior cacheados en SQLite hasta que sincronice.
///
/// PowerSync drop también descarta los uploads pendientes — para un app
/// multi-usuario en mismo dispositivo es el comportamiento correcto
/// (los pending writes pertenecen al user que se acaba de desloguear).
Future<void> disconnectAndClearPowerSync() async {
  await db.disconnectAndClear();
}
