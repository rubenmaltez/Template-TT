import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;

enum _Duracion { unAno, dosAnos, indefinido }

class ContratoFormScreen extends ConsumerStatefulWidget {
  const ContratoFormScreen({super.key, this.contratoId, this.clienteId});
  final String? contratoId;
  final String? clienteId;

  @override
  ConsumerState<ContratoFormScreen> createState() => _ContratoFormScreenState();
}

class _ContratoFormScreenState extends ConsumerState<ContratoFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _diaPagoCtrl = TextEditingController();
  String? _clienteId;
  String? _planId;
  DateTime _fechaInicio = DateTime.now();
  _Duracion _duracion = _Duracion.unAno;
  bool _activo = true;
  bool _cargando = true;
  bool _guardando = false;
  String? _error;

  bool get _esEdicion => widget.contratoId != null;

  @override
  void initState() {
    super.initState();
    _clienteId = widget.clienteId;
    _diaPagoCtrl.text = DateTime.now().day.toString();
    _cargar();
  }

  Future<void> _cargar() async {
    if (!_esEdicion) {
      setState(() => _cargando = false);
      return;
    }
    final rows = await ps.db
        .getAll('SELECT * FROM contratos WHERE id = ?', [widget.contratoId]);
    if (rows.isEmpty) {
      setState(() => _cargando = false);
      return;
    }
    final r = rows.first;
    _clienteId = r['cliente_id'] as String;
    _planId = r['plan_id'] as String;
    _diaPagoCtrl.text = (r['dia_pago'] as int).toString();
    _fechaInicio = DateTime.parse(r['fecha_inicio'] as String);
    _activo = (r['activo'] as int? ?? 1) == 1;
    if (r['fecha_fin'] != null) {
      final fin = DateTime.parse(r['fecha_fin'] as String);
      final meses = (fin.year - _fechaInicio.year) * 12 +
          (fin.month - _fechaInicio.month);
      _duracion = meses == 12
          ? _Duracion.unAno
          : meses == 24
              ? _Duracion.dosAnos
              : _Duracion.indefinido;
    } else {
      _duracion = _Duracion.indefinido;
    }
    setState(() => _cargando = false);
  }

  @override
  void dispose() {
    _diaPagoCtrl.dispose();
    super.dispose();
  }

  DateTime? _fechaFin() {
    switch (_duracion) {
      case _Duracion.unAno:
        return DateTime(_fechaInicio.year + 1, _fechaInicio.month, _fechaInicio.day);
      case _Duracion.dosAnos:
        return DateTime(_fechaInicio.year + 2, _fechaInicio.month, _fechaInicio.day);
      case _Duracion.indefinido:
        return null;
    }
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) return;
    if (_clienteId == null) {
      setState(() => _error = 'Seleccioná un cliente');
      return;
    }
    if (_planId == null) {
      setState(() => _error = 'Seleccioná un plan');
      return;
    }
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) {
      setState(() => _error = 'No se pudo determinar el tenant');
      return;
    }

    setState(() {
      _guardando = true;
      _error = null;
    });

    try {
      final fechaFin = _fechaFin();
      if (_esEdicion) {
        await ps.db.execute(
          '''
          UPDATE contratos
             SET plan_id = ?, dia_pago = ?,
                 fecha_inicio = ?, fecha_fin = ?, activo = ?
           WHERE id = ?
          ''',
          [
            _planId,
            int.parse(_diaPagoCtrl.text),
            _fechaInicio.toIso8601String().substring(0, 10),
            fechaFin?.toIso8601String().substring(0, 10),
            _activo ? 1 : 0,
            widget.contratoId,
          ],
        );
      } else {
        await ps.db.execute(
          '''
          INSERT INTO contratos (
            id, tenant_id, cliente_id, plan_id, dia_pago,
            fecha_inicio, fecha_fin, activo, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
          ''',
          [
            const Uuid().v4(),
            tenantId,
            _clienteId,
            _planId,
            int.parse(_diaPagoCtrl.text),
            _fechaInicio.toIso8601String().substring(0, 10),
            fechaFin?.toIso8601String().substring(0, 10),
            DateTime.now().toIso8601String(),
          ],
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_esEdicion
                ? 'Cambios guardados. Cuotas futuras se ajustaron automáticamente.'
                : 'Contrato creado. Cuotas generadas automáticamente.'),
          ),
        );
        context.go('/admin/contratos');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return const Center(child: CircularProgressIndicator());
    }
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Cliente y plan',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _ClienteSelector(
                    clienteId: _clienteId,
                    enabled: !_esEdicion,
                    onChanged: (id) => setState(() => _clienteId = id),
                  ),
                  const SizedBox(height: 12),
                  _PlanSelector(
                    planId: _planId,
                    onChanged: (id) => setState(() => _planId = id),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Términos',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _SelectorFecha(
                    label: 'Fecha de instalación',
                    fecha: _fechaInicio,
                    onChanged: (d) => setState(() {
                      _fechaInicio = d;
                      // El día de pago default sigue el día de instalación
                      // (regla del negocio: 'instalado el 17 paga los 17').
                      // El admin puede editar el campo después si quiere.
                      _diaPagoCtrl.text = d.day.toString();
                    }),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _diaPagoCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Día de pago (1-31)',
                      helperText:
                          'Si el mes no tiene ese día, cobra el último día disponible.',
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(2),
                    ],
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      if (n == null || n < 1 || n > 31) return 'Entre 1 y 31';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  Text('Duración',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SegmentedButton<_Duracion>(
                    segments: const [
                      ButtonSegment(value: _Duracion.unAno, label: Text('1 año')),
                      ButtonSegment(value: _Duracion.dosAnos, label: Text('2 años')),
                      ButtonSegment(
                          value: _Duracion.indefinido, label: Text('Indefinido')),
                    ],
                    selected: {_duracion},
                    onSelectionChanged: (s) =>
                        setState(() => _duracion = s.first),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _Duracion.indefinido == _duracion
                          ? 'Se generan 3 cuotas iniciales. El cron mantiene un colchón de 3 meses adelante automáticamente.'
                          : 'Se generan todas las cuotas hasta ${Fmt.fechaCorta(_fechaFin()!)} al guardar.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (_esEdicion) ...[
                    const Divider(),
                    SwitchListTile(
                      value: _activo,
                      onChanged: (v) => setState(() => _activo = v),
                      title: Text(_activo ? 'Contrato activo' : 'Cancelado'),
                      subtitle: !_activo
                          ? const Text(
                              'No se generarán nuevas cuotas. Las pendientes siguen vivas.',
                              style: TextStyle(fontSize: 12),
                            )
                          : null,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!),
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _guardando
                      ? null
                      : () => context.go('/admin/contratos'),
                  child: const Text('Cancelar'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  icon: _guardando
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(_guardando
                      ? 'Guardando...'
                      : (_esEdicion ? 'Guardar cambios' : 'Crear contrato')),
                  onPressed: _guardando ? null : _guardar,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ClienteSelector extends StatelessWidget {
  const _ClienteSelector({
    required this.clienteId,
    required this.onChanged,
    this.enabled = true,
  });
  final String? clienteId;
  final ValueChanged<String?> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: ps.db.watch(
        'SELECT id, nombre FROM clientes WHERE activo = 1 ORDER BY nombre',
      ),
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        return DropdownButtonFormField<String?>(
          value: clienteId,
          decoration: InputDecoration(
            labelText: 'Cliente *',
            enabled: enabled,
            helperText: !enabled ? 'No se puede cambiar al editar contrato' : null,
          ),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('—')),
            ...rows.map((r) => DropdownMenuItem(
                  value: r['id'] as String,
                  child: Text(r['nombre'] as String),
                )),
          ],
          onChanged: enabled ? onChanged : null,
          validator: (v) => v == null ? 'Requerido' : null,
        );
      },
    );
  }
}

class _PlanSelector extends StatelessWidget {
  const _PlanSelector({required this.planId, required this.onChanged});
  final String? planId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: ps.db.watch(
        'SELECT id, nombre, precio_mensual FROM planes WHERE activo = 1 ORDER BY precio_mensual',
      ),
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        if (rows.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String?>(
                value: null,
                decoration: const InputDecoration(labelText: 'Plan *'),
                items: const [
                  DropdownMenuItem<String?>(value: null, child: Text('—')),
                ],
                onChanged: null,
                validator: (_) => 'Requerido',
              ),
              const SizedBox(height: 8),
              Text(
                'No hay planes creados. Ir a Planes → Nuevo plan.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          );
        }
        return DropdownButtonFormField<String?>(
          value: planId,
          decoration: const InputDecoration(labelText: 'Plan *'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('—')),
            ...rows.map((r) => DropdownMenuItem(
                  value: r['id'] as String,
                  child: Text(
                      '${r['nombre']} · ${Fmt.cordobas(r['precio_mensual'] as num)}'),
                )),
          ],
          onChanged: onChanged,
          validator: (v) => v == null ? 'Requerido' : null,
        );
      },
    );
  }
}

class _SelectorFecha extends StatelessWidget {
  const _SelectorFecha({
    required this.label,
    required this.fecha,
    required this.onChanged,
  });

  final String label;
  final DateTime fecha;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: fecha,
          firstDate: DateTime(2020),
          lastDate: DateTime(2035),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.calendar_today),
        ),
        child: Text(Fmt.fechaCorta(fecha)),
      ),
    );
  }
}
