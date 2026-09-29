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
      return "Los datos han cambiado. Recarga la página para ver la versión actual.";
    case "P0002":
      return "No se ha encontrado la configuración necesaria. Recarga para continuar.";
    default:
      return "No se pudo completar la operación. Comprueba tu conexión y vuelve a intentarlo.";
  }
}
