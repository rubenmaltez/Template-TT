import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/pago.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/foto_comprobante_view.dart';

/// Preview visual del recibo + acción para imprimir.
/// La impresión Bluetooth real se conecta en una iteración siguiente.
class ReciboScreen extends ConsumerWidget {
  const ReciboScreen({super.key, required this.reciboId});
  final String reciboId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recibo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.home),
            onPressed: () => context.go('/'),
          ),
        ],
      ),
      body: StreamBuilder(
        stream: ps.db.watch(
          '''
          SELECT r.id, r.numero_completo, r.prefijo, r.correlativo,
                 r.created_at, r.impreso_en, r.reimpresiones,
                 p.monto_cordobas, p.moneda, p.monto_original,
                 p.tasa_conversion, p.metodo, p.referencia, p.fecha_pago,
                 p.foto_comprobante_path,
                 cu.periodo, cu.monto AS cuota_monto,
                 ct.dia_pago,
                 c.nombre AS cliente_nombre, c.cedula AS cliente_cedula,
                 pl.nombre AS plan_nombre,
                 co.nombre AS cobrador_nombre
            FROM recibos r
            JOIN pagos p     ON p.id = r.pago_id
            JOIN cuotas cu   ON cu.id = p.cuota_id
            JOIN clientes c  ON c.id = cu.cliente_id
            JOIN contratos ct ON ct.id = cu.contrato_id
            JOIN planes pl   ON pl.id = ct.plan_id
            JOIN cobradores co ON co.id = r.cobrador_id
           WHERE r.id = ?
          ''',
          parameters: [reciboId],
        ),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.data!.isEmpty) {
            return const EmptyState(
              icon: Icons.receipt_long,
              titulo: 'Recibo no encontrado',
            );
          }
          final r = snap.data!.first;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _ReciboTicket(row: r, settings: settings),
              if (r['foto_comprobante_path'] != null) ...[
                const SizedBox(height: 16),
                Text('Comprobante adjunto',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                FotoComprobanteView(
                    path: r['foto_comprobante_path'] as String?),
              ],
              const SizedBox(height: 24),
              _AccionesImpresion(reciboId: reciboId, settings: settings),
            ],
          );
        },
      ),
    );
  }
}

class _ReciboTicket extends StatelessWidget {
  const _ReciboTicket({required this.row, required this.settings});
  final Map<String, dynamic> row;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final emision = DateTime.parse(row['fecha_pago'] as String);
    final periodoCuota = DateTime.parse(row['periodo'] as String);
    final diaPago = (row['dia_pago'] as num).toInt();
    // Regla del 15 sobre día de pago del cliente, no fecha de emisión.
    final periodoLabel = Fmt.periodoRecibo(diaPago, periodoCuota);

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(20),
      child: DefaultTextStyle(
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.4,
          color: Colors.black87,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (settings.empresaNombre.isNotEmpty)
              Text(
                settings.empresaNombre.toUpperCase(),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            if (settings.empresaDireccion.isNotEmpty)
              Text(settings.empresaDireccion, textAlign: TextAlign.center),
            if (settings.empresaTelefono.isNotEmpty)
              Text('Tel: ${settings.empresaTelefono}'),
            if (settings.empresaRuc.isNotEmpty)
              Text('RUC: ${settings.empresaRuc}'),
            const Divider(),

            _ticketRow('Recibo Nº', row['numero_completo'] as String),
            _ticketRow('Fecha', Fmt.fechaCorta(emision)),
            _ticketRow('Hora', Fmt.hora(emision)),
            _ticketRow('Cobrador', row['cobrador_nombre'] as String),
            const Divider(),

            _ticketRow('Cliente', row['cliente_nombre'] as String),
            if (row['cliente_cedula'] != null)
              _ticketRow('Cédula', row['cliente_cedula'] as String),
            const Divider(),

            _ticketRow('Servicio', row['plan_nombre'] as String),
            _ticketRow('Período', periodoLabel[0].toUpperCase() + periodoLabel.substring(1)),
            _ticketRow('Cuota base', Fmt.cordobas(row['cuota_monto'] as num)),
            const Divider(),

            _ticketRow('Método',
                (row['metodo'] as String).toUpperCase()),
            if (row['referencia'] != null)
              _ticketRow('Ref.', row['referencia'] as String),
            if ((row['moneda'] as String) == 'USD')
              _ticketRow(
                'Recibido',
                'US\$${(row['monto_original'] as num).toStringAsFixed(2)} '
                    '(tasa ${(row['tasa_conversion'] as num).toStringAsFixed(2)})',
              ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('PAGADO',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                Text(
                  Fmt.cordobas(row['monto_cordobas'] as num),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ],
            ),

            if (settings.pieRecibo.isNotEmpty) ...[
              const Divider(),
              Text(settings.pieRecibo, textAlign: TextAlign.center),
            ],

            const SizedBox(height: 8),
            if (row['impreso_en'] != null)
              Text(
                'Reimpresión #${(row['reimpresiones'] as int? ?? 0) + 1}',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
          ],
        ),
      ),
    );
  }

  Widget _ticketRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 90, child: Text('$label:')),
        Expanded(child: Text(value, textAlign: TextAlign.right)),
      ],
    );
  }
}

class _AccionesImpresion extends StatelessWidget {
  const _AccionesImpresion({required this.reciboId, required this.settings});
  final String reciboId;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FilledButton.icon(
          icon: const Icon(Icons.print),
          label: Text('Imprimir (${settings.formatoReciboMm}mm)'),
          onPressed: () => _intentarImprimir(context, settings.formatoReciboMm),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.bluetooth),
          label: const Text('Configurar impresora'),
          onPressed: () => _intentarImprimir(context, null),
        ),
        const SizedBox(height: 16),
        Text(
          'La conexión Bluetooth ESC/POS se activa en próxima versión. '
          'Por ahora el recibo queda guardado y sincronizado.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  void _intentarImprimir(BuildContext context, int? formato) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Impresión Bluetooth — pendiente de implementar'),
      ),
    );
  }
}
