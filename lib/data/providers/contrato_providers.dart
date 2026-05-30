import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;

/// Providers del detalle de contrato (`ContratoDetailScreen`).
///
/// Antes los 4 streams (`contrato`, `cuotas`, `pagos`, `resumen`) vivían como
/// `late Stream` dentro del `State` de la pantalla, creados en `initState` con
/// `ps.db.watch(...)`. PowerSync cachea sus streams por query+params, así que
/// `watch(mismo SQL, mismos params)` devuelve la MISMA instancia de stream. Un
/// stream single-subscription sostenido en State, al re-entrar a la pantalla,
/// se re-subscribía sobre un stream ya cancelado → "Stream has already been
/// listened to" / la sección de pagos quedaba vacía.
///
/// La solución idiomática es `StreamProvider.autoDispose.family`: Riverpod
/// maneja UNA subscripción interna, cachea el último `AsyncValue` (replay para
/// nuevos watchers) y `autoDispose` limpia la subscripción al salir de la
/// pantalla, así re-entrar arranca limpio. Mismo patrón que
/// `dashboard_providers.dart`.
///
/// Los providers devuelven las filas crudas (`List<Map<String, dynamic>>`) —
/// los widgets leen los maps directamente, sin mapear a modelos.

final contratoDetalleProvider = StreamProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contratoId) {
  return ps.db.watch(
    '''
    SELECT ct.id, ct.tenant_id, ct.dia_pago, ct.fecha_inicio, ct.fecha_fin,
           ct.estado, ct.cliente_id, ct.cobrador_id,
           ct.documento_path, ct.duracion_meses,
           p.nombre AS plan_nombre, p.precio_mensual,
           c.nombre AS cliente_nombre
      FROM contratos ct
      JOIN planes  p ON p.id = ct.plan_id
      JOIN clientes c ON c.id = ct.cliente_id
     WHERE ct.id = ?
     LIMIT 1
    ''',
    parameters: [contratoId],
  );
});

final contratoCuotasProvider = StreamProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contratoId) {
  return ps.db.watch(
    '''
    SELECT cu.id, cu.monto, cu.monto_pagado, cu.fecha_vencimiento,
           cu.periodo, cu.estado, cu.contrato_id,
           cu.descripcion, cu.tipo_cargo_manual, ct.dia_pago
      FROM cuotas cu
      LEFT JOIN contratos ct ON ct.id = cu.contrato_id
     WHERE cu.contrato_id = ?
     ORDER BY cu.periodo ASC
    ''',
    parameters: [contratoId],
  );
});

final contratoPagosProvider = StreamProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contratoId) {
  return ps.db.watch(
    '''
    SELECT pa.id, pa.tenant_id, pa.cuota_id, pa.cobrador_id,
           pa.monto_cordobas, pa.vuelto_cordobas, pa.moneda,
           pa.monto_original, pa.tasa_conversion, pa.metodo,
           pa.referencia, pa.foto_comprobante_path,
           pa.lat, pa.lng, pa.notas, pa.fecha_pago,
           pa.anulado, pa.anulado_en, pa.anulado_por,
           pa.motivo_anulacion, pa.grupo_cobro, pa.client_local_id,
           cu.periodo, cu.tipo_cargo_manual, ct.dia_pago
      FROM pagos pa
      INNER JOIN cuotas cu ON cu.id = pa.cuota_id
      LEFT JOIN contratos ct ON ct.id = cu.contrato_id
     WHERE cu.contrato_id = ?
     ORDER BY pa.fecha_pago DESC
     LIMIT 20
    ''',
    parameters: [contratoId],
  );
});

// Resumen: SUM(monto_pagado) de pagos NO anulados del contrato.
// Incluye pagos a cuotas regulares Y a cargos manuales del mismo contrato.
final contratoRecaudadoProvider = StreamProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contratoId) {
  return ps.db.watch(
    '''
    SELECT COALESCE(SUM(pa.monto_cordobas), 0) AS recaudado
      FROM pagos pa
      JOIN cuotas cu ON cu.id = pa.cuota_id
     WHERE cu.contrato_id = ?
       AND pa.anulado = 0
    ''',
    parameters: [contratoId],
  );
});
