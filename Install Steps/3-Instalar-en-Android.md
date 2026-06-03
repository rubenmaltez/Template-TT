# 3 — Instalar / actualizar en Android

El APK se firma con **debug key** (no hay key de producción todavía). Update
**in-place**: instalar sobre la versión vieja mantiene los datos, siempre que el
`applicationId` y la firma no cambien (se buildea siempre desde la misma PC).

---

## Instalar

1. En el teléfono, descargá el APK:
   `https://github.com/rubenmaltez/Template-TT/releases/latest/download/SITECSA-CRM.apk`
   (o pasá el `SITECSA-CRM-vX.Y.Z.apk` del Escritorio / `Releases\vX.Y.Z\` por
   WhatsApp / USB).
2. Abrí el APK desde la barra de notificaciones o el explorador de archivos.
3. La primera vez, Android pide permitir **"Instalar apps desconocidas"** para
   el navegador/explorador con el que lo abrís → activalo → volvé atrás →
   **Instalar**.
4. Si ya tenías una versión, tocá **Actualizar** (no pide desinstalar).

---

## Verificar

Abrí la app → en el **login** (al pie) y en **Perfil** (cobrador, al pie) debe
decir `SITECSA CRM vX.Y.Z`.

## Si dice "app no instalada" / conflicto de firma

Pasa si el APK viene de una PC distinta a la que instaló la versión previa
(firma debug diferente). Solución: desinstalá la app vieja y reinstalá. La data
está en el backend, no se pierde (vuelve a sincronizar al loguearte).
