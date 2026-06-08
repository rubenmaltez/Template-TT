import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import 'db_epoch_provider.dart';

/// Cuenta de productos por debajo de su stock mínimo (>0) — alimenta el badge del
/// item "Inventario" del menú admin. El stock se deriva del ledger igual que la
/// tab de Existencias (serializado = COUNT de seriales en_stock; granel = Σdestino
/// − Σorigen). Derivado/offline; recomputa cuando cambian productos/seriales/
/// movimientos (no necesita ticker: el stock cambia por data, no por tiempo).
final inventarioStockBajoCountProvider = StreamProvider.autoDispose<int>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (per-user)
  return ps.db
      .watch('''
        SELECT COUNT(*) AS n FROM (
          SELECT p.stock_minimo AS smin,
                 CASE WHEN p.es_serializado = 1 THEN
                   COALESCE((SELECT COUNT(*) FROM inv_seriales s
                              WHERE s.producto_id = p.id AND s.estado = 'en_stock'), 0)
                 ELSE
                   COALESCE((SELECT SUM(CASE WHEN m.ubicacion_destino_id IS NOT NULL THEN m.cantidad ELSE 0 END)
                                  - SUM(CASE WHEN m.ubicacion_origen_id IS NOT NULL THEN m.cantidad ELSE 0 END)
                               FROM inv_movimientos m WHERE m.producto_id = p.id), 0)
                 END AS stock
            FROM inv_productos p WHERE p.activo = 1
        ) WHERE smin > 0 AND stock < smin
      ''')
      .map((rows) => rows.isEmpty ? 0 : (rows.first['n'] as int? ?? 0));
});
