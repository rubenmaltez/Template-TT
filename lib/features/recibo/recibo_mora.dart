import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers/db_epoch_provider.dart';
import '../../powersync/db.dart' as ps;

/// Cuotas en mora del contrato (pendiente/parcial pasadas de gracia). Cada fila:
/// cuota_id, periodo, saldo. Ordenadas cronológicamente.
///
/// Misma fórmula canónica que `clientes_list_screen.dart` (invariante de
/// consistencia #10): estado IN ('pendiente','parcial') AND la fecha de
/// vencimiento + diasGracia ya pasó. El saldo es monto + cargos_neto -
/// monto_pagado (lo que falta cobrar de esa cuota).
Future<List<Map<String, dynamic>>> fetchMoraContrato(
    String contratoId, int diasGracia) {
  return ps.db.getAll('''
    SELECT cu.id AS cuota_id, cu.periodo,
           (cu.monto + COALESCE(cu.cargos_neto, 0) - cu.monto_pagado) AS saldo
      FROM cuotas cu
     WHERE cu.contrato_id = ?
       AND cu.estado IN ('pendiente','parcial')
       AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now', '-6 hours')
       AND (cu.monto + COALESCE(cu.cargos_neto, 0) - cu.monto_pagado) > 0.01
     ORDER BY cu.periodo ASC
  ''', [contratoId, diasGracia]);
}

final moraContratoProvider = FutureProvider.family<List<Map<String, dynamic>>,
    ({String contratoId, int diasGracia})>((ref, args) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB
  return fetchMoraContrato(args.contratoId, args.diasGracia);
});
