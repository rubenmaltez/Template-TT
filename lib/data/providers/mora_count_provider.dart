import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;

/// Count de notificaciones de mora sin ver para el cobrador actual.
/// Usado para el Badge en el sidebar del cobrador.
final moraCountProvider = StreamProvider<int>((ref) async* {
  yield* ps.db
      .watch('''
        SELECT COUNT(*) AS cnt FROM notificaciones_mora
        WHERE resuelta_en IS NULL AND vista_en IS NULL
      ''')
      .map((rows) => rows.isEmpty ? 0 : (rows.first['cnt'] as int? ?? 0));
});
