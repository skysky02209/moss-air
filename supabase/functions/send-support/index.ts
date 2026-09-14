// MOSS AIR — 사용자 문의 → 개발자 이메일 + DB 저장 (Supabase Edge Function, Deno)
// 배포: supabase functions deploy send-support
// 필요한 Secret(브라우저에 절대 넣지 않음, 서버 환경변수):
//   supabase secrets set SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... RESEND_API_KEY=... DEVELOPER_EMAIL=...
// 프론트(사용자 웹)는 이 함수 URL만 호출합니다(비밀키 미노출).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405, headers: cors });
  try {
    const b = await req.json();
    const type = String(b.type ?? "기타").slice(0, 40);
    const title = String(b.title ?? "").slice(0, 200);
    const content = String(b.content ?? "").slice(0, 5000);
    if (!title || !content) return json({ error: "title/content required" }, 400);

    // 인증 사용자 식별(선택): Authorization 헤더의 JWT로 user 조회
    const url = Deno.env.get("SUPABASE_URL")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const admin = createClient(url, service);
    let userId: string | null = null, userEmail: string | null = b.userEmail ?? null;
    const auth = req.headers.get("authorization");
    if (auth?.startsWith("Bearer ")) {
      const { data } = await admin.auth.getUser(auth.slice(7));
      if (data?.user) { userId = data.user.id; userEmail = data.user.email ?? userEmail; }
    }

    // 1) DB 저장 (민감정보 저장 금지: 비밀번호/토큰은 받지도 않음)
    const { data: row, error } = await admin.from("support_requests")
      .insert({ user_id: userId, device_id: b.deviceRowId ?? null, type, title, content, status: "접수" })
      .select("id, created_at").single();
    if (error) throw error;

    // 2) 개발자 이메일 발송 (Resend 예시; 다른 서비스로 교체 가능)
    const key = Deno.env.get("RESEND_API_KEY");
    const to = Deno.env.get("DEVELOPER_EMAIL");
    let emailed = false;
    if (key && to) {
      const subject = `[MOSS AIR 문의][${type}] ${title}`;
      const html = `<h3>${escapeHtml(title)}</h3><p><b>유형</b>: ${escapeHtml(type)}</p>`
        + `<p style="white-space:pre-wrap">${escapeHtml(content)}</p><hr>`
        + `<p>사용자: ${escapeHtml(userEmail ?? "(비로그인)")} (${userId ?? "-"})<br>`
        + `제품: ${escapeHtml(b.productName ?? "-")} / ${escapeHtml(b.deviceId ?? "-")}<br>`
        + `웹 버전: ${escapeHtml(b.appVersion ?? "-")} · 연결: ${escapeHtml(b.connection ?? "-")}<br>`
        + `접수: ${row.created_at}</p>`;
      const r = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { "Authorization": `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from: "MOSS AIR <onboarding@resend.dev>", to: [to], subject, html }),
      });
      emailed = r.ok;
    }
    return json({ ok: true, id: row.id, emailed });
  } catch (e) {
    return json({ error: String(e?.message ?? e) }, 500);
  }
});

function json(o: unknown, status = 200) {
  return new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
}
function escapeHtml(s: string) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}
