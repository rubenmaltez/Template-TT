import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/repositories/cuotas_repo.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';

/// Dialog "Ajustar cuota" (Sprint 2, audit 2026-06-11): el admin reduce una
/// cuota con MOTIVO obligatorio — p.ej. el cliente pasó sin servicio N días.
/// Inserta un cargos_extra origen='ajuste' vía CuotasRepo (nunca muta
/// cuotas.monto). Gate: setting super-only `cobranza.ajustes_habilitados`
/// (el guard real es server-side, trg_cargos_ajuste_guard; acá se valida lo
/// mismo para feedback inmediato offline).
class AjustarCuotaDialog extends ConsumerStatefulWidget {
  const AjustarCuotaDialog({
    super.key,
    required this.cuotaId,
    required this.montoCuota,
    required this.saldoActual,
  });

  final String cuotaId;
  final double montoCuota;
  final double saldoActual;

  @override
  ConsumerState<AjustarCuotaDialog> createState() => _AjustarCuotaDialogState();
}

class _AjustarCuotaDialogState extends ConsumerState<AjustarCuotaDialog> {
  bool _esPorcentaje = false;
  final _valor = TextEditingController();
  final _motivo = TextEditingController();
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _valor.dispose();
    _motivo.dispose();
    super.dispose();
  }

  /// Acepta coma o punto decimal ("500,50" == "500.50") y rechaza más de un
  /// separador (lección M8 del audit: la coma filtrada en silencio).
  double? _parseValor() {
    final s = _valor.text.trim().replaceAll(',', '.');
    if ('.'.allMatches(s).length > 1) return null;
    final v = double.tryParse(s);
    return (v == null || v <= 0) ? null : v;
  }

  /// Monto del ajuste en C$ según el modo, o null si el input no parsea.
  double? get _montoAjuste {
    final v = _parseValor();
    if (v == null) return null;
    return _esPorcentaje ? widget.montoCuota * v / 100 : v;
  }

  Future<void> _aplicar() async {
    // Guard de impersonación (mismo patrón que AplicarCargoDialog).
    if (ref.read(estaImpersonandoProvider)) {
      setState(() => _error =
          'No se pueden aplicar ajustes mientras gestionás un tenant como super_admin.');
      return;
    }
    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;
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
    // Topes del súper (0 = sin tope) — espejo del guard server 0115.
    if (_esPorcentaje &&
        s.ajusteMaxPorcentaje > 0 &&
        v > s.ajusteMaxPorcentaje) {
      setState(() =>
          _error = 'Excede el tope de ${s.ajusteMaxPorcentaje.toStringAsFixed(0)}% configurado');
      return;
    }
    final monto = _montoAjuste!;
    if (s.ajusteMaxMonto > 0 && monto > s.ajusteMaxMonto) {
      setState(() =>
          _error = 'Excede el tope de ${Fmt.cordobas(s.ajusteMaxMonto)} configurado');
      return;
    }
    if (monto > widget.saldoActual + 0.01) {
      setState(() =>
          _error = 'El ajuste no puede exceder el saldo (${Fmt.cordobas(widget.saldoActual)})');
      return;
    }
    if (_motivo.text.trim().isEmpty) {
      setState(() => _error = 'El motivo es obligatorio');
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
          );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() =>
            _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 400.0;

    final monto = _montoAjuste;
    final nuevoSaldo = monto == null
        ? null
        : (widget.saldoActual - monto).clamp(0.0, double.infinity);

    return AlertDialog(
      title: const Text('Ajustar cuota'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Monto C\$')),
                ButtonSegment(value: true, label: Text('Porcentaje %')),
              ],
              selected: {_esPorcentaje},
              onSelectionChanged: (sel) =>
                  setState(() => _esPorcentaje = sel.first),
            ),
            const SizedBox(height: 12),
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
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _motivo,
              decoration: const InputDecoration(
                labelText: 'Motivo *',
                hintText: 'Ej. Sin servicio 5 días',
              ),
              maxLines: 2,
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
                    : 'Ajuste: −${Fmt.cordobas(monto)}\n'
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
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _guardando ? null : _aplicar,
          child: Text(_guardando ? 'Aplicando...' : 'Aplicar ajuste'),
        ),
      ],
    );
  }
}
