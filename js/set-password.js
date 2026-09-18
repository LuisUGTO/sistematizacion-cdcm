import { supabase } from "./supabase-client.js";

const form = document.getElementById("passwordForm");
const button = document.getElementById("savePassword");

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const password = document.getElementById("password").value;
  const confirmation = document.getElementById("confirmPassword").value;
  if (password !== confirmation) return Swal.fire("No coinciden", "Escribe la misma contraseña en ambos campos.", "warning");
  if (password.length < 10) return Swal.fire("Contraseña corta", "Utiliza al menos 10 caracteres.", "warning");
  button.disabled = true;
  button.textContent = "Guardando…";
  const { data: sessionData } = await supabase.auth.getSession();
  if (!sessionData.session) {
    button.disabled = false; button.textContent = "Guardar y continuar";
    return Swal.fire("Invitación no válida", "Abre nuevamente el enlace recibido por correo o solicita otra invitación.", "error");
  }
  const { error } = await supabase.auth.updateUser({ password });
  if (error) {
    button.disabled = false; button.textContent = "Guardar y continuar";
    return Swal.fire("No se pudo guardar", error.message, "error");
  }
  await Swal.fire("Acceso activado", "Tu contraseña quedó establecida.", "success");
  window.location.replace("index.html");
});
