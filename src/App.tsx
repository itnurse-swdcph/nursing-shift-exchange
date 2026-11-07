import { useEffect, useMemo, useState } from 'react'
import type { FormEvent } from 'react'
import {
  ArrowLeftRight, CalendarDays, CheckCircle2, ClipboardList, FileText,
  LogOut, RefreshCw, ShieldCheck, Users, XCircle, Menu, X,
} from 'lucide-react'
import { isSupabaseConfigured, supabase } from './lib/supabase'
import { MEMO_PREFIXES } from './data/memoPrefixes'

type SessionState = 'checking' | 'signed-in' | 'signed-out' | 'not-configured'
type UserProfile = { full_name: string | null; role: string; staff_directory_id: number | null }
type StaffOption = {
  staff_directory_id: number
  full_name: string
  position: string | null
  unit_name: string | null
  nursing_group: string | null
  org_role: string | null
  has_account: boolean
}
type Approval = {
  step_code: string
  approver_name: string
  approver_org_role: string | null
  decision: string
  comment: string | null
  acted_at?: string | null
  approver_staff_directory_id?: number | null
}
type ShiftRequest = {
  id: string
  requester_name: string
  requester_unit_name: string
  recipient_name: string
  request_type: string
  shift_date: string
  shift_period: string
  status: string
  requester_note: string | null
  recipient_decision?: string | null
  recipient_comment?: string | null
  recipient_staff_directory_id?: number | null
  recipient_acted_at?: string | null
  replacement_required: boolean
  replacement_date: string | null
  replacement_period: string | null
  approvals?: Approval[]
  document?: { document_number: string; document_date: string } | null
  approval?: Approval
}

const navigation = [
  { label: 'ภาพรวม', icon: ClipboardList },
  { label: 'ขอเปลี่ยนเวร', icon: ArrowLeftRight },
  { label: 'รายการคำขอของฉัน', icon: FileText },
  { label: 'รายการที่มอบหมายให้ฉัน', icon: Users },
  { label: 'อนุมัติคำขอ', icon: ShieldCheck },
  { label: 'รายงานประจำเดือน', icon: CalendarDays },
]

const statusLabels: Record<string, string> = {
  waiting_recipient: 'รอผู้รับตอบรับ',
  waiting_unit_head: 'รอหัวหน้างานอนุมัติ',
  waiting_group_head: 'รอหัวหน้ากลุ่มงานอนุมัติ',
  waiting_nursing_head: 'รอหัวหน้าพยาบาลอนุมัติ',
  approved: 'อนุมัติแล้ว',
  rejected: 'ไม่อนุมัติ',
  cancelled: 'ยกเลิกแล้ว',
}
const periodLabels: Record<string, string> = { morning: 'เช้า', afternoon: 'บ่าย', night: 'ดึก' }
const typeLabels: Record<string, string> = { unit: 'เวรหน่วยงาน', refer: 'เวร Refer', supervision: 'เวรตรวจการ' }

function toThaiDigits(value: string | number | null | undefined) {
  return String(value ?? '').replace(/[0-9]/g, digit => '๐๑๒๓๔๕๖๗๘๙'[Number(digit)])
}

function thaiDate(value: string | null | undefined) {
  if (!value) return '—'
  const date = new Date(`${value.slice(0, 10)}T00:00:00`)
  return toThaiDigits(date.toLocaleDateString('th-TH', { day: 'numeric', month: 'short', year: 'numeric' }))
}

function thaiDateFull(value: string | null | undefined) {
  if (!value) return '................................'
  const date = new Date(`${value.slice(0, 10)}T00:00:00`)
  return toThaiDigits(date.toLocaleDateString('th-TH', { day: 'numeric', month: 'long', year: 'numeric' }))
}

function officeUnitName(value: string | null | undefined, prefix: 'งาน' | 'กลุ่มงาน') {
  const name = String(value || '').trim().replace(/^(?:(?:กลุ่มงาน|งาน)\s*)+/u, '').trim()
  return name ? `${prefix}${name}` : ''
}

function statusClass(status: string) {
  if (status === 'approved') return 'status-approved'
  if (status === 'rejected' || status === 'cancelled') return 'status-closed'
  return 'status-pending'
}

export default function App() {
  const [sessionState, setSessionState] = useState<SessionState>(
    isSupabaseConfigured ? 'checking' : 'not-configured',
  )
  const [activePage, setActivePage] = useState('ภาพรวม')
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false)
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [authError, setAuthError] = useState('')
  const [authBusy, setAuthBusy] = useState(false)
  const [profile, setProfile] = useState<UserProfile | null>(null)
  const [isCentralAdmin, setIsCentralAdmin] = useState(false)
  const [impersonation, setImpersonation] = useState<{ active: boolean; target_user_id?: string; target_staff_directory_id?: number; target_name?: string } | null>(null)
  const [impersonationSearch, setImpersonationSearch] = useState('')
  const [impersonationBusy, setImpersonationBusy] = useState(false)
  const [staff, setStaff] = useState<StaffOption[]>([])
  const [myRequests, setMyRequests] = useState<ShiftRequest[]>([])
  const [receivedRequests, setReceivedRequests] = useState<ShiftRequest[]>([])
  const [pendingApprovals, setPendingApprovals] = useState<ShiftRequest[]>([])
  const [workspaceError, setWorkspaceError] = useState('')
  const [workspaceLoading, setWorkspaceLoading] = useState(false)
  const [actionBusy, setActionBusy] = useState('')
  const [selectedRequest, setSelectedRequest] = useState<{ request: ShiftRequest; mode: 'mine' | 'received' | 'approval' } | null>(null)
  const [staffSearch, setStaffSearch] = useState('')
  const [mineFrom, setMineFrom] = useState('')
  const [mineTo, setMineTo] = useState('')
  const [receivedFrom, setReceivedFrom] = useState('')
  const [receivedTo, setReceivedTo] = useState('')
  const [approvalFrom, setApprovalFrom] = useState('')
  const [approvalTo, setApprovalTo] = useState('')
  const [reportMonth, setReportMonth] = useState(() => { const now = new Date(); return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}` })
  const [memoDocumentNumber, setMemoDocumentNumber] = useState('')
  const [memoDocumentDate, setMemoDocumentDate] = useState('')
  const [formError, setFormError] = useState('')
  const [formBusy, setFormBusy] = useState(false)
  const [form, setForm] = useState({
    request_type: 'unit',
    shift_date: '',
    shift_period: 'morning',
    document_number: '',
    document_date: '',
    recipient_staff_directory_id: '',
    replacement_required: false,
    replacement_date: '',
    replacement_period: 'morning',
    requester_note: '',
  })

  const selectableStaff = useMemo(
    () => staff.filter(person =>
      person.has_account &&
      person.staff_directory_id !== profile?.staff_directory_id &&
      person.staff_directory_id !== (isCentralAdmin && impersonation?.active ? impersonation.target_staff_directory_id : null) &&
      `${person.full_name} ${person.position ?? ''} ${person.unit_name ?? ''}`.toLowerCase().includes(staffSearch.trim().toLowerCase()),
    ),
    [staff, profile, staffSearch, isCentralAdmin, impersonation],
  )

  const pendingReceivedCount = receivedRequests.filter(request => request.status === 'waiting_recipient').length
  const filterByDate = (items: ShiftRequest[], from: string, to: string) =>
    items.filter(request => (!from || request.shift_date >= from) && (!to || request.shift_date <= to))
  const filteredMine = useMemo(() => filterByDate(myRequests, mineFrom, mineTo), [myRequests, mineFrom, mineTo])
  const filteredReceived = useMemo(() => filterByDate(receivedRequests, receivedFrom, receivedTo), [receivedRequests, receivedFrom, receivedTo])
  const filteredApprovals = useMemo(() => filterByDate(pendingApprovals, approvalFrom, approvalTo), [pendingApprovals, approvalFrom, approvalTo])
  const monthlyApprovedRequests = useMemo(() => myRequests
    .filter(request => request.status === 'approved'
      && (request.approvals ?? []).some(approval => approval.step_code === 'unit_head')
      && (request.approvals ?? []).some(approval => approval.step_code === 'nursing_head')
      && (request.approvals ?? []).every(approval => approval.decision === 'approved' || approval.decision === 'skipped')
      && request.shift_date.slice(0, 7) === reportMonth)
    .sort((a, b) => a.shift_date.localeCompare(b.shift_date) || a.id.localeCompare(b.id)), [myRequests, reportMonth])
  const reportStaff = staff.find(person => person.staff_directory_id === profile?.staff_directory_id)
  const reportPrefixName = reportStaff?.unit_name || reportStaff?.nursing_group || ''
  const reportPrefixData = MEMO_PREFIXES.find(item => item.name === reportPrefixName)
    || MEMO_PREFIXES.find(item => item.name === reportStaff?.nursing_group)
  const reportOfficeName = reportStaff?.unit_name
    ? officeUnitName(reportStaff.unit_name, 'งาน')
    : officeUnitName(reportStaff?.nursing_group, 'กลุ่มงาน')
  const reportOfficeLine = ['โรงพยาบาลสมเด็จพระยุพราชสว่างแดนดิน', reportOfficeName, reportPrefixData?.phone ? `โทร. ${toThaiDigits(reportPrefixData.phone)}` : ''].filter(Boolean).join(' ')
  const reportBodyOfficeLine = [
    reportStaff?.unit_name ? officeUnitName(reportStaff.unit_name, 'งาน') : '',
    reportStaff?.nursing_group ? officeUnitName(reportStaff.nursing_group, 'กลุ่มงาน') : '',
    'ภารกิจด้านการพยาบาล',
  ].filter(Boolean).join(' ')
  const reportMonthLabel = toThaiDigits(new Date(`${reportMonth}-01T00:00:00`).toLocaleDateString('th-TH', { month: 'long', year: 'numeric' }))
  useEffect(() => {
    if (!memoDocumentNumber.trim() && reportPrefixData?.prefix) setMemoDocumentNumber(reportPrefixData.prefix)
  }, [reportPrefixData?.prefix, memoDocumentNumber])
  const reportOrderReferences = [...new Map(monthlyApprovedRequests
    .filter(request => request.document?.document_number)
    .map(request => [request.document!.document_number, request.document!.document_date] as const)).entries()]
    .map(([number, date]) => `ที่ ${toThaiDigits(number)} ลงวันที่ ${thaiDateFull(date)}`)
  const reportOrderText = reportOrderReferences.length
    ? reportOrderReferences.join(' และ ')
    : 'ที่ ................................ ลงวันที่ ................................'
  const canPrintMemo = Boolean(memoDocumentNumber.trim() && memoDocumentDate)

  const recentDocuments = useMemo(() => {
    const seen = new Map<string, string>()
    myRequests.forEach(request => {
      if (request.document?.document_number) {
        seen.set(request.document.document_number, request.document.document_date)
      }
    })
    return [...seen.entries()]
  }, [myRequests])

  async function refreshWorkspace() {
    if (!supabase) return
    setWorkspaceLoading(true)
    setWorkspaceError('')
    const [staffResult, mineResult, receivedResult, approvalsResult] = await Promise.all([
      supabase.rpc('get_shift_exchange_staff'),
      supabase.rpc('get_shift_exchange_my_requests'),
      supabase.rpc('get_shift_exchange_received_requests'),
      supabase.rpc('get_shift_exchange_pending_approvals'),
    ])
    const firstError = staffResult.error ?? mineResult.error ?? receivedResult.error ?? approvalsResult.error
    if (firstError) {
      setWorkspaceError(firstError.message.includes('function') || firstError.code === 'PGRST202'
        ? 'ฐานข้อมูลส่วนระบบแลกเวรยังไม่ได้ติดตั้ง RPC workflow กรุณาติดตั้ง Migration ก่อนเปิดใช้งาน'
        : firstError.message)
    } else {
      setStaff((staffResult.data ?? []) as StaffOption[])
      const mineRows = (mineResult.data ?? []) as ShiftRequest[]
      if (mineRows.length) {
        const metaResult = await supabase.from('shift_change_requests')
          .select('id,recipient_staff_directory_id,recipient_acted_at')
          .in('id', mineRows.map(request => request.id))
        const metaById = new Map((metaResult.data ?? []).map((row: any) => [row.id, row]))
        setMyRequests(mineRows.map(request => ({
          ...request,
          ...(metaById.get(request.id) as Pick<ShiftRequest, 'recipient_staff_directory_id' | 'recipient_acted_at'> | undefined),
        })))
      } else {
        setMyRequests(mineRows)
      }
      setReceivedRequests((receivedResult.data ?? []) as ShiftRequest[])
      setPendingApprovals((approvalsResult.data ?? []) as ShiftRequest[])
    }
    setWorkspaceLoading(false)
  }

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
    const nextProfile = data as UserProfile
    setProfile(nextProfile)
    const { data: authData } = await supabase.auth.getUser()
    const accountName = (authData.user?.email ?? '').split('@')[0].toLowerCase()
    const centralAdmin = accountName === '11450'
    setIsCentralAdmin(centralAdmin)
    if (!centralAdmin && nextProfile.staff_directory_id) {
      const { error: staffError } = await supabase.rpc('get_my_staff_directory')
      if (staffError) setAuthError(staffError.message)
    }
    if (centralAdmin) {
      const { data: modeData, error: modeError } = await supabase.rpc('get_shift_exchange_impersonation')
      if (modeError) setWorkspaceError(modeError.message)
      else setImpersonation(modeData as { active: boolean; target_user_id?: string; target_staff_directory_id?: number; target_name?: string })
    }
    await refreshWorkspace()
  }

  useEffect(() => {
    if (!supabase) return
    let alive = true
    supabase.auth.getSession().then(async ({ data, error }) => {
      if (!alive) return
      if (error || !data.session) {
        setSessionState('signed-out')
        return
      }
      setSessionState('signed-in')
      await loadProfile(data.session.user.id)
    })
    const { data } = supabase.auth.onAuthStateChange((_event, session) => {
      setSessionState(session ? 'signed-in' : 'signed-out')
      if (!session) {
        setProfile(null)
        setIsCentralAdmin(false)
        setImpersonation(null)
        setStaff([])
        setMyRequests([])
        setReceivedRequests([])
        setPendingApprovals([])
      }
    })
    return () => {
      alive = false
      data.subscription.unsubscribe()
    }
  }, [])

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
      setSessionState('signed-in')
      await loadProfile(data.user.id)
    }
    setAuthBusy(false)
  }

  async function handleLogout() {
    if (!supabase) return
    await supabase.auth.signOut()
    setProfile(null)
    setIsCentralAdmin(false)
    setAuthError('')
    setWorkspaceError('')
  }

  async function submitRequest(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!supabase) return
    if (isCentralAdmin && !impersonation?.active) { setFormError('กรุณาเลือกบุคลากรเพื่อทดสอบแทนก่อนสร้างหรือส่งคำขอ'); return }
    if (!form.recipient_staff_directory_id) {
      setFormError('กรุณาค้นหาและเลือกรายชื่อผู้รับเปลี่ยนเวรจากรายการที่แสดง')
      return
    }
    if (!form.shift_date || !form.document_number.trim() || !form.document_date || (form.replacement_required && !form.replacement_date)) {
      setFormError('กรุณากรอกข้อมูลทุกช่องให้ครบถ้วน')
      return
    }
    setFormBusy(true)
    setFormError('')
    const { error } = await supabase.rpc('create_shift_change_request', {
      p_recipient_staff_directory_id: Number(form.recipient_staff_directory_id),
      p_request_type: form.request_type,
      p_shift_date: form.shift_date,
      p_shift_period: form.shift_period,
      p_document_number: form.document_number.trim() || null,
      p_document_date: form.document_date || null,
      p_replacement_required: form.replacement_required,
      p_replacement_date: form.replacement_required ? form.replacement_date : null,
      p_replacement_period: form.replacement_required ? form.replacement_period : null,
      p_requester_note: form.requester_note.trim() || null,
    })
    if (error) {
      setFormError(error.message)
    } else {
      setForm({
        request_type: 'unit', shift_date: '', shift_period: 'morning',
        document_number: '', document_date: '', recipient_staff_directory_id: '',
        replacement_required: false, replacement_date: '', replacement_period: 'morning',
        requester_note: '',
      })
      setStaffSearch('')
      setActivePage('รายการคำขอของฉัน')
      await refreshWorkspace()
    }
    setFormBusy(false)
  }

  async function startImpersonation(staffId: number) {
    if (!supabase || !isCentralAdmin) return
    setImpersonationBusy(true)
    const { data, error } = await supabase.rpc('start_shift_exchange_impersonation', { p_target_staff_directory_id: staffId })
    if (error) setWorkspaceError(error.message)
    else { setImpersonation(data as { active: boolean; target_user_id?: string; target_staff_directory_id?: number; target_name?: string }); setActivePage('ภาพรวม'); await refreshWorkspace() }
    setImpersonationBusy(false)
  }

  async function stopImpersonation() {
    if (!supabase || !isCentralAdmin) return
    setImpersonationBusy(true)
    const { error } = await supabase.rpc('stop_shift_exchange_impersonation')
    if (error) setWorkspaceError(error.message)
    else { setImpersonation({ active: false }); setActivePage('ภาพรวม'); await refreshWorkspace() }
    setImpersonationBusy(false)
  }

  async function runAction(key: string, rpcName: string, params: Record<string, unknown>) {
    if (!supabase) return
    setActionBusy(key)
    setWorkspaceError('')
    const { error } = await supabase.rpc(rpcName, params)
    if (error) setWorkspaceError(error.message)
    else await refreshWorkspace()
    setActionBusy('')
  }

  function requestTable(items: ShiftRequest[], mode: 'mine' | 'received' | 'approval') {
    return (
      <div className="request-table-wrap">
        <table className="request-table">
          <thead><tr><th>วันที่ปฏิบัติงาน</th><th>ประเภทเวร</th><th>ช่วงเวร</th><th>{mode === 'mine' ? 'ผู้รับเปลี่ยนเวร' : 'ผู้ขอเปลี่ยนเวร'}</th><th>สถานะ</th><th>รายละเอียด</th></tr></thead>
          <tbody>{items.map(request => (
            <tr key={request.id} onClick={() => setSelectedRequest({ request, mode })} tabIndex={0} onKeyDown={event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); setSelectedRequest({ request, mode }) } }}>
              <td><strong>{thaiDate(request.shift_date)}</strong></td>
              <td>{typeLabels[request.request_type] ?? request.request_type}</td>
              <td><span className="shift-period">{periodLabels[request.shift_period] ?? request.shift_period}</span></td>
              <td>{mode === 'mine' ? request.recipient_name : <>{request.requester_name}<small>{request.requester_unit_name}</small></>}</td>
              <td><span className={`status-badge ${statusClass(request.status)}`}>{statusLabels[request.status] ?? request.status}</span></td>
              <td><button className="table-detail-button" type="button" onClick={event => { event.stopPropagation(); setSelectedRequest({ request, mode }) }}>ดูรายละเอียด</button></td>
            </tr>
          ))}</tbody>
        </table>
      </div>
    )
  }
  function requestCard(request: ShiftRequest, mode: 'mine' | 'received' | 'approval') {
    const approvalLines = request.approvals ?? (request.approval ? [request.approval] : [])
    const firstApproverRole = approvalLines.find(item => item.step_code === 'unit_head')?.approver_org_role
    const displayedStatus = request.status === 'waiting_unit_head' && firstApproverRole === 'หัวหน้ากลุ่มงาน'
      ? 'รอหัวหน้ากลุ่มงานอนุมัติ'
      : statusLabels[request.status] ?? request.status
    return (
      <article className="request-card" key={request.id}>
        <div className="request-card-top">
          <div>
            <span className="request-type">{typeLabels[request.request_type] ?? request.request_type}</span>
            <h4>{thaiDate(request.shift_date)} · เวร{periodLabels[request.shift_period] ?? request.shift_period}</h4>
          </div>
          <span className={`status-badge ${statusClass(request.status)}`}>{displayedStatus}</span>
        </div>
        <div className="request-details">
          {mode !== 'mine' && <p><span>ผู้ขอ</span>{request.requester_name} · {request.requester_unit_name}</p>}
          {mode !== 'received' && <p><span>ผู้รับเปลี่ยนเวร</span>{request.recipient_name}</p>}
          {request.document && <p><span>หนังสือ/คำสั่ง</span>{request.document.document_number} ลงวันที่ {thaiDate(request.document.document_date)}</p>}
          {request.replacement_required && <p><span>เวรทดแทน</span>{thaiDate(request.replacement_date)} · เวร{periodLabels[request.replacement_period ?? ''] ?? request.replacement_period}</p>}
          {request.requester_note && <p><span>หมายเหตุ</span>{request.requester_note}</p>}
          {mode === 'received' && request.recipient_comment && <p><span>ความเห็นผู้รับ</span>{request.recipient_comment}</p>}
        </div>
        {approvalLines.length > 0 && (
          <div className="approval-track">
            {approvalLines.map((approval, index) => (
              <div className="approval-line" key={`${approval.step_code}-${index}`}>
                <span>{approval.step_code === 'unit_head' ? 'ขั้นหัวหน้างาน' : approval.step_code === 'group_head' ? 'ขั้นหัวหน้ากลุ่มงาน' : 'ขั้นหัวหน้าพยาบาล'}</span>
                <strong>{approval.approver_name}</strong>
                <small>{approval.decision === 'approved' ? 'อนุมัติแล้ว' : approval.decision === 'rejected' ? 'ไม่อนุมัติ' : approval.decision === 'skipped' ? 'ข้ามขั้น' : 'รอดำเนินการ'}</small>
              </div>
            ))}
          </div>
        )}
        <div className="request-actions">
          {mode === 'received' && request.status === 'waiting_recipient' && (
            <>
              <button className="small-primary" disabled={actionBusy === request.id} onClick={() => runAction(request.id, 'respond_to_shift_change_request', { p_request_id: request.id, p_decision: 'accepted' })} type="button"><CheckCircle2 size={15} /> รับเปลี่ยนเวร</button>
              <button className="small-danger" disabled={actionBusy === request.id} onClick={() => runAction(request.id, 'respond_to_shift_change_request', { p_request_id: request.id, p_decision: 'rejected' })} type="button"><XCircle size={15} /> ปฏิเสธ</button>
            </>
          )}
          {mode === 'approval' && (
            <>
              <button className="small-primary" disabled={actionBusy === request.id} onClick={() => runAction(request.id, 'decide_shift_change_approval', { p_request_id: request.id, p_decision: 'approved' })} type="button"><CheckCircle2 size={15} /> อนุมัติ</button>
              <button className="small-danger" disabled={actionBusy === request.id} onClick={() => runAction(request.id, 'decide_shift_change_approval', { p_request_id: request.id, p_decision: 'rejected' })} type="button"><XCircle size={15} /> ไม่อนุมัติ</button>
            </>
          )}
          {mode === 'mine' && ['waiting_recipient', 'waiting_unit_head', 'waiting_nursing_head'].includes(request.status) && (
            <button className="small-danger" disabled={actionBusy === request.id} onClick={() => runAction(request.id, 'cancel_shift_change_request', { p_request_id: request.id })} type="button">ยกเลิกคำขอ</button>
          )}
        </div>
      </article>
    )
  }

  const dashboardCounts = [
    { label: 'คำขอที่ฉันส่ง', value: myRequests.length, icon: FileText },
    { label: 'คำขอที่ได้รับ', value: receivedRequests.filter(item => item.status === 'waiting_recipient').length, icon: Users },
    { label: 'รอฉันอนุมัติ', value: pendingApprovals.length, icon: ShieldCheck },
  ]

  return (
    <div className="app-shell">
      <aside className={mobileMenuOpen ? "sidebar mobile-menu-open" : "sidebar"}>
        <div className="brand">
          <div className="brand-mark"><img className="brand-logo" src="https://raw.githubusercontent.com/itnurse-swdcph/nursing-shift-exchange/main/icon.png" alt="โลโก้ระบบแลกเปลี่ยนเวร" /></div>
          <div><strong>ระบบแลกเปลี่ยนเวร</strong><span>กลุ่มการพยาบาล</span></div>
          <button className="mobile-menu-toggle" type="button" aria-label={mobileMenuOpen ? "ย่อเมนู" : "ขยายเมนู"} aria-expanded={mobileMenuOpen} onClick={() => setMobileMenuOpen(open => !open)}>{mobileMenuOpen ? <X size={20} /> : <Menu size={20} />}</button>
        </div>
        <div className="nav-caption">เมนูหลัก</div>
        <nav>
          {navigation.map(({ label, icon: Icon }) => (
            <button className={activePage === label ? 'nav-item active' : 'nav-item'} key={label} onClick={() => { setActivePage(label); setMobileMenuOpen(false) }} type="button">
              <Icon size={18} strokeWidth={1.8} /><span>{label}</span>
              {label === 'อนุมัติคำขอ' && pendingApprovals.length > 0 && <i className="nav-count">{pendingApprovals.length}</i>}{label === 'รายการที่มอบหมายให้ฉัน' && pendingReceivedCount > 0 && <i className="nav-count">{pendingReceivedCount}</i>}
            </button>
          ))}
          {isCentralAdmin && <button className={activePage === 'ทดสอบสิทธิ์แทนบุคลากร' ? 'nav-item active' : 'nav-item'} onClick={() => { setActivePage('ทดสอบสิทธิ์แทนบุคลากร'); setMobileMenuOpen(false) }} type="button"><ShieldCheck size={18}/><span>ทดสอบสิทธิ์แทนบุคลากร</span></button>}
        </nav>
        <div className="sidebar-footer">โรงพยาบาลสมเด็จพระยุพราชสว่างแดนดิน</div>
      </aside>

      <main className="main-area">
        <header className="topbar">
          <div><div className="eyebrow">NURSING SERVICES</div><h1>{activePage}</h1></div>
          <div className="topbar-actions">
            {profile && <span className="user-name">{profile.full_name ?? 'ผู้ใช้งาน'}</span>}
            {sessionState === 'signed-in' && <button className="logout-button" onClick={handleLogout} type="button"><LogOut size={15} /> ออกจากระบบ</button>}
            {sessionState === 'signed-in' && <button className="refresh-button" onClick={refreshWorkspace} type="button" disabled={workspaceLoading}><RefreshCw size={14} /> รีเฟรช</button>}
            <div className="session-pill"><span className={sessionState === 'signed-in' ? 'status-dot online' : 'status-dot'} />
              {sessionState === 'checking' ? 'กำลังตรวจสอบบัญชี' : sessionState === 'signed-in' ? 'เข้าสู่ระบบแล้ว' : sessionState === 'not-configured' ? 'รอตั้งค่าเชื่อมต่อ' : 'ยังไม่ได้เข้าสู่ระบบ'}
            </div>
          </div>
        </header>

        {sessionState === 'not-configured' && <div className="notice"><strong>เตรียมการเชื่อมต่อ Supabase</strong><p>กำหนดค่า VITE_SUPABASE_URL และ VITE_SUPABASE_ANON_KEY ใน environment ก่อนเปิดใช้งานระบบ</p></div>}
        {sessionState === 'signed-out' && (
          <form className="login-panel" onSubmit={handleLogin}>
            <div><span className="section-kicker">NURSING SHIFT EXCHANGE</span><h3>เข้าสู่ระบบ</h3><p>เข้าสู่ระบบด้วยรหัสเข้าระบบ P4P</p></div>
            <label>ชื่อผู้ใช้<input autoComplete="username" value={username} onChange={event => setUsername(event.target.value)} placeholder="กรอกชื่อผู้ใช้" required /></label>
            <label>รหัสผ่าน<input autoComplete="current-password" type="password" value={password} onChange={event => setPassword(event.target.value)} placeholder="กรอกรหัสผ่าน" required /></label>
            {authError && <p className="form-error">{authError}</p>}
            <button className="primary-button" disabled={authBusy} type="submit">{authBusy ? 'กำลังเข้าสู่ระบบ…' : 'เข้าสู่ระบบ'}</button>
          </form>
        )}

        {sessionState === 'signed-in' && (
          <>
            {isCentralAdmin && impersonation?.active && <div className="notice warning impersonation-banner"><strong>กำลังทดสอบสิทธิ์แทน: {impersonation.target_name ?? 'บุคลากร'}</strong><p>การสร้างคำขอ ตอบรับ อนุมัติ และยกเลิก จะเปลี่ยนข้อมูลจริงในนามบุคลากรที่เลือก พร้อมบันทึกว่าแอดมิน 11450 เป็นผู้ดำเนินการทดสอบ</p><button className="small-danger" type="button" disabled={impersonationBusy} onClick={stopImpersonation}>หยุดทดสอบแทนบุคลากร</button></div>}
            {authError && <div className="notice warning"><strong>ข้อมูลบัญชีผู้ใช้</strong><p>{authError}</p></div>}
            {workspaceError && <div className="notice warning"><strong>การเชื่อมต่อข้อมูล</strong><p>{workspaceError}</p></div>}
            {workspaceLoading && <div className="loading-line"><span className="spinner" /> กำลังโหลดข้อมูลระบบแลกเวร…</div>}

            {activePage === 'ทดสอบสิทธิ์แทนบุคลากร' && isCentralAdmin && (
              <section className="content-panel"><div className="panel-heading"><div><span className="section-kicker">ADMIN TEST MODE</span><h3>ทดสอบสิทธิ์แทนบุคลากร</h3><p>เลือกบุคลากรที่มีบัญชีใช้งาน การกระทำที่เปลี่ยนสถานะจะบันทึกประวัติแอดมินและผู้ถูกทดสอบแยกกัน</p></div></div>
                <label>ค้นหาบุคลากร<input value={impersonationSearch} onChange={event => setImpersonationSearch(event.target.value)} placeholder="พิมพ์ชื่อ ตำแหน่ง หรือหน่วยงาน" /></label>
                <div className="staff-search-results">{staff.filter(person => person.has_account && (person.full_name + ' ' + (person.position ?? '') + ' ' + (person.unit_name ?? '')).toLowerCase().includes(impersonationSearch.trim().toLowerCase())).slice(0,30).map(person => <button type="button" key={person.staff_directory_id} disabled={impersonationBusy} onClick={() => startImpersonation(person.staff_directory_id)}><strong>{person.full_name}</strong><small>{person.position ?? 'ไม่ระบุตำแหน่ง'} · {person.unit_name ?? 'ไม่ระบุหน่วยงาน'} · {person.org_role ?? 'ผู้ปฏิบัติงาน'}</small></button>)}</div>
              </section>
            )}

            {activePage === 'ภาพรวม' && (
              <>
                <section className="welcome-panel">
                  <div className="welcome-copy"><span className="section-kicker">SHIFT EXCHANGE PORTAL</span><h2>จัดการการเปลี่ยนเวร<br />อย่างเป็นระบบและตรวจสอบได้</h2><p>บันทึกคำขอ ติดตามผู้รับเปลี่ยนเวร และดำเนินการอนุมัติตามลำดับของกลุ่มการพยาบาล</p></div>
                  <div className="welcome-icon"><CalendarDays size={54} strokeWidth={1.2} /></div>
                </section>
                <div className="stat-grid">
                  {dashboardCounts.map(({ label, value, icon: Icon }) => <div className="stat-card" key={label}><span className="stat-icon"><Icon size={18} /></span><div><strong>{value}</strong><small>{label}</small></div></div>)}
                </div>
                <div className="section-heading"><div><span className="section-kicker">WORKSPACE</span><h3>เมนูการทำงาน</h3></div><span className="muted">ระบบแลกเปลี่ยนเวร</span></div>
                <div className="feature-grid">
                  {navigation.slice(1).map(({ label, icon: Icon }, index) => <button className="feature-card" key={label} onClick={() => setActivePage(label)} type="button"><div className="feature-icon"><Icon size={21} /></div><strong>{label}</strong><span>{['สร้างและส่งคำขอเปลี่ยนเวร', 'ติดตามสถานะคำขอที่ส่ง', 'ตอบรับคำขอที่ได้รับมอบหมาย', 'ตรวจสอบและอนุมัติตามสิทธิ์', 'สรุปข้อมูลและพิมพ์รายงาน'][index]}</span></button>)}
                </div>
              </>
            )}

            {activePage === 'ขอเปลี่ยนเวร' && isCentralAdmin && !impersonation?.active && <section className="content-panel approval-restricted"><h3>ยังไม่ได้เลือกบุคลากรทดสอบแทน</h3><p>กรุณาเลือกบุคลากรจากเมนูทดสอบสิทธิ์แทนบุคลากรก่อน จึงจะสร้างและส่งคำขอในนามบุคลากรนั้นได้</p></section>}
            {activePage === 'ขอเปลี่ยนเวร' && (!isCentralAdmin || impersonation?.active) && (
              <section className="content-panel">
                <div className="panel-heading"><div><span className="section-kicker">NEW REQUEST</span><h3>แบบฟอร์มขอเปลี่ยนเวร</h3><p>ผู้อนุมัติจะถูกกำหนดจากหน่วยงานของผู้ขอโดยอัตโนมัติ</p></div></div>
                <form className="request-form" onSubmit={submitRequest}>
                  <div className="form-grid">
                    <label>ประเภทเวร<select value={form.request_type} onChange={event => setForm({ ...form, request_type: event.target.value })}><option value="unit">เวรหน่วยงาน</option><option value="refer">เวร Refer</option><option value="supervision">เวรตรวจการ</option></select></label>
                    <label>วันที่ปฏิบัติงาน<input type="date" value={form.shift_date} onKeyDown={event => event.preventDefault()} onPaste={event => event.preventDefault()} onChange={event => setForm({ ...form, shift_date: event.target.value })} required /></label>
                    <label>ช่วงเวร<select value={form.shift_period} onChange={event => setForm({ ...form, shift_period: event.target.value })}><option value="morning">เช้า</option><option value="afternoon">บ่าย</option><option value="night">ดึก</option></select></label>
                    <label>เลขที่หนังสือ/คำสั่ง<input list="recent-document-numbers" value={form.document_number} onChange={event => {
                      const match = recentDocuments.find(([number]) => number === event.target.value)
                      setForm({ ...form, document_number: event.target.value, document_date: match?.[1] ?? '' })
                    }} placeholder="เช่น 123/2569" required /><datalist id="recent-document-numbers">{recentDocuments.map(([number]) => <option key={number} value={number} />)}</datalist></label>
                    <label>วันที่หนังสือ/คำสั่ง<input type="date" value={form.document_date} onKeyDown={event => event.preventDefault()} onPaste={event => event.preventDefault()} onChange={event => setForm({ ...form, document_date: event.target.value })} required /></label>
                  </div>
                  <div className="form-section">
                    <h4>ผู้รับเปลี่ยนเวร</h4>
                    <label>ค้นหาและเลือกผู้รับเปลี่ยนเวร<input value={staffSearch} onChange={event => { setStaffSearch(event.target.value); setForm({ ...form, recipient_staff_directory_id: '' }) }} placeholder="พิมพ์ชื่อบุคลากรเพื่อค้นหา" required={!form.recipient_staff_directory_id} /></label>
                    {form.recipient_staff_directory_id ? <div className="selected-recipient"><span>ผู้รับที่เลือก: {staff.find(person => String(person.staff_directory_id) === form.recipient_staff_directory_id)?.full_name ?? ''}</span><button type="button" onClick={() => { setForm({ ...form, recipient_staff_directory_id: '' }); setStaffSearch('') }}>เปลี่ยนผู้รับ</button></div> : staffSearch.trim().length > 0 && <div className="staff-search-results">{selectableStaff.slice(0, 10).map(person => <button type="button" key={person.staff_directory_id} onClick={() => { setForm({ ...form, recipient_staff_directory_id: String(person.staff_directory_id) }); setStaffSearch(person.full_name) }}><strong>{person.full_name}</strong><small>{person.position ?? 'ไม่ระบุตำแหน่ง'} · {person.unit_name ?? 'ไม่ระบุหน่วยงาน'}</small></button>)}{selectableStaff.length === 0 && <p className="muted">ไม่พบรายชื่อที่ตรงกัน หรือบุคลากรยังไม่มีบัญชีผู้ใช้ในระบบ</p>}</div>}
                    <input type="hidden" value={form.recipient_staff_directory_id} required />
                  </div>
                  <div className="form-section">
                    <h4>เงื่อนไขการทดแทนเวร</h4>
                    <div className="choice-row"><label className="radio-label"><input type="radio" checked={!form.replacement_required} onChange={() => setForm({ ...form, replacement_required: false, replacement_date: '' })} /> ไม่ต้องทดแทน</label><label className="radio-label"><input type="radio" checked={form.replacement_required} onChange={() => setForm({ ...form, replacement_required: true })} /> ต้องทดแทน</label></div>
                    {form.replacement_required && <div className="form-grid replacement-grid"><label>วันที่ทดแทน<input type="date" value={form.replacement_date} onKeyDown={event => event.preventDefault()} onPaste={event => event.preventDefault()} onChange={event => setForm({ ...form, replacement_date: event.target.value })} required /></label><label>ช่วงเวรที่ทดแทน<select value={form.replacement_period} onChange={event => setForm({ ...form, replacement_period: event.target.value })}><option value="morning">เช้า</option><option value="afternoon">บ่าย</option><option value="night">ดึก</option></select></label></div>}
                  </div>
                  <label>หมายเหตุ <span className="optional">(ไม่บังคับ)</span><textarea rows={3} value={form.requester_note} onChange={event => setForm({ ...form, requester_note: event.target.value })} placeholder="รายละเอียดเพิ่มเติม (ถ้ามี)" /></label>
                  {formError && <p className="form-error">{formError}</p>}
                  <div className="form-actions"><button className="primary-button" disabled={formBusy} type="submit">{formBusy ? 'กำลังบันทึก…' : 'บันทึกและส่งคำขอ'}</button></div>
                </form>
              </section>
            )}

            {activePage === 'รายการคำขอของฉัน' && <section className="content-panel"><div className="panel-heading"><div><span className="section-kicker">MY REQUESTS</span><h3>รายการคำขอของฉัน</h3></div><span className="muted">{filteredMine.length} / {myRequests.length} รายการ</span></div><div className="date-filter"><label>ตั้งแต่วันที่<input type="date" value={mineFrom} onKeyDown={event => event.preventDefault()} onPaste={event => event.preventDefault()} onChange={event => setMineFrom(event.target.value)} /></label><label>ถึงวันที่<input type="date" value={mineTo} onKeyDown={event => event.preventDefault()} onPaste={event => event.preventDefault()} onChange={event => setMineTo(event.target.value)} /></label><button type="button" onClick={() => { setMineFrom(''); setMineTo('') }}>ล้างตัวกรอง</button></div>{filteredMine.length ? requestTable(filteredMine, 'mine') : <div className="empty-state">ไม่พบรายการในช่วงวันที่ที่เลือก</div>}</section>}

            {activePage === 'รายการที่มอบหมายให้ฉัน' && <section className="content-panel"><div className="panel-heading"><div><span className="section-kicker">ASSIGNED TO ME</span><h3>รายการที่มอบหมายให้ฉัน</h3></div><span className="muted">{filteredReceived.length} / {receivedRequests.length} รายการ · ค้างรับ {pendingReceivedCount}</span></div><div className="date-filter"><label>ตั้งแต่วันที่<input type="date" value={receivedFrom} onKeyDown={event => event.preventDefault()} onPaste={event => event.preventDefault()} onChange={event => setReceivedFrom(event.target.value)} /></label><label>ถึงวันที่<input type="date" value={receivedTo} onKeyDown={event => event.preventDefault()} onPaste={event => event.preventDefault()} onChange={event => setReceivedTo(event.target.value)} /></label><button type="button" onClick={() => { setReceivedFrom(''); setReceivedTo('') }}>ล้างตัวกรอง</button></div>{filteredReceived.length ? requestTable(filteredReceived, 'received') : <div className="empty-state">ไม่พบรายการในช่วงวันที่ที่เลือก</div>}</section>}

            {activePage === 'อนุมัติคำขอ' && (isCentralAdmin || ['หัวหน้างาน', 'หัวหน้ากลุ่มงาน', 'หัวหน้าพยาบาล', 'รักษาการหัวหน้าพยาบาล'].includes(staff.find(person => person.staff_directory_id === profile?.staff_directory_id)?.org_role ?? '')) ? <section className="content-panel"><div className="panel-heading"><div><span className="section-kicker">APPROVAL QUEUE</span><h3>รายการรออนุมัติ</h3><p>แสดงเฉพาะคำขอที่อยู่ในขั้นตอนและขอบเขตการอนุมัติของคุณ</p></div><span className="muted">{pendingApprovals.length} รายการ</span></div><div className="date-filter"><label>ตั้งแต่วันที่<input type="date" value={approvalFrom} onKeyDown={event => event.preventDefault()} onPaste={event => event.preventDefault()} onChange={event => setApprovalFrom(event.target.value)} /></label><label>ถึงวันที่<input type="date" value={approvalTo} onKeyDown={event => event.preventDefault()} onPaste={event => event.preventDefault()} onChange={event => setApprovalTo(event.target.value)} /></label><button type="button" onClick={() => { setApprovalFrom(''); setApprovalTo('') }}>ล้างตัวกรอง</button></div>{filteredApprovals.length ? requestTable(filteredApprovals, 'approval') : <div className="empty-state">ไม่พบรายการรออนุมัติในช่วงวันที่ที่เลือก</div>}</section> : activePage === 'อนุมัติคำขอ' ? <section className="content-panel approval-restricted"><div className="restricted-icon"><ShieldCheck size={28}/></div><h3>เมนูนี้สำหรับผู้มีสิทธิ์อนุมัติคำขอเท่านั้น</h3><p>บัญชีผู้ใช้งานทั่วไปไม่สามารถเข้าถึงรายการอนุมัติได้</p></section> : null}

            {activePage === 'รายงานประจำเดือน' && (
              <section className="content-panel monthly-report-screen">
                <div className="panel-heading report-screen-heading">
                  <div><span className="section-kicker">MONTHLY REPORT</span><h3>รายงานประจำเดือน</h3><p>แสดงเฉพาะคำขอของคุณที่อนุมัติครบทุกขั้นตอน โดยอ้างอิงเดือนจากวันที่ขอแลกเวร</p></div>
                  <div className="report-toolbar">
                    <label>เลือกเดือน<input type="month" value={reportMonth} onChange={event => setReportMonth(event.target.value)} /></label>
                    <button className="primary-button" type="button" disabled={monthlyApprovedRequests.length === 0 || !canPrintMemo} onClick={() => window.print()}><FileText size={16} /> พิมพ์บันทึกข้อความ</button>
                  </div>
                </div>
                <div className="report-document-fields">
                  <label>เลขที่หนังสือบันทึกข้อความ<input value={memoDocumentNumber} onChange={event => setMemoDocumentNumber(event.target.value)} placeholder="สน ๐๐๓๓.๓๐๕....../...." /></label>
                  <label>วันที่บันทึกข้อความ<input type="date" value={memoDocumentDate} onChange={event => setMemoDocumentDate(event.target.value)} /></label>
                  <a href="https://itnurse-swdcph.github.io/e-office/" target="_blank" rel="noreferrer">ขอเลขที่หนังสือผ่านระบบ E-Office</a>
                  {!canPrintMemo && <p>กรุณากรอกเลขที่หนังสือและวันที่ให้ครบก่อนพิมพ์</p>}
                </div>
                <div className="report-summary">
                  <div><span>เดือนรายงาน</span><strong>{reportMonthLabel}</strong></div>
                  <div><span>ผู้จัดทำรายงาน</span><strong>{profile?.full_name ?? '—'}</strong></div>
                  <div><span>รายการอนุมัติครบแล้ว</span><strong>{monthlyApprovedRequests.length} รายการ</strong></div>
                </div>
                {monthlyApprovedRequests.length === 0 ? (
                  <div className="empty-state">ไม่พบรายการแลกเวรที่อนุมัติครบแล้วในเดือน{reportMonthLabel}</div>
                ) : (
                  <div className="request-table-wrap monthly-report-preview">
                    <table className="request-table">
                      <thead><tr><th>วันที่ขอแลกเวร</th><th>ประเภทเวร</th><th>ช่วงเวร</th><th>ผู้รับเปลี่ยนเวร</th><th>เงื่อนไขการทดแทน</th><th>ความเห็นผู้อนุมัติ</th></tr></thead>
                      <tbody>{monthlyApprovedRequests.map(request => (
                        <tr key={request.id}>
                          <td><strong>{thaiDate(request.shift_date)}</strong></td>
                          <td>{typeLabels[request.request_type] ?? request.request_type}</td>
                          <td>{periodLabels[request.shift_period] ?? request.shift_period}</td>
                          <td>{request.recipient_name}</td>
                          <td>{request.replacement_required ? `ทดแทนวันที่ ${thaiDate(request.replacement_date)} เวร${periodLabels[request.replacement_period ?? ''] ?? request.replacement_period ?? ''}` : 'ไม่ต้องทดแทน'}</td>
                          <td>{(request.approvals ?? []).filter(item => item.decision === 'approved').map(item => `${item.approver_name} (${item.approver_org_role ?? (item.step_code === 'unit_head' ? 'หัวหน้างาน' : 'หัวหน้าพยาบาล')})`).join(' / ') || 'อนุมัติตามขั้นตอนที่กำหนด'}</td>
                        </tr>
                      ))}</tbody>
                    </table>
                  </div>
                )}
                <div className="print-report">
                  <div className="memo-letterhead">
                    <img src="https://raw.githubusercontent.com/itnurse-swdcph/p4pcal/main/app/public/garuda-emblem.png" alt="" className="memo-garuda" />
                    <h1>บันทึกข้อความ</h1>
                  </div>
                  <div className="memo-line memo-official-line"><strong>ส่วนราชการ</strong><span className="memo-line-value">\${reportOfficeLine}</span></div>
                  <div className="memo-number">
                    <div className="memo-line"><strong>ที่</strong><span className="memo-line-value">\${toThaiDigits(memoDocumentNumber)}</span></div>
                    <div className="memo-line"><strong>วันที่</strong><span className="memo-line-value">\${thaiDateFull(memoDocumentDate)}</span></div>
                  </div>
                  <div className="memo-line memo-subject"><strong>เรื่อง</strong><span className="memo-line-value">ขอเปลี่ยนแปลงการมอบหมายการปฏิบัติงาน (เปลี่ยนเวร)</span></div>
                  <p className="memo-to"><strong>เรียน</strong> หัวหน้าพยาบาล</p>
                  <p className="memo-intro">ข้าพเจ้า \${profile?.full_name ?? '................................................'} ตำแหน่ง \${reportStaff?.position ?? '................................'} \${reportBodyOfficeLine} ได้รับมอบหมายให้ปฏิบัติงานตามคำสั่งโรงพยาบาลสมเด็จพระยุพราชสว่างแดนดิน \${reportOrderText} มีความประสงค์ขอเปลี่ยนแปลงการมอบหมายการปฏิบัติงาน ดังนี้</p>
                  <table className="memo-table">
                    <thead><tr><th>วันเดือนปีที่ได้รับมอบหมาย</th><th>ประเภทเวร / ผลัด</th><th>ผู้รับมอบหมายงานแทน</th><th>เงื่อนไขการรับมอบงาน</th><th>ความเห็นหัวหน้างาน/หัวหน้ากลุ่มงาน</th><th>ความเห็นหัวหน้าพยาบาล</th></tr></thead>
                    <tbody>{monthlyApprovedRequests.map(request => {
                      const unitApproval = (request.approvals ?? []).find(item => item.step_code === 'unit_head')
                      const nursingApproval = (request.approvals ?? []).find(item => item.step_code === 'nursing_head')
                      const recipientStaff = staff.find(person => person.staff_directory_id === request.recipient_staff_directory_id)
                        || staff.find(person => person.full_name.trim() === request.recipient_name.trim())
                      const opinion = (item: Approval | undefined) => {
                        if (!item) return '—'
                        const approverStaff = staff.find(person => person.full_name.trim() === item.approver_name.trim())
                        const role = item.approver_org_role || (item.step_code === 'unit_head' ? 'หัวหน้างาน/หัวหน้ากลุ่มงาน' : 'หัวหน้าพยาบาล')
                        return <>{item.comment || (item.decision === 'skipped' ? 'ข้ามขั้นตอนการอนุมัติ' : 'เห็นควรอนุญาต')}<br /><span className="memo-approver">{item.approver_name}</span>{approverStaff?.position ? <><br />ตำแหน่ง{approverStaff.position}</> : null}<br />{role}{item.acted_at ? <><br />ลงวันที่ {thaiDateFull(item.acted_at)}</> : null}</>
                      }
                      const condition = request.replacement_required
                        ? <><span>☐ ไม่ทดแทน</span><br /><span>☒ ทดแทนในวันที่ {thaiDateFull(request.replacement_date)} เวร{periodLabels[request.replacement_period ?? ''] ?? request.replacement_period ?? ''}</span></>
                        : <><span>☒ ไม่ทดแทน</span><br /><span>☐ ทดแทนในวันที่ .................... เวร....................</span></>
                      return <tr key={request.id}>
                        <td>{thaiDateFull(request.shift_date)}</td>
                        <td>{typeLabels[request.request_type] ?? request.request_type}<br />เวร{periodLabels[request.shift_period] ?? request.shift_period}</td>
                        <td>{request.recipient_name}{recipientStaff?.position ? <><br />ตำแหน่ง{recipientStaff.position}</> : null}{request.recipient_acted_at ? <><br />รับงานวันที่ {thaiDateFull(request.recipient_acted_at)}</> : null}</td>
                        <td>{condition}</td>
                        <td>{opinion(unitApproval)}</td>
                        <td>{opinion(nursingApproval)}</td>
                      </tr>
                    })}</tbody>
                  </table>
                  <p className="memo-closing">จึงเรียนมาเพื่อโปรดพิจารณา</p>
                  <div className="memo-signature"><div>ลงชื่อ ........................................................</div><div>(\${profile?.full_name ?? '........................................................'})</div><div>ตำแหน่ง \${reportStaff?.position ?? '........................................................'}</div></div>
                </div>
              </section>
            )}
          </>
        )}
        {selectedRequest && <div className="modal-backdrop" onClick={() => setSelectedRequest(null)}>
  <section className="request-detail-modal" role="dialog" aria-modal="true" aria-label="รายละเอียดคำขอเปลี่ยนเวร" onClick={event => event.stopPropagation()}>
    <div className="modal-heading"><div><span className="section-kicker">REQUEST DETAILS</span><h3>รายละเอียดคำขอเปลี่ยนเวร</h3></div><button className="modal-close" type="button" onClick={() => setSelectedRequest(null)} aria-label="ปิด"><X size={20}/></button></div>
    {requestCard(selectedRequest.request, selectedRequest.mode)}
  </section>
</div>}
<footer className="page-footer">© 2026 Developed By Natnarinthorn | Nursing Informatics System</footer>
      </main>
    </div>
  )
}
