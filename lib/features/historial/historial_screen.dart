import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/pago.dart';
import '../../data/providers/cobrador_provider.dart';
import '../../data/repositories/pagos_repo.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';

class HistorialScreen extends ConsumerStatefulWidget {
  const HistorialScreen({super.key});

  @override
  ConsumerState<HistorialScreen> createState() => _HistorialScreenState();
}

class _HistorialScreenState extends ConsumerState<HistorialScreen> {
  // Cacheamos el stream de PowerSync en initState para evitar que cada
  // rebuild cree una nueva suscripción (anti-patrón ps.db.watch inline).
  late final Stream<List<Map<String, dynamic>>> _historialStream;

  @override
  void initState() {
    super.initState();
    _historialStream = ps.db.watch(
      '''
      SELECT p.id, p.monto_cordobas, p.moneda, p.monto_original,
             p.metodo, p.fecha_pago, p.notas,
             c.nombre AS cliente_nombre,
             r.id AS recibo_id, r.numero_completo
        FROM pagos p
        JOIN cuotas cu ON cu.id = p.cuota_id
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN recibos r ON r.pago_id = p.id AND r.anulado = 0
       WHERE p.anulado = 0
       ORDER BY p.fecha_pago DESC
       LIMIT 100
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _historialStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.history,
            titulo: 'Sin cobros aún',
            descripcion: 'Tus cobros van a aparecer acá.',
          );
        }
        final byDay = groupBy<Map<String, dynamic>, String>(
          rows,
          (r) => (r['fecha_pago'] as String).substring(0, 10),
        );

        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 80),
          itemCount: byDay.length,
          itemBuilder: (_, i) {
            final entry = byDay.entries.elementAt(i);
            final dia = DateTime.parse(entry.key);
            final total = entry.value.fold<double>(
              0,
              (sum, r) => sum + (r['monto_cordobas'] as num).toDouble(),
            );
            return _GrupoDia(
              dia: dia,
              total: total,
              pagos: entry.value,
            );
          },
        );
      },
    );
  }
}

class _GrupoDia extends ConsumerWidget {
  const _GrupoDia({required this.dia, required this.total, required this.pagos});
  final DateTime dia;
  final double total;
  final List<Map<String, dynamic>> pagos;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(appSettingsProvider);
    final puedeAnular = settings.cobradorAnulaCobros;
    final puedeEditar = settings.cobradorEditaCobros;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Row(
              children: [
                Text(
                  Fmt.fechaRelativa(dia),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Text(
                  Fmt.fechaCorta(dia),
                  style: TextStyle(color: scheme.outline, fontSize: 12),
                ),
                const Spacer(),
                Text(
                  Fmt.cordobas(total),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              children: pagos.mapIndexed((i, p) => Column(
                    children: [
                      if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        dense: true,
                        leading: Icon(_iconForMethod(p['metodo'] as String)),
                        title: Text(p['cliente_nombre'] as String),
                        subtitle: Text(
                          [
                            (p['metodo'] as String),
                            if (p['numero_completo'] != null) p['numero_completo'],
                          ].join(' · '),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              Fmt.cordobas(p['monto_cordobas'] as num),
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            if (puedeEditar) ...[
                              const SizedBox(width: 4),
                              IconButton(
                                icon: Icon(Icons.edit, size: 20, color: scheme.primary),
                                tooltip: 'Editar pago',
                                onPressed: () => _editar(context, ref, p),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              ),
                            ],
                            if (puedeAnular) ...[
                              const SizedBox(width: 4),
                              IconButton(
                                icon: Icon(Icons.block, size: 20, color: scheme.error),
                                tooltip: 'Anular pago',
                                onPressed: () => _anular(context, ref, p),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              ),
                            ],
                          ],
                        ),
                        onTap: p['recibo_id'] != null
                            ? () => context.push('/recibo/${p['recibo_id']}')
                            : null,
                      ),
                    ],
                  )).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editar(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> pago,
  ) async {
    final resultado = await showDialog<_EditarCobroResult?>(
      context: context,
      builder: (_) => _EditarCobroDialog(
        montoActual: (pago['monto_cordobas'] as num).toDouble(),
        metodoActual: MetodoPago.fromString(pago['metodo'] as String),
        notasActuales: pago['notas'] as String?,
      ),
    );
    if (resultado == null || !context.mounted) return;

    try {
      await ref.read(pagosRepoProvider).editarPago(
            pagoId: pago['id'] as String,
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

  Future<void> _anular(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> pago,
  ) async {
    final motivo = await showDialog<String?>(
      context: context,
      builder: (_) => const _AnularCobroDialog(),
    );
    if (motivo == null || motivo.trim().isEmpty || !context.mounted) return;

    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;

    try {
      await ref.read(pagosRepoProvider).anularPago(
            pagoId: pago['id'] as String,
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
          SnackBar(content: Text('Error al anular: $e')),
        );
      }
    }
  }

  IconData _iconForMethod(String m) => switch (m) {
        'efectivo' => Icons.payments,
        'transferencia' => Icons.swap_horiz,
        'deposito' => Icons.account_balance,
        'tarjeta' => Icons.credit_card,
        _ => Icons.payments,
      };
}

/// Resultado de la edición de un cobro.
class _EditarCobroResult {
  const _EditarCobroResult({
    required this.monto,
    required this.metodo,
    this.notas,
  });
  final double monto;
  final MetodoPago metodo;
  final String? notas;
}

class _EditarCobroDialog extends StatefulWidget {
  const _EditarCobroDialog({
    required this.montoActual,
    required this.metodoActual,
    this.notasActuales,
  });
  final double montoActual;
  final MetodoPago metodoActual;
  final String? notasActuales;

  @override
  State<_EditarCobroDialog> createState() => _EditarCobroDialogState();
}

class _EditarCobroDialogState extends State<_EditarCobroDialog> {
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
              _EditarCobroResult(
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

class _AnularCobroDialog extends StatefulWidget {
  const _AnularCobroDialog();
  @override
  State<_AnularCobroDialog> createState() => _AnularCobroDialogState();
}

class _AnularCobroDialogState extends State<_AnularCobroDialog> {
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
