import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: corsHeaders });
const usernamePattern = /^[a-z0-9][a-z0-9._-]{2,29}$/;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json(500, { error: "ระบบยังตั้งค่าไม่สมบูรณ์ กรุณาติดต่อผู้ดูแลระบบ" });
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json(401, { error: "กรุณาเข้าสู่ระบบด้วยบัญชีแอดมิน 11450" });

  let body: any;
  try { body = await req.json(); } catch { return json(400, { error: "ข้อมูลที่ส่งมาไม่ถูกต้อง" }); }
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  const actor = authData?.user;
  if (authError || !actor) return json(401, { error: "เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่" });

  const action = String(body.action || "");
  if (action === "self_update") {
    const username = String(body.username || "").trim().toLowerCase();
    const currentPassword = String(body.current_password || "");
    const newPassword = body.password == null ? "" : String(body.password);
    if (!usernamePattern.test(username)) return json(400, { error: "ชื่อผู้ใช้ต้องยาว 3–30 ตัว และใช้ a-z, 0-9, จุด, ขีดกลาง หรือขีดล่าง" });
    if (!currentPassword || currentPassword.length > 72) return json(400, { error: "กรุณากรอกรหัสผ่านปัจจุบันเพื่อยืนยันตัวตน" });
    if (newPassword && (newPassword.length < 8 || newPassword.length > 72)) return json(400, { error: "รหัสผ่านใหม่ต้องมี 8–72 ตัวอักษร" });

    const { data: ownProfile, error: ownProfileError } = await admin
      .from("profiles").select("user_id,username").eq("user_id", actor.id).maybeSingle();
    if (ownProfileError || !ownProfile) return json(404, { error: "ไม่พบข้อมูลบัญชีผู้ใช้งาน" });
    const oldUsername = String(ownProfile.username || (actor.email || "").replace(/@p4p\\.invalid$/i, "")).toLowerCase();
    const usernameChanged = username !== oldUsername;
    if (!usernameChanged && !newPassword) return json(400, { error: "กรุณาแก้ไขชื่อผู้ใช้หรือตั้งรหัสผ่านใหม่อย่างน้อยหนึ่งรายการ" });

    const { data: duplicate, error: duplicateError } = await admin
      .from("profiles").select("user_id").ilike("username", username).neq("user_id", actor.id).maybeSingle();
    if (duplicateError) return json(500, { error: "ตรวจสอบชื่อผู้ใช้ซ้ำไม่สำเร็จ" });
    if (duplicate) return json(409, { error: "ชื่อผู้ใช้นี้ถูกใช้แล้ว กรุณาเลือกชื่ออื่น" });

    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!anonKey) return json(500, { error: "ระบบยืนยันรหัสผ่านยังไม่พร้อม กรุณาติดต่อผู้ดูแลระบบ" });
    const verifier = createClient(url, anonKey, { auth: { autoRefreshToken: false, persistSession: false } });
    const { error: verifyError } = await verifier.auth.signInWithPassword({
      email: String(actor.email || ""),
      password: currentPassword,
    });
    if (verifyError) return json(400, { error: "รหัสผ่านปัจจุบันไม่ถูกต้อง" });

    const { data: authTarget, error: authTargetError } = await admin.auth.admin.getUserById(actor.id);
    if (authTargetError || !authTarget?.user) return json(404, { error: "ไม่พบข้อมูลบัญชีเข้าสู่ระบบ" });
    const authPatch: Record<string, unknown> = {};
    if (usernameChanged) {
      authPatch.email = username + "@p4p.invalid";
      authPatch.email_confirm = true;
    }
    if (newPassword) authPatch.password = newPassword;

    if (usernameChanged) {
      const { error: profileUpdateError } = await admin.from("profiles")
        .update({ username }).eq("user_id", actor.id);
      if (profileUpdateError) {
        if (profileUpdateError.code === "23505") return json(409, { error: "ชื่อผู้ใช้นี้ถูกใช้แล้ว กรุณาเลือกชื่ออื่น" });
        return json(500, { error: "บันทึกชื่อผู้ใช้ไม่สำเร็จ" });
      }
    }
    const { error: authUpdateError } = await admin.auth.admin.updateUserById(actor.id, authPatch);
    if (authUpdateError) {
      if (usernameChanged) await admin.from("profiles").update({ username: oldUsername }).eq("user_id", actor.id);
      if (/already|registered|exists/i.test(authUpdateError.message || "")) return json(409, { error: "ชื่อผู้ใช้นี้ถูกใช้กับบัญชีอื่นแล้ว" });
      console.error("shift-exchange self account update failed", authUpdateError.message);
      return json(400, { error: "บันทึกบัญชีไม่สำเร็จ ระบบคืนค่าชื่อผู้ใช้เดิมแล้ว" });
    }
    return json(200, { success: true, username, password_changed: Boolean(newPassword) });
  }

  if (String(actor.email || "").toLowerCase() !== "11450@p4p.invalid") {
    return json(403, { error: "เมนูจัดการผู้ใช้สงวนสิทธิ์เฉพาะบัญชีแอดมิน 11450" });
  }
  const { data: actorProfile, error: actorProfileError } = await admin
    .from("profiles").select("role").eq("user_id", actor.id).maybeSingle();
  if (actorProfileError || actorProfile?.role !== "admin") {
    return json(403, { error: "บัญชีนี้ไม่มีสิทธิ์ผู้ดูแลระบบ" });
  }

  if (action === "list") {
    const [{ data: directory, error: directoryError }, { data: profiles, error: profilesError }] = await Promise.all([
      admin.from("staff_directory")
        .select("source_row,prefix,first_name,last_name,position,org_role,unit_name,nursing_group,active")
        .eq("active", true).order("first_name").order("last_name"),
      admin.from("profiles")
        .select("user_id,staff_directory_id,full_name,username,role")
        .not("staff_directory_id", "is", null),
    ]);
    if (directoryError || profilesError) {
      console.error("shift-exchange-admin-users list failed", directoryError?.message, profilesError?.message);
      return json(500, { error: "โหลดทะเบียนบุคลากรหรือบัญชีผู้ใช้ไม่สำเร็จ" });
    }
    const profileByStaff = new Map((profiles || []).map((p: any) => [p.staff_directory_id, p]));
    const rows = (directory || []).map((s: any) => {
      const p: any = profileByStaff.get(s.source_row);
      return {
        staff_directory_id: s.source_row,
        full_name: [s.prefix, s.first_name, s.last_name].filter(Boolean).join(" "),
        position: s.position,
        org_role: s.org_role,
        unit_name: s.unit_name,
        nursing_group: s.nursing_group,
        has_account: Boolean(p),
        user_id: p?.user_id ?? null,
        username: p?.username ?? null,
        display_name: p?.full_name ?? null,
        role: p?.role ?? null,
      };
    });
    return json(200, { success: true, users: rows });
  }

  if (action === "create") {
    const staffId = Number(body.staff_id);
    const username = String(body.username || "").trim().toLowerCase();
    const password = String(body.password || "");
    if (!Number.isInteger(staffId) || staffId < 1) return json(400, { error: "กรุณาเลือกบุคลากรจากทะเบียน" });
    if (!usernamePattern.test(username)) return json(400, { error: "ชื่อผู้ใช้ต้องยาว 3–30 ตัว และใช้ a-z, 0-9, จุด, ขีดกลาง หรือขีดล่าง" });
    if (password.length < 6 || password.length > 72) return json(400, { error: "รหัสผ่านต้องมี 6–72 ตัวอักษร" });

    const { data: staff, error: staffError } = await admin.from("staff_directory")
      .select("source_row,prefix,first_name,last_name,position,org_role,staff_group,staff_type,unit_name,extra_unit_names,nursing_group,extra_nursing_group_names,active")
      .eq("source_row", staffId).eq("active", true).maybeSingle();
    if (staffError) return json(500, { error: "ตรวจสอบทะเบียนบุคลากรไม่สำเร็จ" });
    if (!staff) return json(404, { error: "ไม่พบรายชื่อบุคลากรที่ยังปฏิบัติงาน" });

    const [{ data: linked, error: linkedError }, { data: duplicate, error: duplicateError }] = await Promise.all([
      admin.from("profiles").select("user_id").eq("staff_directory_id", staffId).maybeSingle(),
      admin.from("profiles").select("user_id").ilike("username", username).maybeSingle(),
    ]);
    if (linkedError || duplicateError) return json(500, { error: "ตรวจสอบบัญชีซ้ำไม่สำเร็จ" });
    if (linked) return json(409, { error: "บุคลากรรายนี้มีบัญชีผู้ใช้งานแล้ว" });
    if (duplicate) return json(409, { error: "ชื่อผู้ใช้นี้ถูกใช้แล้ว กรุณาเลือกชื่ออื่น" });

    const { data: unitRows, error: unitError } = await admin.from("units").select("id,name,parent_group").order("id");
    if (unitError) return json(500, { error: "โหลดข้อมูลหน่วยงานไม่สำเร็จ" });
    const units = unitRows || [];
    const aliases: Record<string, string> = {
      "งานการพยาบาลผู้ป่วยในพิเศษปาริฉัตร": "งานการพยาบาลผู้ป่วยในตึกปาริฉัตร",
      "งานการพยาบาลผู้ป่วยในพิเศษพวงชมพู": "งานการพยาบาลผู้ป่วยในตึกพวงชมพู",
      "งานการพยาบาลผู้ป่วยในสงฆ์อาพาธ": "งานการพยาบาลผู้ป่วยสงฆ์อาพาธ",
      "งานการพยาบาลทารกแรกเกิดระยะวิกฤตและทารกป่วย": "งานพยาบาลทารกแรกเกิดระยะวิกฤตและทารกป่วย",
      "งานการพยาบาลผู้ป่วยหนัก": "งานพยาบาลผู้ป่วยหนัก",
      "งานจ่ายกลาง": "หน่วยจ่ายกลาง",
      "งานการพยาบาลตรวจรักษาพิเศษ": "งานการพยาบาลเคมีบำบัด",
    };
    let unit: any = units.find((u: any) => u.name === staff.unit_name || u.name === aliases[staff.unit_name]);
    if (!unit) unit = units.find((u: any) => u.parent_group === staff.nursing_group);
    if (!unit) unit = units.find((u: any) => u.name === "กลุ่มการพยาบาล");
    if (!unit) return json(500, { error: "ไม่สามารถจับคู่หน่วยงานกับระบบได้ กรุณาติดต่อผู้ดูแล" });

    const { data: designations, error: designationError } = await admin.from("position_designations")
      .select("full_name,position").in("position", ["หัวหน้าพยาบาล", "รักษาการหัวหน้าพยาบาล"]);
    if (designationError) return json(500, { error: "ตรวจสอบตำแหน่งผู้บริหารไม่สำเร็จ" });
    const normalizeName = (value: string) => value.normalize("NFC").toLowerCase().replace(/\s+/g, "");
    const selectedName = [staff.prefix, staff.first_name, staff.last_name].filter(Boolean).join(" ");
    const isChief = (designations || []).some((d: any) => normalizeName(String(d.full_name || "")) === normalizeName(selectedName));
    const assignedRole = isChief ? "admin" : staff.org_role === "หัวหน้ากลุ่มงาน" ? "group_head" : staff.org_role === "หัวหน้างาน" ? "head" : "staff";

    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email: username + "@p4p.invalid", password, email_confirm: true,
      user_metadata: { prefix: staff.prefix, first_name: staff.first_name, last_name: staff.last_name, position: staff.position, unit_id: unit.id },
    });
    if (createError || !created.user) {
      const message = createError?.message || "";
      if (/already|registered|exists/i.test(message)) return json(409, { error: "ชื่อผู้ใช้นี้ถูกใช้แล้ว กรุณาเลือกชื่ออื่น" });
      console.error("shift-exchange-admin-users create auth failed", message);
      return json(400, { error: "สร้างบัญชีเข้าสู่ระบบไม่สำเร็จ กรุณาตรวจสอบข้อมูล" });
    }
    const userId = created.user.id;
    const profileWrite = await admin.from("profiles").update({
      username, staff_directory_id: staff.source_row,
      full_name: [staff.prefix, staff.first_name, staff.last_name].filter(Boolean).join(" "),
      prefix: staff.prefix, first_name: staff.first_name, last_name: staff.last_name,
      position: staff.position, unit_id: unit.id, role: assignedRole, org_role: staff.org_role,
      staff_group: staff.staff_group, staff_type: staff.staff_type, nursing_group: staff.nursing_group,
      extra_unit_names: staff.extra_unit_names, extra_nursing_group_names: staff.extra_nursing_group_names,
    }).eq("user_id", userId);
    if (profileWrite.error) {
      await admin.auth.admin.deleteUser(userId);
      if (profileWrite.error.code === "23505") return json(409, { error: "ชื่อผู้ใช้หรือบุคลากรรายนี้ถูกลงทะเบียนแล้ว" });
      console.error("shift-exchange-admin-users profile write failed", profileWrite.error.message);
      return json(500, { error: "บันทึกโปรไฟล์ไม่สำเร็จ ระบบยกเลิกการสร้างบัญชีแล้ว" });
    }

    const personName = [staff.prefix, staff.first_name, staff.last_name].filter(Boolean).join(" ").trim();
    const { data: existingPerson, error: personLookupError } = await admin.from("people")
      .select("id,user_id").eq("staff_directory_id", staff.source_row).maybeSingle();
    if (personLookupError || (existingPerson?.user_id && existingPerson.user_id !== userId)) {
      await admin.auth.admin.deleteUser(userId);
      return json(personLookupError ? 500 : 409, { error: "เชื่อมโยงทะเบียนบุคลากร P4P ไม่สำเร็จ กรุณาตรวจสอบบัญชีเดิม" });
    }
    let personWrite: any;
    if (existingPerson) {
      personWrite = await admin.from("people").update({ user_id: userId }).eq("id", existingPerson.id).is("user_id", null);
    } else {
      personWrite = await admin.from("people").insert({
        prefix: staff.prefix, first_name: staff.first_name, last_name: staff.last_name,
        name: personName, position: staff.position, unit_id: unit.id, active: true,
        staff_directory_id: staff.source_row, user_id: userId,
      });
    }
    if (personWrite.error) {
      await admin.auth.admin.deleteUser(userId);
      console.error("shift-exchange-admin-users people link failed", personWrite.error.message);
      return json(500, { error: "เชื่อมทะเบียนบุคลากร P4P ไม่สำเร็จ ระบบยกเลิกการสร้างบัญชีแล้ว" });
    }
    const extraNames = String(staff.extra_unit_names || "").split(/[;,，、]/).map((x: string) => x.trim()).filter(Boolean);
    let extraUnits = units.filter((u: any) => extraNames.includes(u.name) && u.id !== unit.id).map((u: any) => u.id);
    if (staff.org_role === "หัวหน้ากลุ่มงาน") {
      extraUnits = [...new Set([...extraUnits, ...units.filter((u: any) => u.parent_group === staff.nursing_group && u.id !== unit.id).map((u: any) => u.id)])];
    }
    if (extraUnits.length) {
      const extraWrite = await admin.from("profile_units").upsert(
        extraUnits.map((unit_id: number) => ({ user_id: userId, unit_id, approved: true })),
        { onConflict: "user_id,unit_id" },
      );
      if (extraWrite.error) {
        await admin.auth.admin.deleteUser(userId);
        console.error("shift-exchange-admin-users extra units failed", extraWrite.error.message);
        return json(500, { error: "กำหนดหน่วยงานเพิ่มเติมไม่สำเร็จ ระบบยกเลิกการสร้างบัญชีแล้ว" });
      }
    }
    return json(201, { success: true, staff_id: staffId, username });
  }

  if (action === "update") {
    const staffId = Number(body.staff_id);
    const username = String(body.username || "").trim().toLowerCase();
    const displayName = String(body.display_name || "").trim();
    const password = body.password == null ? "" : String(body.password);
    if (!Number.isInteger(staffId) || staffId < 1) return json(400, { error: "ไม่พบรหัสบุคลากรที่ต้องการแก้ไข" });
    if (!usernamePattern.test(username)) return json(400, { error: "ชื่อผู้ใช้ต้องยาว 3–30 ตัว และใช้ a-z, 0-9, จุด, ขีดกลาง หรือขีดล่าง" });
    if (!displayName || displayName.length > 150) return json(400, { error: "กรุณาระบุชื่อแสดงในระบบไม่เกิน 150 ตัวอักษร" });
    if (password && (password.length < 6 || password.length > 72)) return json(400, { error: "รหัสผ่านใหม่ต้องมี 6–72 ตัวอักษร" });

    const { data: target, error: targetError } = await admin.from("profiles")
      .select("user_id,username,full_name").eq("staff_directory_id", staffId).maybeSingle();
    if (targetError) return json(500, { error: "ค้นหาบัญชีผู้ใช้ไม่สำเร็จ" });
    if (!target) return json(404, { error: "บุคลากรรายนี้ยังไม่มีบัญชีผู้ใช้งาน" });
    const { data: duplicate, error: duplicateError } = await admin.from("profiles")
      .select("user_id").ilike("username", username).neq("user_id", target.user_id).maybeSingle();
    if (duplicateError) return json(500, { error: "ตรวจสอบชื่อผู้ใช้ซ้ำไม่สำเร็จ" });
    if (duplicate) return json(409, { error: "ชื่อผู้ใช้นี้ถูกใช้แล้ว กรุณาเลือกชื่ออื่น" });

    const { data: targetAuth, error: targetAuthError } = await admin.auth.admin.getUserById(target.user_id);
    if (targetAuthError || !targetAuth?.user) return json(404, { error: "ไม่พบข้อมูลบัญชีเข้าสู่ระบบ" });
    const oldUsername = String(target.username || (targetAuth.user.email || "").replace(/@p4p\.invalid$/i, ""));
    const oldDisplayName = String(target.full_name || "");
    const newEmail = username + "@p4p.invalid";
    const usernameChanged = username !== oldUsername.toLowerCase();
    const profileWrite = await admin.from("profiles").update({ username, full_name: displayName }).eq("user_id", target.user_id);
    if (profileWrite.error) {
      if (profileWrite.error.code === "23505") return json(409, { error: "ชื่อผู้ใช้นี้ถูกใช้แล้ว กรุณาเลือกชื่ออื่น" });
      return json(500, { error: "บันทึกข้อมูลผู้ใช้ไม่สำเร็จ" });
    }
    const authPatch: Record<string, unknown> = {};
    if ((targetAuth.user.email || "").toLowerCase() !== newEmail) {
      authPatch.email = newEmail;
      authPatch.email_confirm = true;
    }
    if (password) authPatch.password = password;
    if (Object.keys(authPatch).length) {
      const { error: authUpdateError } = await admin.auth.admin.updateUserById(target.user_id, authPatch);
      if (authUpdateError) {
        await admin.from("profiles").update({ username: oldUsername, full_name: oldDisplayName }).eq("user_id", target.user_id);
        if (/already|registered|exists/i.test(authUpdateError.message || "")) return json(409, { error: "ชื่อผู้ใช้นี้ถูกใช้กับบัญชีเข้าสู่ระบบอื่นแล้ว" });
        console.error("shift-exchange-admin-users update auth failed", authUpdateError.message);
        return json(400, { error: "เปลี่ยนชื่อผู้ใช้หรือรหัสผ่านไม่สำเร็จ ระบบคืนค่าข้อมูลเดิมแล้ว" });
      }
    }
    return json(200, { success: true, staff_id: staffId, username, password_changed: Boolean(password) });
  }

  return json(400, { error: "ไม่รู้จักคำสั่งที่ร้องขอ" });
});
