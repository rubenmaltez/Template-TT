import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/impersonation_provider.dart';
import '../../../data/providers/modulos_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/repositories/super_admin_repo.dart';
import '../../../data/utils/edge_functions.dart';
import '../../../data/utils/formatters.dart';
import '../../../data/utils/validators.dart';
import '../../../powersync/db.dart' as ps;
import '../../super_admin/tenant_dialogs_miembro.dart' show ForzarPasswordDialog;
import '../../shared/widgets/credenciales_dialog.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_cambios_widget.dart';
import '../../shared/widgets/phone_text_field.dart';
import '../../../data/utils/errores.dart';

/// Los 3 roles que cobran en campo y por lo tanto necesitan prefijo de
/// recibo (correlativo propio). El super_admin NO cobra → no lleva prefijo.
const _kRolesQueCobran = {'cobrador', 'admin', 'admin_cobranza'};

/// Map cobrador_id → email para los miembros del tenant del caller. El email
/// vive en `auth.users` (no en `cobradores`), así que se trae por RPC
/// SECURITY DEFINER `list_cobrador_emails` (migración 0091) con guard de rol.
///
/// Es online-only (toca auth.users vía RPC): si no hay conexión el provider
/// queda en error/loading y la UI degrada elegante (no muestra email, no
/// rompe la lista). autoDispose para no retener el map al salir de la pantalla.
final _cobradorEmailsProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final res = await Supabase.instance.client.rpc('list_cobrador_emails')
      as List<dynamic>;
  final map = <String, String>{};
  for (final e in res) {
    final row = Map<String, dynamic>.from(e as Map);
    final id = row['cobrador_id'] as String?;
    final email = row['email'] as String?;
    if (id != null && email != null) map[id] = email;
  }
  return map;
});

/// Gestión de cobradores: ver lista, asignar prefijo de recibo, cambiar
/// rol, activar/desactivar.
///
/// Nota: la creación del usuario en auth.users requiere Supabase Admin
/// API (service role key), que NO va en el cliente. Se invita desde
/// Supabase Dashboard; cuando el cobrador se logea por primera vez
/// (después de que el trigger de Supabase cree su fila en cobradores
/// vía una Edge Function pendiente), aparece acá para configurar.
class CobradoresAdminScreen extends ConsumerStatefulWidget {
  const CobradoresAdminScreen({super.key});

  @override
  ConsumerState<CobradoresAdminScreen> createState() =>
      _CobradoresAdminScreenState();
}

class _CobradoresAdminScreenState
    extends ConsumerState<CobradoresAdminScreen> {
  late final Stream<List<Map<String, dynamic>>> _cobradoresStream;

  @override
  void initState() {
    super.initState();
    // Subqueries en SELECT evitan el producto cartesiano que tendrían
    // dos LEFT JOINs (clientes × pagos) sobre el mismo cobrador.
    _cobradoresStream = ps.db.watch(
      '''
      SELECT co.id, co.nombre, co.telefono, co.rol,
             co.prefijo_recibo, co.activo, co.puede_cambiar_fecha,
             (SELECT COUNT(*) FROM clientes
               WHERE cobrador_id = co.id AND activo = 1
             ) AS clientes_asignados,
             (SELECT COALESCE(SUM(monto_cordobas), 0) FROM pagos
               WHERE cobrador_id = co.id
                 AND anulado = 0
                 AND date(fecha_pago) >= date('now', '-6 hours', 'start of month')
             ) AS cobrado_mes
        FROM cobradores co
       ORDER BY co.activo DESC, co.rol, co.nombre
      ''',
    );
  }

  Future<void> _abrirInvitar(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _InvitarDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _cobradoresStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text(mensajeErrorHumano(snap.error!)));
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

class _InvitarDialog extends ConsumerStatefulWidget {
  const _InvitarDialog();
  @override
  ConsumerState<_InvitarDialog> createState() => _InvitarDialogState();
}

class _InvitarDialogState extends ConsumerState<_InvitarDialog> {
  final _email = TextEditingController();
  final _nombre = TextEditingController();
  final _telefono = TextEditingController();
  final _prefijo = TextEditingController();
  String _rol = 'cobrador';
  bool _enviando = false;
  // Mismo patrón que _CrearTenantDialog e InvitarAdminDialog: default OFF
  // por decisión de producto (onboarding sin email).
  bool _enviarEmail = false;
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
    // El prefijo aplica a los 3 roles que cobran (cobrador/admin/admin_cobranza).
    final rolCobra = _kRolesQueCobran.contains(_rol);
    if (rolCobra && prefijo.isNotEmpty && !RegExp(r'^[A-Z0-9-]{2,16}$').hasMatch(prefijo)) {
      setState(() => _error = 'Prefijo: [A-Z0-9-]{2,16}');
      return;
    }
    // Auto-generar prefijo si el admin lo dejó vacío: primeras 2 letras
    // del nombre en mayúscula. Evita el caso donde el usuario no puede
    // cobrar porque no tiene prefijo asignado (E2E bug). Aplica a los 3
    // roles que cobran, no sólo a cobrador.
    final prefijoFinal = prefijo.isNotEmpty
        ? prefijo
        : rolCobra && nombre.length >= 2
            ? nombre.substring(0, 2).toUpperCase()
            : '';

    // Capturamos refs al Navigator y ScaffoldMessenger ANTES del await
    // para no usar el context del State (que queda desmontado tras el
    // primer pop). Sin esto el lint use_build_context_synchronously
    // flaggea legítimo y en runtime el showDialog puede no aparecer.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final rootContext = Navigator.of(context, rootNavigator: true).context;

    // Si el super_admin está impersonando un tenant, la Edge Function
    // `invitar-cobrador` exige el `tenant_id` en el body (el caller
    // super_admin no tiene tenant operativo propio). Lo leemos del
    // provider de impersonación; para un admin normal es null y no se
    // manda (el server lo infiere del JWT del caller).
    final tenantImpersonado =
        ref.read(impersonatedTenantIdProvider).valueOrNull;

    setState(() {
      _enviando = true;
      _error = null;
    });

    try {
      final data = await invokeEdgeFunction(
        Supabase.instance.client,
        'invitar-cobrador',
        body: {
          'email': email,
          'nombre': nombre,
          'rol': _rol,
          if (tenantImpersonado != null) 'tenant_id': tenantImpersonado,
          if (PhoneTextField.sanitized(_telefono) != null)
            'telefono': PhoneTextField.sanitized(_telefono),
          if (prefijoFinal.isNotEmpty) 'prefijo_recibo': prefijoFinal,
          // Explícito para que el server no asuma default si en el
          // futuro cambia (mismo patrón que crear-tenant).
          'enviar_email': _enviarEmail,
          // ?flow=invite: routea al invitado a /set-password tras
          // clickear el link del email. Sólo aplica al path email
          // (ver _extractAuthFlow en main).
          if (kIsWeb && _enviarEmail)
            'redirect_to': '${Uri.base.origin}/?flow=invite',
        },
      );
      final nuevaPassword = data['nueva_password'] as String?;
      if (nuevaPassword != null && nuevaPassword.isNotEmpty) {
        // Path no-email: cerramos este dialog y abrimos el de
        // credenciales — el admin tiene UNA oportunidad de copiar la
        // password antes de que se pierda. Si cierra sin copiar tiene
        // que ir a "Forzar contraseña" en la fila del cobrador.
        navigator.pop();
        await showDialog<bool>(
          context: rootContext,
          barrierDismissible: false,
          builder: (_) => CredencialesDialog(
            title: 'Credenciales de $nombre',
            email: email,
            password: nuevaPassword,
            intro:
                'Usuario creado. Pasale email + contraseña por canal '
                'seguro — esta es la única vez que la contraseña queda '
                'visible.',
          ),
        );
      } else {
        // Path email: snackbar tradicional + pop.
        navigator.pop();
        messenger.showSnackBar(
          SnackBar(content: Text('Invitación enviada a $email')),
        );
      }
    } catch (e) {
      // El helper invokeEdgeFunction debería lanzar Exception(msg);
      // pelamos el prefijo "Exception: " técnico antes de mostrar al
      // user. Defensive: si por algún motivo el helper no procesó y
      // llega un FunctionException raw, extraemos el campo `error`
      // del toString para no exponer el wrapper técnico.
      if (mounted) {
        setState(() => _error = humanizarEdgeError(e));
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Roles de tickets (Técnico / Admin de tickets) solo si el tenant tiene el
    // módulo tickets habilitado.
    final ticketsOn = ref
            .watch(modulosHabilitadosProvider)
            .valueOrNull
            ?.contains('tickets') ??
        false;
    // Width responsive: 400 en desktop/tablet, 90% del viewport en
    // mobile chico (iPhone SE = 375, no entra el 400 fijo + el switch
    // wrappea feo). Mismo patrón que _CrearTenantDialog.
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 400.0;
    return AlertDialog(
      title: const Text('Invitar cobrador'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // SwitchListTile(
            //   value: _enviarEmail,
            //   onChanged: _enviando
            //       ? null
            //       : (v) => setState(() => _enviarEmail = v),
            //   title: const Text('Enviar email de invitación'),
            //   subtitle: Text(
            //     _enviarEmail
            //         ? 'El usuario recibe el link en su correo.'
            //         : 'No se envía email. Te generamos una contraseña '
            //             'para compartir manualmente.',
            //     style: const TextStyle(fontSize: 11),
            //   ),
            //   contentPadding: EdgeInsets.zero,
            //   dense: true,
            //   visualDensity: VisualDensity.compact,
            // ),
            // const SizedBox(height: 8),
            Text(
              _enviarEmail
                  ? 'Recibirá un email con link para definir su '
                      'contraseña. Una vez logueado, podrá usar la app.'
                  : 'Se creará el usuario con una contraseña aleatoria '
                      '(no se manda email — la vas a copiar y compartir '
                      'vos).',
              style: TextStyle(color: scheme.outline, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'Email *'),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              enabled: !_enviando,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nombre,
              enabled: !_enviando,
              decoration: const InputDecoration(labelText: 'Nombre completo *'),
            ),
            const SizedBox(height: 12),
            PhoneTextField(
              controller: _telefono,
              enabled: !_enviando,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _rol,
              decoration: const InputDecoration(labelText: 'Rol'),
              items: [
                const DropdownMenuItem(
                    value: 'cobrador', child: Text('Cobrador')),
                const DropdownMenuItem(
                    value: 'admin_cobranza', child: Text('Admin de cobranza')),
                const DropdownMenuItem(
                    value: 'admin', child: Text('Administrador')),
                // `admin_tickets` NO se ofrece: es un rol incompleto (sin shell
                // ni bucket de sync propios → caería en el shell del cobrador
                // con data vacía). Alineado con el diálogo del super_admin que
                // tampoco lo expone. Completarlo es feature pendiente.
                if (ticketsOn)
                  const DropdownMenuItem(
                      value: 'tecnico', child: Text('Técnico')),
              ],
              onChanged: _enviando
                  ? null
                  : (v) => setState(() => _rol = v ?? _rol),
            ),
            // Los 3 roles que cobran llevan prefijo de recibo (correlativo
            // propio). Sólo super_admin no lo necesita (no cobra en campo).
            if (_kRolesQueCobran.contains(_rol)) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _prefijo,
                enabled: !_enviando,
                decoration: const InputDecoration(
                  labelText: 'Prefijo de recibo',
                  hintText: 'COB-01',
                  helperText: 'Si lo dejás vacío, se genera automáticamente del nombre',
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')),
                  LengthLimitingTextInputFormatter(16),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _enviando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        // Label e icono cambian según modo — paralelo a
        // _ReenviarInvitacionDialog: ambos describen el artifact
        // resultante, no el canal de entrega.
        FilledButton.icon(
          onPressed: _enviando ? null : _invitar,
          icon: _enviando
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(_enviarEmail ? Icons.send : Icons.lock_reset),
          label: Text(_enviando
              ? 'Procesando…'
              : _enviarEmail
                  ? 'Enviar invitación'
                  : 'Generar contraseña'),
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
    // Email del miembro (de auth.users vía RPC). Degrada a null si la RPC
    // no respondió (offline / loading / error) — sin romper la fila.
    final email = ref
        .watch(_cobradorEmailsProvider)
        .valueOrNull?[row['id'] as String];

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
                    if (email != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Icon(Icons.mail_outline,
                                size: 12, color: scheme.outline),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                email,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: scheme.outline, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    // Stats (prefijo / clientes / cobrado) para los 3 roles
                    // que cobran — todos llevan prefijo y pueden tener
                    // clientes asignados y cobros del mes.
                    if (_kRolesQueCobran.contains(rol)) ...[
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
              // Historial de cambios (0116, fix #9 del audit): cobradores era
              // la única entidad editable sin rastro — y el prefijo de recibo
              // es numeración de dinero.
              IconButton(
                icon: const Icon(Icons.history),
                tooltip: 'Historial de cambios',
                onPressed: () => _historial(context, row['id'] as String),
              ),
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

  void _historial(BuildContext context, String cobradorId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scrollCtrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.history),
                  const SizedBox(width: 8),
                  Text('Historial del miembro',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollCtrl,
                child: HistorialCambiosWidget(
                  tabla: 'cobradores',
                  registroId: cobradorId,
                ),
              ),
            ),
          ],
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
        // Default legible (s.secondary es primary al 10% → iniciales invisibles).
        _ => s.onSurfaceVariant,
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
        'tecnico' => 'Técnico',
        'admin_tickets' => 'Admin tickets',
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
  // Permiso de cambio de fecha de pago por días (feature C, 0119).
  late bool _puedeCambiarFecha;
  String? _error;
  bool _guardando = false;

  // El dropdown de rol solo es editable para el super_admin (el backend lo
  // restringe a la RPC super_admin-only vía el trigger cobradores_freeze_rol).
  bool get _puedeCambiarRol =>
      ref.watch(cobradorActualProvider).valueOrNull?.esSuperAdmin ?? false;

  // Forzar contraseña: sólo admin o super_admin (NO admin_cobranza), y nunca
  // sobre el propio usuario. El backend (Edge Function) replica estos guards
  // y además limita al admin a su tenant + roles no-admin; acá filtramos la
  // UI para no ofrecer el botón cuando seguro va a fallar.
  bool get _puedeForzarPassword {
    final yo = ref.watch(cobradorActualProvider).valueOrNull;
    if (yo == null) return false;
    if (!(yo.esAdmin || yo.esSuperAdmin)) return false;
    // No sobre uno mismo.
    if (widget.row['id'] == yo.id) return false;
    return true;
  }

  Future<void> _forzarPassword() async {
    final nombre = widget.row['nombre'] as String;
    // Reusa el dialog del panel super_admin: pide / genera la password y la
    // devuelve por pop. null/"" = cancelado.
    final nuevaPassword = await showDialog<String>(
      context: context,
      builder: (_) => ForzarPasswordDialog(nombre: nombre),
    );
    if (nuevaPassword == null || nuevaPassword.isEmpty) return;
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    // Email del target para mostrarlo junto a la password (de la RPC de
    // emails); si no está, mostramos un placeholder no-bloqueante.
    final email = ref
            .read(_cobradorEmailsProvider)
            .valueOrNull?[widget.row['id'] as String] ??
        '(email no disponible)';

    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await ref.read(superAdminRepoProvider).forzarPasswordCobrador(
            cobradorId: widget.row['id'] as String,
            nuevaPassword: nuevaPassword,
          );
      if (!mounted) return;
      // CredencialesDialog SÓLO muestra — la generación/invoke ya ocurrió.
      await showDialog<bool>(
        context: rootContext,
        barrierDismissible: false,
        builder: (_) => CredencialesDialog(
          title: 'Contraseña de $nombre',
          email: email,
          password: nuevaPassword,
          intro:
              'Contraseña forzada. Pasale email + contraseña por canal seguro '
              '— el usuario quedó deslogueado y debe entrar con esta nueva.',
        ),
      );
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('No se pudo forzar la contraseña: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _nombreCtrl = TextEditingController(text: widget.row['nombre'] as String);
    _telCtrl = TextEditingController(text: widget.row['telefono'] as String? ?? '');
    _prefijoCtrl =
        TextEditingController(text: widget.row['prefijo_recibo'] as String? ?? '');
    _rol = widget.row['rol'] as String;
    _activo = (widget.row['activo'] as int? ?? 1) == 1;
    _puedeCambiarFecha = (widget.row['puede_cambiar_fecha'] as int? ?? 0) == 1;
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
      // prefijo_recibo aplica a los 3 roles que cobran (cobrador/admin/
      // admin_cobranza); sólo super_admin no lo lleva. Espeja lo que hace
      // la RPC set_cobrador_rol, para que no diverjan.
      final prefijoFinal =
          (_kRolesQueCobran.contains(_rol) && prefijo.isNotEmpty)
              ? prefijo
              : null;
      // nombre/teléfono/prefijo/activo: UPDATE local directo. NO incluye `rol`:
      // el trigger cobradores_freeze_rol (0066) rechaza el write directo de rol
      // (la UI mostraría éxito falso y el sync se rechazaría). El rol va por RPC.
      await ps.db.execute(
        '''
        UPDATE cobradores
           SET nombre = ?, telefono = ?, prefijo_recibo = ?, activo = ?,
               puede_cambiar_fecha = ?
         WHERE id = ?
        ''',
        [
          _nombreCtrl.text.trim(),
          PhoneTextField.sanitized(_telCtrl),
          prefijoFinal,
          _activo ? 1 : 0,
          _puedeCambiarFecha ? 1 : 0,
          widget.row['id'],
        ],
      );
      // Cambio de rol (solo super_admin; el dropdown está locked para el
      // resto): server-side vía RPC, que valida y escribe el audit_log.
      if (cambiaRol) {
        await ref.read(superAdminRepoProvider).setCobradorRol(
              cobradorId: widget.row['id'] as String,
              nuevoRol: _rol,
            );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Ancho responsive: 400 en desktop/tablet, 90% del viewport en mobile
    // chico (un 400 fijo desborda el AlertDialog en pantallas ~360px).
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 400.0;
    // Roles de tickets: si el tenant tiene el módulo, o si el miembro YA es uno
    // de esos roles (para no romper el dropdown con un value fuera de items).
    final mostrarTickets = (ref
                .watch(modulosHabilitadosProvider)
                .valueOrNull
                ?.contains('tickets') ??
            false) ||
        _rol == 'tecnico' ||
        _rol == 'admin_tickets';
    return AlertDialog(
      title: const Text('Editar cobrador'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: dialogW,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nombreCtrl,
                decoration: const InputDecoration(labelText: 'Nombre'),
              ),
              const SizedBox(height: 12),
              PhoneTextField(controller: _telCtrl),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _rol,
                decoration: InputDecoration(
                  labelText: 'Rol',
                  helperText: _puedeCambiarRol
                      ? null
                      : 'Solo el super_admin puede cambiar el rol',
                ),
                items: [
                  const DropdownMenuItem(
                      value: 'admin', child: Text('Administrador')),
                  const DropdownMenuItem(
                      value: 'admin_cobranza',
                      child: Text('Admin de cobranza')),
                  const DropdownMenuItem(
                      value: 'cobrador', child: Text('Cobrador')),
                  if (mostrarTickets)
                    const DropdownMenuItem(
                        value: 'tecnico', child: Text('Técnico')),
                  // `admin_tickets` no se ofrece para asignar (rol incompleto,
                  // ver create dialog). Solo se muestra si el miembro YA lo
                  // tiene, para no romper el dropdown con un value fuera de items.
                  if (_rol == 'admin_tickets')
                    const DropdownMenuItem(
                        value: 'admin_tickets',
                        child: Text('Admin de tickets (legacy)')),
                ],
                onChanged: _puedeCambiarRol
                    ? (v) => setState(() => _rol = v ?? _rol)
                    : null,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _prefijoCtrl,
                decoration: const InputDecoration(
                  labelText: 'Prefijo de recibo',
                  hintText: 'COB-01, PEDRO, ...',
                  helperText:
                      'Para roles que cobran (cobrador / admin / cobranza). Único por empresa.',
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
              // Permiso de cambio de fecha de pago por días (feature C, 0119):
              // solo si el super_admin habilitó la feature para el tenant, y solo
              // para cobrador/admin_cobranza (el admin siempre puede).
              if (ref.watch(appSettingsProvider).cambioFechaHabilitado &&
                  (_rol == 'cobrador' || _rol == 'admin_cobranza'))
                SwitchListTile(
                  value: _puedeCambiarFecha,
                  onChanged: (v) => setState(() => _puedeCambiarFecha = v),
                  title: const Text('Puede cambiar fecha de pago'),
                  subtitle: const Text(
                      'Cobra los días puente y mueve la fecha de pago del cliente'),
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
        if (_puedeForzarPassword)
          TextButton.icon(
            icon: const Icon(Icons.lock_reset, size: 18),
            label: const Text('Forzar contraseña'),
            onPressed: _guardando ? null : _forzarPassword,
          ),
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
