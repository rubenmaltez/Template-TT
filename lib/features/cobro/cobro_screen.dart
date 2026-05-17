import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import '../../data/models/cuota.dart';
import '../../data/models/pago.dart';
import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/foto_comprobante_provider.dart';
import '../../data/repositories/cuotas_repo.dart';
import '../../data/repositories/pagos_repo.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/services/gps_service.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/aplicar_cargo_dialog.dart';
import '../shared/widgets/empty_state.dart';

class CobroScreen extends ConsumerStatefulWidget {
  const CobroScreen({super.key, required this.cuotaId});
  final String cuotaId;

  @override
  ConsumerState<CobroScreen> createState() => _CobroScreenState();
}

class _CobroScreenState extends ConsumerState<CobroScreen> {
  final _formKey = GlobalKey<FormState>();
  final _montoCtrl = TextEditingController();
  final _referenciaCtrl = TextEditingController();
  final _notasCtrl = TextEditingController();

  Moneda _moneda = Moneda.nio;
  MetodoPago _metodo = MetodoPago.efectivo;
  bool _enviando = false;
  String? _error;
  Cuota? _cuota;
  Map<String, dynamic>? _clienteRow;
  double _totalACobrar = 0;
  // Tasa snapshot al iniciar el cobro: si el setting cambia entre el
  // render y el submit, igual usamos la tasa que el cobrador VIO.
  double? _tasaSnapshot;
  // Ubicación capturada en background al abrir la pantalla.
  ({double lat, double lng})? _ubicacion;
  bool _capturandoUbicacion = false;
  // Path local de la foto del comprobante (prefijo 'local://').
  String? _fotoPath;

  @override
  void initState() {
    super.initState();
    // Evita 'setState() called during build' — el bool inicial se asigna
    // directo. El setState llega cuando termina la captura (post first frame).
    _capturandoUbicacion = true;
    _cargar();
    _capturarUbicacion();
  }

  /// Captura GPS en background al abrir la pantalla. Si tarda o falla,
  /// el cobro continúa sin coordenadas — no es bloqueante.
  Future<void> _capturarUbicacion() async {
    final ubi = await const GpsService().obtenerUbicacion();
    if (mounted) {
      setState(() {
        _ubicacion = ubi;
        _capturandoUbicacion = false;
      });
    }
  }

  void _cambiarMoneda(Moneda nueva, AppSettings settings) {
    if (nueva == _moneda) return;
    setState(() {
      _moneda = nueva;
      _tasaSnapshot = settings.tasaUsd;
      // Reset del campo: si el cobrador escribió "500" en NIO y cambia a USD,
      // 500 USD ≠ 500 NIO (sería cobrar 36× más). Forzamos re-ingresar.
      _montoCtrl.clear();
    });
  }

  Future<void> _cargar() async {
    final repo = ref.read(cuotasRepoProvider);
    final cuota = await repo.getById(widget.cuotaId);
    if (cuota == null) return;

    final cliRows = await ps.db.getAll(
      '''
      SELECT c.nombre, c.cedula, c.telefono, co.nombre AS comunidad
        FROM clientes c
   LEFT JOIN comunidades co ON co.id = c.comunidad_id
       WHERE c.id = ?
      ''',
      [cuota.clienteId],
    );
    final total = await repo.totalACobrar(widget.cuotaId);

    if (!mounted) return;
    setState(() {
      _cuota = cuota;
      _clienteRow = cliRows.isEmpty ? null : cliRows.first;
      _totalACobrar = total;
      // Default: cobrar el saldo completo.
      final saldo = total - cuota.montoPagado;
      _montoCtrl.text = saldo.clamp(0, total).toStringAsFixed(2);
    });
  }

  @override
  void dispose() {
    _montoCtrl.dispose();
    _referenciaCtrl.dispose();
    _notasCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirmar() async {
    if (!_formKey.currentState!.validate()) return;
    final cuota = _cuota;
    if (cuota == null) return;
    final cobrador = ref.read(cobradorActualProvider).valueOrNull;
    if (cobrador == null || cobrador.prefijoRecibo == null) {
      setState(() => _error = 'No tenés prefijo de recibo asignado. Pedile al admin que te lo configure.');
      return;
    }
    final settings = ref.read(appSettingsProvider);

    final monto = double.parse(_montoCtrl.text);
    final tasa = _moneda == Moneda.usd
        ? (_tasaSnapshot ?? settings.tasaUsd)
        : 1.0;
    final montoCordobas = monto * tasa;

    setState(() {
      _enviando = true;
      _error = null;
    });

    try {
      final result = await ref.read(pagosRepoProvider).registrarCobro(
            tenantId: cobrador.tenantId,
            cobradorId: cobrador.id,
            prefijoRecibo: cobrador.prefijoRecibo!,
            cuotaId: cuota.id,
            montoCordobas: montoCordobas,
            moneda: _moneda,
            montoOriginal: monto,
            tasaConversion: tasa,
            metodo: _metodo,
            referencia: _referenciaCtrl.text.trim().isEmpty
                ? null
                : _referenciaCtrl.text.trim(),
            fotoComprobantePath: _fotoPath,
            lat: _ubicacion?.lat,
            lng: _ubicacion?.lng,
            notas: _notasCtrl.text.trim().isEmpty
                ? null
                : _notasCtrl.text.trim(),
          );
      if (!mounted) return;
      context.pushReplacement('/recibo/${result.reciboId}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;

    if (_cuota == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Cobrar')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // El botón confirmar requiere cobrador con prefijo asignado.
    final puedeConfirmar =
        !_enviando && cobrador != null && (cobrador.prefijoRecibo ?? '').isNotEmpty;
    final mensajeDeshabilitado = cobrador == null
        ? 'Esperando datos del cobrador...'
        : (cobrador.prefijoRecibo ?? '').isEmpty
            ? 'Tu prefijo de recibo no está configurado. Pedile al admin que te lo asigne.'
            : null;

    final cuota = _cuota!;
    final saldo = (_totalACobrar - cuota.montoPagado).clamp(0, double.infinity);

    final montoEnNio = _moneda == Moneda.usd
        ? (double.tryParse(_montoCtrl.text) ?? 0) * settings.tasaUsd
        : double.tryParse(_montoCtrl.text) ?? 0;

    final esCompleto = montoEnNio >= saldo - 0.01;

    return Scaffold(
      appBar: AppBar(
        title: Text(_clienteRow?['nombre'] ?? 'Cobrar'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: [
          _ClienteCuotaCard(cliente: _clienteRow, cuota: cuota, totalACobrar: _totalACobrar),
          if (settings.descuentosHabilitados || settings.reconexionHabilitada) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.discount),
              label: const Text('Aplicar descuento / cargo'),
              onPressed: () async {
                final aplicado = await showDialog<bool>(
                  context: context,
                  builder: (_) => AplicarCargoDialog(
                    cuotaId: cuota.id,
                    montoCuota: cuota.monto,
                  ),
                );
                if (aplicado == true) {
                  final repo = ref.read(cuotasRepoProvider);
                  final nuevo = await repo.totalACobrar(widget.cuotaId);
                  if (mounted) {
                    setState(() {
                      _totalACobrar = nuevo;
                      // Reajustar default del monto al nuevo saldo.
                      final saldo = (nuevo - cuota.montoPagado)
                          .clamp(0.0, double.infinity);
                      _montoCtrl.text = saldo.toStringAsFixed(2);
                    });
                  }
                }
              },
            ),
          ],

          const SizedBox(height: 24),
          Text('Método de pago', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _MetodosWrap(
            actual: _metodo,
            settings: settings,
            onSelected: (m) {
              setState(() {
                _metodo = m;
                // Si el método ya no requiere comprobante, descartar
                // la foto adjunta para no asociarla a un pago en efectivo.
                if (!m.requiereComprobante) _fotoPath = null;
              });
            },
          ),

          const SizedBox(height: 24),
          Row(
            children: [
              Text('Monto', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (settings.usdHabilitado) _MonedaToggle(
                actual: _moneda,
                onChanged: (m) => _cambiarMoneda(m, settings),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _montoCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: InputDecoration(
              prefixText: _moneda.symbol + ' ',
              hintText: '0.00',
            ),
            onChanged: (_) => setState(() {}),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Ingresá un monto';
              final n = double.tryParse(v);
              if (n == null || n <= 0) return 'Monto inválido';
              final nio = _moneda == Moneda.usd ? n * settings.tasaUsd : n;
              if (nio > saldo + 0.01) return 'Excede el saldo (${Fmt.cordobas(saldo)})';
              return null;
            },
          ),
          if (_moneda == Moneda.usd)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Equivalente: ${Fmt.cordobas(montoEnNio)} (tasa ${settings.tasaUsd})',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),

          if (_metodo.requiereComprobante) ...[
            const SizedBox(height: 24),
            TextFormField(
              controller: _referenciaCtrl,
              decoration: const InputDecoration(
                labelText: 'Número de referencia / confirmación',
              ),
              validator: (v) {
                final hayFoto = _fotoPath != null;
                final hayRef = (v ?? '').trim().isNotEmpty;
                if (_metodo.requiereComprobante && !hayRef && !hayFoto) {
                  return 'Ingresá referencia o adjuntá foto';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            _FotoComprobantePicker(
              path: _fotoPath,
              onPicked: (p) => setState(() => _fotoPath = p),
            ),
          ],

          const SizedBox(height: 24),
          TextFormField(
            controller: _notasCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Notas (opcional)',
            ),
          ),

          const SizedBox(height: 24),
          _UbicacionIndicador(
            capturando: _capturandoUbicacion,
            ubicacion: _ubicacion,
          ),
          const SizedBox(height: 12),
          _ResumenCard(
            saldoActual: saldo,
            aCobrar: montoEnNio,
            esCompleto: esCompleto,
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
              ),
            ),
          ],

          const SizedBox(height: 24),
          if (mensajeDeshabilitado != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                mensajeDeshabilitado,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          FilledButton.icon(
            onPressed: puedeConfirmar ? _confirmar : null,
            icon: _enviando
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: Text(_enviando ? 'Procesando...' : 'Confirmar cobro'),
          ),
        ],
        ),
      ),
    );
  }
}

class _ClienteCuotaCard extends StatelessWidget {
  const _ClienteCuotaCard({
    required this.cliente,
    required this.cuota,
    required this.totalACobrar,
  });

  final Map<String, dynamic>? cliente;
  final Cuota cuota;
  final double totalACobrar;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(cliente?['nombre'] ?? '—',
                style: Theme.of(context).textTheme.titleMedium),
            if (cliente?['comunidad'] != null)
              Text(cliente!['comunidad'] as String,
                  style: TextStyle(color: scheme.outline, fontSize: 12)),
            const Divider(height: 24),
            Row(
              children: [
                const Icon(Icons.calendar_today, size: 18),
                const SizedBox(width: 8),
                Text('Cuota de ${Fmt.mes(cuota.periodo)[0].toUpperCase()}${Fmt.mes(cuota.periodo).substring(1)}'),
                const Spacer(),
                Text(Fmt.cordobas(cuota.monto),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            if (totalACobrar != cuota.monto) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const SizedBox(width: 26),
                  Text(
                    'Con descuentos/cargos: ${Fmt.cordobas(totalACobrar)}',
                    style: TextStyle(color: scheme.outline, fontSize: 12),
                  ),
                ],
              ),
            ],
            if (cuota.montoPagado > 0) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const SizedBox(width: 26),
                  Text(
                    'Ya pagado: ${Fmt.cordobas(cuota.montoPagado)}',
                    style: TextStyle(color: scheme.tertiary, fontSize: 12),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetodosWrap extends StatelessWidget {
  const _MetodosWrap({
    required this.actual,
    required this.settings,
    required this.onSelected,
  });

  final MetodoPago actual;
  final AppSettings settings;
  final ValueChanged<MetodoPago> onSelected;

  @override
  Widget build(BuildContext context) {
    final disponibles = <MetodoPago>[
      MetodoPago.efectivo,
      if (settings.transferenciaHabilitada) MetodoPago.transferencia,
      if (settings.depositoHabilitado) MetodoPago.deposito,
      if (settings.tarjetaHabilitada) MetodoPago.tarjeta,
    ];

    return Wrap(
      spacing: 8,
      children: [
        for (final m in disponibles)
          ChoiceChip(
            label: Text(m.label),
            avatar: Icon(_icon(m), size: 18),
            selected: actual == m,
            onSelected: (_) => onSelected(m),
          ),
      ],
    );
  }

  IconData _icon(MetodoPago m) => switch (m) {
        MetodoPago.efectivo => Icons.payments,
        MetodoPago.transferencia => Icons.swap_horiz,
        MetodoPago.deposito => Icons.account_balance,
        MetodoPago.tarjeta => Icons.credit_card,
      };
}

class _MonedaToggle extends StatelessWidget {
  const _MonedaToggle({required this.actual, required this.onChanged});
  final Moneda actual;
  final ValueChanged<Moneda> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<Moneda>(
      segments: const [
        ButtonSegment(value: Moneda.nio, label: Text('C\$')),
        ButtonSegment(value: Moneda.usd, label: Text('US\$')),
      ],
      selected: {actual},
      onSelectionChanged: (s) => onChanged(s.first),
      style: const ButtonStyle(
        visualDensity: VisualDensity(horizontal: -2, vertical: -2),
      ),
    );
  }
}

class _FotoComprobantePicker extends ConsumerStatefulWidget {
  const _FotoComprobantePicker({required this.path, required this.onPicked});
  final String? path;
  final ValueChanged<String?> onPicked;

  @override
  ConsumerState<_FotoComprobantePicker> createState() =>
      _FotoComprobantePickerState();
}

class _FotoComprobantePickerState
    extends ConsumerState<_FotoComprobantePicker> {
  Uint8List? _bytes;

  @override
  void didUpdateWidget(covariant _FotoComprobantePicker old) {
    super.didUpdateWidget(old);
    if (widget.path != old.path) _resolverBytes();
  }

  @override
  void initState() {
    super.initState();
    // Caso sincrónico: path null → bytes null. No usar setState (pre-build).
    if (widget.path == null) {
      _bytes = null;
    } else {
      _resolverBytes();
    }
  }

  Future<void> _resolverBytes() async {
    final b = widget.path == null
        ? null
        : await ref
            .read(fotoComprobanteServiceProvider)
            .bytesLocal(widget.path);
    if (mounted) setState(() => _bytes = b);
  }

  Future<void> _elegir(ImageSource source) async {
    try {
      final p = await ref
          .read(fotoComprobanteServiceProvider)
          .capturar(source: source);
      if (p != null) widget.onPicked(p);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo capturar: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              _bytes!,
              height: 180,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Cambiar'),
                  onPressed: () => _mostrarFuente(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Quitar'),
                  onPressed: () => widget.onPicked(null),
                ),
              ),
            ],
          ),
        ],
      );
    }

    return OutlinedButton.icon(
      icon: const Icon(Icons.camera_alt),
      label: const Text('Adjuntar foto del comprobante'),
      onPressed: _mostrarFuente,
    );
  }

  void _mostrarFuente() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Tomar foto'),
              onTap: () {
                Navigator.pop(ctx);
                _elegir(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Elegir de galería'),
              onTap: () {
                Navigator.pop(ctx);
                _elegir(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _UbicacionIndicador extends StatelessWidget {
  const _UbicacionIndicador({
    required this.capturando,
    required this.ubicacion,
  });
  final bool capturando;
  final ({double lat, double lng})? ubicacion;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, label, color) = capturando
        ? (Icons.gps_not_fixed, 'Capturando ubicación...', scheme.outline)
        : ubicacion != null
            ? (Icons.gps_fixed, 'Ubicación capturada', scheme.tertiary)
            : (Icons.gps_off, 'Sin ubicación (cobro continúa)', scheme.outline);

    return Row(
      children: [
        if (capturando)
          const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
        else
          Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: color, fontSize: 12)),
      ],
    );
  }
}

class _ResumenCard extends StatelessWidget {
  const _ResumenCard({
    required this.saldoActual,
    required this.aCobrar,
    required this.esCompleto,
  });

  final double saldoActual;
  final double aCobrar;
  final bool esCompleto;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final saldoFinal = (saldoActual - aCobrar).clamp(0, double.infinity);
    return Card(
      color: esCompleto ? scheme.tertiaryContainer : scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _row('Saldo actual', Fmt.cordobas(saldoActual)),
            const SizedBox(height: 4),
            _row('A cobrar ahora', Fmt.cordobas(aCobrar), bold: true),
            const Divider(),
            _row(
              esCompleto ? 'Cuota completa ✓' : 'Saldo restante',
              Fmt.cordobas(saldoFinal.toDouble()),
              color: esCompleto ? scheme.tertiary : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false, Color? color}) {
    return Row(
      children: [
        Text(label),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            color: color,
          ),
        ),
      ],
    );
  }
}
