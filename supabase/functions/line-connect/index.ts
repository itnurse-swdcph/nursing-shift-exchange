import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: corsHeaders });
const hashCode = async (code: string) => {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(code));
  return Array.from(new Uint8Array(digest)).map((v) => v.toString(16).padStart(2, "0")).join("");
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json(500, { error: "ระบบเชื่อมต่อ LINE ยังตั้งค่าไม่สมบูรณ์" });

  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json(401, { error: "กรุณาเข้าสู่ระบบใหม่" });

  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  const actor = authData?.user;
  if (authError || !actor) return json(401, { error: "เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่" });

  let body: any;
  try { body = await req.json(); } catch { return json(400, { error: "ข้อมูลไม่ถูกต้อง" }); }
  const action = String(body.action || "");

  const { data: profile, error: profileError } = await admin
    .from("profiles").select("staff_directory_id").eq("user_id", actor.id).maybeSingle();
  if (profileError || !profile) return json(404, { error: "ไม่พบข้อมูลบัญชีผู้ใช้" });
  if (profile.staff_directory_id == null) return json(403, { error: "บัญชีผู้ดูแลระบบที่ไม่มีทะเบียนบุคลากรไม่ต้องเชื่อม LINE" });

  if (action === "status") {
    const { data, error } = await admin.from("line_user_links")
      .select("line_user_id, is_active, linked_at, friend_verified_at")
      .eq("user_id", actor.id).maybeSingle();
    if (error) return json(500, { error: "ตรวจสอบสถานะ LINE ไม่สำเร็จ" });
    return json(200, {
      linked: Boolean(data?.is_active),
      linked_at: data?.linked_at ?? null,
      friend_verified_at: data?.friend_verified_at ?? null,
    });
  }

  if (action === "unlink") {
    const { error } = await admin.from("line_user_links").delete().eq("user_id", actor.id);
    await admin.from("line_link_codes").delete().eq("user_id", actor.id);
    if (error) return json(500, { error: "ยกเลิกการเชื่อมบัญชี LINE ไม่สำเร็จ" });
    return json(200, { success: true, linked: false });
  }

  if (action === "create_code") {
    const { data: existing, error: existingError } = await admin.from("line_user_links")
      .select("is_active").eq("user_id", actor.id).maybeSingle();
    if (existingError) return json(500, { error: "ตรวจสอบบัญชี LINE ไม่สำเร็จ" });
    if (existing?.is_active) return json(200, { linked: true });

    const random = new Uint32Array(1);
    crypto.getRandomValues(random);
    const code = String(random[0] % 100000000).padStart(8, "0");
    const codeHash = await hashCode(code);
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();

    await admin.from("line_link_codes").delete().eq("user_id", actor.id);
    const { error } = await admin.from("line_link_codes").insert({
      user_id: actor.id, code_hash: codeHash, expires_at: expiresAt,
    });
    if (error) return json(500, { error: "สร้างรหัสเชื่อมต่อไม่สำเร็จ กรุณาลองใหม่" });
    return json(200, { linked: false, code, expires_at: expiresAt });
  }

  return json(400, { error: "ไม่รู้จักคำสั่งที่ร้องขอ" });
});