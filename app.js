(() => {
  "use strict";

  const config = window.LEAVE_APP_CONFIG || {};
  const sessionKey = "leaveEmployeeSession";
  const state = {
    month: new Date(new Date().getFullYear(), new Date().getMonth(), 1),
    employees: [],
    leaves: [],
    editStatus: null,
    duration: 1,
    session: null,
    saving: false
  };

  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => [...document.querySelectorAll(selector)];
  const toIsoDate = (date) => {
    const y = date.getFullYear();
    const m = String(date.getMonth() + 1).padStart(2, "0");
    const d = String(date.getDate()).padStart(2, "0");
    return `${y}-${m}-${d}`;
  };
  const parseIsoDate = (value) => new Date(`${value}T12:00:00`);

  async function rpc(name, body = {}) {
    if (!config.supabaseUrl || !config.supabasePublishableKey || config.supabaseUrl.includes("YOUR_PROJECT")) {
      throw new Error("網站尚未完成資料庫設定");
    }
    const response = await fetch(`${config.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: { apikey: config.supabasePublishableKey, "Content-Type": "application/json" },
      body: JSON.stringify(body)
    });
    const payload = await response.json().catch(() => null);
    if (!response.ok) {
      const raw = payload?.message || "操作失敗，請稍後再試";
      throw new Error(raw.replace(/^.*?: /, ""));
    }
    return payload;
  }

  function notify(message, isError = false) {
    const toast = $("#toast");
    toast.textContent = message;
    toast.classList.toggle("error", isError);
    toast.classList.add("show");
    clearTimeout(notify.timer);
    notify.timer = setTimeout(() => toast.classList.remove("show"), 3200);
  }

  function escapeHtml(value) {
    return String(value).replace(/[&<>'"]/g, (char) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
    })[char]);
  }

  function setPage(name) {
    $$(".tab").forEach((tab) => tab.classList.toggle("active", tab.dataset.page === name));
    $$(".page").forEach((page) => page.classList.toggle("active", page.id === `page-${name}`));
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function monthRange() {
    const firstCell = new Date(state.month.getFullYear(), state.month.getMonth(), 1 - state.month.getDay());
    const lastCell = new Date(firstCell);
    lastCell.setDate(lastCell.getDate() + 41);
    return [firstCell, lastCell];
  }

  function firstFutureMonthDate() {
    const base = state.editStatus?.today_date ? parseIsoDate(state.editStatus.today_date) : new Date();
    return new Date(base.getFullYear(), base.getMonth() + 1, 1);
  }

  function isFutureMonth(date) {
    const first = firstFutureMonthDate();
    return date.getFullYear() > first.getFullYear() ||
      (date.getFullYear() === first.getFullYear() && date.getMonth() >= first.getMonth());
  }

  function renderEmployees() {
    const legend = $("#employeeLegend");
    if (!state.employees.length) {
      legend.innerHTML = "<span>尚未新增員工</span>";
      return;
    }
    legend.innerHTML = state.employees.map((employee) =>
      `<span class="legend-item"><span class="dot" style="background:${employee.color}"></span>${escapeHtml(employee.employee_name)}</span>`
    ).join("");
  }

  function renderSession() {
    const loggedIn = Boolean(state.session?.session_token);
    $("#employeeControls").hidden = !loggedIn;
    $("#openLeaveForm").textContent = loggedIn ? "回到月曆" : "員工登入";
    if (loggedIn) $("#sessionName").textContent = `已登入：${state.session.employee_name}`;
    renderEditStatus();
    renderCalendar();
  }

  function renderEditStatus() {
    if (!state.editStatus) return;
    const banner = $("#editStatus");
    const open = Boolean(state.editStatus.editing_open);
    banner.classList.toggle("locked", !open);
    banner.textContent = open
      ? `本月預休填寫開放中｜請在 ${state.editStatus.deadline_date} 前完成`
      : `本月預休已截止｜${state.editStatus.next_open_date} 重新開放修改`;
    $("#calendarHint").textContent = !open
      ? "目前只能查看所有人的預休，無法新增或取消。"
      : state.session
        ? "點日期立即新增；再點自己的預休日期即可取消。"
        : "請先登入，之後直接點日期即可新增或取消預休。";
  }

  function renderCalendar() {
    const [firstCell] = monthRange();
    const today = state.editStatus?.today_date || toIsoDate(new Date());
    const month = state.month.getMonth();
    const leavesByDate = state.leaves.reduce((map, leave) => {
      (map[leave.leave_date] ||= []).push(leave);
      return map;
    }, {});
    $("#monthTitle").textContent = new Intl.DateTimeFormat("zh-TW", { year: "numeric", month: "long" }).format(state.month);

    const cells = [];
    for (let i = 0; i < 42; i += 1) {
      const date = new Date(firstCell);
      date.setDate(firstCell.getDate() + i);
      const iso = toIsoDate(date);
      const selectable = Boolean(state.editStatus?.editing_open) && isFutureMonth(date);
      const chips = (leavesByDate[iso] || []).map((leave) =>
        `<span class="leave-chip${leave.employee_id === state.session?.employee_id ? " mine" : ""}" style="color:${leave.color}">${escapeHtml(leave.employee_name)}</span>`
      ).join("");
      cells.push(`
        <button class="calendar-day${date.getMonth() !== month ? " outside" : ""}${iso === today ? " today" : ""}${selectable ? " editable" : " locked-day"}" type="button" ${selectable ? `data-date="${iso}"` : ""} aria-label="${iso}${selectable ? " 切換預休" : " 查看預休"}">
          <span class="day-number">${date.getDate()}</span>${chips}
        </button>`);
    }
    $("#calendarGrid").innerHTML = cells.join("");
    $("#calendarGrid").classList.toggle("saving", state.saving);
  }

  async function loadEmployees() {
    state.employees = await rpc("get_employees");
    renderEmployees();
  }

  async function loadEditStatus() {
    const rows = await rpc("get_edit_status");
    state.editStatus = rows[0];
    renderEditStatus();
    renderCalendar();
  }

  async function loadMonth() {
    const [start, end] = monthRange();
    state.leaves = await rpc("get_leave_days", { start_date: toIsoDate(start), end_date: toIsoDate(end) });
    renderCalendar();
  }

  function saveSession(session) {
    state.session = session;
    try { sessionStorage.setItem(sessionKey, JSON.stringify(session)); } catch (_) { /* private browsing fallback */ }
    renderSession();
  }

  function clearSession() {
    state.session = null;
    try { sessionStorage.removeItem(sessionKey); } catch (_) { /* private browsing fallback */ }
    renderSession();
  }

  async function restoreSession() {
    let stored = null;
    try { stored = JSON.parse(sessionStorage.getItem(sessionKey)); } catch (_) { /* ignore invalid storage */ }
    if (!stored?.session_token) return;
    try {
      const result = await rpc("get_employee_session", { session_token: stored.session_token });
      saveSession({ session_token: stored.session_token, ...result });
    } catch (_) {
      clearSession();
    }
  }

  function withBusy(form, task) {
    return async (event) => {
      event.preventDefault();
      const buttons = [...form.querySelectorAll('button[type="submit"]')];
      buttons.forEach((button) => { button.disabled = true; });
      try { await task(event); } catch (error) { notify(error.message, true); } finally {
        buttons.forEach((button) => { button.disabled = false; });
      }
    };
  }

  $$(".tab").forEach((tab) => tab.addEventListener("click", () => setPage(tab.dataset.page)));
  $("#openLeaveForm").addEventListener("click", () => setPage(state.session ? "calendar" : "leave"));
  $("#todayButton").addEventListener("click", () => { state.month = new Date(new Date().getFullYear(), new Date().getMonth(), 1); loadMonth(); });
  $("#prevMonth").addEventListener("click", () => { state.month = new Date(state.month.getFullYear(), state.month.getMonth() - 1, 1); loadMonth(); });
  $("#nextMonth").addEventListener("click", () => { state.month = new Date(state.month.getFullYear(), state.month.getMonth() + 1, 1); loadMonth(); });

  $$("[data-duration]").forEach((button) => button.addEventListener("click", () => {
    state.duration = Number(button.dataset.duration);
    $$("[data-duration]").forEach((item) => item.classList.toggle("active", item === button));
  }));

  $("#calendarGrid").addEventListener("click", async (event) => {
    const day = event.target.closest("[data-date]");
    if (!day || state.saving) return;
    if (!state.session) {
      notify("請先登入員工帳號");
      setPage("leave");
      return;
    }
    state.saving = true;
    renderCalendar();
    try {
      const result = await rpc("toggle_leave_range", {
        session_token: state.session.session_token,
        selected_start_date: day.dataset.date,
        duration_days: state.duration
      });
      notify(result.action === "removed" ? `已取消 ${result.affected_days} 天預休` : `已新增 ${result.affected_days} 天預休`);
      await loadMonth();
    } catch (error) {
      notify(error.message, true);
      if (error.message.includes("登入已過期")) {
        clearSession();
        setPage("leave");
      }
    } finally {
      state.saving = false;
      renderCalendar();
    }
  });

  $("#loginForm").addEventListener("submit", withBusy($("#loginForm"), async () => {
    const result = await rpc("login_employee", {
      login_username: $("#employeeUsername").value,
      login_password: $("#employeePassword").value
    });
    $("#employeePassword").value = "";
    saveSession(result);
    notify(`登入成功，歡迎 ${result.employee_name}`);
    setPage("calendar");
  }));

  $("#logoutButton").addEventListener("click", async () => {
    const token = state.session?.session_token;
    clearSession();
    if (token) rpc("logout_employee", { session_token: token }).catch(() => {});
    notify("已登出");
  });

  $("#employeeForm").addEventListener("submit", withBusy($("#employeeForm"), async () => {
    await rpc("admin_create_employee", {
      admin_code: $("#adminCode").value,
      employee_name: $("#employeeName").value,
      login_username: $("#newEmployeeUsername").value,
      login_password: $("#newEmployeePassword").value,
      employee_color: $("#employeeColor").value
    });
    $("#employeeName").value = "";
    $("#newEmployeeUsername").value = "";
    $("#newEmployeePassword").value = "";
    notify("員工帳號已新增");
    await loadEmployees();
  }));

  $("#adminCodeForm").addEventListener("submit", withBusy($("#adminCodeForm"), async () => {
    await rpc("admin_change_code", { current_admin_code: $("#currentAdminCode").value, new_admin_code: $("#newAdminCode").value });
    $("#currentAdminCode").value = "";
    $("#newAdminCode").value = "";
    notify("管理密碼已更新");
  }));

  renderCalendar();
  Promise.all([loadEmployees(), loadEditStatus(), restoreSession(), loadMonth()]).catch((error) => notify(error.message, true));
})();
