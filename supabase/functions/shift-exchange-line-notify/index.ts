import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: corsHeaders });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const accessToken = Deno.env.get("LINE_CHANNEL_ACCESS_TOKEN");
  if (!url || !serviceKey || !accessToken) return json(503, { error: "LINE Messaging API ยังตั้งค่าไม่ครบ" });

  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json(401, { error: "กรุณาเข้าสู่ระบบ" });
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  const actor = authData?.user;
  if (authError || !actor) return json(401, { error: "เซสชันหมดอายุ" });

  let body: any;
  try { body = await req.json(); } catch { return json(400, { error: "ข้อมูลไม่ถูกต้อง" }); }
  const requestId = String(body.request_id || "");
  const action = String(body.action || "");
  if (!requestId || !["request_submitted", "workflow_updated"].includes(action)) return json(400, { error: "คำสั่งแจ้งเตือนไม่ถูกต้อง" });

  const { data: request, error: requestError } = await admin.from("shift_change_requests")
    .select("id,requester_user_id,requester_staff_directory_id,requester_name,requester_unit_name,recipient_user_id,recipient_staff_directory_id,recipient_name,request_type,shift_date,shift_period,status")
    .eq("id", requestId).maybeSingle();
  if (requestError || !request) return json(404, { error: "ไม่พบคำขอแลกเวร" });

  const { data: actorProfile } = await admin.from("profiles")
    .select("staff_directory_id").eq("user_id", actor.id).maybeSingle();
  const isCentralAdmin = String(actor.email || "").toLowerCase() === "11450@p4p.invalid";
  let isApprover = false;
  if (actorProfile?.staff_directory_id != null) {
    const { data: approval } = await admin.from("shift_change_approvals")
      .select("id").eq("request_id", requestId)
      .eq("approver_staff_directory_id", actorProfile.staff_directory_id).limit(1).maybeSingle();
    isApprover = Boolean(approval);
  }
  const isParticipant = actor.id === request.requester_user_id || actor.id === request.recipient_user_id;
  if (!isCentralAdmin && !isParticipant && !isApprover) return json(403, { error: "ไม่มีสิทธิ์ส่งการแจ้งเตือนสำหรับรายการนี้" });

  const targets: Array<{ userId: string; eventType: string; message: string }> = [];
  const dateText = String(request.shift_date || "");
  const shiftText = String(request.shift_period || "");
  const typeText = String(request.request_type || "");
  const summary = "วันที่ " + dateText + " เวร" + shiftText + " (" + typeText + ")";

  if (action === "request_submitted") {
    let recipientUserId = request.recipient_user_id as string | null;
    if (!recipientUserId) {
      const { data: recipientProfile } = await admin.from("profiles")
        .select("user_id").eq("staff_directory_id", request.recipient_staff_directory_id).maybeSingle();
      recipientUserId = recipientProfile?.user_id ?? null;
    }
    if (recipientUserId) {
      targets.push({
        userId: recipientUserId,
        eventType: "request_submitted",
        message: "มีคำขอแลกเวรใหม่จาก " + request.requester_name + " " + summary + " กรุณาเปิดระบบแลกเวรเพื่อตรวจสอบและตอบรับ",
      });
    }
  } else {
    if (["waiting_unit_head", "waiting_group_head", "waiting_nursing_head"].includes(String(request.status))) {
      const { data: pendingApprovals } = await admin.from("shift_change_approvals")
        .select("step_code,approver_user_id,approver_staff_directory_id,approver_name")
        .eq("request_id", requestId).eq("decision", "pending");
      for (const approval of pendingApprovals || []) {
        let approverUserId = approval.approver_user_id as string | null;
        if (!approverUserId) {
          const { data: approverProfile } = await admin.from("profiles")
            .select("user_id").eq("staff_directory_id", approval.approver_staff_directory_id).maybeSingle();
          approverUserId = approverProfile?.user_id ?? null;
        }
        if (approverUserId) {
          targets.push({
            userId: approverUserId,
            eventType: "approval_" + approval.step_code,
            message: "มีคำขอแลกเวรรออนุมัติจาก " + request.requester_name + " " + summary + " กรุณาเปิดระบบแลกเวรเพื่อตรวจสอบ",
          });
        }
      }
    } else if (request.status === "approved") {
      targets.push({
        userId: request.requester_user_id,
        eventType: "final_approved_requester",
        message: "คำขอแลกเวรของคุณได้รับอนุมัติครบทุกขั้นตอนแล้ว " + summary,
      });
      if (request.recipient_user_id) {
        targets.push({
          userId: request.recipient_user_id,
          eventType: "final_approved_recipient",
          message: "รายการแลกเวรกับ " + request.requester_name + " ได้รับอนุมัติครบทุกขั้นตอนแล้ว " + summary,
        });
      }
    } else if (request.status === "cancelled") {
      let recipientUserId = request.recipient_user_id as string | null;
      if (!recipientUserId) {
        const { data: recipientProfile } = await admin.from("profiles")
          .select("user_id").eq("staff_directory_id", request.recipient_staff_directory_id).maybeSingle();
        recipientUserId = recipientProfile?.user_id ?? null;
      }
      if (recipientUserId) targets.push({
        userId: recipientUserId,
        eventType: "request_cancelled",
        message: "คำขอแลกเวรจาก " + request.requester_name + " ถูกยกเลิกแล้ว " + summary,
      });
    } else if (request.status === "rejected") {
      targets.push({
        userId: request.requester_user_id,
        eventType: "request_rejected",
        message: "คำขอแลกเวรของคุณไม่ได้รับอนุมัติ " + summary,
      });
    }
  }

  let sent = 0;
  let skipped = 0;
  for (const target of targets) {
    const { data: lineLink } = await admin.from("line_user_links")
      .select("line_user_id").eq("user_id", target.userId).eq("is_active", true).maybeSingle();
    const eventKey = requestId + ":" + target.eventType + ":" + target.userId;
    const { data: previous } = await admin.from("line_notification_logs")
      .select("id,status").eq("event_key", eventKey).maybeSingle();
    if (previous?.status === "sent") { skipped++; continue; }

    if (!lineLink?.line_user_id) {
      if (previous?.id) {
        await admin.from("line_notification_logs").update({ status: "skipped", error_message: "ผู้รับยังไม่ได้เชื่อม LINE" }).eq("id", previous.id);
      } else {
        await admin.from("line_notification_logs").insert({
          event_key: eventKey, request_id: requestId, user_id: target.userId,
          event_type: target.eventType, status: "skipped", error_message: "ผู้รับยังไม่ได้เชื่อม LINE",
        });
      }
      skipped++;
      continue;
    }

    let logId = previous?.id;
    if (logId) {
      await admin.from("line_notification_logs").update({
        status: "pending", line_user_id: lineLink.line_user_id, error_message: null,
      }).eq("id", logId);
    } else {
      const { data: logRow, error: logError } = await admin.from("line_notification_logs").insert({
        event_key: eventKey, request_id: requestId, user_id: target.userId,
        line_user_id: lineLink.line_user_id, event_type: target.eventType, status: "pending",
      }).select("id").single();
      if (logError || !logRow) { skipped++; continue; }
      logId = logRow.id;
    }

    try {
      const lineResponse = await fetch("https://api.line.me/v2/bot/message/push", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: "Bearer " + accessToken },
        body: JSON.stringify({ to: lineLink.line_user_id, messages: [{ type: "text", text: target.message }] }),
      });
      const responseText = await lineResponse.text();
      if (!lineResponse.ok) {
        await admin.from("line_notification_logs").update({
          status: "failed", error_message: "LINE API " + lineResponse.status, response_body: { body: responseText },
        }).eq("id", logId);
      } else {
        await admin.from("line_notification_logs").update({
          status: "sent", sent_at: new Date().toISOString(), response_body: { body: responseText },
        }).eq("id", logId);
        sent++;
      }
    } catch (error) {
      await admin.from("line_notification_logs").update({
        status: "failed", error_message: String(error),
      }).eq("id", logId);
    }
  }

  return json(200, { success: true, sent, skipped, status: request.status });
});