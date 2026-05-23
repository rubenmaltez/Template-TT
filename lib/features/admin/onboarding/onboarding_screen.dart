import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/phone_text_field.dart';

/// Wizard de onboarding del tenant: el admin completa configuración mínima
/// la primera vez que entra. Se accede via `/admin/onboarding` y el router
/// lo dispara cuando `empresa.nombre` está vacío.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _empresaNombre = TextEditingController();
  final _empresaDireccion = TextEditingController();
  final _empresaTelefono = TextEditingController();
  final _empresaRuc = TextEditingController();
  final _tasaUsd = TextEditingController(text: '36.50');
  final _diasGracia = TextEditingController(text: '10');
  final _primerPlanNombre = TextEditingController(text: 'Internet 10MB');
  final _primerPlanPrecio = TextEditingController(text: '750');

  int _paso = 0;
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _empresaNombre.dispose();
    _empresaDireccion.dispose();
    _empresaTelefono.dispose();
    _empresaRuc.dispose();
    _tasaUsd.dispose();
    _diasGracia.dispose();
    _primerPlanNombre.dispose();
    _primerPlanPrecio.dispose();
    super.dispose();
  }

  bool _puedeAvanzar() {
    switch (_paso) {
      case 0:
        return _empresaNombre.text.trim().isNotEmpty;
      case 1:
        final tasa = double.tryParse(_tasaUsd.text);
        final dias = int.tryParse(_diasGracia.text);
        return tasa != null && tasa > 0 && dias != null && dias >= 0;
      case 2:
        // Plan opcional: si llenó nombre, validar precio.
        if (_primerPlanNombre.text.trim().isEmpty) return true;
        final p = double.tryParse(_primerPlanPrecio.text);
        return p != null && p > 0;
      default:
        return false;
    }
  }

  Future<void> _finalizar() async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) {
      setState(() => _error = 'Sin tenant');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final repo = ref.read(settingsRepoProvider);
      await repo.update(tenantId, 'empresa.nombre', _empresaNombre.text.trim());
      await repo.update(tenantId, 'empresa.direccion', _empresaDireccion.text.trim());
      await repo.update(tenantId, 'empresa.telefono',
          PhoneTextField.sanitized(_empresaTelefono) ?? '');
      await repo.update(tenantId, 'empresa.ruc', _empresaRuc.text.trim());
      await repo.update(tenantId, 'pagos.tasa_usd_cordoba',
          double.parse(_tasaUsd.text));
      await repo.update(tenantId, 'cobranza.dias_gracia',
          int.parse(_diasGracia.text));

      if (_primerPlanNombre.text.trim().isNotEmpty) {
        await ps.db.execute(
          '''
          INSERT INTO planes (id, tenant_id, nombre, tipo, precio_mensual,
                              activo, created_at)
          VALUES (?, ?, ?, 'internet', ?, 1, ?)
          ''',
          [
            const Uuid().v4(),
            tenantId,
            _primerPlanNombre.text.trim(),
            double.parse(_primerPlanPrecio.text),
            DateTime.now().toIso8601String(),
          ],
        );
      }

      if (mounted) context.go('/admin');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.rocket_launch, color: scheme.primary, size: 32),
                        const SizedBox(width: 12),
                        Text('Configuración inicial',
                            style: Theme.of(context).textTheme.headlineSmall),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Paso ${_paso + 1} de 3',
                      style: TextStyle(color: scheme.outline),
                    ),
                    const SizedBox(height: 24),
                    if (_paso == 0) _PasoEmpresa(
                      nombre: _empresaNombre,
                      direccion: _empresaDireccion,
                      telefono: _empresaTelefono,
                      ruc: _empresaRuc,
                      onChange: () => setState(() {}),
                    ),
                    if (_paso == 1) _PasoCobranza(
                      tasa: _tasaUsd,
                      diasGracia: _diasGracia,
                      onChange: () => setState(() {}),
                    ),
                    if (_paso == 2) _PasoPlan(
                      nombre: _primerPlanNombre,
                      precio: _primerPlanPrecio,
                      onChange: () => setState(() {}),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!,
                          style: TextStyle(color: scheme.error)),
                    ],
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        if (_paso > 0)
                          OutlinedButton(
                            onPressed: _guardando
                                ? null
                                : () => setState(() => _paso--),
                            child: const Text('Atrás'),
                          ),
                        const Spacer(),
                        FilledButton.icon(
                          icon: _guardando
                              ? const SizedBox(
                                  width: 16, height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : Icon(_paso == 2 ? Icons.check : Icons.arrow_forward),
                          label: Text(_paso == 2 ? 'Finalizar' : 'Siguiente'),
                          onPressed: !_puedeAvanzar() || _guardando
                              ? null
                              : () {
                                  if (_paso == 2) {
                                    _finalizar();
                                  } else {
                                    setState(() => _paso++);
                                  }
                                },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PasoEmpresa extends StatelessWidget {
  const _PasoEmpresa({
    required this.nombre,
    required this.direccion,
    required this.telefono,
    required this.ruc,
    required this.onChange,
  });
  final TextEditingController nombre;
  final TextEditingController direccion;
  final TextEditingController telefono;
  final TextEditingController ruc;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Datos de tu empresa',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('Aparecen en los recibos impresos.',
            style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        const SizedBox(height: 16),
        TextField(
          controller: nombre,
          decoration: const InputDecoration(labelText: 'Nombre comercial *'),
          onChanged: (_) => onChange(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: direccion,
          decoration: const InputDecoration(labelText: 'Dirección'),
        ),
        const SizedBox(height: 12),
        PhoneTextField(
          controller: telefono,
          hint: '+505 2222-3333',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: ruc,
          decoration: const InputDecoration(labelText: 'RUC'),
        ),
      ],
    );
  }
}

class _PasoCobranza extends StatelessWidget {
  const _PasoCobranza({
    required this.tasa,
    required this.diasGracia,
    required this.onChange,
  });
  final TextEditingController tasa;
  final TextEditingController diasGracia;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Cobranza',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('Podés cambiarlo después desde Configuración.',
            style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        const SizedBox(height: 16),
        TextField(
          controller: tasa,
          decoration: const InputDecoration(
            labelText: 'Tasa USD → C\$',
            helperText: 'Usada al cobrar en dólares.',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          onChanged: (_) => onChange(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: diasGracia,
          decoration: const InputDecoration(
            labelText: 'Días de gracia',
            helperText:
                'Tiempo entre vencimiento y notificación de mora (típico: 10).',
          ),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => onChange(),
        ),
      ],
    );
  }
}

class _PasoPlan extends StatelessWidget {
  const _PasoPlan({
    required this.nombre,
    required this.precio,
    required this.onChange,
  });
  final TextEditingController nombre;
  final TextEditingController precio;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Primer plan (opcional)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('Podés agregar más planes después desde la sección Planes. '
            'Dejá vacío si querés saltarlo.',
            style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        const SizedBox(height: 16),
        TextField(
          controller: nombre,
          decoration: const InputDecoration(
            labelText: 'Nombre del plan',
            hintText: 'Internet 10MB',
          ),
          onChanged: (_) => onChange(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: precio,
          decoration: const InputDecoration(
            labelText: 'Precio mensual (C\$)',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          onChanged: (_) => onChange(),
        ),
      ],
    );
  }
}
