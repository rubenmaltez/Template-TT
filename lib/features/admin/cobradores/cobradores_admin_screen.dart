import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/utils/edge_functions.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/validators.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';

/// Gestión de cobradores: ver lista, asignar prefijo de recibo, cambiar
/// rol, activar/desactivar.
///
/// Nota: la creación del usuario en auth.users requiere Supabase Admin
/// API (service role key), que NO va en el cliente. Se invita desde
/// Supabase Dashboard; cuando el cobrador se logea por primera vez
/// (después de que el trigger de Supabase cree su fila en cobradores
/// vía una Edge Function pendiente), aparece acá para configurar.
class CobradoresAdminScreen extends ConsumerWidget {
  const CobradoresAdminScreen({super.key});

  Future<void> _abrirInvitar(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _InvitarDialog(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder(
      stream: ps.db.watch(
        // Subqueries en SELECT evitan el producto cartesiano que tendrían
        // dos LEFT JOINs (clientes × pagos) sobre el mismo cobrador.
        '''
        SELECT co.id, co.nombre, co.telefono, co.rol,
               co.prefijo_recibo, co.activo,
               (SELECT COUNT(*) FROM clientes
                 WHERE cobrador_id = co.id AND activo = 1
               ) AS clientes_asignados,
               (SELECT COALESCE(SUM(monto_cordobas), 0) FROM pagos
                 WHERE cobrador_id = co.id
                   AND anulado = 0
                   AND date(fecha_pago) >= date('now', 'start of month')
               ) AS cobrado_mes
          FROM cobradores co
         ORDER BY co.activo DESC, co.rol, co.nombre
        ''',
      ),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snap.data!;
        if (rows.isEmpty) {
          return EmptyState(
            icon: Icons.engineering,
            titulo: 'Sin cobradores',
            descripcion:
                'Invitá al primero — recibirá un email para crear su contraseña.',
            accion: FilledButton.icon(
              icon: const Icon(Icons.person_add),
              label: const Text('Invitar cobrador'),
              onPressed: () => _abrirInvitar(context),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                icon: const Icon(Icons.person_add),
                label: const Text('Invitar nuevo'),
                onPressed: () => _abrirInvitar(context),
              ),
            ),
            const SizedBox(height: 16),
            ...rows.map((r) => _CobradorCard(row: r)),
          ],
        );
      },
    );
  }
}

class _InvitarDialog extends StatefulWidget {
  const _InvitarDialog();
  @override
  State<_InvitarDialog> createState() => _InvitarDialogState();
}

class _InvitarDialogState extends State<_InvitarDialog> {
  final _email = TextEditingController();
  final _nombre = TextEditingController();
  final _telefono = TextEditingController();
  final _prefijo = TextEditingController();
  String _rol = 'cobrador';
  bool _enviando = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _nombre.dispose();
    _telefono.dispose();
    _prefijo.dispose();
    super.dispose();
  }

  Future<void> _invitar() async {
    final email = _email.text.trim();
    final nombre = _nombre.text.trim();
    if (email.isEmpty || nombre.isEmpty) {
      setState(() => _error = 'Email y nombre requeridos');
      return;
    }
    final emailErr = Validators.email(email);
    if (emailErr != null) {
      setState(() => _error = emailErr);
      return;
    }
    final prefijo = _prefijo.text.trim().toUpperCase();
    if (prefijo.isNotEmpty && !RegExp(r'^[A-Z0-9-]{2,16}$').hasMatch(prefijo)) {
      setState(() => _error = 'Prefijo: [A-Z0-9-]{2,16}');
      return;
    }

    setState(() {
      _enviando = true;
      _error = null;
    });

    try {
      await invokeEdgeFunction(
        Supabase.instance.client,
        'invitar-cobrador',
        body: {
          'email': email,
          'nombre': nombre,
          'rol': _rol,
          if (_telefono.text.trim().isNotEmpty)
            'telefono': _telefono.text.trim(),
          if (_rol == 'cobrador' && prefijo.isNotEmpty)
            'prefijo_recibo': prefijo,
          // ?flow=invite: routea al invitado a /set-password tras
          // clickear el link del email (ver _extractAuthFlow en main).
          if (kIsWeb) 'redirect_to': '${Uri.base.origin}/?flow=invite',
        },
      );
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invitación enviada a $email')),
        );
      }
    } catch (e) {
      // El helper invokeEdgeFunction lanza Exception(msg); pelamos el
      // prefijo "Exception: " técnico antes de mostrar al user.
      if (mounted) {
        setState(() =>
            _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Invitar cobrador'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Recibirá un email con link para definir su contraseña. '
              'Una vez logueado, podrá usar la app.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'Email *'),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nombre,
              decoration: const InputDecoration(labelText: 'Nombre completo *'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _telefono,
              decoration: const InputDecoration(labelText: 'Teléfono'),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _rol,
              decoration: const InputDecoration(labelText: 'Rol'),
              items: const [
                DropdownMenuItem(value: 'cobrador', child: Text('Cobrador')),
                DropdownMenuItem(value: 'admin_cobranza', child: Text('Admin de cobranza')),
                DropdownMenuItem(value: 'admin', child: Text('Administrador')),
              ],
              onChanged: (v) => setState(() => _rol = v ?? _rol),
            ),
            if (_rol == 'cobrador') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _prefijo,
                decoration: const InputDecoration(
                  labelText: 'Prefijo de recibo',
                  hintText: 'COB-01',
                  helperText: 'Si lo dejás vacío, lo asignás después',
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')),
                  LengthLimitingTextInputFormatter(16),
                ],
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
          onPressed: _enviando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _enviando ? null : _invitar,
          child: Text(_enviando ? 'Enviando...' : 'Enviar invitación'),
        ),
      ],
    );
  }
}

class _CobradorCard extends ConsumerWidget {
  const _CobradorCard({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final activo = (row['activo'] as int? ?? 1) == 1;
    final rol = row['rol'] as String;
    final prefijo = row['prefijo_recibo'] as String?;
    final clientes = row['clientes_asignados'] as int? ?? 0;
    final cobradoMes = (row['cobrado_mes'] as num? ?? 0).toDouble();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: activo
                    ? _colorRol(rol, scheme).withValues(alpha: 0.15)
                    : scheme.surfaceContainerHighest,
                foregroundColor: activo ? _colorRol(rol, scheme) : scheme.outline,
                child: Text(_initials(row['nombre'] as String)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(row['nombre'] as String,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        _RolChip(rol: rol),
                        if (!activo) ...[
                          const SizedBox(width: 8),
                          Chip(
                            label: const Text('Inactivo'),
                            backgroundColor: scheme.surfaceContainerHighest,
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ],
                    ),
                    if (row['telefono'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(row['telefono'] as String,
                            style: TextStyle(color: scheme.outline, fontSize: 12)),
                      ),
                    if (rol == 'cobrador') ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 16,
                        runSpacing: 4,
                        children: [
                          _Stat(
                            label: 'Prefijo',
                            value: prefijo ?? '— sin asignar —',
                            color: prefijo == null ? scheme.error : null,
                          ),
                          _Stat(label: 'Clientes', value: '$clientes'),
                          _Stat(
                            label: 'Cobrado este mes',
                            value: Fmt.cordobas(cobradoMes),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.edit),
                tooltip: 'Editar',
                onPressed: () => _editar(context, ref, row),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editar(BuildContext context, WidgetRef ref, Map<String, dynamic> row) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _EditarCobradorDialog(row: row),
    );
  }

  String _initials(String s) {
    final parts = s.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  Color _colorRol(String rol, ColorScheme s) => switch (rol) {
        'admin' => s.primary,
        'admin_cobranza' => s.tertiary,
        _ => s.secondary,
      };
}

class _RolChip extends StatelessWidget {
  const _RolChip({required this.rol});
  final String rol;
  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(switch (rol) {
        'admin' => 'Admin',
        'admin_cobranza' => 'Cobranza',
        'cobrador' => 'Cobrador',
        _ => rol,
      }),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: Theme.of(context).colorScheme.outline, fontSize: 11)),
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: color)),
      ],
    );
  }
}

class _EditarCobradorDialog extends ConsumerStatefulWidget {
  const _EditarCobradorDialog({required this.row});
  final Map<String, dynamic> row;

  @override
  ConsumerState<_EditarCobradorDialog> createState() => _EditarCobradorDialogState();
}

class _EditarCobradorDialogState extends ConsumerState<_EditarCobradorDialog> {
  late TextEditingController _nombreCtrl;
  late TextEditingController _telCtrl;
  late TextEditingController _prefijoCtrl;
  late String _rol;
  late bool _activo;
  String? _error;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    _nombreCtrl = TextEditingController(text: widget.row['nombre'] as String);
    _telCtrl = TextEditingController(text: widget.row['telefono'] as String? ?? '');
    _prefijoCtrl =
        TextEditingController(text: widget.row['prefijo_recibo'] as String? ?? '');
    _rol = widget.row['rol'] as String;
    _activo = (widget.row['activo'] as int? ?? 1) == 1;
  }

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _telCtrl.dispose();
    _prefijoCtrl.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    final prefijo = _prefijoCtrl.text.trim().toUpperCase();
    if (prefijo.isNotEmpty && !RegExp(r'^[A-Z0-9-]{2,16}$').hasMatch(prefijo)) {
      setState(() => _error =
          'Prefijo: solo letras mayúsculas, números y guiones (2 a 16 chars)');
      return;
    }

    // Confirmar cambios sensibles: rol y desactivación.
    final rolViejo = widget.row['rol'] as String;
    final activoViejo = (widget.row['activo'] as int? ?? 1) == 1;
    final cambiaRol = _rol != rolViejo;
    final desactiva = activoViejo && !_activo;

    if (cambiaRol || desactiva) {
      final msgs = <String>[];
      if (cambiaRol) {
        msgs.add('• Rol: $rolViejo → $_rol');
      }
      if (desactiva) {
        msgs.add('• Desactivás el cobrador (sus cobros pendientes quedan asignados pero no podrá loguearse).');
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirmar cambios'),
          content: Text('${msgs.join('\n')}\n\n¿Continuar?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await ps.db.execute(
        '''
        UPDATE cobradores
           SET nombre = ?, telefono = ?, rol = ?,
               prefijo_recibo = ?, activo = ?
         WHERE id = ?
        ''',
        [
          _nombreCtrl.text.trim(),
          _telCtrl.text.trim().isEmpty ? null : _telCtrl.text.trim(),
          _rol,
          prefijo.isEmpty ? null : prefijo,
          _activo ? 1 : 0,
          widget.row['id'],
        ],
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Editar cobrador'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nombreCtrl,
                decoration: const InputDecoration(labelText: 'Nombre'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _telCtrl,
                decoration: const InputDecoration(labelText: 'Teléfono'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _rol,
                decoration: const InputDecoration(labelText: 'Rol'),
                items: const [
                  DropdownMenuItem(value: 'admin', child: Text('Administrador')),
                  DropdownMenuItem(value: 'admin_cobranza', child: Text('Admin de cobranza')),
                  DropdownMenuItem(value: 'cobrador', child: Text('Cobrador')),
                ],
                onChanged: (v) => setState(() => _rol = v ?? _rol),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _prefijoCtrl,
                decoration: const InputDecoration(
                  labelText: 'Prefijo de recibo',
                  hintText: 'COB-01, PEDRO, ...',
                  helperText: 'Solo para rol "cobrador". Único por empresa.',
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')),
                  LengthLimitingTextInputFormatter(16),
                ],
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                value: _activo,
                onChanged: (v) => setState(() => _activo = v),
                title: Text(_activo ? 'Activo' : 'Inactivo'),
                contentPadding: EdgeInsets.zero,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _guardando ? null : _guardar,
          child: Text(_guardando ? 'Guardando...' : 'Guardar'),
        ),
      ],
    );
  }
}
