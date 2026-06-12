import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/impersonation_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/montos.dart';
import 'descuento_dialog.dart' show CargoPendiente;

/// Diálogo de CARGO extra del cobro (lo que SUMA: reconexión / otro).
/// Separado del descuento a pedido de Rubén (2026-06-11): el dropdown que
/// mezclaba descuentos con cargos era poco intuitivo. Igual que el
/// descuento, NO graba: devuelve un [CargoPendiente] que el cobro inserta
/// recién al confirmar (con pago_id) — abandonar el cobro no deja rastro.
class CargoDialog extends ConsumerStatefulWidget {
  const CargoDialog({
    super.key,
    required this.saldoActual,
  });

  final double saldoActual;

  @override
  ConsumerState<CargoDialog> createState() => _CargoDialogState();
}

class _CargoDialogState extends ConsumerState<CargoDialog> {
  /// true = reconexión, false = otro cargo.
  bool _esReconexion = false;
  final _valor = TextEditingController();
  final _descripcion = TextEditingController();
  String? _error;
  bool _prefillHecho = false;

  @override
  void initState() {
    super.initState();
    final s = ref.read(appSettingsProvider);
    if (s.reconexionHabilitada) {
      _esReconexion = true;
      _prefillReconexion(s);
    }
  }

  @override
  void dispose() {
    _valor.dispose();
    _descripcion.dispose();
    super.dispose();
  }

  void _prefillReconexion(AppSettings s) {
    // El setting es solo un default pre-poblado; el usuario puede editarlo.
    if (!_prefillHecho && s.montoReconexion > 0 && _valor.text.trim().isEmpty) {
      _valor.text = s.montoReconexion.toStringAsFixed(2);
      _prefillHecho = true;
    }
  }

  void _aplicar() {
    if (ref.read(estaImpersonandoProvider)) {
      setState(() => _error =
          'No se pueden aplicar cargos mientras gestionás un tenant como super_admin.');
      return;
    }
    final v = parseMonto(_valor.text); // coma o punto decimal (M8)
    if (v == null || v <= 0) {
      setState(() => _error = 'Valor inválido');
      return;
    }
    final descripcion = _descripcion.text.trim();
    if (!_esReconexion && descripcion.isEmpty) {
      setState(() => _error = 'Describí el cargo (qué se está cobrando)');
      return;
    }
    Navigator.pop(
      context,
      CargoPendiente(
        tipo: _esReconexion ? 'reconexion' : 'otro',
        monto: v,
        descripcion: _esReconexion
            ? (descripcion.isEmpty ? 'Cargo por reconexión' : descripcion)
            : descripcion,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = ref.watch(appSettingsProvider);
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 400.0;

    final v = parseMonto(_valor.text);
    final monto = (v == null || v <= 0) ? null : v;

    return AlertDialog(
      title: const Text('Cargo extra'),
      content: SizedBox(
        width: dialogW,
        // Scroll: en 360px con teclado abierto el contenido no entra
        // (audit F4 — mismo patrón que DescuentoDialog).
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s.reconexionHabilitada) ...[
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, label: Text('Reconexión')),
                  ButtonSegment(value: false, label: Text('Otro cargo')),
                ],
                selected: {_esReconexion},
                onSelectionChanged: (sel) => setState(() {
                  _esReconexion = sel.first;
                  if (_esReconexion) _prefillReconexion(s);
                }),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _valor,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Monto (C\$)',
                helperText: _esReconexion && s.montoReconexion > 0
                    ? 'Default: ${Fmt.cordobas(s.montoReconexion)}'
                    : null,
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [montoInputFormatter],
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descripcion,
              decoration: InputDecoration(
                labelText: _esReconexion ? 'Descripción' : 'Descripción *',
                hintText: _esReconexion
                    ? 'Default: Cargo por reconexión'
                    : 'Ej. Cambio de equipo, instalación, etc.',
              ),
              maxLines: 2,
            ),
            // Preview: el cargo SUBE el saldo (en espejo del descuento).
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
                    : 'Cargo: +${Fmt.cordobas(monto)}\n'
                        'Saldo: ${Fmt.cordobas(widget.saldoActual)} → '
                        '${Fmt.cordobas(widget.saldoActual + monto)}',
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
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _aplicar,
          child: const Text('Aplicar cargo'),
        ),
      ],
    );
  }
}
