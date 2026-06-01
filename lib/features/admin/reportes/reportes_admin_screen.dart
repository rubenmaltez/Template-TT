import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../config/router.dart';
import '../../../data/models/pago.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import 'pdf/reporte_anulaciones_pdf.dart';
import 'pdf/reporte_arqueo_pdf.dart';
import 'pdf/reporte_clientes_pdf.dart';
import 'pdf/reporte_cobros_pdf.dart';
import 'pdf/reporte_eficiencia_pdf.dart';
import 'pdf/reporte_fiscal_pdf.dart';
import 'pdf/reporte_inactivos_pdf.dart';
import 'pdf/reporte_mora_pdf.dart';
import 'pdf/reporte_por_cobrador_pdf.dart';

/// Rango de fechas para los reportes DESCARGABLES (#3). Filtra por `fecha_pago`
/// (la "fecha de cobro"). NO afecta las tarjetas analíticas en pantalla —esas
/// siguen mostrando el mes actual—. Default: mes actual.
class RangoReporte {
  const RangoReporte({
    required this.desde,
    required this.hasta,
    required this.label,
  });
  final DateTime desde; // inclusive (date-only)
  final DateTime hasta; // inclusive (date-only)
  final String label;

  String get desdeSql => _d(desde);
  String get hastaSql => _d(hasta);
  String get periodoLabel => '${Fmt.fechaCorta(desde)} – ${Fmt.fechaCorta(hasta)}';
  static String _d(DateTime x) => x.toIso8601String().substring(0, 10);

  static RangoReporte mesActual() {
    final now = DateTime.now();
    return RangoReporte(
      desde: DateTime(now.year, now.month, 1),
      hasta: DateTime(now.year, now.month, now.day),
      label: 'Este mes',
    );
  }

  static RangoReporte mesPasado() {
    final now = DateTime.now();
    final finMesPasado = DateTime(now.year, now.month, 1)
        .subtract(const Duration(days: 1));
    return RangoReporte(
      desde: DateTime(finMesPasado.year, finMesPasado.month, 1),
      hasta: finMesPasado,
      label: 'Mes pasado',
    );
  }

  /// Día de hoy (desde = hasta = hoy). Default del arqueo de caja.
  static RangoReporte hoy() {
    final now = DateTime.now();
    final dia = DateTime(now.year, now.month, now.day);
    return RangoReporte(desde: dia, hasta: dia, label: 'Hoy');
  }

  /// Día de ayer (desde = hasta = ayer). Para cerrar la caja del día previo.
  static RangoReporte ayer() {
    final now = DateTime.now();
    final dia =
        DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
    return RangoReporte(desde: dia, hasta: dia, label: 'Ayer');
  }
}

/// Rango activo para reportes descargables. Default: mes actual.
final reporteRangoProvider =
    StateProvider<RangoReporte>((ref) => RangoReporte.mesActual());

/// Rango propio del arqueo / cierre por cobrador. Default: HOY (el arqueo se
/// hace por día, no por mes). Independiente de [reporteRangoProvider].
final reporteArqueoRangoProvider =
    StateProvider<RangoReporte>((ref) => RangoReporte.hoy());

class ReportesAdminScreen extends ConsumerWidget {
  const ReportesAdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diasGracia = ref.watch(appSettingsProvider).diasGracia;
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const _RangoReportesCard(),
            const SizedBox(height: 16),
            const _ArqueoCajaCard(),
            const SizedBox(height: 16),
            const _RecaudacionMensualCard(),
            const SizedBox(height: 16),
            const _CobradoresMesCard(),
            const SizedBox(height: 16),
            _MoraPorComunidadCard(diasGracia: diasGracia),
            const SizedBox(height: 16),
            const _PlanesPopularesCard(),
            const SizedBox(height: 80),
          ],
        ),
        Positioned(
          right: 24,
          bottom: 24,
          child: _DescargarPdfMenu(diasGracia: diasGracia),
        ),
      ],
    );
  }
}

/// Selector de rango para los reportes descargables (#3). Muestra el rango
/// activo y permite cambiarlo con presets (Este mes / Mes pasado / custom).
/// Deja claro que NO afecta las tarjetas analíticas de abajo.
class _RangoReportesCard extends ConsumerWidget {
  const _RangoReportesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rango = ref.watch(reporteRangoProvider);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.date_range, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Rango de reportes descargables',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 2),
                  Text(
                    '${rango.label} · ${rango.periodoLabel}',
                    style:
                        TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                  Text(
                      'Filtra por fecha de cobro. No afecta las tarjetas de abajo.',
                      style: TextStyle(color: scheme.outline, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _elegirRango(context, ref),
              icon: const Icon(Icons.edit_calendar, size: 18),
              label: const Text('Cambiar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _elegirRango(BuildContext context, WidgetRef ref) async {
    final opcion = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.today),
              title: const Text('Este mes'),
              onTap: () => Navigator.pop(ctx, 'mes'),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Mes pasado'),
              onTap: () => Navigator.pop(ctx, 'pasado'),
            ),
            ListTile(
              leading: const Icon(Icons.date_range),
              title: const Text('Personalizado…'),
              onTap: () => Navigator.pop(ctx, 'custom'),
            ),
          ],
        ),
      ),
    );
    if (opcion == null || !context.mounted) return;
    final notifier = ref.read(reporteRangoProvider.notifier);
    if (opcion == 'mes') {
      notifier.state = RangoReporte.mesActual();
    } else if (opcion == 'pasado') {
      notifier.state = RangoReporte.mesPasado();
    } else if (opcion == 'custom') {
      final now = DateTime.now();
      final actual = ref.read(reporteRangoProvider);
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 5),
        lastDate: now, // sin futuro: "fecha de cobro" no tiene sentido a futuro
        initialDateRange:
            DateTimeRange(start: actual.desde, end: actual.hasta),
      );
      if (picked == null) return;
      notifier.state = RangoReporte(
        desde:
            DateTime(picked.start.year, picked.start.month, picked.start.day),
        hasta: DateTime(picked.end.year, picked.end.month, picked.end.day),
        label: 'Personalizado',
      );
    }
  }
}

/// Card del arqueo / cierre por cobrador. READ-ONLY: lee pagos del rango y
/// genera el PDF de cuadre de caja (efectivo por moneda + electrónico).
/// Tiene rango PROPIO con default HOY (chips Hoy/Ayer/Personalizado…),
/// independiente del rango de los demás reportes.
class _ArqueoCajaCard extends ConsumerWidget {
  const _ArqueoCajaCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rango = ref.watch(reporteArqueoRangoProvider);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.point_of_sale, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Arqueo / cierre por cobrador',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        'Efectivo por moneda (US\$/C\$) + electrónico, para cuadrar caja',
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Selector compacto de rango propio del arqueo.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ChoiceChip(
                  label: const Text('Hoy'),
                  selected: rango.label == 'Hoy',
                  onSelected: (_) => ref
                      .read(reporteArqueoRangoProvider.notifier)
                      .state = RangoReporte.hoy(),
                ),
                ChoiceChip(
                  label: const Text('Ayer'),
                  selected: rango.label == 'Ayer',
                  onSelected: (_) => ref
                      .read(reporteArqueoRangoProvider.notifier)
                      .state = RangoReporte.ayer(),
                ),
                ChoiceChip(
                  label: const Text('Personalizado…'),
                  selected: rango.label == 'Personalizado',
                  onSelected: (_) => _elegirCustom(context, ref),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Rango: ${rango.label} · ${rango.periodoLabel}',
              style: TextStyle(color: scheme.outline, fontSize: 11),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () => _generar(context, ref, rango),
                icon: const Icon(Icons.picture_as_pdf, size: 18),
                label: const Text('Generar PDF'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _elegirCustom(BuildContext context, WidgetRef ref) async {
    final now = DateTime.now();
    final actual = ref.read(reporteArqueoRangoProvider);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now, // sin futuro: la "fecha de cobro" no aplica a futuro
      initialDateRange: DateTimeRange(start: actual.desde, end: actual.hasta),
    );
    if (picked == null) return;
    ref.read(reporteArqueoRangoProvider.notifier).state = RangoReporte(
      desde: DateTime(picked.start.year, picked.start.month, picked.start.day),
      hasta: DateTime(picked.end.year, picked.end.month, picked.end.day),
      label: 'Personalizado',
    );
  }

  Future<void> _generar(
      BuildContext context, WidgetRef ref, RangoReporte rango) async {
    try {
      final empresaNombre =
          ref.read(empresaNombreProvider).valueOrNull ?? 'ISP';
      final tasaActual = ref.read(appSettingsProvider).tasaUsd;
      final rows =
          await ps.db.getAll(_arqueoSql, [rango.desdeSql, rango.hastaSql]);

      final now = DateTime.now();
      final doc = buildReporteArqueo(
        titulo: 'Arqueo / cierre por cobrador',
        empresaNombre: empresaNombre,
        periodo: rango.periodoLabel,
        rows: rows,
        tasaActual: tasaActual,
      );
      await Printing.sharePdf(
        bytes: await doc.save(),
        filename: 'arqueo_${now.year}_${now.month}_${now.day}.pdf',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generando arqueo: $e')),
        );
      }
    }
  }
}

/// Query del arqueo / cierre por cobrador. Una fila por cobrador con los
/// efectivos separados por moneda (US$/C$, montos en `monto_original`), el
/// vuelto total, los electrónicos por método, y el recaudado contable
/// (`monto_cordobas`). Params: [desde, hasta] (date-only, inclusive).
/// SQLite-válida: usa SUM(CASE WHEN…), NO FILTER. Compartida por PDF y CSV.
const String _arqueoSql = '''
  SELECT cb.nombre AS cobrador_nombre,
         COUNT(p.id) AS total_cobros,
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='USD' THEN p.monto_original ELSE 0 END),0) AS efectivo_usd,
         SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='USD' THEN 1 ELSE 0 END) AS efectivo_usd_qty,
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='NIO' THEN p.monto_original ELSE 0 END),0) AS efectivo_nio,
         SUM(CASE WHEN p.metodo='efectivo' AND p.moneda='NIO' THEN 1 ELSE 0 END) AS efectivo_nio_qty,
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' THEN p.vuelto_cordobas ELSE 0 END),0) AS efectivo_vuelto,
         COALESCE(SUM(CASE WHEN p.metodo='efectivo' THEN p.monto_cordobas ELSE 0 END),0) AS efectivo_ingreso,
         COALESCE(SUM(CASE WHEN p.metodo='transferencia' THEN p.monto_cordobas ELSE 0 END),0) AS transferencia,
         SUM(CASE WHEN p.metodo='transferencia' THEN 1 ELSE 0 END) AS transferencia_qty,
         COALESCE(SUM(CASE WHEN p.metodo='deposito' THEN p.monto_cordobas ELSE 0 END),0) AS deposito,
         SUM(CASE WHEN p.metodo='deposito' THEN 1 ELSE 0 END) AS deposito_qty,
         COALESCE(SUM(CASE WHEN p.metodo='tarjeta' THEN p.monto_cordobas ELSE 0 END),0) AS tarjeta,
         SUM(CASE WHEN p.metodo='tarjeta' THEN 1 ELSE 0 END) AS tarjeta_qty,
         COALESCE(SUM(p.monto_cordobas),0) AS ingreso_total
    FROM cobradores cb
    JOIN pagos p ON p.cobrador_id = cb.id AND p.anulado = 0
                AND date(p.fecha_pago) BETWEEN ? AND ?
   GROUP BY cb.id, cb.nombre
   ORDER BY ingreso_total DESC
''';

class _DescargarPdfMenu extends ConsumerWidget {
  const _DescargarPdfMenu({required this.diasGracia});
  final int diasGracia;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      onSelected: (tipo) => _generar(context, ref, tipo),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'cobros',
          child: ListTile(
            leading: Icon(Icons.receipt_long),
            title: Text('Reporte de cobros'),
            subtitle: Text('Cobros del mes actual'),
            dense: true,
          ),
        ),
        PopupMenuItem(
          value: 'mora',
          child: ListTile(
            leading: Icon(Icons.warning_amber),
            title: Text('Reporte de mora'),
            subtitle: Text('Clientes con cuotas vencidas'),
            dense: true,
          ),
        ),
        PopupMenuItem(
          value: 'por_cobrador',
          child: ListTile(
            leading: Icon(Icons.person_search),
            title: Text('Reporte por cobrador'),
            subtitle: Text('Cobros filtrados por cobrador'),
            dense: true,
          ),
        ),
        PopupMenuItem(
          value: 'clientes',
          child: ListTile(
            leading: Icon(Icons.people),
            title: Text('Estado de clientes'),
            subtitle: Text('Saldo pendiente por cliente'),
            dense: true,
          ),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'fiscal',
          child: ListTile(
            leading: Icon(Icons.account_balance),
            title: Text('Reporte fiscal'),
            subtitle: Text('Ingresos por plan y método'),
            dense: true,
          ),
        ),
        PopupMenuItem(
          value: 'eficiencia',
          child: ListTile(
            leading: Icon(Icons.speed),
            title: Text('Eficiencia por cobrador'),
            subtitle: Text('Tasa de éxito y montos'),
            dense: true,
          ),
        ),
        PopupMenuItem(
          value: 'inactivos',
          child: ListTile(
            leading: Icon(Icons.person_off),
            title: Text('Clientes inactivos'),
            subtitle: Text('Sin pagos en los últimos 3 meses'),
            dense: true,
          ),
        ),
        PopupMenuItem(
          value: 'anulaciones',
          child: ListTile(
            leading: Icon(Icons.cancel_outlined),
            title: Text('Reporte de anulaciones'),
            subtitle: Text('Cobros anulados con motivo'),
            dense: true,
          ),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'csv',
          child: ListTile(
            leading: Icon(Icons.table_chart),
            title: Text('Exportar CSV'),
            subtitle: Text('Copiar al portapapeles'),
            dense: true,
          ),
        ),
      ],
      child: FloatingActionButton.extended(
        onPressed: null,
        icon: const Icon(Icons.picture_as_pdf),
        label: const Text('Reportes'),
      ),
    );
  }

  Future<void> _generar(
      BuildContext context, WidgetRef ref, String tipo) async {
    final empresaNombre =
        ref.read(empresaNombreProvider).valueOrNull ?? 'ISP';
    final rango = ref.read(reporteRangoProvider);

    // CSV export abre un sub-menú para elegir qué reporte exportar.
    if (tipo == 'csv') {
      if (!context.mounted) return;
      await _mostrarMenuCsv(context, ref);
      return;
    }

    try {
      if (tipo == 'cobros') {
        final rows = await ps.db.getAll('''
          SELECT p.fecha_pago, c.nombre AS cliente_nombre,
                 p.monto_cordobas AS monto, p.metodo,
                 cb.nombre AS cobrador_nombre,
                 r.numero_completo AS numero_recibo,
                 SUBSTR(p.grupo_cobro, 1, 8) AS ref_grupo
            FROM pagos p
            JOIN cuotas cu ON cu.id = p.cuota_id
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN cobradores cb ON cb.id = p.cobrador_id
       LEFT JOIN recibos r ON r.pago_id = p.id
           WHERE p.anulado = 0
             AND date(p.fecha_pago) BETWEEN ? AND ?
           ORDER BY p.fecha_pago DESC
        ''', [rango.desdeSql, rango.hastaSql]);

        final now = DateTime.now();
        final periodo = rango.periodoLabel;
        final doc = buildReporteCobros(
          titulo: 'Reporte de cobros',
          empresaNombre: empresaNombre,
          periodo: periodo,
          rows: rows,
        );

        await Printing.sharePdf(
          bytes: await doc.save(),
          filename: 'cobros_${now.year}_${now.month}.pdf',
        );
      } else if (tipo == 'mora') {
        final rows = await ps.db.getAll('''
          SELECT c.nombre AS cliente_nombre,
                 co.nombre AS comunidad,
                 COUNT(cu.id) AS cuotas_vencidas,
                 COALESCE(SUM(cu.monto + COALESCE(cu.cargos_neto, 0)
                   - cu.monto_pagado), 0) AS monto_adeudado,
                 CAST(julianday('now') - julianday(MIN(cu.fecha_vencimiento))
                   AS INTEGER) AS dias_mora
            FROM cuotas cu
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN comunidades co ON co.id = c.comunidad_id
           WHERE cu.estado IN ('pendiente','parcial')
             AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                 < date('now')
           GROUP BY c.id, c.nombre, co.nombre
           ORDER BY dias_mora DESC
        ''', [diasGracia]);

        final now = DateTime.now();
        final periodoMora = Fmt.mes(now);

        final doc = buildReporteMora(
          titulo: 'Reporte de mora',
          empresaNombre: empresaNombre,
          periodo: periodoMora,
          rows: rows,
        );
        await Printing.sharePdf(
          bytes: await doc.save(),
          filename: 'mora_${now.year}_${now.month}_${now.day}.pdf',
        );
      } else if (tipo == 'por_cobrador') {
        // Selector de cobrador antes de generar.
        final cobradores = await ps.db.getAll('''
          SELECT id, nombre FROM cobradores
          WHERE activo = 1 AND rol = 'cobrador'
          ORDER BY nombre
        ''');
        if (!context.mounted) return;
        final seleccionado = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Seleccioná un cobrador'),
            children: cobradores.map((c) => SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c),
              child: Text(c['nombre'] as String),
            )).toList(),
          ),
        );
        if (seleccionado == null) return;

        final rows = await ps.db.getAll('''
          SELECT p.fecha_pago, c.nombre AS cliente_nombre,
                 p.monto_cordobas AS monto, p.metodo,
                 r.numero_completo AS numero_recibo
            FROM pagos p
            JOIN cuotas cu ON cu.id = p.cuota_id
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN recibos r ON r.pago_id = p.id
           WHERE p.anulado = 0
             AND p.cobrador_id = ?
             AND date(p.fecha_pago) BETWEEN ? AND ?
           ORDER BY p.fecha_pago DESC
        ''', [seleccionado['id'], rango.desdeSql, rango.hastaSql]);

        final now = DateTime.now();
        final doc = buildReportePorCobrador(
          titulo: 'Reporte por cobrador',
          empresaNombre: empresaNombre,
          periodo: rango.periodoLabel,
          cobradorNombre: seleccionado['nombre'] as String,
          rows: rows,
        );
        await Printing.sharePdf(
          bytes: await doc.save(),
          filename: 'cobrador_${now.year}_${now.month}.pdf',
        );
      } else if (tipo == 'clientes') {
        final rows = await ps.db.getAll('''
          SELECT c.nombre, co.nombre AS comunidad,
                 COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial') THEN 1 ELSE 0 END), 0)
                   AS pendientes,
                 COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                   THEN cu.monto + COALESCE(cu.cargos_neto, 0) - cu.monto_pagado
                   ELSE 0 END), 0) AS saldo,
                 MAX(p.fecha_pago) AS ultimo_pago
            FROM clientes c
       LEFT JOIN comunidades co ON co.id = c.comunidad_id
       LEFT JOIN cuotas cu ON cu.cliente_id = c.id
       LEFT JOIN pagos p ON p.cuota_id = cu.id AND p.anulado = 0
           WHERE c.activo = 1
           GROUP BY c.id, c.nombre, co.nombre
           ORDER BY saldo DESC
        ''');

        final now = DateTime.now();
        final doc = buildReporteClientes(
          titulo: 'Estado de clientes',
          empresaNombre: empresaNombre,
          periodo: Fmt.mes(now),
          rows: rows,
        );
        await Printing.sharePdf(
          bytes: await doc.save(),
          filename: 'clientes_${now.year}_${now.month}.pdf',
        );
      } else if (tipo == 'fiscal') {
        await _generarFiscal(context, empresaNombre, rango);
      } else if (tipo == 'eficiencia') {
        await _generarEficiencia(context, empresaNombre, rango);
      } else if (tipo == 'inactivos') {
        await _generarInactivos(context, empresaNombre);
      } else if (tipo == 'anulaciones') {
        await _generarAnulaciones(context, empresaNombre, rango);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generando reporte: $e')),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // E1: Reporte fiscal — ingresos por mes, plan y método de pago
  // ---------------------------------------------------------------------------

  Future<void> _generarFiscal(
      BuildContext context, String empresaNombre, RangoReporte rango) async {
    final rows = await ps.db.getAll('''
      SELECT strftime('%Y-%m', p.fecha_pago) AS mes,
             COALESCE(pl.nombre, 'Sin plan') AS plan_nombre,
             p.metodo,
             COALESCE(SUM(p.monto_cordobas), 0) AS total_monto,
             COUNT(p.id) AS cantidad
        FROM pagos p
        JOIN cuotas cu ON cu.id = p.cuota_id
   LEFT JOIN contratos ct ON ct.id = cu.contrato_id
   LEFT JOIN planes pl ON pl.id = ct.plan_id
       WHERE p.anulado = 0
         AND date(p.fecha_pago) BETWEEN ? AND ?
       GROUP BY mes, plan_nombre, p.metodo
       ORDER BY mes DESC, plan_nombre, p.metodo
    ''', [rango.desdeSql, rango.hastaSql]);

    final now = DateTime.now();
    final doc = buildReporteFiscal(
      titulo: 'Reporte fiscal / contable',
      empresaNombre: empresaNombre,
      periodo: rango.periodoLabel,
      rows: rows,
    );
    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'fiscal_${now.year}_${now.month}.pdf',
    );
  }

  // ---------------------------------------------------------------------------
  // E2: Reporte eficiencia por cobrador
  // ---------------------------------------------------------------------------

  Future<void> _generarEficiencia(
      BuildContext context, String empresaNombre, RangoReporte rango) async {
    final rows = await ps.db.getAll('''
      SELECT cb.nombre AS cobrador_nombre,
             COUNT(p.id) AS total_cobros,
             COUNT(DISTINCT cu.cliente_id) AS clientes_visitados,
             COALESCE(SUM(p.monto_cordobas), 0) AS monto_total,
             (SELECT COUNT(*)
                FROM cuotas cq
               WHERE cq.cobrador_id = cb.id
                 AND cq.estado IN ('pendiente','parcial','pagada')
                 AND date(cq.fecha_vencimiento) BETWEEN ? AND ?
             ) AS cuotas_asignadas
        FROM cobradores cb
   LEFT JOIN pagos p ON p.cobrador_id = cb.id
                    AND p.anulado = 0
                    AND date(p.fecha_pago) BETWEEN ? AND ?
   LEFT JOIN cuotas cu ON cu.id = p.cuota_id
       WHERE cb.rol = 'cobrador' AND cb.activo = 1
       GROUP BY cb.id, cb.nombre
       ORDER BY monto_total DESC
    ''', [rango.desdeSql, rango.hastaSql, rango.desdeSql, rango.hastaSql]);

    final now = DateTime.now();
    final doc = buildReporteEficiencia(
      titulo: 'Eficiencia por cobrador',
      empresaNombre: empresaNombre,
      periodo: rango.periodoLabel,
      rows: rows,
    );
    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'eficiencia_${now.year}_${now.month}.pdf',
    );
  }

  // ---------------------------------------------------------------------------
  // E3: Reporte clientes inactivos
  // ---------------------------------------------------------------------------

  Future<void> _generarInactivos(
      BuildContext context, String empresaNombre) async {
    const mesesInactividad = 3;
    final rows = await ps.db.getAll('''
      SELECT c.nombre, co.nombre AS comunidad,
             c.telefono,
             MAX(p.fecha_pago) AS ultimo_pago,
             CAST(julianday('now') - julianday(MAX(p.fecha_pago))
               AS INTEGER) AS dias_sin_pago
        FROM clientes c
   LEFT JOIN comunidades co ON co.id = c.comunidad_id
   LEFT JOIN cuotas cu ON cu.cliente_id = c.id
   LEFT JOIN pagos p ON p.cuota_id = cu.id AND p.anulado = 0
       WHERE c.activo = 1
       GROUP BY c.id, c.nombre, co.nombre, c.telefono
      HAVING MAX(p.fecha_pago) IS NULL
          OR MAX(p.fecha_pago) < date('now', '-$mesesInactividad months')
       ORDER BY ultimo_pago ASC
    ''');

    final now = DateTime.now();
    final doc = buildReporteInactivos(
      titulo: 'Clientes inactivos',
      empresaNombre: empresaNombre,
      periodo: Fmt.mes(now),
      rows: rows,
      mesesInactividad: mesesInactividad,
    );
    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'inactivos_${now.year}_${now.month}.pdf',
    );
  }

  // ---------------------------------------------------------------------------
  // E4: Reporte de anulaciones
  // ---------------------------------------------------------------------------

  Future<void> _generarAnulaciones(
      BuildContext context, String empresaNombre, RangoReporte rango) async {
    final rows = await ps.db.getAll('''
      SELECT p.fecha_pago,
             c.nombre AS cliente_nombre,
             p.monto_cordobas AS monto,
             p.motivo_anulacion,
             cb_anulador.nombre AS anulado_por_nombre,
             r.numero_completo AS numero_recibo
        FROM pagos p
        JOIN cuotas cu ON cu.id = p.cuota_id
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN cobradores cb_anulador ON cb_anulador.id = p.anulado_por
   LEFT JOIN recibos r ON r.pago_id = p.id
       WHERE p.anulado = 1
         AND date(p.fecha_pago) BETWEEN ? AND ?
       ORDER BY p.anulado_en DESC, p.fecha_pago DESC
    ''', [rango.desdeSql, rango.hastaSql]);

    final now = DateTime.now();
    final doc = buildReporteAnulaciones(
      titulo: 'Reporte de anulaciones',
      empresaNombre: empresaNombre,
      periodo: rango.periodoLabel,
      rows: rows,
    );
    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'anulaciones_${now.year}_${now.month}.pdf',
    );
  }

  // ---------------------------------------------------------------------------
  // E5: Exportar CSV — sub-menú de selección de reporte
  // ---------------------------------------------------------------------------

  Future<void> _mostrarMenuCsv(BuildContext context, WidgetRef ref) async {
    final tipo = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Exportar CSV'),
        children: [
          _csvOpcion(ctx, 'cobros', Icons.receipt_long, 'Cobros del mes'),
          _csvOpcion(ctx, 'mora', Icons.warning_amber, 'Mora'),
          _csvOpcion(ctx, 'clientes', Icons.people, 'Estado de clientes'),
          _csvOpcion(ctx, 'fiscal', Icons.account_balance, 'Fiscal'),
          _csvOpcion(ctx, 'eficiencia', Icons.speed, 'Eficiencia cobradores'),
          _csvOpcion(ctx, 'inactivos', Icons.person_off, 'Clientes inactivos'),
          _csvOpcion(ctx, 'anulaciones', Icons.cancel_outlined, 'Anulaciones'),
          _csvOpcion(ctx, 'arqueo', Icons.point_of_sale, 'Arqueo / cierre'),
        ],
      ),
    );
    if (tipo == null || !context.mounted) return;

    try {
      // El arqueo usa su rango propio (HOY por default); el resto, el global.
      final rango = tipo == 'arqueo'
          ? ref.read(reporteArqueoRangoProvider)
          : ref.read(reporteRangoProvider);
      final tasaUsd = ref.read(appSettingsProvider).tasaUsd;
      final csv = await _generarCsv(tipo, rango, tasaUsd);
      await Clipboard.setData(ClipboardData(text: csv));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('CSV copiado al portapapeles — pegalo en Excel'),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generando CSV: $e')),
        );
      }
    }
  }

  SimpleDialogOption _csvOpcion(
      BuildContext ctx, String value, IconData icon, String label) {
    return SimpleDialogOption(
      onPressed: () => Navigator.pop(ctx, value),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

  Future<String> _generarCsv(
      String tipo, RangoReporte rango, double tasaUsd) async {
    switch (tipo) {
      case 'cobros':
        final rows = await ps.db.getAll('''
          SELECT p.fecha_pago, c.nombre AS cliente_nombre,
                 p.monto_cordobas AS monto, p.metodo,
                 cb.nombre AS cobrador_nombre,
                 r.numero_completo AS numero_recibo,
                 SUBSTR(p.grupo_cobro, 1, 8) AS ref_grupo
            FROM pagos p
            JOIN cuotas cu ON cu.id = p.cuota_id
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN cobradores cb ON cb.id = p.cobrador_id
       LEFT JOIN recibos r ON r.pago_id = p.id
           WHERE p.anulado = 0
             AND date(p.fecha_pago) BETWEEN ? AND ?
           ORDER BY p.fecha_pago DESC
        ''', [rango.desdeSql, rango.hastaSql]);
        return _toCsv(
          ['Fecha', 'Cliente', 'Monto', 'Método', 'Cobrador', 'Recibo', 'Grupo'],
          rows.map((r) => [
            r['fecha_pago']?.toString() ?? '',
            r['cliente_nombre']?.toString() ?? '',
            r['monto']?.toString() ?? '0',
            MetodoPago.fromString(r['metodo']?.toString() ?? '').label,
            r['cobrador_nombre']?.toString() ?? '',
            r['numero_recibo']?.toString() ?? '',
            r['ref_grupo']?.toString() ?? '',
          ]).toList(),
        );

      case 'mora':
        final rows = await ps.db.getAll('''
          SELECT c.nombre AS cliente_nombre,
                 co.nombre AS comunidad,
                 COUNT(cu.id) AS cuotas_vencidas,
                 COALESCE(SUM(cu.monto + COALESCE(cu.cargos_neto, 0)
                   - cu.monto_pagado), 0) AS monto_adeudado,
                 CAST(julianday('now') - julianday(MIN(cu.fecha_vencimiento))
                   AS INTEGER) AS dias_mora
            FROM cuotas cu
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN comunidades co ON co.id = c.comunidad_id
           WHERE cu.estado IN ('pendiente','parcial')
             AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                 < date('now')
           GROUP BY c.id, c.nombre, co.nombre
           ORDER BY dias_mora DESC
        ''', [diasGracia]);
        return _toCsv(
          ['Cliente', 'Comunidad', 'Cuotas vencidas', 'Monto adeudado',
           'Días mora'],
          rows.map((r) => [
            r['cliente_nombre']?.toString() ?? '',
            r['comunidad']?.toString() ?? '',
            r['cuotas_vencidas']?.toString() ?? '0',
            r['monto_adeudado']?.toString() ?? '0',
            r['dias_mora']?.toString() ?? '0',
          ]).toList(),
        );

      case 'clientes':
        final rows = await ps.db.getAll('''
          SELECT c.nombre, co.nombre AS comunidad,
                 COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial') THEN 1 ELSE 0 END), 0)
                   AS pendientes,
                 COALESCE(SUM(CASE WHEN cu.estado IN ('pendiente','parcial')
                   THEN cu.monto + COALESCE(cu.cargos_neto, 0) - cu.monto_pagado
                   ELSE 0 END), 0) AS saldo,
                 MAX(p.fecha_pago) AS ultimo_pago
            FROM clientes c
       LEFT JOIN comunidades co ON co.id = c.comunidad_id
       LEFT JOIN cuotas cu ON cu.cliente_id = c.id
       LEFT JOIN pagos p ON p.cuota_id = cu.id AND p.anulado = 0
           WHERE c.activo = 1
           GROUP BY c.id, c.nombre, co.nombre
           ORDER BY saldo DESC
        ''');
        return _toCsv(
          ['Cliente', 'Comunidad', 'Pendientes', 'Saldo', 'Último pago'],
          rows.map((r) => [
            r['nombre']?.toString() ?? '',
            r['comunidad']?.toString() ?? '',
            r['pendientes']?.toString() ?? '0',
            r['saldo']?.toString() ?? '0',
            r['ultimo_pago']?.toString() ?? 'Sin pagos',
          ]).toList(),
        );

      case 'fiscal':
        final rows = await ps.db.getAll('''
          SELECT strftime('%Y-%m', p.fecha_pago) AS mes,
                 COALESCE(pl.nombre, 'Sin plan') AS plan_nombre,
                 p.metodo,
                 COALESCE(SUM(p.monto_cordobas), 0) AS total_monto,
                 COUNT(p.id) AS cantidad
            FROM pagos p
            JOIN cuotas cu ON cu.id = p.cuota_id
       LEFT JOIN contratos ct ON ct.id = cu.contrato_id
       LEFT JOIN planes pl ON pl.id = ct.plan_id
           WHERE p.anulado = 0
             AND date(p.fecha_pago) BETWEEN ? AND ?
           GROUP BY mes, plan_nombre, p.metodo
           ORDER BY mes DESC, plan_nombre, p.metodo
        ''', [rango.desdeSql, rango.hastaSql]);
        return _toCsv(
          ['Mes', 'Plan', 'Método', 'Monto total', 'Cantidad cobros'],
          rows.map((r) => [
            r['mes']?.toString() ?? '',
            r['plan_nombre']?.toString() ?? '',
            MetodoPago.fromString(r['metodo']?.toString() ?? '').label,
            r['total_monto']?.toString() ?? '0',
            r['cantidad']?.toString() ?? '0',
          ]).toList(),
        );

      case 'eficiencia':
        final rows = await ps.db.getAll('''
          SELECT cb.nombre AS cobrador_nombre,
                 COUNT(p.id) AS total_cobros,
                 COUNT(DISTINCT cu.cliente_id) AS clientes_visitados,
                 COALESCE(SUM(p.monto_cordobas), 0) AS monto_total,
                 (SELECT COUNT(*)
                    FROM cuotas cq
                   WHERE cq.cobrador_id = cb.id
                     AND cq.estado IN ('pendiente','parcial','pagada')
                     AND date(cq.fecha_vencimiento) BETWEEN ? AND ?
                 ) AS cuotas_asignadas
            FROM cobradores cb
       LEFT JOIN pagos p ON p.cobrador_id = cb.id
                        AND p.anulado = 0
                        AND date(p.fecha_pago) BETWEEN ? AND ?
       LEFT JOIN cuotas cu ON cu.id = p.cuota_id
           WHERE cb.rol = 'cobrador' AND cb.activo = 1
           GROUP BY cb.id, cb.nombre
           ORDER BY monto_total DESC
        ''', [rango.desdeSql, rango.hastaSql, rango.desdeSql, rango.hastaSql]);
        return _toCsv(
          ['Cobrador', 'Cobros', 'Clientes visitados', 'Monto total',
           'Cuotas asignadas', '% Éxito'],
          rows.map((r) {
            final cobros = ((r['total_cobros'] as num?) ?? 0).toInt();
            final asignadas =
                ((r['cuotas_asignadas'] as num?) ?? 0).toInt();
            final tasa = asignadas > 0
                ? ((cobros / asignadas) * 100).toStringAsFixed(1)
                : '0';
            return [
              r['cobrador_nombre']?.toString() ?? '',
              '$cobros',
              r['clientes_visitados']?.toString() ?? '0',
              r['monto_total']?.toString() ?? '0',
              '$asignadas',
              '$tasa%',
            ];
          }).toList(),
        );

      case 'inactivos':
        const mesesInactividad = 3;
        final rows = await ps.db.getAll('''
          SELECT c.nombre, co.nombre AS comunidad,
                 c.telefono,
                 MAX(p.fecha_pago) AS ultimo_pago,
                 CAST(julianday('now') - julianday(MAX(p.fecha_pago))
                   AS INTEGER) AS dias_sin_pago
            FROM clientes c
       LEFT JOIN comunidades co ON co.id = c.comunidad_id
       LEFT JOIN cuotas cu ON cu.cliente_id = c.id
       LEFT JOIN pagos p ON p.cuota_id = cu.id AND p.anulado = 0
           WHERE c.activo = 1
           GROUP BY c.id, c.nombre, co.nombre, c.telefono
          HAVING MAX(p.fecha_pago) IS NULL
              OR MAX(p.fecha_pago) < date('now', '-$mesesInactividad months')
           ORDER BY ultimo_pago ASC
        ''');
        return _toCsv(
          ['Cliente', 'Comunidad', 'Teléfono', 'Último pago',
           'Días sin pago'],
          rows.map((r) => [
            r['nombre']?.toString() ?? '',
            r['comunidad']?.toString() ?? '',
            r['telefono']?.toString() ?? '',
            r['ultimo_pago']?.toString() ?? 'Sin pagos',
            r['dias_sin_pago']?.toString() ?? '',
          ]).toList(),
        );

      case 'anulaciones':
        final rows = await ps.db.getAll('''
          SELECT p.fecha_pago,
                 c.nombre AS cliente_nombre,
                 p.monto_cordobas AS monto,
                 p.motivo_anulacion,
                 cb_anulador.nombre AS anulado_por_nombre,
                 r.numero_completo AS numero_recibo
            FROM pagos p
            JOIN cuotas cu ON cu.id = p.cuota_id
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN cobradores cb_anulador ON cb_anulador.id = p.anulado_por
       LEFT JOIN recibos r ON r.pago_id = p.id
           WHERE p.anulado = 1
             AND date(p.fecha_pago) BETWEEN ? AND ?
           ORDER BY p.anulado_en DESC, p.fecha_pago DESC
        ''', [rango.desdeSql, rango.hastaSql]);
        return _toCsv(
          ['Fecha', 'Cliente', 'Monto', 'Motivo', 'Anulado por', 'Recibo'],
          rows.map((r) => [
            r['fecha_pago']?.toString() ?? '',
            r['cliente_nombre']?.toString() ?? '',
            r['monto']?.toString() ?? '0',
            r['motivo_anulacion']?.toString() ?? 'Sin motivo',
            r['anulado_por_nombre']?.toString() ?? '',
            r['numero_recibo']?.toString() ?? '',
          ]).toList(),
        );

      case 'arqueo':
        final rows = await ps.db.getAll(_arqueoSql, [
          rango.desdeSql,
          rango.hastaSql,
        ]);
        return _toCsv(
          [
            'Cobrador', 'Total cobros', 'Efectivo USD', 'Efectivo C\$',
            'Vuelto C\$', 'Efectivo neto C\$', 'Transferencia', 'Depósito',
            'Tarjeta', 'Equivalente total C\$', 'Ingreso total',
          ],
          rows.map((r) {
            double d(String k) => ((r[k] as num?) ?? 0).toDouble();
            final efectivoNetoC = d('efectivo_nio') - d('efectivo_vuelto');
            final equivalenteTotalC = efectivoNetoC +
                d('efectivo_usd') * tasaUsd +
                d('transferencia') +
                d('deposito') +
                d('tarjeta');
            return [
              r['cobrador_nombre']?.toString() ?? '',
              r['total_cobros']?.toString() ?? '0',
              d('efectivo_usd').toString(),
              d('efectivo_nio').toString(),
              d('efectivo_vuelto').toString(),
              efectivoNetoC.toString(),
              d('transferencia').toString(),
              d('deposito').toString(),
              d('tarjeta').toString(),
              equivalenteTotalC.toString(),
              d('ingreso_total').toString(),
            ];
          }).toList(),
        );

      default:
        return '';
    }
  }

  /// Convierte headers + filas a CSV con escape correcto de comillas.
  String _toCsv(List<String> headers, List<List<String>> rows) {
    String escapar(String celda) =>
        '"${celda.replaceAll('"', '""')}"';
    final lineas = <String>[
      headers.map(escapar).join(','),
      ...rows.map((r) => r.map(escapar).join(',')),
    ];
    return lineas.join('\n');
  }
}

class _RecaudacionMensualCard extends StatefulWidget {
  const _RecaudacionMensualCard();

  @override
  State<_RecaudacionMensualCard> createState() =>
      _RecaudacionMensualCardState();
}

class _RecaudacionMensualCardState extends State<_RecaudacionMensualCard> {
  late final Stream<List<Map<String, dynamic>>> _recaudacionStream;

  @override
  void initState() {
    super.initState();
    _recaudacionStream = ps.db.watch(
      '''
      SELECT strftime('%Y-%m', fecha_pago) AS mes,
             COALESCE(SUM(monto_cordobas), 0) AS total,
             COUNT(*) AS qty
        FROM pagos
       WHERE anulado = 0
         AND date(fecha_pago) >= date('now', '-5 months', 'start of month')
       GROUP BY mes
       ORDER BY mes
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Recaudación últimos 6 meses',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _recaudacionStream,
              initialData: const [],
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text('Error: ${snap.error}',
                      style: TextStyle(color: Theme.of(context).colorScheme.error));
                }
                final rows = snap.data!;
                if (rows.isEmpty) {
                  return Text('Sin pagos en los últimos 6 meses',
                      style: TextStyle(color: Theme.of(context).colorScheme.outline));
                }
                final maxTotal = rows.map((r) => (r['total'] as num).toDouble()).reduce((a, b) => a > b ? a : b);
                return Column(
                  children: rows.map((r) {
                    final total = (r['total'] as num).toDouble();
                    final pct = maxTotal > 0 ? total / maxTotal : 0.0;
                    final mes = _mesLabel(r['mes'] as String);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(mes)),
                              Text('${r['qty']} cobros',
                                  style: TextStyle(
                                      color: Theme.of(context).colorScheme.outline,
                                      fontSize: 12)),
                              const SizedBox(width: 12),
                              Text(Fmt.cordobas(total),
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: pct,
                              minHeight: 6,
                              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _mesLabel(String yyyyMm) {
    final parts = yyyyMm.split('-');
    final mes = int.parse(parts[1]);
    const nombres = [
      'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
      'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'
    ];
    return '${nombres[mes - 1]} ${parts[0]}';
  }
}

class _CobradoresMesCard extends StatefulWidget {
  const _CobradoresMesCard();

  @override
  State<_CobradoresMesCard> createState() => _CobradoresMesCardState();
}

class _CobradoresMesCardState extends State<_CobradoresMesCard> {
  late final Stream<List<Map<String, dynamic>>> _cobradoresMesStream;

  @override
  void initState() {
    super.initState();
    _cobradoresMesStream = ps.db.watch(
      '''
      SELECT co.id, co.nombre, co.prefijo_recibo,
             COALESCE(SUM(p.monto_cordobas), 0) AS total,
             COUNT(p.id) AS qty,
             COUNT(DISTINCT p.cuota_id) AS cuotas
        FROM cobradores co
   LEFT JOIN pagos p ON p.cobrador_id = co.id
                    AND p.anulado = 0
                    AND date(p.fecha_pago) >= date('now', 'start of month')
       WHERE co.rol = 'cobrador' AND co.activo = 1
       GROUP BY co.id, co.nombre, co.prefijo_recibo
       ORDER BY total DESC
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Cobradores este mes',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _cobradoresMesStream,
              initialData: const [],
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text('Error: ${snap.error}',
                      style: TextStyle(color: Theme.of(context).colorScheme.error));
                }
                final rows = snap.data!;
                if (rows.isEmpty) return const SizedBox.shrink();
                return Column(
                  children: rows.map((r) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor:
                              Theme.of(context).colorScheme.primaryContainer,
                          child: Text(
                              ((r['prefijo_recibo'] as String?) ?? '??')
                                  .padRight(2, '?')
                                  .substring(0, 2)),
                        ),
                        title: Text(r['nombre'] as String),
                        subtitle: Text('${r['qty']} cobros · ${r['cuotas']} cuotas'),
                        trailing: Text(
                          Fmt.cordobas(r['total'] as num),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      )).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MoraPorComunidadCard extends StatefulWidget {
  const _MoraPorComunidadCard({required this.diasGracia});
  final int diasGracia;

  @override
  State<_MoraPorComunidadCard> createState() => _MoraPorComunidadCardState();
}

class _MoraPorComunidadCardState extends State<_MoraPorComunidadCard> {
  late Stream<List<Map<String, dynamic>>> _moraStream;

  @override
  void initState() {
    super.initState();
    _buildStream();
  }

  @override
  void didUpdateWidget(covariant _MoraPorComunidadCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diasGracia != widget.diasGracia) {
      setState(() => _buildStream());
    }
  }

  void _buildStream() {
    _moraStream = ps.db.watch(
      '''
      SELECT co.nombre AS comunidad, m.nombre AS municipio,
             COUNT(cu.id) AS vencidas,
             COALESCE(SUM(cu.monto + COALESCE(cu.cargos_neto, 0) - cu.monto_pagado), 0) AS adeudo
        FROM cuotas cu
        JOIN clientes c ON c.id = cu.cliente_id
        JOIN comunidades co ON co.id = c.comunidad_id
        JOIN municipios m ON m.id = co.municipio_id
       WHERE cu.estado IN ('pendiente','parcial')
         AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now')
       GROUP BY co.id, co.nombre, m.nombre
       ORDER BY adeudo DESC
       LIMIT 10
      ''',
      parameters: [widget.diasGracia],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Mora por comunidad',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _moraStream,
              initialData: const [],
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text('Error: ${snap.error}',
                      style: TextStyle(color: Theme.of(context).colorScheme.error));
                }
                final rows = snap.data!;
                if (rows.isEmpty) {
                  return Text('Sin mora — todos al día',
                      style: TextStyle(color: Theme.of(context).colorScheme.outline));
                }
                return Column(
                  children: rows.map((r) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.warning,
                            color: Theme.of(context).colorScheme.error),
                        title: Text(r['comunidad'] as String),
                        subtitle: Text(
                            '${r['municipio']} · ${r['vencidas']} cuotas vencidas'),
                        trailing: Text(
                          Fmt.cordobas(r['adeudo'] as num),
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.error),
                        ),
                      )).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanesPopularesCard extends StatefulWidget {
  const _PlanesPopularesCard();

  @override
  State<_PlanesPopularesCard> createState() => _PlanesPopularesCardState();
}

class _PlanesPopularesCardState extends State<_PlanesPopularesCard> {
  late final Stream<List<Map<String, dynamic>>> _planesStream;

  @override
  void initState() {
    super.initState();
    _planesStream = ps.db.watch(
      '''
      SELECT p.nombre, p.precio_mensual,
             COUNT(ct.id) AS contratos
        FROM planes p
   LEFT JOIN contratos ct ON ct.plan_id = p.id AND ct.estado = 'activo'
       GROUP BY p.id, p.nombre, p.precio_mensual
       ORDER BY contratos DESC
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Planes contratados',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _planesStream,
              initialData: const [],
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text('Error: ${snap.error}',
                      style: TextStyle(color: Theme.of(context).colorScheme.error));
                }
                final rows = snap.data!;
                if (rows.isEmpty) return const SizedBox.shrink();
                return Column(
                  children: rows.map((r) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.wifi),
                        title: Text(r['nombre'] as String),
                        subtitle: Text(Fmt.cordobas(r['precio_mensual'] as num)),
                        trailing: Text(
                          '${r['contratos']} contratos',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      )).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
