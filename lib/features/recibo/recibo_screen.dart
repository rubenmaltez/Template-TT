import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:printing/printing.dart';

import '../../data/models/pago.dart';
import '../../data/models/recibo_layout.dart';
import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/impresora_provider.dart';
import '../../data/providers/logo_empresa_provider.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../data/utils/monto_a_letras.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/foto_comprobante_view.dart';
import '../shared/widgets/impersonation_banner.dart';
import 'recibo_mora.dart';
import 'recibo_pdf.dart';

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

  // Vista preview: si está activa, el body del recibo se constraine al
  // ancho visual de la tira térmica (según `cobranza.formato_recibo_mm`).
  // El recibo se muestra SIEMPRE simulando el ancho real del papel
  // térmico (80mm/57mm). Sin toggle: la vista preview es permanente.

  bool get _esMultiCuota => widget.grupoCobro != null;

  /// Ancho en píxeles para simular la tira térmica.
  /// 80mm ≈ 300px, 57mm ≈ 215px.
  double _previewWidthPx(int formatoMm) {
    if (formatoMm == 57) return 215;
    return 300;
  }

  @override
  void initState() {
    super.initState();
    if (_esMultiCuota) {
      _reciboStream = ps.db.watch(
        '''
        SELECT r.id, r.numero_completo, r.prefijo, r.correlativo,
               r.created_at, r.impreso_en, r.reimpresiones,
               p.monto_cordobas, p.vuelto_cordobas, p.moneda, p.monto_original,
               p.tasa_conversion, p.metodo, p.referencia, p.fecha_pago,
               p.foto_comprobante_path, p.grupo_cobro,
               cu.id AS cuota_id, cu.contrato_id,
               cu.periodo, cu.monto AS cuota_monto,
               cu.monto_pagado AS monto_pagado_cuota,
               cu.cargos_neto,
               ct.dia_pago,
               c.id AS cliente_id, c.nombre AS cliente_nombre, c.cedula AS cliente_cedula,
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
               p.monto_cordobas, p.vuelto_cordobas, p.moneda, p.monto_original,
               p.tasa_conversion, p.metodo, p.referencia, p.fecha_pago,
               p.foto_comprobante_path,
               cu.id AS cuota_id, cu.contrato_id,
               cu.periodo, cu.monto AS cuota_monto,
               cu.monto_pagado AS monto_pagado_cuota,
               cu.cargos_neto,
               ct.dia_pago,
               c.id AS cliente_id, c.nombre AS cliente_nombre, c.cedula AS cliente_cedula,
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
    // Logo URL firmada. Una sola fuente de verdad: el bloque `logo` del
    // layout del recibo. Solo se carga si ese bloque está visible (y hay
    // un path configurado). El provider es reactivo: si el admin cambia el
    // logo o la visibilidad del bloque en settings, se refresca.
    final logoVisible =
        settings.reciboLayout.any((b) => b.id == 'logo' && b.visible);
    final logoUrl =
        logoVisible ? ref.watch(logoEmpresaUrlProvider).valueOrNull : null;

    // Rol del usuario: el admin navega DENTRO del AdminShell (con panel
    // lateral); el cobrador a sus rutas full-screen. Sin esto, "home" y "ver
    // detalle del cliente" mandaban al admin a las rutas del cobrador (/ y
    // /clientes/:id), que viven fuera del shell → quedaba sin menú izquierdo.
    final esAdmin =
        ref.watch(cobradorActualProvider).valueOrNull?.tieneAccesoAdmin ?? false;
    final maxWidth = _previewWidthPx(settings.formatoReciboMm);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recibo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.home),
            onPressed: () => context.go(esAdmin ? '/admin' : '/'),
          ),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _reciboStream,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) {
            return const EmptyState(
              icon: Icons.error_outline,
              titulo: 'Error al cargar el recibo',
            );
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
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const ImpersonationBanner(), // #9a
                    _MultiReciboTicket(
                        rows: rows, settings: settings, logoUrl: logoUrl),
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
                      logoUrl: logoUrl,
                      multiRows: rows,
                    ),
                    const SizedBox(height: 16),
                    _PostCobroActions(clienteId: r['cliente_id'] as String?),
                  ],
                ),
              ),
            );
          }

          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const ImpersonationBanner(), // #9a
                  ReciboTicket(row: r, settings: settings, logoUrl: logoUrl),
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
                    logoUrl: logoUrl,
                  ),
                  const SizedBox(height: 16),
                  _PostCobroActions(clienteId: r['cliente_id'] as String?),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Ticket visual de un recibo de cobro single-cuota. Público para reusarlo en
/// la vista previa del diseñador de recibos en settings (#8a).
///
/// `ConsumerWidget` (no `StatelessWidget`) porque el bloque `mora` necesita
/// `ref.watch(moraContratoProvider)` para listar los meses en mora del contrato.
class ReciboTicket extends ConsumerWidget {
  const ReciboTicket({
    super.key,
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
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    // Se ITERA el layout configurable: cada bloque se construye en
    // `_buildBloque` (devuelve [] si no hay nada que mostrar) y entre bloques
    // se emite un separador (gap chico entre dos bloques de header, Divider en
    // el resto). El contenido/orden lo manda `settings.reciboLayout`; el bloque
    // `totales` (dinero) sigue intacto, solo cambia su posición.
    final children = <Widget>[];
    String? zonaPrev;
    for (final b in settings.reciboLayout) {
      if (!b.visible) continue;
      final contenido = _buildBloque(context, ref, b.id, _scaleDe(b.size));
      if (contenido.isEmpty) continue;
      final zona = reciboBloqueInfo(b.id)?.zona ?? ReciboZona.body;
      if (children.isNotEmpty) {
        // Entre dos bloques de header: gap chico (sin divider). Resto: Divider.
        if (zonaPrev == 'header' && zona == ReciboZona.header) {
          children.add(const SizedBox(height: 4));
        } else {
          children.add(const Divider());
        }
      }
      children.addAll(contenido);
      zonaPrev = zona == ReciboZona.header ? 'header' : 'otro';
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
            ...children,
            // Badge de reimpresión: NO es un bloque del layout, va SIEMPRE al
            // final (es metadata de la impresión, no del contenido).
            if (row['impreso_en'] != null) ...[
              const SizedBox(height: 8),
              Text(
                'Reimpresión #${(row['reimpresiones'] as int? ?? 0) + 1}',
                style: TextStyle(
                    fontSize: 10, color: scheme.outline),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Multiplicador de fontSize según el tamaño del bloque (chico/normal/grande).
  double _scaleDe(ReciboTextoSize s) => switch (s) {
        ReciboTextoSize.chico => 0.85,
        ReciboTextoSize.grande => 1.3,
        ReciboTextoSize.normal => 1.0,
      };

  /// Construye las líneas de UN bloque del recibo single. Devuelve [] si el
  /// bloque no tiene nada que mostrar (logo null, empresa toda vacía, pie
  /// vacío, etc.) — el loop del build salta los vacíos y su separador.
  List<Widget> _buildBloque(
      BuildContext context, WidgetRef ref, String id, double k) {
    switch (id) {
      case 'logo':
        if (logoUrl == null) return const [];
        return [
          Image.network(
            logoUrl!,
            height: 60 * k,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ];
      case 'empresa':
        final out = <Widget>[];
        if (settings.empresaNombre.isNotEmpty) {
          out.add(Text(
            settings.empresaNombre.toUpperCase(),
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16 * k),
            textAlign: TextAlign.center,
          ));
        }
        if (settings.empresaDireccion.isNotEmpty) {
          out.add(Text(settings.empresaDireccion,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13 * k)));
        }
        if (settings.empresaTelefono.isNotEmpty) {
          out.add(Text('Tel: ${settings.empresaTelefono}',
              style: TextStyle(fontSize: 13 * k)));
        }
        if (settings.empresaRuc.isNotEmpty) {
          out.add(Text('RUC: ${settings.empresaRuc}',
              style: TextStyle(fontSize: 13 * k)));
        }
        return out;
      case 'titulo':
        if (settings.reciboTitulo.isEmpty) return const [];
        return [
          Text(
            settings.reciboTitulo.toUpperCase(),
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14 * k),
            textAlign: TextAlign.center,
          ),
        ];
      case 'meta':
        final emision = DateTime.parse(row['fecha_pago'] as String);
        return [
          _ticketRow('Recibo Nº', row['numero_completo'] as String, k),
          _ticketRow('Fecha', Fmt.fechaCorta(emision), k),
          _ticketRow('Hora', Fmt.hora(emision), k),
          _ticketRow('Cobrador', row['cobrador_nombre'] as String, k),
        ];
      case 'cliente':
        return [
          _ticketRow('Cliente', row['cliente_nombre'] as String, k),
          if (settings.reciboMostrarCedula && row['cliente_cedula'] != null)
            _ticketRow('Cédula', row['cliente_cedula'] as String, k),
        ];
      case 'servicio':
        final periodoCuota = DateTime.parse(row['periodo'] as String);
        final diaPago = (row['dia_pago'] as num?)?.toInt();
        final esManual = row['plan_nombre'] == null;
        // Regla del 15 sobre día de pago del cliente, no fecha de emisión.
        // Cuotas manuales (sin contrato): mes del periodo directo.
        final periodoLabel = diaPago != null
            ? Fmt.periodoRecibo(diaPago, periodoCuota)
            : Fmt.mes(periodoCuota);
        return [
          _ticketRow(
              'Servicio',
              esManual
                  ? (row['cuota_descripcion'] as String? ?? 'Cuota manual')
                  : row['plan_nombre'] as String,
              k),
          _ticketRow('Período',
              periodoLabel[0].toUpperCase() + periodoLabel.substring(1), k),
        ];
      case 'cuota':
        // Saldo de la cuota tras este pago (sub-toggle `mostrar_adeudado`).
        final saldoCuota = ((row['cuota_monto'] as num).toDouble() +
                (row['cargos_neto'] as num? ?? 0).toDouble()) -
            (row['monto_pagado_cuota'] as num? ?? row['monto_cordobas'] as num)
                .toDouble();
        return [
          _ticketRow('Cuota base', Fmt.cordobas(row['cuota_monto'] as num), k),
          if (settings.reciboMostrarAdeudado && saldoCuota > 0.01)
            _ticketRow('Saldo cuota', Fmt.cordobas(saldoCuota), k),
        ];
      case 'metodo':
        return [
          _ticketRow(
              'Método',
              MetodoPago.fromString(row['metodo'] as String)
                  .label
                  .toUpperCase(),
              k),
          if (row['referencia'] != null)
            _ticketRow('Ref.', row['referencia'] as String, k),
          if ((row['moneda'] as String) == 'USD')
            _ticketRow(
              'Recibido',
              'US\$${(row['monto_original'] as num).toStringAsFixed(2)} '
                  '(tasa ${(row['tasa_conversion'] as num).toStringAsFixed(2)})',
              k,
            ),
        ];
      case 'letras':
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              montoALetras(
                (row['monto_cordobas'] as num).toDouble(),
                moneda: (row['moneda'] as String?) ?? 'NIO',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11 * k, fontWeight: FontWeight.w600),
            ),
          ),
        ];
      case 'totales':
        // EL BLOQUE DE DINERO. Matemática y contenido IDÉNTICOS al original:
        // COBRADO siempre, + VUELTO/PAGADO si hubo vuelto (con manejo USD).
        // Solo cambió su posición (la da el layout).
        final scheme = Theme.of(context).colorScheme;
        final vuelto = (row['vuelto_cordobas'] as num? ?? 0).toDouble();
        final cobrado = (row['monto_cordobas'] as num).toDouble();
        final entregado = cobrado + vuelto;
        final esUsd = (row['moneda'] as String) == 'USD';
        return [
          // COBRADO = monto aplicado a la cuota (lo que entra a la caja).
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('COBRADO',
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 15 * k)),
              Text(
                Fmt.cordobas(row['monto_cordobas'] as num),
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15 * k),
              ),
            ],
          ),
          // VUELTO + PAGADO: si hubo vuelto, mostrar ambos. Si no, solo
          // COBRADO es suficiente (PAGADO == COBRADO en ese caso).
          if (vuelto > 0.01) ...[
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    esUsd ? 'VUELTO (en C\$)' : 'VUELTO',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13 * k,
                      color: scheme.primary,
                    ),
                  ),
                  Text(
                    Fmt.cordobas(vuelto),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13 * k,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('PAGADO',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14 * k,
                      )),
                  Text(
                    esUsd
                        ? 'US\$${(row['monto_original'] as num).toStringAsFixed(2)} = ${Fmt.cordobas(entregado)}'
                        : Fmt.cordobas(entregado),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14 * k,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ];
      case 'mora':
        // Detalle de mora del MISMO contrato: meses pendiente/parcial pasados
        // de gracia, excluyendo la cuota recién cobrada en este recibo. NO es
        // dinero del comprobante (no toca la matemática de `cuota`/`totales`):
        // es un resumen informativo de lo que el cliente aún debe del contrato.
        final contratoId = row['contrato_id'] as String?;
        if (contratoId == null) return const []; // cuota manual: sin contrato
        final mora = (ref
                    .watch(moraContratoProvider((
                      contratoId: contratoId,
                      diasGracia: settings.diasGracia,
                    )))
                    .valueOrNull ??
                const [])
            .where((m) => m['cuota_id'] != row['cuota_id'])
            .toList();
        if (mora.isEmpty) return const [];
        final totalMora = mora.fold<double>(
            0, (s, m) => s + (m['saldo'] as num).toDouble());
        return [
          Text('EN MORA',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13 * k),
              textAlign: TextAlign.center),
          const SizedBox(height: 2),
          for (final m in mora)
            _ticketRow(
              Fmt.mes(DateTime.parse(m['periodo'] as String)),
              Fmt.cordobas(m['saldo'] as num),
              k,
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('TOTAL MORA',
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 13 * k)),
              Text(Fmt.cordobas(totalMora),
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 13 * k)),
            ],
          ),
        ];
      case 'pie':
        if (settings.pieRecibo.isEmpty) return const [];
        return [
          Text(settings.pieRecibo,
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13 * k)),
        ];
      case 'whatsapp':
        if (settings.empresaWhatsapp.isEmpty) return const [];
        return [
          Text('WhatsApp: ${settings.empresaWhatsapp}',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13 * k)),
        ];
      default:
        return const [];
    }
  }

  Widget _ticketRow(String label, String value, [double k = 1]) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
            width: 90,
            child: Text('$label:', style: TextStyle(fontSize: 13 * k))),
        Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 13 * k))),
      ],
    );
  }
}

/// `ConsumerWidget` (no `StatelessWidget`) porque el bloque `mora` necesita
/// `ref.watch(moraContratoProvider)` para listar los meses en mora del contrato.
class _MultiReciboTicket extends ConsumerWidget {
  const _MultiReciboTicket({
    required this.rows,
    required this.settings,
    this.logoUrl,
  });
  final List<Map<String, dynamic>> rows;
  final AppSettings settings;
  final String? logoUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    // Se ITERA el MISMO layout configurable que el recibo single. Los ids
    // mapean a su contenido MULTI (lista de N cuotas, totales sumados, etc.).
    // El bloque `totales` (dinero) mantiene su matemática IDÉNTICA; solo cambia
    // su posición (la da el layout).
    final children = <Widget>[];
    String? zonaPrev;
    for (final b in settings.reciboLayout) {
      if (!b.visible) continue;
      final contenido = _buildBloque(context, ref, b.id, _scaleDe(b.size));
      if (contenido.isEmpty) continue;
      final zona = reciboBloqueInfo(b.id)?.zona ?? ReciboZona.body;
      if (children.isNotEmpty) {
        // Entre dos bloques de header: gap chico (sin divider). Resto: Divider.
        if (zonaPrev == 'header' && zona == ReciboZona.header) {
          children.add(const SizedBox(height: 4));
        } else {
          children.add(const Divider());
        }
      }
      children.addAll(contenido);
      zonaPrev = zona == ReciboZona.header ? 'header' : 'otro';
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
          children: children,
        ),
      ),
    );
  }

  /// Multiplicador de fontSize según el tamaño del bloque (chico/normal/grande).
  /// Idéntico al del recibo single — la térmica mapea aparte.
  double _scaleDe(ReciboTextoSize s) => switch (s) {
        ReciboTextoSize.chico => 0.85,
        ReciboTextoSize.grande => 1.3,
        ReciboTextoSize.normal => 1.0,
      };

  /// Construye las líneas de UN bloque del recibo MULTI. Devuelve [] si el
  /// bloque no tiene nada que mostrar. El bloque `servicio` va vacío en multi
  /// (la lista de cuotas del bloque `cuota` ya lo cubre).
  List<Widget> _buildBloque(
      BuildContext context, WidgetRef ref, String id, double k) {
    final first = rows.first;
    switch (id) {
      case 'logo':
        if (logoUrl == null) return const [];
        return [
          Image.network(
            logoUrl!,
            height: 60 * k,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ];
      case 'empresa':
        final out = <Widget>[];
        if (settings.empresaNombre.isNotEmpty) {
          out.add(Text(
            settings.empresaNombre.toUpperCase(),
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16 * k),
            textAlign: TextAlign.center,
          ));
        }
        if (settings.empresaDireccion.isNotEmpty) {
          out.add(Text(settings.empresaDireccion,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13 * k)));
        }
        if (settings.empresaTelefono.isNotEmpty) {
          out.add(Text('Tel: ${settings.empresaTelefono}',
              style: TextStyle(fontSize: 13 * k)));
        }
        if (settings.empresaRuc.isNotEmpty) {
          out.add(Text('RUC: ${settings.empresaRuc}',
              style: TextStyle(fontSize: 13 * k)));
        }
        return out;
      case 'titulo':
        if (settings.reciboTitulo.isEmpty) return const [];
        return [
          Text(
            settings.reciboTitulo.toUpperCase(),
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14 * k),
            textAlign: TextAlign.center,
          ),
        ];
      case 'meta':
        final emision = DateTime.parse(first['fecha_pago'] as String);
        return [
          Text('COBRO MÚLTIPLE (${rows.length} cuotas)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14 * k)),
          const SizedBox(height: 4),
          _ticketRow('Recibos',
              '${rows.first['numero_completo']} - ${rows.last['numero_completo']}',
              k),
          _ticketRow('Fecha', Fmt.fechaCorta(emision), k),
          _ticketRow('Hora', Fmt.hora(emision), k),
          _ticketRow('Cobrador', first['cobrador_nombre'] as String, k),
        ];
      case 'cliente':
        return [
          _ticketRow('Cliente', first['cliente_nombre'] as String, k),
          if (settings.reciboMostrarCedula && first['cliente_cedula'] != null)
            _ticketRow('Cédula', first['cliente_cedula'] as String, k),
        ];
      case 'servicio':
        // En multi la lista de cuotas (bloque `cuota`) ya cubre el servicio.
        return const [];
      case 'cuota':
        // La LISTA de N cuotas: período → monto aplicado de cada una.
        return [
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      Fmt.mesServicioLabel(
                        DateTime.parse(r['periodo'] as String),
                        r['plan_nombre'] == null
                            ? null
                            : (r['dia_pago'] as num?)?.toInt(),
                      ),
                      style: TextStyle(fontSize: 12 * k),
                    ),
                  ),
                  Text(Fmt.cordobas(r['monto_cordobas'] as num),
                      style: TextStyle(fontSize: 12 * k)),
                ],
              ),
            ),
        ];
      case 'metodo':
        final totalOriginal = _totalOriginal();
        final esUsd = (first['moneda'] as String?) == 'USD';
        return [
          _ticketRow('Método',
              MetodoPago.fromString(first['metodo'] as String).label.toUpperCase(),
              k),
          if (first['referencia'] != null)
            _ticketRow('Ref.', first['referencia'] as String, k),
          if (esUsd)
            _ticketRow(
              'Recibido',
              'US\$${totalOriginal.toStringAsFixed(2)} '
                  '(tasa ${(first['tasa_conversion'] as num).toStringAsFixed(2)})',
              k,
            ),
        ];
      case 'letras':
        final totalCobrado = _totalCobrado();
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              // Monto en letras corresponde al COBRADO (lo que entró
              // a la caja del ISP), no a lo entregado por el cliente.
              montoALetras(totalCobrado,
                  moneda: (first['moneda'] as String?) ?? 'NIO'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11 * k, fontWeight: FontWeight.w600),
            ),
          ),
        ];
      case 'totales':
        // EL BLOQUE DE DINERO (multi). Matemática y contenido IDÉNTICOS al
        // original: TOTAL COBRADO + VUELTO/PAGADO sumados (con manejo USD =
        // Σ monto_original). Solo cambió su posición (la da el layout).
        final scheme = Theme.of(context).colorScheme;
        final totalCobrado = _totalCobrado();
        final totalVuelto = _totalVuelto();
        final totalOriginal = _totalOriginal();
        final totalEntregado = totalCobrado + totalVuelto;
        // Todo el grupo comparte moneda/tasa (registrarCobroMultiple usa una sola).
        final esUsd = (first['moneda'] as String?) == 'USD';
        return [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('TOTAL COBRADO',
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 15 * k)),
              Text(Fmt.cordobas(totalCobrado),
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 15 * k)),
            ],
          ),
          if (totalVuelto > 0.01) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(esUsd ? 'VUELTO (en C\$)' : 'VUELTO',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13 * k,
                      color: scheme.primary,
                    )),
                Text(Fmt.cordobas(totalVuelto),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13 * k,
                      color: scheme.primary,
                    )),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('PAGADO',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 14 * k)),
                Text(
                    esUsd
                        ? 'US\$${totalOriginal.toStringAsFixed(2)} = ${Fmt.cordobas(totalEntregado)}'
                        : Fmt.cordobas(totalEntregado),
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 14 * k)),
              ],
            ),
          ],
        ];
      case 'mora':
        // Detalle de mora del contrato (multi): excluye TODAS las cuotas del
        // grupo recién cobrado, así solo figura lo que aún se debe. Mismo
        // resumen informativo que el single — no toca la matemática del dinero.
        final contratoId = first['contrato_id'] as String?;
        if (contratoId == null) return const []; // cuota manual: sin contrato
        final cobradas =
            rows.map((r) => r['cuota_id']).whereType<Object>().toSet();
        final mora = (ref
                    .watch(moraContratoProvider((
                      contratoId: contratoId,
                      diasGracia: settings.diasGracia,
                    )))
                    .valueOrNull ??
                const [])
            .where((m) => !cobradas.contains(m['cuota_id']))
            .toList();
        if (mora.isEmpty) return const [];
        final totalMora = mora.fold<double>(
            0, (s, m) => s + (m['saldo'] as num).toDouble());
        return [
          Text('EN MORA',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13 * k),
              textAlign: TextAlign.center),
          const SizedBox(height: 2),
          for (final m in mora)
            _ticketRow(
              Fmt.mes(DateTime.parse(m['periodo'] as String)),
              Fmt.cordobas(m['saldo'] as num),
              k,
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('TOTAL MORA',
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 13 * k)),
              Text(Fmt.cordobas(totalMora),
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 13 * k)),
            ],
          ),
        ];
      case 'pie':
        if (settings.pieRecibo.isEmpty) return const [];
        return [
          Text(settings.pieRecibo,
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13 * k)),
        ];
      case 'whatsapp':
        if (settings.empresaWhatsapp.isEmpty) return const [];
        return [
          Text('WhatsApp: ${settings.empresaWhatsapp}',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13 * k)),
        ];
      default:
        return const [];
    }
  }

  // Totales del grupo. Mismas sumas que antes (sin cambios de matemática).
  double _totalCobrado() {
    var t = 0.0;
    for (final r in rows) {
      t += (r['monto_cordobas'] as num).toDouble();
    }
    return t;
  }

  double _totalVuelto() {
    var t = 0.0;
    for (final r in rows) {
      t += (r['vuelto_cordobas'] as num? ?? 0).toDouble();
    }
    return t;
  }

  // Σ monto_original = lo entregado en moneda original.
  double _totalOriginal() {
    var t = 0.0;
    for (final r in rows) {
      t += (r['monto_original'] as num? ?? 0).toDouble();
    }
    return t;
  }

  Widget _ticketRow(String label, String value, [double k = 1]) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
            width: 90,
            child: Text('$label:', style: TextStyle(fontSize: 13 * k))),
        Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 13 * k))),
      ],
    );
  }
}

class _AccionesImpresion extends ConsumerStatefulWidget {
  const _AccionesImpresion({
    required this.reciboId,
    required this.recibo,
    required this.settings,
    this.logoUrl,
    this.multiRows,
  });
  final String reciboId;
  final Map<String, dynamic> recibo;
  final AppSettings settings;

  /// URL firmada del logo de la empresa. Si está presente, el PDF se
  /// genera con el logo embebido. Si falla el fetch, el PDF se genera
  /// sin logo (no rompe la descarga).
  final String? logoUrl;

  /// Si está presente, genera el PDF en modo cobro múltiple usando todas
  /// las filas. Caso contrario, recibo individual.
  final List<Map<String, dynamic>>? multiRows;

  @override
  ConsumerState<_AccionesImpresion> createState() => _AccionesImpresionState();
}

class _AccionesImpresionState extends ConsumerState<_AccionesImpresion> {
  bool _imprimiendo = false;
  bool _descargandoPdf = false;

  Future<void> _descargarPdf() async {
    setState(() => _descargandoPdf = true);
    try {
      // Fetch del logo (best-effort). Si falla, el PDF se genera sin logo
      // — no rompemos la descarga por un error de red en una imagen.
      Uint8List? logoBytes;
      final logoUrl = widget.logoUrl;
      if (logoUrl != null && logoUrl.isNotEmpty) {
        try {
          final response = await http.get(Uri.parse(logoUrl));
          if (response.statusCode == 200) {
            logoBytes = response.bodyBytes;
          }
        } catch (_) {
          // Silenciado a propósito: el PDF se genera sin logo.
          logoBytes = null;
        }
      }

      // Detalle de mora del contrato para el bloque `mora` del PDF. El PDF no
      // tiene `ref` ni hace IO, así que la mora se calcula acá (mismo
      // `fetchMoraContrato` que el provider de pantalla) y se pasa hecha.
      // Single: excluir la cuota cobrada. Multi: excluir TODAS las del grupo.
      // Cuota manual (contrato_id null) → mora vacía.
      final multiRows = widget.multiRows;
      final contratoId = (multiRows != null ? multiRows.first : widget.recibo)[
          'contrato_id'] as String?;
      final excluir = (multiRows != null
              ? multiRows.map((r) => r['cuota_id'])
              : [widget.recibo['cuota_id']])
          .whereType<Object>()
          .toSet();
      final moraRows = contratoId == null
          ? const <Map<String, dynamic>>[]
          : (await fetchMoraContrato(contratoId, widget.settings.diasGracia))
              .where((m) => !excluir.contains(m['cuota_id']))
              .toList();

      final doc = multiRows != null
          ? await buildMultiReciboPdf(
              rows: multiRows,
              settings: widget.settings,
              logoBytes: logoBytes,
              moraRows: moraRows)
          : await buildReciboPdf(
              row: widget.recibo,
              settings: widget.settings,
              logoBytes: logoBytes,
              moraRows: moraRows);
      final bytes = await doc.save();
      final numero = (widget.recibo['numero_completo'] as String?) ?? widget.reciboId;
      final filename =
          'recibo_${numero.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.pdf';
      await Printing.sharePdf(bytes: bytes, filename: filename);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF generado')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al generar PDF: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _descargandoPdf = false);
    }
  }

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
        reciboTitulo: widget.settings.reciboTitulo,
        mostrarAdeudado: widget.settings.reciboMostrarAdeudado,
        empresaWhatsapp: widget.settings.empresaWhatsapp,
        // Sub-toggle que SE MANTIENE: cédula dentro del bloque `cliente`.
        mostrarCedula: widget.settings.reciboMostrarCedula,
        // Layout configurable: orden + visibilidad + tamaño por bloque. La
        // térmica itera la misma lista que pantalla/PDF (supersede
        // mostrarEmpresa/ordenPie).
        layout: widget.settings.reciboLayout,
        // #6a: si es cobro múltiple, imprimir las N cuotas del grupo (no solo
        // la 1ª). El service cae al recibo single si multiRows es null/1.
        multiRecibos: widget.multiRows,
      );

      if (!mounted) return;
      if (ok) {
        // Actualizar BD local: impreso_en + reimpresiones + formato.
        await ps.db.execute(
          '''
          UPDATE recibos
             SET impreso_en = ?,
                 reimpresiones = reimpresiones + ?,
                 ultimo_formato_mm = ?,
                 ocurrido_en = ?
           WHERE id = ?
          ''',
          [
            DateTime.now().toIso8601String(),
            esReimpresion ? 1 : 0,
            widget.settings.formatoReciboMm,
            DateTime.now().toUtc().toIso8601String(),
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
        // Impresión Bluetooth térmica: solo mobile. En web se usa el PDF.
        if (!kIsWeb)
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
        // PDF download — solo visible en web. En mobile usan la impresora
        // Bluetooth térmica, así que el PDF no aporta nada.
        if (kIsWeb) ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: _descargandoPdf
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_as_pdf),
            label: Text(_descargandoPdf
                ? 'Generando PDF...'
                : 'Descargar PDF ${widget.settings.formatoReciboMm}mm'),
            onPressed: _descargandoPdf ? null : _descargarPdf,
          ),
        ],
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

class _PostCobroActions extends ConsumerWidget {
  const _PostCobroActions({required this.clienteId});
  final String? clienteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = clienteId;
    if (id == null) return const SizedBox.shrink();
    // Ruta según rol: el admin va al detalle dentro del AdminShell (con panel
    // lateral). El cobrador a /clientes/:id (full-screen). Antes era fijo a
    // /clientes/:id y el admin quedaba sin menú izquierdo.
    final esAdmin =
        ref.watch(cobradorActualProvider).valueOrNull?.tieneAccesoAdmin ?? false;
    final clientePath = esAdmin ? '/admin/clientes/$id' : '/clientes/$id';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.person),
          label: const Text('Ver detalle del cliente'),
          onPressed: () => context.go(clientePath),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
