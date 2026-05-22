import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/providers/dashboard_providers.dart';
import '../../../data/utils/formatters.dart';

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
        const SizedBox(height: 24),
        const _AccesosRapidos(),
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
        // Mobile (1 col): ratio 3.0 — el 4 anterior dejaba altura
        // insuficiente para el contenido (icon + label + value + sub)
        // y tiraba "BOTTOM OVERFLOWED BY 18 PIXELS" en viewports <500px.
        // 2 / 3 columnas mantienen 2.2 (testeado OK).
        childAspectRatio: cols == 1 ? 3.0 : 2.2,
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
                    _row('En gracia', '${k.enGracia}', scheme.tertiary,
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

class _AccesosRapidos extends StatelessWidget {
  const _AccesosRapidos();

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
                // Forms CRUD: push para que back vuelva al dashboard
                // (consistente con R9 en clientes/contratos admin).
                _accion(context, Icons.person_add, 'Nuevo cliente',
                    '/admin/clientes/nuevo', push: true),
                _accion(context, Icons.assignment_add, 'Nuevo contrato',
                    '/admin/contratos/nuevo', push: true),
                // Tabs del shell: go reemplaza la stack (navegación lateral).
                _accion(context, Icons.warning, 'Ver mora', '/admin/cuotas'),
                _accion(context, Icons.settings, 'Configuración',
                    '/admin/settings'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _accion(BuildContext context, IconData icon, String label,
      String path,
      {bool push = false}) {
    return OutlinedButton.icon(
      icon: Icon(icon),
      label: Text(label),
      onPressed: () => push ? context.push(path) : context.go(path),
    );
  }
}
