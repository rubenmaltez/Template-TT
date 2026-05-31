import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import '../models/cuota.dart';
import '../providers/db_epoch_provider.dart';

class CuotasRepo {
  const CuotasRepo();

  Stream<List<Cuota>> watchCobrables() {
    return ps.db
        .watch(
          '''
          SELECT * FROM cuotas
           WHERE estado IN ('pendiente','parcial')
           ORDER BY fecha_vencimiento ASC
          ''',
        )
        .map((rows) => rows.map(Cuota.fromRow).toList());
  }

  Future<Cuota?> getById(String id) async {
    final rows = await ps.db.getAll('SELECT * FROM cuotas WHERE id = ?', [id]);
    return rows.isEmpty ? null : Cuota.fromRow(rows.first);
  }

  /// Calcula total a cobrar de una cuota considerando cargos extra
  /// (descuentos restan, reconexión/otro suman). Mirror del SQL.
  Future<double> totalACobrar(String cuotaId) async {
    final cuota = await getById(cuotaId);
    if (cuota == null) return 0;
    final rows = await ps.db.getAll(
      '''
      SELECT tipo, SUM(monto) AS total
        FROM cargos_extra
       WHERE cuota_id = ?
       GROUP BY tipo
      ''',
      [cuotaId],
    );
    var total = cuota.monto;
    for (final r in rows) {
      final tipo = r['tipo'] as String;
      final monto = (r['total'] as num).toDouble();
      if (tipo == 'descuento_monto' || tipo == 'descuento_porcentaje') {
        total -= monto;
      } else if (tipo == 'reconexion' || tipo == 'otro') {
        total += monto;
      }
    }
    return total < 0 ? 0 : total;
  }
}

final cuotasRepoProvider = Provider((_) => const CuotasRepo());

final cuotasCobrablesProvider = StreamProvider<List<Cuota>>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  return ref.watch(cuotasRepoProvider).watchCobrables();
});
