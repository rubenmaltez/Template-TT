import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import '../repositories/settings_repo.dart';
import 'db_epoch_provider.dart';

/// Providers de los KPIs del dashboard admin (R10).
///
/// Antes los KPIs vivían en `StreamBuilder` directos dentro del dashboard
/// screen, lo cual disparaba una re-subscripción al stream en cada rebuild
/// del padre (porque `ps.db.watch(...)` retorna una nueva instancia de
/// Stream en cada llamada). Eso causaba flashes de loading e queries
/// duplicadas en SQLite.
///
/// Acá los pasamos a `StreamProvider`: Riverpod cachea el stream por
/// identidad del provider, así que no importa cuántas veces rebuildee el
/// dashboard — el stream se subscribe una sola vez y los watchers leen
/// del cache.
///
/// Los providers que dependen de settings usan `select((s) => s.X)` para
/// invalidarse sólo cuando el campo específico cambia (no en cualquier
/// update del mapa global de settings).
///
/// Fechas: se computan dentro del factory del provider y quedan
/// efectivamente fijas hasta que el provider se invalida o la app
/// reinicia. El cambio de día sin reload manual deja stats un día atrás
/// — edge case aceptado, fuera de scope de R10.

class CobrosKpis {
  const CobrosKpis({
    required this.hoy,
    required this.semana,
    required this.mes,
    required this.qtyHoy,
    required this.qtySemana,
    required this.qtyMes,
  });
  final num hoy;
  final num semana;
  final num mes;
  final int qtyHoy;
  final int qtySemana;
  final int qtyMes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CobrosKpis &&
          other.hoy == hoy &&
          other.semana == semana &&
          other.mes == mes &&
          other.qtyHoy == qtyHoy &&
          other.qtySemana == qtySemana &&
          other.qtyMes == qtyMes;

  @override
  int get hashCode =>
      Object.hash(hoy, semana, mes, qtyHoy, qtySemana, qtyMes);
}

class OperativoKpis {
  const OperativoKpis({
    required this.clientes,
    required this.cuotasPend,
    required this.saldo,
    required this.vencidas,
    required this.saldoVencido,
  });
  final int clientes;
  final int cuotasPend;
  final num saldo;
  final int vencidas;
  final num saldoVencido;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OperativoKpis &&
          other.clientes == clientes &&
          other.cuotasPend == cuotasPend &&
          other.saldo == saldo &&
          other.vencidas == vencidas &&
          other.saldoVencido == saldoVencido;

  @override
  int get hashCode =>
      Object.hash(clientes, cuotasPend, saldo, vencidas, saldoVencido);
}

class TopCobrador {
  const TopCobrador({
    required this.id,
    required this.nombre,
    required this.total,
    required this.qty,
  });
  final String id;
  final String nombre;
  final num total;
  final int qty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TopCobrador &&
          other.id == id &&
          other.nombre == nombre &&
          other.total == total &&
          other.qty == qty;

  @override
  int get hashCode => Object.hash(id, nombre, total, qty);
}

class DistribucionCuotas {
  const DistribucionCuotas({
    required this.alDia,
    required this.parcial,
    required this.enGracia,
    required this.vencida,
    required this.pagada,
  });
  final int alDia;
  final int parcial;
  final int enGracia;
  final int vencida;
  final int pagada;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DistribucionCuotas &&
          other.alDia == alDia &&
          other.parcial == parcial &&
          other.enGracia == enGracia &&
          other.vencida == vencida &&
          other.pagada == pagada;

  @override
  int get hashCode =>
      Object.hash(alDia, parcial, enGracia, vencida, pagada);
}

({String hoy, String inicioSemana, String inicioMes}) _dashboardDates() {
  final now = DateTime.now();
  final hoy = DateTime(now.year, now.month, now.day)
      .toIso8601String()
      .substring(0, 10);
  final inicioMes =
      DateTime(now.year, now.month, 1).toIso8601String().substring(0, 10);
  final inicioSemana = DateTime(now.year, now.month, now.day)
      .subtract(Duration(days: now.weekday - 1))
      .toIso8601String()
      .substring(0, 10);
  return (hoy: hoy, inicioSemana: inicioSemana, inicioMes: inicioMes);
}

final cobrosKpisProvider = StreamProvider<CobrosKpis>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  final d = _dashboardDates();
  return ps.db.watch(
    '''
    SELECT
      COALESCE(SUM(CASE WHEN date(fecha_pago) = ?            THEN monto_cordobas ELSE 0 END), 0) AS hoy,
      COALESCE(SUM(CASE WHEN date(fecha_pago) >= ?           THEN monto_cordobas ELSE 0 END), 0) AS semana,
      COALESCE(SUM(CASE WHEN date(fecha_pago) >= ?           THEN monto_cordobas ELSE 0 END), 0) AS mes,
      COUNT(CASE WHEN date(fecha_pago) = ?  THEN 1 END) AS qty_hoy,
      COUNT(CASE WHEN date(fecha_pago) >= ? THEN 1 END) AS qty_semana,
      COUNT(CASE WHEN date(fecha_pago) >= ? THEN 1 END) AS qty_mes
      FROM pagos
     WHERE anulado = 0
    ''',
    parameters: [
      d.hoy,
      d.inicioSemana,
      d.inicioMes,
      d.hoy,
      d.inicioSemana,
      d.inicioMes,
    ],
  ).map((rows) {
    final r = rows.first;
    return CobrosKpis(
      hoy: r['hoy'] as num,
      semana: r['semana'] as num,
      mes: r['mes'] as num,
      qtyHoy: (r['qty_hoy'] as num).toInt(),
      qtySemana: (r['qty_semana'] as num).toInt(),
      qtyMes: (r['qty_mes'] as num).toInt(),
    );
  });
});

final operativoKpisProvider = StreamProvider<OperativoKpis>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  final diasGracia =
      ref.watch(appSettingsProvider.select((s) => s.diasGracia));
  return ps.db.watch(
    '''
    SELECT
      (SELECT COUNT(*) FROM clientes WHERE activo = 1) AS clientes,
      (SELECT COUNT(*) FROM cuotas
         WHERE estado IN ('pendiente','parcial')) AS cuotas_pend,
      (SELECT COALESCE(SUM(monto + COALESCE(cargos_neto, 0) - monto_pagado), 0)
         FROM cuotas WHERE estado IN ('pendiente','parcial')) AS saldo,
      (SELECT COUNT(*) FROM cuotas
         WHERE estado IN ('pendiente','parcial')
           AND date(fecha_vencimiento, '+' || ? || ' days') < date('now')
      ) AS vencidas,
      (SELECT COALESCE(SUM(monto + COALESCE(cargos_neto, 0) - monto_pagado), 0)
         FROM cuotas
         WHERE estado IN ('pendiente','parcial')
           AND date(fecha_vencimiento, '+' || ? || ' days') < date('now')
      ) AS saldo_vencido
    ''',
    parameters: [diasGracia, diasGracia],
  ).map((rows) {
    final r = rows.first;
    return OperativoKpis(
      clientes: (r['clientes'] as num).toInt(),
      cuotasPend: (r['cuotas_pend'] as num).toInt(),
      saldo: r['saldo'] as num,
      vencidas: (r['vencidas'] as num).toInt(),
      saldoVencido: r['saldo_vencido'] as num,
    );
  });
});

final topCobradoresProvider = StreamProvider<List<TopCobrador>>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  final d = _dashboardDates();
  return ps.db.watch(
    '''
    SELECT co.id, co.nombre,
           COALESCE(SUM(p.monto_cordobas), 0) AS total,
           COUNT(p.id) AS qty
      FROM cobradores co
 LEFT JOIN pagos p ON p.cobrador_id = co.id
                  AND p.anulado = 0
                  AND date(p.fecha_pago) >= ?
     WHERE co.activo = 1 AND co.rol = 'cobrador'
     GROUP BY co.id, co.nombre
     ORDER BY total DESC
     LIMIT 5
    ''',
    parameters: [d.inicioMes],
  ).map((rows) => rows
      .map((r) => TopCobrador(
            id: r['id'] as String,
            // `nombre` debería ser NOT NULL en schema, pero defensivo
            // por si algún row legacy llegó null desde otro dispositivo.
            nombre: (r['nombre'] as String?) ?? '',
            total: r['total'] as num,
            qty: (r['qty'] as num).toInt(),
          ))
      .toList());
});

final distribucionCuotasProvider = StreamProvider<DistribucionCuotas>((ref) {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  final diasGracia =
      ref.watch(appSettingsProvider.select((s) => s.diasGracia));
  return ps.db.watch(
    '''
    SELECT
      COUNT(CASE WHEN estado = 'pagada' THEN 1 END) AS pagada,
      COUNT(CASE WHEN estado = 'parcial' THEN 1 END) AS parcial,
      COUNT(CASE WHEN estado = 'pendiente'
                AND fecha_vencimiento >= date('now') THEN 1 END) AS al_dia,
      COUNT(CASE WHEN estado IN ('pendiente','parcial')
                AND fecha_vencimiento < date('now')
                AND date(fecha_vencimiento, '+' || ? || ' days') >= date('now')
           THEN 1 END) AS en_gracia,
      COUNT(CASE WHEN estado IN ('pendiente','parcial')
                AND date(fecha_vencimiento, '+' || ? || ' days') < date('now')
           THEN 1 END) AS vencida
      FROM cuotas
     WHERE estado != 'anulada'
    ''',
    parameters: [diasGracia, diasGracia],
  ).map((rows) {
    final r = rows.first;
    return DistribucionCuotas(
      alDia: (r['al_dia'] as num).toInt(),
      parcial: (r['parcial'] as num).toInt(),
      enGracia: (r['en_gracia'] as num).toInt(),
      vencida: (r['vencida'] as num).toInt(),
      pagada: (r['pagada'] as num).toInt(),
    );
  });
});
