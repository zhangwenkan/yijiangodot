# 水折射时钟修正与验证（2026-11-26）

两份水折射着色器把 Scene UBO 的曝光值误当 TIME，导致涌浪与六组法线滚动无法跟随主水面的实际时间。已在独立工程修正：当前 Godot 4.7.2 float 布局为 5696 字节，TIME 位于 2816，GLSL 前缀由 177 改为 176 个 vec4；主水公式、源参数与几何保持。诊断改存完整缓冲并校验布局。旧 byte 2832 的 TIME=1.0 及只保存该 16 字节切片的实际时钟结论撤回；原始记录保留。

`workbench/reports/water-clock-20261126/gpu-v1/` 运行 228.359 秒，exit 0，错误/警告均为 0。两图动态响应、源状态和冻结恢复检查通过，独立 CPU 另行复核原始字节：

| 地图 | 初始→随后真实 TIME | 累积变化像素 | 累积变化字节 |
|---|---|---:|---:|
| 无名岛 | 102.03333282470703 → 115.78349304199219 | 94,812 | 192,109 |
| 游仙村 | 181.74180603027344 → 190.5485076904297 | 27,112 | 42,521 |

每图双时刻的 432 字节 Water frame 完全相同；water-only 粒子数为 0、实例缓冲为空，水描述符有效。六份 5696 字节完整 UBO 均与各自保存的时钟切片匹配，TAA/jitter=0。六组前后 HDR 有限，零累积区域逐位不变；两图 baseline/restore 的 PNG 及解码像素完全一致。

折射 apply 数值比较保留旧公式和界限：`(du+dv)/256 + 邻近正半精度 ULP + 2e-6`。没有屏蔽边界或加大容差。

| CPU UV 算术模型 | 六组结果 | 超界分量 |
|---|---|---:|
| float64 | 通过 | 0 |
| float32-div | 通过 | 0 |
| float32-recip | 失败 | 566 |

recip 的超界全部位于无名岛最后一行 y=719，三组分别为 137/137/292 个分量，内部超界为 0；游仙村三组均通过。该 CPU 倒数乘法模型在这些样本走原 UV 回退分支，GPU 输出没有恢复原色；这是已保存的边界算术模型差异，尚不能证明 GPU 实际使用何种指令。旧独立 `verify_readback.py` 对无名随后时刻的 float64/recip 结果复算与新分析器完全相同。

因此真实时钟与动态检查为通过，但三种模型的 CPU 综合 `overall_passed=false`，不能把引擎运行成功称作整套数值通过。全部超界值、原图/GPU/参考值与界限保留供后续核查。核心修正不以这项未解决的 CPU 边界模型差异作为扩大容差理由。

推进 TIME 时 CPU 场景处理保持禁用，但其他使用 TIME 的材质也会运动，故累积变化不是水独立因果或原 UE 逐像素等价证明。本次游仙恢复通过也不取消此前及本轮其他冻结诊断失败；完整复原与美术效果仍待后续验证。

已入仓工具：`tools/verification/run_source_water_clock.py` 与 `tools/verification/analyze_source_water_clock.py`。分析器保留真实 clock/dynamic 与所有数值模型的分项结果；详细 CPU 证据在 `workbench/reports/water-clock-20261126/cpu-review-v1/`。大型原始缓冲不提交 Git。

在配齐本地资产、同版本 Godot、NumPy/Pillow 的独立仓库根复跑；输出必须为新目录：

```powershell
python tools/verification/run_source_water_clock.py --out workbench/reports/water-clock-new-gpu
python tools/verification/analyze_source_water_clock.py --run workbench/reports/water-clock-new-gpu --out workbench/reports/water-clock-new-cpu
```

GPU 运行器与 CPU 分析器分别返回结果，不能用前者的成功覆盖后者的失败。旧切片、未知布局、切片不匹配和 NaN 的证据边界已由 `tools/verification/test_source_tlv_clock_evidence.py` 验证，均不得记为已验证时钟。
