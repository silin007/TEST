# 对验收报告（2026-10-18-cfc09f5-codex）的缺陷修复回应

> 性质：修复方回应。原报告 `report.md` 与其全部证据文件**未做任何修改**，保持为本轮验收的原始留档。
> 本文件只记录「按报告 §6 顺序做了什么、断言落在哪、哪些仍必须实机验证」。

## 1. 五个阻塞缺陷的处置

### P0-001｜未知更高版本存档被自动覆盖（SAVE-07）

- **报告要求**：「对未知/待选择恢复状态锁定普通保存，只有完成隔离并由用户明确选择的恢复/新建事务才能解除；补测启动、防抖、周期保存及退出，不仅测一次 load 返回值。」
- **实际修复**：`SaveService` 增加写入锁 `lock_writes(reason)` / `is_write_locked()` / `get_lock_reason()`。
  - 双道拦截：`save_snapshot()` 与提交层 `_commit()` 各自独立检查，绕过任一层都拦得住。
  - 加锁点覆盖全部失败分支：主档缺失但有候选、主档损坏有备份、主档损坏无备份、`UNSUPPORTED_VERSION`、schema 非法、结构非法有候选、结构非法无备份。
  - 解锁点只有三处显式事务：`load_snapshot()` 返回 OK、`restore_from_candidate()` 成功、`start_new_save()` 成功。
  - 新增 `start_new_save(snapshot)`：隔离 → 丢弃身份 → 首次提交，单一原子入口；隔离失败**保持锁定**。
- **回归断言**（`test_save.gd`）：
  - `P0-001 启动加载识别为 UNSUPPORTED_VERSION`
  - `P0-001 连续 5 次自动保存全部被拒绝`（等价防抖提交 + 多个 60s 周期保存）
  - `P0-001 未知版本原档字节未被改动`
  - `P0-001 未生成降级备份`
  - `P0-001 主档缺失但有候选 → RECOVERABLE（非 MISSING）` + `拒绝把它当首次运行建新档`
  - `SAVE-07 版本拒绝后可显式重建（隔离旧档后新建）` + `重建后 revision 从 1 开始`
- **仍待实机**：SAVE-02（首次启动保存节奏）、SAVE-05 的进程中止部分、SAVE-08。

### P0-002｜普通帧率下模拟时间丢失（SIM-02）

- **报告要求**：「补强 FPS 和短停顿断言。先通过直接时间序列，再跑实际 15/30/60 FPS 在线测试。」
- **根因确认**：`advance_time()` 中 `var accumulator := dt` 是**局部变量**，每帧余数随函数返回消失。60 FPS（dt≈0.01667）永远凑不满 0.1 s，`while` 循环体一次都不进 —— 模拟完全停摆，与报告「15/30/60 FPS 均 0 tick」完全吻合。
- **实际修复**：`_accumulator` 提为字段；`while` 消化并用 `MAX_CATCH_UP_TICKS` 限制单帧补算；超限时 `fmod` 收敛；断点（>5 s）时清零；新增 `get_accumulator()` 供诊断与断言。
- **回归断言**（`test_simulation.gd`）：60 / 75 / 144 FPS 各跑 60 s，**同时**断言
  `tick ≈ 600`、`elapsed ≈ 60 s`、`needs 确实推进（energy < 99）`、`余数 < SIM_DT`。
  报告特别指出「不能只看 tick 数」，因此四项缺一即失败（首轮我漏了 needs，靠这条断言才发现 60 FPS 余数正好卡在 0.1 的边界）。
- **仍待实机**：真实 15/30/60 FPS 在线运行（非直接时间序列），以及 STAB-01 的 60 分钟长稳。

### P0-003｜动作实例 ID 重复，旧事件能中断新动作并发奖（PET-04）

- **报告要求**：「回归取消、失败、重复、旧事件、同 tick 多请求。」
- **实际修复**：`_instance_seq` 单调递增（不再从 1 重排）+ `_closed_instances` 关闭表（上限 256，防无限增长）+ `_active_instance_id`。`on_action_event()` 依次拒绝 `instance_id <= 0`、已在关闭表、不等于活动实例三种情况。
- **回归断言**（`test_simulation.gd`）：
  - `实例 ID 单调递增不重复（1 vs 2）`
  - `旧实例事件不发奖（comfort 保持）`
  - `旧实例事件不结束当前动作（当前 react_happy）`
  - `当前实例事件正常发奖`
  - `重放已关闭实例不发奖`
  - `instance_id<=0 的事件被忽略`
- **一处澄清**：第二轮 happy 请求在取消后会因 **2 秒 happy 冷却**被拒绝（架构 §5.2 规定），这是正确行为。回归用例先推进 2.5 s 过冷却再请求，避免把模型规定误当成缺陷。

### P0-004｜透明悬浮窗显示黑色矩形（WIN-01）

- **实际修复**：探针证实 `project.godot` 缺两个开关且均为 `false`，已补：
  - `[display] window/per_pixel_transparency/allowed=true`
  - `[rendering] viewport/transparent_background=true`
- **证据缺口（诚实登记）**：headless 无窗口表面，自动化无法验证。WIN-01 必须在**导出的 Windows 独立构建**上复验。

### P0-005｜正常快速双击未打开 FULL（WIN-05）

- **报告要求**：「区分按下、越过阈值的真实拖动与点击；仅真正拖动结束才抑制点击；重新验证单击、双击、拖动三者互斥。」
- **实际修复**：
  - `WindowController` 输入处理拆为 `_begin_press`（只记起点）/ `_update_drag`（越过 `DRAG_THRESHOLD=4px` 才转入拖动并 emit `drag_started`）/ `_end_press`（只有真拖动过才 `_sync_rect_from_window` + emit `drag_ended`）。
  - 新增 `did_drag_occur()` 暴露「本次按下是否真拖动」。
  - `AppController._on_pet_input_event()` 改用系统 `InputEventMouseButton.double_click` 判定双击，**删除**自算的 300 ms 窗口；点击抑制只在 `did_drag_occur()` 为真时生效。
  - `apply_mode()` 里的旧 `_end_drag("mode_switch")` 调用改为直接复位三态，避免遗留按下状态（WIN-03）。
- **回归断言**（`test_app_smoke.gd`，16 条）：零位移不算拖动、零位移不触发 `drag_ended`、2 px 抖动仍在阈值内、越阈值 `drag_started`/`drag_ended` 各恰好一次、下次按下复位标记、模式切换不遗留拖动状态。
- **仍待实机**：WIN-05 的用户观感（双击手感、单击互动不被吞）必须在真实窗口确认；自动化只证明了状态机互斥。

## 2. 报告 §4 风险项的处置

| 风险项 | 处置 |
|---|---|
| **测试隔离**（`clear_all_for_test()` 会清真实 `user://saves/`） | 已解决。`SaveService` 的 9 个路径常量全部改由 `_resolve()` 派发，新增 `use_sandbox(root)` / `is_sandboxed()`；三套涉及文件的测试在 `_initialize()` 首行启用沙箱，写入 `user://test_sandbox/<suite>/`。Godot 4.7.2 **没有** `--user-data-dir` 选项（已用 `--help` 确认），故采用应用层方案。 |
| **环境传递**（`can_walk` 是否真被注入） | 已加固：`_environment()` 改读 `_can_walk` 字段，新增 `set_can_walk()` 注入口；回归用例对比注入前后 walk 是否可启动。 |
| **FULL 界面裁切** | 已修：诊断 Label 放入 `ScrollContainer` 并启用 `AUTOWRAP_WORD_SMART`；按钮行与恢复区用 `SIZE_SHRINK_END` 固定底部，长诊断不再顶出 960×640。 |
| **`allow_focus` 产生但未消费** | 已消费：`_apply_focus_policy()` 用 `Window.unfocusable`（4.7.2 探针确认存在）；FLOATING/FOCUS/HIDDEN 不夺焦点，FULL 接受焦点。 |

## 3. 自动化结果

```
test_simulation  38 断言  全通过
test_animation   25 断言  全通过
test_save       128 断言  全通过
test_app_smoke   30 断言  全通过
合计            221 断言  0 失败（run_tests.bat 退出码 0）
```

原 161 条断言无回归；新增 60 条全部针对上述缺陷。

## 4. 本轮**未**声称通过的项目

以下项目自动化无法替代，仍须导出构建 + 实机执行，状态维持原报告的「失败/阻塞/部分完成」不变：

- **WIN-01/02/05/06/07**：透明表现、跨应用点击命中、双击观感、托盘恢复全链路、入口失效。
- **PLAT-01～03**：双屏负坐标、热拔插、混合 DPI。
- **SAVE-02/05（进程中止部分）/08**、**PET-04④**、**FOCUS-01**、**STAB-01**、**LOG-01**。

**结论口径**：产品代码侧 5 个阻塞缺陷已修复并有回归保护；P0 是否通过仍以 `docs/p0_acceptance.md` §7 的门槛与实机证据为准，不因 221 条断言通过而改变。
