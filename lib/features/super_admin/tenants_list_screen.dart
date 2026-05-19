import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/modulo.dart';
import '../../data/models/tenant_admin.dart';
import '../../data/repositories/super_admin_repo.dart';
import '../../data/utils/cobrador_helpers.dart';
import '../../data/utils/formatters.dart';
import '../shared/widgets/animated_list_entry.dart';
import '../shared/widgets/skeleton.dart';

Future<void> _abrirCrearTenant(BuildContext context, WidgetRef ref) async {
  // Capturamos messenger antes del await — el showSnackBar post-éxito lo
  // usamos sin pasar por el context (que podría tener cambios pendientes).
  final messenger = ScaffoldMessenger.of(context);
  final resultado = await showDialog<
      ({
        String tenantId,
        String adminUserId,
        String adminEmail,
        String? adminPassword,
      })>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _CrearTenantDialog(),
  );
  if (resultado == null) return;
  ref.invalidate(tenantsAdminProvider);

  // Si vino una password, el super_admin pidió no-email — abrimos
  // dialog que muestra email+password para copiar (mismo patrón que
  // _PasswordCopiarDialog de forzar-password). La password se generó
  // server-side y NO queda guardada en ningún lado — esta es la
  // única oportunidad de verla; si la pierde, hay que ir a "Forzar
  // contraseña" desde el detalle del miembro para generar otra.
  //
  // El dialog devuelve true si el user copió la password — sólo en
  // ese caso navegamos al detalle (parity con la action "Ver detalle"
  // del path de email). Si cerró sin copiar, lo dejamos en la lista
  // por si quiere reintentar.
  final password = resultado.adminPassword;
  if (password != null && password.isNotEmpty) {
    if (!context.mounted) return;
    final copio = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AdminCredencialesDialog(
        email: resultado.adminEmail,
        password: password,
      ),
    );
    if (copio == true && context.mounted) {
      context.go('/super/tenants/${resultado.tenantId}');
    }
    return;
  }

  // Path con email: snackbar + acción "Ver detalle". Nos quedamos en
  // la lista para que el super_admin pueda crear varios seguidos sin
  // navegar manualmente cada vez.
  messenger.showSnackBar(
    SnackBar(
      content: const Text('ISP creado e invitación enviada por email'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 6),
      action: SnackBarAction(
        label: 'Ver detalle',
        onPressed: () {
          if (!context.mounted) return;
          context.go('/super/tenants/${resultado.tenantId}');
        },
      ),
    ),
  );
}

/// Lista de tenants — pantalla raíz del panel /super.
class TenantsListScreen extends ConsumerWidget {
  const TenantsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tenantsAsync = ref.watch(tenantsAdminProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(tenantsAdminProvider),
      child: tenantsAsync.when(
        // Skeleton imitando la altura final — sin layout jump al cargar.
        // Usamos ListView (no SingleChildScrollView) para que el
        // RefreshIndicator funcione consistente entre loading y data.
        loading: () => ListView(
          padding: const EdgeInsets.all(16),
          children: const [
            SkeletonList(
              count: 3,
              hasAvatar: true,
              hasChip: true,
              cardMarginBottom: 12,
            ),
          ],
        ),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Error cargando tenants:\n$e',
                textAlign: TextAlign.center),
          ),
        ),
        data: (tenants) {
          if (tenants.isEmpty) {
            // Sin tenants: la card del CTA es suficiente — agregar un
            // EmptyState debajo era duplicar el mismo mensaje.
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _CrearTenantCard(
                  onTap: () => _abrirCrearTenant(context, ref),
                ),
              ],
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            // +1 por la card de "crear" que renderizamos en index 0.
            itemCount: tenants.length + 1,
            itemBuilder: (_, i) {
              if (i == 0) {
                return _CrearTenantCard(
                  onTap: () => _abrirCrearTenant(context, ref),
                );
              }
              final tenant = tenants[i - 1];
              return AnimatedListEntry(
                // Key estable por id: si la lista crece/shrinkea, los items
                // existentes no se re-animan ni se descolocan.
                key: ValueKey(tenant.id),
                index: i - 1,
                child: _TenantCard(tenant: tenant),
              );
            },
          );
        },
      ),
    );
  }
}

class _TenantCard extends StatefulWidget {
  const _TenantCard({required this.tenant});
  final TenantAdmin tenant;

  @override
  State<_TenantCard> createState() => _TenantCardState();
}

class _TenantCardState extends State<_TenantCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tenant = widget.tenant;
    // Reduce motion (WCAG): si el OS lo pide, animamos sin duración.
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final animDur = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 150);
    // Lift sólo si hover activo Y no reducimos motion.
    final lift = (_hover && !reduceMotion) ? -2.0 : 0.0;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // AnimatedContainer maneja color, shadow y desplazamiento en una sola
      // animación. Material transparente adentro para que el InkWell tenga
      // su ripple sin pelearse con el bg.
      child: AnimatedContainer(
        duration: animDur,
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 12),
        transform: Matrix4.identity()..translate(0.0, lift),
        transformAlignment: Alignment.center,
        decoration: BoxDecoration(
          // Salto de 2 tonos en dark theme + borde sutil en hover para
          // que la diferencia sea perceptible (sin border, surfaceLow→High
          // en dark es apenas visible).
          color: _hover
              ? scheme.surfaceContainerHighest
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _hover ? scheme.outlineVariant : Colors.transparent,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: _hover ? 0.18 : 0.05),
              blurRadius: _hover ? 10 : 3,
              offset: Offset(0, _hover ? 4 : 1),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.go('/super/tenants/${tenant.id}'),
            child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: scheme.primaryContainer,
                    child: Text(
                      initialsFromName(tenant.nombre),
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tenant.nombre,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'Creado ${Fmt.fechaLarga(tenant.createdAt)}',
                          style: TextStyle(
                              color: scheme.outline, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.people_outline,
                      size: 16, color: scheme.outline),
                  const SizedBox(width: 4),
                  Text(
                    '${tenant.cobradoresCount} cobradores activos',
                    style: TextStyle(color: scheme.outline, fontSize: 13),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: tenant.modulosHabilitados
                    .map((m) => Chip(
                          label: Text(m),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: scheme.secondaryContainer,
                          labelStyle:
                              TextStyle(color: scheme.onSecondaryContainer),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
          ),
        ),
      ),
    );
  }

}

/// Card "+ Crear nuevo tenant" arriba de la lista. Mismo border-radius
/// y altura aproximada que los _TenantCard para que la lista no salte
/// visualmente, pero con tinte primary y borde resaltado para que sea
/// claramente un CTA y no un row más.
class _CrearTenantCard extends StatelessWidget {
  const _CrearTenantCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: scheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: scheme.primary.withValues(alpha: 0.4),
                width: 1.5,
              ),
            ),
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 18),
            child: Row(
              children: [
                Icon(Icons.add_business, color: scheme.primary, size: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Crear nuevo ISP',
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Da de alta un ISP y enviá la invitación',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward, color: scheme.primary, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Dialog del flow alta-tenant. Toma nombre del tenant, datos del admin
/// y módulos no-base opcionales; llama a la Edge Function `crear-tenant`
/// y al éxito devuelve {tenantId, adminUserId} al caller para que
/// navegue al detalle.
class _CrearTenantDialog extends ConsumerStatefulWidget {
  const _CrearTenantDialog();

  @override
  ConsumerState<_CrearTenantDialog> createState() =>
      _CrearTenantDialogState();
}

class _CrearTenantDialogState extends ConsumerState<_CrearTenantDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nombreCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _adminNombreCtrl = TextEditingController();
  final _telefonoCtrl = TextEditingController();
  // Set de códigos de módulos extras seleccionados (los base ya van
  // automáticos vía trigger, no se muestran como opciones).
  final Set<String> _modulosExtras = {};
  // Default true: queremos que el flow normal mande el email. El
  // switch permite saltar el envío — el server crea al admin con una
  // password aleatoria y la devuelve para que el super_admin la
  // comparta a mano (workaround para SMTP en sandbox o destinatarios
  // sin email automatizado).
  bool _enviarEmail = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _emailCtrl.dispose();
    _adminNombreCtrl.dispose();
    _telefonoCtrl.dispose();
    super.dispose();
  }

  Future<void> _crear() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(superAdminRepoProvider);
      // Telefono opcional: si el campo quedó vacío, mandamos null para
      // que la metadata del invite no quede con "" — el trigger
      // handle_new_user trataría "" como un valor seteado.
      final telTrim = _telefonoCtrl.text.trim();
      final resultado = await repo.crearTenant(
        nombre: _nombreCtrl.text.trim(),
        adminEmail: _emailCtrl.text.trim(),
        adminNombre: _adminNombreCtrl.text.trim(),
        adminTelefono: telTrim.isEmpty ? null : telTrim,
        modulosExtra: _modulosExtras.toList(),
        // Sin redirect_to con flow=invite, el link cae al root y se
        // pierde el routing a /set-password — tanto para emails como
        // para links generados manualmente.
        redirectTo:
            kIsWeb ? '${Uri.base.origin}/?flow=invite' : null,
        enviarEmail: _enviarEmail,
      );
      if (!mounted) return;
      Navigator.of(context).pop(resultado);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 480.0;
    final modulosAsync = ref.watch(modulosProvider);
    // PopScope con canPop:!_busy: evita que Esc o el back-gesture
    // cierren el dialog mid-request (la operación sigue corriendo en
    // el server, dejaríamos al user sin saber el resultado).
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
      icon: Icon(Icons.add_business, color: scheme.primary, size: 32),
      title: const Text('Crear ISP'),
      content: SizedBox(
        width: dialogW,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _nombreCtrl,
                  enabled: !_busy,
                  // autofocus: queremos que arranque tipeando el
                  // nombre, no que tenga que tabbear primero. Sin esto,
                  // el textInputAction.next del primer field no tiene
                  // de dónde saltar.
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Nombre del ISP',
                    hintText: 'ej: ISP Las Lomas',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return 'Requerido';
                    if (t.length > 120) return 'Máximo 120 caracteres';
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  'Admin del tenant',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _emailCtrl,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    hintText: 'marcos@laslomas.ni',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return 'Requerido';
                    final ok = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                        .hasMatch(t);
                    if (!ok) return 'Email inválido';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _adminNombreCtrl,
                  enabled: !_busy,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.name],
                  decoration: const InputDecoration(
                    labelText: 'Nombre completo',
                    hintText: 'Marcos Pineda',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Requerido' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _telefonoCtrl,
                  enabled: !_busy,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  decoration: const InputDecoration(
                    labelText: 'Teléfono (opcional)',
                    hintText: '+505 8888 1234',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Módulos adicionales',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                modulosAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(),
                  ),
                  error: (e, _) => Text(
                    'No se pudieron cargar los módulos: $e',
                    style: TextStyle(
                        color: scheme.error, fontSize: 12),
                  ),
                  // Renderiza TODOS los módulos (base y no-base). Los
                  // base aparecen disabled-checked para que el
                  // super_admin vea qué viene incluido y no se quede
                  // buscando Cobranza en la lista.
                  data: (mods) => _ModulosPicker(
                    modulos: mods,
                    seleccionadosExtra: _modulosExtras,
                    onChanged: _busy
                        ? null
                        : (codigo, checked) {
                            setState(() {
                              if (checked) {
                                _modulosExtras.add(codigo);
                              } else {
                                _modulosExtras.remove(codigo);
                              }
                            });
                          },
                  ),
                ),
                const SizedBox(height: 8),
                // Switch para saltar el envío de email — útil con SMTP
                // en sandbox. Default ON (manda email) — el flow
                // normal con dominio Resend verificado. Cuando OFF,
                // el server crea al admin con password aleatoria y la
                // devuelve para que el super_admin la comparta a mano.
                SwitchListTile(
                  value: _enviarEmail,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _enviarEmail = v),
                  title: const Text('Enviar email de invitación'),
                  subtitle: Text(
                    _enviarEmail
                        ? 'El admin recibe el link en su correo.'
                        : 'No se envía email. Te generamos una '
                            'contraseña para compartir manualmente.',
                    style: const TextStyle(fontSize: 11),
                  ),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    container: true,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.error_outline,
                              color: scheme.onErrorContainer, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: scheme.onErrorContainer,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        // Semantics.hint comunica el side-effect al screen reader.
        // El label y el ícono cambian según el modo: email vs
        // password generada server-side.
        Semantics(
          button: true,
          enabled: !_busy,
          hint: _enviarEmail
              ? 'Envía un correo de invitación al admin del ISP'
              : 'Crea el ISP y genera la contraseña del admin para '
                  'que la copies',
          child: FilledButton.icon(
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_enviarEmail ? Icons.send : Icons.key),
            label: Text(
              _busy
                  ? 'Creando…'
                  : _enviarEmail
                      ? 'Crear y enviar invitación'
                      : 'Crear y generar contraseña',
            ),
            onPressed: _busy ? null : _crear,
          ),
        ),
      ],
    ),
    );
  }
}

/// Picker de módulos para el alta de tenant. Los módulos base se
/// renderean disabled-checked (el trigger los habilita automáticamente
/// al crear el tenant — el super_admin no puede ni deseleccionarlos);
/// los no-base son checkboxes interactivos cuyo estado vive en
/// `seleccionadosExtra` (set de códigos elegidos por el caller).
class _ModulosPicker extends StatelessWidget {
  const _ModulosPicker({
    required this.modulos,
    required this.seleccionadosExtra,
    required this.onChanged,
  });

  final List<Modulo> modulos;
  final Set<String> seleccionadosExtra;
  // onChanged null = todos los checkboxes deshabilitados (estado busy
  // del dialog padre). Sólo se llama para módulos no-base.
  final void Function(String codigo, bool checked)? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (modulos.isEmpty) {
      return Text(
        'No hay módulos en el catálogo.',
        style: TextStyle(
            color: scheme.onSurfaceVariant, fontSize: 12),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: modulos.map((m) {
        final esBase = m.esBase;
        return CheckboxListTile(
          value: esBase || seleccionadosExtra.contains(m.codigo),
          // Base: onChanged null (greyed-out, no se puede tocar).
          // No-base: si el dialog está busy, también null.
          onChanged: (esBase || onChanged == null)
              ? null
              : (v) => onChanged!(m.codigo, v ?? false),
          title: Row(
            children: [
              Expanded(child: Text(m.nombre)),
              if (esBase)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'incluido',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          subtitle: m.descripcion == null
              ? null
              : Text(
                  m.descripcion!,
                  style: const TextStyle(fontSize: 11),
                ),
          contentPadding: EdgeInsets.zero,
          dense: true,
          visualDensity: VisualDensity.compact,
          controlAffinity: ListTileControlAffinity.leading,
        );
      }).toList(),
    );
  }
}

/// Dialog que muestra email + password recién generadas (cuando el
/// super_admin pidió "no enviar email"). Mismo patrón de UX que
/// _PasswordCopiarDialog de forzar-password: copiar es la acción
/// primaria, cerrar pierde la password permanentemente. La password
/// la generó el server con crypto.getRandomValues y NO queda guardada
/// en ningún lado — esta es la única oportunidad de verla. Si la
/// pierde, el super_admin va al detalle del miembro → "Forzar
/// contraseña" para generar una nueva.
///
/// Devuelve true vía Navigator.pop si el user copió la password
/// (caller usa eso para decidir si navegar al detalle del tenant nuevo).
class _AdminCredencialesDialog extends StatefulWidget {
  const _AdminCredencialesDialog({
    required this.email,
    required this.password,
  });

  final String email;
  final String password;

  @override
  State<_AdminCredencialesDialog> createState() =>
      _AdminCredencialesDialogState();
}

class _AdminCredencialesDialogState extends State<_AdminCredencialesDialog> {
  bool _copiadoPassword = false;
  bool _copiadoEmail = false;
  String? _copyError;

  Future<void> _copiarPassword() async {
    // En web con clipboard bloqueado (iframe, permiso denegado, etc.)
    // Clipboard.setData lanza PlatformException — antes lo tragábamos
    // y el botón decía "Copiado" mientras el portapapeles estaba
    // vacío. Capturamos y mostramos el error para que el super_admin
    // pueda copiar manualmente del SelectableText.
    try {
      await Clipboard.setData(ClipboardData(text: widget.password));
      if (!mounted) return;
      setState(() {
        _copiadoPassword = true;
        _copyError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _copyError = 'No pude copiar al portapapeles: '
            'seleccioná la contraseña y copiala a mano (Ctrl+C).';
      });
    }
  }

  Future<void> _copiarEmail() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.email));
      if (!mounted) return;
      setState(() => _copiadoEmail = true);
    } catch (_) {
      // El email no es secreto — si falla, no rompemos UX. Si la
      // password también falló, ya hay un banner avisando.
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 480.0;
    return AlertDialog(
      icon: Icon(Icons.check_circle, color: scheme.primary, size: 40),
      title: const Text('Credenciales del admin'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'El ISP ya está creado y el admin puede loguearse ya '
              'mismo con estas credenciales. Pasalas por canal '
              'seguro — si las compartiste por uno inseguro, podés '
              'rotarle la contraseña en cualquier momento desde el '
              'detalle del ISP.',
            ),
            const SizedBox(height: 16),
            // Email primero — username, recuperable de la conversación
            // original si se pierde. La contraseña va abajo, junto al
            // warning específico que la cubre.
            Text(
              'Email',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            _CredencialRow(
              valor: widget.email,
              copiado: _copiadoEmail,
              onCopiar: _copiarEmail,
              semanticLabel: 'Copiar email',
            ),
            const SizedBox(height: 12),
            // Warning específico para la contraseña: la posicionamos
            // INMEDIATAMENTE arriba del bloque de la contraseña, no
            // como header del dialog — sino se lee primero, se
            // olvida, y se vuelve a la copia sin contexto.
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined,
                      color: scheme.onErrorContainer, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'La contraseña sólo se muestra una vez. Si la '
                      'perdés, abrí el ISP y usá "Forzar contraseña" '
                      'en la fila del admin para generar otra. '
                      'Si vas a probar el login en este browser, '
                      'hacelo en una ventana de incógnito — sino vas '
                      'a cerrar tu sesión de Super Admin.',
                      style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Contraseña',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            _CredencialRow(
              valor: widget.password,
              copiado: _copiadoPassword,
              onCopiar: _copiarPassword,
              semanticLabel: 'Copiar contraseña',
            ),
            if (_copyError != null) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  _copyError!,
                  style: TextStyle(
                    color: scheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      // Una vez copiada la contraseña, el flow está completo: el
      // FilledButton primario pasa a ser "Listo" (acción de salir),
      // y el copy duplicado pasa a TextButton secundario (acción de
      // re-copiar). Antes había 2 botones compitiendo por la atención
      // del super_admin tras copiar, con el FilledButton mintiendo:
      // "Contraseña copiada" sin acción primaria asociada.
      actions: _copiadoPassword
          ? [
              TextButton.icon(
                icon: const Icon(Icons.content_copy, size: 18),
                label: const Text('Copiar otra vez'),
                onPressed: _copiarPassword,
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Listo'),
              ),
            ]
          : [
              TextButton(
                // pop(false) — no navegamos al detalle si no copió.
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cerrar sin copiar'),
              ),
              Semantics(
                button: true,
                hint: 'Copia la contraseña al portapapeles',
                child: FilledButton.icon(
                  icon: const Icon(Icons.content_copy),
                  label: const Text('Copiar contraseña'),
                  onPressed: _copiarPassword,
                ),
              ),
            ],
    );
  }
}

/// Bloque "monospace + botón copiar" para mostrar una credencial
/// individual. Usado por _AdminCredencialesDialog para email y
/// contraseña — mismo styling, distinto contenido. El semanticLabel
/// distingue ambos roles para screen readers (sino TalkBack lee
/// "Copiar" suelto sin contexto).
class _CredencialRow extends StatelessWidget {
  const _CredencialRow({
    required this.valor,
    required this.copiado,
    required this.onCopiar,
    required this.semanticLabel,
  });

  final String valor;
  final bool copiado;
  final VoidCallback onCopiar;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      // Top alignment: para emails largos (50+ chars) que wrappean en
      // 2 líneas, el ícono queda anclado al inicio en vez de
      // centrado a la mitad del bloque.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              valor,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: copiado ? 'Copiado' : semanticLabel,
            icon: Icon(
              copiado ? Icons.check : Icons.content_copy,
              size: 18,
            ),
            onPressed: onCopiar,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
