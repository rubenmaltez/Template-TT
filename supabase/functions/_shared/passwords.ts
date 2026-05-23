/// Genera una password aleatoria de 16 chars usando crypto.getRandomValues.
/// Sincronizar el alphabet con _ForzarPasswordDialog del cliente Flutter.
export function generarPasswordSegura(): string {
  const chars =
    "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#%*-+";
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  let out = "";
  for (let i = 0; i < 16; i++) {
    out += chars[bytes[i] % chars.length];
  }
  return out;
}
