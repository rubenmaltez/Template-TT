import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';

import '../../powersync/db.dart' as ps;

/// Stream del estado de sync de PowerSync. Se actualiza en cada cambio
/// (conexión, descarga, subida, último timestamp).
final syncStatusProvider = StreamProvider<SyncStatus?>((ref) async* {
  yield ps.db.currentStatus;
  yield* ps.db.statusStream;
});
