import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import '../models/cuota.dart';
import '../utils/cuota_estado.dart';

class CuotasRepo {
  /// [db] permite inyectar una `PowerSyncDatabase` para tests (mismo patrón
  /// que PagosRepo). En producción queda null y usa la global `ps.db`.
  CuotasRepo({PowerSyncDatabase? db}) : _db = db;
  final PowerSyncDatabase? _db;
  PowerSyncDatabase get _dbOrGlobal => _db ?? ps.db;

  Future<Cuota?> getById(String id) async {
    final rows =
        await _dbOrGlobal.getAll('SELECT * FROM cuotas WHERE id = ?', [id]);
    return rows.isEmpty ? null : Cuota.fromRow(rows.first);
  }

  /// Calcula total a cobrar de una cuota considerando cargos extra
  /// (descuentos restan, reconexión/otro suman). Mirror del SQL.
  Future<double> totalACobrar(String cuotaId) async {
    final cuota = await getById(cuotaId);
    if (cuota == null) return 0;
    final rows = await _dbOrGlobal.getAll(
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

  // ─────────────────────────────────────────────────────────────────────
  // DESCUENTOS del admin: AJUSTES y PROMOS (Sprint 2 0115 + rediseño
  // 2026-06-11: las promos van por el MISMO riel con origen='promo' —
  // misma mecánica, etiqueta distinta en historial/recibo/reportes).
  // Principio rector: un descuento es una fila de cargos_extra — NUNCA se
  // muta cuotas.monto. Capas de validación: acá lo básico offline-first
  // (motivo/valor/estado/saldo); los TOPES del súper viven en el dialog
  // (feedback inmediato) y en el guard server trg_cargos_ajuste_guard
  // (el control REAL: habilitado + rol + motivo + tipo + topes; cubre
  // 'ajuste' y 'promo' desde 0117).
  // ─────────────────────────────────────────────────────────────────────

  /// Aplica un descuento de admin (ajuste o promo, con motivo) a una cuota
  /// pendiente/parcial. [valor] es % (0-100] si [esPorcentaje], o C$ si no.
  Future<void> aplicarAjuste({
    required String tenantId,
    required String cuotaId,
    required bool esPorcentaje,
    required double valor,
    required String motivo,
    required String aplicadoPorId,
    String origen = 'ajuste',
  }) async {
    if (origen != 'ajuste' && origen != 'promo') {
      throw Exception('Origen inválido: solo ajuste o promo.');
    }
    if (motivo.trim().isEmpty) {
      throw Exception('El ajuste requiere un motivo.');
    }
    if (valor <= 0) {
      throw Exception('El valor del ajuste debe ser mayor a cero.');
    }
    if (esPorcentaje && valor > 100) {
      throw Exception('El porcentaje no puede exceder 100.');
    }

    // Hora REAL del dispositivo (UTC) para el change log — offline-first.
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    await _dbOrGlobal.writeTransaction((tx) async {
      final rows = await tx.getAll(
        '''
        SELECT monto, monto_pagado, cargos_neto, estado, cobrador_id
          FROM cuotas WHERE id = ?
        ''',
        [cuotaId],
      );
      if (rows.isEmpty) throw Exception('Cuota no encontrada.');
      final r = rows.first;
      final estado = r['estado'] as String? ?? '';
      if (estado != 'pendiente' && estado != 'parcial') {
        throw Exception('Solo se ajustan cuotas pendientes o parciales.');
      }
      final montoCuota = (r['monto'] as num).toDouble();
      final cargosNeto = (r['cargos_neto'] as num?)?.toDouble() ?? 0.0;
      final pagado = (r['monto_pagado'] as num?)?.toDouble() ?? 0.0;
      final saldo = montoCuota + cargosNeto - pagado;

      final monto = esPorcentaje ? montoCuota * valor / 100 : valor;
      if (monto > saldo + 0.01) {
        throw Exception(
          'El ajuste no puede exceder el saldo de la cuota '
          '(${saldo.toStringAsFixed(2)}).',
        );
      }

      await tx.execute(
        '''
        INSERT INTO cargos_extra (
          id, tenant_id, cuota_id, cobrador_id, tipo, monto, porcentaje,
          descripcion, aplicado_por, aplicado_en, client_local_id, ocurrido_en,
          origen
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          const Uuid().v4(),
          tenantId,
          cuotaId,
          // Denormalizado para las sync rules del cobrador (mismo patrón que
          // todo INSERT de cargos): el cargo viaja en el bucket de la cuota.
          (r['cobrador_id'] as String?) ?? aplicadoPorId,
          esPorcentaje ? 'descuento_porcentaje' : 'descuento_monto',
          monto,
          esPorcentaje ? valor : null,
          motivo.trim(),
          aplicadoPorId,
          ocurridoEn,
          const Uuid().v4(),
          ocurridoEn,
          origen,
        ],
      );
      await _recalcularCuotaLocal(tx, cuotaId, ocurridoEn: ocurridoEn);
    });
  }

  /// Descuentos de admin (ajustes y promos) aplicados a una cuota (más
  /// nuevo primero), con el origen y el nombre de quién lo aplicó.
  Future<List<Map<String, dynamic>>> ajustesDeCuota(String cuotaId) {
    return _dbOrGlobal.getAll(
      '''
      SELECT ce.id, ce.tipo, ce.monto, ce.porcentaje, ce.descripcion,
             ce.origen, ce.ocurrido_en, ce.aplicado_en,
             co.nombre AS aplicado_por_nombre
        FROM cargos_extra ce
   LEFT JOIN cobradores co ON co.id = ce.aplicado_por
       WHERE ce.cuota_id = ? AND ce.origen IN ('ajuste', 'promo')
       ORDER BY COALESCE(ce.ocurrido_en, ce.aplicado_en) DESC
      ''',
      [cuotaId],
    );
  }

  /// Revierte un ajuste/promo: DELETE físico del cargo. El rastro queda en
  /// el change log (el agregador de la cuota lee el \$.cuota_id del snapshot
  /// — fix M22). Server: trg_cargos_extra_actualizar_neto + recalcular_cuota
  /// rehacen neto/estado; acá los espejamos.
  Future<void> quitarAjuste({required String cargoId}) async {
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    await _dbOrGlobal.writeTransaction((tx) async {
      final rows = await tx.getAll(
        "SELECT cuota_id FROM cargos_extra WHERE id = ? AND origen IN ('ajuste', 'promo')",
        [cargoId],
      );
      if (rows.isEmpty) return; // ya quitado: no-op idempotente
      final cuotaId = rows.first['cuota_id'] as String;
      await tx.execute('DELETE FROM cargos_extra WHERE id = ?', [cargoId]);
      await _recalcularCuotaLocal(tx, cuotaId, ocurridoEn: ocurridoEn);
    });
  }

  /// Mirror local de los triggers server (0023 neto + 0083 estado) tras
  /// insertar/borrar cargos — mismo cálculo que AplicarCargoDialog y
  /// PagosRepo._deltaCargosExtra.
  Future<void> _recalcularCuotaLocal(
    // `dynamic` como en PagosRepo._deltaCargosExtra: el contexto de la tx.
    dynamic tx,
    String cuotaId, {
    required String ocurridoEn,
  }) async {
    final cuotaInfo = await tx.getAll(
      'SELECT monto, monto_pagado, estado FROM cuotas WHERE id = ?',
      [cuotaId],
    );
    if (cuotaInfo.isEmpty) return;
    final montoCuota = (cuotaInfo.first['monto'] as num).toDouble();
    final pagado = (cuotaInfo.first['monto_pagado'] as num?)?.toDouble() ?? 0.0;
    final estadoActual = cuotaInfo.first['estado'] as String? ?? 'pendiente';
    final deltaRows = await tx.getAll(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN tipo IN ('reconexion','otro')
                          THEN monto ELSE 0 END), 0) AS sumar,
        COALESCE(SUM(CASE WHEN tipo IN ('descuento_monto','descuento_porcentaje')
                          THEN monto ELSE 0 END), 0) AS restar
        FROM cargos_extra WHERE cuota_id = ?
      ''',
      [cuotaId],
    );
    final delta = (deltaRows.first['sumar'] as num).toDouble() -
        (deltaRows.first['restar'] as num).toDouble();
    final nuevoEstado = calcularEstadoCuota(
      estadoActual: estadoActual,
      montoCuota: montoCuota,
      pagadoNuevo: pagado,
      deltaCargosExtra: delta,
    );
    await tx.execute(
      'UPDATE cuotas SET cargos_neto = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
      [delta, nuevoEstado, ocurridoEn, cuotaId],
    );
  }
}

final cuotasRepoProvider = Provider((_) => CuotasRepo());
