import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../config/router.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import 'pdf/reporte_cobros_pdf.dart';
import 'pdf/reporte_mora_pdf.dart';

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

class _DescargarPdfMenu extends ConsumerWidget {
  const _DescargarPdfMenu({required this.diasGracia});
  final int diasGracia;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      onSelected: (tipo) => _generar(context, ref, tipo),
      itemBuilder: (_) => const [
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
      ],
      child: FloatingActionButton.extended(
        onPressed: null,
        icon: const Icon(Icons.picture_as_pdf),
        label: const Text('Descargar PDF'),
      ),
    );
  }

  Future<void> _generar(
      BuildContext context, WidgetRef ref, String tipo) async {
    final empresaNombre =
        ref.read(empresaNombreProvider).valueOrNull ?? 'ISP';

    try {
      if (tipo == 'cobros') {
        final rows = await ps.db.getAll('''
          SELECT p.fecha_pago, c.nombre AS cliente_nombre,
                 p.monto_cordobas AS monto, p.metodo,
                 cb.nombre AS cobrador_nombre,
                 r.numero_completo AS numero_recibo
            FROM pagos p
            JOIN cuotas cu ON cu.id = p.cuota_id
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN cobradores cb ON cb.id = p.cobrador_id
       LEFT JOIN recibos r ON r.pago_id = p.id
           WHERE p.anulado = 0
             AND date(p.fecha_pago) >= date('now', 'start of month')
           ORDER BY p.fecha_pago DESC
        ''');

        final now = DateTime.now();
        final periodo = '${Fmt.mes(now)} ${now.year}';
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
                 MIN(cu.fecha_vencimiento) AS primera_vencida
            FROM cuotas cu
            JOIN clientes c ON c.id = cu.cliente_id
       LEFT JOIN comunidades co ON co.id = c.comunidad_id
           WHERE cu.estado IN ('pendiente','parcial')
             AND date(cu.fecha_vencimiento, '+' || ? || ' days')
                 < date('now')
           GROUP BY c.id, c.nombre, co.nombre
           ORDER BY monto_adeudado DESC
        ''', [diasGracia]);

        final doc = buildReporteMora(
          titulo: 'Reporte de mora',
          empresaNombre: empresaNombre,
          rows: rows,
        );

        final now = DateTime.now();
        await Printing.sharePdf(
          bytes: await doc.save(),
          filename: 'mora_${now.year}_${now.month}_${now.day}.pdf',
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generando PDF: $e')),
        );
      }
    }
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
            StreamBuilder(
              stream: _recaudacionStream,
              builder: (context, snap) {
                if (!snap.hasData) return const SizedBox.shrink();
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
            StreamBuilder(
              stream: _cobradoresMesStream,
              builder: (context, snap) {
                if (!snap.hasData) return const SizedBox.shrink();
                return Column(
                  children: snap.data!.map((r) => ListTile(
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
            StreamBuilder(
              stream: _moraStream,
              builder: (context, snap) {
                if (!snap.hasData) return const SizedBox.shrink();
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
   LEFT JOIN contratos ct ON ct.plan_id = p.id AND ct.activo = 1
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
            StreamBuilder(
              stream: _planesStream,
              builder: (context, snap) {
                if (!snap.hasData) return const SizedBox.shrink();
                return Column(
                  children: snap.data!.map((r) => ListTile(
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
