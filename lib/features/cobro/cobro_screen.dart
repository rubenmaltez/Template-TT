import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import 'package:uuid/uuid.dart';

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
  const CobroScreen({super.key, required this.cuotaIds});
  final List<String> cuotaIds;

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

  // Multi-cuota: lista de cuotas y sus totales a cobrar.
  final List<Cuota> _cuotas = [];
  final List<double> _totalesACobrar = [];
  Map<String, dynamic>? _clienteRow;
  double _totalACobrar = 0;
  double? _tasaSnapshot;
  ({double lat, double lng})? _ubicacion;
  bool _capturandoUbicacion = false;
  String? _fotoPath;
  DateTime _fechaCobro = DateTime.now();

  // C3/C4: cargos automáticos detectados.
  final List<_CargoAutoPreview> _cargosAuto = [];

  bool get _esMultiCuota => widget.cuotaIds.length > 1;

  // Backward compat.
  Cuota? get _cuota => _cuotas.isEmpty ? null : _cuotas.first;

  @override
  void initState() {
    super.initState();
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
    final settings = ref.read(appSettingsProvider);
    final cuotas = <Cuota>[];
    final totales = <double>[];

    for (final id in widget.cuotaIds) {
      final cuota = await repo.getById(id);
      if (cuota == null) continue;
      cuotas.add(cuota);
      totales.add(await repo.totalACobrar(id));
    }
    if (cuotas.isEmpty) return;

    final cliRows = await ps.db.getAll(
      '''
      SELECT c.nombre, c.cedula, c.telefono, co.nombre AS comunidad
        FROM clientes c
   LEFT JOIN comunidades co ON co.id = c.comunidad_id
       WHERE c.id = ?
      ''',
      [cuotas.first.clienteId],
    );

    // C3: detectar cuotas vencidas que necesitan cargo reconexión.
    final cargos = <_CargoAutoPreview>[];
    if (settings.reconexionHabilitada && settings.montoReconexion > 0) {
      final diasGracia = settings.diasGracia;
      final hoy = DateTime.now();
      for (final cu in cuotas) {
        final vence = cu.fechaVencimiento;
        final diasPasados = hoy.difference(vence).inDays;
        if (diasPasados > diasGracia &&
            (cu.estado == 'pendiente' || cu.estado == 'parcial')) {
          // Verificar que no haya ya un cargo reconexión para esta cuota.
          final existing = await ps.db.getAll(
            "SELECT id FROM cargos_extra WHERE cuota_id = ? AND tipo = 'reconexion'",
            [cu.id],
          );
          if (existing.isEmpty) {
            cargos.add(_CargoAutoPreview(
              cuotaId: cu.id,
              tipo: 'reconexion',
              monto: settings.montoReconexion,
              descripcion: 'Cargo por reconexión',
            ));
          }
        }
      }
    }

    // C4: detectar pago adelantado para descuento pronto pago.
    final descuento = settings.descuentoProntoPago;
    if (descuento > 0) {
      final hoy = DateTime.now();
      for (var i = 0; i < cuotas.length; i++) {
        final cu = cuotas[i];
        if (hoy.isBefore(cu.fechaVencimiento)) {
          // Verificar que no haya ya un descuento pronto pago.
          final existing = await ps.db.getAll(
            "SELECT id FROM cargos_extra WHERE cuota_id = ? AND tipo IN ('descuento_monto','descuento_porcentaje')"
            " AND descripcion = 'Descuento pronto pago'",
            [cu.id],
          );
          if (existing.isEmpty) {
            final esPorcentaje = descuento < 100;
            final montoDescuento = esPorcentaje
                ? cuotas[i].monto * descuento / 100
                : descuento;
            cargos.add(_CargoAutoPreview(
              cuotaId: cu.id,
              tipo: esPorcentaje ? 'descuento_porcentaje' : 'descuento_monto',
              monto: montoDescuento,
              porcentaje: esPorcentaje ? descuento : null,
              descripcion: 'Descuento pronto pago',
            ));
          }
        }
      }
    }

    // Ajustar totales con cargos automáticos.
    for (final cargo in cargos) {
      final idx = cuotas.indexWhere((c) => c.id == cargo.cuotaId);
      if (idx < 0) continue;
      if (cargo.tipo == 'reconexion') {
        totales[idx] += cargo.monto;
      } else {
        totales[idx] -= cargo.monto;
        if (totales[idx] < 0) totales[idx] = 0;
      }
    }

    final totalGlobal = totales.fold(0.0, (s, t) => s + t);

    if (!mounted) return;
    setState(() {
      _cuotas.addAll(cuotas);
      _totalesACobrar.addAll(totales);
      _clienteRow = cliRows.isEmpty ? null : cliRows.first;
      _totalACobrar = totalGlobal;
      _cargosAuto.addAll(cargos);
      // Default: cobrar el saldo completo de todas las cuotas.
      var saldo = 0.0;
      for (var i = 0; i < cuotas.length; i++) {
        saldo += (totales[i] - cuotas[i].montoPagado).clamp(0.0, double.infinity);
      }
      _montoCtrl.text = saldo.toStringAsFixed(2);
    });
  }

  @override
  void dispose() {
    _montoCtrl.dispose();
    _referenciaCtrl.dispose();
    _notasCtrl.dispose();
    super.dispose();
  }

  Future<void> _cancelar(BuildContext context) async {
    // Si hay datos significativos cargados, confirmar antes de descartar.
    final hayDatos = _montoCtrl.text.trim().isNotEmpty &&
        double.tryParse(_montoCtrl.text) != null &&
        double.parse(_montoCtrl.text) > 0;
    final tieneFoto = _fotoPath != null;
    final tieneRef = _referenciaCtrl.text.trim().isNotEmpty;
    if (hayDatos || tieneFoto || tieneRef) {
      final descartar = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('¿Descartar cobro?'),
          content: const Text('Vas a perder el monto/foto/referencia '
              'cargados. Esta cuota queda sin cobrar.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Seguir editando'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError,
              ),
              child: const Text('Descartar'),
            ),
          ],
        ),
      );
      if (descartar != true) return;
    }
    if (context.mounted) context.pop();
  }

  Future<void> _confirmar() async {
    if (!_formKey.currentState!.validate()) return;
    if (_cuotas.isEmpty) return;
    final cobrador = ref.read(cobradorActualProvider).valueOrNull;
    if (cobrador == null || cobrador.prefijoRecibo == null) {
      setState(() => _error = 'No tenés prefijo de recibo asignado. Pedile al admin que te lo configure.');
      return;
    }
    final settings = ref.read(appSettingsProvider);
    final tasa = _moneda == Moneda.usd
        ? (_tasaSnapshot ?? settings.tasaUsd)
        : 1.0;

    setState(() {
      _enviando = true;
      _error = null;
    });

    try {
      final CobroResultado result;
      if (_esMultiCuota) {
        // Multi-cuota: distribuir el monto proporcionalmente entre cuotas.
        final montosNIO = <double>[];
        final montosOrig = <double>[];
        for (var i = 0; i < _cuotas.length; i++) {
          final saldo = (_totalesACobrar[i] - _cuotas[i].montoPagado)
              .clamp(0.0, double.infinity);
          montosNIO.add(saldo);
          montosOrig.add(_moneda == Moneda.usd ? saldo / tasa : saldo);
        }

        final cargosInfo = _cargosAuto
            .map((c) => CargoAutoInfo(
                  cuotaId: c.cuotaId,
                  tipo: c.tipo,
                  monto: c.monto,
                  porcentaje: c.porcentaje,
                  descripcion: c.descripcion,
                ))
            .toList();

        result = await ref.read(pagosRepoProvider).registrarCobroMultiple(
              tenantId: cobrador.tenantId,
              cobradorId: cobrador.id,
              prefijoRecibo: cobrador.prefijoRecibo!,
              cuotaIds: _cuotas.map((c) => c.id).toList(),
              montosCordobas: montosNIO,
              moneda: _moneda,
              montosOriginal: montosOrig,
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
              fechaPago: _fechaCobro,
              cargosAuto: cargosInfo.isEmpty ? null : cargosInfo,
            );
      } else {
        // Single cuota: flow original.
        final monto = double.parse(_montoCtrl.text);
        final montoCordobas = monto * tasa;

        // Insertar cargos auto si hay (C3/C4 para single cuota).
        if (_cargosAuto.isNotEmpty) {
          final now = DateTime.now().toIso8601String();
          for (final cargo in _cargosAuto) {
            await ps.db.execute(
              '''
              INSERT INTO cargos_extra (
                id, tenant_id, cuota_id, cobrador_id, tipo, monto,
                porcentaje, descripcion, aplicado_por, aplicado_en, client_local_id
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              ''',
              [
                const Uuid().v4(), cobrador.tenantId, cargo.cuotaId,
                cobrador.id, cargo.tipo, cargo.monto, cargo.porcentaje,
                cargo.descripcion, cobrador.id, now, const Uuid().v4(),
              ],
            );
          }
        }

        result = await ref.read(pagosRepoProvider).registrarCobro(
              tenantId: cobrador.tenantId,
              cobradorId: cobrador.id,
              prefijoRecibo: cobrador.prefijoRecibo!,
              cuotaId: _cuotas.first.id,
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
              fechaPago: _fechaCobro,
            );
      }

      if (!mounted) return;

      if (result.esMultiCuota) {
        // Multi-cuota: navegar al primer recibo (el screen agrupa por grupo_cobro).
        context.pushReplacement('/recibo/${result.reciboId}?grupo=${result.grupoCobro}');
      } else {
        context.pushReplacement('/recibo/${result.reciboId}');
      }
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

    // Si el método seleccionado fue deshabilitado en settings, corregir
    // al primer método disponible para evitar un estado inválido.
    final metodosDisponibles = <MetodoPago>[
      if (settings.efectivoHabilitado) MetodoPago.efectivo,
      if (settings.transferenciaHabilitada) MetodoPago.transferencia,
      if (settings.depositoHabilitado) MetodoPago.deposito,
      if (settings.tarjetaHabilitada) MetodoPago.tarjeta,
    ];
    if (metodosDisponibles.isNotEmpty && !metodosDisponibles.contains(_metodo)) {
      // Schedule después del build para evitar setState durante build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _metodo = metodosDisponibles.first);
      });
    }

    if (_cuotas.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Cobrar')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final puedeConfirmar =
        !_enviando && cobrador != null && (cobrador.prefijoRecibo ?? '').isNotEmpty;
    final mensajeDeshabilitado = cobrador == null
        ? 'Esperando datos del cobrador...'
        : (cobrador.prefijoRecibo ?? '').isEmpty
            ? 'Tu prefijo de recibo no está configurado. Pedile al admin que te lo asigne.'
            : null;

    final cuota = _cuotas.first;
    var saldo = 0.0;
    for (var i = 0; i < _cuotas.length; i++) {
      saldo += (_totalesACobrar[i] - _cuotas[i].montoPagado).clamp(0.0, double.infinity);
    }

    final montoEnNio = _moneda == Moneda.usd
        ? (double.tryParse(_montoCtrl.text) ?? 0) * settings.tasaUsd
        : double.tryParse(_montoCtrl.text) ?? 0;

    final esCompleto = montoEnNio >= saldo - 0.01;

    return Scaffold(
      appBar: AppBar(
        title: Text(_esMultiCuota
            ? 'Cobro múltiple (${_cuotas.length} cuotas)'
            : _clienteRow?['nombre'] ?? 'Cobrar'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: [
          if (_esMultiCuota)
            _MultiCuotaCard(
              cliente: _clienteRow,
              cuotas: _cuotas,
              totales: _totalesACobrar,
            )
          else
            _ClienteCuotaCard(cliente: _clienteRow, cuota: cuota, totalACobrar: _totalesACobrar.first),
          // Cargos automáticos (C3/C4).
          if (_cargosAuto.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final cargo in _cargosAuto)
              Card(
                color: cargo.tipo.startsWith('descuento')
                    ? Theme.of(context).colorScheme.tertiaryContainer
                    : Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        cargo.tipo.startsWith('descuento')
                            ? Icons.discount
                            : Icons.add_circle_outline,
                        size: 18,
                        color: cargo.tipo.startsWith('descuento')
                            ? Theme.of(context).colorScheme.onTertiaryContainer
                            : Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(cargo.descripcion)),
                      Text(
                        '${cargo.tipo.startsWith('descuento') ? '-' : '+'}${Fmt.cordobas(cargo.monto)}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          if (!_esMultiCuota && (settings.descuentosHabilitados || settings.reconexionHabilitada)) ...[
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
                  final nuevo = await repo.totalACobrar(_cuotas.first.id);
                  if (mounted) {
                    setState(() {
                      _totalesACobrar[0] = nuevo;
                      _totalACobrar = nuevo;
                      final s = (nuevo - cuota.montoPagado)
                          .clamp(0.0, double.infinity);
                      _montoCtrl.text = s.toStringAsFixed(2);
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
          // Fecha del cobro: editable si el admin lo habilitó.
          if (settings.cobradorEditaFecha) ...[
            const SizedBox(height: 16),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _fechaCobro,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now(),
                  locale: const Locale('es', 'NI'),
                );
                if (picked != null) {
                  setState(() => _fechaCobro = picked);
                }
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Fecha del cobro',
                  prefixIcon: Icon(Icons.calendar_today),
                ),
                child: Text(Fmt.fechaCorta(_fechaCobro)),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _ResumenCard(
            saldoActual: saldo,
            aCobrar: montoEnNio,
            esCompleto: esCompleto,
            cantidadCuotas: _cuotas.length,
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
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _enviando ? null : () => _cancelar(context),
                  child: const Text('Cancelar'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: puedeConfirmar ? _confirmar : null,
                  icon: _enviando
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(_enviando
                      ? 'Procesando...'
                      : _esMultiCuota
                          ? 'Confirmar ${_cuotas.length} cuotas'
                          : 'Confirmar cobro'),
                ),
              ),
            ],
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

class _MultiCuotaCard extends StatelessWidget {
  const _MultiCuotaCard({
    required this.cliente,
    required this.cuotas,
    required this.totales,
  });
  final Map<String, dynamic>? cliente;
  final List<Cuota> cuotas;
  final List<double> totales;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    var totalGeneral = 0.0;
    for (var i = 0; i < cuotas.length; i++) {
      totalGeneral += (totales[i] - cuotas[i].montoPagado).clamp(0.0, double.infinity);
    }

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
            Text('${cuotas.length} cuotas seleccionadas',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                )),
            const SizedBox(height: 8),
            for (var i = 0; i < cuotas.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      'Cuota ${Fmt.mes(cuotas[i].periodo)[0].toUpperCase()}${Fmt.mes(cuotas[i].periodo).substring(1)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const Spacer(),
                    Text(
                      Fmt.cordobas((totales[i] - cuotas[i].montoPagado).clamp(0.0, double.infinity)),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            const Divider(height: 16),
            Row(
              children: [
                Text('Total a cobrar',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    )),
                const Spacer(),
                Text(Fmt.cordobas(totalGeneral),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                      fontSize: 16,
                    )),
              ],
            ),
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
      if (settings.efectivoHabilitado) MetodoPago.efectivo,
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
    this.cantidadCuotas = 1,
  });

  final double saldoActual;
  final double aCobrar;
  final bool esCompleto;
  final int cantidadCuotas;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final saldoFinal = (saldoActual - aCobrar).clamp(0, double.infinity);
    final vuelto = aCobrar > saldoActual ? aCobrar - saldoActual : 0.0;
    return Card(
      color: esCompleto ? scheme.tertiaryContainer : scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _row('Saldo total${cantidadCuotas > 1 ? ' ($cantidadCuotas cuotas)' : ''}',
                Fmt.cordobas(saldoActual)),
            const SizedBox(height: 4),
            _row('A cobrar ahora', Fmt.cordobas(aCobrar), bold: true),
            if (vuelto > 0.01) ...[
              const SizedBox(height: 4),
              _row('Vuelto al cliente', Fmt.cordobas(vuelto),
                  color: scheme.primary, bold: true),
            ],
            const Divider(),
            _row(
              esCompleto
                  ? (cantidadCuotas > 1 ? 'Cuotas completas ✓' : 'Cuota completa ✓')
                  : 'Saldo restante',
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

class _CargoAutoPreview {
  const _CargoAutoPreview({
    required this.cuotaId,
    required this.tipo,
    required this.monto,
    this.porcentaje,
    required this.descripcion,
  });
  final String cuotaId;
  final String tipo;
  final double monto;
  final double? porcentaje;
  final String descripcion;
}
