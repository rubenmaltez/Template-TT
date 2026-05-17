import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
export 'contrato_form_screen.dart';

class ContratosAdminScreen extends ConsumerStatefulWidget {
  const ContratosAdminScreen({super.key});

  @override
  ConsumerState<ContratosAdminScreen> createState() =>
      _ContratosAdminScreenState();
}

class _ContratosAdminScreenState extends ConsumerState<ContratosAdminScreen> {
  bool _soloActivos = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              FilterChip(
                label: const Text('Solo activos'),
                selected: _soloActivos,
                onSelected: (v) => setState(() => _soloActivos = v),
              ),
              const Spacer(),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Nuevo contrato'),
                onPressed: () => context.go('/admin/contratos/nuevo'),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder(
            stream: ps.db.watch(
              '''
              SELECT ct.id, ct.dia_pago, ct.fecha_inicio, ct.fecha_fin,
                     ct.activo,
                     c.id AS cliente_id, c.nombre AS cliente,
                     p.nombre AS plan, p.precio_mensual,
                     co.nombre AS cobrador,
                     COUNT(cu.id) AS total_cuotas,
                     COUNT(cu.id) FILTER (WHERE cu.estado = 'pagada') AS cuotas_pagadas
                FROM contratos ct
                JOIN clientes c   ON c.id = ct.cliente_id
                JOIN planes   p   ON p.id = ct.plan_id
           LEFT JOIN cobradores co ON co.id = ct.cobrador_id
           LEFT JOIN cuotas    cu ON cu.contrato_id = ct.id
               WHERE ${_soloActivos ? 'ct.activo = 1' : '1=1'}
               GROUP BY ct.id, ct.dia_pago, ct.fecha_inicio, ct.fecha_fin,
                        ct.activo, c.id, c.nombre, p.nombre, p.precio_mensual,
                        co.nombre
               ORDER BY ct.activo DESC, c.nombre
              ''',
            ),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows = snap.data!;
              if (rows.isEmpty) {
                return const EmptyState(
                  icon: Icons.assignment_outlined,
                  titulo: 'Sin contratos',
                  descripcion: 'Creá un contrato para empezar a generar cuotas.',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _ContratoCard(row: rows[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ContratoCard extends StatelessWidget {
  const _ContratoCard({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activo = (row['activo'] as int? ?? 1) == 1;
    final fechaInicio = DateTime.parse(row['fecha_inicio'] as String);
    final fechaFin = row['fecha_fin'] != null
        ? DateTime.parse(row['fecha_fin'] as String)
        : null;
    final duracion = fechaFin == null
        ? 'Indefinido'
        : _mesesEntre(fechaInicio, fechaFin) == 12
            ? '1 año'
            : _mesesEntre(fechaInicio, fechaFin) == 24
                ? '2 años'
                : '${_mesesEntre(fechaInicio, fechaFin)} meses';
    final totalCuotas = row['total_cuotas'] as int? ?? 0;
    final pagadas = row['cuotas_pagadas'] as int? ?? 0;

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: activo
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          child: Icon(
            activo ? Icons.check : Icons.archive,
            color: activo ? scheme.primary : scheme.outline,
          ),
        ),
        title: Text(row['cliente'] as String),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${row['plan']} · ${Fmt.cordobas(row['precio_mensual'] as num)}'),
            Text(
              '$duracion · Día de pago: ${row['dia_pago']} · '
              'Cuotas: $pagadas/$totalCuotas',
              style: TextStyle(color: scheme.outline, fontSize: 12),
            ),
          ],
        ),
        trailing: row['cobrador'] != null
            ? Chip(
                label: Text(row['cobrador'] as String,
                    style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
              )
            : null,
        onTap: () => context.go('/admin/contratos/${row['id']}/editar'),
      ),
    );
  }

  int _mesesEntre(DateTime a, DateTime b) {
    return (b.year - a.year) * 12 + (b.month - a.month);
  }
}
