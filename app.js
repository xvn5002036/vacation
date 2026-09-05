(() => {
  "use strict";

  const config = window.LEAVE_APP_CONFIG || {};
  const state = {
    month: new Date(new Date().getFullYear(), new Date().getMonth(), 1),
    employees: [],
    leaves: []
  };

  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => [...document.querySelectorAll(selector)];
  const toIsoDate = (date) => {
    const y = date.getFullYear();
    const m = String(date.getMonth() + 1).padStart(2, "0");
    const d = String(date.getDate()).padStart(2, "0");
    return `${y}-${m}-${d}`;
  };

  async function rpc(name, body = {}) {
    if (!config.supabaseUrl || !config.supabasePublishableKey || config.supabaseUrl.includes("YOUR_PROJECT")) {
      throw new Error("網站尚未完成資料庫設定");
    }
    const response = await fetch(`${config.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: {
        apikey: config.supabasePublishableKey,
        "Content-Type": "application/json"
      },
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

  function renderEmployees() {
    const legend = $("#employeeLegend");
    const select = $("#leaveEmployee");
    if (!state.employees.length) {
      legend.innerHTML = '<span>尚未新增員工</span>';
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

  function renderCalendar() {
    const [firstCell] = monthRange();
    const today = toIsoDate(new Date());
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
      const chips = (leavesByDate[iso] || []).map((leave) =>
        `<span class="leave-chip" style="color:${leave.color}">${escapeHtml(leave.employee_name)}</span>`
      ).join("");
      cells.push(`
        <button class="calendar-day${date.getMonth() !== month ? " outside" : ""}${iso === today ? " today" : ""}" type="button" data-date="${iso}" aria-label="${iso} 登記休假">
          <span class="day-number">${date.getDate()}</span>${chips}
        </button>`);
    }
    $("#calendarGrid").innerHTML = cells.join("");
  }

  async function loadEmployees() {
    state.employees = await rpc("get_employees");
    renderEmployees();
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

  function escapeHtml(value) {
    return String(value).replace(/[&<>'"]/g, (char) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
    })[char]);
  }

  function withBusy(form, task) {
    const button = form.querySelector('button[type="submit"]');
    return async (event) => {
      event.preventDefault();
      button.disabled = true;
      try { await task(); } catch (error) { notify(error.message, true); } finally { button.disabled = false; }
    };
  }

  $$(".tab").forEach((tab) => tab.addEventListener("click", () => setPage(tab.dataset.page)));
  $("#openLeaveForm").addEventListener("click", () => setPage("leave"));
  $("#todayButton").addEventListener("click", () => {
    state.month = new Date(new Date().getFullYear(), new Date().getMonth(), 1);
    loadMonth();
  });
  $("#prevMonth").addEventListener("click", () => {
    state.month = new Date(state.month.getFullYear(), state.month.getMonth() - 1, 1);
    loadMonth();
  });
  $("#nextMonth").addEventListener("click", () => {
    state.month = new Date(state.month.getFullYear(), state.month.getMonth() + 1, 1);
    loadMonth();
  });
  $("#calendarGrid").addEventListener("click", (event) => {
    const day = event.target.closest("[data-date]");
    if (!day) return;
    $("#leaveDate").value = day.dataset.date;
    setPage("leave");
  });

  $("#leaveForm").addEventListener("submit", withBusy($("#leaveForm"), async () => {
    await rpc("register_leave", {
      selected_employee_id: $("#leaveEmployee").value,
      employee_code: $("#employeeCode").value,
      selected_date: $("#leaveDate").value
    });
    $("#employeeCode").value = "";
    notify("休假日期已登記");
    const selected = new Date(`${$("#leaveDate").value}T12:00:00`);
    state.month = new Date(selected.getFullYear(), selected.getMonth(), 1);
    await loadMonth();
    setPage("calendar");
  }));

  $("#employeeForm").addEventListener("submit", withBusy($("#employeeForm"), async () => {
    await rpc("admin_create_employee", {
      admin_code: $("#adminCode").value,
      employee_name: $("#employeeName").value,
      employee_code: $("#newEmployeeCode").value,
      employee_color: $("#employeeColor").value
    });
    $("#employeeName").value = "";
    $("#newEmployeeCode").value = "";
    notify("員工已新增");
    await loadEmployees();
  }));

  $("#adminCodeForm").addEventListener("submit", withBusy($("#adminCodeForm"), async () => {
    await rpc("admin_change_code", {
      current_admin_code: $("#currentAdminCode").value,
      new_admin_code: $("#newAdminCode").value
    });
    $("#currentAdminCode").value = "";
    $("#newAdminCode").value = "";
    notify("管理密碼已更新");
  }));

  $("#leaveDate").value = toIsoDate(new Date());
  renderCalendar();
  Promise.all([loadEmployees(), loadMonth()]).catch((error) => notify(error.message, true));
})();

