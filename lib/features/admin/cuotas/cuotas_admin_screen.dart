import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';

class CuotasAdminScreen extends ConsumerStatefulWidget {
  const CuotasAdminScreen({super.key});

  @override
  ConsumerState<CuotasAdminScreen> createState() => _CuotasAdminScreenState();
}

class _CuotasAdminScreenState extends ConsumerState<CuotasAdminScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String _estado = 'todas'; // todas / pendiente / parcial / pagada / anulada
  Timer? _debounce;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = v.trim().toLowerCase());
    });
  }

  @override
  Widget build(BuildContext context) {
    final diasGracia = ref.watch(appSettingsProvider).diasGracia;

    final where = <String>[];
    final params = <Object?>[];
    if (_query.isNotEmpty) {
      where.add('lower(c.nombre) LIKE ?');
      params.add('%$_query%');
    }
    if (_estado != 'todas') {
      where.add('cu.estado = ?');
      params.add(_estado);
    }
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _searchCtrl,
            onChanged: _onSearch,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Buscar por cliente',
            ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              for (final e in ['todas', 'pendiente', 'parcial', 'pagada', 'anulada']) ...[
                ChoiceChip(
                  label: Text(e[0].toUpperCase() + e.substring(1)),
                  selected: _estado == e,
                  onSelected: (_) => setState(() => _estado = e),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder(
            stream: ps.db.watch(
              '''
              SELECT cu.*, c.nombre AS cliente, p.nombre AS plan,
                     co.nombre AS cobrador
                FROM cuotas cu
                JOIN clientes c ON c.id = cu.cliente_id
                JOIN contratos ct ON ct.id = cu.contrato_id
                JOIN planes p ON p.id = ct.plan_id
           LEFT JOIN cobradores co ON co.id = cu.cobrador_id
               $whereSql
               ORDER BY cu.fecha_vencimiento DESC, c.nombre
               LIMIT 300
              ''',
              parameters: params,
            ),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows = snap.data!;
              if (rows.isEmpty) {
                return const EmptyState(
                  icon: Icons.receipt_long,
                  titulo: 'Sin cuotas',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, i) =>
                    _CuotaCard(row: rows[i], diasGracia: diasGracia),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CuotaCard extends ConsumerWidget {
  const _CuotaCard({required this.row, required this.diasGracia});
  final Map<String, dynamic> row;
  final int diasGracia;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final estado = row['estado'] as String;
    final monto = (row['monto'] as num).toDouble();
    final pagado = (row['monto_pagado'] as num? ?? 0).toDouble();
    final saldo = monto - pagado;
    final vence = DateTime.parse(row['fecha_vencimiento'] as String);
    final periodo = DateTime.parse(row['periodo'] as String);

    final (color, label) = _displayEstado(estado, vence, diasGracia, scheme);

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(_icon(estado, vence, diasGracia), color: color),
        ),
        title: Text(row['cliente'] as String),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${row['plan']} · ${Fmt.mes(periodo)[0].toUpperCase()}${Fmt.mes(periodo).substring(1)}',
              style: TextStyle(color: scheme.outline, fontSize: 12),
            ),
            Text('Vence ${Fmt.fechaCorta(vence)} · $label',
                style: TextStyle(color: color, fontSize: 12)),
            if (row['cobrador'] != null)
              Text('Cobrador: ${row['cobrador']}',
                  style: TextStyle(color: scheme.outline, fontSize: 11)),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(Fmt.cordobas(monto),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  decoration: estado == 'anulada' ? TextDecoration.lineThrough : null,
                )),
            if (estado != 'pagada' && estado != 'anulada' && pagado > 0)
              Text('Saldo: ${Fmt.cordobas(saldo)}',
                  style: TextStyle(color: scheme.outline, fontSize: 11)),
          ],
        ),
        onTap: estado != 'anulada' && estado != 'pagada'
            ? () => _accionesCuota(context, ref)
            : null,
      ),
    );
  }

  IconData _icon(String estado, DateTime vence, int dg) {
    if (estado == 'pagada') return Icons.check_circle;
    if (estado == 'anulada') return Icons.block;
    final diff = DateTime.now().difference(vence).inDays;
    if (diff > dg) return Icons.warning;
    if (diff > 0) return Icons.schedule;
    return Icons.event;
  }

  (Color, String) _displayEstado(
      String estado, DateTime vence, int dg, ColorScheme s) {
    if (estado == 'pagada') return (s.tertiary, 'Pagada');
    if (estado == 'anulada') return (s.outline, 'Anulada');
    final diff = DateTime.now().difference(vence).inDays;
    if (diff > dg) return (s.error, 'Vencida hace ${diff - dg} día(s)');
    if (diff > 0) return (s.tertiary, 'En gracia');
    if (diff == 0) return (s.primary, 'Vence hoy');
    return (s.outline, 'Al día');
  }

  Future<void> _accionesCuota(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.block),
              title: const Text('Anular cuota'),
              subtitle: const Text('No se podrá cobrar más'),
              onTap: () async {
                Navigator.pop(context);
                await _anular(context, ref);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _anular(BuildContext context, WidgetRef ref) async {
    final motivo = await showDialog<String?>(
      context: context,
      builder: (_) => const _AnularCuotaDialog(),
    );
    if (motivo == null || motivo.trim().isEmpty || !context.mounted) return;

    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;

    try {
      await ps.db.execute(
        '''
        UPDATE cuotas
           SET estado = 'anulada',
               anulada_en = ?,
               anulada_por = ?,
               motivo_anulacion = ?
         WHERE id = ?
        ''',
        [DateTime.now().toIso8601String(), me.id, motivo.trim(), row['id']],
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cuota anulada')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}

class _AnularCuotaDialog extends StatefulWidget {
  const _AnularCuotaDialog();
  @override
  State<_AnularCuotaDialog> createState() => _AnularCuotaDialogState();
}

class _AnularCuotaDialogState extends State<_AnularCuotaDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Anular cuota'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Esta acción se registra en auditoría. '
              'Los pagos ya aplicados a esta cuota no se modifican.'),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Motivo *',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            if (_ctrl.text.trim().isEmpty) return;
            Navigator.pop(context, _ctrl.text);
          },
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          child: const Text('Anular'),
        ),
      ],
    );
  }
}
