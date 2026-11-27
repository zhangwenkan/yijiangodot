# 地形受光漂移定位与权重导入修正（2026-11-27）

游仙村冻结漂移已进一步定位到原地形受光路径；同时查实并修正了两图权重纹理导入时的数据改写。两件事尚未建立“权重错误导致时间漂移”的因果关系，不能据此宣布漂移或完整复原完成。

## 仅原地形受光对照

`landscape-drift-20261127/gpu-v1` 运行 32.328 秒，exit 0、错误/警告 0，共 12 次捕获。只向运行时最终地形 shader 的 render_mode 插入 `unshaded`；原参数、几何及其它材质保持。每个条件四帧，独立 CPU 分别检查六对，沿用逐字节一致门槛：

| 条件 | 最早 POST_OPAQUE 变化对数 | 变化像素并集 | 最大 HDR 差 | 最终 PNG 最大通道差 |
|---|---:|---:|---:|---:|
| 原状态 | 6/6 | 116 | 0.0697021484375 | 6/255 |
| 仅地形临时 unshaded | 0/6 | 0 | 0 | 0 |
| 恢复原受光 | 6/6 | 20 | 0.00390625 | 6/255 |

地形 unshaded 组所有三阶段 HDR、折射前后和 PNG 均完全一致；恢复受光后漂移重现。这缩小了调查范围，但不能直接判定是哪项 BRDF、light、cluster 或 shadow 输入，也不能把关闭受光用作生产修复。

严格识别的唯一目标为 `OriginalLandscape_youxian` / `OriginalLandscape_Compiled_youxian`，源地形组件 40。目标 70 个 uniform 保持，共 370 份材质（其余 369 份）五次状态检查通过；完整前后材质快照 JSON 字节与内容完全一致。该检查覆盖 CPU 可见材质及场景引用，不是内部 GPU uniform 回读。

36 份上游完整 5696B UBO 彼此完全一致，12 份折射 UBO 彼此也完全一致；两类之间恒定仅 byte 2700 的 uint32 值为 15/7，故不能称全部 48 份相同。真实 TIME=18.11944580078125，TAA/jitter=0；36 份深度、12 份累积缓冲跨条件完全一致。PNG 在 HDR 捕获之后取得，不称同帧。独立分析 `evidence_passed=true`，但因原态/恢复漂移，`overall_passed=false`。

## 权重纹理的独立导入因果对照

四张地形 PNG 是八个权重通道，alpha 也是权重数据。旧导入启用 `process/fix_alpha_border=true` 会按透明色图处理它们。隔离工程复制两图四张 PNG，各做 baseline/candidate，共八份；所有原像素不变，导入 params 仅此项 true/false 不同。

隔离 import 12.359 秒、verify 2.453 秒，均 exit 0、错误/警告 0。baseline 的完整 RGBA 哈希复现旧生产缓存；candidate 四份导入 RGBA 均与源 PNG 解码字节完全一致：

| 图与权重文件 | baseline 被改写像素 / 通道 | candidate |
|---|---:|---|
| 无名 1–4 | 19,747 / 28,693 | 全图 exact |
| 游仙 1–4 | 7,257 / 11,867 | 全图 exact |
| 两图 5–8 | 各 0 / 0 | 全图 exact |

这证明该导入设置造成固定权重数据改写；不证明它造成此前随帧受光漂移。两份 5–8 虽在当前数据未见改写，仍采用数据纹理一致策略关闭该设置。

生产仅修改四份 `project/assets/{wuming,youxian}/landscape/atlas-weights-{1-4,5-8}.png.import` 中的此布尔值，原 PNG 不改。重导入 `landscape-weights-20261127/reimport-v1` 已完成，5.844 秒、exit 0、错误/警告 0。备份、PNG 与设置哈希保存在 `production-import-v1`。

生产 `production-verify-v1` 已运行 4.734 秒，exit 0、错误/警告 0，四份导入 RGBA 与源图全字节相同，验证输入前后哈希保持。`verify_landscape_weights.gd` 逐个覆盖 texel 调用实际 `original_footsteps.select_map/_landscape_material`，合计 438,482 次，选材误差 0；不播放声音，不代替实际行走与桥木碰撞验证。

| 项目 | 无名岛 | 游仙村 |
|---|---:|---:|
| 覆盖 texel / 实际脚步选材次数 | 278,902 | 159,580 |
| 修正后权重和不匹配 / 选材不匹配 | 0 / 0 | 0 / 0 |
| 旧导入全零权重点 → 修正后 | 345 → 0 | 322 → 0 |
| 旧导入与源权重的物理材质分类差异 | 2,018 | 1,488 |
| 旧导入与源权重的脚步音组差异 | 245 | 45 |

两图源权重和范围均为 254–256。无名岛实际物理材质计数：Desert 262,239、Rock 13,722、Grass 2,371、未指定 570；游仙村为 Desert 146,393、Rock 11,930、Grass 1,257。脚步音组无名岛 Dirt 276,531、Grass 2,371；游仙村 Dirt 158,323、Grass 1,257；两图本次地形覆盖均无 Wood，不扩展为桥上木板选材已验证。

独立 CPU 复核将全部计数、旧→新类别转换与预先生成的 `cpu-footstep-expectations.json` 一一比较，并重新解码生产源 PNG、逐字节比较四份导入 raw。首轮 v1 验证器对可选 baseline 本身只检查长度；本次外部复核额外确认实际 baseline 目录与启动参数相同，四份文件 SHA 均匹配修改前 manifest 的预存哈希及隔离 run-v1 的记录，补齐当时旧→新统计的基线证据。

随后 verifier v2 已将这项保证收进工具入口：四份旧 baseline 使用修改前 manifest 预存 SHA，启动快照、实际读入和结束快照均检查，且 baseline 纳入完整输入前后比较。`production-verify-v2` 正例 6.312 秒、exit 0、错误/警告 0，四份 SHA exact、438,482 次实际选材全通过。`verifier-negative-v2` 将一份 baseline 等长改 1 字节，0.672 秒、exit 1、错误/警告 0，地图统计尚未开始即拒绝；前后快照相同，明确报告 baseline SHA mismatch，两次对应前/后检查，另有两图未完成的总检查错误。该负例证明入口不会把等长错误基线当成有效统计依据；v1 及其外部复核历史继续保留。

## 修正后的环境捕获与投影

`capture-run-v1` 运行 99.860 秒，exit 0、错误/警告 0；两图分别两次六面捕获，24 份 raw 重复逐字节一致。各图主视图 baseline 重复、捕获前后画面均为 0 通道变化；场景状态与时间缩放恢复通过，failures 为空。无名岛另有 live-time 恢复测试，验证恢复处理和时间缩放，不主张该运行中画面相同。

`integrated-v1` 已用此次 capture-0 生成两图 SH9。独立复核确认 capture manifest 与六面 raw 的输入哈希正确，常量球、下半球及方向 RGB 测试均通过。32 采样相对全分辨率最大 RGB 误差，无名岛约 `[0.0005181, 0.0005587, 0.0006816]`，游仙村约 `[0.0006363, 0.0009033, 0.0014493]`；这是投影采样误差，不是对原版画面的误差。

独立复核报告 `cpu-production-review.json` 共 233 项全通过，包含实际文件 SHA、原始字节与计数比较。它是只读 CPU 检查，没有再启动 Godot/GPU。上述捕获来自当前跨引擎重建场景，并非原 UE 的 GPU 原始缓冲，不能替代原版光照一致性验收。

`compare-run-v1` 运行 122.656 秒，exit 0、错误/警告 0。两图各 default / water-center 共四机位，分别替换漫反射、反射、两者后恢复旧资源；四机位恢复图均为 0 通道差，434 / 301 份 shader 材质恢复无错误。新旧图存在预期变化，例如游仙村 water-center 的新旧双替换比较有 148,290 个通道变化、最大 55/255；这是整图字节统计，不是水体 ROI 或改善评分。

`cache-deployment-v1` 已备份旧资源，将两图各一份 cube `.res` 与 SH9 `.json` 共四份资源正式部署，并核验源/目标 SHA。`house-run-v1` 运行 171.469 秒，exit 0、错误/警告 0；两图各室外初态→室内→室外→室内→室外五阶段，以及室内退出时的清理检查均通过，failures 为空。该测试实际调用 `house.set_inside`，不是门口导航或角色穿门测试。

后续独立 CPU 部署复核 `cpu-deployment-review.json` 共 169 项全通过：重新解码四机位 PNG，复算各新旧变化通道数/最大差，并确认 restored 全字节 exact；四份当前生产资源与各自 capture/SH9 源文件字节、哈希、长度一致；house 各阶段与清理报告逐项核对。此补充检查不重复 GPU，也不是对画面美术质量评分。

根代理已检查两图 default 新画面，未见明显缺材或破面；不将此作为美术验收。已通过的导入、选材、捕获、投影、部署和房屋状态检查不代表完整复原。

## 权重与环境资源更新后的冻结复测

`landscape-drift-20261127/post-weight-refresh-v1` 已独立分析至 `post-weight-refresh-cpu-v1`，`evidence_passed=true`、`overall_passed=false`：

| 条件 | 最早 POST_OPAQUE 变化对数 | 变化像素并集 | 最大 HDR 差 |
|---|---:|---:|---:|
| 更新后原状态 | 6/6 | 82 | 0.032958984375 |
| 仅地形临时 unshaded | 0/6 | 0 | 0 |
| 恢复原受光 | 6/6 | 54 | 0.0184326171875 |

中间 unshaded 组所有原始阶段和 PNG 完全一致；原态/恢复 PNG 分别 5/6、6/6 对有变化。370 份材质及目标 70 个 uniform 前后快照字节一致；36 份上游 UBO、12 份折射 UBO 仍各组一致，36 深度和 12 累积缓冲跨条件一致。

因此固定权重数据虽已修正，时间漂移仍重现，仍定位于地形受光相关路径。不能把不同运行的变化像素数减少解释为漂移根因已部分修好。

## 仅地形直接镜面分支对照

`specular-v1` 通过正式 wrapper 运行 88.469 秒，exit 0、引擎错误 0，输入源码哈希保持。只在唯一原地形的最终运行时 shader 中，将直接镜面分支条件 `if (nl > 0.0 && ROUGHNESS > 0.0)` 改为 `if (false && nl > 0.0 && ROUGHNESS > 0.0)`；独立 diff 确认除此一行无其它 shader 改动，漫反射、fragment、材质参数和其它材质不变。

| 条件 | POST_OPAQUE 变化对数 | 变化像素并集 | 最大 HDR 差 |
|---|---:|---:|---:|
| 原状态 | 5/6 | 11 | 0.0048828125 |
| 仅地形关闭直接镜面分支 | 6/6 | 22 | 0.13427734375 |
| 恢复原分支 | 6/6 | 87 | 0.050048828125 |

独立分析 `specular-cpu-v1` 的证据通过、整体仍失败；370 份材质、目标 70 个 uniform、完整前后材质快照恢复通过，36 上游与 12 折射 UBO 仍各组稳定，深度/累积缓冲相同。原状态有一对在这次 POST_OPAQUE 原始帧相同、最终 PNG 不同；PNG 捕获较晚，不能将其当作同帧结论。

单独关闭直接镜面分支仍漂，因而“只有这条直接高光分支造成全部漂移”不足以解释当前结果；这不证明高光完全没有贡献。该关断仅用于显式诊断，未部署到默认运行。源 DXBC 对照另指出的 Fresnel 公式缺口仍是独立候选、待验证，不能借此当成漂移修复或宣称跨引擎逐位等价；审核资料在 `landscape-drift-20261127/lighting-input-audit-v2/`，候选不进入生产或 Git。后续继续检查地形的局部 cone/受光输入，按单一变量和原有精确一致门槛推进，不修改生产受光公式掩盖漂移。

## 核心代码与复跑

四份小型 `.import` 使用精确文件白名单纳入 Git；原 PNG、GLB、ctex、`.godot` 和大型报告继续排除。诊断与验证器作为独立显式入口，不默认开启 TLV 或 unshaded。

在已配齐本地资产和同版本引擎的仓库根运行，输出目录必须新建：

```powershell
python tools/verification/run_source_tlv_drift.py --landscape-controls --direct-youxian --out workbench/reports/landscape-new/gpu --timeout 300
python tools/verification/drift/analyze_landscape_controls.py --run workbench/reports/landscape-new/gpu --out workbench/reports/landscape-new/cpu --helpers tools/verification/drift
python tools/verification/run_source_tlv_drift.py --landscape-specular-controls --direct-youxian --out workbench/reports/landscape-specular-new/gpu --timeout 300
python tools/verification/drift/analyze_landscape_controls.py --run workbench/reports/landscape-specular-new/gpu --out workbench/reports/landscape-specular-new/cpu --helpers tools/verification/drift --control no-direct-specular
```

所有 landscape 控制选项互斥，均已通过正式 wrapper 实际采集。分析器严格拒绝缺失/重复捕获、阶段不齐、原始尺寸或哈希不符及材料恢复失败。帮助/AST、本轮实际 12 捕获的独立复算均完成；合成负例覆盖以对应分析器测试记录为准，早期 unshaded 分析轮没有执行缺失负例。分析器返回 1 可以表示证据完整但精确冻结比较失败，应同时查看分项结果。

本地证据根为 `workbench/reports/landscape-drift-20261127/` 与 `workbench/reports/landscape-weights-20261127/`。独立导入 A/B 与地形分析已归档；本次 233 + 169 项生产 CPU 复核已归档到后者的 `cpu-production-review-v1/`，负例输入另存 `verifier-negative-input-v2/`，不进入 Git。此前所有冻结失败与错误时间切片记录继续保留。

## 局部直接灯路径与严格计数诊断

继续完成 `cone-v1`、`direct-v1`、`local-input-v1` 与 `raw-count-v1`，均为唯一游仙原地形的临时运行时 shader 控制，默认受光代码、模型和资产未改。原态与恢复条件仍漂，不能把以下诊断关闭项当成生产修复。

| 运行与条件 | POST_OPAQUE 变化对 | 变化像素并集 | 最大 HDR 差 |
|---|---:|---:|---:|
| cone：原态 / 旁路局部 cone / 恢复 | 6/6、6/6、6/6 | 44 / 74 / 79 | .0050048828125 / .0048828125 / .105224609375 |
| direct：原态 / 仅方向灯 / 仅局部灯 / 无直接灯 / 恢复 | 6/6、0/6、6/6、0/6、6/6 | 27 / 0 / 135 / 0 / 17 | .004638671875 / 0 / .011962890625 / 0 / .0047607421875 |
| local-input：原态 / 常数 / 灯色 / 衰减 / Lambert / 恢复 | 全部 6/6 | 93 / 906 / 1148 / 135 / 129 / 36 | .01171875 / .110595703125 / 16450 / .057373046875 / .022216796875 / .0218505859375 |
| raw-count：原态 / 中性输出计数 / 恢复 | 全部 6/6 | 159 / 779 / 32 | .0084228515625 / .375 / .011962890625 |

各运行耗时 105.657 / 42.468 / 46.578 / 31.734 秒，退出 0、引擎错误 0、输入哈希保持。`direct-v1` 的仅方向灯和无直接灯条件所有五类 HDR 及最终 PNG 均 exact，将当前调查收窄到地形局部灯相关路径。静态 guard 会允许编译器删除无用计算，不能据源码保留宣称 GPU 指令完全相同。

`local-input` 保留原 ALBEDO/环境/雾，仅改变局部直接光累加表达式，常数条件尚不是无污染调用次数。灯色条件的 16450 是去掉衰减后的有限 HDR 最大差，不是原版正常光照误差。独立原始重算 24 帧、120 HDR、24 PNG 与主报告统计零差；原态与灯色 PNG 为 5/6 对变化，其余为 6/6。资料：`local-input-independent-v1/`。

`raw-count` 仍保留直接受光循环，仅对该地形增加 `fog_disabled, ambient_light_disabled`，fragment 末尾覆盖 ALBEDO=1、METALLIC/SPECULAR/EMISSION=0、IRRADIANCE/RADIANCE=黑色且 alpha=1；两处直接镜面累加禁用，局部漫反射每次精确增加 1/16。原 NORMAL 源码保留，GPU 编译优化边界同上。该模式不改共享 shader include、灯节点或默认生产效果。脚本解析 0.485 秒通过；370 材质、70 参数、完整前后快照与原 shader 恢复通过。

旧 906 坐标的跨运行复用检查**失败并保留**：882 点四帧符合 RGB 相等、乘 16 为 0–31 整数；873 点深度与旧 run exact。24 个数值不合格点全部位于 33 个跨 run 深度变化点内，不能把它们强归地形或放宽门槛。`raw-count-cpu-v1` 的 evidence=false、overall=false。分析器真实子进程返回 2；默认 PowerShell 尾部 native 失败曾被外层显示为 1，独立 subprocess 已核明，工具不需因此改返回逻辑。

另对**本次运行自身**779 个 POST_OPAQUE 变化像素做独立复算：779/779 的四帧 RGB 严格相等，乘 16 都为精确整数，实际计数 0–8、26 种四帧序列、最大变化 6。四帧完整 depth/UBO exact。这是当前输出的数值事实，不将其用来改写旧坐标复用失败，也不以灰度整数单独证明运行时材质 ID。独立报告和空间图：`raw-count-independent-v1/`。

同 run 的源 GLB 射线检查中，779 条射线均首先命中源地形，源命中与保存深度残差最大 1.874442 cm；285 点残差≤1 mm，进一步要求距投影三角边≥0.5 px、1 cm 内无源非地形、次地形间距>1 cm 后有155个保守候选。实际导入启用压缩/LOD，GPU primitive/material ID 未取得，所以保持 runtime_ownership_proven=false，不把源候选当成运行时精确归属。记录：`raw-count-source-ownership-v1/`；旧906的独立源审查留在 `local-count-source-ownership-v1/`。

官方本地引擎源码推导 cluster tile=32/shift=5，本次 scene UBO z_far=1800.23046875；尚未读取实际 implementation/cluster buffer。779 点占71个 tile+z 分组，其中21组内部四帧序列不相同；155保守候选中的29组有6组内部不同。三个同源三角的相邻像素例：

| 像素 A / 次数 | 像素 B / 次数 | 推导 cluster | 源三角 |
|---|---|---|---:|
| (448,167) / 0,0,1,1 | (448,168) / 0,1,1,1 | (14,5,1) | 242861 |
| (126,251) / 0,1,0,0 | (126,252) / 1,1,0,0 | (3,7,0) | 233021 |
| (9,255) / 1,0,0,0 | (10,255) / 1,0,1,1 | (0,7,0) | 228486 |

在相同运行时地形/层掩码/cluster等前提成立时，仅“整份 cluster 灯列表随帧变”不能解释同组的像素差异。仍需 GPU 缓冲和实际着色器执行证据，不据此归因驱动错误。stock 脚本 API 未暴露内部 cluster RID；源码真实 opaque 绑定位为 set1/binding9。未找到保留当前灯路径而仅禁用 subgroup 的真实配置；不能用裁灯容量或切渲染器冒充等价控制。相关源码与接口审查：`cluster-access-review-v1/`。原适配 ReflectionProbe 已被 mode2 adapter 隐藏，环境创建代码不能当成其当前活跃证据。

所有运行仍分别核对上游与折射 UBO：cone/raw 各36/12份，direct为60/20份，local-input为72/24份，各自组内exact；两类之间byte2700恒定15/7，不合称全部一致。各次depth/accum跨条件exact，370/70材料恢复保持。PNG晚于同回调HDR，不称同帧。局部cone、直接光拆分、输入拆分和计数均是显式诊断；TLV/caster仍未接入默认行走，完整复原未完成。

新增复跑入口（新输出目录，原exact门槛不变）：

```powershell
python tools/verification/run_source_tlv_drift.py --direct-youxian --landscape-direct-controls --out workbench/reports/new-direct/gpu --timeout 240
python tools/verification/drift/analyze_landscape_direct_controls.py --run workbench/reports/new-direct/gpu --out workbench/reports/new-direct/cpu --helpers tools/verification/drift --control direct-series
python tools/verification/run_source_tlv_drift.py --direct-youxian --landscape-local-input-controls --out workbench/reports/new-local-input/gpu --timeout 240
python tools/verification/drift/analyze_landscape_local_input_controls.py --run workbench/reports/new-local-input/gpu --out workbench/reports/new-local-input/cpu --helpers tools/verification/drift --control local-input-series
python tools/verification/run_source_tlv_drift.py --direct-youxian --landscape-raw-count-controls --out workbench/reports/new-raw-count/gpu --timeout 240
python tools/verification/drift/analyze_landscape_raw_count.py --run workbench/reports/new-raw-count/gpu --out workbench/reports/new-raw-count/cpu --helpers tools/verification/drift --control raw-count --prior-count-samples workbench/reports/landscape-drift-20261127/local-input-cpu-v1/landscape-local-count/postopaque-world-samples.json
```

raw-count 的旧样本参数有意做严格跨run有效性审查，可能因可见表面改变而拒绝，不能为了出通过结果删掉失败坐标。本轮核心工具、小文档纳入Git，大报告、捕获原始缓冲及原资产继续仅本地保存。


## 外部 GPU 捕获尝试与停止点（2026-11-27）

为读取实际 cluster/light buffer，完成三次 RenderDoc 捕获尝试；三次均没有生成 RDC，未执行 replay，也未取得实际 GPU cluster/light buffer。这三次抓帧阶段的默认生产着色、几何和灯光未改。各次证据独立保留，不能把场景自身的 live compositor 捕获视为 RenderDoc 成功。

| 尝试 | 实际结果 | 捕获及恢复边界 |
|---|---|---|
| `renderdoc-raw-count-v1` | wrapper 219.297 秒；注入和 TargetControl 连接成功，但未收到 Vulkan RegisterAPI，未触发捕获。Godot gate 90 秒超时后继续原诊断，controller 180 秒等待超时。 | 后续完成 12 次 live compositor 捕获；370 材质、70 参数及完整前后快照恢复通过，场景/compositor/process_mode/time_scale 恢复，输入源码 SHA 保持，引擎错误/警告 0。Godot 自然结束但因 gate failure 退出 1；整次捕获失败。 |
| `renderdoc-raw-count-v2` | qrenderdoc 在 3.813 秒以 `0xC0000005` 崩溃，没有形成 controller 捕获结果、目标身份、Godot receiver/READY 或 RDC。 | wrapper 最后原子替换 `result.json.writing` 时遇到 WinError 5，旧 result 的 waiting 状态已陈旧。从保留的 `.writing` 只读恢复失败终态证据：`supervision_finished`、监督耗时 96.813 秒。没有改写历史结果；该恢复不代表捕获成功，也不据此确诊崩溃原因。 |
| `renderdoc-raw-count-v3` | wrapper 43.297 秒；捕获环境仅传给目标 Godot，Vulkan RegisterAPI 已成功注册（supported=true、presenting=false），随后地图加载前出现 Vulkan device lost，Godot 以 `0xC0000005` 崩溃。 | 没有 READY、触发、RDC 或 receiver/材质前后快照，不能声称本次材质/状态恢复通过。输入源码 SHA 保持；`natural_process_completion=true` 仅表示非 wrapper 强杀，不表示正常运行成功。 |

三次 `capture_passed=false`。v1 的 qrenderdoc 退出 0 不能替代捕获状态；v2 的旧 waiting 文件不能覆盖 `.writing` 中已完成的失败监督快照。v1/v3 的本地 runner、audit 和引擎记录分别在 `workbench/reports/landscape-drift-20261127/renderdoc-raw-count-v1/`、`renderdoc-raw-count-v3/`。v2 恢复证据为 `workbench/reports/landscape-drift-20261127/renderdoc-small-evidence-v1/renderdoc-v2-recovery-evidence-20261127/recovery-evidence.json`，其中保存原 result 和 `.writing` 的来源及哈希。

另对 v1 gate 超时后取得的 **本次 live 运行自身**数据完成 CPU 独立复算：POST_OPAQUE raw-count 四帧变化并集 767 点，767/767 四帧 RGB 严格相等且乘 16 精确为 0–31 整数，未使用 epsilon、rounding 或排除像素。实际计数为 0–7、39 种四帧序列、最大计数变化 6，最大 raw HDR 差 0.375，6/6 对变化。36 份上游完整 UBO 和 12 份折射 UBO各自组内 exact，不能写成全部 48 份相同；36 份 depth exact。运行时材质/cluster 身份仍未证明（`identity_proven=false`）。审计为 `workbench/reports/landscape-drift-20261127/renderdoc-small-evidence-v1/renderdoc-v1-live-cpu-audit-20261127/summary.json` 及同目录 `audit.json`。

上述 767 点属于新的失败捕获尝试之后的 live 观测，不是 RDC 帧，不证明 live/RDC 同帧，也不把整次 `overall_passed=false` 改为通过。此前 raw-count-v1 的 779 点/26 序列/0–8 和旧 906 坐标复用失败仍作为各自历史证据保留，不能混用运行或以本次数字覆盖。

同类 GPU 抓帧在此暂停。捕获进程崩溃与 device lost 仅是本次外部捕获路径的失败事实，不能据此归因原场景冻结漂移或断言驱动缺陷。停止抓帧时，Fresnel 缺口尚在独立研究；其后限定地形的部署和验证见下一节，不将其视为漂移修复。TLV/caster 仍未默认启用，完整复原与美术验收均未完成。大报告及捕获数据仍只在本地保留。


## 原地形 Fresnel 的有限源公式补齐（2026-11-27）

RenderDoc 抓帧暂停后，独立完成了原地形 Fresnel 适用范围核对，并将限定修正部署到 `project/scripts/original_lightfunctions.gd` 和 `project/shaders/original_lightfunction_receiving.gdshaderinc` 两个生产文件。此前“生产着色未改”描述的是上节三次抓帧阶段；本节记录其后的有限变更，不能继续概括当前状态为完全未改着色。

原字节证据覆盖当前复原采用的无名岛、游仙村两个代表地形编译实例，各 8 个六 MRT pixel shader，共 16/16 通过解压、fresh D3DDisassemble 与已保存 ASM/hash 核对。GBuffer 材质通道编译数据流对应 numeric model 1，支持只对这两图的 compiled landscape 补齐 `F90 = clamp(50 * F0.g, 0, 1)`；不是原版实机 RT/SRV 绑定或所有 permutation 的验证。源证据归档 `workbench/reports/landscape-drift-20261127/native-fresnel-scope-v1/`，其中“未实施”的建议是当时审计阶段记录。

注入器仅对 `source_landscape_compiled=true` 材质在 include 前写入 `SOURCE_LF_NATIVE_F90`，并把宏状态纳入 shader 缓存键，避免同一源 shader 串用两个分支。非地形继续走原默认公式；没有把人物、鸟、落叶、水体或其它材质的原 shading model 缺失值当成 DefaultLit，也未顺带改 F0 映射、其它 GGX 项、几何或默认灯光。

headless/cache 检查 0.406 秒、脚本 parse 0.437 秒、两图正常渲染路径检查 80.343 秒，均 exit0，引擎错误/警告签名为空。独立 CPU 审核 80 项通过，归档 `workbench/reports/landscape-drift-20261127/native-fresnel-runtime-cpu-v1/`。两图分别四轮检查全材质：无名岛每轮 586、游仙村每轮 370；各 70 项地形 uniform、shader 资源/源码、材料引用与参数恢复通过。这是 CPU 可见状态核对，不是逐项 GPU uniform 回读。非地形 ShaderMaterial 分别检查 433/300 个；两图各仅 1 个缓存 shader 带宏，总缓存 21/13。运行时候选源码去掉唯一 29 字节 define 后与旧式源码逐字相同，生产两文件仍匹配部署候选。

每图在同一固定机位保存三张 PNG：临时旧式、候选、恢复候选后的重复图。这里“旧式”指此前 Godot 公式，不是原版 UE 截图；每图相机记录相同、time_scale=0，PNG 均为 960×540 RGB、SHA 与记录一致。

| 地图 | 旧式与候选 | 候选与恢复后重复图 |
|---|---|---|
| 无名岛 | 文件哈希及全部像素 exact | 文件哈希及全部像素 exact |
| 游仙村 | 73 像素、87 颜色通道不同，最大 1/255 | 16 像素、18 颜色通道不同，最大 1/255 |

游仙村旧式与恢复图为 80 像素/93 通道差异，最大同为 1/255。无名岛 exact 不证明画面改善；游仙村候选重复图仍有差异，不能把旧式与候选之间的全部差异归因这条公式，更不能宣称原冻结漂移已解决。只覆盖保存的两个机位，不代表两图全范围或原版 UE 逐像素等价。

上述 maps-v1 的游仙村最终 renderer shutdown 的 restored 状态及嵌套 errors 空已复核；无名岛换图前未保存单独的完整 shutdown JSON，其目标 shader/材料恢复由该图四轮核对覆盖，不能把 maps-v1 扩写为独立全栈 teardown 证明。后续 house 运行的单独恢复证据另述如下。

该有限修正后又完成 `native-fresnel-capture-run-v1`：105.5 秒、exit0，引擎错误/警告签名为空。`native-fresnel-capture-v1/capture-refresh-validation.json` 中两图各两组六面 raw 的 SHA 逐面严格一致，`baseline_repeat` 和 `before_after` 均为 0 变化通道，`controller_state_restored=true`。这些是重建场景六面捕获的重复性与恢复检查，不是此前失败的 RenderDoc 抓帧，也不是主相机原地形局部灯冻结漂移已消失的证明。

无名岛另完成运行时钟恢复检查：实际字段为 `live_time_capture.time_scale_restored=true`、`live_time_test.outer_time_scale_restored=true` 和 `live_time_test.process_mode_restored=true`；外层 time_scale 从 1 经捕获内部 0 返回 1。该项 `image_equality_asserted=false`，不能扩写为活跃时间前后图像 exact。

`native-fresnel-integrated-v1` 已生成两图输出，原有 3 项 CPU 投影测试通过；其 manifest/raw provenance 已纳入下述最终独立 CPU 审阅。

`native-fresnel-compare-run-v1` 已完成：109.313 秒、exit0，引擎错误/警告签名为空。两图各 default/water-center 两机位分别替换漫反射、反射及两者，再恢复；四机位恢复均为 0 变化通道。无名岛/游仙村各 434/301 个 ShaderMaterial、323/275 个 SH9 材质恢复检查 errors 为空。差异统计范围为全图字节，不是水体专用 ROI，也不证明原版 UE 像素等价；记录为 `native-fresnel-compare-v1/sky-refresh-comparison.json`。

两图各一份 cubemap 和 SH9，共四份缓存已备份、部署并核对 SHA，记录为 `native-fresnel-cache-deployment-v1/deployment.json`。目标为 `project/source_reflection_candidate/{wuming,youxian}-source-scene-capture.res` 和 `project/sh9_candidate/{wuming,youxian}-source-sh9.json`；本次缓存更新与前述两个生产代码文件的有限改动分别记录，不能把“仅两文件”扩写为没有更新派生缓存。

随后 production house 运行 159.64 秒、exit0，引擎错误/警告签名为空，最终 `SOURCE_REFLECTION_HOUSE_VALIDATED` 为 failures=[]、maps=2。已实读 `native-fresnel-production-house-v1/reflection-house-validation.json`：每图依次验证 outdoor-initial→indoor-1→outdoor-1→indoor-2→outdoor-2 五阶段，候选 sky 均保持、各阶段 errors 空；室内缓存 3 项，返回室外为 0。每图另外从室内执行 shutdown，`shutdown_from_indoor.status=restored`、`shutdown_assertions.house_outdoors=true`，errors 空，反射源恢复为 2、energy 恢复约 0.099。该运行验证实际 `house.set_inside` 状态切换和清理，不是角色穿门导航或行走验收。

最终独立 CPU 审阅已归档 `workbench/reports/landscape-drift-20261127/native-fresnel-refresh-cpu-v1/`，322 项通过、失败 0。30 个 raw 文件的半精度值均有限，两图各两组冻结六面逐字节一致；按当前积分器重算两图各四组 SH9 系数，误差均为 0，三项解析探针通过。34 张 PNG 完整解码，20 张对照图的全字节差异独立重算，四机位旧缓存恢复仍为 0 通道；四资源来源/当前目标/之前备份哈希均核对，house 两图五阶段及室内关停恢复记录也已复核。

审阅边界保留：当前积分器的逐面 box mip 不等于原引擎跨面 GPU mip 或 FP16 规约逐位复现；对照额外重复帧未保存，只能由运行报告支持。compare 的材料恢复记录没有单独序列化最终 controller 状态或 sky 资源身份，保存的旧/恢复像素 exact 只适用于四个机位。house 是状态记录与 10 张 PNG 解码，未断言 house 图像重复、实际穿门步行或全地图稳定。有限源公式补齐和缓存刷新不等于原冻结漂移修复、原版 UE 像素等价、完整复原或美术验收；TLV/caster 仍未默认启用。

本轮 9 文件代码提交已在本地形成 `6b78ced243b4ed174172d282d67ff67c8f9a7a2f`（Restore native landscape Fresnel and refresh sky captures）；本节封存时尚未 push，不记作已同步远端。
