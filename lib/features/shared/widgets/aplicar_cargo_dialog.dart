import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;

enum CargoTipo {
  descuentoMonto('descuento_monto'),
  descuentoPorcentaje('descuento_porcentaje'),
  reconexion('reconexion'),
  otro('otro');

  const CargoTipo(this.value);
  final String value;

  String get label => switch (this) {
        CargoTipo.descuentoMonto => 'Descuento (monto fijo)',
        CargoTipo.descuentoPorcentaje => 'Descuento (porcentaje)',
        CargoTipo.reconexion => 'Cargo por reconexión',
        CargoTipo.otro => 'Otro cargo',
      };

  bool get esDescuento =>
      this == CargoTipo.descuentoMonto || this == CargoTipo.descuentoPorcentaje;
}

/// Dialog reutilizable para aplicar un descuento o cargo a una cuota.
/// Respeta los toggles de settings y los topes de descuento.
class AplicarCargoDialog extends ConsumerStatefulWidget {
  const AplicarCargoDialog({
    super.key,
    required this.cuotaId,
    required this.montoCuota,
  });

  final String cuotaId;
  final double montoCuota;

  @override
  ConsumerState<AplicarCargoDialog> createState() => _AplicarCargoDialogState();
}

class _AplicarCargoDialogState extends ConsumerState<AplicarCargoDialog> {
  CargoTipo? _tipo;
  final _valor = TextEditingController();
  final _descripcion = TextEditingController();
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _valor.dispose();
    _descripcion.dispose();
    super.dispose();
  }

  List<CargoTipo> _tiposDisponibles(AppSettings s) {
    final out = <CargoTipo>[];
    if (s.descuentosHabilitados) {
      final permite = s.descuentoTipo;
      if (permite == 'monto' || permite == 'ambos') {
        out.add(CargoTipo.descuentoMonto);
      }
      if (permite == 'porcentaje' || permite == 'ambos') {
        out.add(CargoTipo.descuentoPorcentaje);
      }
    }
    if (s.reconexionHabilitada) out.add(CargoTipo.reconexion);
    out.add(CargoTipo.otro);
    return out;
  }

  Future<void> _aplicar() async {
    // Guard (#9): no aplicar cargos impersonando — se atribuiría al tenant
    // System (fila real del super_admin), no al impersonado.
    if (ref.read(estaImpersonandoProvider)) {
      setState(() => _error =
          'No se puede aplicar cargos mientras gestionás un tenant como super_admin.');
      return;
    }
    if (_tipo == null) {
      setState(() => _error = 'Elegí un tipo');
      return;
    }
    final cobrador = ref.read(cobradorActualProvider).valueOrNull;
    if (cobrador == null) return;
    final s = ref.read(appSettingsProvider);

    final valor = double.tryParse(_valor.text);
    if (valor == null || valor <= 0) {
      setState(() => _error = 'Valor inválido');
      return;
    }

    double monto;
    double? porcentaje;

    if (_tipo == CargoTipo.descuentoPorcentaje) {
      if (valor > 100) {
        setState(() => _error = 'El porcentaje no puede exceder 100');
        return;
      }
      if (s.descuentoMaxPorcentaje > 0 && valor > s.descuentoMaxPorcentaje) {
        setState(() =>
            _error = 'Excede el tope (${s.descuentoMaxPorcentaje}%) sin aprobación');
        return;
      }
      porcentaje = valor;
      monto = (widget.montoCuota * valor / 100).toDouble();
    } else if (_tipo == CargoTipo.descuentoMonto) {
      if (s.descuentoMaxMonto > 0 && valor > s.descuentoMaxMonto) {
        setState(() =>
            _error = 'Excede el tope (${Fmt.cordobas(s.descuentoMaxMonto)}) sin aprobación');
        return;
      }
      if (valor > widget.montoCuota) {
        setState(() => _error = 'El descuento no puede exceder la cuota');
        return;
      }
      monto = valor;
    } else if (_tipo == CargoTipo.reconexion) {
      // Usar lo que el usuario ingresó (el setting es sólo default
      // pre-poblado al elegir el tipo).
      monto = valor;
    } else {
      // otro
      if (_descripcion.text.trim().isEmpty) {
        setState(() => _error = 'Descripción requerida para "Otro"');
        return;
      }
      monto = valor;
    }

    setState(() {
      _guardando = true;
      _error = null;
    });

    try {
      final cuotaRows = await ps.db.getAll(
        'SELECT cobrador_id FROM cuotas WHERE id = ?',
        [widget.cuotaId],
      );
      final cobradorCuota = cuotaRows.isEmpty
          ? cobrador.id
          : (cuotaRows.first['cobrador_id'] as String? ?? cobrador.id);

      // Hora REAL del dispositivo (UTC) para el change log — offline-first.
      final ocurridoEn = DateTime.now().toUtc().toIso8601String();
      await ps.db.execute(
        '''
        INSERT INTO cargos_extra (
          id, tenant_id, cuota_id, cobrador_id, tipo, monto, porcentaje,
          descripcion, aplicado_por, aplicado_en, client_local_id, ocurrido_en
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          const Uuid().v4(),
          cobrador.tenantId,
          widget.cuotaId,
          cobradorCuota,
          _tipo!.value,
          monto,
          porcentaje,
          _descripcion.text.trim().isEmpty ? null : _descripcion.text.trim(),
          cobrador.id,
          DateTime.now().toIso8601String(),
          const Uuid().v4(),
          ocurridoEn,
        ],
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appSettingsProvider);
    final tipos = _tiposDisponibles(s);

    // Ancho responsive: 400 en desktop/tablet, 90% del viewport en mobile
    // chico (un 400 fijo desborda el AlertDialog en pantallas ~360px).
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 400.0;

    return AlertDialog(
      title: const Text('Aplicar cargo'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<CargoTipo>(
              value: _tipo,
              decoration: const InputDecoration(labelText: 'Tipo'),
              items: tipos
                  .map((t) => DropdownMenuItem(value: t, child: Text(t.label)))
                  .toList(),
              onChanged: (v) {
                setState(() {
                  _tipo = v;
                  // Pre-poblar valor para reconexión con default del setting,
                  // si está disponible y el campo está vacío.
                  if (v == CargoTipo.reconexion &&
                      s.montoReconexion > 0 &&
                      _valor.text.trim().isEmpty) {
                    _valor.text = s.montoReconexion.toStringAsFixed(2);
                  }
                });
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _valor,
              decoration: InputDecoration(
                labelText: _tipo == CargoTipo.descuentoPorcentaje
                    ? 'Porcentaje (0-100)'
                    : 'Monto (C\$)',
                helperText: _tipo == CargoTipo.reconexion && s.montoReconexion > 0
                    ? 'Default: ${Fmt.cordobas(s.montoReconexion)}'
                    : null,
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
            ),
            if (_tipo == CargoTipo.otro) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _descripcion,
                decoration: const InputDecoration(
                  labelText: 'Descripción *',
                  hintText: 'Ej. Ajuste por instalación, etc.',
                ),
                maxLines: 2,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
          child: Text(_guardando ? 'Aplicando...' : 'Aplicar'),
        ),
      ],
    );
  }
}
