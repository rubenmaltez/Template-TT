import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/models/tenant_admin.dart';
import '../../data/repositories/super_admin_repo.dart';
import '../../data/utils/edge_functions.dart';
import '../../data/utils/validators.dart';

/// Dialog para que el super_admin invite el primer/otro admin de un tenant.
/// Llama a la Edge Function `invitar-cobrador` con tenant_id explícito.
class InvitarAdminDialog extends ConsumerStatefulWidget {
  const InvitarAdminDialog({super.key, required this.tenant});
  final TenantAdmin tenant;

  @override
  ConsumerState<InvitarAdminDialog> createState() =>
      _InvitarAdminDialogState();
}

class _InvitarAdminDialogState extends ConsumerState<InvitarAdminDialog> {
  final _email = TextEditingController();
  final _nombre = TextEditingController();
  final _telefono = TextEditingController();
  bool _enviando = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _nombre.dispose();
    _telefono.dispose();
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
          'rol': 'admin',
          'tenant_id': widget.tenant.id,
          if (_telefono.text.trim().isNotEmpty)
            'telefono': _telefono.text.trim(),
          // ?flow=invite: para que cuando el invitado clickee el link
          // del email, el app lo route a /set-password en vez del
          // dashboard sin password. Ver _extractAuthFlow en main.dart.
          if (kIsWeb) 'redirect_to': '${Uri.base.origin}/?flow=invite',
        },
      );
      // Refrescar lista de tenants (cobradores_count) y lista de miembros
      // para que aparezca el nuevo invitado con estado "pendiente".
      ref.invalidate(tenantsAdminProvider);
      ref.invalidate(cobradoresTenantProvider(widget.tenant.id));
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Invitación enviada a $email'),
        duration: const Duration(seconds: 3),
      ));
    } catch (e) {
      // Helper invokeEdgeFunction lanza Exception(msg); pelamos el
      // prefijo "Exception: " — alineado con los hermanos de este
      // archivo y la convención del codebase.
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _enviando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('Invitar admin a ${widget.tenant.nombre}'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'El invitado recibirá un email para crear su contraseña. '
              'Una vez logueado, será admin de este tenant.',
              style: TextStyle(color: scheme.outline, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Email',
                hintText: 'admin@empresa.com',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nombre,
              decoration: const InputDecoration(
                labelText: 'Nombre completo',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _telefono,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Teléfono (opcional)',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_error!,
                    style: TextStyle(color: scheme.onErrorContainer)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _enviando ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          icon: _enviando
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send),
          label: const Text('Enviar invitación'),
          onPressed: _enviando ? null : _invitar,
        ),
      ],
    );
  }
}
