import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/pago.dart';
import '../../data/providers/impresora_provider.dart';
import '../../data/providers/logo_empresa_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../data/utils/monto_a_letras.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/foto_comprobante_view.dart';

/// Preview visual del recibo + acción para imprimir.
/// La impresión Bluetooth real se conecta en una iteración siguiente.
class ReciboScreen extends ConsumerStatefulWidget {
  const ReciboScreen({super.key, required this.reciboId, this.grupoCobro});
  final String reciboId;
  final String? grupoCobro;

  @override
  ConsumerState<ReciboScreen> createState() => _ReciboScreenState();
}

class _ReciboScreenState extends ConsumerState<ReciboScreen> {
  late final Stream<List<Map<String, dynamic>>> _reciboStream;

  bool get _esMultiCuota => widget.grupoCobro != null;

  @override
  void initState() {
    super.initState();
    if (_esMultiCuota) {
      _reciboStream = ps.db.watch(
        '''
        SELECT r.id, r.numero_completo, r.prefijo, r.correlativo,
               r.created_at, r.impreso_en, r.reimpresiones,
               p.monto_cordobas, p.moneda, p.monto_original,
               p.tasa_conversion, p.metodo, p.referencia, p.fecha_pago,
               p.foto_comprobante_path, p.grupo_cobro,
               cu.periodo, cu.monto AS cuota_monto,
               cu.monto_pagado AS monto_pagado_cuota,
               cu.cargos_neto,
               ct.dia_pago,
               c.nombre AS cliente_nombre, c.cedula AS cliente_cedula,
               pl.nombre AS plan_nombre,
               cu.descripcion AS cuota_descripcion,
               co.nombre AS cobrador_nombre
          FROM recibos r
          JOIN pagos p     ON p.id = r.pago_id
          JOIN cuotas cu   ON cu.id = p.cuota_id
          JOIN clientes c  ON c.id = cu.cliente_id
     LEFT JOIN contratos ct ON ct.id = cu.contrato_id
     LEFT JOIN planes pl   ON pl.id = ct.plan_id
          JOIN cobradores co ON co.id = r.cobrador_id
         WHERE p.grupo_cobro = ? AND p.anulado = 0
         ORDER BY cu.periodo ASC
        ''',
        parameters: [widget.grupoCobro],
      );
    } else {
      _reciboStream = ps.db.watch(
        '''
        SELECT r.id, r.numero_completo, r.prefijo, r.correlativo,
               r.created_at, r.impreso_en, r.reimpresiones,
               p.monto_cordobas, p.moneda, p.monto_original,
               p.tasa_conversion, p.metodo, p.referencia, p.fecha_pago,
               p.foto_comprobante_path,
               cu.periodo, cu.monto AS cuota_monto,
               cu.monto_pagado AS monto_pagado_cuota,
               cu.cargos_neto,
               ct.dia_pago,
               c.nombre AS cliente_nombre, c.cedula AS cliente_cedula,
               pl.nombre AS plan_nombre,
               cu.descripcion AS cuota_descripcion,
               co.nombre AS cobrador_nombre
          FROM recibos r
          JOIN pagos p     ON p.id = r.pago_id
          JOIN cuotas cu   ON cu.id = p.cuota_id
          JOIN clientes c  ON c.id = cu.cliente_id
     LEFT JOIN contratos ct ON ct.id = cu.contrato_id
     LEFT JOIN planes pl   ON pl.id = ct.plan_id
          JOIN cobradores co ON co.id = r.cobrador_id
         WHERE r.id = ?
        ''',
        parameters: [widget.reciboId],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    // Logo URL firmada. Solo se carga si `imprimirLogoEnRecibo` está
    // activo y hay un path configurado. El provider es reactivo: si
    // el admin cambia el logo en settings, se refresca.
    final logoUrl = settings.imprimirLogoEnRecibo
        ? ref.watch(logoEmpresaUrlProvider).valueOrNull
        : null;

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
        stream: _reciboStream,
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
          final rows = snap.data!;
          final r = rows.first;

          if (_esMultiCuota && rows.length > 1) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _MultiReciboTicket(rows: rows, settings: settings, logoUrl: logoUrl),
                if (r['foto_comprobante_path'] != null) ...[
                  const SizedBox(height: 16),
                  Text('Comprobante adjunto',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  FotoComprobanteView(
                      path: r['foto_comprobante_path'] as String?),
                ],
                const SizedBox(height: 24),
                _AccionesImpresion(
                  reciboId: widget.reciboId,
                  recibo: r,
                  settings: settings,
                ),
              ],
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _ReciboTicket(row: r, settings: settings, logoUrl: logoUrl),
              if (r['foto_comprobante_path'] != null) ...[
                const SizedBox(height: 16),
                Text('Comprobante adjunto',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                FotoComprobanteView(
                    path: r['foto_comprobante_path'] as String?),
              ],
              const SizedBox(height: 24),
              _AccionesImpresion(
                reciboId: widget.reciboId,
                recibo: r,
                settings: settings,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ReciboTicket extends StatelessWidget {
  const _ReciboTicket({
    required this.row,
    required this.settings,
    this.logoUrl,
  });
  final Map<String, dynamic> row;
  final AppSettings settings;

  /// URL firmada del logo. Null si no hay logo o si el toggle
  /// `recibo.imprimir_logo` está desactivado.
  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final emision = DateTime.parse(row['fecha_pago'] as String);
    final periodoCuota = DateTime.parse(row['periodo'] as String);
    final diaPago = (row['dia_pago'] as num?)?.toInt();
    final esManual = row['plan_nombre'] == null;
    // Regla del 15 sobre día de pago del cliente, no fecha de emisión.
    // Para cuotas manuales (sin contrato) mostramos el mes del periodo directamente.
    final periodoLabel = diaPago != null
        ? Fmt.periodoRecibo(diaPago, periodoCuota)
        : Fmt.mes(periodoCuota);

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
            // Logo de la empresa (si está configurado y el toggle activo).
            if (logoUrl != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Image.network(
                  logoUrl!,
                  height: 60,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
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

            _ticketRow('Servicio', esManual
                ? (row['cuota_descripcion'] as String? ?? 'Cuota manual')
                : row['plan_nombre'] as String),
            _ticketRow('Período', periodoLabel[0].toUpperCase() + periodoLabel.substring(1)),
            _ticketRow('Cuota base', Fmt.cordobas(row['cuota_monto'] as num)),

            // Cantidad en letras (si está habilitado en settings).
            if (settings.reciboMontoEnLetras)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  montoALetras(
                    (row['monto_cordobas'] as num).toDouble(),
                    moneda: (row['moneda'] as String?) ?? 'NIO',
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),

            const Divider(),

            _ticketRow('Método',
                MetodoPago.fromString(row['metodo'] as String).label.toUpperCase()),
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
            // Vuelto: si el monto pagado excede el saldo real de la cuota
            // (monto + cargos - ya pagado), mostrar la diferencia como
            // vuelto. Usa saldo ajustado (no cuota_monto base) para
            // que cargos extra no distorsionen el cálculo.
            Builder(builder: (_) {
              final montoPagado = (row['monto_cordobas'] as num).toDouble();
              final cuotaBase = (row['cuota_monto'] as num).toDouble();
              final cargosNeto = (row['cargos_neto'] as num?)?.toDouble() ?? 0;
              final saldoTotal = cuotaBase + cargosNeto;
              final vuelto = montoPagado - saldoTotal;
              if (vuelto <= 0.01) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('VUELTO',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.primary,
                        )),
                    Text(
                      Fmt.cordobas(vuelto),
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              );
            }),

            if (settings.pieRecibo.isNotEmpty) ...[
              const Divider(),
              Text(settings.pieRecibo, textAlign: TextAlign.center),
            ],

            const SizedBox(height: 8),
            if (row['impreso_en'] != null)
              Text(
                'Reimpresión #${(row['reimpresiones'] as int? ?? 0) + 1}',
                style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.outline),
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

class _MultiReciboTicket extends StatelessWidget {
  const _MultiReciboTicket({
    required this.rows,
    required this.settings,
    this.logoUrl,
  });
  final List<Map<String, dynamic>> rows;
  final AppSettings settings;
  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = rows.first;
    final emision = DateTime.parse(first['fecha_pago'] as String);
    var totalPagado = 0.0;
    for (final r in rows) {
      totalPagado += (r['monto_cordobas'] as num).toDouble();
    }

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
            if (logoUrl != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Image.network(
                  logoUrl!,
                  height: 60,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            if (settings.empresaNombre.isNotEmpty)
              Text(
                settings.empresaNombre.toUpperCase(),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            if (settings.empresaDireccion.isNotEmpty)
              Text(settings.empresaDireccion, textAlign: TextAlign.center),
            if (settings.empresaTelefono.isNotEmpty)
              Text('Tel: ${settings.empresaTelefono}'),
            if (settings.empresaRuc.isNotEmpty)
              Text('RUC: ${settings.empresaRuc}'),
            const Divider(),

            Text('COBRO MÚLTIPLE (${rows.length} cuotas)',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 4),
            _ticketRow('Recibos', '${rows.first['numero_completo']} - ${rows.last['numero_completo']}'),
            _ticketRow('Fecha', Fmt.fechaCorta(emision)),
            _ticketRow('Hora', Fmt.hora(emision)),
            _ticketRow('Cobrador', first['cobrador_nombre'] as String),
            const Divider(),

            _ticketRow('Cliente', first['cliente_nombre'] as String),
            if (first['cliente_cedula'] != null)
              _ticketRow('Cédula', first['cliente_cedula'] as String),
            const Divider(),

            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        '${Fmt.mes(DateTime.parse(r['periodo'] as String))[0].toUpperCase()}'
                        '${Fmt.mes(DateTime.parse(r['periodo'] as String)).substring(1)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    Text(Fmt.cordobas(r['monto_cordobas'] as num),
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),

            const Divider(),
            _ticketRow('Método', MetodoPago.fromString(first['metodo'] as String).label.toUpperCase()),
            if (first['referencia'] != null)
              _ticketRow('Ref.', first['referencia'] as String),

            if (settings.reciboMontoEnLetras)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  montoALetras(totalPagado,
                      moneda: (first['moneda'] as String?) ?? 'NIO'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),

            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('TOTAL PAGADO',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                Text(Fmt.cordobas(totalPagado),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ],
            ),

            if (settings.pieRecibo.isNotEmpty) ...[
              const Divider(),
              Text(settings.pieRecibo, textAlign: TextAlign.center),
            ],
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

class _AccionesImpresion extends ConsumerStatefulWidget {
  const _AccionesImpresion({
    required this.reciboId,
    required this.recibo,
    required this.settings,
  });
  final String reciboId;
  final Map<String, dynamic> recibo;
  final AppSettings settings;

  @override
  ConsumerState<_AccionesImpresion> createState() => _AccionesImpresionState();
}

class _AccionesImpresionState extends ConsumerState<_AccionesImpresion> {
  bool _imprimiendo = false;

  Future<void> _imprimir() async {
    final favState = ref.read(impresoraFavoritaProvider);
    // Si todavía no se leyó SharedPreferences, esperar y reintentar.
    if (!favState.hasValue) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cargando preferencias…')),
      );
      return;
    }
    final fav = favState.value;
    if (fav == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('No tenés impresora configurada'),
          action: SnackBarAction(
            label: 'Configurar',
            onPressed: () => context.push('/perfil/impresora'),
          ),
        ),
      );
      return;
    }

    setState(() => _imprimiendo = true);
    try {
      final service = ref.read(impresoraServiceProvider);
      final esReimpresion = widget.recibo['impreso_en'] != null;
      final ok = await service.imprimir(
        macImpresora: fav.mac,
        recibo: widget.recibo,
        empresa: {
          'nombre': widget.settings.empresaNombre,
          'direccion': widget.settings.empresaDireccion,
          'telefono': widget.settings.empresaTelefono,
          'ruc': widget.settings.empresaRuc,
        },
        anchoMm: widget.settings.formatoReciboMm,
        pieRecibo: widget.settings.pieRecibo,
        esReimpresion: esReimpresion,
      );

      if (!mounted) return;
      if (ok) {
        // Actualizar BD local: impreso_en + reimpresiones + formato.
        await ps.db.execute(
          '''
          UPDATE recibos
             SET impreso_en = ?,
                 reimpresiones = reimpresiones + ?,
                 ultimo_formato_mm = ?
           WHERE id = ?
          ''',
          [
            DateTime.now().toIso8601String(),
            esReimpresion ? 1 : 0,
            widget.settings.formatoReciboMm,
            widget.reciboId,
          ],
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recibo enviado a impresora')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo conectar a la impresora')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _imprimiendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fav = ref.watch(impresoraFavoritaProvider).valueOrNull;
    final puedeImprimir = !kIsWeb;
    return Column(
      children: [
        if (kIsWeb)
          FilledButton.icon(
            icon: const Icon(Icons.print_disabled),
            label: const Text('Imprimir (sólo disponible en mobile)'),
            onPressed: null,
          )
        else
          FilledButton.icon(
            icon: _imprimiendo
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.print),
            label: Text(_imprimiendo
                ? 'Enviando...'
                : 'Imprimir ${widget.settings.formatoReciboMm}mm'),
            onPressed: _imprimiendo || !puedeImprimir ? null : _imprimir,
          ),
        const SizedBox(height: 8),
        if (!kIsWeb)
          OutlinedButton.icon(
            icon: const Icon(Icons.bluetooth_searching),
            label: Text(fav == null
                ? 'Configurar impresora'
                : 'Cambiar impresora (${fav.nombre})'),
            onPressed: () => context.push('/perfil/impresora'),
          ),
        const SizedBox(height: 16),
        Text(
          'El recibo queda guardado y sincronizado aunque la impresora '
          'falle. Podés reintentar imprimir cuando quieras.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
