import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/logo_empresa_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../recibo/recibo_screen.dart' show ReciboTicket;

/// Vista previa EN VIVO del recibo en la tab Recibos de settings (#8a).
///
/// Renderiza el MISMO widget `ReciboTicket` que ve el cobrador, con datos de
/// EJEMPLO, y se actualiza al instante cuando el admin cambia cualquier ajuste
/// del recibo (título, logo, monto en letras, pie, WhatsApp, ancho, etc.).
/// Así el "diseñador" es visual: el admin ve lo que configura sin imprimir.
class ReciboPreview extends ConsumerWidget {
  const ReciboPreview({super.key});

  /// Ancho en píxeles para simular la tira térmica (80mm≈300, 57mm≈215).
  static double _previewWidthPx(int formatoMm) => formatoMm == 57 ? 215 : 300;

  /// Fila de ejemplo con TODOS los campos que lee `ReciboTicket`. Cobro en
  /// efectivo de una cuota mensual, sin vuelto. Datos ficticios.
  Map<String, dynamic> _sampleRow() {
    final ahora = DateTime.now();
    final periodo = DateTime(ahora.year, ahora.month, 1);
    return {
      'numero_completo': 'A-000123',
      'reimpresiones': 0,
      'impreso_en': null,
      'monto_cordobas': 500.0,
      'vuelto_cordobas': 0.0,
      'moneda': 'NIO',
      'monto_original': 500.0,
      'tasa_conversion': 1.0,
      'metodo': 'efectivo',
      'referencia': null,
      'fecha_pago': ahora.toIso8601String(),
      'periodo': periodo.toIso8601String(),
      'cuota_monto': 500.0,
      'monto_pagado_cuota': 500.0,
      'cargos_neto': 0.0,
      'dia_pago': 15,
      'cliente_nombre': 'Cliente de Ejemplo',
      'cliente_cedula': '001-010190-0001A',
      'plan_nombre': 'Plan Hogar 10 Mbps',
      'cuota_descripcion': null,
      'cobrador_nombre': 'Cobrador de Ejemplo',
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    // Logo reactivo: una sola fuente de verdad, la visibilidad del bloque
    // `logo` del layout. Si está visible y hay logo configurado, se muestra
    // el real; si no, null (igual que en el recibo real).
    final logoVisible =
        settings.reciboLayout.any((b) => b.id == 'logo' && b.visible);
    final logoUrl =
        logoVisible ? ref.watch(logoEmpresaUrlProvider).valueOrNull : null;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.visibility, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Vista previa',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${settings.formatoReciboMm}mm',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Datos de ejemplo — se actualiza al instante con tus cambios.',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            const SizedBox(height: 12),
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: _previewWidthPx(settings.formatoReciboMm),
                ),
                child: ReciboTicket(
                  row: _sampleRow(),
                  settings: settings,
                  logoUrl: logoUrl,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
