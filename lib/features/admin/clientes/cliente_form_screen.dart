import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/form_dirty_provider.dart';
import '../../../data/utils/validators.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/confirm_discard_dialog.dart';
import '../../shared/widgets/mapa_picker_screen.dart';
import '../../shared/widgets/phone_text_field.dart';
import '../inventario/equipos_en_baja.dart';
import 'widgets/geo_picker.dart';
import 'widgets/red_picker.dart';

class ClienteFormScreen extends ConsumerStatefulWidget {
  const ClienteFormScreen({super.key, this.clienteId});
  final String? clienteId;

  @override
  ConsumerState<ClienteFormScreen> createState() => _ClienteFormScreenState();
}

class _ClienteFormScreenState extends ConsumerState<ClienteFormScreen> {
  final _formKey = GlobalKey<FormState>();
  // Tracking de "form sucio" — true cuando el user tocó algún campo
  // tras la última cargada/guardado. Usado por PopScope para mostrar
  // dialog de confirmación al intentar salir con cambios sin guardar.
  bool _dirty = false;
  final _codigo = TextEditingController();
  final _nombre = TextEditingController();
  final _cedula = TextEditingController();
  final _telefono = TextEditingController();
  final _direccion = TextEditingController();
  final _referencia = TextEditingController();
  final _lat = TextEditingController();
  final _lng = TextEditingController();

  String? _comunidadId;
  String? _puertoId;
  String? _cobradorId;
  bool _activo = true;
  bool _activoOriginal = true; // para detectar la transición activo→inactivo
  bool _cargando = true;
  bool _guardando = false;
  String? _error;
  // Foto legacy del cliente (campo viejo). Se preserva al guardar pero
  // ya no se setea desde el form — las fotos múltiples viven en
  // FotoGalleryWidget en la pantalla de detalle del cliente.
  String? _fotoPath;

  // Código de cliente: chequeo de duplicado en vivo + bloqueo de inmutabilidad.
  String? _codigoDupNombre; // nombre del cliente que ya usa ese código (o null)
  bool _codigoYaAsignado = false; // true = el cliente ya tiene código guardado
  Timer? _dupDebounce; // debounce del chequeo de duplicado en vivo

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    if (widget.clienteId == null) {
      setState(() => _cargando = false);
      return;
    }
    final rows = await ps.db
        .getAll('SELECT * FROM clientes WHERE id = ?', [widget.clienteId]);
    if (rows.isEmpty) {
      setState(() => _cargando = false);
      return;
    }
    final r = rows.first;
    _nombre.text = r['nombre'] as String? ?? '';
    _cedula.text = r['cedula'] as String? ?? '';
    _telefono.text = r['telefono'] as String? ?? '';
    _direccion.text = r['direccion'] as String? ?? '';
    _referencia.text = r['direccion_referencia'] as String? ?? '';
    _lat.text = r['latitud']?.toString() ?? '';
    _lng.text = r['longitud']?.toString() ?? '';
    _comunidadId = r['comunidad_id'] as String?;
    _puertoId = r['puerto_id'] as String?;
    _cobradorId = r['cobrador_id'] as String?;
    _activo = (r['activo'] as int? ?? 1) == 1;
    _activoOriginal = _activo;
    _fotoPath = r['foto_path'] as String?;
    _codigo.text = r['codigo'] as String? ?? '';
    // Si ya tiene código asignado queda read-only para admin/cobrador; el
    // super_admin sí puede corregirlo (se evalúa en build con el rol actual).
    _codigoYaAsignado = _codigo.text.trim().isNotEmpty;
    setState(() => _cargando = false);
  }

  String? _clienteIdAsignado;

  @override
  void dispose() {
    // Reset defensivo del form_dirty_provider: el shell que watchea
    // este provider no debe ver dirty=true tras desmontar el form,
    // sino el próximo sidebar tap mostraría un dialog huérfano.
    // Sync (antes de super.dispose) porque ref sigue válido acá.
    ref.read(formDirtyProvider.notifier).state = false;
    _dupDebounce?.cancel();
    _codigo.dispose();
    _nombre.dispose();
    _cedula.dispose();
    _telefono.dispose();
    _direccion.dispose();
    _referencia.dispose();
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  /// Chequea (contra el SQLite local) si ya existe OTRO cliente del tenant con
  /// el mismo código (case-insensitive). Setea `_codigoDupNombre` con el nombre
  /// del cliente en conflicto, o null si está libre. El admin baja todos los
  /// clientes del tenant → el chequeo es confiable para él; el UNIQUE de
  /// Postgres es la garantía dura (el cobrador tiene vista parcial).
  Future<void> _verificarCodigoDuplicado() async {
    final codigo = _codigo.text.trim();
    if (codigo.isEmpty) {
      if (_codigoDupNombre != null) setState(() => _codigoDupNombre = null);
      return;
    }
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    try {
      final rows = await ps.db.getAll(
        'SELECT nombre FROM clientes '
        'WHERE tenant_id = ? AND upper(codigo) = upper(?) AND id != ? LIMIT 1',
        [tenantId, codigo, widget.clienteId ?? ''],
      );
      if (!mounted) return;
      final nombre = rows.isEmpty ? null : rows.first['nombre'] as String?;
      if (nombre != _codigoDupNombre) setState(() => _codigoDupNombre = nombre);
    } catch (_) {
      // Best-effort: si la query local falla no bloqueamos el form (el UNIQUE
      // de Postgres es la garantía dura igual).
    }
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) {
      setState(() => _error = 'No se pudo determinar el tenant');
      return;
    }

    // Guard de código duplicado (hard stop con mensaje claro; el UNIQUE de la
    // DB es la red final). El super_admin puede corregir un código asignado,
    // así que para él el campo es editable y también se chequea.
    final esSuper =
        ref.read(cobradorActualProvider).valueOrNull?.esSuperAdmin ?? false;
    final codigoBloqueado = _codigoYaAsignado && !esSuper;
    if (!codigoBloqueado) {
      await _verificarCodigoDuplicado();
      if (_codigoDupNombre != null) {
        setState(() => _error =
            'Ya existe un cliente con el código "${_codigo.text.trim()}": '
            '$_codigoDupNombre');
        return;
      }
    }

    // Guard cliente-side: si el admin intenta desasignar cobrador en un
    // cliente existente que tiene contratos activos, bloquear con error
    // claro antes de pegarle a la DB. El trigger 0058 lo refuerza server-side.
    if (widget.clienteId != null && _cobradorId == null) {
      final activos = await ps.db.getAll(
        "SELECT COUNT(*) AS n FROM contratos WHERE cliente_id = ? AND estado = 'activo'",
        [widget.clienteId],
      );
      final n = (activos.first['n'] as int? ?? 0);
      if (n > 0) {
        setState(() => _error =
            'No se puede desasignar el cobrador: el cliente tiene $n contrato(s) activo(s). '
            'Reasigne primero a otro cobrador.');
        return;
      }
    }

    setState(() {
      _guardando = true;
      _error = null;
    });

    try {
      final now = DateTime.now().toIso8601String();
      // Hora REAL del dispositivo (UTC) para el change log — offline-first.
      final ocurridoEn = DateTime.now().toUtc().toIso8601String();
      final lat = double.tryParse(_lat.text);
      final lng = double.tryParse(_lng.text);

      if (widget.clienteId == null) {
        // Si ya subimos foto antes de guardar, reusamos el id para que
        // el path remoto y el id en BD coincidan.
        final id = _clienteIdAsignado ?? const Uuid().v4();
        await ps.db.execute(
          '''
          INSERT INTO clientes (
            id, tenant_id, cobrador_id, comunidad_id, puerto_id, codigo, nombre,
            cedula, telefono, direccion, direccion_referencia, latitud, longitud,
            foto_path, activo, created_at, updated_at, ocurrido_en
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            id, tenantId, _cobradorId, _comunidadId, _puertoId,
            _codigo.text.trim().isEmpty ? null : _codigo.text.trim().toUpperCase(),
            _nombre.text.trim(),
            _cedula.text.trim().isEmpty ? null : _cedula.text.trim(),
            PhoneTextField.sanitized(_telefono),
            _direccion.text.trim().isEmpty ? null : _direccion.text.trim(),
            _referencia.text.trim().isEmpty ? null : _referencia.text.trim(),
            lat, lng,
            _fotoPath,
            _activo ? 1 : 0, now, now, ocurridoEn,
          ],
        );
      } else {
        await ps.db.execute(
          '''
          UPDATE clientes
             SET cobrador_id = ?, comunidad_id = ?, puerto_id = ?, codigo = ?,
                 nombre = ?, cedula = ?, telefono = ?, direccion = ?,
                 direccion_referencia = ?, latitud = ?, longitud = ?,
                 foto_path = ?, activo = ?, updated_at = ?, ocurrido_en = ?
           WHERE id = ?
          ''',
          [
            _cobradorId, _comunidadId, _puertoId,
            _codigo.text.trim().isEmpty ? null : _codigo.text.trim().toUpperCase(),
            _nombre.text.trim(),
            _cedula.text.trim().isEmpty ? null : _cedula.text.trim(),
            PhoneTextField.sanitized(_telefono),
            _direccion.text.trim().isEmpty ? null : _direccion.text.trim(),
            _referencia.text.trim().isEmpty ? null : _referencia.text.trim(),
            lat, lng,
            _fotoPath,
            _activo ? 1 : 0, now, ocurridoEn,
            widget.clienteId,
          ],
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.clienteId == null
              ? 'Cliente creado'
              : 'Cambios guardados')),
        );
        // Reseteamos _dirty PRE-pop para que el PopScope no intercepte
        // con el dialog "¿Descartar cambios?" — recién guardamos, no
        // hay cambios sin persistir. Sin esto, el guardado dispara la
        // confirmación que el user esperaría solo en cancelación.
        _dirty = false;
        // Si se DESACTIVÓ el cliente (transición activo→inactivo), ofrecer
        // gestionar sus equipos instalados antes de salir (audit de lifecycle).
        if (widget.clienteId != null && _activoOriginal && !_activo) {
          await ofrecerGestionEquiposEnBaja(context, ref,
              clienteId: widget.clienteId!, entidad: 'cliente');
        }
        if (!context.mounted) return;
        // pop si vinimos vía push (caso normal); fallback go al listado
        // si fue deep-link directo a la edición.
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/admin/clientes');
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _abrirMapaPicker() async {
    final inicial = (double.tryParse(_lat.text) != null &&
            double.tryParse(_lng.text) != null)
        ? LatLng(double.parse(_lat.text), double.parse(_lng.text))
        : const LatLng(12.13, -86.25); // Managua como centro default
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(builder: (_) => MapaPickerScreen(inicial: inicial)),
    );
    if (picked != null) {
      setState(() {
        _lat.text = picked.latitude.toStringAsFixed(6);
        _lng.text = picked.longitude.toStringAsFixed(6);
        // controller.text = ... asignación programática NO dispara
        // Form.onChanged (solo onSubmitted/onChanged del field). Marcar
        // dirty a mano para que PopScope intercepte el discard.
        _dirty = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sync el dirty state al provider global para que el sidebar del
    // shell pueda mostrar "¿Descartar cambios?" si el user toca un
    // item de menú con cambios sin guardar (PopScope solo cubre pops,
    // no `context.go` del go_router).
    //
    // Condicional para no schedular un postFrameCallback en cada
    // keystroke cuando _dirty ya está en true. Post-frame porque
    // setear el state notifica listeners; durante build no se permite.
    if (ref.read(formDirtyProvider) != _dirty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(formDirtyProvider.notifier).state = _dirty;
        }
      });
    }

    if (_cargando) {
      return const Center(child: CircularProgressIndicator());
    }

    // El código es inmutable una vez asignado para admin/cobrador; el
    // super_admin sí puede corregirlo (P1 del audit del feature).
    final esSuper =
        ref.watch(cobradorActualProvider).valueOrNull?.esSuperAdmin ?? false;
    final codigoBloqueado = _codigoYaAsignado && !esSuper;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final confirm = await confirmDiscardChanges(context);
        if (confirm != true || !context.mounted) return;
        // Mismo patrón fallback que `_guardar()`: si vinimos por push
        // (canPop=true), Navigator.pop. Si fue deep-link directo
        // (canPop=false), `Navigator.pop` no haría nada y el user
        // quedaría atrapado con _dirty=false. Hacemos go al listado.
        if (context.canPop()) {
          Navigator.pop(context);
        } else {
          context.go('/admin/clientes');
        }
      },
      child: Form(
        key: _formKey,
        onChanged: () {
          // Cualquier change en cualquier TextFormField del árbol del
          // Form dispara esto. Lo usamos para flagear dirty sin tener
          // que addListener manual a cada controller.
          if (!_dirty) setState(() => _dirty = true);
        },
        child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // ── Datos personales ──────────────────────────────────────────
          _Section(
            titulo: 'Datos personales',
            children: [
              TextFormField(
                controller: _codigo,
                enabled: !codigoBloqueado,
                decoration: InputDecoration(
                  labelText: 'Código de cliente *',
                  hintText: 'Ej. CL00027',
                  helperText: codigoBloqueado
                      ? 'Inmutable: no se puede cambiar una vez asignado.'
                      : 'Identificador visible del cliente. No se puede repetir.',
                  errorText: _codigoDupNombre != null
                      ? 'Ya existe un cliente con ese código: $_codigoDupNombre'
                      : null,
                  prefixIcon: const Icon(Icons.badge_outlined),
                ),
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-_]')),
                  TextInputFormatter.withFunction((oldV, newV) =>
                      newV.copyWith(text: newV.text.toUpperCase())),
                  LengthLimitingTextInputFormatter(30),
                ],
                validator: (v) {
                  if (codigoBloqueado) return null;
                  final t = (v ?? '').trim();
                  if (t.isEmpty) return 'El código es obligatorio';
                  if (_codigoDupNombre != null) {
                    return 'Ya existe un cliente con ese código: $_codigoDupNombre';
                  }
                  return null;
                },
                onChanged: (_) {
                  _dupDebounce?.cancel();
                  _dupDebounce = Timer(const Duration(milliseconds: 350),
                      _verificarCodigoDuplicado);
                },
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nombre,
                decoration: const InputDecoration(labelText: 'Nombre completo *'),
                validator: (v) =>
                    Validators.requiredField(v, label: 'Nombre') ??
                    Validators.minLength(v, 3),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _cedula,
                      decoration: const InputDecoration(
                          labelText: 'Cédula', hintText: '000-000000-0000A'),
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return null; // Opcional
                        if (!RegExp(r'^\d{3}-\d{6}-\d{4}[A-Za-z]$')
                            .hasMatch(t)) {
                          return 'Formato: 000-000000-0000A';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PhoneTextField(controller: _telefono),
                  ),
                ],
              ),
            ],
          ),

          // ── Ubicación ─────────────────────────────────────────────────
          _Section(
            titulo: 'Ubicación',
            children: [
              GeoPicker(
                tenantId: ref.read(tenantIdProvider) ?? '',
                comunidadId: _comunidadId,
                onChanged: (id) => setState(() {
                  _comunidadId = id;
                  _dirty = true;
                }),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _direccion,
                decoration: const InputDecoration(
                  labelText: 'Dirección',
                  hintText: 'Calle, número, sector',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _referencia,
                decoration: const InputDecoration(
                  labelText: 'Referencia',
                  hintText: 'Casa amarilla, frente al molino, etc.',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _lat,
                      decoration: const InputDecoration(labelText: 'Latitud'),
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                      ],
                      validator: (v) {
                        if ((v ?? '').trim().isEmpty) return null;
                        final n = double.tryParse(v!);
                        if (n == null) return 'Número inválido';
                        if (n < -90 || n > 90) return 'Fuera de rango (-90 a 90)';
                        if (n < 10 || n > 15) return 'Nicaragua: entre 10 y 15';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _lng,
                      decoration: const InputDecoration(labelText: 'Longitud'),
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                      ],
                      validator: (v) {
                        if ((v ?? '').trim().isEmpty) return null;
                        final n = double.tryParse(v!);
                        if (n == null) return 'Número inválido';
                        if (n < -180 || n > 180) return 'Fuera de rango (-180 a 180)';
                        if (n < -88 || n > -82) return 'Nicaragua: entre -88 y -82';
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.map),
                label: const Text('Seleccionar en mapa'),
                onPressed: _abrirMapaPicker,
              ),
            ],
          ),

          // ── Conexión de red ───────────────────────────────────────────
          _Section(
            titulo: 'Conexión de red (opcional)',
            children: [
              RedPicker(
                tenantId: ref.read(tenantIdProvider) ?? '',
                puertoId: _puertoId,
                onChanged: (id) => setState(() {
                  _puertoId = id;
                  _dirty = true;
                }),
              ),
            ],
          ),

          // ── Asignación + Estado ───────────────────────────────────────
          _Section(
            titulo: 'Asignación',
            children: [
              _SelectorCobrador(
                cobradorId: _cobradorId,
                onChanged: (id) => setState(() {
                  _cobradorId = id;
                  _dirty = true;
                }),
              ),
            ],
          ),

          // ── Estado del cliente ────────────────────────────────────────
          // Solo admin puede cambiar estado activo/inactivo.
          if (ref.watch(cobradorActualProvider).valueOrNull?.rol == 'admin')
            _Section(
              titulo: 'Estado',
              children: [
                SwitchListTile(
                  value: _activo,
                  onChanged: (v) => setState(() {
                    _activo = v;
                    _dirty = true;
                  }),
                  title: Text(_activo ? 'Cliente activo' : 'Cliente inactivo'),
                  subtitle: Text(_activo
                      ? 'El cliente aparece en la lista del cobrador y se generan cuotas.'
                      : 'El cliente se oculta del cobrador y NO se generan nuevas cuotas.'),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!),
                ),
              ),
            ),

          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _guardando
                      ? null
                      : () => context.canPop()
                          ? context.pop()
                          : context.go('/admin/clientes'),
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
                      : (widget.clienteId == null
                          ? 'Crear cliente'
                          : 'Guardar cambios')),
                  onPressed: _guardando ? null : _guardar,
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

class _Section extends StatelessWidget {
  const _Section({required this.titulo, required this.children});
  final String titulo;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(titulo,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectorCobrador extends StatefulWidget {
  const _SelectorCobrador({required this.cobradorId, required this.onChanged});
  final String? cobradorId;
  final ValueChanged<String?> onChanged;

  @override
  State<_SelectorCobrador> createState() => _SelectorCobradorState();
}

class _SelectorCobradorState extends State<_SelectorCobrador> {
  /// Stream cacheado — query fija, no depende de props.
  late final Stream<List<Map<String, dynamic>>> _cobradoresStream;

  @override
  void initState() {
    super.initState();
    _cobradoresStream = ps.db.watch(
      '''
      SELECT id, nombre, prefijo_recibo FROM cobradores
       WHERE activo = 1 AND rol = 'cobrador'
       ORDER BY nombre
      ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _cobradoresStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Text('Error: ${snap.error}');
        }
        final rows = snap.data!;
        // Si el value del cobrador no está aún en la lista de items
        // (primer frame con initialData vacío), pasamos null al dropdown
        // para evitar el assertion de Flutter "no item matches value".
        final ids = rows.map((r) => r['id'] as String).toSet();
        final safeValue = widget.cobradorId != null && ids.contains(widget.cobradorId)
            ? widget.cobradorId
            : null;
        return DropdownButtonFormField<String?>(
          value: safeValue,
          decoration: const InputDecoration(labelText: 'Cobrador asignado'),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('— Sin asignar —'),
            ),
            ...rows.map((r) => DropdownMenuItem(
                  value: r['id'] as String,
                  child: Text(
                    r['prefijo_recibo'] != null
                        ? '${r['nombre']} (${r['prefijo_recibo']})'
                        : r['nombre'] as String,
                  ),
                )),
          ],
          onChanged: widget.onChanged,
        );
      },
    );
  }
}


