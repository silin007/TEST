# 对 08df5df 独立复验报告的 P0-006 修复回应

> 性质：修复方回应。复验报告（`…/outputs/tests/manual/results/2026-10-18-08df5df-recheck/report.md`）与全部证据**未做修改**，保持原始留档。
> 本文件只记录 P0-006 与复验 §5 裁切问题的处置、证据与边界。

## 1. P0-006｜隐藏主窗口失败（B1，WIN-06）

### 复验指出的两个要求

1. 选择并实测可行的**原生隐藏实现**；
2. 平台操作失败必须**返回明确错误并阻止提交 HIDDEN 状态**。

### 探针实测（`tests/probe/probe_hide.gd`，真实 Windows 驱动）

| 手段 | 结果 |
|---|---|
| `win.visible = false` | ❌ `Can't change visibility of main window.`（window.cpp:1017），visible 仍 true —— 与复验一致 |
| `DisplayServer.window_set_mode(MINIMIZED)` | ✅ 回读 `window_get_mode()`=1；恢复 WINDOWED 回 0 |
| `WINDOW_HANDLE` 原生句柄 | 存在（HWND 非 0），留作 P1 托盘级隐藏备选 |
| `win.size=1×1` | 被钳制为 180×64，伪隐藏，禁用 |

### 修复

- `_hide_native()`：DisplayServer 最小化 + **回读校验**，未确认进入 MINIMIZED 即返回 `ERR_UNAVAILABLE`。
- `_can_hide_natively()`：headless/dummy 显示驱动直接判不支持，杜绝假成功。
- `apply_mode()` **失败整体回滚**（mode/mouse/can_walk/allow_focus 快照还原 + 重应用窗口外观）。
- `restore_visible()` 改为 `_restore_from_minimize()`，只还原自己造成的最小化。
- `validate_geometry()` 最小化时跳过，避免污染隐藏前矩形。
- `get_platform_state()` + `AppController` 诊断合并：**同时**暴露应用 mode 与平台真实状态。
- `_last_mode_error` 进入面板显示与诊断：失败用户可见，不静默。

### 验证

- 原生流程（`probe_hidden_flow.gd`，真实驱动）：HIDDEN → `err=0`、`minimized=true`、`window_mode=1`；
  恢复 FLOATING → `minimized=false`、`window_mode=0`。
- 回归断言 5 条（headless 覆盖"平台拒绝"分支）：失败返回错误、模式回滚、不记录为已隐藏、
  失败原因进诊断、诊断暴露平台状态。

### 边界（诚实登记）

- 最小化窗口**不在桌面渲染**，但任务栏条目是否消失取决于窗口样式；
  **托盘级"完全不可见"未实现**（P1 可用 WINDOW_HANDLE + Win32 ShowWindow 或 GDExtension）。
- 验证在**编辑器运行环境**完成；WIN-06 仍须**导出构建**复验（复验 §1 的执行边界同样适用于本修复）。
- 复验 §4 要求的"三种来源（FLOATING/FULL/FOCUS）隐藏 + 托盘显示 + 恢复交互 + 退出"完整矩阵尚未执行。

## 2. 复验 §5｜FULL 按钮裁切

上轮我以为 ScrollContainer 解决了裁切，复验证明没有——接受指正。

实测根因（`probe_layout.gd`）：**`window/stretch/mode="canvas_items"` + 基线 256×256**。
窗口 960×640 时缩放 = min(960/256, 640/256) = 2.5，UI 画布仅 **384×256**（与实测完全吻合）：
按钮被压成两行后总高 305 > 可用 232，右侧"退出"被裁；诊断区高度塌成 0；宠物在 FULL 被放大 2.5 倍。

修复：`stretch/mode="disabled"`；按钮行改 `HFlowContainer`（窄窗自动换行）；诊断区最小高 120。

实测（**重排后**测量——切模式同帧测量会拿到重排前的最小尺寸）：面板 960×640、
六按钮一行（"退出"右边界 408 < 960）、诊断区 533 高。截图：`full_panel.png` / `floating.png`（本目录）。

回归断言 4 条；**已验证能抓住旧 bug**：临时改回 canvas_items 后断言失败
（`面板 384×256 覆盖窗口 (960,640)`），随后还原。

## 3. 数字勘误

复验 §2 指出 README 分套件断言数与实际不符（README 记 sim 38 / save 128，实际 47 / 119）。
已核实并修正：**47 / 25 / 119 / 39 = 230**（smoke 本轮 +9）。勘误说明已写入实施记录 §3。

## 4. 本轮仍未声称通过

WIN-02/05（组合矩阵）/06（导出构建视觉确认）/07、PLAT-01～03、SAVE-02/05（进程中止）/08、
PET-04④、FOCUS-01、STAB-01、LOG-01 —— 维持复验报告的登记状态不变。

**结论口径**：P0-006 已在产品代码中修复并有真实驱动证据；P0 整体仍未通过，
以 `docs/p0_acceptance.md` 门槛与导出构建实测为准。
