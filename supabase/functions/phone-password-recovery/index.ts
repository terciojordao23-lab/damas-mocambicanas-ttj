import { createSupabaseContext } from "npm:@supabase/server";

const APP_ORIGIN = "https://terciojordao23-lab.github.io";
const corsHeaders = {
  "Access-Control-Allow-Origin": APP_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizePhone(value: unknown) {
  const phone = String(value || "").trim();
  return /^\+[1-9]\d{7,14}$/.test(phone) ? phone : null;
}

async function hmacHex(secret: string, value: string) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
  return Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function twilioConfig() {
  const accountSid = Deno.env.get("TWILIO_ACCOUNT_SID") || "";
  const authToken = Deno.env.get("TWILIO_AUTH_TOKEN") || "";
  const serviceSid = Deno.env.get("TWILIO_VERIFY_SERVICE_SID") || "";
  if (!/^AC[0-9a-fA-F]{32}$/.test(accountSid) ||
      !/^VA[0-9a-fA-F]{32}$/.test(serviceSid) || !authToken) {
    throw new Error("Twilio secrets are incomplete or invalid.");
  }
  return { accountSid, authToken, serviceSid };
}

async function twilioRequest(path: string, values: Record<string, string>) {
  const { accountSid, authToken, serviceSid } = twilioConfig();
  const form = new URLSearchParams(values);
  const response = await fetch(
    "https://verify.twilio.com/v2/Services/" + serviceSid + "/" + path,
    {
      method: "POST",
      headers: {
        "Authorization": "Basic " + btoa(accountSid + ":" + authToken),
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form,
    },
  );
  const payload = await response.json().catch(() => ({}));
  return { response, payload };
}

async function findEligibleAccount(admin: any, phone: string) {
  const { data: contact, error } = await admin
    .from("player_recovery_contacts")
    .select("user_id")
    .eq("phone_e164", phone)
    .maybeSingle();
  if (error) throw error;
  if (!contact?.user_id) return null;

  const { data, error: userError } = await admin.auth.admin.getUserById(contact.user_id);
  if (userError || !data?.user) return null;
  const user = data.user;
  if (!user.email || !user.email_confirmed_at || user.is_anonymous) return null;
  return user;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Método não permitido." }, 405);

  const { data: ctx, error: contextError } = await createSupabaseContext(req, { auth: "none" });
  if (contextError || !ctx?.supabaseAdmin) {
    return json({ error: "Serviço temporariamente indisponível." }, 503);
  }

  try {
    const body = await req.json();
    const action = String(body?.action || "");
    const phone = normalizePhone(body?.phone);
    if (!phone) return json({ error: "Introduz o telefone no formato internacional (+258…)."}, 400);

    const admin = ctx.supabaseAdmin;
    const user = await findEligibleAccount(admin, phone);

    if (action === "request") {
      // Always return the same success response for unknown or ineligible numbers.
      if (!user) {
        return json({
          ok: true,
          message: "Se o número estiver associado a uma conta confirmada, receberás um código SMS.",
        });
      }

      const { authToken } = twilioConfig();
      const forwarded = req.headers.get("cf-connecting-ip") ||
        req.headers.get("x-forwarded-for")?.split(",")[0].trim() || "";
      const phoneHash = await hmacHex(authToken, "phone:" + phone);
      const checks = [
        admin.rpc("consume_phone_recovery_rate_limit", {
          p_key_type: "phone",
          p_key_hash: phoneHash,
          p_max_attempts: 3,
          p_window_seconds: 900,
        }),
      ];
      if (forwarded) {
        checks.push(admin.rpc("consume_phone_recovery_rate_limit", {
          p_key_type: "ip",
          p_key_hash: await hmacHex(authToken, "ip:" + forwarded),
          p_max_attempts: 10,
          p_window_seconds: 900,
        }));
      }
      const limits = await Promise.all(checks);
      if (limits.some((item: any) => item.error || item.data !== true)) {
        return json({
          ok: true,
          message: "Se o número estiver associado a uma conta confirmada, receberás um código SMS.",
        });
      }

      const { response } = await twilioRequest("Verifications", {
        To: phone,
        Channel: "sms",
      });
      if (!response.ok) {
        console.error("Twilio verification start failed with HTTP", response.status);
        return json({ error: "Não foi possível enviar o SMS agora. Tenta novamente mais tarde." }, 503);
      }
      return json({
        ok: true,
        message: "Se o número estiver associado a uma conta confirmada, receberás um código SMS.",
      });
    }

    if (action === "complete") {
      const code = String(body?.code || "").trim();
      const newPassword = String(body?.newPassword || "");
      if (!/^\d{4,10}$/.test(code)) return json({ error: "Introduz o código recebido por SMS." }, 400);
      if (newPassword.length < 8) {
        return json({ error: "A nova palavra-passe deve ter pelo menos 8 caracteres." }, 400);
      }
      if (!user) return json({ error: "Código inválido ou expirado." }, 400);

      const { response, payload } = await twilioRequest("VerificationCheck", {
        To: phone,
        Code: code,
      });
      if (!response.ok || payload?.status !== "approved") {
        return json({ error: "Código inválido ou expirado. Pede um novo código se necessário." }, 400);
      }

      const { error: passwordError } = await admin.auth.admin.updateUserById(user.id, {
        password: newPassword,
      });
      if (passwordError) {
        console.error("Password update failed after approved verification.");
        return json({ error: "O código foi confirmado, mas não foi possível actualizar a palavra-passe. Contacta o suporte." }, 500);
      }

      return json({ ok: true, message: "Palavra-passe actualizada. Já podes entrar com o teu e-mail e a nova palavra-passe." });
    }

    return json({ error: "Acção inválida." }, 400);
  } catch (error) {
    console.error("phone-password-recovery failed:", error instanceof Error ? error.message : "unknown error");
    return json({ error: "Não foi possível concluir a recuperação agora." }, 500);
  }
});
