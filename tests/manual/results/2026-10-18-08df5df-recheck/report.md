# MOTE P0 独立复验 · 08df5df · 2026-10-18

**结论：P0 整体仍未通过。上轮 5 项问题已有对应修复证据；本轮新确认隐藏功能失败，阻塞 WIN-06。** 本报告是修复后复验，保留上一轮报告和日志，不覆盖历史失败记录。

## 1. 对象与执行边界

- 工程 `I:\TEMP\godot-temp`，基准提交 `08df5df`，完整提交号和环境见 [environment.json](environment.json)。
- Godot `4.7.2.stable.official.ed1daf0bf`，Windows 11 构建 26200，Mobile / D3D12，RTX 4070 Laptop GPU。
- 代码复制到本次工作目录执行，自动测试和原生程序分别使用独立的 `MOTE_P0_AUDIT_INTEGRATION_RECHECK_08df5df`、`MOTE_P0_AUDIT_RECHECK_08df5df` 和 `MOTE_P0_AUDIT_LIFECYCLE_08df5df` 用户目录。
- 保留产品自带的 SaveService 测试沙箱；未直接运行原配置下可能影响正常存档的夹具。原产品脚本、场景和 project.godot 未修改。
- 使用上轮已校验的 4.7.2 Windows 模板，在副本中配置自定义模板路径，导出不带探针、只读观察版、原生生命周期测试版三个独立 DEBUG 构建。
- 原生生命周期版在实际 Windows 显示驱动下调用已有应用回调，不发送系统鼠标输入；它验证窗口状态转换，不替代物理托盘点击测试。实际“隐藏宠物”按钮也另外经桌面工具点击复现。

## 2. 自动复验：全部通过

| 套件 | 实际 PASS 数 | 退出码 | 原始输出 |
|---|---:|---:|---|
| test_simulation | 47 | 0 | [stdout](test_simulation.stdout.txt) |
| test_animation | 25 | 0 | [stdout](test_animation.stdout.txt) |
| test_save | 119 | 0 | [stdout](test_save.stdout.txt) |
| test_app_smoke | 30 | 0 | [stdout](test_app_smoke.stdout.txt) |
| 原有四套合计 | **221** | 全部 0 | [汇总](automated-summary.json) |
| test_p0_acceptance_audit | 14 | 0 | [stdout](test_p0_acceptance_audit.stdout.txt) |
| test_p0_acceptance_integration | 2 | 0 | [stdout](test_p0_acceptance_integration.stdout.txt) |

共 237 条自动检查通过，无脚本解析错误。README 原分配为模拟 38、存档 128；本轮实际为 47、119，合计同为 221，此处按日志登记。套件通过不能代替完整 P0 用例和实机矩阵通过。

## 3. 上轮 5 项问题的关闭范围

| 原问题 | 本轮独立证据 | 判定边界 |
|---|---|---|
| P0-001 未知版本存档自动覆盖 | 实际主场景运行约 3 秒后 schema 仍为 999，原字节保持一致，autosave_stopped=true；补充集成测试 2/2 通过 | 原复现已修复；更长周期、退出及恢复的完整矩阵仍按 SAVE 用例执行 |
| P0-002 普通 FPS 不推进 | 15/30/60 FPS 的 60 秒序列为 599/600/599 tick，energy=79.401/79.400/79.401；原生运行时间也持续推进 | 原复现已修复；三个 FPS 各 5 分钟的实机矩阵尚未完成 |
| P0-003 旧事件误奖励 | 旧实例 1、新实例 2；迟到旧事件后仍为 walk，comfort 保持 50，专项检查全通过 | 原复现已修复；动画缺失、超时、完整交互矩阵仍需完成 |
| P0-004 黑色矩形 | 独立导出构建实际观察到角色外显示底层应用；探针记录 transparency_allowed=true、transparency_available=true、transparent_bg=true，首帧背景角像素 alpha=0 | 本机这条 Mobile/D3D12 路径取得修复证据；多背景/长时间/多环境复验尚未完成 |
| P0-005 快速双击不开 FULL | 用桌面工具在角色区域实际双击，窗口从 FLOATING 切到 FULL，出现完整面板，输入日志归档 | 基础双击已实测；20 轮切换、拖动互斥和各显示器组合尚未完成 |

双击截图：[double-click-full.png](double-click-full.png)。只读运行证据：[runtime-observer.jsonl](runtime-observer.jsonl)、[runtime-inputs.jsonl](runtime-inputs.jsonl)。

原生时钟两个采样点之间：墙钟增量 220.688 秒，模拟增量 220.800 秒，2208 tick，误差约 0.051%；已超过上轮仅推进 0.1 秒的状态。见 [native-clock-summary.json](native-clock-summary.json)。这只是短时在线证据，不是 60 分钟稳定性通过。

## 4. 新阻塞 P0-006：隐藏主窗口失败（B1，WIN-06）

### 实际操作与结果

1. 在独立 Windows 构建中，通过真实双击进入 FULL。
2. 实际点击面板的“隐藏宠物”。
3. 面板消失，宠物仍在桌面上显示；窗口保留完整窗口大小。
4. 原生 stderr 明确报错：`Can't change visibility of main window.`
5. 运行探针随后记录：应用 `mode=HIDDEN`，但真实 `Window.visible=true`，`unfocusable=true`。应用已宣称隐藏，原生操作实际失败。

实际按钮触发栈见 [native-runtime.stderr.txt](native-runtime.stderr.txt)：

```text
ERROR: Can't change visibility of main window.
_apply_native_attributes (window_controller.gd:159)
apply_mode (window_controller.gd:89)
switch_mode (app_controller.gd:192)
_on_panel_action (app_controller.gd:516)
<anonymous lambda> (full_panel.gd:86)
```

### 独立原生集成复现

额外导出的生命周期测试版在 **Windows 显示驱动**下执行已有回调，5 项检查、1 项失败，退出码 1：

| 阶段 | 实测 | 判定 |
|---|---|---|
| 初始 FULL | FULL / visible=true | 通过 |
| 从 FULL 进入 HIDDEN | HIDDEN / visible=true；引擎报上述错误 | **失败，应不可见** |
| 调用显示宠物回调 | FULL / visible=true | 回调完成，但前一步并未真正隐藏 |
| 调用打开 FULL 回调 | FULL / visible=true | 同上，不能据此证明隐藏恢复成功 |
| 恢复交互回调 | FLOATING / visible=true | 安全返回路径有效 |

证据：[native-lifecycle.stdout.txt](native-lifecycle.stdout.txt)、[native-lifecycle.stderr.txt](native-lifecycle.stderr.txt)、[结构化结果](native_lifecycle_result.json)、[测试探针源码](native_lifecycle_probe.gd.txt)。没有把 headless 的 visible 值用作原生隐藏判断。

### 定位与修复方向

当前 `WindowController._apply_native_attributes()` 对主 Window 执行 `win.visible=false`；本机引擎明确拒绝该操作。该函数仍返回 OK，AppController 因而更新模式、鼠标策略、面板和存档，形成应用状态与平台状态不一致。

下一步须先选择并实测可行的原生隐藏实现，同时让平台操作失败返回明确错误并阻止提交 HIDDEN 状态。不能只隐藏 FullPanel、停止绘制或保存 mode=HIDDEN 来代替隐藏窗口。修复后复验 FLOATING/FULL/FOCUS 三种来源的隐藏、托盘显示、恢复交互、打开完整窗口和退出。

## 5. 其他观察及未完成范围

- FULL 的诊断区已有换行改进，但本轮截图中右侧退出按钮仍未完整显示；需要继续检查按钮行在当前 viewport/缩放下的布局，不能仅凭增加 ScrollContainer 认为裁切已解决。
- FLOATING 时 `unfocusable=true`、FULL 时 false 的原生值已取得；10 分钟免打扰输入和异常场景仍未完成。
- 最初操作工具自动启动两次超时；带日志的原生启动诊断正常运行并退出 0，后续成功取得窗口并完成透明、双击和隐藏操作。因此启动工具超时不登记为产品崩溃。
- 跨应用穿透、物理托盘可达性/入口失效、负坐标与混合 DPI、热拔插、实际睡眠、提交中止、60 分钟稳定性均未完成。不复用上轮取证受阻记录作为新版已测结论。
- 本轮没有修改 Windows 显示布局或使用户电脑睡眠；未把短时 CPU/内存采样当作稳定性通过。

## 6. 31 项状态更新

“部分完成”包含已有自动或实机证据，完整用例仍未通过。原用例步骤与门槛不变。

| 用例 | 当前登记 | 本轮进展或剩余内容 |
|---|---|---|
| ENV-01 | 部分完成 | Git、引擎、模板、导出确认；三轮完整离线启停未执行 |
| WIN-01 | 部分完成 | 本机透明基本复验成功；背景/环境矩阵未完成 |
| WIN-02 | 未执行 | 新构建跨应用真实输入尚未复验 |
| WIN-03 | 部分完成 | 输入阈值自动回归通过；完整手动拖动矩阵未完成 |
| WIN-04 | 部分完成 | 存档及加载自动证据；各模式与几何重启组合待测 |
| WIN-05 | 部分完成 | 真实快速双击进入 FULL 成功；20 轮及组合未完成 |
| WIN-06 | **失败** | P0-006，隐藏主窗口被引擎拒绝 |
| WIN-07 | 未执行 | 恢复入口失效与平台事务失败注入待测 |
| PET-01 | 部分完成 | 动画套件通过，完整四动画人工复核待完成 |
| PET-02 | 部分完成 | 映射自动证据，完整表现/隔离矩阵待完成 |
| PET-03 | 部分完成 | 原生运行出现自主行为，规则测试通过；环境组合待补 |
| PET-04 | 部分完成 | 旧事件原复现关闭，完整失败/取消/超时矩阵待补 |
| SIM-01 | 部分完成 | 数值套件通过；全部边界与数据范围验收待补 |
| SIM-02 | 部分完成 | 原复现关闭，短时原生时钟误差约 0.051%；实机 FPS 矩阵待补 |
| SIM-03 | 部分完成 | 断点自动部分通过；离线重启全流程待补 |
| SIM-04 | 部分完成 | 现有套件通过；须对照墙钟注入要求补齐独立证据 |
| SIM-05 | 部分完成 | 纯模拟与在线持续推进有证据；隐藏实际失败 |
| SAVE-01 | 部分完成 | 往返自动检查通过；全字段/窗口模式实机组合待补 |
| SAVE-02 | 部分完成 | 隔离原生程序有存档与自动保存；启停节奏全流程待补 |
| SAVE-03 | 部分完成 | 备份恢复自动部分通过；真实恢复 UI 待补 |
| SAVE-04 | 部分完成 | 锁定与显式新建自动部分通过；完整隔离失败 UI 待补 |
| SAVE-05 | 部分完成 | 错误注入回归通过；真实进程提交中断待补 |
| SAVE-06 | 部分完成 | 自动故障与退出回退通过；占用/权限/空间及实机免打扰待补 |
| SAVE-07 | 部分完成 | 未知版本启动覆盖原复现关闭；其余完整验收组合待核对 |
| SAVE-08 | 未执行 | 延迟 IO 与多触发保存串行化场景待补 |
| FOCUS-01 | 未执行 | 焦点 flag 已观察；10 分钟完整操作尚未执行 |
| PLAT-01 | 部分完成 | 取得双屏运行环境；负坐标/混合 DPI 未覆盖 |
| PLAT-02 | 未执行 | 未改变显示布局或热拔插 |
| PLAT-03 | 未执行 | 未执行实际睡眠唤醒 |
| STAB-01 | 阻塞 | 隐藏场景失败，未进行最终 60 分钟综合验收 |
| LOG-01 | 部分完成 | 本轮证据归档；轮转和完整已知问题流程待补 |

## 7. 下一步与收尾

优先修复 **P0-006 的原生隐藏实现及错误传播**，随后复验 WIN-06/07 与跨应用穿透，再推进平台、存档中断及最终 60 分钟测试。上轮 5 项修复不等同于 31 项全部通过，当前仍不进入 P1。

本轮仅新增复验记录、原生诊断探针的证据副本及文档状态更新；没有修改产品逻辑、提交或推送 Git。自己启动的验收进程已清理，原用户应用与存档未作为测试夹具使用。
