import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum _Modo { login, signup, recuperar }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _nombre = TextEditingController();
  final _empresaNombre = TextEditingController();
  _Modo _modo = _Modo.login;
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    _nombre.dispose();
    _empresaNombre.dispose();
    super.dispose();
  }

  Future<void> _ejecutar() async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      final email = _email.text.trim();
      switch (_modo) {
        case _Modo.login:
          await Supabase.instance.client.auth.signInWithPassword(
            email: email,
            password: _pass.text,
          );
          break;
        case _Modo.signup:
          if (_nombre.text.trim().isEmpty ||
              _empresaNombre.text.trim().isEmpty) {
            throw 'Nombre y empresa son requeridos';
          }
          // El trigger handle_new_user creará el tenant + cobrador admin
          // usando este metadata.
          await Supabase.instance.client.auth.signUp(
            email: email,
            password: _pass.text,
            data: {
              'rol': 'admin',
              'nombre': _nombre.text.trim(),
              'empresa_nombre': _empresaNombre.text.trim(),
            },
          );
          setState(() => _info =
              'Revisá tu email para confirmar la cuenta (si el proyecto exige confirmación).');
          break;
        case _Modo.recuperar:
          await Supabase.instance.client.auth.resetPasswordForEmail(email);
          setState(() => _info =
              'Te mandamos un email con el link para recuperar tu contraseña.');
          break;
      }
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wifi_tethering,
                    size: 64, color: scheme.primary),
                const SizedBox(height: 8),
                Text(
                  'Cobranza ISP',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  switch (_modo) {
                    _Modo.login => 'Iniciar sesión',
                    _Modo.signup => 'Crear cuenta (primer admin)',
                    _Modo.recuperar => 'Recuperar contraseña',
                  },
                  style: TextStyle(color: scheme.outline),
                ),
                const SizedBox(height: 32),

                if (_modo == _Modo.signup) ...[
                  TextField(
                    controller: _nombre,
                    autofillHints: const [AutofillHints.name],
                    decoration: const InputDecoration(
                      labelText: 'Tu nombre *',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _empresaNombre,
                    decoration: const InputDecoration(
                      labelText: 'Nombre de tu empresa *',
                      border: OutlineInputBorder(),
                      helperText: 'Crearemos tu tenant con este nombre',
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_modo != _Modo.recuperar) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pass,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(
                      labelText: 'Contraseña',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],

                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: TextStyle(color: scheme.error),
                    textAlign: TextAlign.center,
                  ),
                ],
                if (_info != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(_info!, textAlign: TextAlign.center),
                  ),
                ],

                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _ejecutar,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(switch (_modo) {
                          _Modo.login => 'Iniciar sesión',
                          _Modo.signup => 'Crear cuenta',
                          _Modo.recuperar => 'Enviar link',
                        }),
                ),

                const SizedBox(height: 12),
                if (_modo == _Modo.login) ...[
                  TextButton(
                    onPressed: () => setState(() {
                      _modo = _Modo.recuperar;
                      _error = null;
                      _info = null;
                    }),
                    child: const Text('Olvidé mi contraseña'),
                  ),
                  const Divider(),
                  TextButton(
                    onPressed: () => setState(() {
                      _modo = _Modo.signup;
                      _error = null;
                      _info = null;
                    }),
                    child: const Text('Crear cuenta nueva'),
                  ),
                ] else
                  TextButton(
                    onPressed: () => setState(() {
                      _modo = _Modo.login;
                      _error = null;
                      _info = null;
                    }),
                    child: const Text('Volver a iniciar sesión'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
