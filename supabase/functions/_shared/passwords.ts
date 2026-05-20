/// Genera una password aleatoria de 16 chars usando crypto.getRandomValues.
///
/// Alphabet alineado con _ForzarPasswordDialog del cliente: excluye chars
/// ambiguos para dictar (I/l/1, O/0) y limita los símbolos a los que no se
/// confunden con markdown / espacios. Cualquier cambio acá tiene que
/// reflejarse en lib/features/super_admin/tenant_modulos_screen.dart
/// para que las passwords generadas server-side coincidan en formato con
/// las que el super_admin tipea a mano.
///
/// Usado por las edge functions crear-tenant y reenviar-invitacion en
/// modo no-email. Si surge una tercera, importar de acá en vez de copiar.
export function generarPasswordSegura(): string {
  const chars =
    "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#%*-+";
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  let out = "";
  for (let i = 0; i < 16; i++) {
    // Sesgo del módulo: 256 mod 63 = 4, así que 4 buckets reciben 5
    // muestras vs 4 — pérdida total ~0.4 bits sobre 16 chars
    // (95.27 vs 95.64 bits). Irrelevante para una password rotable
    // on-demand; si el modelo de amenaza cambia, switchear a rejection
    // sampling.
    out += chars[bytes[i] % chars.length];
  }
  return out;
}
