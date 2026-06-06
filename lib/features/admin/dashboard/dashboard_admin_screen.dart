import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/dashboard_providers.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;

class DashboardAdminScreen extends StatelessWidget {
  const DashboardAdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Resumen', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(
          '${Fmt.diaSemana(now)}, ${Fmt.fechaLarga(now)}',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
        const SizedBox(height: 24),
        const _CobrosKPIs(),
        const SizedBox(height: 16),
        const _Sparkline7d(),
        const SizedBox(height: 24),
        const _OperativoKPIs(),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, c) {
            // En narrow (< 700px) NO usamos Flex con Expanded: estamos
            // adentro de un ListView (altura infinita) y Expanded
            // necesita altura finita para expandirse, sino tira
            // assertion "non-zero flex / unbounded height constraints"
            // y entra en loop de rebuild. Column normal con SizedBox
            // ya hace stack sin pelearse con el ListView.
            if (c.maxWidth >= 700) {
              return const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _TopCobradoresCard()),
                  SizedBox(width: 16),
                  Expanded(child: _DistribucionCuotasCard()),
                ],
              );
            }
            return const Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopCobradoresCard(),
                SizedBox(height: 16),
                _DistribucionCuotasCard(),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _CobrosKPIs extends ConsumerWidget {
  const _CobrosKPIs();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(cobrosKpisProvider);
    return async.when(
      data: (k) => _Kpis(items: [
        _KpiData('Hoy', Fmt.cordobas(k.hoy), '${k.qtyHoy} cobros', Icons.today),
        _KpiData('Esta semana', Fmt.cordobas(k.semana),
            '${k.qtySemana} cobros', Icons.calendar_view_week),
        _KpiData('Este mes', Fmt.cordobas(k.mes), '${k.qtyMes} cobros',
            Icons.calendar_month,
            primary: true),
      ]),
      loading: () => const SizedBox(
          height: 100, child: Center(child: CircularProgressIndicator())),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _Sparkline7d extends StatefulWidget {
  const _Sparkline7d();
  @override
  State<_Sparkline7d> createState() => _Sparkline7dState();
}

class _Sparkline7dState extends State<_Sparkline7d> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = ps.db.watch('''
      SELECT date(fecha_pago) AS dia,
             COALESCE(SUM(monto_cordobas), 0) AS total
        FROM pagos
       WHERE anulado = 0
         AND date(fecha_pago) >= date('now', '-6 hours', '-6 days')
       GROUP BY date(fecha_pago)
       ORDER BY dia
    ''');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.show_chart, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text('Cobros últimos 7 días',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _stream,
                initialData: const [],
                builder: (context, snap) {
                  if (snap.hasError || snap.data!.isEmpty) {
                    return Center(
                      child: Text('Sin datos',
                          style: TextStyle(color: scheme.outline, fontSize: 12)),
                    );
                  }
                  // Llenar los 7 días con 0 donde no hay cobros.
                  final map = <String, double>{};
                  for (final r in snap.data!) {
                    map[r['dia'] as String] = (r['total'] as num).toDouble();
                  }
                  final values = <double>[];
                  for (var i = 6; i >= 0; i--) {
                    final d = DateTime.now().subtract(Duration(days: i));
                    final key = d.toIso8601String().substring(0, 10);
                    values.add(map[key] ?? 0);
                  }
                  return CustomPaint(
                    size: const Size(double.infinity, 48),
                    painter: _SparklinePainter(
                      values: values,
                      color: scheme.primary,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.color});
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    if (maxV == 0) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 0.3), color.withValues(alpha: 0.0)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final path = Path();
    final fillPath = Path();
    final stepX = size.width / (values.length - 1);

    for (var i = 0; i < values.length; i++) {
      final x = i * stepX;
      final y = size.height - (values[i] / maxV * size.height * 0.85);
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);

    // Dots en cada punto.
    final dotPaint = Paint()..color = color;
    for (var i = 0; i < values.length; i++) {
      final x = i * stepX;
      final y = size.height - (values[i] / maxV * size.height * 0.85);
      canvas.drawCircle(Offset(x, y), 3, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values != values || old.color != color;
}

class _OperativoKPIs extends ConsumerWidget {
  const _OperativoKPIs();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(operativoKpisProvider);
    return async.when(
      data: (k) => _Kpis(items: [
        _KpiData('Clientes activos', '${k.clientes}', null, Icons.people),
        _KpiData('Cuotas por cobrar', '${k.cuotasPend}',
            Fmt.cordobas(k.saldo), Icons.pending),
        _KpiData(
          'En mora',
          '${k.vencidas}',
          Fmt.cordobas(k.saldoVencido),
          Icons.warning,
          error: true,
        ),
      ]),
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _Kpis extends StatelessWidget {
  const _Kpis({required this.items});
  final List<_KpiData> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 900 ? 3 : c.maxWidth >= 500 ? 2 : 1;
      return GridView.count(
        crossAxisCount: cols,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        // Mobile (1 col): ratio 2.3 — el contenido del card (icon+label
        // row + headlineMedium value + sub-label + 3 spacings + padding
        // 20×2) necesita ~132px de alto. Con viewport 375px y padding
        // del padre (~32px), el ancho del card es ~343px → ratio 2.3
        // da ~149px de alto, holgado. Probado: 4.0 → "BOTTOM OVERFLOWED
        // BY 18 PIXELS", 3.0 → "BY 23 PIXELS", 2.3 → entra OK.
        // 2 / 3 columnas (tablet/desktop) mantienen 2.2 — el ancho del
        // card es menor pero el contenido entra holgado.
        childAspectRatio: cols == 1 ? 2.3 : 2.2,
        children: items.map((k) => _KpiCard(data: k)).toList(),
      );
    });
  }
}

class _KpiData {
  const _KpiData(this.label, this.value, this.sub, this.icon,
      {this.primary = false, this.error = false});
  final String label;
  final String value;
  final String? sub;
  final IconData icon;
  final bool primary;
  final bool error;
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.data});
  final _KpiData data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = data.error
        ? scheme.error
        : (data.primary ? scheme.primary : scheme.outline);
    return Card(
      color:
          data.primary ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(data.icon, size: 20, color: color),
                const SizedBox(width: 8),
                Text(data.label,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 12),
            Text(data.value,
                style: Theme.of(context).textTheme.headlineMedium),
            if (data.sub != null) ...[
              const SizedBox(height: 4),
              Text(data.sub!,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

class _TopCobradoresCard extends ConsumerWidget {
  const _TopCobradoresCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(topCobradoresProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Top cobradores (este mes)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            async.when(
              data: (rows) {
                if (rows.isEmpty) {
                  return Text('Sin cobradores activos',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline));
                }
                final maxTotal = rows
                    .map((r) => r.total.toDouble())
                    .reduce((a, b) => a > b ? a : b);
                return Column(
                  children: rows.map((r) {
                    final total = r.total.toDouble();
                    final pct = maxTotal > 0 ? total / maxTotal : 0.0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(r.nombre)),
                              Text(Fmt.cordobas(total),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: pct,
                              minHeight: 6,
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _DistribucionCuotasCard extends ConsumerWidget {
  const _DistribucionCuotasCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(distribucionCuotasProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Distribución de cuotas',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            async.when(
              data: (k) {
                final scheme = Theme.of(context).colorScheme;
                return Column(
                  children: [
                    _row('Al día', '${k.alDia}', scheme.primary, Icons.event),
                    _row('Pago parcial', '${k.parcial}', scheme.secondary,
                        Icons.hourglass_bottom),
                    _row('En gracia', '${k.enGracia}', Colors.amber.shade700,
                        Icons.schedule),
                    _row('Vencidas', '${k.vencida}', scheme.error,
                        Icons.warning),
                    _row('Pagadas', '${k.pagada}', scheme.outline, Icons.check),
                  ],
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, Color color, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          Text(value,
              style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

