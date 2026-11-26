import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });
const hashCode = async (code: string) => {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(code));
  return Array.from(new Uint8Array(digest)).map((v) => v.toString(16).padStart(2, "0")).join("");
};
const safeEqual = (a: string, b: string) => {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return result === 0;
};
const reply = async (replyToken: string, text: string, accessToken: string) => {
  await fetch("https://api.line.me/v2/bot/message/reply", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer " + accessToken },
    body: JSON.stringify({ replyToken, messages: [{ type: "text", text }] }),
  });
};

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });
  const channelSecret = Deno.env.get("LINE_CHANNEL_SECRET");
  const accessToken = Deno.env.get("LINE_CHANNEL_ACCESS_TOKEN") || "";
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!channelSecret || !url || !serviceKey) return json(500, { error: "LINE webhook is not configured" });

  const rawBody = await req.text();
  const signature = req.headers.get("x-line-signature") || "";
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(channelSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const signed = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody));
  const expected = btoa(String.fromCharCode(...new Uint8Array(signed)));
  if (!safeEqual(signature, expected)) return json(401, { error: "Invalid signature" });

  let payload: any;
  try { payload = JSON.parse(rawBody); } catch { return json(400, { error: "Invalid JSON" }); }
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });

  for (const event of (payload.events || [])) {
    const lineUserId = event?.source?.userId;
    if (!lineUserId) continue;

    if (event.type === "unfollow") {
      await admin.from("line_user_links").update({ is_active: false }).eq("line_user_id", lineUserId);
      continue;
    }

    if (event.type !== "message" || event.message?.type !== "text") continue;
    const text = String(event.message.text || "").trim();
    const match = text.match(/^(?:LINK|เชื่อม)\s+(\d{8})$/i);
    if (!match) continue;

    const codeHash = await hashCode(match[1]);
    const now = new Date().toISOString();
    const { data: pending, error: pendingError } = await admin.from("line_link_codes")
      .select("id,user_id,expires_at")
      .eq("code_hash", codeHash).is("consumed_at", null).gt("expires_at", now).maybeSingle();

    let responseText = "ไม่พบรหัสเชื่อมบัญชี หรือรหัสหมดอายุแล้ว กรุณากลับไปสร้างรหัสใหม่ในระบบแลกเวร";
    if (!pendingError && pending) {
      const { data: lineOwner } = await admin.from("line_user_links")
        .select("user_id").eq("line_user_id", lineUserId).eq("is_active", true).maybeSingle();
      const { data: accountLink } = await admin.from("line_user_links")
        .select("line_user_id,is_active").eq("user_id", pending.user_id).maybeSingle();

      if (lineOwner && lineOwner.user_id !== pending.user_id) {
        responseText = "LINE บัญชีนี้เชื่อมกับบัญชีระบบอื่นอยู่แล้ว กรุณาติดต่อผู้ดูแลระบบ";
      } else if (accountLink?.is_active && accountLink.line_user_id !== lineUserId) {
        responseText = "บัญชีระบบนี้เชื่อมกับ LINE บัญชีอื่นอยู่แล้ว กรุณายกเลิกการเชื่อมบัญชีเดิมก่อน";
      } else {
        const { error: saveError } = await admin.from("line_user_links").upsert({
          user_id: pending.user_id,
          line_user_id: lineUserId,
          is_active: true,
          linked_at: now,
          friend_verified_at: now,
          updated_at: now,
        }, { onConflict: "user_id" });
        if (!saveError) {
          await admin.from("line_link_codes").update({ consumed_at: now }).eq("id", pending.id);
          responseText = "เชื่อมบัญชีกับระบบแลกเวรสำเร็จแล้ว กลับไปยังหน้าเว็บ ระบบจะเปิดให้ใช้งานโดยอัตโนมัติ";
        } else {
          responseText = "ไม่สามารถเชื่อมบัญชีได้ กรุณาลองใหม่หรือติดต่อผู้ดูแลระบบ";
        }
      }
    }

    if (event.replyToken && accessToken) {
      try { await reply(event.replyToken, responseText, accessToken); } catch (error) {
        console.error("LINE reply failed", error);
      }
    }
  }

  return json(200, { success: true });
});