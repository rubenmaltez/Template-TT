import '../../powersync/db.dart' as ps;

/// Data del DESGLOSE de descuentos/cargos del recibo (rediseño 2026-06-11):
/// el bloque `cuota` muestra una línea por cada cargo_extra vigente de la(s)
/// cuota(s) cobrada(s), para que el cliente vea POR QUÉ el saldo es el que
/// es (antes los descuentos eran invisibles: solo cambiaba el neto).
///
/// Mismo patrón que `fetchMoraContrato`: los renderers (ticket/PDF) son
/// puros — el call-site busca la data y la pasa hecha. 100% offline.
Future<List<Map<String, dynamic>>> fetchCargosCuotas(
    List<String> cuotaIds) async {
  if (cuotaIds.isEmpty) return const [];
  final placeholders = List.filled(cuotaIds.length, '?').join(',');
  return ps.db.getAll(
    '''
    SELECT cuota_id, tipo, monto, porcentaje, descripcion, origen, aplicado_en
      FROM cargos_extra
     WHERE cuota_id IN ($placeholders)
     ORDER BY aplicado_en ASC
    ''',
    cuotaIds,
  );
}

/// Etiqueta de una línea de cargo en el recibo. Con [conMotivo] apagado
/// queda solo la semántica (Ajuste / Promo / Descuento / Reconexión /
/// Cargo); encendido se agrega el motivo, evitando redundancia en los
/// automáticos cuyo motivo ya ES la etiqueta.
String cargoEtiquetaRecibo(Map<String, dynamic> c, {required bool conMotivo}) {
  final tipo = c['tipo'] as String? ?? '';
  final origen = c['origen'] as String? ?? 'cobro';
  final motivo = (c['descripcion'] as String?)?.trim() ?? '';
  // Puente del cambio de fecha de pago (feature C): etiqueta fija y
  // autoexplicada (el motivo guardado es verboso → sería redundante repetirlo).
  if (origen == 'puente') return 'Puente de pago';
  final esDescuento = tipo.startsWith('descuento');
  final etiqueta = !esDescuento
      ? (tipo == 'reconexion' ? 'Reconexión' : 'Cargo')
      : switch (origen) {
          'ajuste' => 'Ajuste',
          'promo' => 'Promo',
          _ => 'Descuento',
        };
  if (!conMotivo || motivo.isEmpty) return etiqueta;
  // Los automáticos del cobro se explican solos ("Descuento pronto pago",
  // "Cargo por reconexión") — repetir la etiqueta sería ruido.
  if (motivo == 'Descuento pronto pago' || motivo == 'Cargo por reconexión') {
    return motivo;
  }
  return '$etiqueta: $motivo';
}
