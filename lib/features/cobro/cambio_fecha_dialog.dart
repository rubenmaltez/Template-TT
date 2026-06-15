import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/pago.dart';
import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/impersonation_provider.dart';
import '../../data/repositories/pagos_repo.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/cobro_calculo.dart';
import '../../data/utils/formatters.dart';
import '../../data/utils/montos.dart';
import '../../data/utils/prorrateo.dart';
import '../../powersync/db.dart' as ps;

/// Diálogo "Cambiar fecha de pago" (feature C, Diseño A). El cliente AL DÍA
/// mueve su día de pago: paga el "puente" (días prorrateados entre lo pagado y
/// el ancla del día nuevo) con recibo, y desde ahí su calendario corre en el
/// día nuevo. Es un mini-cobro: muestra el preview del puente y reusa la
/// mecánica del cobro (monto entregado / moneda / método / vuelto).
///
/// Devuelve por `Navigator.pop` el `reciboId` del cobro del puente (o null si
/// se canceló) — el caller navega a `/recibo/:id`.
class CambioFechaDialog extends ConsumerStatefulWidget {
  const CambioFechaDialog({
    super.key,
    required this.contratoId,
    required this.diaPagoActual,
    required this.precioMensual,
    this.clienteNombre,
  });

  final String contratoId;
  final int diaPagoActual;
  final double precioMensual;
  final String? clienteNombre;

  @override
  ConsumerState<CambioFechaDialog> createState() => _CambioFechaDialogState();
}

class _CambioFechaDialogState extends ConsumerState<CambioFechaDialog> {
  final _montoCtrl = TextEditingController();
  final _referenciaCtrl = TextEditingController();

  int? _diaNuevo;
  Moneda _moneda = Moneda.nio;
  MetodoPago _metodo = MetodoPago.efectivo;
  double? _tasaSnapshot;

  bool _cargando = true;
  String? _noElegible; // motivo por el que NO se puede cambiar la fecha
  DateTime? _pagadoHasta; // día de servicio NOMINAL ya cubierto

  bool _enviando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _montoCtrl.dispose();
    _referenciaCtrl.dispose();
    super.dispose();
  }

  DateTime _parsePeriodo(String s) {
    final p = s.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), 1);
  }

  /// Carga el "pagado hasta" (día nominal de la última cuota pagada) y valida
  /// la elegibilidad (al día, sin parciales) — espejo de los guards del repo,
  /// para mostrar el motivo ANTES de que el cobrador llene el pago.
  Future<void> _cargar() async {
    try {
      final pagadas = await ps.db.getAll(
        "SELECT periodo FROM cuotas WHERE contrato_id = ? AND estado = 'pagada' "
        "ORDER BY date(periodo) DESC LIMIT 1",
        [widget.contratoId],
      );
      final vencidas = await ps.db.getAll(
        "SELECT COUNT(*) AS n FROM cuotas WHERE contrato_id = ? "
        "AND estado IN ('pendiente','parcial') "
        "AND date(fecha_vencimiento) <= date('now','-6 hours')",
        [widget.contratoId],
      );
      final parciales = await ps.db.getAll(
        "SELECT COUNT(*) AS n FROM cuotas WHERE contrato_id = ? AND estado = 'parcial'",
        [widget.contratoId],
      );
      if (!mounted) return;
      setState(() {
        _cargando = false;
        if (pagadas.isEmpty) {
          _noElegible = 'El cliente todavía no tiene cuotas pagadas.';
          return;
        }
        if ((vencidas.first['n'] as num).toInt() > 0) {
          _noElegible = 'El cliente no está al día (tiene cuotas vencidas).';
          return;
        }
        if ((parciales.first['n'] as num).toInt() > 0) {
          _noElegible = 'Hay un pago parcial en curso en este contrato.';
          return;
        }
        final periodo = _parsePeriodo(pagadas.first['periodo'] as String);
        _pagadoHasta = DateTime(
          periodo.year,
          periodo.month,
          diaClampMes(periodo.year, periodo.month, widget.diaPagoActual),
        );
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _cargando = false;
          _noElegible = 'No se pudo cargar la información del contrato.';
        });
      }
    }
  }

  PuenteCambioFecha? get _puente {
    if (_pagadoHasta == null || _diaNuevo == null) return null;
    return calcularPuenteCambioFecha(
      pagadoHasta: _pagadoHasta!,
      diaNuevo: _diaNuevo!,
      precioMensual: widget.precioMensual,
    );
  }

  double get _tasa {
    if (_moneda != Moneda.usd) return 1.0;
    return _tasaSnapshot ?? ref.read(appSettingsProvider).tasaUsd;
  }

  Future<void> _confirmar() async {
    if (ref.read(estaImpersonandoProvider)) {
      setState(() => _error =
          'No se puede cambiar la fecha mientras gestionás un tenant como super_admin.');
      return;
    }
    final puente = _puente;
    if (puente == null || puente.montoPuente <= 0) {
      setState(() => _error = 'Elegí un día nuevo válido.');
      return;
    }
    final entregado = parseMonto(_montoCtrl.text);
    if (entregado == null || entregado <= 0) {
      setState(() => _error = 'Ingresá el monto entregado.');
      return;
    }
    final entregadoCordobas = CobroCalculo.aCordobas(entregado, _tasa);
    if ((entregadoCordobas * 100).round() < (puente.montoPuente * 100).round()) {
      setState(() => _error =
          'El monto entregado no alcanza para el puente (${Fmt.cordobas(puente.montoPuente)}).');
      return;
    }
    if (_metodo.requiereComprobante && _referenciaCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Ingresá la referencia del ${_metodo.label.toLowerCase()}.');
      return;
    }
    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null || (me.prefijoRecibo ?? '').isEmpty) {
      setState(() => _error =
          'Tu usuario no tiene prefijo de recibo asignado. Pedíselo al admin.');
      return;
    }

    setState(() {
      _enviando = true;
      _error = null;
    });
    try {
      final res = await ref.read(pagosRepoProvider).registrarCambioFecha(
            tenantId: me.tenantId,
            cobradorId: me.id,
            prefijoRecibo: me.prefijoRecibo!,
            contratoId: widget.contratoId,
            diaNuevo: _diaNuevo!,
            precioMensual: widget.precioMensual,
            moneda: _moneda,
            montoOriginal: entregado,
            tasaConversion: _tasa,
            metodo: _metodo,
            referencia: _referenciaCtrl.text.trim().isEmpty
                ? null
                : _referenciaCtrl.text.trim(),
          );
      if (mounted) Navigator.pop(context, res.reciboId);
    } catch (e) {
      if (mounted) {
        setState(() =>
            _error = e.toString().replaceFirst('Exception: ', '').replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = ref.watch(appSettingsProvider);
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;
    final puente = _puente;

    final entregado = parseMonto(_montoCtrl.text);
    final vueltoCordobas = (puente != null && entregado != null)
        ? CobroCalculo.calcular(
            entregadoCordobas: CobroCalculo.aCordobas(entregado, _tasa),
            saldoCordobas: puente.montoPuente,
          ).vueltoCordobas
        : 0.0;

    final dias = List<int>.generate(31, (i) => i + 1)
        .where((d) => d != widget.diaPagoActual)
        .toList();

    return AlertDialog(
      title: Text(widget.clienteNombre == null
          ? 'Cambiar fecha de pago'
          : 'Cambiar fecha · ${widget.clienteNombre}'),
      content: SizedBox(
        width: dialogW,
        child: _cargando
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : _noElegible != null
                ? Text(_noElegible!, style: TextStyle(color: scheme.error))
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Día de pago actual: ${widget.diaPagoActual}',
                            style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<int>(
                          initialValue: _diaNuevo,
                          decoration:
                              const InputDecoration(labelText: 'Nuevo día de pago'),
                          items: [
                            for (final d in dias)
                              DropdownMenuItem(value: d, child: Text('Día $d')),
                          ],
                          onChanged: (d) => setState(() => _diaNuevo = d),
                        ),
                        const SizedBox(height: 12),
                        // Preview del puente.
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: puente == null
                              ? const Text('Elegí el día nuevo para ver el puente.')
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Puente: ${puente.diasPuente} días',
                                        style:
                                            Theme.of(context).textTheme.bodyMedium),
                                    const SizedBox(height: 2),
                                    Text('A cobrar ahora: ${Fmt.cordobas(puente.montoPuente)}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 2),
                                    Text(
                                        'Desde ahí, las cuotas vencen el día ${_diaNuevo!} de cada mes.',
                                        style:
                                            Theme.of(context).textTheme.bodySmall),
                                  ],
                                ),
                        ),
                        const SizedBox(height: 14),
                        // Pago del puente.
                        if (s.usdHabilitado) ...[
                          SegmentedButton<Moneda>(
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(value: Moneda.nio, label: Text('C\$')),
                              ButtonSegment(value: Moneda.usd, label: Text('US\$')),
                            ],
                            selected: {_moneda},
                            onSelectionChanged: (sel) => setState(() {
                              _moneda = sel.first;
                              if (_moneda == Moneda.usd) {
                                _tasaSnapshot = ref.read(appSettingsProvider).tasaUsd;
                              }
                              _montoCtrl.clear();
                            }),
                          ),
                          if (_moneda == Moneda.usd)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text('Tasa: ${Fmt.cordobas(_tasa)} / US\$',
                                  style: Theme.of(context).textTheme.bodySmall),
                            ),
                          const SizedBox(height: 10),
                        ],
                        TextField(
                          controller: _montoCtrl,
                          decoration: InputDecoration(
                            labelText: 'Monto entregado (${_moneda.symbol})',
                          ),
                          keyboardType:
                              const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [montoInputFormatter],
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final m in [
                              MetodoPago.efectivo,
                              if (s.transferenciaHabilitada) MetodoPago.transferencia,
                              if (s.tarjetaHabilitada) MetodoPago.tarjeta,
                            ])
                              ChoiceChip(
                                label: Text(m.label),
                                selected: _metodo == m,
                                onSelected: (_) => setState(() => _metodo = m),
                              ),
                          ],
                        ),
                        if (_metodo.requiereComprobante) ...[
                          const SizedBox(height: 10),
                          TextField(
                            controller: _referenciaCtrl,
                            decoration: const InputDecoration(
                                labelText: 'Referencia / N° de comprobante'),
                          ),
                        ],
                        if (vueltoCordobas > 0.01) ...[
                          const SizedBox(height: 10),
                          Text('Vuelto: ${Fmt.cordobas(vueltoCordobas)}',
                              style: TextStyle(color: scheme.primary)),
                        ],
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
          onPressed: _enviando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed:
              (_enviando || _cargando || _noElegible != null || _puente == null)
                  ? null
                  : _confirmar,
          child: Text(_enviando ? 'Cobrando...' : 'Cobrar puente y cambiar fecha'),
        ),
      ],
    );
  }
}
