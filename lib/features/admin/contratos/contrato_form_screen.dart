import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/form_dirty_provider.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/montos.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/confirm_discard_dialog.dart';

enum _Duracion { unAno, dosAnos, indefinido }

class ContratoFormScreen extends ConsumerStatefulWidget {
  // Solo ALTA de contrato. La edición se quitó (M5/M6 del audit): cambiar un
  // contrato existente se hace cancelándolo y creando uno nuevo (B2 terminal),
  // así nunca divergen el contrato y sus cuotas ya generadas.
  const ContratoFormScreen({super.key, this.clienteId});
  final String? clienteId;

  @override
  ConsumerState<ContratoFormScreen> createState() => _ContratoFormScreenState();
}

class _ContratoFormScreenState extends ConsumerState<ContratoFormScreen> {
  final _formKey = GlobalKey<FormState>();
  // Tracking de "form sucio" — flagea cambios para que PopScope muestre
  // confirmación al salir con data sin guardar.
  bool _dirty = false;
  String? _clienteId;
  String? _planId;
  DateTime _fechaInicio = DateTime.now();
  // Día de pago mensual = día de la fecha de instalación (un solo campo). La
  // primera cuota vence el MES SIGUIENTE (facturación vencida); el server
  // (generar_cuotas_contrato) lo deriva de fecha_inicio.
  final _costoCtrl = TextEditingController();
  final _notasCtrl = TextEditingController();
  final _codigoCtrl = TextEditingController();
  // Código de contrato (0077): identificador legible OPCIONAL, único por
  // tenant, inmutable una vez asignado (server lo refuerza; solo super lo cambia).
  String? _codigoDupInfo; // nombre del cliente del contrato en conflicto, o null
  bool _codigoYaAsignado = false;
  Timer? _dupDebounce; // chequeo de código duplicado en vivo (como cliente).
  _Duracion _duracion = _Duracion.unAno;
  bool _cargando = false;
  bool _guardando = false;
  String? _error;

  // Documento del contrato (opcional al crear). Se sube best-effort tras el
  // INSERT si hay conexión; offline o sin adjuntar, el contrato se crea igual
  // y el doc se puede subir luego desde el detalle. Solo en alta (no edición:
  // ahí el detalle ya tiene su propia sección de documento).
  static const _docBucket = 'contratos-documentos';
  static const _docMaxBytes = 10 * 1024 * 1024; // 10 MB
  Uint8List? _docBytes;
  String? _docExt;
  String? _docNombre;

  @override
  void initState() {
    super.initState();
    _clienteId = widget.clienteId;
  }

  @override
  void dispose() {
    _costoCtrl.dispose();
    _notasCtrl.dispose();
    _dupDebounce?.cancel();
    _codigoCtrl.dispose();
    // Reset defensivo del form_dirty_provider: el shell que watchea
    // este provider no debe ver dirty=true tras desmontar el form.
    // Sync (no post-frame) porque dispose corre fuera del build cycle.
    ref.read(formDirtyProvider.notifier).state = false;
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

  /// Vencimiento estimado de la primera cuota = mes SIGUIENTE a la
  /// instalación, mismo día (clamp a fin de mes). Solo para mostrar en el
  /// form; el server (generar_cuotas_contrato) lo deriva igual de fecha_inicio.
  DateTime _primerCobroEstimado() {
    final base = DateTime(_fechaInicio.year, _fechaInicio.month + 1, 1);
    final ultimoDia = DateTime(base.year, base.month + 1, 0).day;
    final dia = _fechaInicio.day < ultimoDia ? _fechaInicio.day : ultimoDia;
    return DateTime(base.year, base.month, dia);
  }

  /// Abre el file picker para el documento del contrato (PDF/Word/foto).
  /// Solo guarda los bytes en memoria; la subida real ocurre en _guardar
  /// tras crear el contrato (necesita el contrato_id).
  Future<void> _elegirDocumento() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'doc', 'docx'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    final bytes = file.bytes;
    if (bytes == null) return;
    if (bytes.length > _docMaxBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'El archivo supera el límite de ${_docMaxBytes ~/ (1024 * 1024)} MB')),
        );
      }
      return;
    }
    setState(() {
      _docBytes = bytes;
      _docExt = (file.extension ?? 'bin').toLowerCase();
      _docNombre = file.name;
      _dirty = true;
    });
  }

  /// Sube el documento adjunto al bucket y actualiza documento_path.
  /// Best-effort: si falla (offline, etc.) no rompe la creación del contrato
  /// — solo avisa que se puede reintentar desde el detalle.
  Future<void> _subirDocumento(
      String contratoId, String tenantId, String ocurridoEn) async {
    try {
      final ext = _docExt ?? 'bin';
      final storagePath =
          '$tenantId/$contratoId/${DateTime.now().millisecondsSinceEpoch}.$ext';
      await Supabase.instance.client.storage.from(_docBucket).uploadBinary(
            storagePath,
            _docBytes!,
            fileOptions: FileOptions(contentType: _mimeDoc(ext)),
          );
      await ps.db.execute(
        'UPDATE contratos SET documento_path = ?, ocurrido_en = ? WHERE id = ?',
        [storagePath, ocurridoEn, contratoId],
      );
    } catch (_) {
      // No bloquea: el contrato ya existe. Avisamos para subir desde detalle.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'El contrato se creó, pero no se pudo subir el documento '
                  '(¿sin conexión?). Podés adjuntarlo desde el detalle.')),
        );
      }
    }
  }

  String _mimeDoc(String ext) => switch (ext) {
        'pdf' => 'application/pdf',
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'doc' => 'application/msword',
        'docx' =>
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        _ => 'application/octet-stream',
      };

  /// Chequea (contra SQLite local) si ya existe OTRO contrato del tenant con el
  /// mismo código (case-insensitive). Setea `_codigoDupInfo` con el nombre del
  /// cliente del contrato en conflicto. El UNIQUE de Postgres (0077) es la red
  /// dura. Devuelve true si hay conflicto.
  Future<bool> _verificarCodigoDuplicado() async {
    final codigo = _codigoCtrl.text.trim();
    if (codigo.isEmpty) {
      _codigoDupInfo = null;
      return false;
    }
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return false;
    try {
      final rows = await ps.db.getAll(
        'SELECT c.nombre AS n FROM contratos ct '
        'JOIN clientes c ON c.id = ct.cliente_id '
        'WHERE ct.tenant_id = ? AND upper(ct.codigo) = upper(?) '
        'LIMIT 1',
        [tenantId, codigo],
      );
      _codigoDupInfo = rows.isEmpty ? null : rows.first['n'] as String?;
      return _codigoDupInfo != null;
    } catch (_) {
      return false; // best-effort; el UNIQUE de Postgres es la red dura
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
    // Doble-submit (fix audit #7): _guardando se setea ANTES del primer
    // await — con el botón habilitado durante los pre-chequeos async, un
    // doble-click en Windows creaba DOS contratos locales (el server
    // rechazaba el 2º recién al sync; offline persistían). Cada early-return
    // de acá en adelante debe revertirlo.
    setState(() {
      _guardando = true;
      _error = null;
    });
    // Guard: el trigger contratos_check_cliente_con_cobrador en Postgres
    // requiere que el cliente tenga cobrador asignado. Validamos acá
    // para dar feedback claro en vez de una CRUD rejection silenciosa.
    final clienteRows = await ps.db.getAll(
      'SELECT cobrador_id FROM clientes WHERE id = ?',
      [_clienteId],
    );
    if (!mounted) return;
    if (clienteRows.isNotEmpty && clienteRows.first['cobrador_id'] == null) {
      setState(() {
        _guardando = false;
        _error = 'El cliente no tiene cobrador asignado. '
            'Asigná uno desde Clientes → Editar antes de crear el contrato.';
      });
      return;
    }
    // Guard: el índice único contratos_unique_activo_por_cliente_plan
    // (migración 0023/0054) prohíbe dos contratos ACTIVOS del mismo
    // cliente+plan. Sin este pre-chequeo, el INSERT local pasa pero PowerSync
    // lo rechaza al sincronizar con un error técnico en inglés. El contrato
    // nuevo siempre nace activo, así que el chequeo siempre corre.
    final dup = await ps.db.getAll(
      '''
      SELECT id FROM contratos
       WHERE cliente_id = ? AND plan_id = ? AND estado = 'activo'
       LIMIT 1
      ''',
      [_clienteId, _planId],
    );
    if (!mounted) return;
    if (dup.isNotEmpty) {
      setState(() {
        _guardando = false;
        _error = 'Este cliente ya tiene un contrato activo con ese plan. '
            'Cancelá el contrato anterior o elegí otro plan.';
      });
      return;
    }
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) {
      setState(() {
        _guardando = false;
        _error = 'No se pudo determinar el tenant';
      });
      return;
    }

    // Guard de código duplicado (el UNIQUE de 0077 es la red dura). Si el
    // código está bloqueado (asignado + no super), no se puede cambiar → skip.
    final esSuper =
        ref.read(cobradorActualProvider).valueOrNull?.esSuperAdmin ?? false;
    if (!(_codigoYaAsignado && !esSuper)) {
      if (await _verificarCodigoDuplicado()) {
        if (!mounted) return;
        setState(() {
          _guardando = false;
          _error =
              'Ya existe un contrato con el código "${_codigoCtrl.text.trim()}"'
              '${_codigoDupInfo != null ? ' (cliente $_codigoDupInfo)' : ''}.';
        });
        return;
      }
    }

    try {
      final fechaFin = _fechaFin();
      // Duración inmutable del contrato (invariante #5): se fija al crear y
      // NO se re-deriva de fechas. null = indefinido.
      final duracionMeses = _duracion == _Duracion.unAno
          ? 12
          : (_duracion == _Duracion.dosAnos ? 24 : null);
      // Día de pago = día de la instalación (un solo campo). La primera cuota
      // vence el mes siguiente; el server la deriva de fecha_inicio.
      final diaPago = _fechaInicio.day;
      final fechaPrimerCobroStr =
          _primerCobroEstimado().toIso8601String().substring(0, 10);
      final costoInstalacion = parseMonto(_costoCtrl.text);
      final notas =
          _notasCtrl.text.trim().isEmpty ? null : _notasCtrl.text.trim();
      // Hora REAL del dispositivo (UTC) para el change log — offline-first.
      final ocurridoEn = DateTime.now().toUtc().toIso8601String();
      // Denormalizamos cobrador_id desde clientes en el INSERT local.
      // Postgres tiene trigger que lo llenaría server-side, pero ese
      // trigger no corre en SQLite local — sin esto, el contrato local
      // queda con cobrador_id NULL hasta sync, lo que lo hace invisible
      // al bucket por_cobrador.
      final clienteRow = await ps.db.getOptional(
        'SELECT cobrador_id FROM clientes WHERE id = ?',
        [_clienteId],
      );
      final cobradorId = clienteRow?['cobrador_id'] as String?;

      // Guard: si no podemos determinar el cobrador (cliente no
      // sincronizado, o sin cobrador asignado), bloqueamos. Sin esto
      // el contrato se crea invisible al cobrador hasta el sync server.
      if (cobradorId == null) {
        setState(() {
          _error = clienteRow == null
              ? 'No se pudo cargar el cliente. Verificá que esté sincronizado.'
              : 'El cliente no tiene cobrador asignado. Asignale uno antes de crear el contrato.';
          _guardando = false;
        });
        return;
      }

      final nuevoId = const Uuid().v4();
      await ps.db.execute(
        '''
        INSERT INTO contratos (
          id, tenant_id, cliente_id, codigo, cobrador_id, plan_id, dia_pago,
          fecha_inicio, fecha_fin, duracion_meses, fecha_primer_cobro,
          costo_instalacion, notas, estado, created_at, ocurrido_en
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'activo', ?, ?)
        ''',
        [
          nuevoId,
          tenantId,
          _clienteId,
          _codigoCtrl.text.trim().isEmpty
              ? null
              : _codigoCtrl.text.trim().toUpperCase(),
          cobradorId,
          _planId,
          diaPago,
          _fechaInicio.toIso8601String().substring(0, 10),
          fechaFin?.toIso8601String().substring(0, 10),
          duracionMeses,
          fechaPrimerCobroStr,
          costoInstalacion,
          notas,
          DateTime.now().toIso8601String(),
          ocurridoEn,
        ],
      );

      // Documento opcional: subir best-effort si se adjuntó. Requiere
      // conexión (Storage); si falla o estamos offline, el contrato ya
      // quedó creado y el doc se puede subir luego desde el detalle.
      if (_docBytes != null) {
        await _subirDocumento(nuevoId, tenantId, ocurridoEn);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('Contrato creado. Cuotas generadas automáticamente.'),
          ),
        );
        // _dirty=false pre-pop para que PopScope no intercepte con
        // "¿Descartar?" tras guardado exitoso (no hay cambios sin
        // persistir — recién guardamos).
        _dirty = false;
        // pop si vinimos vía push (caso normal); fallback go al listado
        // si fue deep-link directo a la edición/creación.
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/admin/contratos');
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sync _dirty al form_dirty_provider para que el shell sidebar
    // pregunte "¿Descartar cambios?" antes de navegar — `context.go`
    // bypassa PopScope. Condicional para evitar postFrameCallbacks
    // en cada keystroke.
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
    final esSuper =
        ref.watch(cobradorActualProvider).valueOrNull?.esSuperAdmin ?? false;
    final codigoBloqueado = _codigoYaAsignado && !esSuper;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final confirm = await confirmDiscardChanges(context);
        if (confirm != true || !context.mounted) return;
        // Fallback para deep-link: si canPop=false, Navigator.pop no
        // hace nada y el user queda atrapado. Go al listado.
        if (context.canPop()) {
          Navigator.pop(context);
        } else {
          context.go('/admin/contratos');
        }
      },
      child: Form(
        key: _formKey,
        onChanged: () {
          if (!_dirty) setState(() => _dirty = true);
        },
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
                  TextFormField(
                    controller: _codigoCtrl,
                    enabled: !codigoBloqueado,
                    decoration: InputDecoration(
                      labelText: 'Código de contrato *',
                      hintText: 'Ej. CT00012',
                      helperText: codigoBloqueado
                          ? 'Inmutable: no se puede cambiar una vez asignado.'
                          : 'Identificador del contrato. No se puede repetir.',
                      errorText: _codigoDupInfo != null
                          ? 'Ya existe un contrato con ese código '
                              '(cliente $_codigoDupInfo)'
                          : null,
                      prefixIcon: const Icon(Icons.tag),
                    ),
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'[A-Za-z0-9\-_]')),
                      TextInputFormatter.withFunction((oldV, newV) =>
                          newV.copyWith(text: newV.text.toUpperCase())),
                      LengthLimitingTextInputFormatter(30),
                    ],
                    validator: (v) {
                      if (codigoBloqueado) return null;
                      if ((v ?? '').trim().isEmpty) {
                        return 'El código es obligatorio';
                      }
                      if (_codigoDupInfo != null) {
                        return 'Ya existe un contrato con ese código '
                            '(cliente $_codigoDupInfo)';
                      }
                      return null;
                    },
                    onChanged: (_) {
                      _dupDebounce?.cancel();
                      _dupDebounce = Timer(
                        const Duration(milliseconds: 350),
                        () async {
                          await _verificarCodigoDuplicado();
                          if (mounted) setState(() {});
                        },
                      );
                    },
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  _ClienteSelector(
                    clienteId: _clienteId,
                    enabled: true,
                    // Form.onChanged solo dispara para FormFields; los
                    // selectors custom acá deben marcar dirty a mano.
                    onChanged: (id) => setState(() {
                      _clienteId = id;
                      _dirty = true;
                    }),
                  ),
                  const SizedBox(height: 12),
                  _PlanSelector(
                    planId: _planId,
                    onChanged: (id) => setState(() {
                      _planId = id;
                      _dirty = true;
                    }),
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
                      _dirty = true;
                    }),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                    child: Text(
                      'La primera cuota vence el ${Fmt.fechaCorta(_primerCobroEstimado())} '
                      '(mes siguiente). Después, cada día ${_fechaInicio.day} del mes.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 12,
                      ),
                    ),
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
                    onSelectionChanged: (s) => setState(() {
                      _duracion = s.first;
                      _dirty = true;
                    }),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _Duracion.indefinido == _duracion
                          ? 'Contrato indefinido: se generan las cuotas del período actual y el sistema mantiene un colchón de 3 meses adelante.'
                          : 'Se generan ${_duracion == _Duracion.unAno ? 12 : 24} cuotas (una por mes) desde el primer cobro.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _costoCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Costo de instalación (opcional)',
                      prefixText: 'C\$ ',
                      helperText:
                          'Dato informativo. No genera un cobro automático.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _notasCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Notas del contrato (opcional)',
                      alignLabelWithHint: true,
                    ),
                  ),
                  // El estado del contrato (activo / cancelado / completado) se
                  // gestiona SOLO desde el dropdown del detalle del contrato —
                  // ahí la cancelación liquida las cuotas (anula pendientes +
                  // descuenta el saldo de las parciales) y es terminal. El form
                  // de edición no toca el estado para no saltearse esa lógica.
                ],
              ),
            ),
          ),
          // Documento del contrato (opcional al crear).
          ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Documento del contrato (opcional)',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      'Adjuntá el contrato firmado (PDF, Word o foto). Si no '
                      'tenés conexión ahora, podés subirlo después desde el '
                      'detalle del contrato.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_docBytes == null)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Adjuntar documento'),
                        onPressed: _guardando ? null : _elegirDocumento,
                      )
                    else
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.insert_drive_file),
                        title: Text(_docNombre ?? 'Documento',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '${(_docBytes!.length / 1024).toStringAsFixed(0)} KB'),
                        trailing: IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Quitar',
                          onPressed: _guardando
                              ? null
                              : () => setState(() {
                                    _docBytes = null;
                                    _docExt = null;
                                    _docNombre = null;
                                  }),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
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
                      : () => context.canPop()
                          ? context.pop()
                          : context.go('/admin/contratos'),
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
                  label: Text(_guardando ? 'Guardando...' : 'Crear contrato'),
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

class _ClienteSelector extends StatefulWidget {
  const _ClienteSelector({
    required this.clienteId,
    required this.onChanged,
    this.enabled = true,
  });
  final String? clienteId;
  final ValueChanged<String?> onChanged;
  final bool enabled;

  @override
  State<_ClienteSelector> createState() => _ClienteSelectorState();
}

class _ClienteSelectorState extends State<_ClienteSelector> {
  /// Stream cacheado — query fija, no depende de props.
  late final Stream<List<Map<String, dynamic>>> _clientesStream;

  @override
  void initState() {
    super.initState();
    _clientesStream = ps.db.watch(
      'SELECT id, nombre FROM clientes WHERE activo = 1 ORDER BY nombre',
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _clientesStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final rows = snap.data!;
        // Guard: si el value actual no está en los items (stream re-emit
        // durante sync), usamos null para evitar la assertion de Flutter
        // "There should be exactly one item with [DropdownButton]'s value".
        final clienteIds = rows.map((r) => r['id'] as String).toSet();
        final safeClienteId = (widget.clienteId != null && clienteIds.contains(widget.clienteId))
            ? widget.clienteId
            : null;
        return DropdownButtonFormField<String?>(
          value: safeClienteId,
          decoration: InputDecoration(
            labelText: 'Cliente *',
            enabled: widget.enabled,
            helperText: !widget.enabled ? 'No se puede cambiar al editar contrato' : null,
          ),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('—')),
            ...rows.map((r) => DropdownMenuItem(
                  value: r['id'] as String,
                  child: Text(r['nombre'] as String),
                )),
          ],
          onChanged: widget.enabled ? widget.onChanged : null,
          validator: (v) => v == null ? 'Requerido' : null,
        );
      },
    );
  }
}

class _PlanSelector extends StatefulWidget {
  const _PlanSelector({required this.planId, required this.onChanged});
  final String? planId;
  final ValueChanged<String?> onChanged;

  @override
  State<_PlanSelector> createState() => _PlanSelectorState();
}

class _PlanSelectorState extends State<_PlanSelector> {
  /// Stream cacheado — query fija, no depende de props.
  late final Stream<List<Map<String, dynamic>>> _planesStream;

  @override
  void initState() {
    super.initState();
    _planesStream = ps.db.watch(
      'SELECT id, nombre, precio_mensual FROM planes WHERE activo = 1 ORDER BY precio_mensual',
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _planesStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final rows = snap.data!;
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
        final planIds = rows.map((r) => r['id'] as String).toSet();
        final safePlanId = (widget.planId != null && planIds.contains(widget.planId))
            ? widget.planId
            : null;
        return DropdownButtonFormField<String?>(
          value: safePlanId,
          decoration: const InputDecoration(labelText: 'Plan *'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('—')),
            ...rows.map((r) => DropdownMenuItem(
                  value: r['id'] as String,
                  child: Text(
                      '${r['nombre']} · ${Fmt.cordobas(r['precio_mensual'] as num)}'),
                )),
          ],
          onChanged: widget.onChanged,
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
        final minDate = DateTime(2020);
        // initialDate debe estar dentro de [firstDate, lastDate].
        final initial = fecha.isBefore(minDate) ? minDate : fecha;
        final picked = await showDatePicker(
          context: context,
          initialDate: initial,
          firstDate: minDate,
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
