import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/services/foto_cliente_service.dart';
import '../../../data/utils/validators.dart';
import '../../../powersync/db.dart' as ps;
import 'widgets/geo_picker.dart';

class ClienteFormScreen extends ConsumerStatefulWidget {
  const ClienteFormScreen({super.key, this.clienteId});
  final String? clienteId;

  @override
  ConsumerState<ClienteFormScreen> createState() => _ClienteFormScreenState();
}

class _ClienteFormScreenState extends ConsumerState<ClienteFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nombre = TextEditingController();
  final _cedula = TextEditingController();
  final _telefono = TextEditingController();
  final _direccion = TextEditingController();
  final _referencia = TextEditingController();
  final _lat = TextEditingController();
  final _lng = TextEditingController();

  String? _comunidadId;
  String? _cobradorId;
  bool _activo = true;
  bool _cargando = true;
  bool _guardando = false;
  String? _error;
  // Foto del cliente: path remoto en BD + URL firmada para preview.
  String? _fotoPath;
  bool _subiendoFoto = false;

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
    _cobradorId = r['cobrador_id'] as String?;
    _activo = (r['activo'] as int? ?? 1) == 1;
    _fotoPath = r['foto_path'] as String?;
    setState(() => _cargando = false);
  }

  /// Captura foto y la sube. Para clientes nuevos, primero genera el id
  /// del cliente para usarlo en el path remoto.
  Future<void> _capturarFoto(ImageSource source) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    setState(() => _subiendoFoto = true);
    try {
      final service = FotoClienteService(Supabase.instance.client);
      // Si es nuevo, asignamos id ahora (se reusa en el INSERT).
      _clienteIdAsignado ??= widget.clienteId ?? const Uuid().v4();
      final path = await service.capturarYSubir(
        source: source,
        tenantId: tenantId,
        clienteId: _clienteIdAsignado!,
      );
      if (path == null) return;
      // Generar URL firmada para preview inmediato.
      final url = await service.urlFirmada(path);
      if (mounted) {
        setState(() {
          _fotoPath = path;
          _urlFirmadaPreview = url;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo subir foto: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _subiendoFoto = false);
    }
  }

  String? _clienteIdAsignado;
  String? _urlFirmadaPreview;

  @override
  void dispose() {
    _nombre.dispose();
    _cedula.dispose();
    _telefono.dispose();
    _direccion.dispose();
    _referencia.dispose();
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  /// Teléfono normalizado para persistir: solo `[0-9+]`. Aunque el
  /// inputFormatters del field rechaza letras, sanitizamos también acá
  /// como defensa en profundidad (por si en el futuro alguien setea
  /// el campo programáticamente desde otro path).
  ///
  /// Si después de strip no quedan dígitos (caso `"+"`, `"+++"`, `"   "`,
  /// o legacy con solo basura), retornamos null. Sin este guard, BD
  /// terminaba con `"+"` que es inutilizable como `tel:`/`wa.me` —
  /// rompe el botón "Llamar" silenciosamente.
  String? _telefonoLimpio() {
    final t = sanitizePhone(_telefono.text);
    if (sanitizePhoneForWhatsApp(t).isEmpty) return null;
    return t;
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) return;
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
      final now = DateTime.now().toIso8601String();
      final lat = double.tryParse(_lat.text);
      final lng = double.tryParse(_lng.text);

      if (widget.clienteId == null) {
        // Si ya subimos foto antes de guardar, reusamos el id para que
        // el path remoto y el id en BD coincidan.
        final id = _clienteIdAsignado ?? const Uuid().v4();
        await ps.db.execute(
          '''
          INSERT INTO clientes (
            id, tenant_id, cobrador_id, comunidad_id, nombre, cedula,
            telefono, direccion, direccion_referencia, latitud, longitud,
            foto_path, activo, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            id, tenantId, _cobradorId, _comunidadId,
            _nombre.text.trim(),
            _cedula.text.trim().isEmpty ? null : _cedula.text.trim(),
            _telefonoLimpio(),
            _direccion.text.trim().isEmpty ? null : _direccion.text.trim(),
            _referencia.text.trim().isEmpty ? null : _referencia.text.trim(),
            lat, lng,
            _fotoPath,
            _activo ? 1 : 0, now, now,
          ],
        );
      } else {
        await ps.db.execute(
          '''
          UPDATE clientes
             SET cobrador_id = ?, comunidad_id = ?, nombre = ?, cedula = ?,
                 telefono = ?, direccion = ?, direccion_referencia = ?,
                 latitud = ?, longitud = ?, foto_path = ?,
                 activo = ?, updated_at = ?
           WHERE id = ?
          ''',
          [
            _cobradorId, _comunidadId, _nombre.text.trim(),
            _cedula.text.trim().isEmpty ? null : _cedula.text.trim(),
            _telefonoLimpio(),
            _direccion.text.trim().isEmpty ? null : _direccion.text.trim(),
            _referencia.text.trim().isEmpty ? null : _referencia.text.trim(),
            lat, lng,
            _fotoPath,
            _activo ? 1 : 0, now,
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
      MaterialPageRoute(builder: (_) => _MapaPickerScreen(inicial: inicial)),
    );
    if (picked != null) {
      setState(() {
        _lat.text = picked.latitude.toStringAsFixed(6);
        _lng.text = picked.longitude.toStringAsFixed(6);
      });
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
          // ── Foto ──────────────────────────────────────────────────────
          _Section(
            titulo: 'Foto',
            children: [
              _FotoClienteWidget(
                urlFirmada: _urlFirmadaPreview,
                pathRemoto: _fotoPath,
                cargando: _subiendoFoto,
                onCapturar: _capturarFoto,
                onQuitar: () => setState(() {
                  _fotoPath = null;
                  _urlFirmadaPreview = null;
                }),
              ),
            ],
          ),

          // ── Datos personales ──────────────────────────────────────────
          _Section(
            titulo: 'Datos personales',
            children: [
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
                    child: TextFormField(
                      controller: _telefono,
                      decoration: const InputDecoration(
                          labelText: 'Teléfono',
                          hintText: '+505 8888-8888'),
                      keyboardType: TextInputType.phone,
                      // Bloquea letras y otros símbolos en el input. Antes
                      // el validator solo contaba dígitos via
                      // sanitizePhoneForWhatsApp pero NO sanitizaba al
                      // guardar — el user podía meter "abc12345678" y la
                      // BD quedaba con el string literal. inputFormatters
                      // + sanitizePhone al guardar (ver _telefonoLimpio)
                      // cierra ambos huecos.
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9+\s\-]')),
                      ],
                      validator: (v) {
                        final digits = sanitizePhoneForWhatsApp(v ?? '');
                        if (digits.isEmpty) return null; // Opcional
                        if (digits.length < 8) return 'Mínimo 8 dígitos';
                        return null;
                      },
                    ),
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
                comunidadId: _comunidadId,
                onChanged: (id) => setState(() => _comunidadId = id),
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

          // ── Asignación + Estado ───────────────────────────────────────
          _Section(
            titulo: 'Asignación',
            children: [
              _SelectorCobrador(
                cobradorId: _cobradorId,
                onChanged: (id) => setState(() => _cobradorId = id),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: _activo,
                onChanged: (v) => setState(() => _activo = v),
                title: Text(_activo ? 'Activo' : 'Inactivo'),
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
    );
  }
}

class _FotoClienteWidget extends StatefulWidget {
  const _FotoClienteWidget({
    required this.urlFirmada,
    required this.pathRemoto,
    required this.cargando,
    required this.onCapturar,
    required this.onQuitar,
  });

  final String? urlFirmada;
  final String? pathRemoto;
  final bool cargando;
  final Future<void> Function(ImageSource source) onCapturar;
  final VoidCallback onQuitar;

  @override
  State<_FotoClienteWidget> createState() => _FotoClienteWidgetState();
}

class _FotoClienteWidgetState extends State<_FotoClienteWidget> {
  String? _urlResuelta;

  @override
  void didUpdateWidget(covariant _FotoClienteWidget old) {
    super.didUpdateWidget(old);
    if (widget.urlFirmada != old.urlFirmada) {
      _urlResuelta = widget.urlFirmada;
    }
  }

  @override
  void initState() {
    super.initState();
    _urlResuelta = widget.urlFirmada;
    if (_urlResuelta == null && widget.pathRemoto != null) {
      _resolverUrl();
    }
  }

  Future<void> _resolverUrl() async {
    final url = await FotoClienteService(Supabase.instance.client)
        .urlFirmada(widget.pathRemoto!);
    if (mounted) setState(() => _urlResuelta = url);
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
                widget.onCapturar(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Elegir de galería'),
              onTap: () {
                Navigator.pop(ctx);
                widget.onCapturar(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.cargando) {
      return const SizedBox(
        height: 180,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (widget.pathRemoto != null && _urlResuelta != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              _urlResuelta!,
              height: 180,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                height: 180,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Center(child: Icon(Icons.broken_image)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Cambiar'),
                  onPressed: _mostrarFuente,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Quitar'),
                  onPressed: widget.onQuitar,
                ),
              ),
            ],
          ),
        ],
      );
    }
    return OutlinedButton.icon(
      icon: const Icon(Icons.add_a_photo),
      label: const Text('Agregar foto del cliente'),
      onPressed: _mostrarFuente,
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

class _SelectorCobrador extends StatelessWidget {
  const _SelectorCobrador({required this.cobradorId, required this.onChanged});
  final String? cobradorId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: ps.db.watch(
        '''
        SELECT id, nombre, prefijo_recibo FROM cobradores
         WHERE activo = 1 AND rol = 'cobrador'
         ORDER BY nombre
        ''',
      ),
      builder: (context, snap) {
        final rows = snap.data ?? const [];
        return DropdownButtonFormField<String?>(
          value: cobradorId,
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
          onChanged: onChanged,
        );
      },
    );
  }
}

/// Pantalla full-screen para elegir coordenadas con clic en el mapa.
class _MapaPickerScreen extends StatefulWidget {
  const _MapaPickerScreen({required this.inicial});
  final LatLng inicial;

  @override
  State<_MapaPickerScreen> createState() => _MapaPickerScreenState();
}

class _MapaPickerScreenState extends State<_MapaPickerScreen> {
  late LatLng _punto;

  @override
  void initState() {
    super.initState();
    _punto = widget.inicial;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Seleccionar ubicación'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: () => Navigator.pop(context, _punto),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              options: MapOptions(
                initialCenter: _punto,
                initialZoom: 13,
                onTap: (_, p) => setState(() => _punto = p),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.ispbilling.app',
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _punto,
                      width: 40, height: 40,
                      child: const Icon(Icons.location_on,
                          color: Colors.red, size: 40),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Lat: ${_punto.latitude.toStringAsFixed(6)}, '
              'Lng: ${_punto.longitude.toStringAsFixed(6)}',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

