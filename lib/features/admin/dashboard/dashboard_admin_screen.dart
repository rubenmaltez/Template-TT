import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;

class DashboardAdminScreen extends ConsumerWidget {
  const DashboardAdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diasGracia = ref.watch(appSettingsProvider).diasGracia;
    final now = DateTime.now();
    final hoy = DateTime(now.year, now.month, now.day).toIso8601String().substring(0, 10);
    final inicioMes = DateTime(now.year, now.month, 1).toIso8601String().substring(0, 10);
    final inicioSemana = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1))
        .toIso8601String()
        .substring(0, 10);

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
        _CobrosKPIs(hoy: hoy, inicioSemana: inicioSemana, inicioMes: inicioMes),
        const SizedBox(height: 24),
        _OperativoKPIs(diasGracia: diasGracia),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, c) {
            final esDosCols = c.maxWidth >= 700;
            return Flex(
              direction: esDosCols ? Axis.horizontal : Axis.vertical,
              children: [
                Expanded(child: _TopCobradoresCard(inicioMes: inicioMes)),
                SizedBox(width: esDosCols ? 16 : 0, height: esDosCols ? 0 : 16),
                Expanded(child: _DistribucionCuotasCard(diasGracia: diasGracia)),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        _AccesosRapidos(),
      ],
    );
  }
}

class _CobrosKPIs extends StatelessWidget {
  const _CobrosKPIs({
    required this.hoy,
    required this.inicioSemana,
    required this.inicioMes,
  });
  final String hoy;
  final String inicioSemana;
  final String inicioMes;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: ps.db.watch(
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
        parameters: [hoy, inicioSemana, inicioMes, hoy, inicioSemana, inicioMes],
      ),
      builder: (context, snap) {
        if (!snap.hasData || snap.data!.isEmpty) {
          return const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()));
        }
        final r = snap.data!.first;
        return _Kpis(items: [
          _KpiData('Hoy', Fmt.cordobas(r['hoy'] as num), '${r['qty_hoy']} cobros', Icons.today),
          _KpiData('Esta semana', Fmt.cordobas(r['semana'] as num), '${r['qty_semana']} cobros', Icons.calendar_view_week),
          _KpiData('Este mes', Fmt.cordobas(r['mes'] as num), '${r['qty_mes']} cobros', Icons.calendar_month, primary: true),
        ]);
      },
    );
  }
}

class _OperativoKPIs extends StatelessWidget {
  const _OperativoKPIs({required this.diasGracia});
  final int diasGracia;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: ps.db.watch(
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
      ),
      builder: (context, snap) {
        if (!snap.hasData || snap.data!.isEmpty) {
          return const SizedBox.shrink();
        }
        final r = snap.data!.first;
        return _Kpis(items: [
          _KpiData('Clientes activos', '${r['clientes']}', null, Icons.people),
          _KpiData('Cuotas por cobrar', '${r['cuotas_pend']}', Fmt.cordobas(r['saldo'] as num), Icons.pending),
          _KpiData(
            'En mora',
            '${r['vencidas']}',
            Fmt.cordobas(r['saldo_vencido'] as num),
            Icons.warning,
            error: true,
          ),
        ]);
      },
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
        childAspectRatio: cols == 1 ? 4 : 2.2,
        children: items.map((k) => _KpiCard(data: k)).toList(),
      );
    });
  }
}

class _KpiData {
  const _KpiData(this.label, this.value, this.sub, this.icon, {this.primary = false, this.error = false});
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
    final color = data.error ? scheme.error : (data.primary ? scheme.primary : scheme.outline);
    return Card(
      color: data.primary ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
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

class _TopCobradoresCard extends StatelessWidget {
  const _TopCobradoresCard({required this.inicioMes});
  final String inicioMes;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Top cobradores (este mes)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            StreamBuilder(
              stream: ps.db.watch(
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
                parameters: [inicioMes],
              ),
              builder: (context, snap) {
                if (!snap.hasData) return const SizedBox.shrink();
                final rows = snap.data!;
                if (rows.isEmpty) {
                  return Text('Sin cobradores activos',
                      style: TextStyle(color: Theme.of(context).colorScheme.outline));
                }
                final maxTotal = rows.map((r) => (r['total'] as num).toDouble()).reduce((a, b) => a > b ? a : b);
                return Column(
                  children: rows.map((r) {
                    final total = (r['total'] as num).toDouble();
                    final pct = maxTotal > 0 ? total / maxTotal : 0.0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(r['nombre'] as String)),
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
}

class _DistribucionCuotasCard extends StatelessWidget {
  const _DistribucionCuotasCard({required this.diasGracia});
  final int diasGracia;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Distribución de cuotas',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            StreamBuilder(
              stream: ps.db.watch(
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
              ),
              builder: (context, snap) {
                if (!snap.hasData || snap.data!.isEmpty) {
                  return const SizedBox.shrink();
                }
                final r = snap.data!.first;
                final scheme = Theme.of(context).colorScheme;
                return Column(
                  children: [
                    _row('Al día', '${r['al_dia']}', scheme.primary, Icons.event),
                    _row('Pago parcial', '${r['parcial']}', scheme.secondary, Icons.hourglass_bottom),
                    _row('En gracia', '${r['en_gracia']}', scheme.tertiary, Icons.schedule),
                    _row('Vencidas', '${r['vencida']}', scheme.error, Icons.warning),
                    _row('Pagadas', '${r['pagada']}', scheme.outline, Icons.check),
                  ],
                );
              },
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
          Text(value, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

class _AccesosRapidos extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Acciones rápidas',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _accion(context, Icons.person_add, 'Nuevo cliente', '/admin/clientes/nuevo'),
                _accion(context, Icons.assignment_add, 'Nuevo contrato', '/admin/contratos/nuevo'),
                _accion(context, Icons.warning, 'Ver mora', '/admin/cuotas'),
                _accion(context, Icons.settings, 'Configuración', '/admin/settings'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _accion(BuildContext context, IconData icon, String label, String path) {
    return OutlinedButton.icon(
      icon: Icon(icon),
      label: Text(label),
      onPressed: () => context.go(path),
    );
  }
}
