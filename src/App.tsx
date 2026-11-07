import { useEffect, useState } from 'react'
import type { FormEvent } from 'react'
import { ArrowLeftRight, CalendarDays, ClipboardList, FileText, LogOut, ShieldCheck, Users } from 'lucide-react'
import { isSupabaseConfigured, supabase } from './lib/supabase'

type SessionState = 'checking' | 'signed-in' | 'signed-out' | 'not-configured'
type UserProfile = { full_name: string | null; role: string; staff_directory_id: number | null }

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
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [authError, setAuthError] = useState('')
  const [authBusy, setAuthBusy] = useState(false)
  const [profile, setProfile] = useState<UserProfile | null>(null)

  useEffect(() => {
    if (!supabase) return
    let alive = true
    supabase.auth.getSession().then(async ({ data, error }) => {
      if (!alive) return
      setSessionState(error ? 'signed-out' : data.session ? 'signed-in' : 'signed-out')
      if (data.session?.user) await loadProfile(data.session.user.id)
    })
    const { data } = supabase.auth.onAuthStateChange((_event, session) => {
      setSessionState(session ? 'signed-in' : 'signed-out')
      if (!session) setProfile(null)
    })
    return () => {
      alive = false
      data.subscription.unsubscribe()
    }
  }, [])

  async function loadProfile(userId: string) {
    if (!supabase) return
    const { data, error } = await supabase
      .from('profiles')
      .select('full_name, role, staff_directory_id')
      .eq('user_id', userId)
      .maybeSingle()
    if (error || !data) {
      setAuthError(error?.message ?? 'ไม่พบโปรไฟล์บัญชีผู้ใช้')
      return
    }
    setProfile(data as UserProfile)
    if (data.role !== 'admin' && data.staff_directory_id) {
      const { error: staffError } = await supabase.rpc('get_my_staff_directory')
      if (staffError) setAuthError(staffError.message)
    }
  }

  async function handleLogin(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!supabase) return
    setAuthBusy(true)
    setAuthError('')
    const normalizedUsername = username.trim().toLowerCase()
    const { data, error } = await supabase.auth.signInWithPassword({
      email: `${normalizedUsername}@p4p.invalid`,
      password,
    })
    if (error) {
      setAuthError('ชื่อผู้ใช้หรือรหัสผ่านไม่ถูกต้อง')
    } else if (data.user) {
      await loadProfile(data.user.id)
    }
    setAuthBusy(false)
  }

  async function handleLogout() {
    if (!supabase) return
    await supabase.auth.signOut()
    setProfile(null)
    setAuthError('')
  }

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
          <div className="topbar-actions">
            {profile && <span className="user-name">{profile.full_name ?? 'ผู้ใช้งาน'}</span>}
            {sessionState === 'signed-in' && <button className="logout-button" onClick={handleLogout} type="button"><LogOut size={15} /> ออกจากระบบ</button>}
            <div className="session-pill">
              <span className={sessionState === 'signed-in' ? 'status-dot online' : 'status-dot'} />
              {sessionState === 'checking' ? 'กำลังตรวจสอบบัญชี' :
                sessionState === 'signed-in' ? 'เข้าสู่ระบบแล้ว' :
                sessionState === 'not-configured' ? 'รอตั้งค่าเชื่อมต่อ' : 'ยังไม่ได้เข้าสู่ระบบ'}
            </div>
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
          <form className="login-panel" onSubmit={handleLogin}>
            <div>
              <span className="section-kicker">EXISTING STAFF ACCOUNT</span>
              <h3>เข้าสู่ระบบด้วยบัญชีเดิม</h3>
              <p>ใช้ชื่อผู้ใช้และรหัสผ่านชุดเดียวกับระบบ P4P ไม่ต้องสมัครสมาชิกใหม่</p>
            </div>
            <label>ชื่อผู้ใช้
              <input autoComplete="username" value={username} onChange={(event) => setUsername(event.target.value)} placeholder="กรอกชื่อผู้ใช้" required />
            </label>
            <label>รหัสผ่าน
              <input autoComplete="current-password" type="password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="กรอกรหัสผ่าน" required />
            </label>
            {authError && <p className="form-error">{authError}</p>}
            <button className="primary-button" disabled={authBusy} type="submit">{authBusy ? 'กำลังเข้าสู่ระบบ…' : 'เข้าสู่ระบบ'}</button>
            <small>ระบบใช้ Supabase Auth เดิมของโรงพยาบาล และจะไม่สร้างบัญชีใหม่</small>
          </form>
        )}
        {sessionState === 'signed-in' && (
          <div className="notice success">
            <strong>{profile?.role === 'admin' ? 'เข้าสู่ระบบผู้ดูแลแล้ว' : 'เชื่อมต่อบัญชีบุคลากรแล้ว'}</strong>
            <p>{profile?.role === 'admin' ? 'บัญชีผู้ดูแลระบบไม่ได้ผูกกับทะเบียนบุคลากร' : 'บัญชีนี้จะใช้ข้อมูลบุคลากรจาก staff_directory เพื่อกำหนดหน่วยงานและสิทธิ์การอนุมัติ'}</p>
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
