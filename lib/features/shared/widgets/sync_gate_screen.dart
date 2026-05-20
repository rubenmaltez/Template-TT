import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pantalla intermedia mostrada por el router mientras PowerSync confirma
/// un sync tras cambio de identidad (login después de signOut, o switch
/// de user en el mismo browser).
///
/// Cuando `syncReadyProvider` flippa a `true`, el redirect del router
/// vuelve a evaluarse y manda al user a su pantalla por rol.
///
/// Manejo de gate "colgado" (offline o sync que no avanza):
///   - 8s sin avance: mostramos "Verificá tu conexión" como texto
///     secundario.
///   - 25s sin avance: aparece botón "Volver al login" que cierra la
///     sesión y rompe el loop (sino el user queda atrapado para
///     siempre con un cache que no se puede actualizar).
class SyncGateScreen extends StatefulWidget {
  const SyncGateScreen({super.key});

  @override
  State<SyncGateScreen> createState() => _SyncGateScreenState();
}

class _SyncGateScreenState extends State<SyncGateScreen> {
  Timer? _slowHintTimer;
  Timer? _escapeHatchTimer;
  bool _showSlowHint = false;
  bool _showEscapeHatch = false;

  @override
  void initState() {
    super.initState();
    _slowHintTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _showSlowHint = true);
    });
    _escapeHatchTimer = Timer(const Duration(seconds: 25), () {
      if (mounted) setState(() => _showEscapeHatch = true);
    });
  }

  @override
  void dispose() {
    _slowHintTimer?.cancel();
    _escapeHatchTimer?.cancel();
    super.dispose();
  }

  Future<void> _volverAlLogin() async {
    await Supabase.instance.client.auth.signOut();
    // El listener de main.dart dispara onSignOut → el redirect del
    // router lleva a /login. No hace falta navegación manual.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Semantics(
          label: 'Sincronizando datos con el servidor',
          liveRegion: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 20),
              const Text(
                'Sincronizando datos…',
                style: TextStyle(fontSize: 16),
              ),
              if (_showSlowHint) ...[
                const SizedBox(height: 12),
                Text(
                  'Esto está tardando más de lo normal. '
                  'Verificá tu conexión.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (_showEscapeHatch) ...[
                const SizedBox(height: 20),
                TextButton(
                  onPressed: _volverAlLogin,
                  child: const Text('Volver al login'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
