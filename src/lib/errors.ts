export function friendlyError(error: unknown): string {
  if (import.meta.env.DEV) console.error("[MisGastos]", error);
  const value = error as { code?: string; status?: number; name?: string };
  if (
    value?.status === 401 ||
    [
      "28000",
      "PGRST301",
      "PGRST303",
      "refresh_token_not_found",
      "session_not_found",
    ].includes(value?.code || "")
  ) {
    window.dispatchEvent(new Event("misgastos:session-expired"));
    return "Tu sesión ha caducado. Vuelve a iniciar sesión.";
  }
  switch (value?.code) {
    case "invalid_credentials":
      return "El email o la contraseña no son correctos.";
    case "email_not_confirmed":
      return "Confirma tu email antes de iniciar sesión.";
    case "user_already_exists":
      return "No se pudo crear la cuenta. Prueba a iniciar sesión o recuperar la contraseña.";
    case "weak_password":
      return "La contraseña no cumple los requisitos de seguridad. Usa una más larga y variada.";
    case "same_password":
      return "Elige una contraseña diferente a la anterior.";
    case "over_email_send_rate_limit":
    case "over_request_rate_limit":
      return "Demasiados intentos. Espera unos minutos y vuelve a probar.";
    case "22023":
      return "Revisa los datos, las fechas y la zona horaria. El período debe incluir el día de hoy.";
    case "22003":
      return "El importe es demasiado grande. Usa como máximo 18 cifras enteras y dos decimales.";
    case "40001":
      return "Los datos han cambiado. Revisa la versión actual antes de volver a guardar.";
    case "23505":
      return "Ya existe un elemento activo con ese nombre. Elige otro.";
    case "P0002":
      return "No se ha encontrado la configuración necesaria. Recarga para continuar.";
    default:
      return "No se pudo completar la operación. Comprueba tu conexión y vuelve a intentarlo.";
  }
}

export function movementError(error: unknown): string {
  const value = error as { code?: string; message?: string };
  // Traducciones controladas: nunca devolver el mensaje técnico al usuario.
  if (value?.code === "22023" || value?.code === "P0002") {
    if (import.meta.env.DEV) console.error("[MisGastos]", error);
    const message = value.message || "";
    if (/período/i.test(message))
      return "La fecha debe pertenecer al período abierto. Los movimientos de períodos cerrados no se pueden editar ni borrar.";
    if (/insuficiente|negativo/i.test(message))
      return "El cambio dejaría un saldo insuficiente en alguna fecha afectada. Revisa el importe y los movimientos posteriores.";
    if (/Categoría/i.test(message))
      return "La categoría ya no está disponible. Actualiza y selecciona una categoría activa.";
    if (/Método/i.test(message))
      return "El método de pago ya no está disponible. Actualiza y elige otro o deja el campo vacío.";
    if (/Cuenta/i.test(message))
      return "Revisa las cuentas de ahorro: deben estar disponibles y existir en la fecha elegida.";
    if (/Movimiento no encontrado/i.test(message))
      return "Este movimiento ya no existe. Actualiza la lista.";
    return "Revisa el importe, la fecha y el origen y destino del movimiento.";
  }
  return friendlyError(error);
}

export function isStaleData(error: unknown) {
  return ["40001", "P0002"].includes((error as { code?: string })?.code || "");
}
