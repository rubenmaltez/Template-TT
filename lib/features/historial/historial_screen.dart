import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';

class HistorialScreen extends ConsumerWidget {
  const HistorialScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder(
      stream: ps.db.watch(
        '''
        SELECT p.id, p.monto_cordobas, p.moneda, p.monto_original,
               p.metodo, p.fecha_pago,
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
      ),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
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

class _GrupoDia extends StatelessWidget {
  const _GrupoDia({required this.dia, required this.total, required this.pagos});
  final DateTime dia;
  final double total;
  final List<Map<String, dynamic>> pagos;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
                        trailing: Text(
                          Fmt.cordobas(p['monto_cordobas'] as num),
                          style: const TextStyle(fontWeight: FontWeight.w600),
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

  IconData _iconForMethod(String m) => switch (m) {
        'efectivo' => Icons.payments,
        'transferencia' => Icons.swap_horiz,
        'deposito' => Icons.account_balance,
        'tarjeta' => Icons.credit_card,
        _ => Icons.payments,
      };
}
