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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Método não permitido." }, 405);

  const { data: ctx, error: contextError } = await createSupabaseContext(req, { auth: "none" });
  if (contextError || !ctx?.supabaseAdmin) {
    return json({ error: "Serviço temporariamente indisponível." }, 503);
  }

  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.replace(/^Bearer\\s+/i, "");
  if (!token) return json({ error: "Inicia sessão para guardar o telefone de recuperação." }, 401);

  try {
    const admin = ctx.supabaseAdmin;
    const { data: authData, error: authError } = await admin.auth.getUser(token);
    if (authError || !authData?.user) {
      return json({ error: "A sessão expirou. Inicia sessão novamente." }, 401);
    }
    const user = authData.user;
    const userId = user.id;
    const body = await req.json();
    const action = body?.action || "get";

    if (action === "get") {
      const { data, error } = await admin
        .from("player_recovery_contacts")
        .select("phone_e164")
        .eq("user_id", userId)
        .maybeSingle();
      if (error) throw error;
      return json({ phone: data?.phone_e164 || "" });
    }

    if (action !== "set") return json({ error: "Acção inválida." }, 400);

    const phone = String(body?.phone || "").trim();
    if (!/^\+[1-9]\d{7,14}$/.test(phone)) {
      return json({ error: "Introduz o telefone no formato internacional, por exemplo +258841234567." }, 400);
    }

    if (!user.email) {
      return json({ error: "Primeiro associa um endereço de e-mail à conta." }, 400);
    }

    const { error } = await admin
      .from("player_recovery_contacts")
      .upsert(
        { user_id: userId, phone_e164: phone, updated_at: new Date().toISOString() },
        { onConflict: "user_id" },
      );

    if (error?.code === "23505") {
      return json({ error: "Este número já está associado a outra conta." }, 409);
    }
    if (error) throw error;

    return json({ ok: true, phone });
  } catch (error) {
    console.error("recovery-contact failed:", error instanceof Error ? error.message : "unknown error");
    return json({ error: "Não foi possível guardar o telefone de recuperação." }, 500);
  }
});
