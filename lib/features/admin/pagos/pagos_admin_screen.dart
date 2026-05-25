import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/models/pago.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/pagos_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/cargar_mas_button.dart';
import '../../shared/widgets/empty_state.dart';

class PagosAdminScreen extends ConsumerStatefulWidget {
  const PagosAdminScreen({super.key});

  @override
  ConsumerState<PagosAdminScreen> createState() => _PagosAdminScreenState();
}

const int _kPageSize = 50;
const int _kSearchPageSize = 200;

class _PagosAdminScreenState extends ConsumerState<PagosAdminScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _verAnulados = false;
  Timer? _debounce;
  late Stream<List<Map<String, dynamic>>> _pagosStream;
  int _pageSize = _kPageSize;
  bool _loadingMore = false;
  Timer? _loadingMoreTimer;

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

    // LIMIT como último parámetro posicional.
    params.add(_pageSize);

    return ps.db.watch(
      '''
      SELECT p.id, p.monto_cordobas, p.moneda, p.monto_original,
             p.metodo, p.fecha_pago, p.referencia, p.notas,
             p.anulado, p.anulado_en, p.motivo_anulacion,
             p.grupo_cobro,
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
       LIMIT ?
      ''',
      parameters: params,
    );
  }

  int get _baseSize => _query.isEmpty ? _kPageSize : _kSearchPageSize;

  void _onLoadMore() {
    setState(() {
      _pageSize += _baseSize;
      _loadingMore = true;
      _pagosStream = _buildStream();
    });
    _loadingMoreTimer?.cancel();
    _loadingMoreTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _loadingMore = false);
    });
  }

  void _resetPagination() {
    _pageSize = _baseSize;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    _loadingMoreTimer?.cancel();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        setState(() {
          _query = v.trim().toLowerCase();
          _resetPagination();
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
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Buscar por cliente o número de recibo',
                    suffixIcon: _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() {
                                _query = '';
                                _resetPagination();
                                _pagosStream = _buildStream();
                              });
                            },
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilterChip(
                label: const Text('Ver anulados'),
                selected: _verAnulados,
                onSelected: (v) => setState(() {
                  _verAnulados = v;
                  _resetPagination();
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
              final hayMas = rows.length >= _pageSize;
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: rows.length + (hayMas ? 1 : 0),
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  if (i == rows.length) {
                    return CargarMasButton(
                      loading: _loadingMore,
                      onPressed: _onLoadMore,
                    );
                  }
                  return _PagoCard(row: rows[i]);
                },
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
                      MetodoPago.fromString(row['metodo'] as String).label,
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
                  if (row['grupo_cobro'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Cobro agrupado',
                          style: TextStyle(
                            color: scheme.onPrimaryContainer,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
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
            if (!anulado) ...[
              IconButton(
                icon: const Icon(Icons.edit),
                tooltip: 'Editar pago',
                onPressed: () => _editar(context, ref),
              ),
              IconButton(
                icon: const Icon(Icons.block),
                tooltip: 'Anular pago',
                onPressed: () => _anular(context, ref),
              ),
            ],
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

  Future<void> _editar(BuildContext context, WidgetRef ref) async {
    final resultado = await showDialog<_EditarPagoResult?>(
      context: context,
      builder: (_) => _EditarPagoDialog(
        montoActual: (row['monto_cordobas'] as num).toDouble(),
        metodoActual: MetodoPago.fromString(row['metodo'] as String),
        notasActuales: row['notas'] as String?,
      ),
    );
    if (resultado == null || !context.mounted) return;

    try {
      await ref.read(pagosRepoProvider).editarPago(
            pagoId: row['id'] as String,
            montoCordobas: resultado.monto,
            montoOriginal: resultado.monto,
            tasaConversion: 1.0,
            metodo: resultado.metodo,
            notas: resultado.notas,
            limpiarNotas: resultado.notas == null,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pago editado')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al editar: $e')),
        );
      }
    }
  }

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

/// Resultado de la edición de un pago (admin).
class _EditarPagoResult {
  const _EditarPagoResult({
    required this.monto,
    required this.metodo,
    this.notas,
  });
  final double monto;
  final MetodoPago metodo;
  final String? notas;
}

class _EditarPagoDialog extends StatefulWidget {
  const _EditarPagoDialog({
    required this.montoActual,
    required this.metodoActual,
    this.notasActuales,
  });
  final double montoActual;
  final MetodoPago metodoActual;
  final String? notasActuales;

  @override
  State<_EditarPagoDialog> createState() => _EditarPagoDialogState();
}

class _EditarPagoDialogState extends State<_EditarPagoDialog> {
  late final TextEditingController _montoCtrl;
  late final TextEditingController _notasCtrl;
  late MetodoPago _metodo;

  @override
  void initState() {
    super.initState();
    _montoCtrl = TextEditingController(
      text: widget.montoActual.toStringAsFixed(2),
    );
    _notasCtrl = TextEditingController(text: widget.notasActuales ?? '');
    _metodo = widget.metodoActual;
  }

  @override
  void dispose() {
    _montoCtrl.dispose();
    _notasCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Editar pago'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _montoCtrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Monto (C\$)',
              prefixText: 'C\$ ',
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<MetodoPago>(
            value: _metodo,
            decoration: const InputDecoration(labelText: 'Método de pago'),
            items: MetodoPago.values
                .map((m) => DropdownMenuItem(value: m, child: Text(m.label)))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _metodo = v);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _notasCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Notas (opcional)',
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
            final monto = double.tryParse(_montoCtrl.text);
            if (monto == null || monto <= 0) return;
            Navigator.pop(
              context,
              _EditarPagoResult(
                monto: monto,
                metodo: _metodo,
                notas: _notasCtrl.text.trim().isEmpty
                    ? null
                    : _notasCtrl.text.trim(),
              ),
            );
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
