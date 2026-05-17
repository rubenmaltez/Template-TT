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
  final _diaPagoCtrl = TextEditingController(text: '');
  String? _clienteId;
  String? _planId;
  DateTime _fechaInicio = DateTime.now();
  _Duracion _duracion = _Duracion.unAno;
  bool _guardando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _clienteId = widget.clienteId;
    // Default día_pago = día actual.
    _diaPagoCtrl.text = DateTime.now().day.toString();
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
      final id = const Uuid().v4();
      final fechaFin = _fechaFin();
      await ps.db.execute(
        '''
        INSERT INTO contratos (
          id, tenant_id, cliente_id, plan_id, dia_pago,
          fecha_inicio, fecha_fin, activo, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
        ''',
        [
          id, tenantId, _clienteId, _planId,
          int.parse(_diaPagoCtrl.text),
          _fechaInicio.toIso8601String().substring(0, 10),
          fechaFin?.toIso8601String().substring(0, 10),
          DateTime.now().toIso8601String(),
        ],
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(
              'Contrato creado. Las cuotas se generan automáticamente.')),
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
                    onChanged: (d) => setState(() => _fechaInicio = d),
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
                          ? 'Se generan 3 cuotas iniciales. El sistema mantiene un colchón de 3 meses adelante automáticamente.'
                          : 'Se generan todas las cuotas hasta ${Fmt.fechaCorta(_fechaFin()!)} al crear el contrato.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 12,
                      ),
                    ),
                  ),
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
                  label: Text(_guardando ? 'Creando...' : 'Crear contrato'),
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
  const _ClienteSelector({required this.clienteId, required this.onChanged});
  final String? clienteId;
  final ValueChanged<String?> onChanged;

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
          decoration: const InputDecoration(labelText: 'Cliente *'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('—')),
            ...rows.map((r) => DropdownMenuItem(
                  value: r['id'] as String,
                  child: Text(r['nombre'] as String),
                )),
          ],
          onChanged: onChanged,
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
          locale: const Locale('es', 'NI'),
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
