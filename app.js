(() => {
  "use strict";

  const config = window.LEAVE_APP_CONFIG || {};
  const state = {
    month: new Date(new Date().getFullYear(), new Date().getMonth(), 1),
    employees: [],
    leaves: [],
    editStatus: null
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

  function escapeHtml(value) {
    return String(value).replace(/[&<>'"]/g, (char) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
    })[char]);
  }

  function renderEmployees() {
    const legend = $("#employeeLegend");
    const select = $("#leaveEmployee");
    if (!state.employees.length) {
      legend.innerHTML = "<span>尚未新增員工</span>";
      select.innerHTML = '<option value="">請先由管理員新增員工</option>';
      return;
    }
    legend.innerHTML = state.employees.map((employee) =>
      `<span class="legend-item"><span class="dot" style="background:${employee.color}"></span>${escapeHtml(employee.employee_name)}</span>`
    ).join("");
    select.innerHTML = '<option value="">請選擇姓名</option>' + state.employees.map((employee) =>
      `<option value="${employee.employee_id}">${escapeHtml(employee.employee_name)}</option>`
    ).join("");
  }

  function renderEditStatus() {
    const banner = $("#editStatus");
    const form = $("#leaveForm");
    const open = Boolean(state.editStatus?.editing_open);
    if (!state.editStatus) return;
    banner.classList.toggle("locked", !open);
    banner.textContent = open
      ? `本月預休填寫開放中｜請在 ${state.editStatus.deadline_date} 前完成`
      : `本月預休已截止｜${state.editStatus.next_open_date} 重新開放修改`;
    form.querySelectorAll("input, select, button").forEach((control) => { control.disabled = !open; });
    $("#calendarHint").textContent = open
      ? "點選未來月份的日期，可直接新增或取消預休。"
      : "目前只能查看所有人的預休，無法新增或取消。";
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
      const editable = Boolean(state.editStatus?.editing_open) && isFutureMonth(date);
      const chips = (leavesByDate[iso] || []).map((leave) =>
        `<span class="leave-chip" style="color:${leave.color}">${escapeHtml(leave.employee_name)}</span>`
      ).join("");
      cells.push(`
        <button class="calendar-day${date.getMonth() !== month ? " outside" : ""}${iso === today ? " today" : ""}${editable ? " editable" : " locked-day"}" type="button" ${editable ? `data-date="${iso}"` : ""} aria-label="${iso}${editable ? " 登記預休" : " 查看預休"}">
          <span class="day-number">${date.getDate()}</span>${chips}
        </button>`);
    }
    $("#calendarGrid").innerHTML = cells.join("");
  }

  async function loadEmployees() {
    state.employees = await rpc("get_employees");
    renderEmployees();
  }

  async function loadEditStatus() {
    const rows = await rpc("get_edit_status");
    state.editStatus = rows[0];
    const minDate = toIsoDate(firstFutureMonthDate());
    $("#leaveDate").min = minDate;
    if (!$("#leaveDate").value || $("#leaveDate").value < minDate) $("#leaveDate").value = minDate;
    renderEditStatus();
    renderCalendar();
  }

  async function loadMonth() {
    const [start, end] = monthRange();
    try {
      state.leaves = await rpc("get_leave_days", { start_date: toIsoDate(start), end_date: toIsoDate(end) });
      renderCalendar();
    } catch (error) {
      $("#calendarGrid").innerHTML = `<div class="empty">${escapeHtml(error.message)}</div>`;
      notify(error.message, true);
    }
  }

  function withBusy(form, task) {
    return async (event) => {
      event.preventDefault();
      const buttons = [...form.querySelectorAll('button[type="submit"]')];
      buttons.forEach((button) => { button.disabled = true; });
      try { await task(event); } catch (error) { notify(error.message, true); } finally {
        const leaveLocked = form.id === "leaveForm" && !state.editStatus?.editing_open;
        buttons.forEach((button) => { button.disabled = leaveLocked; });
      }
    };
  }

  $$(".tab").forEach((tab) => tab.addEventListener("click", () => setPage(tab.dataset.page)));
  $("#openLeaveForm").addEventListener("click", () => setPage("leave"));
  $("#todayButton").addEventListener("click", () => { state.month = new Date(new Date().getFullYear(), new Date().getMonth(), 1); loadMonth(); });
  $("#prevMonth").addEventListener("click", () => { state.month = new Date(state.month.getFullYear(), state.month.getMonth() - 1, 1); loadMonth(); });
  $("#nextMonth").addEventListener("click", () => { state.month = new Date(state.month.getFullYear(), state.month.getMonth() + 1, 1); loadMonth(); });
  $("#calendarGrid").addEventListener("click", (event) => {
    const day = event.target.closest("[data-date]");
    if (!day) return;
    $("#leaveDate").value = day.dataset.date;
    setPage("leave");
  });

  $("#leaveForm").addEventListener("submit", withBusy($("#leaveForm"), async (event) => {
    const removing = event.submitter?.value === "remove";
    const credentials = {
      selected_employee_id: $("#leaveEmployee").value,
      login_username: $("#employeeUsername").value,
      login_password: $("#employeePassword").value,
      selected_date: $("#leaveDate").value
    };
    await rpc(removing ? "delete_leave" : "register_leave", credentials);
    $("#employeePassword").value = "";
    notify(removing ? "這天的預休已取消" : "預休日期已登記");
    const selected = parseIsoDate($("#leaveDate").value);
    state.month = new Date(selected.getFullYear(), selected.getMonth(), 1);
    await loadMonth();
    setPage("calendar");
  }));

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
  Promise.all([loadEmployees(), loadEditStatus(), loadMonth()]).catch((error) => notify(error.message, true));
})();
