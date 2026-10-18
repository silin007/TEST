# MOTE — Windows 透明悬浮桌宠（P0 原型）

> 配套设计文档：[docs/architecture.md](docs/architecture.md) · [docs/p0_acceptance.md](docs/p0_acceptance.md)

## 最新 P0 验收结论（2026-10-18）

**本轮报告的 5 个阻塞缺陷已修复，自动化测试 221 条全绿。** 独立验收（[完整报告](tests/manual/results/2026-10-18-cfc09f5-codex/report.md)）曾判定「未通过，暂不进入 P1」，指出正常帧率下模拟不推进、旧动作完成事件误奖励、未知版本存档被自动覆盖、导出后黑底、快速双击不打开完整窗口。五个缺陷的修复与回归断言见 [实施记录 §3.1](docs/p0_执行记录_草案_2026-10-18.md)。

**仍需实机证据的项**（不可用自动化替代）：WIN-01/02/05/06/07、PLAT-01～03、SAVE-02/05/08、FOCUS-01、STAB-01、LOG-01 —— 须在**导出的 Windows 独立构建**上执行。

`tests/unit/test_p0_acceptance_audit.gd`（纯模拟、无存档写入）与 `test_p0_acceptance_integration.gd`（独立用户目录保护）作为验收留档保留。集成套件必须在专用 `MOTE_P0_AUDIT_INTEGRATION_...` 配置中运行，正常用户配置下会拒绝执行。

**测试隔离（已解决）：** `test_save.gd`、`test_app_smoke.gd` 三套涉及文件的测试现在在 `_initialize()` 首行调用 `SaveService.use_sandbox(...)`，存档与日志全部重定向到 `user://test_sandbox/<suite>/`。跑测试**不会再触碰**真实 `user://saves/`，可放心直接执行。

## 这是什么

MOTE 是一个运行在 Windows 桌面上的透明悬浮桌宠（测试角色），P0 验证四件事：**桌面窗口外壳**（透明/无边框/置顶/整窗穿透/恢复）、**骨骼动画**（idle/walk/happy/rest）、**最小生命模拟**（固定步进 + 需求 + UtilityAI）、**可靠本地存档**（JSON + 备份 + 异常恢复）。基础功能完全离线可用；云 AI、账号、同步、订阅、手机/网页端均不在 P0 范围。

## 锁定环境（ENV-01 依据）

| 项 | 值 |
|---|---|
| 引擎 | Godot **4.7.2 stable**（official build `ed1daf0bf`，位于 `C:\Users\lynn_\Godot\Godot.exe`） |
| 语言 | GDScript 2.0，全静态强类型 |
| 渲染 | `mobile` 渲染方法；Windows 驱动 `d3d12` |
| 目标 | Windows 桌面（E1 主环境） |
| 存档 | `user://saves/`（导出后为系统用户数据目录，诊断页会显示绝对路径） |

> 若更换引擎版本或渲染方案，须同步修订 `docs/architecture.md` 与 `docs/p0_acceptance.md`，并重跑受影响用例。

## 如何运行

### 编辑器运行（开发）

```bash
# 用已安装的 Godot 打开工程
"C:\Users\lynn_\Godot\Godot.exe" --path "I:\TEMP\godot-temp" -e

# 或直接运行主场景
"C:\Users\lynn_\Godot\Godot.exe" --path "I:\TEMP\godot-temp"
```

### 无头运行自动化测试

```bash
# 单个套件
"C:\Users\lynn_\Godot\Godot.exe" --headless --path "I:\TEMP\godot-temp" --script res://tests/unit/test_simulation.gd
"C:\Users\lynn_\Godot\Godot.exe" --headless --path "I:\TEMP\godot-temp" --script res://tests/unit/test_animation.gd
"C:\Users\lynn_\Godot\Godot.exe" --headless --path "I:\TEMP\godot-temp" --script res://tests/unit/test_save.gd
"C:\Users\lynn_\Godot\Godot.exe" --headless --path "I:\TEMP\godot-temp" --script res://tests/unit/test_app_smoke.gd

# 全部（Windows 批处理；可从任意目录运行，也可直接双击）
tests\run_tests.bat

# 只跑一个套件
tests\run_tests.bat test_save

# 引擎不在默认路径时
set GODOT=D:\Godot\Godot.exe
tests\run_tests.bat
```

> `run_tests.bat` 从**自身所在位置**推导工程根目录（不是当前目录），因此双击或从任意目录调用都可用；
> 找不到 `project.godot` 或引擎时会给出明确提示并以 2/3 退出。全部通过退出 0，任一套件失败退出 1。

| 套件 | 覆盖 | 断言数 |
|---|---|---|
| `test_simulation.gd` | SIM-01～04、PET-03①②③、PET-04①③；含 **P0-002 跨帧累加器**（60/75/144 FPS × 60s）与 **P0-003 陈旧事件拒奖**回归 | 38 |
| `test_animation.gd` | PET-01 真实 Skeleton2D/Bone2D 运动、PET-02 映射与失败返回 | 25 |
| `test_save.gd` | SAVE-01/03/04/05/06/07；含 **P0-001 写入锁**（未知版本在自动保存链路中存活）与显式新建事务回归 | 128 |
| `test_app_smoke.gd` | 主场景装配、启动模式、受控时钟、保存链路、退出事务；含 **P0-005 单击/双击/拖动互斥**回归 | 30 |
| **合计** | | **221** |

新增/修改脚本后若报 “Identifier/class not found”，先刷新类缓存：

```bash
"C:\Users\lynn_\Godot\Godot.exe" --headless --path "I:\TEMP\godot-temp" --import
```

> **关于输出里的 ERROR/WARNING**：`test_save` 的损坏档与故障注入用例会**故意**写入非法内容，
> 因此会出现 `ERROR: Parse JSON failed`（现已降到最少）与 `push_warning` 栈回溯；
> 测试脚本会在对应用例前打印 `[注] …属预期`。判断脚本本轮执行结果可查看：
> 每个套件的 `ALL … TESTS PASSED`，以及 `run_tests.bat` 的退出码（0 通过 / 1 失败）。
> `No Bone2D children of node …` 是 Godot 对叶子骨骼的固有告警，非错误。
> 上述输出只能说明已有断言是否通过；P0 是否通过仍取决于覆盖范围、补充验收和实机证据，见最新报告。

> **测试沙箱**：`test_save.gd` 与 `test_app_smoke.gd` 在 `_initialize()` 首行调用
> `SaveService.use_sandbox("user://test_sandbox/<suite>")`，存档与日志写入独立沙箱，
> `clear_all_for_test()` 只清沙箱。真实 `user://saves/` 不会被读写。

### 环境探针（ENV 证据，非测试）

```bash
"C:\Users\lynn_\Godot\Godot.exe" --headless --path . --script res://tests/probe/probe_window.gd   # 窗口属性签名
"C:\Users\lynn_\Godot\Godot.exe" --headless --path . --script res://tests/probe/probe_tray.gd     # StatusIndicator API
"C:\Users\lynn_\Godot\Godot.exe" --headless --path . --script res://tests/probe/probe_anim.gd     # 动画轨道常量
"C:\Users\lynn_\Godot\Godot.exe" --headless --path . --script res://tests/probe/probe_skeleton.gd # Bone2D.rest 默认值
```

### 导出 Windows 构建（验收用）

1. 编辑器 → 项目 → 导出 → Windows Desktop（需先安装 **4.7.2 对应导出模板**）。
2. 独立运行导出 exe 执行 `docs/p0_acceptance.md` 的手动用例（穿透/托盘/双屏等必须实机验证）。
3. 导出构建的 `user://` 绝对路径在应用诊断界面可见，验收时记录存档目录。

## 阶段进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| 1 | 工程骨架、版本锁定、Git 初始化 | 已完成 |
| 2 | 核心纯逻辑：PetState / PetSimulation / UtilityAI / ActionExecutor | 已完成（P0-002 时钟、P0-003 实例事件已修复，38 断言全绿） |
| 3 | WindowController / FocusController / AppController / RecoveryEntry（窗口、穿透、恢复） | 代码已完成（P0-004 透明、P0-005 双击已修复；穿透/恢复/双屏仍待导出构建实机验证） |
| 4 | 骨骼测试角色与四种动画 | 已完成（25 断言全绿） |
| 5 | SaveService JSON 安全存档 | 已完成（P0-001 写入锁已修复，128 断言全绿） |
| 6 | 隔离测试与运行文档闭环 | 已完成（三套文件类测试沙箱化，221 断言全绿） |

验收标准与完成门槛见 `docs/p0_acceptance.md` §7；最新 31 项执行状态以独立验收报告为准，不得以「代码写好了」或单元测试通过代替完整用例与实机证据。

**自动化已覆盖**：SIM-01/02/03/04、PET-01/02、PET-03①②③、PET-04①③、SAVE-01/03/04/05/06/07 的自动部分、装配与退出事务，以及 5 个阻塞缺陷的专项回归。
**仍须实机/导出构建验证**（不能凭代码宣称通过）：WIN-01/02/05/06/07（透明、跨应用穿透、托盘/恢复入口、双击观感）、PET-04④、SAVE-02/05 的进程中止部分、SAVE-08、FOCUS-01、PLAT-01～03、STAB-01、LOG-01。

## 目录结构

```text
scenes/app/           主场景（AppController 根节点）
scenes/pet/           骨骼测试角色
scenes/ui/            完整窗口、诊断/恢复界面
scripts/app/          AppController、FocusController
scripts/desktop/      WindowController 及平台适配
scripts/pet/          PetState、PetSimulation、UtilityAI、ActionExecutor
scripts/character/    AnimationController
scripts/persistence/  SaveService、v1 验证与迁移分派
resources/            行为/动画配置
tests/unit/           纯逻辑自动测试（可无头运行）
tests/manual/         桌面手工用例记录
```

## 版本控制

远程：<https://github.com/silin007/TEST.git>（分支 `master`，本地 `master` 已跟踪 `origin/master`）

```bash
git add -A
git commit -m "描述"
git push
```

- `.godot/`、导出产物、真实存档/日志、`.workbuddy/`（本机会话状态）均被忽略。
- `.gitattributes` 固定行尾：文本一律 LF，`.bat/.cmd/.ps1` 强制 CRLF（cmd 无法解析 LF 批处理）。
- 提交前建议先跑 `tests\run_tests.bat`，确认 4 个套件全绿。

## 已知环境备注（实施期实测结论）

- 当前 `project.godot` 仍标记 `Mobile` + `d3d12`（继承自初始工程）。桌面窗口能力以**实际运行 + 导出构建**为准，不以配置标记为准（架构 O-03）。
- **已实测（Godot 4.7.2）**：
  - `Window.mouse_passthrough` 是 **bool**（整窗穿透）；局部多边形另在 `mouse_passthrough_polygon`。跨应用命中仍须导出构建实测（WIN-02）。
  - `StatusIndicator` 可实例化，但**没有** `is_system_tray_available()`；菜单用 `set_menu(NodePath)`。入口自检只能间接进行，托盘真实可用须实机验证（WIN-06/O-04）。
  - `Animation` 无 `TYPE_ROTATION`（已改名 `TYPE_ROTATION_3D`，仅 Node3D）；2D 骨骼旋转用 `TYPE_VALUE` + `":rotation"` 属性轨道。动画须加入 `AnimationLibrary`（`AnimationPlayer.add_animation()` 已移除）。
  - `Bone2D.rest` 默认全零（det=0），不显式设置会在骨架求逆时报错；本工程已在 `scenes/pet/pet.tscn` 为每根骨骼设置 rest。
- 恢复入口采用「原生托盘优先 → 失败则建立独立常驻小窗口」的双层策略；即使托盘不可用也不退化为仅窗口内按钮（架构 §4.1）。
- `Window.unfocusable` 存在（探针确认），用于实现 `allow_focus` 策略：FLOATING/FOCUS/HIDDEN 不夺焦点，FULL 接受焦点。

## 诊断入口（架构 §8）

`AppController` 提供：`get_diagnostics()`（需求/动作/模式/入口/存档 revision/路径）、`debug_advance(seconds)`、`debug_set_save_fault(stage, enabled)`；`SaveService` 提供 `set_fault()` 与 `get_diagnostics()`。完整窗口（FULL）界面会显示只读诊断与存档恢复候选。
