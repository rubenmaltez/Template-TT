import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/repositories/cuotas_repo.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/montos.dart';

/// Un descuento o cargo elegido durante el COBRO que todavía NO está en la
/// DB: el cobro lo inserta recién al confirmar (PagosRepo, con `pago_id`).
/// Si el cobrador abandona la pantalla no queda rastro, y anular el pago lo
/// revierte solo (cierra el backlog del "descuento fantasma": antes el
/// diálogo insertaba al toque, sin pago_id y aunque el cobro no se hiciera).
class CargoPendiente {
  const CargoPendiente({
    required this.tipo,
    required this.monto,
    this.porcentaje,
    required this.descripcion,
  });

  /// 'descuento_monto' | 'descuento_porcentaje' | 'reconexion' | 'otro'.
  final String tipo;

  /// C$ siempre positivo — el signo lo da el tipo (mismo contrato que
  /// cargos_extra.monto).
  final double monto;
  final double? porcentaje;
  final String descripcion;

  bool get esDescuento => tipo.startsWith('descuento');
}

/// Desde dónde se abre el diálogo — define topes, reglas y persistencia.
enum DescuentoContexto {
  /// Admin desde el detalle del contrato: graba YA vía CuotasRepo con
  /// origen 'ajuste' o 'promo' (selector). Topes `ajuste_max_*`.
  contrato,

  /// Pantalla de cobro (cobrador o admin): NO graba — devuelve un
  /// [CargoPendiente] que el cobro inserta al confirmar. Topes
  /// `descuento_max_*` y modos según `descuento_tipo`.
  cobro,
}

/// EL diálogo de descuento de toda la app (rediseño 2026-06-11): mismo look
/// y mismas reglas en ambos contextos — motivo SIEMPRE obligatorio (con
/// chips rápidos), preview del saldo antes de confirmar, topes por rol.
/// El guard real de ajustes/promos es server-side (trg_cargos_ajuste_guard);
/// acá se valida lo mismo para feedback inmediato offline.
class DescuentoDialog extends ConsumerStatefulWidget {
  const DescuentoDialog({
    super.key,
    required this.contexto,
    required this.cuotaId,
    required this.montoCuota,
    required this.saldoActual,
  });

  final DescuentoContexto contexto;
  final String cuotaId;
  final double montoCuota;
  final double saldoActual;

  @override
  ConsumerState<DescuentoDialog> createState() => _DescuentoDialogState();
}

class _DescuentoDialogState extends ConsumerState<DescuentoDialog> {
  // Chips por semántica (audit F4): un ajuste es una corrección; una promo,
  // un beneficio — sugerir "Sin servicio" para una promo era contradictorio.
  static const _motivosAjuste = [
    'Sin servicio',
    'Promesa de pago',
    'Acuerdo con el cliente',
  ];
  static const _motivosPromo = [
    'Promo de temporada',
    'Cliente referido',
    'Acuerdo comercial',
  ];

  List<String> get _motivosRapidos =>
      _esPromo ? _motivosPromo : _motivosAjuste;

  bool _esPorcentaje = false;
  bool _esPromo = false; // solo contexto contrato
  final _valor = TextEditingController();
  final _motivo = TextEditingController();
  bool _guardando = false;
  String? _error;

  bool get _esCobro => widget.contexto == DescuentoContexto.cobro;

  @override
  void initState() {
    super.initState();
    // En el cobro, `descuento_tipo` puede restringir a un solo modo.
    if (_esCobro) {
      final tipo = ref.read(appSettingsProvider).descuentoTipo;
      if (tipo == 'porcentaje') _esPorcentaje = true;
    }
  }

  @override
  void dispose() {
    _valor.dispose();
    _motivo.dispose();
    super.dispose();
  }

  /// Modos habilitados: en contrato siempre ambos; en cobro según el
  /// setting `descuento_tipo` (monto | porcentaje | ambos).
  ({bool monto, bool porcentaje}) _modos(AppSettings s) {
    if (!_esCobro) return (monto: true, porcentaje: true);
    return switch (s.descuentoTipo) {
      'monto' => (monto: true, porcentaje: false),
      'porcentaje' => (monto: false, porcentaje: true),
      _ => (monto: true, porcentaje: true),
    };
  }

  double? _parseValor() {
    final v = parseMonto(_valor.text); // coma o punto decimal (M8)
    return (v == null || v <= 0) ? null : v;
  }

  /// Monto del descuento en C$ según el modo, o null si el input no parsea.
  double? get _montoDescuento {
    final v = _parseValor();
    if (v == null) return null;
    return _esPorcentaje ? widget.montoCuota * v / 100 : v;
  }

  Future<void> _aplicar() async {
    // Guard de impersonación: el cargo se atribuiría a la fila real del
    // super_admin (tenant System), no al impersonado.
    if (ref.read(estaImpersonandoProvider)) {
      setState(() => _error =
          'No se pueden aplicar descuentos mientras gestionás un tenant como super_admin.');
      return;
    }
    final s = ref.read(appSettingsProvider);

    final v = _parseValor();
    if (v == null) {
      setState(() => _error = 'Valor inválido');
      return;
    }
    if (_esPorcentaje && v > 100) {
      setState(() => _error = 'El porcentaje no puede exceder 100');
      return;
    }
    // Topes del súper (0 = sin tope): ajuste_max_* en el contrato,
    // descuento_max_* en el cobro — espejo de los guards server.
    final maxPct = _esCobro ? s.descuentoMaxPorcentaje : s.ajusteMaxPorcentaje;
    final maxMonto = _esCobro ? s.descuentoMaxMonto : s.ajusteMaxMonto;
    if (_esPorcentaje && maxPct > 0 && v > maxPct) {
      setState(() => _error =
          'Excede el tope de ${maxPct.toStringAsFixed(0)}% configurado');
      return;
    }
    final monto = _montoDescuento!;
    if (maxMonto > 0 && monto > maxMonto) {
      setState(() => _error =
          'Excede el tope de ${Fmt.cordobas(maxMonto)} configurado');
      return;
    }
    if (monto > widget.saldoActual + 0.01) {
      setState(() => _error =
          'El descuento no puede exceder el saldo (${Fmt.cordobas(widget.saldoActual)})');
      return;
    }
    if (_motivo.text.trim().isEmpty) {
      setState(() => _error = 'El motivo es obligatorio');
      return;
    }

    // Contexto COBRO: devolver el descuento pendiente — lo graba el cobro.
    if (_esCobro) {
      Navigator.pop(
        context,
        CargoPendiente(
          tipo: _esPorcentaje ? 'descuento_porcentaje' : 'descuento_monto',
          monto: monto,
          porcentaje: _esPorcentaje ? v : null,
          descripcion: _motivo.text.trim(),
        ),
      );
      return;
    }

    // Contexto CONTRATO: grabar ya (ajuste o promo).
    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) {
      // Audit F4: antes el return silencioso dejaba el botón "muerto".
      setState(() => _error =
          'Tus datos de usuario todavía no cargaron. Probá de nuevo en unos segundos.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await ref.read(cuotasRepoProvider).aplicarAjuste(
            tenantId: me.tenantId,
            cuotaId: widget.cuotaId,
            esPorcentaje: _esPorcentaje,
            valor: v,
            motivo: _motivo.text,
            aplicadoPorId: me.id,
            origen: _esPromo ? 'promo' : 'ajuste',
          );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = ref.watch(appSettingsProvider);
    final modos = _modos(s);
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 400.0;

    final monto = _montoDescuento;
    final nuevoSaldo = monto == null
        ? null
        : (widget.saldoActual - monto).clamp(0.0, double.infinity);

    return AlertDialog(
      title: Text(_esCobro ? 'Descuento en este cobro' : 'Descontar cuota'),
      content: SizedBox(
        width: dialogW,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Semántica clara ajuste vs promo (decisión Rubén 2026-06-11):
              // mismo flujo, etiqueta distinta en historial/recibo/reportes.
              if (!_esCobro) ...[
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('Ajuste')),
                    ButtonSegment(value: true, label: Text('Promo')),
                  ],
                  selected: {_esPromo},
                  onSelectionChanged: (sel) =>
                      setState(() => _esPromo = sel.first),
                ),
                const SizedBox(height: 4),
                Text(
                  _esPromo
                      ? 'Beneficio comercial — queda etiquetado como promoción.'
                      : 'Corrección puntual: días sin servicio, error, acuerdo.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.outline),
                ),
                const SizedBox(height: 12),
              ],
              if (modos.monto && modos.porcentaje) ...[
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('Monto C\$')),
                    ButtonSegment(value: true, label: Text('Porcentaje %')),
                  ],
                  selected: {_esPorcentaje},
                  onSelectionChanged: (sel) =>
                      setState(() => _esPorcentaje = sel.first),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _valor,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: _esPorcentaje
                      ? 'Porcentaje a descontar (0-100)'
                      : 'Monto a descontar (C\$)',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [montoInputFormatter],
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _motivo,
                decoration: InputDecoration(
                  labelText: 'Motivo *',
                  hintText: _esPromo
                      ? 'Ej. Promo 3 meses a mitad de precio'
                      : 'Ej. Sin servicio 5 días',
                ),
                maxLines: 2,
                onChanged: (_) => setState(() {}),
              ),
              // Chips de motivos comunes: un toque y listo (no frenan al
              // cobrador en campo; el texto sigue siendo editable).
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 0,
                children: [
                  for (final m in _motivosRapidos)
                    ActionChip(
                      label: Text(m, style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _motivo.text = m),
                    ),
                ],
              ),
              // Preview SIEMPRE visible antes de confirmar (pedido de Rubén:
              // intuitivo y sin sorpresas contables).
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  monto == null
                      ? 'Saldo actual: ${Fmt.cordobas(widget.saldoActual)}'
                      : 'Descuento: −${Fmt.cordobas(monto)}\n'
                          'Saldo: ${Fmt.cordobas(widget.saldoActual)} → '
                          '${Fmt.cordobas(nuevoSaldo!)}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _guardando ? null : _aplicar,
          child: Text(_guardando ? 'Aplicando...' : 'Aplicar descuento'),
        ),
      ],
    );
  }
}
