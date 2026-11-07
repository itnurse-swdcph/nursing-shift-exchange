import { useEffect, useState } from 'react'
import { ArrowLeftRight, CalendarDays, ClipboardList, FileText, ShieldCheck, Users } from 'lucide-react'
import { isSupabaseConfigured, supabase } from './lib/supabase'

type SessionState = 'checking' | 'signed-in' | 'signed-out' | 'not-configured'

const navigation = [
  { label: 'ภาพรวม', icon: ClipboardList },
  { label: 'ขอเปลี่ยนเวร', icon: ArrowLeftRight },
  { label: 'รายการคำขอของฉัน', icon: FileText },
  { label: 'รายการที่มอบหมายให้ฉัน', icon: Users },
  { label: 'อนุมัติคำขอ', icon: ShieldCheck },
  { label: 'รายงานประจำเดือน', icon: CalendarDays },
]

export default function App() {
  const [sessionState, setSessionState] = useState<SessionState>(
    isSupabaseConfigured ? 'checking' : 'not-configured',
  )
  const [activePage, setActivePage] = useState('ภาพรวม')

  useEffect(() => {
    if (!supabase) return
    let alive = true
    supabase.auth.getSession().then(({ data, error }) => {
      if (!alive) return
      setSessionState(error ? 'signed-out' : data.session ? 'signed-in' : 'signed-out')
    })
    const { data } = supabase.auth.onAuthStateChange((_event, session) => {
      setSessionState(session ? 'signed-in' : 'signed-out')
    })
    return () => {
      alive = false
      data.subscription.unsubscribe()
    }
  }, [])

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <div className="brand-mark"><ArrowLeftRight size={22} /></div>
          <div>
            <strong>ระบบแลกเปลี่ยนเวร</strong>
            <span>กลุ่มการพยาบาล</span>
          </div>
        </div>
        <div className="nav-caption">เมนูหลัก</div>
        <nav>
          {navigation.map(({ label, icon: Icon }) => (
            <button
              className={activePage === label ? 'nav-item active' : 'nav-item'}
              key={label}
              onClick={() => setActivePage(label)}
              type="button"
            >
              <Icon size={18} strokeWidth={1.8} />
              <span>{label}</span>
            </button>
          ))}
        </nav>
        <div className="sidebar-footer">โรงพยาบาลสมเด็จพระยุพราชสว่างแดนดิน</div>
      </aside>

      <main className="main-area">
        <header className="topbar">
          <div>
            <div className="eyebrow">NURSING SERVICES</div>
            <h1>{activePage}</h1>
          </div>
          <div className="session-pill">
            <span className={sessionState === 'signed-in' ? 'status-dot online' : 'status-dot'} />
            {sessionState === 'checking' ? 'กำลังตรวจสอบบัญชี' :
              sessionState === 'signed-in' ? 'เข้าสู่ระบบแล้ว' :
              sessionState === 'not-configured' ? 'รอตั้งค่าเชื่อมต่อ' : 'ยังไม่ได้เข้าสู่ระบบ'}
          </div>
        </header>

        <section className="welcome-panel">
          <div className="welcome-copy">
            <span className="section-kicker">SHIFT EXCHANGE PORTAL</span>
            <h2>จัดการการเปลี่ยนเวร<br />อย่างเป็นระบบและตรวจสอบได้</h2>
            <p>บันทึกคำขอ ติดตามผู้รับเปลี่ยนเวร และดำเนินการอนุมัติตามลำดับของกลุ่มการพยาบาล</p>
          </div>
          <div className="welcome-icon"><CalendarDays size={54} strokeWidth={1.2} /></div>
        </section>

        {sessionState === 'not-configured' && (
          <div className="notice">
            <strong>เตรียมการเชื่อมต่อ Supabase</strong>
            <p>กำหนดค่า VITE_SUPABASE_URL และ VITE_SUPABASE_ANON_KEY ใน environment ก่อนเปิดใช้งานระบบ</p>
          </div>
        )}
        {sessionState === 'signed-out' && (
          <div className="notice">
            <strong>ยังไม่ได้เข้าสู่ระบบ</strong>
            <p>ส่วนการเข้าสู่ระบบจะเชื่อมกับบัญชีเดิมของ P4P หลังตรวจสอบรูปแบบ username และวิธีตรวจสอบโปรไฟล์เดิม เพื่อไม่สร้างบัญชีซ้ำหรือกระทบระบบเดิม</p>
          </div>
        )}
        {sessionState === 'signed-in' && (
          <div className="notice success">
            <strong>เชื่อมต่อบัญชีแล้ว</strong>
            <p>ขั้นตอนถัดไปจะโหลดข้อมูลบุคลากรจาก staff_directory และตรวจสอบสิทธิ์ตามหน่วยงาน</p>
          </div>
        )}

        <div className="section-heading">
          <div>
            <span className="section-kicker">WORKSPACE</span>
            <h3>เมนูการทำงาน</h3>
          </div>
          <span className="muted">ระบบต้นแบบ</span>
        </div>
        <div className="feature-grid">
          {navigation.slice(1).map(({ label, icon: Icon }, index) => (
            <button className="feature-card" key={label} onClick={() => setActivePage(label)} type="button">
              <div className="feature-icon"><Icon size={21} /></div>
              <strong>{label}</strong>
              <span>{['สร้างและส่งคำขอเปลี่ยนเวร', 'ติดตามสถานะคำขอที่ส่ง', 'ตอบรับคำขอที่ได้รับมอบหมาย', 'ตรวจสอบและอนุมัติตามสิทธิ์', 'สรุปข้อมูลและพิมพ์รายงาน'][index]}</span>
            </button>
          ))}
        </div>
        <footer className="page-footer">Nursing Shift Exchange · โรงพยาบาลสมเด็จพระยุพราชสว่างแดนดิน</footer>
      </main>
    </div>
  )
}
