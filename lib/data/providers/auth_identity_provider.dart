import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Identidad de auth observada por el sync gate (R7).
///
/// Trackea dos cosas:
///   - `userId`: el id del user logueado actualmente (null si signedOut).
///   - `changedAt`: timestamp del último cambio de identidad que requiere
///     re-sync (signOut, o signIn con un user distinto al previo).
///
/// El sync gate compara `changedAt` con `lastSyncedAt` de PowerSync — si
/// el sync confirmó datos POSTERIORES al cambio, asumimos que el cache
/// local está alineado con la identidad actual y dejamos pasar.
///
/// Persistencia cross-session (clave del feature):
///   El notifier acepta `lastKnownUserId` y `onPersist`. En startup el
///   container lee `last_known_user_id` de SharedPreferences y lo pasa
///   como estado inicial — sino el caso "user A cierra pestaña, user B
///   abre y se loguea" arrancaría con (null, null), caería en la rama
///   "restore inicial" y NO gatearía el cache de A, anulando el feature.
///
/// Reglas en `onSignIn(uid)`:
///   - Mismo `uid` que el actual → no-op (token refresh / restore exacto).
///   - State inicial vacío (null, null) — solo posible en fresh install
///     sin storage previo — → no gate.
///   - Cualquier otro caso (storage tenía otro user, hubo signOut previo,
///     user switch live) → setea `changedAt = now` y persiste el nuevo uid.
///
/// En `onSignOut` NO se limpia `last_known_user_id` del storage — lo
/// queremos preservar para detectar el switch en el próximo signIn aunque
/// cierre la pestaña entre medio.
///
/// Notar: este provider NO es `autoDispose` a propósito. El router lo
/// watchea a través de `syncReadyProvider` y la app entera depende de
/// que sobreviva el ciclo de Flutter.
class AuthIdentityState {
  const AuthIdentityState({this.userId, this.changedAt});

  final String? userId;
  final DateTime? changedAt;
}

class AuthIdentityNotifier extends StateNotifier<AuthIdentityState> {
  AuthIdentityNotifier({
    String? lastKnownUserId,
    void Function(String userId)? onPersist,
  })  : _onPersist = onPersist,
        super(AuthIdentityState(userId: lastKnownUserId, changedAt: null));

  final void Function(String userId)? _onPersist;

  void onSignIn(String userId) {
    // Mismo user que ya estaba (token refresh, evento duplicado, restore
    // exacto del lastKnownUserId del storage). No-op.
    if (state.userId == userId) return;

    // State inicial completamente vacío: solo posible si el storage estaba
    // vacío (fresh install) y nunca hubo signOut en este proceso. Es
    // restore legítimo de la primera sesión, no hay cache previo de otro
    // user que proteger.
    if (state.userId == null && state.changedAt == null) {
      state = AuthIdentityState(userId: userId, changedAt: null);
      _onPersist?.call(userId);
      return;
    }

    // Cualquier otro caso es un cambio real de identidad:
    //   - storage tenía a userX y ahora viene userY (cross-session switch).
    //   - hubo signOut + signIn en este proceso.
    //   - user switch live sin signOut intermedio (no debería pasar).
    // Gate hasta que PowerSync confirme sync post-cambio.
    state = AuthIdentityState(userId: userId, changedAt: DateTime.now());
    _onPersist?.call(userId);
  }

  void onSignOut() {
    // No tocamos el storage — `last_known_user_id` se mantiene apuntando
    // al user del cache local. Si la pestaña se cierra y otro user se
    // loguea después, el próximo `onSignIn` detectará el switch
    // comparando con el storage.
    state = AuthIdentityState(userId: null, changedAt: DateTime.now());
  }
}

final authIdentityProvider =
    StateNotifierProvider<AuthIdentityNotifier, AuthIdentityState>(
  (ref) => AuthIdentityNotifier(),
);
