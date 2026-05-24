import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/pagos_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';

class PagosAdminScreen extends ConsumerStatefulWidget {
  const PagosAdminScreen({super.key});

  @override
  ConsumerState<PagosAdminScreen> createState() => _PagosAdminScreenState();
}

class _PagosAdminScreenState extends ConsumerState<PagosAdminScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _verAnulados = false;
  Timer? _debounce;
  late Stream<List<Map<String, dynamic>>> _pagosStream;

  @override
  void initState() {
    super.initState();
    _pagosStream = _buildStream();
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    final where = <String>[];
    final params = <Object?>[];
    if (!_verAnulados) where.add('p.anulado = 0');
    if (_query.isNotEmpty) {
      where.add('(lower(c.nombre) LIKE ? OR r.numero_completo LIKE ?)');
      final like = '%$_query%';
      params..add(like)..add(like);
    }
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';

    return ps.db.watch(
      '''
      SELECT p.id, p.monto_cordobas, p.moneda, p.monto_original,
             p.metodo, p.fecha_pago, p.referencia,
             p.anulado, p.anulado_en, p.motivo_anulacion,
             c.nombre AS cliente,
             co.nombre AS cobrador,
             r.numero_completo
        FROM pagos p
        JOIN cuotas cu ON cu.id = p.cuota_id
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN cobradores co ON co.id = p.cobrador_id
   LEFT JOIN recibos r ON r.pago_id = p.id
       $whereSql
       ORDER BY p.fecha_pago DESC
       LIMIT 300
      ''',
      parameters: params,
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        setState(() {
          _query = v.trim().toLowerCase();
          _pagosStream = _buildStream();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearch,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Buscar por cliente o número de recibo',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilterChip(
                label: const Text('Ver anulados'),
                selected: _verAnulados,
                onSelected: (v) => setState(() {
                  _verAnulados = v;
                  _pagosStream = _buildStream();
                }),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder(
            stream: _pagosStream,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows = snap.data!;
              if (rows.isEmpty) {
                return const EmptyState(
                  icon: Icons.payments_outlined,
                  titulo: 'Sin pagos',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _PagoCard(row: rows[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PagoCard extends ConsumerWidget {
  const _PagoCard({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final anulado = (row['anulado'] as int? ?? 0) == 1;
    final fecha = DateTime.parse(row['fecha_pago'] as String);

    return Card(
      color: anulado ? scheme.surfaceContainerHighest.withValues(alpha: 0.5) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: anulado
                  ? scheme.outlineVariant
                  : scheme.primaryContainer,
              child: Icon(
                anulado ? Icons.block : _iconMetodo(row['metodo'] as String),
                color: anulado ? scheme.outline : scheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          row['cliente'] as String,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            decoration: anulado ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                      Text(
                        Fmt.cordobas(row['monto_cordobas'] as num),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          decoration: anulado ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      row['numero_completo'] ?? '—',
                      (row['metodo'] as String),
                      Fmt.fechaCorta(fecha),
                      if (row['cobrador'] != null) row['cobrador'],
                    ].join(' · '),
                    style: TextStyle(color: scheme.outline, fontSize: 12),
                  ),
                  if ((row['moneda'] as String) == 'USD')
                    Text(
                      'Pagado en USD: ${(row['monto_original'] as num).toStringAsFixed(2)}',
                      style: TextStyle(color: scheme.outline, fontSize: 12),
                    ),
                  if (anulado && row['motivo_anulacion'] != null) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Anulado: ${row['motivo_anulacion']}',
                        style: TextStyle(color: scheme.error, fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!anulado)
              IconButton(
                icon: const Icon(Icons.block),
                tooltip: 'Anular pago',
                onPressed: () => _anular(context, ref),
              ),
          ],
        ),
      ),
    );
  }

  IconData _iconMetodo(String m) => switch (m) {
        'efectivo' => Icons.payments,
        'transferencia' => Icons.swap_horiz,
        'deposito' => Icons.account_balance,
        'tarjeta' => Icons.credit_card,
        _ => Icons.payments,
      };

  Future<void> _anular(BuildContext context, WidgetRef ref) async {
    final motivo = await showDialog<String?>(
      context: context,
      builder: (_) => const _AnularDialog(),
    );
    if (motivo == null || motivo.trim().isEmpty || !context.mounted) return;

    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;

    try {
      await ref.read(pagosRepoProvider).anularPago(
            pagoId: row['id'] as String,
            anuladoPorId: me.id,
            motivo: motivo.trim(),
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pago anulado')),
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

class _AnularDialog extends StatefulWidget {
  const _AnularDialog();
  @override
  State<_AnularDialog> createState() => _AnularDialogState();
}

class _AnularDialogState extends State<_AnularDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Anular pago'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
              'Esta acción queda registrada en auditoría. La cuota volverá '
              'a su estado anterior. El recibo emitido queda inválido.'),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Motivo de anulación *',
              hintText: 'Ej. Monto incorrecto, registrado por error...',
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
